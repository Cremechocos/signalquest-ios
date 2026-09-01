import CarPlay
import Combine
import CoreLocation
import MapKit

/// Pilote la surface CarPlay : pile de templates, carte, chargement, cycle de vie.
///
/// Le délégué de scène se contente de le créer et de le détruire ; toute la
/// logique vit ici, derrière `CarPlayInterfaceControlling`, pour rester
/// testable sans véhicule ni simulateur CarPlay.
@MainActor
final class CarPlayCoordinator {
    private let interface: CarPlayInterfaceControlling
    private let services: AppServices
    private let session: AuthSessionViewModel

    /// Non nul en catégorie navigation (`carplay-maps`) : la fenêtre du véhicule
    /// dans laquelle on installe notre `MKMapView`. Nil en repli « liste », où
    /// l'on ne dispose que des templates.
    private let carWindow: CPWindow?

    private var mapController: CarPlayMapController?
    private let layers: CarPlayLayerController

    /// Dernier chargement, conservé pour deux usages : alimenter la liste
    /// « Autour de toi », et retrouver la donnée SOURCE d'un marqueur. Les
    /// pannes et les évolutions portent des champs (services touchés, statut
    /// d'activation) que `MapAnnotationPayload` ne transporte pas — sans ça, il
    /// faudrait refaire un appel réseau pour afficher ce qu'on vient de charger.
    private var loadedLayers = CarPlayLayerController.Layers()
    private var outagesById: [String: OutageSiteLive] = [:]
    private var plannedById: [String: PlannedSiteLive] = [:]

    // MARK: Guidage
    private let routeService = CarPlayRouteService()
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var tracker: RouteProgressTracker?
    private var currentPlan: RoutePlan?
    private var destination: CLLocationCoordinate2D?
    /// Dernière progression observée, réutilisée par les alertes pour savoir si
    /// une manœuvre est imminente.
    private var lastProgress: RouteProgress?
    private var voiceGuide: CarPlayVoiceGuide?
    /// Retenu ici : `CPSearchTemplate.delegate` est faible, un contrôleur local
    /// serait libéré avant la première frappe.
    private var searchController: CarPlaySearchController?
    /// Conservées pour recomposer la barre : « Arrêter » n'apparaît que pendant
    /// un guidage, donc les boutons changent en cours de route.
    private var mapActions: CarPlayMapTemplateBuilder.Actions?
    /// Jeton d'abonnement aux positions, à relâcher en fin de guidage : sans
    /// cela, le suivi continuerait à alimenter un guidage terminé.
    private var locationObserver: UUID?
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
        case here, nearby, sentinelle, detail, speedtest, poi, comparison
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

    /// Centre de la dernière requête de tuiles, pour ne pas recharger à chaque
    /// micro-déplacement. Le seuil vient du drive test, où il est éprouvé.
    private var lastLoadedCenter: CLLocationCoordinate2D?
    private static let reloadDistanceMeters: CLLocationDistance = 400

    /// Zoom fixé en conduite : la carte se lit d'un coup d'œil ou pas du tout.
    /// À ce niveau le clustering serveur suffit, donc pas besoin du regroupement
    /// client de `MapExplorerView`.
    private static let drivingZoom: Double = 14

    var isShowingMap: Bool { carWindow != nil }

    init(interface: CarPlayInterfaceControlling,
         services: AppServices,
         session: AuthSessionViewModel,
         carWindow: CPWindow?) {
        self.interface = interface
        self.services = services
        self.session = session
        self.carWindow = carWindow
        self.layers = CarPlayLayerController(map: services.map)
    }

