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
        case here, nearby, detail, speedtest, poi, comparison
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

    init(interface: CarPlayInterfaceControlling,
         services: AppServices,
         session: AuthSessionViewModel) {
        self.interface = interface
        self.services = services
        self.session = session
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
        installRoot()
    }

    // MARK: - Racine à onglets

    private var hereTemplate: CPInformationTemplate?
    private var tabBarDelegate: CarPlayTabBarDelegate?
    /// Dernier remplissage de l'onglet « Ici ». L'onglet suit le trajet : il se
    /// recharge quand on y revient, au plus une fois par intervalle.
    private var hereLoadedAt: Date?
    private static let hereRefreshInterval: TimeInterval = 30
    private var poiTemplate: CPPointOfInterestTemplate?
    /// Retenu ici : `pointOfInterestDelegate` est une référence faible, un
    /// contrôleur local serait libéré avant le premier déplacement de carte.
    private var poiController: CarPlayPOIController?

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

        let tabs = [
            CarPlayTabBarBuilder.decorate(here, title: String(localized: "Ici"),
                                          systemImage: "dot.radiowaves.left.and.right"),
            poi,
            CarPlayTabBarBuilder.decorate(speedtest, title: String(localized: "Speedtest"),
                                          systemImage: "speedometer"),
        ]

        let tabBar = CarPlayTabBarBuilder.make(tabs: tabs)
        let tabDelegate = CarPlayTabBarDelegate()
        tabDelegate.onSelect = { [weak self] selected in
            guard let self, let here = hereTemplate, selected === here else { return }
            refreshHereIfStale(here)
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
        loadPOI(around: nil)
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
        speedtestTemplate = nil
        interface.setRoot(CarPlayRootTemplateBuilder.list { [weak self] entry in
            self?.open(entry)
        }, animated: false)
    }

    private func poiActions() -> CarPlayPOIBuilder.Actions {
        .init(details: { [weak self] payload in self?.showDetail(for: payload) })
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
            guard !Task.isCancelled, isCurrent(.poi, generation) else { return }
            guard let location else {
                poiTemplate.setPointsOfInterest([], selectedIndex: NSNotFound)
                return
            }

            let coordinate = location.coordinate
            let delta = 0.045
            let fetched: [AntennaSite]?
            do {
                fetched = try await services.antennas.list(
                    bbox: BoundingBox(north: coordinate.latitude + delta,
                                      south: coordinate.latitude - delta,
                                      east: coordinate.longitude + delta,
                                      west: coordinate.longitude - delta),
                    market: MapMarketStore.initialMarketCode(),
                    operatorName: MapMarketStore.initialOperatorKey(),
                    technologies: []
                )
            } catch {
                fetched = nil
            }
            guard !Task.isCancelled, isCurrent(.poi, generation) else { return }
            // Échec ≠ vide : on le dit, avec un bouton pour recommencer.
            guard let sites = fetched else {
                poiTemplate.setPointsOfInterest(
                    [CarPlayPOIBuilder.failurePoint(at: coordinate) { [weak self] in self?.loadPOI(around: center) }],
                    selectedIndex: NSNotFound
                )
                return
            }

            let update = {
                let payloads = sites.compactMap { Self.payload(for: $0) }
                let entries = CarPlayPOIBuilder.entries(from: payloads, userLocation: location)
                poiTemplate.setPointsOfInterest(
                    CarPlayPOIBuilder.points(from: entries, userLocation: location,
                                             actions: self.poiActions()),
                    selectedIndex: NSNotFound
                )
            }
            // Un centre choisi sur la carte reste une intention manuelle ; seul
            // le point GPS doit encore être autorisé et frais après le réseau.
            if center != nil { update() }
            else if !CarPlayLocationRenderGate.commit(location, service: services.location, update: update) {
                poiTemplate.setPointsOfInterest([], selectedIndex: NSNotFound)
            }
        }
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
            input: .init(path: services.networkPath.status, quality: nil),
            actions: .init()
        )
        interface.push(template, animated: true)
        loadHere(into: template)
    }

    /// Remplit l'écran « Ici ». Séparé de `showHere` pour que l'ONGLET puisse
    /// s'alimenter sans rien empiler : en mode onglets, cet écran est la racine.
    private func loadHere(into template: CPInformationTemplate) {
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
                let filled = NearestAntennaTemplateBuilder.make(
                    input: input,
                    actions: .init(
                        compareOperators: { [weak self] in self?.showOperatorComparison() }
                    )
                )
                // Mise à jour EN PLACE, comme pour les fiches : re-pousser empilerait
                // deux écrans identiques.
                template.items = filled.items
                template.actions = filled.actions
            }
            if !didRender {
                showHereWithoutLocation(into: template)
            }
        }
    }

    private func refreshHereIfStale(_ template: CPInformationTemplate) {
        if let hereLoadedAt, Date().timeIntervalSince(hereLoadedAt) < Self.hereRefreshInterval { return }
        loadHere(into: template)
    }

    private func showHereWithoutLocation(into template: CPInformationTemplate) {
        template.items = NearestAntennaTemplateBuilder.itemsWithoutLocation(path: services.networkPath.status)
        template.actions = []
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
