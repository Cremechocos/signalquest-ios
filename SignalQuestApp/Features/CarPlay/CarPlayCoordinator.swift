import CarPlay
import Combine
import CoreLocation

@MainActor
enum CarPlayLocationRenderGate {
    /// Une réponse réseau peut arriver après expiration du fix ou révocation GPS.
    /// Le contrôle et la mutation restent synchrones sur le main actor.
    @discardableResult
    static func commit(_ fix: CLLocation, service: LocationService, update: () -> Void) -> Bool {
        guard service.isUsable(fix) else { return false }
        update()
        return true
    }
}

/// Signale le changement d'onglet. `CPTabBarTemplate.delegate` est une référence
/// faible : le coordinateur le retient.
@MainActor
final class CarPlayTabBarDelegate: NSObject, CPTabBarTemplateDelegate {
    var onSelect: (CPTemplate) -> Void = { _ in }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        onSelect(selectedTemplate)
    }
}

/// Pilote la surface CarPlay : pile de templates, onglets, chargement, cycle de vie.
///
/// Apple n'a accordé que la catégorie « driving task » : pas de carte dessinée,
/// pas de guidage, seulement les templates Apple (onglets, listes, fiches,
/// points d'intérêt). Le délégué de scène se contente de créer et détruire ce
/// coordinateur ; toute la logique vit ici, derrière
/// `CarPlayInterfaceControlling`, pour rester testable sans véhicule ni
/// simulateur CarPlay.
@MainActor
final class CarPlayCoordinator {
    private let interface: CarPlayInterfaceControlling
    private let services: AppServices
    private let session: AuthSessionViewModel

    /// Données SOURCES des pannes et des sites prévus affichés, indexées par
    /// l'identifiant du marqueur : `MapAnnotationPayload` ne transporte ni les
    /// services touchés par une panne ni le statut d'activation d'un site prévu,
    /// et refaire un appel réseau pour réafficher ce qu'on vient de charger
    /// ferait attendre le conducteur.
    private var outagesById: [String: OutageSiteLive] = [:]
    private var plannedById: [String: PlannedSiteLive] = [:]

    private var sessionCancellable: AnyCancellable?

    /// Travaux longs à annuler à la déconnexion.
    ///
    /// Volontairement des `Task` et jamais un `Timer.scheduledTimer` : un timer
    /// reste retenu par la run loop et continuerait de tourner véhicule
    /// débranché, à réveiller le réseau pour une surface qui n'existe plus.
    ///
    /// Indexées par jeton et retirées à leur terme, plutôt qu'empilées dans un
    /// tableau : le rechargement des couches en pose une tous les 400 m et
    /// l'évaluation des alertes une tous les 500 m. Sur un long trajet, un
    /// tableau accumulait des centaines de tâches ACHEVÉES, retenues jusqu'au
    /// débranchement.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Écrans dont le contenu arrive de façon asynchrone.
    ///
    /// Chaque ouverture incrémente le jeton de son écran. Une réponse réseau qui
    /// revient après coup compare son jeton au courant : s'il a changé, elle se
    /// tait. Sans ça, ouvrir une fiche, revenir, en rouvrir une autre laissait la
    /// réponse la plus LENTE repeindre l'écran de la plus récente.
    private enum Screen: Hashable {
        case here, nearby, detail, speedtest, poi, comparison, layers
    }
    private var generations: [Screen: Int] = [:]

    /// Sérialise l'évaluation des alertes.
    ///
    /// Le verdict demande un aller-retour réseau, pendant lequel une seconde
    /// position peut déclencher une seconde évaluation. Les deux liraient le
    /// même `lastAlertAt` (encore nil) et passeraient toutes deux la politique
    /// anti-répétition, pour alerter coup sur coup — exactement ce qu'elle
    /// existe pour empêcher.
    private var isEvaluatingAlert = false

    /// Ouvre une URL hors de l'app (« Y aller » → Plans), par la scène CarPlay :
    /// c'est elle qui fait passer Plans sur l'écran du véhicule.
    private let openURL: (URL) -> Void

    init(interface: CarPlayInterfaceControlling,
         services: AppServices,
         session: AuthSessionViewModel,
         openURL: @escaping (URL) -> Void = { _ in }) {
        self.interface = interface
        self.services = services
        self.session = session
        self.openURL = openURL
    }