    func start() {
        services.setCarPlayConnected(true, canGuide: isShowingMap)
        interface.setRoot(CarPlayRootTemplateBuilder.loading(), animated: false)

        // Les alertes de couverture valent pour TOUT trajet. Elles étaient
        // posées dans `installMap`, donc jamais en mode liste — c'est-à-dire
        // jamais du tout avec la catégorie « driving task » réellement accordée.
        // Le réglage était visible dans l'app et sans le moindre effet.
        if CarPlayAlertSettings.coverageAlertsEnabled {
            alertObserver = services.location.addLocationObserver { [weak self] location in
                self?.evaluateCoverageAlert(at: location)
            }
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
        // Le guidage d'abord : il détient un abonnement aux positions et une
        // session de navigation, qui survivraient au débranchement du véhicule.
        endGuidance(finished: false)
        // Le speedtest tient une assertion d'arrière-plan : le laisser courir
        // véhicule débranché maintiendrait le processus éveillé pour un écran
        // qui n'existe plus.
        speedtestTask?.cancel()
        speedtestTask = nil
        speedtestTemplate = nil
        if let alertObserver {
            services.location.removeLocationObserver(alertObserver)
            self.alertObserver = nil
        }
        CarPlayDashboardRoute.setListener(nil)
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        // Invalide toute réponse encore en vol : au retour, son jeton ne
        // correspondra plus et elle n'ira repeindre aucun template.
        generations.removeAll()
        searchController = nil
        layersTemplate = nil
        hereTemplate = nil
        poiTemplate = nil
        poiController = nil
        sentinelleTemplate = nil
        mapActions = nil
        lastProgress = nil
        loadedLayers = CarPlayLayerController.Layers()
        outagesById.removeAll()
        plannedById.removeAll()
        mapController = nil
        mapTemplate = nil
        services.setCarPlayConnected(false)
    }

    // MARK: - Racine

    private func installRoot() {
        guard isAuthenticated else {
            interface.setRoot(CarPlayRootTemplateBuilder.signedOut(), animated: true)
            return
        }
        guard let carWindow else {
            // Sans carte plein écran, la surface à onglets EST l'application.
            installTabBar()
            observeDashboardRoute()
            return
        }
        installMap(in: carWindow)
        observeDashboardRoute()
    }

    private func observeSessionChanges() {
        sessionCancellable?.cancel()
        sessionCancellable = session.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.accountStateDidChange() }
    }

    private func accountStateDidChange() {
        endGuidance(finished: false)
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        generations.removeAll()
        loadedLayers = CarPlayLayerController.Layers()
        outagesById.removeAll()
        plannedById.removeAll()
        installRoot()
    }

    // MARK: - Racine à onglets

    private var hereTemplate: CPInformationTemplate?
    private var poiTemplate: CPPointOfInterestTemplate?
    private var sentinelleTemplate: CPListTemplate?
    /// Retenu ici : `pointOfInterestDelegate` est une référence faible, un
    /// contrôleur local serait libéré avant le premier déplacement de carte.
    private var poiController: CarPlayPOIController?

    /// Pose les quatre onglets, et se rabat sur l'ancienne liste si le système
    /// les refuse.
    ///
    /// Le repli n'est pas de la prudence gratuite : les templates autorisés
    /// dépendent de la catégorie d'entitlement, et un template non autorisé fait
    /// échouer la pose de la racine. Sans filet, l'app s'ouvrirait sur un écran
    /// vide dans le véhicule — ou pire, lèverait une exception. Le bloc de
    /// complétion ajouté au protocole permet de le détecter et de réagir.
    private func installTabBar() {
        let here = NearestAntennaTemplateBuilder.make(
            input: .init(path: services.networkPath.status, quality: nil),
            actions: .init()
        )
        hereTemplate = here

        let poi = CarPlayPOIBuilder.make(entries: [], userLocation: nil, actions: poiActions())
        poiTemplate = poi
        let controller = CarPlayPOIController { [weak self] region in
            self?.loadPOI(around: region.center)
        }
        poi.pointOfInterestDelegate = controller
        poiController = controller

        let speedtest = SpeedtestTemplateBuilder.make(
            state: speedtestState,
            actions: .init(start: { [weak self] in self?.runSpeedtest() })
        )
        speedtestTemplate = speedtest

        let sentinelle = SentinelleTemplateBuilder.list(targets: []) { _ in }
        CarPlayListPlaceholder.applyLoading(to: sentinelle)
        sentinelleTemplate = sentinelle

        let tabs = [
            CarPlayTabBarBuilder.decorate(here, title: String(localized: "Ici"),
                                          systemImage: "dot.radiowaves.left.and.right"),
            poi,
            CarPlayTabBarBuilder.decorate(speedtest, title: String(localized: "Débit"),
                                          systemImage: "speedometer"),
            CarPlayTabBarBuilder.decorate(sentinelle, title: String(localized: "Sentinelle"),
                                          systemImage: "wifi.router.fill"),
        ]

        interface.setRoot(CarPlayTabBarBuilder.make(tabs: tabs), animated: true) { [weak self] success, _ in
            guard let self, !success else { return }
            installListRoot()
        }

        // Les onglets qui dépendent de données se remplissent en parallèle :
        // l'utilisateur peut ouvrir n'importe lequel en premier.
        loadHere(into: here)
        loadPOI(around: nil)
        loadSentinelle(into: sentinelle)
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
        poiTemplate = nil
        poiController = nil
        sentinelleTemplate = nil
        speedtestTemplate = nil
        interface.setRoot(CarPlayRootTemplateBuilder.list { [weak self] entry in
            self?.open(entry)
        }, animated: false)
    }

