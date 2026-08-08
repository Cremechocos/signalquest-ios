import CarPlay
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
    /// Conservées pour recomposer la barre : « Arrêter » n'apparaît que pendant
    /// un guidage, donc les boutons changent en cours de route.
    private var mapActions: CarPlayMapTemplateBuilder.Actions?
    /// Jeton d'abonnement aux positions, à relâcher en fin de guidage : sans
    /// cela, le suivi continuerait à alimenter un guidage terminé.
    private var locationObserver: UUID?

    /// Travaux longs à annuler à la déconnexion.
    ///
    /// Volontairement des `Task` et jamais un `Timer.scheduledTimer` : un timer
    /// reste retenu par la run loop et continuerait de tourner véhicule
    /// débranché, à réveiller le réseau pour une surface qui n'existe plus.
    private var tasks: [Task<Void, Never>] = []

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
        services.setCarPlayConnected(true)
        interface.setRoot(CarPlayRootTemplateBuilder.loading(), animated: false)

        // L'amorçage peut n'avoir jamais eu lieu : au branchement du véhicule,
        // iOS lance l'app en arrière-plan et la fenêtre iPhone peut ne jamais
        // apparaître. `bootstrapIfNeeded` est coalescé, donc l'appeler ici ne
        // double pas le travail si la fenêtre l'a déjà déclenché.
        let task = Task { [weak self] in
            guard let self else { return }
            await services.bootstrapIfNeeded(session: session)
            guard !Task.isCancelled else { return }
            installRoot()
        }
        tasks.append(task)
    }

    func stop() {
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
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
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
            // Repli sans carte : Apple n'a pas accordé la catégorie navigation.
            // Cette liste EST alors l'application — tout doit y être atteignable.
            interface.setRoot(CarPlayRootTemplateBuilder.list { [weak self] entry in
                self?.open(entry)
            }, animated: true)
            consumeDashboardRouteIfNeeded()
            return
        }
        installMap(in: carWindow)
        consumeDashboardRouteIfNeeded()
    }

    /// Applique l'intention éventuellement déposée par un raccourci du
    /// Dashboard. Appelé une fois la racine posée : pousser un écran avant
    /// qu'elle existe laisserait une pile incohérente derrière le bouton retour.
    private func consumeDashboardRouteIfNeeded() {
        switch CarPlayDashboardRoute.consume() {
        case .here: showHere()
        // La carte est déjà la racine en mode navigation ; en mode liste, on
        // ouvre ce qui s'en rapproche le plus.
        case .map: if !isShowingMap { showNearby() }
        case nil: break
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

        if CarPlayAlertSettings.coverageAlertsEnabled {
            alertObserver = services.location.addLocationObserver { [weak self] location in
                self?.evaluateCoverageAlert(at: location)
            }
        }

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

        let task = Task { [weak self] in
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
        tasks.append(task)
    }

    // MARK: - Actions de barre (remplies par les lots suivants)

    private func showLayers() {
        interface.push(LayersGridBuilder.make(
            current: MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters,
            onToggle: { [weak self] kind in self?.toggleLayer(kind) },
            onSentinelle: { [weak self] in self?.showSentinelle() }
        ), animated: true)
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
        if let last = lastAlertCheckCoordinate {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: location)
            guard moved >= 500 else { return }
        }
        lastAlertCheckCoordinate = location.coordinate

        let task = Task { [weak self] in
            guard let self else { return }
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
        tasks.append(task)
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
        )
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
        interface.push(template, animated: true)

        let task = Task { [weak self] in
            guard let self else { return }
            guard let response = try? await services.sentinelle.targets() else { return }
            guard !Task.isCancelled else { return }
            let filled = SentinelleTemplateBuilder.list(targets: response.targets) { [weak self] target in
                self?.interface.push(SentinelleTemplateBuilder.detail(target), animated: true)
            }
            // `updateSections` plutôt qu'un nouveau push : l'écran de chargement
            // et l'écran rempli sont le même, pas deux étapes de navigation.
            template.updateSections(filled.sections)
        }
        tasks.append(task)
    }

    private func toggleLayer(_ kind: MapDisplayItem.Kind) {
        var filters = MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters
        if filters.contains(kind) { filters.remove(kind) } else { filters.insert(kind) }
        MapFilterStore.save(filters)
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

        guard let location = services.location.lastLocation else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let input = await hereInput(at: location)
            guard !Task.isCancelled else { return }
            let filled = NearestAntennaTemplateBuilder.make(
                input: input,
                actions: .init(
                    showOnMap: input.nearestSite.flatMap { site -> (() -> Void)? in
                        guard let lat = site.latitude, let lon = site.longitude else { return nil }
                        return { [weak self] in
                            self?.mapController?.center(on: .init(latitude: lat, longitude: lon))
                            self?.interface.pop(animated: true)
                        }
                    },
                    navigate: isShowingMap ? input.nearestSite.flatMap { site -> (() -> Void)? in
                        guard let lat = site.latitude, let lon = site.longitude else { return nil }
                        return { [weak self] in
                            self?.startNavigation(
                                to: .init(latitude: lat, longitude: lon),
                                title: String(localized: "Site \(site.siteId ?? site.id)")
                            )
                        }
                    } : nil
                )
            )
            // Mise à jour EN PLACE, comme pour les fiches : re-pousser empilerait
            // deux écrans identiques.
            template.items = filled.items
            template.actions = filled.actions
        }
        tasks.append(task)
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
        let task = Task { [weak self] in
            guard let self else { return }
            let details = try? await services.antennas.details(
                id: antennaId,
                market: MapMarketStore.initialMarketCode(),
                operatorName: MapMarketStore.initialOperatorKey(),
                anfrCode: payload.backendId
            )
            guard !Task.isCancelled, let details else { return }
            // Le template est mis à jour EN PLACE : re-pousser empilerait deux
            // fiches identiques, et le bouton retour ramènerait sur la première.
            let enriched = CarPlayDetailTemplateBuilder.antenna(
                payload: payload, details: details,
                userLocation: services.location.lastLocation, actions: actions
            )
            template.items = enriched.items
            template.actions = enriched.actions
        }
        tasks.append(task)
    }

    private func detailActions(for payload: MapAnnotationPayload) -> CarPlayDetailTemplateBuilder.Actions {
        .init(
            // « Y aller » n'est proposé qu'en mode carte : sans `CPMapTemplate`,
            // il n'y a pas de session de navigation à démarrer.
            navigate: isShowingMap ? { [weak self] in
                self?.startNavigation(to: payload.coordinate, title: payload.title)
            } : nil,
            center: { [weak self] in
                self?.mapController?.center(on: payload.coordinate)
                self?.interface.pop(animated: true)
            }
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
        guard let origin = services.location.lastLocation?.coordinate else { return }
        destination = coordinate

        let task = Task { [weak self] in
            guard let self else { return }
            guard let plan = try? await routeService.route(from: origin, to: coordinate) else { return }
            guard !Task.isCancelled else { return }
            beginGuidance(with: plan, title: title)
        }
        tasks.append(task)
    }

    private func beginGuidance(with plan: RoutePlan, title: String) {
        guard let mapTemplate else { return }
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
        services.location.startTracking()
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
        let task = Task { [weak self] in
            guard let self else { return }
            guard let plan = try? await routeService.route(from: origin, to: destination,
                                                           isRecalculation: true) else { return }
            guard !Task.isCancelled else { return }
            currentPlan = plan
            tracker = RouteProgressTracker(plan: plan)
            navigationSession?.upcomingManeuvers = ManeuverMapper.maneuvers(for: plan, from: 0)
            mapController?.showRoute(plan.polyline)
        }
        tasks.append(task)
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
        let template = NearbyListTemplateBuilder.make(
            entries: NearbyListTemplateBuilder.entries(from: loadedLayers.annotations,
                                                      userLocation: services.location.lastLocation)
        ) { [weak self] payload in
            self?.showDetail(for: payload)
        }
        interface.push(template, animated: true)

        // Sans carte, personne n'a chargé de marqueurs : la liste serait vide
        // alors que c'est le seul accès aux antennes. On les récupère ici, autour
        // de la position, comme le fait l'écran « Ici ».
        guard loadedLayers.annotations.isEmpty,
              let location = services.location.lastLocation else { return }
        let task = Task { [weak self] in
            guard let self else { return }
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
            guard !Task.isCancelled else { return }
            let payloads = sites.compactMap { Self.payload(for: $0) }
            let entries = NearbyListTemplateBuilder.entries(from: payloads, userLocation: location)
            let filled = NearbyListTemplateBuilder.make(entries: entries) { [weak self] payload in
                self?.showDetail(for: payload)
            }
            // `updateSections` plutôt qu'un push : l'écran vide et l'écran rempli
            // sont le même, pas deux étapes de navigation.
            template.updateSections(filled.sections)
        }
        tasks.append(task)
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