    func start() {
        services.setCarPlayConnected(true)
        interface.setRoot(CarPlayRootTemplateBuilder.loading(), animated: false)

        // Les alertes de couverture valent pour TOUT trajet, quel que soit
        // l'onglet affiché.
        syncCoverageAlertObserver()
        // Le réglage peut être activé en roulant : l'abonnement suit sa valeur.
        alertSettingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCoverageAlertObserver() }
        }

        // L'amorçage peut n'avoir jamais eu lieu : au branchement du véhicule,
        // iOS lance l'app en arrière-plan et la fenêtre iPhone peut ne jamais
        // apparaître. `bootstrapIfNeeded` est coalescé, donc l'appeler ici ne
        // double pas le travail si la fenêtre l'a déjà déclenché.
        track { [weak self] in
            guard let self else { return }
            await services.bootstrapIfNeeded(session: session)
            guard !Task.isCancelled else { return }
            installRoot()
            observeSessionChanges()
        }
    }

    /// Lance un travail annulable à la déconnexion, retiré du registre dès qu'il
    /// se termine.
    private func track(_ operation: @escaping () async -> Void) {
        let token = UUID()
        tasks[token] = Task { [weak self] in
            await operation()
            self?.tasks.removeValue(forKey: token)
        }
    }

    /// Ouvre un écran asynchrone et renvoie le jeton à comparer au retour.
    private func beginScreen(_ screen: Screen) -> Int {
        let next = (generations[screen] ?? 0) + 1
        generations[screen] = next
        return next
    }

    /// L'écran est-il toujours celui que l'utilisateur a ouvert ?
    private func isCurrent(_ screen: Screen, _ generation: Int) -> Bool {
        generations[screen] == generation
    }

    func stop() {
        sessionCancellable?.cancel()
        sessionCancellable = nil
        // Le speedtest tient une assertion d'arrière-plan : le laisser courir
        // véhicule débranché maintiendrait le processus éveillé pour un écran
        // qui n'existe plus.
        speedtestTask?.cancel()
        speedtestTask = nil
        speedtestTemplate = nil
        if let alertSettingObserver {
            NotificationCenter.default.removeObserver(alertSettingObserver)
            self.alertSettingObserver = nil
        }
        if let alertObserver {
            services.location.removeLocationObserver(alertObserver)
            self.alertObserver = nil
        }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        // Invalide toute réponse encore en vol : au retour, son jeton ne
        // correspondra plus et elle n'ira repeindre aucun template.
        generations.removeAll()
        hereTemplate = nil
        tabBarDelegate = nil
        hereLoadedAt = nil
        poiTemplate = nil
        poiController = nil
        lastPOICenter = nil
        anfrSnapshot = nil
        mapLayersTemplate = nil
        layerCounts.removeAll()
        layerCountsAt = nil
        layerCache.removeAll()
        outagesById.removeAll()
        plannedById.removeAll()
        services.setCarPlayConnected(false)
    }

    // MARK: - Racine

    private func installRoot() {
        guard isAuthenticated else {
            interface.setRoot(CarPlayRootTemplateBuilder.signedOut(), animated: true)
            return
        }
        installTabBar()
    }

    private func observeSessionChanges() {
        sessionCancellable?.cancel()
        // L'état porte l'utilisateur entier : un simple rafraîchissement du
        // profil (points, avatar) le change. Seule l'identité du compte doit
        // réinstaller la voiture (CAR-01).
        sessionCancellable = session.$state
            .map(CarPlayAccountKey.init)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.accountStateDidChange() }
    }

    /// Ce qui compte pour la voiture : connecté (et sous quel compte) ou non.
    enum CarPlayAccountKey: Equatable {
        case signedIn(String)
        case signedOut

        init(_ state: AuthSessionViewModel.State) {
            if case .authenticated(let user) = state { self = .signedIn(user.id) } else { self = .signedOut }
        }
    }

    private func accountStateDidChange() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        generations.removeAll()
        outagesById.removeAll()
        plannedById.removeAll()
        layerCache.removeAll()
        layerCountsAt = nil
        installRoot()
    }

    // MARK: - Racine à onglets

    private var hereTemplate: CPListTemplate?
    private var tabBarDelegate: CarPlayTabBarDelegate?
    /// Dernier remplissage de l'onglet « Ici ». L'onglet suit le trajet : il se
    /// recharge quand on y revient, au plus une fois par intervalle.
    private var hereLoadedAt: Date?
    private static let hereRefreshInterval: TimeInterval = 30
    private var poiTemplate: CPPointOfInterestTemplate?
    /// Retenu ici : `pointOfInterestDelegate` est une référence faible, un
    /// contrôleur local serait libéré avant le premier déplacement de carte.
    private var poiController: CarPlayPOIController?
    /// Couche affichée par la carte, une seule à la fois.
    private var mapLayer: CarPlayMapLayer = .antennas
    /// Centre de la dernière zone demandée par la carte ; nil tant que le
    /// conducteur ne l'a pas déplacée (la carte suit alors le véhicule).
    private var lastPOICenter: CLLocationCoordinate2D?
    /// Dernier relevé ANFR complet. Il ne change qu'une fois par semaine et
    /// couvre tout le pays : le retélécharger à chaque déplacement de carte
    /// coûterait du réseau pour un contenu identique.
    private var anfrSnapshot: (snapshot: ANFRMapSnapshot, loadedAt: Date)?
    private static let anfrSnapshotLifetime: TimeInterval = 30 * 60
    /// Racine de l'onglet Carte quand plusieurs couches existent (France) ;
    /// nil quand la carte des antennes est elle-même l'onglet.
    private var mapLayersTemplate: CPListTemplate?
    private var layerCounts: [CarPlayMapLayer: CarPlayMapLayersTemplateBuilder.Count] = [:]
    private var layerCountsAt: Date?
    private static let layerCountsInterval: TimeInterval = 120
    /// Dernier chargement de chaque couche : ouvrir une couche juste après
    /// l'avoir comptée ne refait pas le même appel réseau.
    private var layerCache: [CarPlayMapLayer: (load: POILoad, area: CLLocation, at: Date)] = [:]

    /// Pose les onglets, et se rabat sur l'ancienne liste si le système
    /// les refuse.
    ///
    /// Le repli n'est pas de la prudence gratuite : les templates autorisés
    /// dépendent de la catégorie d'entitlement, et un template non autorisé fait
    /// échouer la pose de la racine. Sans filet, l'app s'ouvrirait sur un écran
    /// vide dans le véhicule — ou pire, lèverait une exception. Le bloc de
    /// complétion ajouté au protocole permet de le détecter et de réagir.
    private func installTabBar() {
        let here = NearestAntennaTemplateBuilder.make(
            input: .init(phase: .loading, path: services.networkPath.status),
            actions: hereActions()
        )
        hereTemplate = here

        let layers = CarPlayMapLayer.available(market: MapMarketStore.initialMarketCode())
        mapLayer = .antennas
        let poi = CarPlayPOIBuilder.make(entries: [], userLocation: nil, actions: .init())
        poiTemplate = poi
        let controller = CarPlayPOIController { [weak self] region in
            self?.loadPOI(around: region.center)
        }
        poi.pointOfInterestDelegate = controller
        poiController = controller
        // Plusieurs couches (France) : l'onglet est la liste des couches, chaque
        // rangée pousse sa carte. Une seule : la carte des antennes EST l'onglet,
        // une liste d'un seul choix n'aurait pas de sens.
        let mapTab: CPTemplate
        if layers.count > 1 {
            let list = CarPlayMapLayersTemplateBuilder.make(available: layers) { [weak self] layer in
                self?.openMapLayer(layer)
            }
            mapLayersTemplate = list
            mapTab = CarPlayTabBarBuilder.decorate(list, title: String(localized: "Carte"), systemImage: "map.fill")
        } else {
            mapLayersTemplate = nil
            mapTab = poi
        }

        let speedtest = SpeedtestTemplateBuilder.make(
            state: speedtestState,
            actions: .init(start: { [weak self] in self?.runSpeedtest() })
        )
        speedtestTemplate = speedtest

        let tabs = [
            CarPlayTabBarBuilder.decorate(here, title: String(localized: "Ici"),
                                          systemImage: "dot.radiowaves.left.and.right"),
            mapTab,
            CarPlayTabBarBuilder.decorate(speedtest, title: String(localized: "Speedtest"),
                                          systemImage: "speedometer"),
        ]

        let tabBar = CarPlayTabBarBuilder.make(tabs: tabs)
        let tabDelegate = CarPlayTabBarDelegate()
        tabDelegate.onSelect = { [weak self] selected in
            guard let self else { return }
            if let here = hereTemplate, selected === here { refreshHereIfStale(here) }
            if let list = mapLayersTemplate, selected === list { refreshLayerCountsIfStale() }
            // « il y a 2 h » vieillit : on recalcule le titre au retour sur l'onglet.
            if let speedtest = speedtestTemplate, selected === speedtest { updateSpeedtest(state: speedtestState) }
        }
        tabBar.delegate = tabDelegate
        tabBarDelegate = tabDelegate

        interface.setRoot(tabBar, animated: true) { [weak self] success, _ in
            guard let self, !success else { return }
            installListRoot()
        }

        // Les onglets qui dépendent de données se remplissent en parallèle :
        // l'utilisateur peut ouvrir n'importe lequel en premier.
        loadHere(into: here)
        if mapLayersTemplate == nil { loadPOI(around: nil) }
        loadLastSpeedtest()
    }

    /// Affiche la dernière mesure connue au lieu d'un écran vide.
    ///
    /// `SpeedtestTemplateBuilder` acceptait déjà un dernier résultat et le
    /// coordinateur passait `nil` en dur : l'onglet s'ouvrait sur « Aucune
    /// mesure » alors que l'historique était sur le disque, à portée d'appel.
    private func loadLastSpeedtest() {
        track { [weak self] in
            guard let self else { return }
            let last = await services.speedtest.history().first
            guard !Task.isCancelled, last != nil else { return }
            // Ne rien écraser si une mesure a démarré entre-temps.
            guard case .idle = speedtestState else { return }
            updateSpeedtest(state: .idle(last: last))
        }
    }

    /// Ancienne racine, conservée comme filet pour les catégories
    /// d'entitlement qui n'autorisent pas les onglets.
    private func installListRoot() {
        hereTemplate = nil
        tabBarDelegate = nil
        hereLoadedAt = nil
        poiTemplate = nil
        poiController = nil
        mapLayersTemplate = nil
        speedtestTemplate = nil
        interface.setRoot(CarPlayRootTemplateBuilder.list { [weak self] entry in
            self?.open(entry)
        }, animated: false)
    }

    /// Boutons de la carte du point.
    ///
    /// - « Détails » pousse une fiche. Carte en onglet : 2 écrans, toujours
    ///   permis. Carte poussée depuis la liste des couches : 3 écrans, permis
    ///   seulement depuis iOS 26.4 ; avant, la carte du point porte déjà
    ///   distance, direction et opérateurs.
    /// - « Y aller » ouvre Plans. Une évolution ANFR n'a ni fiche ni
    ///   destination utile : c'est un changement administratif, pas un lieu.
    private func poiActions(for layer: CarPlayMapLayer) -> CarPlayPOIBuilder.Actions {
        guard layer != .changes else { return .init() }
        var actions = CarPlayPOIBuilder.Actions(navigate: { [weak self] payload in self?.navigate(to: payload) })
        if mapLayersTemplate == nil || Self.allowsThirdScreen {
            actions.details = { [weak self] payload in self?.showDetail(for: payload) }
        }
        return actions
    }

    /// Plafond de pile des apps « driving task » : 2 écrans jusqu'à iOS 26.3,
    /// 3 depuis 26.4.
    private static var allowsThirdScreen: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    private func navigate(to payload: MapAnnotationPayload) {
        guard let url = CarPlayPOIBuilder.directionsURL(to: payload.coordinate) else { return }
        openURL(url)
    }

    // MARK: - Couches de la carte

    /// Pousse la carte de la couche choisie, centrée sur le véhicule.
    private func openMapLayer(_ layer: CarPlayMapLayer) {
        guard let poiTemplate else { return }
        mapLayer = layer
        lastPOICenter = nil
        // Les points d'une autre couche ne doivent pas s'afficher sous ce nom.
        poiTemplate.title = layer.title()
        poiTemplate.setPointsOfInterest([], selectedIndex: NSNotFound)
        poiController?.invalidate()
        interface.push(poiTemplate, animated: true)
        loadPOI(around: nil)
    }

    /// Recompte les couches à l'ouverture de l'onglet, au plus toutes les deux
    /// minutes : on roule, ce qui est « autour » change.
    private func refreshLayerCountsIfStale() {
        if let layerCountsAt, Date().timeIntervalSince(layerCountsAt) < Self.layerCountsInterval { return }
        refreshLayerCounts()
    }

    private func refreshLayerCounts() {
        guard let list = mapLayersTemplate else { return }
        let market = MapMarketStore.initialMarketCode()
        let layers = CarPlayMapLayer.available(market: market)
        let generation = beginScreen(.layers)
        layerCountsAt = Date()
        layerCounts = Dictionary(uniqueKeysWithValues: layers.map { ($0, .loading) })
        repaintLayers(list, layers)
        track { [weak self] in
            guard let self else { return }
            guard let vehicle = await services.location.currentLocation(),
                  !Task.isCancelled, isCurrent(.layers, generation) else {
                // Sans position, « autour » ne veut rien dire : on retente à la
                // prochaine ouverture plutôt que d'afficher un échec.
                if isCurrent(.layers, generation) {
                    layerCountsAt = nil
                    layerCounts = [:]
                    repaintLayers(list, layers)
                }
                return
            }
            for layer in layers {
                track { [weak self] in
                    guard let self else { return }
                    let loaded = await poiLoad(for: layer, around: vehicle, market: market)
                    guard !Task.isCancelled, isCurrent(.layers, generation) else { return }
                    if let loaded {
                        let nearby = loaded.payloads.filter {
                            vehicle.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                                              longitude: $0.coordinate.longitude))
                                <= layer.countRadiusMeters
                        }
                        layerCounts[layer] = .value(nearby.count)
                    } else {
                        layerCounts[layer] = .failed
                    }
                    repaintLayers(list, layers)
                }
            }
        }
    }

    private func repaintLayers(_ list: CPListTemplate, _ layers: [CarPlayMapLayer]) {
        list.updateSections(CarPlayMapLayersTemplateBuilder.sections(
            available: layers, counts: layerCounts
        ) { [weak self] layer in self?.openMapLayer(layer) })
    }

    /// Ce qu'une couche a chargé : ses marqueurs, et les données sources que
    /// la fiche d'une panne ou d'un projet relit.
    private struct POILoad {
        var payloads: [MapAnnotationPayload]
        var snapshotDate: String?
        var outages: [String: OutageSiteLive] = [:]
        var planned: [String: PlannedSiteLive] = [:]
    }

    /// Charge la couche affichée autour d'un point et repeint la carte à onglets.
    ///
    /// - Parameter center: centre de la carte déplacée ; nil = position du
    ///   véhicule.
    private func loadPOI(around center: CLLocationCoordinate2D?) {
        guard let poiTemplate else { return }
        let generation = beginScreen(.poi)
        let market = MapMarketStore.initialMarketCode()
        // Le pays a pu changer depuis le choix : une couche absente devient vide
        // pour toujours, on revient aux antennes.
        if !CarPlayMapLayer.available(market: market).contains(mapLayer) { mapLayer = .antennas }
        let layer = mapLayer
        if let center { lastPOICenter = center }
        track { [weak self] in
            guard let self else { return }
            let area: CLLocation?
            if let center {
                area = CLLocation(latitude: center.latitude, longitude: center.longitude)
            } else {
                area = await services.location.currentLocation()
            }
            guard !Task.isCancelled, isCurrent(.poi, generation) else { return }
            guard let area else {
                poiTemplate.setPointsOfInterest([], selectedIndex: NSNotFound)
                return
            }
            // Le prochain déplacement de carte compte à partir de ce chargement.
            poiController?.noteLoaded(center: area.coordinate)

            let loaded = await poiLoad(for: layer, around: area, market: market)
            guard !Task.isCancelled, isCurrent(.poi, generation) else { return }
            // Échec ≠ vide : on le dit, avec un bouton pour recommencer.
            guard let loaded else {
                poiTemplate.title = layer.title()
                poiTemplate.setPointsOfInterest(
                    [CarPlayPOIBuilder.failurePoint(at: area.coordinate) { [weak self] in self?.loadPOI(around: center) }],
                    selectedIndex: NSNotFound
                )
                return
            }

            let update = {
                // La distance affichée part du VÉHICULE, même carte déplacée :
                // « 3 km » doit dire à quelle distance on est.
                let vehicle = center == nil ? area : self.services.location.cachedLocation()
                let entries = CarPlayPOIBuilder.entries(from: loaded.payloads, userLocation: vehicle, around: area)
                self.outagesById = loaded.outages
                self.plannedById = loaded.planned
                // Un template de points d'intérêt n'a pas de vue vide : le titre
                // dit qu'il n'y a rien, plutôt qu'une carte muette.
                poiTemplate.title = entries.isEmpty ? layer.emptyTitle : layer.title(snapshotDate: loaded.snapshotDate)
                poiTemplate.setPointsOfInterest(
                    CarPlayPOIBuilder.points(from: entries, userLocation: vehicle,
                                             actions: self.poiActions(for: layer)),
                    selectedIndex: NSNotFound
                )
            }
            // Un centre choisi sur la carte reste une intention manuelle ; seul
            // le point GPS doit encore être autorisé et frais après le réseau.
            if center != nil { update() }
            else if !CarPlayLocationRenderGate.commit(area, service: services.location, update: update) {
                poiTemplate.setPointsOfInterest([], selectedIndex: NSNotFound)
            }
        }
    }

    /// Données d'une couche autour d'un point ; nil si le serveur n'a pas répondu.
    ///
    /// Pannes, projets et relevé ANFR arrivent pour tout le pays : les
    /// convertisseurs les bornent au rayon de la carte.
    private func poiLoad(for layer: CarPlayMapLayer, around area: CLLocation, market: String) async -> POILoad? {
        if let cached = layerCache[layer], Date().timeIntervalSince(cached.at) < Self.layerCountsInterval,
           cached.area.distance(from: area) < 1_000 {
            return cached.load
        }
        let loaded = await fetchPOILoad(for: layer, around: area, market: market)
        if let loaded { layerCache[layer] = (loaded, area, Date()) }
        return loaded
    }

    private func fetchPOILoad(for layer: CarPlayMapLayer, around area: CLLocation, market: String) async -> POILoad? {
        let operatorKey = MapMarketStore.initialOperatorKey()
        switch layer {
        case .antennas:
            let coordinate = area.coordinate
            let delta = 0.045
            guard let sites = try? await services.antennas.list(
                bbox: BoundingBox(north: coordinate.latitude + delta,
                                  south: coordinate.latitude - delta,
                                  east: coordinate.longitude + delta,
                                  west: coordinate.longitude - delta),
                market: market,
                operatorName: operatorKey,
                technologies: []
            ) else { return nil }
            return POILoad(payloads: sites.compactMap { Self.payload(for: $0) })
        case .outages:
            guard let sites = try? await services.map.outageSites(
                market: market, operatorName: operatorKey, territory: nil, bands: []
            ) else { return nil }
            let payloads = CarPlayMapLayerPoints.outages(sites, around: area)
            let shown = Set(payloads.map(\.id))
            return POILoad(payloads: payloads, outages: Dictionary(
                sites.map { (CarPlayMapLayerPoints.outageId($0), $0) }.filter { shown.contains($0.0) },
                uniquingKeysWith: { first, _ in first }
            ))
        case .planned:
            guard let sites = try? await services.map.plannedSites(
                market: market, operatorName: operatorKey, territory: nil, bands: []
            ) else { return nil }
            let payloads = CarPlayMapLayerPoints.planned(sites, around: area)
            let shown = Set(payloads.map(\.id))
            return POILoad(payloads: payloads, planned: Dictionary(
                sites.map { (CarPlayMapLayerPoints.plannedId($0), $0) }.filter { shown.contains($0.0) },
                uniquingKeysWith: { first, _ in first }
            ))
        case .changes:
            guard let snapshot = await latestANFRSnapshot() else { return nil }
            return POILoad(payloads: CarPlayMapLayerPoints.changes(snapshot.sites, around: area),
                           snapshotDate: snapshot.snapshotDate)
        }
    }

    /// Dernier relevé ANFR, gardé une demi-heure ; l'ancien reste servi si le
    /// réseau tombe, plutôt qu'une carte en échec.
    private func latestANFRSnapshot() async -> ANFRMapSnapshot? {
        if let cached = anfrSnapshot, Date().timeIntervalSince(cached.loadedAt) < Self.anfrSnapshotLifetime {
            return cached.snapshot
        }
        guard let snapshot = try? await services.anfr.mapSnapshot(date: nil) else { return anfrSnapshot?.snapshot }
        anfrSnapshot = (snapshot, Date())
        return snapshot
    }

    /// Ouvre une entrée de la racine en mode liste.
    private func open(_ entry: CarPlayRootTemplateBuilder.Entry) {
        switch entry {
        case .nearby: showNearby()
        case .here: showHere()
        case .speedtest: showSpeedtest()
        }
    }

    private var isAuthenticated: Bool {
        if case .authenticated = session.state { return true }
        return false
    }

    // MARK: - Alertes « zone mal couverte »

    private var lastAlertAt: Date?
    private var lastAlertCoordinate: CLLocationCoordinate2D?
    private var lastAlertCheckCoordinate: CLLocationCoordinate2D?
    /// Abonnement aux positions, posé seulement quand les alertes sont actives :
    /// suivre la position sans raison coûte de la batterie et de la vie privée.
    private var alertObserver: UUID?
    private var alertSettingObserver: NSObjectProtocol?

    /// Pose ou retire l'abonnement aux positions selon le réglage des alertes.
    private func syncCoverageAlertObserver() {
        if CarPlayAlertSettings.coverageAlertsEnabled {
            guard alertObserver == nil else { return }
            alertObserver = services.location.addLocationObserver(scope: .session) { [weak self] location in
                self?.evaluateCoverageAlert(at: location)
            }
        } else if let alertObserver {
            services.location.removeLocationObserver(alertObserver)
            self.alertObserver = nil
        }
    }

    /// Réévalue la couverture au fil du trajet et alerte si la zone traversée
    /// est mauvaise.
    ///
    /// Appelé depuis le suivi de position, donc potentiellement à chaque
    /// seconde : on ne relance l'évaluation que tous les ~500 m, sinon on
    /// interrogerait le service en continu pour un verdict qui ne change pas
    /// d'un lampadaire à l'autre.
    private func evaluateCoverageAlert(at location: CLLocation) {
        guard CarPlayAlertSettings.coverageAlertsEnabled else { return }
        // Une seule évaluation à la fois : voir `isEvaluatingAlert`.
        guard !isEvaluatingAlert else { return }
        if let last = lastAlertCheckCoordinate {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: location)
            guard moved >= 500 else { return }
        }
        lastAlertCheckCoordinate = location.coordinate
        isEvaluatingAlert = true

        track { [weak self] in
            guard let self else { return }
            defer { isEvaluatingAlert = false }
            let path = services.networkPath.status
            let verdict = await services.nearbyQuality.verdict(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                isCellular: path.connection == .cellular,
                simPlmn: services.networkPath.simPLMN().plmn,
                maxAge: nil
            )
            guard !Task.isCancelled, let verdict else { return }

            let context = CarPlayAlertPolicy.Context(
                isEnabled: true,
                verdict: verdict.level,
                sampleCount: verdict.sampleCount,
                speed: max(location.speed, 0),
                coordinate: location.coordinate,
                lastAlertAt: lastAlertAt,
                lastAlertCoordinate: lastAlertCoordinate,
                now: Date()
            )
            guard CarPlayAlertPolicy.shouldAlert(context) else { return }

            lastAlertAt = context.now
            lastAlertCoordinate = location.coordinate
            presentCoverageAlert(
                CarPlayAlertPolicy.message(for: verdict.level, operatorLabel: verdict.operatorLabel)
            )
        }
    }

    /// Alerte affichée dans le véhicule si notre scène est au premier plan,
    /// sinon déposée en notification locale.
    ///
    /// Les deux chemins sont EXCLUSIFS : émettre les deux ferait recevoir
    /// l'alerte en double. Et le second est indispensable — l'écran du véhicule
    /// affiche le plus souvent Plan ou la musique, pas SignalQuest ; sans lui,
    /// l'alerte n'existerait quasiment jamais.
    private func presentCoverageAlert(_ message: String) {
        guard isSceneForeground else {
            postCoverageNotification(message)
            return
        }
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                self?.interface.dismiss(animated: true)
            }]
        )
        interface.present(alert, animated: true)
    }

    /// Notre scène CarPlay est-elle au premier plan de l'écran du véhicule ?
    private var isSceneForeground: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene is CPTemplateApplicationScene && scene.activationState == .foregroundActive
        }
    }

    /// Notification locale. Elle n'atteindra l'écran du véhicule que grâce à la
    /// catégorie `.allowInCarPlay` : sans elle, iOS l'afficherait sur l'iPhone
    /// et s'arrêterait là.
    private func postCoverageNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Réseau faible")
        content.body = message
        content.categoryIdentifier = CarPlayNotificationCategories.coverageAlert
        // Déclenchement immédiat : l'information porte sur l'endroit où l'on est
        // MAINTENANT, elle n'a plus de sens dans une minute.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            // Sans cette trace, une notification refusée (autorisation retirée,
            // quota) laissait croire que l'alerte avait été émise.
            guard let error else { return }
            CarPlayNavigationLog.record("notification", target: "couverture",
                                        success: false, error: error)
        }
    }

    /// Écran « Ici » : ce que vaut le réseau à cet endroit, et quelle antenne le
    /// dessert.
    ///
    /// Poussé IMMÉDIATEMENT avec ce que l'on sait sans réseau (l'opérateur et la
    /// techno en cours), puis complété. Les deux appels — antennes autour et
    /// verdict de couverture — prennent chacun le temps d'un aller-retour, et
    /// attendre les deux laisserait le conducteur devant un écran vide après
    /// avoir pressé un bouton.
    private func showHere() {
        let template = NearestAntennaTemplateBuilder.make(
            input: .init(phase: .loading, path: services.networkPath.status),
            actions: hereActions()
        )
        interface.push(template, animated: true)
        loadHere(into: template)
    }

    /// Ce que chaque rangée de « Ici » ouvre, un niveau plus bas — le seul
    /// disponible sous un onglet en catégorie « driving task ».
    private func hereActions() -> NearestAntennaTemplateBuilder.Actions {
        .init(
            showQuality: { [weak self] quality in
                self?.interface.push(NearestAntennaTemplateBuilder.qualityDetail(quality), animated: true)
            },
            showAntenna: { [weak self] site in
                guard let payload = Self.payload(for: site) else { return }
                self?.showAntennaDetail(for: payload)
            },
            compareOperators: { [weak self] in self?.showOperatorComparison() }
        )
    }

    /// Remplit l'écran « Ici ». Séparé de `showHere` pour que l'ONGLET puisse
    /// s'alimenter sans rien empiler : en mode onglets, cet écran est la racine.
    private func loadHere(into template: CPListTemplate) {
        hereLoadedAt = Date()
        let generation = beginScreen(.here)
        track { [weak self] in
            guard let self else { return }
            // `currentLocation()` et non `lastLocation` : au branchement du
            // véhicule, iOS lance l'app EN ARRIÈRE-PLAN et aucun fix n'a encore
            // été pris. L'ancien `guard lastLocation else { return }` laissait
            // donc l'écran phare figé sur une seule ligne, sans message ni
            // reprise — précisément dans le cas nominal.
            let location = await services.location.currentLocation()
            guard !Task.isCancelled, isCurrent(.here, generation) else { return }
            guard let location else {
                showHereWithoutLocation(into: template)
                return
            }
            let input = await hereInput(at: location)
            guard !Task.isCancelled, isCurrent(.here, generation) else { return }
            let didRender = CarPlayLocationRenderGate.commit(location, service: services.location) {
                // Mise à jour EN PLACE, comme pour les fiches : re-pousser empilerait
                // deux écrans identiques.
                template.updateSections(NearestAntennaTemplateBuilder.sections(for: input, actions: hereActions()))
            }
            if !didRender {
                showHereWithoutLocation(into: template)
            }
        }
    }

    private func refreshHereIfStale(_ template: CPListTemplate) {
        if let hereLoadedAt, Date().timeIntervalSince(hereLoadedAt) < Self.hereRefreshInterval { return }
        loadHere(into: template)
    }

    private func showHereWithoutLocation(into template: CPListTemplate) {
        template.updateSections(NearestAntennaTemplateBuilder.sections(
            for: .init(phase: .withoutLocation, path: services.networkPath.status),
            actions: hereActions()
        ))
    }

    /// Classement des opérateurs à l'endroit où l'on se trouve.
    ///
    /// Un seul niveau de pile depuis « Ici », donc compatible avec le plafond de
    /// la catégorie « driving task ».
    private func showOperatorComparison() {
        let template = OperatorComparisonTemplateBuilder.make(stats: [], metric: .download)
        CarPlayListPlaceholder.applyLoading(to: template)
        interface.push(template, animated: true)
        loadOperatorComparison(into: template)
    }

    private func loadOperatorComparison(into template: CPListTemplate) {
        let generation = beginScreen(.comparison)
        track { [weak self] in
            guard let self else { return }
            guard let location = await services.location.currentLocation() else {
                guard isCurrent(.comparison, generation) else { return }
                CarPlayListPlaceholder.applyEmpty(
                    to: template,
                    title: String(localized: "Position inconnue"),
                    subtitle: String(localized: "SignalQuest n'a pas accès à ta position pour l'instant.")
                )
                return
            }
            let stats = await services.nearbyQuality.operatorRanking(
                metric: .download,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                maxAge: nil
            )
            guard !Task.isCancelled, isCurrent(.comparison, generation) else { return }
            let didRender = CarPlayLocationRenderGate.commit(location, service: services.location) {
                if stats.isEmpty {
                    CarPlayListPlaceholder.applyEmpty(
                        to: template,
                        title: String(localized: "Pas assez de mesures"),
                        subtitle: String(localized: "La communauté n'a pas encore assez mesuré cette zone.")
                    )
                } else {
                    template.updateSections([
                        CPListSection(items: OperatorComparisonTemplateBuilder.items(for: stats, metric: .download))
                    ])
                }
            }
            if !didRender {
                CarPlayListPlaceholder.applyEmpty(
                    to: template,
                    title: String(localized: "Position inconnue"),
                    subtitle: String(localized: "SignalQuest n'a pas accès à ta position pour l'instant.")
                )
            }
        }
    }

    /// Rassemble les données de l'écran « Ici ». Les deux requêtes partent EN
    /// PARALLÈLE : elles sont indépendantes, les enchaîner doublerait l'attente.
    private func hereInput(at location: CLLocation) async -> NearestAntennaTemplateBuilder.Input {
        let coordinate = location.coordinate
        let path = services.networkPath.status

        // ~5 km de côté, comme le drive test : au-delà, l'antenne « la plus
        // proche » n'explique plus rien de ce qu'on capte ici.
        let delta = 0.045
        async let antennas = try? services.antennas.list(
            bbox: BoundingBox(north: coordinate.latitude + delta,
                              south: coordinate.latitude - delta,
                              east: coordinate.longitude + delta,
                              west: coordinate.longitude - delta),
            market: MapMarketStore.initialMarketCode(),
            operatorName: MapMarketStore.initialOperatorKey(),
            technologies: []
        )
        async let quality = services.nearbyQuality.verdict(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            isCellular: path.connection == .cellular,
            simPlmn: services.networkPath.simPLMN().plmn,
            maxAge: nil
        )

        var input = NearestAntennaTemplateBuilder.Input(path: path, quality: await quality)
        // `nil` = requête échouée, à distinguer d'une zone réellement vide.
        guard let sites = await antennas else {
            input.antennasUnavailable = true
            return input
        }
        guard let nearest = AntennaSectorGeometry.nearest(to: coordinate, among: sites) else {
            return input
        }
        input.nearestSite = nearest.site
        input.nearestDistanceMeters = nearest.distanceMeters
        if let lat = nearest.site.latitude, let lon = nearest.site.longitude {
            let antennaCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            input.bearingDegrees = AntennaSectorGeometry.bearing(from: coordinate, to: antennaCoordinate)
            input.isInSector = AntennaSectorGeometry.bestSector(
                antenna: antennaCoordinate,
                azimuths: nearest.site.azimuths,
                user: coordinate
            )?.inSector
        }
        return input
    }

    // MARK: - Fiches

    /// Ouvre la fiche correspondant au marqueur touché.
    ///
    /// La fiche est poussée IMMÉDIATEMENT avec ce que la carte sait déjà, puis
    /// enrichie quand le serveur répond : attendre le réseau laisserait le
    /// conducteur devant un écran inchangé, sans savoir si son geste a été pris
    /// en compte.
    private func showDetail(for payload: MapAnnotationPayload) {
        // Un cluster n'a pas de fiche.
        if let count = payload.clusterCount, count > 0 { return }

        switch payload.kind {
        case .outage:
            guard let site = outagesById[payload.id] else { return }
            interface.push(CarPlayDetailTemplateBuilder.outage(
                site, userLocation: services.location.cachedLocation(), actions: .init()
            ), animated: true)
        case .planned:
            guard let site = plannedById[payload.id] else { return }
            interface.push(CarPlayDetailTemplateBuilder.planned(
                site, userLocation: services.location.cachedLocation(), actions: .init()
            ), animated: true)
        default:
            showAntennaDetail(for: payload)
        }
    }

    private func showAntennaDetail(for payload: MapAnnotationPayload) {
        let actions = CarPlayDetailTemplateBuilder.Actions()
        let template = CarPlayDetailTemplateBuilder.antenna(
            payload: payload, details: nil,
            userLocation: services.location.cachedLocation(), actions: actions
        )
        interface.push(template, animated: true)

        guard let antennaId = payload.antennaId else { return }
        let generation = beginScreen(.detail)
        track { [weak self] in
            guard let self else { return }
            let details = try? await services.antennas.details(
                id: antennaId,
                market: MapMarketStore.initialMarketCode(),
                operatorName: MapMarketStore.initialOperatorKey(),
                anfrCode: payload.backendId
            )
            // Le jeton évite qu'une réponse lente pour une fiche refermée ne
            // vienne repeindre celle qui est affichée à sa place.
            guard !Task.isCancelled, isCurrent(.detail, generation), let details else { return }
            // Le template est mis à jour EN PLACE : re-pousser empilerait deux
            // fiches identiques, et le bouton retour ramènerait sur la première.
            let enriched = CarPlayDetailTemplateBuilder.antenna(
                payload: payload, details: details,
                userLocation: services.location.cachedLocation(), actions: actions
            )
            template.items = enriched.items
            template.actions = enriched.actions
        }
    }

    // MARK: - Speedtest

    private var speedtestTemplate: CPInformationTemplate?
    private var speedtestState = SpeedtestTemplateBuilder.State.idle(last: nil)
    private var speedtestTask: Task<Void, Never>?
    private var speedtestThrottle = SpeedtestRefreshThrottle()

    private func showSpeedtest() {
        let template = SpeedtestTemplateBuilder.make(
            state: speedtestState,
            actions: .init(start: { [weak self] in self?.runSpeedtest() })
        )
        speedtestTemplate = template
        interface.push(template, animated: true)
    }

    private func runSpeedtest() {
        // Un seul test à la fois : deux mesures concurrentes se partageraient la
        // bande passante et se fausseraient l'une l'autre.
        guard speedtestTask == nil else { return }
        // Un Drive Test mesure déjà : un second test fausserait les deux (MES-18).
        guard !services.driveTest.isRunning else {
            updateSpeedtest(state: .failed(String(localized: "Un Drive Test est en cours sur l’iPhone : il mesure déjà le réseau.")))
            return
        }
        // Un test lancé sur l'iPhone mesure déjà (CAR-05).
        guard !services.speedtest.isRunning else {
            updateSpeedtest(state: .failed(SpeedtestBusyError.alreadyRunning.errorDescription ?? ""))
            return
        }
        updateSpeedtest(state: .running(SpeedtestLiveProgress(phase: .idle)))

        speedtestTask = Task { [weak self] in
            guard let self else { return }
            // Le test dure une dizaine de secondes, pendant lesquelles l'iPhone
            // peut se verrouiller : sans cette assertion, iOS suspendrait le
            // processus au milieu de la mesure.
            let scope = BackgroundTaskScope()
            scope.begin(name: "carplay-speedtest")
            defer {
                scope.end()
                speedtestTask = nil
            }

            let location = await services.location.currentLocation()
            let coordinates = location.map {
                Coordinates(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
            do {
                let result = try await services.speedtest.run(
                    pathStatus: services.networkPath.status,
                    location: coordinates,
                    settings: .androidDefault,
                    progress: { progress in
                        // Le handler est `@Sendable` et peut être appelé hors du
                        // main actor : on repasse explicitement dessus.
                        Task { @MainActor [weak self] in
                            self?.handleSpeedtestProgress(progress)
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                updateSpeedtest(state: .finished(result))
                // Même intention que dans l’app : publication exacte demandée.
                // Le service garde le VPN privé ; le serveur applique les zones
                // privées et l’éligibilité du réseau.
                do {
                    try await services.speedtest.save(
                        result,
                        streams: SpeedtestRunSettings.androidDefault.streams,
                        publishToMap: true,
                        shareExactLocation: true
                    )
                } catch {
                    // Le résultat reste affiché, mais on ne laisse pas croire qu'il est sauvegardé.
                    guard !Task.isCancelled, case .finished = speedtestState else { return }
                    updateSpeedtest(state: .finishedUnsaved(result))
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateSpeedtest(state: .failed(error.userFacingMessage))
            }
        }
    }

    private func handleSpeedtestProgress(_ progress: SpeedtestLiveProgress) {
        let phaseChanged: Bool
        if case .running(let previous) = speedtestState {
            phaseChanged = previous.phase != progress.phase
        } else {
            phaseChanged = true
        }
        guard speedtestThrottle.shouldEmit(now: Date(), phaseChanged: phaseChanged) else {
            // On garde l'état même sans l'afficher, pour que la prochaine
            // émission compare la bonne phase.
            speedtestState = .running(progress)
            return
        }
        updateSpeedtest(state: .running(progress))
    }

    private func updateSpeedtest(state: SpeedtestTemplateBuilder.State) {
        speedtestState = state
        guard let speedtestTemplate else { return }
        // Mise à jour EN PLACE : re-pousser empilerait un écran par
        // rafraîchissement, soit une vingtaine par test.
        let refreshed = SpeedtestTemplateBuilder.make(
            state: state,
            actions: .init(start: { [weak self] in self?.runSpeedtest() })
        )
        speedtestTemplate.title = refreshed.title
        speedtestTemplate.items = refreshed.items
        speedtestTemplate.actions = refreshed.actions
    }

    /// Liste « Antennes autour » de la racine de repli. Elle part vide, et ce
    /// vide est un CHARGEMENT — pas une absence de sites.
    private func showNearby() {
        let template = NearbyListTemplateBuilder.make(entries: []) { [weak self] payload in
            self?.showDetail(for: payload)
        }
        CarPlayListPlaceholder.applyLoading(to: template)
        interface.push(template, animated: true)
        loadNearby(into: template)
    }

    /// Charge les sites autour de la position. Extrait de `showNearby` pour que
    /// « Réessayer » relance sans réempiler d'écran.
    private func loadNearby(into template: CPListTemplate) {
        let generation = beginScreen(.nearby)
        track { [weak self] in
            guard let self else { return }
            // Même raison qu'à l'écran « Ici » : au branchement du véhicule il
            // n'existe encore aucun fix, et se contenter de `lastLocation`
            // laissait la liste éternellement vide.
            guard let location = await services.location.currentLocation() else {
                guard isCurrent(.nearby, generation) else { return }
                CarPlayListPlaceholder.applyEmpty(
                    to: template,
                    title: String(localized: "Position inconnue"),
                    subtitle: String(localized: "SignalQuest n'a pas accès à ta position pour l'instant.")
                )
                return
            }
            guard !Task.isCancelled, isCurrent(.nearby, generation) else { return }

            let coordinate = location.coordinate
            let delta = 0.045
            do {
                let sites = try await services.antennas.list(
                    bbox: BoundingBox(north: coordinate.latitude + delta,
                                      south: coordinate.latitude - delta,
                                      east: coordinate.longitude + delta,
                                      west: coordinate.longitude - delta),
                    market: MapMarketStore.initialMarketCode(),
                    operatorName: MapMarketStore.initialOperatorKey(),
                    technologies: []
                )
                guard !Task.isCancelled, isCurrent(.nearby, generation) else { return }
                let payloads = sites.compactMap { Self.payload(for: $0) }
                let entries = NearbyListTemplateBuilder.entries(from: payloads, userLocation: location)
                guard !entries.isEmpty else {
                    CarPlayListPlaceholder.applyEmpty(
                        to: template,
                        title: String(localized: "Rien à proximité"),
                        subtitle: String(localized: "Aucun site connu dans un rayon de 5 km.")
                    )
                    return
                }
                let filled = NearbyListTemplateBuilder.make(entries: entries) { [weak self] payload in
                    self?.showDetail(for: payload)
                }
                // `updateSections` plutôt qu'un push : l'écran vide et l'écran rempli
                // sont le même, pas deux étapes de navigation.
                template.updateSections(filled.sections)
            } catch {
                guard !Task.isCancelled, isCurrent(.nearby, generation) else { return }
                CarPlayListPlaceholder.applyFailure(to: template) { [weak self] in
                    CarPlayListPlaceholder.applyLoading(to: template)
                    self?.loadNearby(into: template)
                }
            }
        }
    }

    /// Convertit un site de la liste `/api/antennas` en marqueur, pour que les
    /// fiches reçoivent la même forme qu'en mode carte.
    private static func payload(for site: AntennaSite) -> MapAnnotationPayload? {
        guard let lat = site.latitude, let lon = site.longitude else { return nil }
        return MapAnnotationPayload(
            id: "antenna-\(site.id)",
            kind: .antenna,
            title: String(localized: "Site \(site.siteId ?? site.id)"),
            // « Opérateurs · générations », noms complets : la carte en tire
            // ses textes (noms courts dans sa liste étroite), la fiche son
            // sous-titre.
            subtitle: [NearestAntennaTemplateBuilder.operatorNames(site.operators),
                       NearestAntennaTemplateBuilder.generations(site.technologies)]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            metric: nil,
            backendId: site.siteId ?? site.id,
            details: nil,
            antennaId: site.id,
            clusterCount: nil,
            azimuths: site.azimuths,
            showsAzimuths: false,
            tint: SQBrand.operatorColor(site.operators.first),
            // Le point de la carte iPhone : une part par opérateur, anneau 5G.
            has5G: site.technologies.contains { SQQualityScale.Generation(technology: $0) == .fiveG },
            operatorTints: site.operators.prefix(4).map { SQBrand.operatorColor($0) }
        )
    }
}