    private func poiActions() -> CarPlayPOIBuilder.Actions {
        .init(
            details: { [weak self] payload in self?.showDetail(for: payload) },
            // Comme partout ailleurs : pas de guidage sans `CPMapTemplate`.
            navigate: isShowingMap ? { [weak self] payload in
                self?.startNavigation(to: payload.coordinate, title: payload.title)
            } : nil
        )
    }

    /// Charge les antennes autour d'un point et repeint la carte à onglets.
    private func loadPOI(around center: CLLocationCoordinate2D?) {
        guard let poiTemplate else { return }
        let generation = beginScreen(.poi)
        track { [weak self] in
            guard let self else { return }
            let location: CLLocation?
            if let center {
                location = CLLocation(latitude: center.latitude, longitude: center.longitude)
            } else {
                location = await services.location.currentLocation()
            }
            guard let location, !Task.isCancelled, isCurrent(.poi, generation) else { return }

            let coordinate = location.coordinate
            let delta = 0.045
            guard let sites = try? await services.antennas.list(
                bbox: BoundingBox(north: coordinate.latitude + delta,
                                  south: coordinate.latitude - delta,
                                  east: coordinate.longitude + delta,
                                  west: coordinate.longitude - delta),
                market: MapMarketStore.initialMarketCode(),
                operatorName: MapMarketStore.initialOperatorKey(),
                technologies: []
            ) else { return }
            guard !Task.isCancelled, isCurrent(.poi, generation) else { return }

            let payloads = sites.compactMap { Self.payload(for: $0) }
            let entries = CarPlayPOIBuilder.entries(from: payloads, userLocation: location)
            poiTemplate.setPointsOfInterest(
                CarPlayPOIBuilder.points(from: entries, userLocation: location,
                                         actions: poiActions()),
                selectedIndex: NSNotFound
            )
        }
    }

    /// S'abonne aux intentions venues du Dashboard ou de l'iPhone.
    ///
    /// Installé une fois la racine posée : pousser un écran avant qu'elle existe
    /// laisserait une pile incohérente derrière le bouton retour. L'abonnement
    /// sert AUSSI les intentions déposées plus tôt — et, contrairement à la
    /// lecture unique d'avant, celles qui arrivent véhicule déjà branché.
    private func observeDashboardRoute() {
        CarPlayDashboardRoute.setListener { [weak self] destination in
            guard let self else { return }
            switch destination {
            case .here: showHere()
            // La carte est déjà la racine en mode navigation ; en mode liste, on
            // ouvre ce qui s'en rapproche le plus.
            case .map: if !isShowingMap { showNearby() }
            }
        }
    }

    /// Ouvre une entrée de la racine en mode liste.
    private func open(_ entry: CarPlayRootTemplateBuilder.Entry) {
        switch entry {
        case .nearby: showNearby()
        case .here: showHere()
        case .speedtest: showSpeedtest()
        case .sentinelle: showSentinelle()
        }
    }

    private var isAuthenticated: Bool {
        if case .authenticated = session.state { return true }
        return false
    }

    // MARK: - Carte

    private func installMap(in window: CPWindow) {
        let controller = CarPlayMapController()
        mapController = controller
        window.rootViewController = controller

        controller.onRegionChange = { [weak self] bounds, zoom in
            self?.reloadLayersIfNeeded(bounds: bounds, zoom: zoom)
        }
        controller.onSelect = { [weak self] payload in
            self?.showDetail(for: payload)
        }

        let actions = CarPlayMapTemplateBuilder.Actions(
            recenter: { [weak controller] in controller?.recenterOnUser() },
            zoomIn: { [weak controller] in controller?.zoomIn() },
            zoomOut: { [weak controller] in controller?.zoomOut() },
            showLayers: { [weak self] in self?.showLayers() },
            showHere: { [weak self] in self?.showHere() },
            showNearby: { [weak self] in self?.showNearby() },
            stopGuidance: { [weak self] in self?.endGuidance(finished: false) },
            showSpeedtest: { [weak self] in self?.showSpeedtest() }
        )
        mapActions = actions
        let template = CarPlayMapTemplateBuilder.make(actions: actions)
        mapTemplate = template
        interface.setRoot(template, animated: true)

        // (Les alertes de couverture sont posées dans `start()` : elles ne
        // dépendent pas de la carte.)

        // Premier cadrage : la dernière position connue si elle est fraîche,
        // sinon on laisse le suivi GPS recentrer dès le premier fix.
        if let location = services.location.lastLocation {
            controller.setZoom(Self.drivingZoom, animated: false)
            reloadLayersIfNeeded(bounds: SQMapProjection.bounds(of: controller.mapView.region),
                                 zoom: Self.drivingZoom,
                                 around: location.coordinate)
        }
    }

    private func reloadLayersIfNeeded(bounds: MapBounds,
                                     zoom: Double,
                                     around center: CLLocationCoordinate2D? = nil) {
        let newCenter = center ?? CLLocationCoordinate2D(
            latitude: (bounds.north + bounds.south) / 2,
            longitude: (bounds.east + bounds.west) / 2
        )
        if let last = lastLoadedCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: newCenter.latitude, longitude: newCenter.longitude))
            guard moved >= Self.reloadDistanceMeters else { return }
        }
        lastLoadedCenter = newCenter

        track { [weak self] in
            guard let self else { return }
            let loaded = await layers.load(
                bounds: bounds,
                zoom: zoom,
                filters: MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters,
                market: MapMarketStore.initialMarketCode(),
                operatorKey: MapMarketStore.initialOperatorKey()
            )
            guard !Task.isCancelled, let controller = mapController else { return }
            loadedLayers = loaded
            outagesById = loaded.outageSources
            plannedById = loaded.plannedSources
            controller.apply(payloads: loaded.annotations)
            controller.setCoverage(loaded.coverage)
            controller.setSpeedtests(loaded.speedtests)
        }
    }

    // MARK: - Actions de barre (remplies par les lots suivants)

    /// Grille des couches, retenue pour pouvoir en rafraîchir les libellés
    /// après une bascule.
    private var layersTemplate: CPGridTemplate?

    private func showLayers() {
        let template = LayersGridBuilder.make(
            current: MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters,
            onToggle: { [weak self] kind in self?.toggleLayer(kind) },
            onSentinelle: { [weak self] in self?.showSentinelle() },
            // Recherche seulement en mode carte : sans `CPMapTemplate`, il n'y a
            // pas de session de navigation à démarrer derrière un résultat.
            onSearch: isShowingMap ? { [weak self] in self?.showSearch() } : nil,
            onRecents: isShowingMap ? { [weak self] in self?.showRecentDestinations() } : nil
        )
        layersTemplate = template
        interface.push(template, animated: true)
    }

    // MARK: - Alertes « zone mal couverte »

    private var lastAlertAt: Date?
    private var lastAlertCoordinate: CLLocationCoordinate2D?
    private var lastAlertCheckCoordinate: CLLocationCoordinate2D?
    /// Abonnement DISTINCT de celui du guidage : les alertes de couverture
    /// valent pour tout trajet, pas seulement quand on suit un itinéraire.
    /// Séparer les deux évite aussi qu'arrêter un guidage ne coupe les alertes.
    private var alertObserver: UUID?

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
                simMnc: path.operatorMnc,
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
                now: Date(),
                // Rien ne doit couvrir une manœuvre annoncée : le conducteur a
                // besoin de son attention pour tourner.
                isManeuverImminent: isManeuverImminent
            )
            guard CarPlayAlertPolicy.shouldAlert(context) else { return }

            lastAlertAt = context.now
            lastAlertCoordinate = location.coordinate
            presentCoverageAlert(
                CarPlayAlertPolicy.message(for: verdict.level, operatorLabel: verdict.operatorLabel)
            )
        }
    }

    /// Vrai quand une manœuvre est proche. Le seuil correspond au deuxième
    /// palier d'annonce vocale : à partir de là, l'écran et la voix
    /// appartiennent au guidage.
    ///
    /// Lu sur la dernière progression observée plutôt que recalculé : le suivi
    /// vient de le faire, et refaire le calcul ici risquerait de diverger.
    private var isManeuverImminent: Bool {
        guard let lastProgress else { return false }
        return lastProgress.distanceToManeuver <= 300
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

    // MARK: - Sentinelle

    /// Liste des box surveillées, chargée à l'ouverture.
    ///
    /// Pas de rafraîchissement périodique : une box qui tombe déclenche une
    /// notification (lot 8), et sonder l'API en boucle depuis un véhicule
    /// coûterait des données pour une information qu'on ne regarde pas en
    /// roulant.
    private func showSentinelle() {
        let template = SentinelleTemplateBuilder.list(targets: []) { _ in }
        CarPlayListPlaceholder.applyLoading(to: template)
        interface.push(template, animated: true)
        loadSentinelle(into: template)
    }

    /// Remplit l'écran Sentinelle — extrait de `showSentinelle` pour que le
    /// bouton « Réessayer » puisse relancer le chargement sans réempiler
    /// d'écran (la profondeur autorisée est trop courte pour se le permettre).
    private func loadSentinelle(into template: CPListTemplate) {
        let generation = beginScreen(.sentinelle)
        track { [weak self] in
            guard let self else { return }
            do {
                let response = try await services.sentinelle.targets()
                guard !Task.isCancelled, isCurrent(.sentinelle, generation) else { return }
                guard !response.targets.isEmpty else {
                    CarPlayListPlaceholder.applyEmpty(
                        to: template,
                        title: String(localized: "Aucune box surveillée"),
                        subtitle: String(localized: "Ajoute une connexion à surveiller depuis l'app.")
                    )
                    return
                }
                let filled = SentinelleTemplateBuilder.list(targets: response.targets) { [weak self] target in
                    self?.interface.push(SentinelleTemplateBuilder.detail(target), animated: true)
                }
                // `updateSections` plutôt qu'un nouveau push : l'écran de chargement
                // et l'écran rempli sont le même, pas deux étapes de navigation.
                template.updateSections(filled.sections)
            } catch {
                guard !Task.isCancelled, isCurrent(.sentinelle, generation) else { return }
                CarPlayListPlaceholder.applyFailure(to: template) { [weak self] in
                    CarPlayListPlaceholder.applyLoading(to: template)
                    self?.loadSentinelle(into: template)
                }
            }
        }
    }

    private func toggleLayer(_ kind: MapDisplayItem.Kind) {
        var filters = MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters
        if filters.contains(kind) { filters.remove(kind) } else { filters.insert(kind) }
        MapFilterStore.save(filters)
        // Repeindre la grille : sans ça le « ✓ » du bouton restait figé et
        // l'appui semblait n'avoir aucun effet.
        layersTemplate?.updateGridButtons(LayersGridBuilder.buttons(
            current: filters,
            onToggle: { [weak self] kind in self?.toggleLayer(kind) },
            onSentinelle: { [weak self] in self?.showSentinelle() },
            onSearch: isShowingMap ? { [weak self] in self?.showSearch() } : nil,
            onRecents: isShowingMap ? { [weak self] in self?.showRecentDestinations() } : nil
        ))
        // Forcer le rechargement : la zone n'a pas bougé, seul le contenu change.
        lastLoadedCenter = nil
        guard let controller = mapController else { return }
        reloadLayersIfNeeded(bounds: SQMapProjection.bounds(of: controller.mapView.region),
                             zoom: controller.currentZoom)
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
            input: .init(path: services.networkPath.status, quality: nil),
            actions: .init()
        )
        interface.push(template, animated: true)
        loadHere(into: template)
    }

    /// Remplit l'écran « Ici ». Séparé de `showHere` pour que l'ONGLET puisse
    /// s'alimenter sans rien empiler : en mode onglets, cet écran est la racine.
    private func loadHere(into template: CPInformationTemplate) {
        let generation = beginScreen(.here)
        track { [weak self] in
            guard let self else { return }
            // `currentLocation()` et non `lastLocation` : au branchement du
            // véhicule, iOS lance l'app EN ARRIÈRE-PLAN et aucun fix n'a encore
            // été pris. L'ancien `guard lastLocation else { return }` laissait
            // donc l'écran phare figé sur une seule ligne, sans message ni
            // reprise — précisément dans le cas nominal.
            guard let location = await services.location.currentLocation() else { return }
            guard !Task.isCancelled, isCurrent(.here, generation) else { return }
            let input = await hereInput(at: location)
            guard !Task.isCancelled, isCurrent(.here, generation) else { return }
            let filled = NearestAntennaTemplateBuilder.make(
                input: input,
                actions: .init(
                    // Comme « Y aller », conditionné à la présence d'une carte :
                    // sans elle, ce bouton promettait un recentrage et se
                    // contentait de fermer la fiche.
                    showOnMap: isShowingMap ? input.nearestSite.flatMap { site -> (() -> Void)? in
                        guard let lat = site.latitude, let lon = site.longitude else { return nil }
                        return { [weak self] in
                            self?.mapController?.center(on: .init(latitude: lat, longitude: lon))
                            self?.interface.pop(animated: true)
                        }
                    } : nil,
                    navigate: isShowingMap ? input.nearestSite.flatMap { site -> (() -> Void)? in
                        guard let lat = site.latitude, let lon = site.longitude else { return nil }
                        return { [weak self] in
                            self?.startNavigation(
                                to: .init(latitude: lat, longitude: lon),
                                title: String(localized: "Site \(site.siteId ?? site.id)")
                            )
                        }
                    } : nil,
                    compareOperators: { [weak self] in self?.showOperatorComparison() }
                )
            )
            // Mise à jour EN PLACE, comme pour les fiches : re-pousser empilerait
            // deux écrans identiques.
            template.items = filled.items
            template.actions = filled.actions
        }
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
                    subtitle: String(localized: "Autorise la localisation pour comparer les opérateurs.")
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
            guard !stats.isEmpty else {
                CarPlayListPlaceholder.applyEmpty(
                    to: template,
                    title: String(localized: "Pas assez de mesures"),
                    subtitle: String(localized: "La communauté n'a pas encore assez mesuré cette zone.")
                )
                return
            }
            template.updateSections([
                CPListSection(items: OperatorComparisonTemplateBuilder.items(for: stats, metric: .download))
            ])
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
            simMnc: path.operatorMnc,
            maxAge: nil
        )

        var input = NearestAntennaTemplateBuilder.Input(path: path, quality: await quality)
        guard let sites = await antennas,
              let nearest = AntennaSectorGeometry.nearest(to: coordinate, among: sites) else {
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
        // Un cluster n'a pas de fiche : on s'en approche pour l'éclater.
        if let count = payload.clusterCount, count > 0 {
            mapController?.zoomIn()
            return
        }

        switch payload.kind {
        case .outage:
            guard let site = outagesById[payload.id] else { return }
            interface.push(CarPlayDetailTemplateBuilder.outage(
                site, userLocation: services.location.lastLocation, actions: detailActions(for: payload)
            ), animated: true)
        case .planned:
            guard let site = plannedById[payload.id] else { return }
            interface.push(CarPlayDetailTemplateBuilder.planned(
                site, userLocation: services.location.lastLocation, actions: detailActions(for: payload)
            ), animated: true)
        default:
            showAntennaDetail(for: payload)
        }
    }

    private func showAntennaDetail(for payload: MapAnnotationPayload) {
        let actions = detailActions(for: payload)
        let template = CarPlayDetailTemplateBuilder.antenna(
            payload: payload, details: nil,
            userLocation: services.location.lastLocation, actions: actions
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
                userLocation: services.location.lastLocation, actions: actions
            )
            template.items = enriched.items
            template.actions = enriched.actions
        }
    }

    private func detailActions(for payload: MapAnnotationPayload) -> CarPlayDetailTemplateBuilder.Actions {
        .init(
            // « Y aller » n'est proposé qu'en mode carte : sans `CPMapTemplate`,
            // il n'y a pas de session de navigation à démarrer.
            navigate: isShowingMap ? { [weak self] in
                self?.startNavigation(to: payload.coordinate, title: payload.title)
            } : nil,
            // « Centrer » non plus : sans carte à centrer, le bouton se
            // contentait de refermer la fiche, ce qui ressemble à un bug.
            center: isShowingMap ? { [weak self] in
                self?.mapController?.center(on: payload.coordinate)
                self?.interface.pop(animated: true)
            } : nil
        )
    }

    // MARK: - Guidage

    /// Calcule l'itinéraire et démarre le guidage.
    ///
    /// L'ordre compte : on revient d'abord à la carte, PUIS on calcule. Laisser
    /// la fiche affichée pendant l'appel réseau donnerait l'impression que le
    /// bouton n'a rien fait.
    func startNavigation(to coordinate: CLLocationCoordinate2D, title: String) {
        interface.pop(animated: true)
        guard let origin = services.location.lastLocation?.coordinate else {
            presentNavigationAlert(String(localized: "Position indisponible — autorise la localisation dans les réglages."))
            return
        }
        destination = coordinate
        // Mémorisé AVANT le calcul : une destination choisie reste utile dans les
        // récents même si l'itinéraire échoue — c'est justement là qu'on voudra
        // réessayer sans avoir à la ressaisir.
        CarPlayDestinationStore.record(title: title, coordinate: coordinate)

        track { [weak self] in
            guard let self else { return }
            guard let plan = try? await routeService.route(from: origin, to: coordinate) else {
                presentNavigationAlert(String(localized: "Connexion impossible. Vérifie ta connexion puis réessaie."))
                return
            }
            guard !Task.isCancelled else { return }
            beginGuidance(with: plan, title: title)
        }
    }

    private func presentNavigationAlert(_ message: String) {
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                self?.interface.dismiss(animated: true)
            }]
        )
        interface.present(alert, animated: true)
    }

    private func beginGuidance(with plan: RoutePlan, title: String) {
        guard let mapTemplate else { return }
        if navigationSession != nil { endGuidance(finished: false) }
        currentPlan = plan
        tracker = RouteProgressTracker(plan: plan)
        voiceGuide = CarPlayVoiceGuide { [weak self] in
            // Se taire pendant un appel : le guidage parlerait par-dessus
            // l'interlocuteur, sur le même haut-parleur.
            self?.services.callManager.activeCall != nil
        }

        let choice = CPRouteChoice(
            summaryVariants: [title],
            additionalInformationVariants: [SQUnits.distance(meters: plan.totalDistanceMeters)],
            selectionSummaryVariants: [title]
        )
        // L'init par `CPNavigationWaypoint` n'existe qu'à partir d'iOS 26.4 et la
        // cible du projet est iOS 16 : celui-ci, déprécié depuis, reste le seul
        // disponible sur toute la plage supportée.
        let trip = CPTrip(
            origin: MKMapItem(placemark: MKPlacemark(coordinate: origin(of: plan))),
            destination: MKMapItem(placemark: MKPlacemark(coordinate: plan.polyline.last ?? origin(of: plan))),
            routeChoices: [choice]
        )
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        navigationSession?.upcomingManeuvers = ManeuverMapper.maneuvers(for: plan, from: 0)

        mapController?.showRoute(plan.polyline)
        updateGuidanceControls(isGuiding: true)
        locationObserver = services.location.addLocationObserver { [weak self] location in
            self?.handleGuidance(location: location)
        }
    }

    private func handleGuidance(location: CLLocation) {
        guard let tracker, let plan = currentPlan else { return }
        let previousStep = tracker.stepIndex
        let progress = tracker.update(with: location)
        lastProgress = progress

        if progress.hasArrived {
            voiceGuide?.announceArrival()
            endGuidance(finished: true)
            return
        }

        if progress.stepIndex != previousStep {
            navigationSession?.upcomingManeuvers = ManeuverMapper.maneuvers(for: plan, from: progress.stepIndex)
        }
        if let maneuver = navigationSession?.upcomingManeuvers.first {
            // Swift importe `updateTravelEstimates:forManeuver:` sous ce nom.
            navigationSession?.updateEstimates(
                ManeuverMapper.travelEstimates(distanceMeters: progress.distanceToManeuver,
                                               timeRemaining: 0),
                for: maneuver
            )
        }
        voiceGuide?.handle(progress: progress, plan: plan)

        // Sortie CONFIRMÉE seulement, et seulement si le budget d'appels le
        // permet : `MKDirections` est throttlé, et une rafale de recalculs
        // arrêterait le guidage pour de bon.
        if progress.isOffRoute, routeService.canRecalculate() {
            recalculate(from: location.coordinate)
        }
    }

    private func recalculate(from origin: CLLocationCoordinate2D) {
        guard let destination else { return }
        track { [weak self] in
            guard let self else { return }
            guard let plan = try? await routeService.route(from: origin, to: destination,
                                                           isRecalculation: true) else { return }
            guard !Task.isCancelled else { return }
            currentPlan = plan
            tracker = RouteProgressTracker(plan: plan)
            navigationSession?.upcomingManeuvers = ManeuverMapper.maneuvers(for: plan, from: 0)
            mapController?.showRoute(plan.polyline)
        }
    }

    private func updateGuidanceControls(isGuiding: Bool) {
        guard let mapTemplate, let mapActions else { return }
        mapTemplate.trailingNavigationBarButtons =
            CarPlayMapTemplateBuilder.trailingButtons(isGuiding: isGuiding, actions: mapActions)
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
                // Publié sur la carte comme depuis l'app, mais SANS position
                // exacte : une mesure prise en roulant n'a pas besoin d'être
                // rattachée au mètre près, et le point de départ d'un trajet en
                // dit long sur son auteur.
                try? await services.speedtest.save(
                    result,
                    streams: SpeedtestRunSettings.androidDefault.streams,
                    publishToMap: true,
                    shareExactLocation: false
                )
            } catch {
                guard !Task.isCancelled else { return }
                updateSpeedtest(state: .failed(error.localizedDescription))
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
        speedtestTemplate.items = refreshed.items
        speedtestTemplate.actions = refreshed.actions
    }

    /// Point de départ affiché dans la prévisualisation : la position réelle si
    /// on l'a, sinon le début du tracé — jamais (0, 0), qui placerait l'origine
    /// dans le golfe de Guinée.
    private func origin(of plan: RoutePlan) -> CLLocationCoordinate2D {
        services.location.lastLocation?.coordinate ?? plan.polyline.first ?? plan.steps.first?.maneuverCoordinate
            ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    private func endGuidance(finished: Bool) {
        if finished { navigationSession?.finishTrip() } else { navigationSession?.cancelTrip() }
        navigationSession = nil
        tracker = nil
        currentPlan = nil
        destination = nil
        voiceGuide?.reset()
        voiceGuide = nil
        mapController?.clearRoute()
        updateGuidanceControls(isGuiding: false)
        if let locationObserver {
            services.location.removeLocationObserver(locationObserver)
            self.locationObserver = nil
        }
    }

    /// Liste « Autour de toi » — le seul chemin vers les fiches sur un véhicule
    /// à molette, où viser un marqueur est impossible, et la porte d'entrée des
    /// antennes en mode liste.
    private func showNearby() {
        let known = NearbyListTemplateBuilder.entries(from: loadedLayers.annotations,
                                                     userLocation: services.location.lastLocation)
        let template = NearbyListTemplateBuilder.make(entries: known) { [weak self] payload in
            self?.showDetail(for: payload)
        }
        // En mode carte les marqueurs sont déjà chargés, la liste est complète
        // d'emblée. Sinon elle part vide, et ce vide est un CHARGEMENT — pas une
        // absence de sites.
        if known.isEmpty { CarPlayListPlaceholder.applyLoading(to: template) }
        interface.push(template, animated: true)

        guard known.isEmpty else { return }
        loadNearby(into: template)
    }

    /// Charge les sites autour de la position, pour le mode liste où personne
    /// n'a chargé de marqueurs de carte. Extrait de `showNearby` pour que
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
                    subtitle: String(localized: "Autorise la localisation pour voir les sites autour.")
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

    /// Recherche d'une destination — adresse ou site par son code.
    ///
    /// Le contrôleur est RETENU par le coordinateur : `CPSearchTemplate.delegate`
    /// est une référence faible, un contrôleur local serait libéré avant la
    /// première frappe et la recherche ne répondrait jamais.
    private func showSearch() {
        let controller = CarPlaySearchController(
            antennas: services.antennas,
            around: { [weak self] in self?.services.location.lastLocation?.coordinate },
            market: { MapMarketStore.initialMarketCode() },
            onSelect: { [weak self] coordinate, title in
                self?.startNavigation(to: coordinate, title: title)
            }
        )
        searchController = controller
        interface.push(controller.makeTemplate(), animated: true)
    }

    /// Destinations récentes : une pression, aucune saisie. Sur les véhicules où
    /// le clavier se bloque en roulant, c'est la seule source encore utilisable.
    private func showRecentDestinations() {
        let template = RecentDestinationsTemplateBuilder.make(
            CarPlayDestinationStore.all()
        ) { [weak self] destination in
            self?.startNavigation(to: destination.coordinate, title: destination.title)
        }
        interface.push(template, animated: true)
    }

    /// Convertit un site de la liste `/api/antennas` en marqueur, pour que les
    /// fiches reçoivent la même forme qu'en mode carte.
    private static func payload(for site: AntennaSite) -> MapAnnotationPayload? {
        guard let lat = site.latitude, let lon = site.longitude else { return nil }
        return MapAnnotationPayload(
            id: "antenna-\(site.id)",
            kind: .antenna,
            title: String(localized: "Site \(site.siteId ?? site.id)"),
            subtitle: [site.operators.joined(separator: "/"),
                       site.technologies.prefix(3).joined(separator: "/")]
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
            tint: SQBrand.operatorColor(site.operators.first)
        )
    }
}
