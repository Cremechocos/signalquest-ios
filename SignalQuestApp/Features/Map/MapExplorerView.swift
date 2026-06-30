import SwiftUI
import MapKit
import ImageIO
#if canImport(MapLibre)
import MapLibre
#endif

@MainActor
final class MapExplorerViewModel: ObservableObject {
    @Published var snapshot: SocialMapSnapshot = .empty
    @Published var antennas: [AntennaSite] = []
    @Published var antennaClusters: [AndroidMapCluster] = []
    @Published var speedtestTiles: [AndroidSpeedtestTileResponse] = []
    @Published var coverageTiles: [AndroidCoverageTileResponse] = []
    @Published var communitySiteTiles: [AndroidCommunitySiteTileResponse] = []
    @Published var plannedSites: [PlannedSiteLive] = []
    @Published var outages: [OutageSiteLive] = []
    @Published var coverageHeat: [CoverageHeatPoint] = []
    /// Photos publiques de tous les membres (couche Photos). Mode « Amis » =
    /// restreint aux amis (rechargé avec friendsOnly).
    @Published var publicPhotos: [MapPublicPhoto] = []
    /// Incrémenté à chaque application de données (fin de `load`). Sert de signal
    /// O(1) pour reconstruire le cache d'annotations de la vue uniquement quand
    /// les données changent — et non à chaque invalidation de `body`.
    @Published private(set) var dataVersion = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Marché + opérateur initiaux : dernier choix persisté, sinon le pays de la
    // locale appareil (jamais la France imposée). La détection fine (SIM/GPS) est
    // appliquée ensuite dans `resolveInitialSelection`.
    @Published var marketFilter = MapMarketStore.initialMarketCode()
    @Published var operatorFilter = MapMarketStore.initialOperatorKey()
    @Published var techFilters: Set<String> = []
    @Published var bandFilters: Set<Int> = []
    @Published var sharingFilters: Set<String> = []
    /// Inclure les cellules seulement « observées » (vs sites probables
    /// consolidés) dans la couche communautaire.
    @Published var includeObservedSites = true
    @Published var speedtestDays = 0
    @Published var coverageDays = 0
    @Published var searchQuery: String = ""
    @Published var searchResults: [AntennaSite] = []
    /// Marchés sélectionnables du registre (picker manuel).
    @Published var registryMarkets: [MarketRegistryEntry] = []
    /// Entrée du registre correspondant au marché courant.
    @Published var currentMarketEntry: MarketRegistryEntry?
    /// Bandeau « Marché : X » affiché 2 s après un changement automatique.
    @Published var marketSwitchNotice: String?

    let mapService: MapSnapshotServicing
    let antennasService: AntennasServicing
    let marketsService: MarketRegistryServicing

    private var marketDetectionTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Code détecté au passage précédent : un switch auto exige deux
    /// détections consécutives du même marché.
    private var pendingAutoMarketCode: String?
    /// Vrai entre un switch automatique et sa consommation par la vue,
    /// pour court-circuiter le recentrage du picker manuel.
    private var autoMarketSwitchInProgress = false
    /// Vrai pendant la sélection initiale (cascade marché/opérateur à
    /// l'ouverture) : les `onChange` de marketFilter/operatorFilter doivent alors
    /// court-circuiter recentrage + rechargement, car le `.task` les pilote lui-même.
    private(set) var initialSelectionInProgress = false

    init(map: MapSnapshotServicing, antennas: AntennasServicing, markets: MarketRegistryServicing) {
        self.mapService = map
        self.antennasService = antennas
        self.marketsService = markets
    }

    // MARK: Registre des marchés

    func loadRegistry() async {
        let payload = await marketsService.registry()
        registryMarkets = payload.markets.filter(\.publicSelectable)
        currentMarketEntry = payload.market(forCode: marketFilter)
    }

    /// Sélection initiale du marché + opérateur à l'ouverture de la carte, **sans
    /// jamais imposer la France**. À appeler après `loadRegistry()`.
    ///
    /// Cascade : si l'utilisateur a déjà un choix persisté cohérent, on le
    /// respecte. Sinon, marché via MCC (cellulaire) → GPS (si déjà autorisé) →
    /// locale appareil → 1ʳᵉ entrée du registre ; opérateur via `operatorKey`
    /// (IP/ASN, hors VPN) → MNC → **« Tous »**. Ne touche `marketFilter` /
    /// `operatorFilter` que si la détection apporte une valeur différente, et pose
    /// `initialSelectionInProgress` pour que les `onChange` ne rechargent pas en
    /// double (le `.task` pilote le recentrage + l'unique `load`).
    func resolveInitialSelection(
        networkPath: NetworkPathMonitor,
        networkOperator: NetworkOperatorServicing,
        location: LocationService
    ) async {
        let payload = await marketsService.registry()
        guard !payload.markets.isEmpty else { return }

        networkPath.refreshNow()
        let status = networkPath.status

        // 1. Marché.
        var entry: MarketRegistryEntry?
        if status.connection == .cellular, let mcc = status.operatorMcc {
            entry = payload.markets.first { $0.publicSelectable && $0.mccs.contains(mcc) }
        }
        if entry == nil,
           location.authorizationStatus == .authorizedWhenInUse
            || location.authorizationStatus == .authorizedAlways,
           let loc = await location.currentLocation(timeoutSeconds: 4) {
            let resolved = await marketsService.marketForLocation(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude
            )
            entry = resolved?.publicSelectable == true ? resolved : nil
        }
        if entry == nil { entry = Self.localeMarketEntry(in: payload) }
        if entry == nil { entry = payload.markets.first { $0.publicSelectable } }
        guard let entry else { return }
        let marketCode = entry.marketCode.isEmpty ? entry.code : entry.marketCode

        // Choix persisté cohérent : on respecte la sélection de l'utilisateur.
        if let persisted = MapMarketStore.lastMarket(),
           persisted.uppercased() == marketCode.uppercased() {
            currentMarketEntry = entry
            return
        }

        // 2. Opérateur : « Tous » par défaut, affiné par l'opérateur réel détecté.
        var operatorKey = "ALL"
        if status.connection == .cellular {
            if let detected = await networkOperator.resolve(viaVpn: VPNDetector.isActive()),
               let key = detected.operatorKey,
               entry.operatorEntry(forKey: key) != nil {
                operatorKey = key
            } else if let mnc = status.operatorMnc,
                      let op = entry.selectableOperators.first(where: { $0.mncs.contains(mnc) }) {
                operatorKey = op.key
            }
        }

        // 3. Application (les onChange court-circuitent grâce au flag).
        initialSelectionInProgress = true
        currentMarketEntry = entry
        if operatorFilter.uppercased() != operatorKey.uppercased() { operatorFilter = operatorKey }
        if marketFilter.uppercased() != marketCode.uppercased() { marketFilter = marketCode }
        MapMarketStore.save(market: marketCode, operator: operatorKey)
    }

    /// Fin de la phase de sélection initiale (réautorise recentrage + rechargement
    /// dans les `onChange`). Appelé par la vue après l'unique `load`.
    func endInitialSelection() { initialSelectionInProgress = false }

    /// Entrée du registre correspondant au pays de la locale appareil (ISO), ou nil.
    private static func localeMarketEntry(in payload: MarketRegistryPayload) -> MarketRegistryEntry? {
        guard let region = Locale.current.region?.identifier.uppercased(), !region.isEmpty else { return nil }
        return payload.markets.first {
            $0.publicSelectable && ($0.countryCode.uppercased() == region
                || $0.code.uppercased() == region
                || $0.marketCode.uppercased() == region)
        }
    }

    /// Recherche synchrone dans les marchés déjà chargés (picker, recentrage).
    func registryMarket(forCode code: String) -> MarketRegistryEntry? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        if let current = currentMarketEntry,
           current.marketCode.uppercased() == normalized || current.code.uppercased() == normalized {
            return current
        }
        return registryMarkets.first {
            $0.marketCode.uppercased() == normalized || $0.code.uppercased() == normalized
        }
    }

    /// Réaligne l'entrée courante et le filtre opérateur après un changement
    /// de marché. `resetOperator` force le retour à l'opérateur par défaut
    /// (switch automatique) ; sinon on ne corrige que les valeurs invalides.
    func alignWithMarket(code: String, resetOperator: Bool) async {
        let entry = await marketsService.market(forCode: code)
        currentMarketEntry = entry
        guard let entry else { return }
        let validKeys = Set(entry.selectableOperators.map { $0.key.uppercased() } + ["ALL"])
        if resetOperator || !validKeys.contains(operatorFilter.uppercased()) {
            operatorFilter = Self.defaultOperatorKey(for: entry)
        }
        // Purge des bandes/partages devenus invalides pour le nouveau pays :
        // sinon une sélection (ex. B20 en FR, ou « Crozon SFR ») resterait
        // invisible dans la feuille (pas de chip) mais active dans la requête.
        let validBands = Set(MapFilterCatalog.bands(forMarket: entry.marketCode).map(\.band))
        let prunedBands = bandFilters.intersection(validBands)
        if prunedBands != bandFilters { bandFilters = prunedBands }
        let validSharing = Set(MapFilterCatalog.sharing(forMarket: entry.marketCode).map(\.value))
        let prunedSharing = sharingFilters.intersection(validSharing)
        if prunedSharing != sharingFilters { sharingFilters = prunedSharing }
    }

    var supportsCommunityLayers: Bool {
        currentMarketEntry?.capabilities.communityLayers ?? false
    }

    var isCommunityOnlyMarket: Bool {
        currentMarketEntry?.isCommunityOnly ?? false
    }

    var currentMarketLabel: String {
        currentMarketEntry?.label ?? marketFilter
    }

    var defaultOperatorKeyForCurrentMarket: String {
        currentMarketEntry.map(Self.defaultOperatorKey(for:)) ?? "SFR"
    }

    /// Opérateurs filtrables du marché courant (clés registre + "ALL").
    var operatorOptions: [String] {
        guard let entry = currentMarketEntry else {
            // Registre pas encore chargé : on n'affiche que la sélection courante.
            return operatorFilter.uppercased() == "ALL" ? ["ALL"] : [operatorFilter, "ALL"]
        }
        var keys = entry.selectableOperators.map(\.key)
        if !keys.contains(where: { $0.uppercased() == "ALL" }) {
            keys.append("ALL")
        }
        return keys
    }

    func operatorShortLabel(_ key: String) -> String {
        if let entry = currentMarketEntry?.operatorEntry(forKey: key) {
            return entry.shortLabel
        }
        return key.uppercased() == "ALL" ? "Tous" : key
    }

    func operatorLabel(_ key: String) -> String {
        if let entry = currentMarketEntry?.operatorEntry(forKey: key) {
            return entry.label
        }
        return key.uppercased() == "ALL" ? "Tous les opérateurs" : key
    }

    func operatorAccent(_ key: String) -> Color {
        if key.uppercased() == "ALL", currentMarketEntry?.operatorEntry(forKey: key) == nil {
            return SQColor.labelSecondary
        }
        return currentMarketEntry?.operatorColor(forKey: key) ?? SQBrand.operatorColor(key)
    }

    private static func defaultOperatorKey(for entry: MarketRegistryEntry) -> String {
        if entry.isCommunityOnly { return "ALL" }
        return entry.selectableOperators.first(where: { $0.key.uppercased() != "ALL" })?.key
            ?? entry.selectableOperators.first?.key
            ?? "ALL"
    }

    /// Code département DROM (974, 971…) couvrant le centre du viewport, pour la
    /// résolution opérateur des couches pannes/prévisionnels (le backend mappe
    /// Orange/Free vers la bonne filiale selon le territoire). `nil` hors DROM
    /// connu : le backend retombe alors sur sa valeur par défaut.
    static func dromTerritory(for bounds: MapBounds) -> String? {
        let lat = (bounds.north + bounds.south) / 2
        let lon = (bounds.east + bounds.west) / 2
        // (sud, ouest, nord, est, département)
        let boxes: [(Double, Double, Double, Double, String)] = [
            (14.35, -61.25, 14.95, -60.75, "972"),   // Martinique
            (15.75, -61.90, 16.60, -61.00, "971"),   // Guadeloupe
            (17.80, -63.25, 18.20, -62.75, "971"),   // Saint-Martin / Saint-Barthélemy
            (2.00, -54.70, 5.95, -51.45, "973"),     // Guyane
            (-21.45, 55.15, -20.85, 55.95, "974"),   // La Réunion
            (-13.10, 44.90, -12.55, 45.35, "976"),   // Mayotte
            (46.70, -56.50, 47.20, -56.00, "975")    // Saint-Pierre-et-Miquelon
        ]
        for (south, west, north, east, code) in boxes
        where lat >= south && lat <= north && lon >= west && lon <= east {
            return code
        }
        return nil
    }

    /// QA : reconstruit le snapshot en y plaçant de vraies photos publiques
    /// (vignettes + détail/like/commentaires réels) réparties autour du centre.
    static func snapshotInjectingQAPhotos(into snapshot: SocialMapSnapshot, around bounds: MapBounds) -> SocialMapSnapshot {
        let lat = (bounds.north + bounds.south) / 2
        let lon = (bounds.east + bounds.west) / 2
        let seeds: [(String, String)] = [
            ("cmqa1yaf40fne2fo5m3eucsd8", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215890861_thumb.webp"),
            ("cmqa1y8v30fna2fo5u3d9alkk", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215888538_thumb.webp"),
            ("cmqa1y6qs0fn62fo50yn9bx69", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215885580_thumb.webp"),
            ("cmqa1y4kd0fn22fo5ukn3xpdr", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215883100_thumb.webp")
        ]
        let offsets: [(Double, Double)] = [(0.004, 0.004), (-0.004, 0.005), (0.005, -0.004), (-0.005, -0.005)]
        let photos = zip(seeds, offsets).map { seed, off in
            SocialPhotoLive(
                id: seed.0, userId: nil, siteId: "615909",
                lat: lat + off.0, lng: lon + off.1,
                imageUrl: URL(string: seed.1), thumbnailUrl: URL(string: seed.1),
                uploadedAt: Date(), description: "Photo d'antenne (QA)"
            )
        }
        return SocialMapSnapshot(
            timestamp: snapshot.timestamp, friends: snapshot.friends, photos: photos,
            validations: snapshot.validations, sessions: snapshot.sessions,
            coveragePoints: snapshot.coveragePoints, speedtests: snapshot.speedtests,
            photosCount: photos.count, validationsCount: snapshot.validationsCount,
            sessionsCount: snapshot.sessionsCount, coveragePointsCount: snapshot.coveragePointsCount,
            speedtestsCount: snapshot.speedtestsCount, rawCoveragePointsCount: snapshot.rawCoveragePointsCount,
            logicalCoveragePointsCount: snapshot.logicalCoveragePointsCount
        )
    }

    // MARK: Changement automatique de marché (caméra idle)

    /// Appelé à chaque fin de déplacement caméra. Debounce 600 ms puis
    /// résolution du marché sous le centre de la carte.
    func scheduleMarketDetection(center: CLLocationCoordinate2D) {
        MessageSyncLog.logger.debug("market detect schedule lat=\(center.latitude, privacy: .private) lng=\(center.longitude, privacy: .private)")
        marketDetectionTask?.cancel()
        marketDetectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.detectMarket(at: center)
        }
    }

    /// À consommer dans `.onChangeCompat(of: marketFilter)` : vrai si le changement
    /// vient du switch automatique (la caméra ne doit alors pas bouger).
    func consumeAutoMarketSwitch() -> Bool {
        defer { autoMarketSwitchInProgress = false }
        return autoMarketSwitchInProgress
    }

    private func detectMarket(at center: CLLocationCoordinate2D) async {
        // Hysteresis France : tant que le centre reste dans la zone tampon
        // (métropole + Corse), on ne quitte pas FR.
        if marketFilter.uppercased() == "FR",
           marketsService.franceHysteresisContains(latitude: center.latitude, longitude: center.longitude) {
            pendingAutoMarketCode = nil
            return
        }
        guard let entry = await marketsService.marketForLocation(latitude: center.latitude, longitude: center.longitude) else {
            MessageSyncLog.logger.debug("market detect: aucun marché à lat=\(center.latitude, privacy: .private) lng=\(center.longitude, privacy: .private)")
            pendingAutoMarketCode = nil
            return
        }
        let code = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        MessageSyncLog.logger.debug("market detect: \(code, privacy: .public) (courant \(self.marketFilter, privacy: .public))")
        guard code.uppercased() != marketFilter.uppercased() else {
            pendingAutoMarketCode = nil
            return
        }
        // Stabilité : deux détections du même marché espacées dans le temps.
        // La seconde est auto-planifiée — un pan unique qui s'arrête sur un
        // autre pays doit suffire, sans attendre un nouvel événement caméra.
        guard pendingAutoMarketCode?.uppercased() == code.uppercased() else {
            pendingAutoMarketCode = code
            marketDetectionTask?.cancel()
            marketDetectionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await self?.detectMarket(at: center)
            }
            return
        }
        pendingAutoMarketCode = nil
        applyAutoMarketSwitch(to: entry, code: code)
    }

    private func applyAutoMarketSwitch(to entry: MarketRegistryEntry, code: String) {
        autoMarketSwitchInProgress = true
        currentMarketEntry = entry
        operatorFilter = Self.defaultOperatorKey(for: entry)
        marketFilter = code
        showMarketNotice("Marché : \(entry.label)")
    }

    private func showMarketNotice(_ text: String) {
        noticeTask?.cancel()
        marketSwitchNotice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.marketSwitchNotice = nil
        }
    }

    func load(region: MKCoordinateRegion, zoom: Double, filters: Set<MapDisplayItem.Kind>, lightweight: Bool = true) async {
        let bounds = MapBounds(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        await load(bounds: bounds, zoom: zoom, filters: filters, lightweight: lightweight)
    }

    func load(bounds: MapBounds, zoom: Double, filters: Set<MapDisplayItem.Kind>, lightweight: Bool = true) async {
        if AppEnvironment.usesDemoData {
            snapshot = .demo
            // QA (DEBUG) : injecte de vraies photos géolocalisées même en démo pour
            // visualiser/capturer le rendu de la couche Photos (publicPhotos).
            if ProcessInfo.processInfo.arguments.contains("--qa-demo-photos") {
                snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
                publicPhotos = Self.demoPublicPhotos(around: bounds)
            }
            errorMessage = nil
            dataVersion &+= 1
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Couches de carte indépendantes : chargées EN PARALLÈLE (async let) au
        // lieu d'enchaîner ~7 allers-retours en série. La latence perçue passe de
        // la SOMME des couches au MAX d'une seule (cf. audit SCALABILITY-02). Les
        // services sont Sendable ; on capture les entrées (immuables pendant le
        // chargement) dans des constantes locales pour l'usage concurrent, et on
        // garde les transformations isolées MainActor (Self.antennas…) APRÈS le await.
        let svc = mapService
        let antennasSvc = antennasService
        let market = marketFilter
        let op = operatorFilter
        let techs = techFilters
        let bands = bandFilters
        let sharing = sharingFilters
        let includeObserved = includeObservedSites
        let stDays = speedtestDays
        let covDays = coverageDays
        let communityOnly = isCommunityOnlyMarket
        let supportsCommunity = supportsCommunityLayers

        let wantsAntenna = filters.contains(.antenna) && !communityOnly
        let wantsCommunitySites = (filters.contains(.communitySite) || (communityOnly && filters.contains(.antenna))) && supportsCommunity
        let wantsSpeedtest = filters.contains(.speedtest)
        // Sites prévisionnels et pannes : FR métropole ET DROM (le backend répond
        // pour FR/DROM). En DROM on déduit le territoire (974, 971…) du centre du
        // viewport pour la résolution opérateur par île, comme le sélecteur web.
        let supportsPlannedOutage = ["FR", "DROM"].contains(market.uppercased())
        let territory = market.uppercased() == "DROM" ? Self.dromTerritory(for: bounds) : nil
        let wantsPlanned = filters.contains(.planned) && supportsPlannedOutage
        let wantsOutage = filters.contains(.outage) && supportsPlannedOutage
        let wantsCoverage = filters.contains(.coverage)

        // Photos : couche dédiée `/api/map/photos` (TOUS les membres), filtrée par
        // opérateur de la photo + mode « Amis » (= filtre `.friend` actif).
        let wantsPhoto = filters.contains(.photo)
        let photosFriendsOnly = filters.contains(.friend)
        // Le snapshot « lightweight » omet validations/sessions (perf). On ne charge
        // le snapshot COMPLET que pour ces couches (les photos ont leur endpoint).
        let needsHeavySnapshot = filters.contains(.validation) || filters.contains(.session)
        let snapshotLightweight = lightweight && !needsHeavySnapshot
        async let snapshotResult: (snapshot: SocialMapSnapshot?, error: String?) = {
            do { return (try await svc.snapshot(bounds: bounds, zoom: zoom, lightweight: snapshotLightweight), nil) }
            catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        // tiles non-nil → tuiles disponibles ; tiles nil → repli sur la liste bbox.
        async let antennaRaw: (tiles: [AndroidAntennaTileResponse]?, list: [AntennaSite]) = {
            guard wantsAntenna else { return (nil, []) }
            let usesAdvancedAntennaFilters = !techs.isEmpty || !bands.isEmpty || !sharing.isEmpty
            if !usesAdvancedAntennaFilters,
               let tiles = try? await svc.antennaTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, withAzimuth: true, bands: bands) {
                return (tiles, [])
            }
            let list = (try? await antennasSvc.list(bbox: bounds.asBoundingBox, market: market, operatorName: op, technologies: techs, bands: bands, sharing: sharing)) ?? []
            return (nil, list)
        }()
        async let communityRaw: [AndroidCommunitySiteTileResponse] = {
            guard wantsCommunitySites else { return [] }
            return (try? await svc.communitySiteTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, includeObserved: includeObserved, bands: bands)) ?? []
        }()
        async let speedtestRaw: [AndroidSpeedtestTileResponse] = {
            guard wantsSpeedtest else { return [] }
            return (try? await svc.speedtestTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: stDays, bands: bands)) ?? []
        }()
        // Prévisionnels & pannes : respectent le filtre opérateur de la carte
        // (l'opérateur sélectionné `op`, ou ALL quand « Tous » est choisi). Le
        // backend FR accepte ALL comme un opérateur précis.
        async let plannedRaw: [PlannedSiteLive] = {
            guard wantsPlanned else { return [] }
            return ((try? await svc.plannedSites(market: market, operatorName: op, territory: territory, bands: bands)) ?? []).filter { bounds.contains(lat: $0.lat, lon: $0.lon) }
        }()
        async let outageRaw: [OutageSiteLive] = {
            guard wantsOutage else { return [] }
            return ((try? await svc.outageSites(market: market, operatorName: op, territory: territory, bands: bands)) ?? []).filter { bounds.contains(lat: $0.lat, lon: $0.lon) }
        }()
        async let coverageRaw: (tiles: [AndroidCoverageTileResponse], heat: [CoverageHeatPoint]) = {
            guard wantsCoverage else { return ([], []) }
            let tiles = (try? await svc.coverageTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: covDays, bands: bands)) ?? []
            if tiles.isEmpty {
                let points = (try? await svc.coveragePoints(bounds: bounds, market: market, operatorName: op, technology: techs.sorted().first, bands: bands)) ?? []
                return ([], points)
            }
            return (tiles, [])
        }()
        async let photosRaw: [MapPublicPhoto] = {
            guard wantsPhoto else { return [] }
            // Couche communautaire : on veut TOUTES les photos des membres, quel que
            // soit le filtre opérateur des antennes → opérateur forcé à "ALL". Seul le
            // mode « Amis » restreint l'ensemble.
            return (try? await svc.publicPhotos(bounds: bounds, zoom: zoom, market: market, operatorName: "ALL", friendsOnly: photosFriendsOnly)) ?? []
        }()

        // --- On attend TOUS les résultats AVANT d'assigner ---
        let snap = await snapshotResult
        let antenna = await antennaRaw
        let community = await communityRaw
        let speedtest = await speedtestRaw
        let planned = await plannedRaw
        let outage = await outageRaw
        let coverage = await coverageRaw
        let photos = await photosRaw

        // Chargement REMPLACÉ (pan / changement de filtre / d'onglet suivant) : on
        // conserve les données déjà à l'écran au lieu de tout effacer et d'afficher
        // une erreur « Requête annulée ». (Régression du chargement parallèle.)
        if Task.isCancelled { return }

        if let value = snap.snapshot {
            snapshot = value
        } else if let error = snap.error {
            errorMessage = error
            snapshot = .empty
        }
        // QA (DEBUG) : injecte de vraies photos publiques géolocalisées pour
        // vérifier le rendu des vignettes + le viewer.
        if ProcessInfo.processInfo.arguments.contains("--qa-demo-photos") {
            snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
        }

        if let tiles = antenna.tiles {
            antennaClusters = tiles.flatMap(\.clusters)
            antennas = Self.antennas(from: tiles).filter(\.hasValidCoordinate)
        } else {
            antennaClusters = []
            antennas = antenna.list.filter(\.hasValidCoordinate)
        }

        communitySiteTiles = community
        speedtestTiles = speedtest
        plannedSites = planned
        outages = outage
        coverageTiles = coverage.tiles
        coverageHeat = coverage.heat
        // QA (DEBUG) : injecte des photos publiques de démo pour visualiser la
        // couche (le compte de test n'a pas forcément de photos géolocalisées).
        if ProcessInfo.processInfo.arguments.contains("--qa-demo-photos") {
            publicPhotos = Self.demoPublicPhotos(around: bounds)
        } else {
            publicPhotos = photos
        }
        dataVersion &+= 1
    }

    /// Photos publiques de démonstration (QA) réparties autour du viewport.
    static func demoPublicPhotos(around bounds: MapBounds) -> [MapPublicPhoto] {
        let lat = (bounds.north + bounds.south) / 2
        let lon = (bounds.east + bounds.west) / 2
        let seeds: [(String, String)] = [
            ("cmqa1yaf40fne2fo5m3eucsd8", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215890861_thumb.webp"),
            ("cmqa1y8v30fna2fo5u3d9alkk", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215888538_thumb.webp"),
            ("cmqa1y6qs0fn62fo50yn9bx69", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215885580_thumb.webp"),
            ("cmqa1y4kd0fn22fo5ukn3xpdr", "https://s3.signalquest.fr/photos/thumbnails/615909_1781215883100_thumb.webp")
        ]
        let offsets: [(Double, Double)] = [(0.004, 0.004), (-0.004, 0.005), (0.005, -0.004), (-0.005, -0.005)]
        return zip(seeds, offsets).map { seed, off in
            MapPublicPhoto(
                id: seed.0, siteId: "615909",
                lat: lat + off.0, lng: lon + off.1,
                thumbnailUrl: URL(string: seed.1), operator: "SFR",
                authorId: nil, uploadedAt: Date(), isFriend: false
            )
        }
    }

    func search() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        do {
            searchResults = try await antennasService.quickSearch(query: q)
        } catch {
            searchResults = []
        }
    }

    private static func antennas(from tiles: [AndroidAntennaTileResponse]) -> [AntennaSite] {
        var seen = Set<String>()
        return tiles.flatMap(\.markers).compactMap { marker -> AntennaSite? in
            let key = marker.supId ?? marker.anfrCode ?? marker.id
            guard seen.insert(key).inserted else { return nil }
            let operators = (marker.operators.isEmpty ? [marker.operator].compactMap { $0 } : marker.operators)
            var site = AntennaSite(
                id: marker.id,
                siteId: marker.supId ?? marker.anfrCode,
                anfrCode: marker.anfrCode,
                latitude: marker.lat,
                longitude: marker.lng,
                operators: operators,
                technologies: marker.technologies,
                bands: marker.bands,
                azimuths: marker.azimuts,
                sharingType: marker.sharingType ?? marker.zbLeader.map { "ZB \($0)" },
                crozonLeader: marker.crozonLeader,
                address: marker.address,
                height: nil,
                owner: marker.operator
            )
            site.photoCount = marker.photoCount
            site.validationCount = marker.validationCount
            return site
        }
    }
}

private extension MapBounds {
    var asBoundingBox: BoundingBox {
        BoundingBox(north: north, south: south, east: east, west: west)
    }

    func contains(lat: Double?, lon: Double?) -> Bool {
        guard let lat, let lon else { return false }
        return lat <= north && lat >= south && lon <= east && lon >= west
    }
}

private struct MapAnnotationPayload: Identifiable, Equatable {
    let id: String
    let kind: MapDisplayItem.Kind
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let metric: String?
    let backendId: String?
    let details: MapItemDetails?
    let antennaId: String?
    let clusterCount: Int?
    let azimuths: [Double]
    let showsAzimuths: Bool
    /// Couleur registry de l'opérateur ; prioritaire sur les heuristiques de
    /// `markerColor` quand elle est connue.
    var tint: Color? = nil
    /// Cellule communautaire seulement « observée » (vs site probable) : rendu
    /// plus translucide pour signaler une confiance moindre.
    var communityObserved: Bool = false
    /// Vignette à afficher directement sur la carte (couche Photos) : le marqueur
    /// devient une mini-photo « polaroïd » au lieu d'une pastille.
    var thumbnailURL: URL? = nil
    /// Statut d'activation d'un site prévisionnel : pilote l'anneau + le badge
    /// (actif ✓ / upgrade ↑ / déclaré / prévu).
    var plannedStatus: PlannedActivationStatus? = nil
    /// Glyphe SF Symbol forcé (ex. pannes colorées par type d'incident).
    var glyphOverride: String? = nil
    /// Nombre de photos publiques sur le site (antennes) → badge appareil-photo.
    var contributionPhotos: Int = 0

    static func == (lhs: MapAnnotationPayload, rhs: MapAnnotationPayload) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.metric == rhs.metric &&
        lhs.backendId == rhs.backendId &&
        lhs.details == rhs.details &&
        lhs.antennaId == rhs.antennaId &&
        lhs.clusterCount == rhs.clusterCount &&
        lhs.azimuths == rhs.azimuths &&
        lhs.showsAzimuths == rhs.showsAzimuths &&
        lhs.tint == rhs.tint &&
        lhs.communityObserved == rhs.communityObserved &&
        lhs.thumbnailURL == rhs.thumbnailURL &&
        lhs.plannedStatus == rhs.plannedStatus &&
        lhs.glyphOverride == rhs.glyphOverride &&
        lhs.contributionPhotos == rhs.contributionPhotos
    }
}

/// Point speedtest rendu en couche GPU (`MLNCircleStyleLayer`). Distinct des
/// annotations-vues : permet d'afficher TOUS les points (milliers) sans cluster
/// ni cap, coloré par débit — comportement identique à Android.
private struct SpeedtestFeature: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let downloadMbps: Double
    let uploadMbps: Double?
    let pingMs: Double?
    let tech: String?
    let band: Int?
    let frequency: String?
    let timestamp: Date?

    static func == (lhs: SpeedtestFeature, rhs: SpeedtestFeature) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.downloadMbps == rhs.downloadMbps &&
        lhs.uploadMbps == rhs.uploadMbps &&
        lhs.pingMs == rhs.pingMs &&
        lhs.tech == rhs.tech &&
        lhs.band == rhs.band &&
        lhs.frequency == rhs.frequency &&
        lhs.timestamp == rhs.timestamp
    }
}

/// Politique de rendu de la couche couverture selon le zoom (pure & testable).
/// Points bruts dès le « zoom ville » (~z11) ; clusters seulement au niveau région/pays.
/// Caps relevés pour ne plus tronquer les points (bug « points qui disparaissent au zoom »).
enum CoverageRenderPolicy {
    /// Zoom à partir duquel le CLIENT demande les points bruts (`detail=points`) ; en
    /// dessous, des clusters (`detail=overview`). « Zoom ville ». Seuil iOS uniquement —
    /// Android a sa propre constante (z13), qu'on ne touche pas.
    static let rawPointsFromZoom = 11
    /// Plafond de points bruts par tuile (= `limit` demandé au backend). Unifié quel que
    /// soit le zoom — fini la dégradation 900→250 qui masquait ~75 % des points au dézoom.
    static let pointCapPerTile = 2500
    /// Plafond du repli `/api/coverage/points` (bbox, sans tuiles).
    static let fallbackCap = 6000

    /// Rendu piloté par la DONNÉE reçue (robuste quel que soit le zoom / le seuil de
    /// fetch) : on affiche les points bruts s'il y en a (ou si un filtre bande est actif),
    /// sinon les clusters. Mutuellement exclusifs.
    static func mode(hasPoints: Bool, hasClusters: Bool, hasBandFilter: Bool) -> (useClusters: Bool, useRawPoints: Bool) {
        let useRawPoints = hasPoints || hasBandFilter
        let useClusters = hasClusters && !useRawPoints
        return (useClusters, useRawPoints)
    }
}

private struct CoverageHeatFeature: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let weight: Double
    /// Clé de regroupement GPU — une source/couche par clé (bande RSRP ou génération).
    let colorKey: String
    /// Couleur de la pastille (0xRRGGBB), figée selon le mode de coloration courant.
    let colorHex: UInt32
    /// Opacité réduite pour les bandes « inconnu » (RSRP) / « aucun » (génération).
    let dimmed: Bool

    static func == (lhs: CoverageHeatFeature, rhs: CoverageHeatFeature) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.weight == rhs.weight &&
        lhs.colorKey == rhs.colorKey &&
        lhs.colorHex == rhs.colorHex
    }
}

private enum CoverageQualityBand: String, CaseIterable, Identifiable {
    case excellent
    case good
    case fair
    case weak
    case poor
    case unknown

    var id: String { rawValue }

    static var visibleBands: [CoverageQualityBand] {
        [.excellent, .good, .fair, .weak, .poor]
    }

    // Seuils RSRP alignés sur le web (`lib/signal-quality.ts` RSRP_SCALE) :
    // ≥ -80 excellent · -90 bon · -100 moyen · -110 faible · sinon très faible.
    static func band(for rsrp: Double?) -> CoverageQualityBand {
        guard let rsrp else { return .unknown }
        switch rsrp {
        case (-80)...: return .excellent
        case -90..<(-80): return .good
        case -100..<(-90): return .fair
        case -110..<(-100): return .weak
        default: return .poor
        }
    }

    var title: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Bon"
        case .fair: return "Moyen"
        case .weak: return "Faible"
        case .poor: return "Très faible"
        case .unknown: return "Inconnu"
        }
    }

    /// Intervalle RSRP explicite (dBm) — l'unité est rappelée une fois dans le titre
    /// de la légende (TEL-MAP-01 : un seul nombre par bande était ambigu).
    var rangeLabel: String {
        switch self {
        case .excellent: return "≥ -80"
        case .good: return "-90 à -80"
        case .fair: return "-100 à -90"
        case .weak: return "-110 à -100"
        case .poor: return "< -110"
        case .unknown: return "n/a"
        }
    }

    // Couleurs QUALITY_HEX du web : #10b981 / #84cc16 / #f59e0b / #f97316 / #ef4444.
    var colorHex: UInt32 {
        switch self {
        case .excellent: return 0x10B981
        case .good: return 0x84CC16
        case .fair: return 0xF59E0B
        case .weak: return 0xF97316
        case .poor: return 0xEF4444
        case .unknown: return 0x94A3B8
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .excellent: return Color(hex: 0x10B981)
        case .good: return Color(hex: 0x84CC16)
        case .fair: return Color(hex: 0xF59E0B)
        case .weak: return Color(hex: 0xF97316)
        case .poor: return Color(hex: 0xEF4444)
        case .unknown: return Color(hex: 0x94A3B8)
        }
    }

#if canImport(MapLibre)
    var uiColor: UIColor {
        switch self {
        case .excellent: return UIColor(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255, alpha: 1.0)
        case .good: return UIColor(red: 0x84 / 255, green: 0xCC / 255, blue: 0x16 / 255, alpha: 1.0)
        case .fair: return UIColor(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1.0)
        case .weak: return UIColor(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1.0)
        case .poor: return UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1.0)
        case .unknown: return UIColor(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255, alpha: 1.0)
        }
    }
#endif
}

/// Bandes de GÉNÉRATION pour la couche couverture (mode « génération », distinct du
/// RSRP). Couleurs alignées sur la carte « Mes mesures » (SessionGenerationColor) :
/// 5G violet · 4G bleu · 3G teal · 2G ambre · gris (aucun/inconnu).
private enum CoverageGenerationBand: String, CaseIterable, Identifiable {
    case g5, g4, g3, g2, none

    var id: String { rawValue }

    static var visibleBands: [CoverageGenerationBand] { [.g5, .g4, .g3, .g2, .none] }

    static func band(for tech: String?) -> CoverageGenerationBand {
        let t = (tech ?? "").uppercased()
        if t.contains("5G") || t.contains("NR") { return .g5 }
        if t.contains("4G") || t.contains("LTE") { return .g4 }
        if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return .g3 }
        if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return .g2 }
        return .none
    }

    var title: String {
        switch self {
        case .g5: return "5G"
        case .g4: return "4G"
        case .g3: return "3G"
        case .g2: return "2G"
        case .none: return "Aucun"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .g5: return 0x8B5CF6
        case .g4: return 0x3B82F6
        case .g3: return 0x14B8A6
        case .g2: return 0xF59E0B
        case .none: return 0x94A3B8
        }
    }

    var swiftUIColor: Color { Color(hex: colorHex) }
}

/// Paliers de débit descendant pour colorer la couche GPU des speedtests —
/// échelle identique au web (`speedColorUtils.ts`) et à Android : rouge → orange
/// → jaune → vert clair → vert → cyan → bleu.
private enum SpeedBand: String, CaseIterable {
    case verySlow
    case slow
    case medium
    case good
    case veryGood
    case excellent
    case exceptional

    static func band(forDownload mbps: Double) -> SpeedBand {
        switch mbps {
        case 1000...:    return .exceptional
        case 600..<1000: return .excellent
        case 300..<600:  return .veryGood
        case 100..<300:  return .good
        case 30..<100:   return .medium
        case 10..<30:    return .slow
        default:         return .verySlow
        }
    }

#if canImport(MapLibre)
    var uiColor: UIColor {
        switch self {
        case .exceptional: return UIColor(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1.0)
        case .excellent:   return UIColor(red: 0x06 / 255, green: 0xB6 / 255, blue: 0xD4 / 255, alpha: 1.0)
        case .veryGood:    return UIColor(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255, alpha: 1.0)
        case .good:        return UIColor(red: 0x84 / 255, green: 0xCC / 255, blue: 0x16 / 255, alpha: 1.0)
        case .medium:      return UIColor(red: 0xEA / 255, green: 0xB3 / 255, blue: 0x08 / 255, alpha: 1.0)
        case .slow:        return UIColor(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1.0)
        case .verySlow:    return UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1.0)
        }
    }
#endif
}

/// Persists the last viewed map region so the app reopens where the user left
/// off instead of a fixed location. (UserDefaults use is declared in
/// PrivacyInfo.xcprivacy under reason CA92.1.)
private enum MapRegionStore {
    private static let key = "map.lastRegion.v1"

    /// Efface la région mémorisée (QA `--reset-map` : repart sur la France).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func save(_ region: MKCoordinateRegion) {
        guard region.center.latitude.isFinite, region.center.longitude.isFinite,
              region.span.longitudeDelta > 0, region.span.latitudeDelta > 0 else { return }
        UserDefaults.standard.set([
            "lat": region.center.latitude,
            "lon": region.center.longitude,
            "latD": region.span.latitudeDelta,
            "lonD": region.span.longitudeDelta
        ], forKey: key)
    }

    static func lastRegion() -> MKCoordinateRegion? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let lat = dict["lat"], let lon = dict["lon"],
              let latD = dict["latD"], let lonD = dict["lonD"],
              lat.isFinite, lon.isFinite, latD > 0, lonD > 0 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: latD, longitudeDelta: lonD)
        )
    }
}

/// Persiste le dernier marché + opérateur sélectionnés sur la carte, pour rouvrir
/// sur le choix de l'utilisateur plutôt que sur un défaut codé en dur (France).
/// (UserDefaults déclaré dans PrivacyInfo.xcprivacy sous la raison CA92.1.)
/// Internal (pas `private`) : réutilisé par le mode Drive Test pour cibler le bon
/// marché lors du chargement des antennes proches.
/// Persistance locale des couches actives de la carte (mémorisées entre navigations /
/// relances). Défaut : antennes seule — l'utilisateur active le reste à la demande.
enum MapFilterStore {
    private static let key = "map.lastFilters.v1"

    /// Couches par défaut : antennes seule.
    static let defaultFilters: Set<MapDisplayItem.Kind> = [.antenna]

    static func save(_ filters: Set<MapDisplayItem.Kind>) {
        UserDefaults.standard.set(filters.map(\.rawValue), forKey: key)
    }

    /// Couches mémorisées (éventuellement vide si tout désactivé), ou `nil` si jamais
    /// enregistrées → l'appelant retombe sur `defaultFilters`.
    static func lastFilters() -> Set<MapDisplayItem.Kind>? {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return nil }
        return Set(raw.compactMap(MapDisplayItem.Kind.init(rawValue:)))
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

enum MapMarketStore {
    private static let marketKey = "map.lastMarket.v1"
    private static let operatorKey = "map.lastOperator.v1"

    /// QA `--reset-map` : oublie le marché/opérateur pour rejouer la détection.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: marketKey)
        UserDefaults.standard.removeObject(forKey: operatorKey)
    }

    static func save(market: String, operator op: String) {
        let market = market.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !market.isEmpty else { return }
        UserDefaults.standard.set(market, forKey: marketKey)
        let op = op.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(op.isEmpty ? "ALL" : op, forKey: operatorKey)
    }

    static func lastMarket() -> String? {
        guard let value = UserDefaults.standard.string(forKey: marketKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func lastOperator() -> String? {
        guard let value = UserDefaults.standard.string(forKey: operatorKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Code marché utilisable AVANT le chargement du registre (init synchrone) :
    /// dernier choix persisté, sinon pays de la locale appareil, sinon "FR".
    static func initialMarketCode() -> String { lastMarket() ?? localeMarketCode() }

    static func initialOperatorKey() -> String { lastOperator() ?? "ALL" }

    /// Pays de la locale appareil (ISO, ex. "FR" / "CA"). Repli "FR" si absent —
    /// jamais affiché tel quel : la détection registre le corrige juste après.
    static func localeMarketCode() -> String {
        Locale.current.region?.identifier.uppercased() ?? "FR"
    }
}

struct MapExplorerView: View {
    @StateObject private var model: MapExplorerViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Carte SwiftUI de secours (jamais compilée tant que MapLibre est présent).
#if !canImport(MapLibre)
    @State private var position: MapCameraPosition
#endif
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var mapZoom: Double
    // Cache des couches lourdes de la carte : reconstruit uniquement quand les
    // données (`model.dataVersion`) ou les couches actives (`filters`) changent,
    // pour ne plus recalculer des milliers de structs à chaque invalidation de `body`.
    @State private var renderedAnnotations: [MapAnnotationPayload] = []
    @State private var renderedCoverageFeatures: [CoverageHeatFeature] = []
    @State private var renderedSpeedtestFeatures: [SpeedtestFeature] = []
    // Couches mémorisées localement (restaurées entre navigations / relances). Défaut :
    // antennes seule — l'utilisateur active les autres couches à la demande.
    @State private var filters: Set<MapDisplayItem.Kind> = MapFilterStore.lastFilters() ?? MapFilterStore.defaultFilters
    /// Couche Couverture : coloration par génération (5G/4G/…) plutôt que par RSRP.
    /// Persisté localement. Modes mutuellement exclusifs (jamais mélangés).
    @AppStorage("map_coverage_by_generation") private var coverageByGeneration = false
    @State private var selectedItem: MapDisplayItem?
    @State private var selectedAntenna: AntennaSite?
    @State private var selectedPhoto: MapPhotoTarget?
    @State private var selectedOutage: OutageSiteLive?
    @State private var selectedPlanned: PlannedSiteLive?
    @State private var fetchTask: Task<Void, Never>?
    @State private var lastRegion: MKCoordinateRegion
    @State private var showFilterSheet = false

    init(service: MapSnapshotServicing = MapSnapshotService(api: APIClient()),
         antennas: AntennasServicing = AntennasService(api: APIClient()),
         markets: MarketRegistryServicing = MarketRegistryService(api: APIClient())) {
        _model = StateObject(wrappedValue: MapExplorerViewModel(map: service, antennas: antennas, markets: markets))
        // QA : `--reset-map` oublie région + marché/opérateur pour rejouer la détection.
        if ProcessInfo.processInfo.arguments.contains("--reset-map") {
            MapRegionStore.reset()
            MapMarketStore.reset()
        }
        // Restaure la dernière région, sinon vue pays du marché initial (dernier
        // choix persisté ou pays de la locale) — jamais une ville ni la France imposée.
        let region = MapRegionStore.lastRegion() ?? Self.region(for: MapMarketStore.initialMarketCode())
#if !canImport(MapLibre)
        _position = State(initialValue: .region(region))
#endif
        _mapCenter = State(initialValue: region.center)
        _lastRegion = State(initialValue: region)
        _mapZoom = State(initialValue: Self.zoom(forSpan: region))
    }

    var body: some View {
        ZStack {
            mapLayer
            controlsLayer
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedItem) { item in MapItemSheet(item: item) }
        .sheet(item: $selectedOutage) { site in
            OutageDetailSheet(site: site)
        }
        .sheet(item: $selectedPlanned) { site in
            PlannedDetailSheet(site: site, operatorLabel: model.operatorLabel(site.operator ?? "ALL"), operatorAccent: model.operatorAccent(site.operator ?? "ALL"))
        }
        .sheet(item: $selectedAntenna) { site in
            AntennaDetailSheet(site: site, market: model.marketFilter, operatorName: model.operatorFilter, service: services.antennas)
        }
        .fullScreenCover(item: $selectedPhoto) { target in
            MapPhotoViewer(
                photoId: target.id,
                initialThumbnailURL: target.thumbnailURL,
                service: services.photos,
                operatorAccent: { model.operatorAccent($0) }
            )
        }
        .sheet(isPresented: $showFilterSheet) {
            MapAdvancedFilterSheet(
                market: $model.marketFilter,
                operatorName: $model.operatorFilter,
                technologies: $model.techFilters,
                bands: $model.bandFilters,
                sharing: $model.sharingFilters,
                speedtestDays: $model.speedtestDays,
                coverageDays: $model.coverageDays,
                layers: $filters,
                includeObserved: $model.includeObservedSites,
                allMarkets: model.registryMarkets
            )
            .presentationDetents([.medium, .large])
            .presentationBackgroundCompat(SQColor.bg)
        }
        .task {
            // QA (DEBUG) : pré-active les couches pour capturer leurs couleurs.
            if ProcessInfo.processInfo.arguments.contains("--qa-map-layers") {
                filters = [.antenna, .speedtest, .coverage]
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-demo-photos") {
                filters = [.photo]
            }
            await model.loadRegistry()
            // Sélection auto du marché + opérateur (SIM/GPS/locale) AVANT le 1er
            // chargement : évite le flash « France/SFR puis Canada/Bell ».
            await model.resolveInitialSelection(
                networkPath: services.networkPath,
                networkOperator: services.networkOperator,
                location: services.location
            )
            // 1er lancement sans région mémorisée : recentre sur le marché résolu.
            if MapRegionStore.lastRegion() == nil {
                let region = region(forMarketCode: model.marketFilter)
                mapCenter = region.center
                mapZoom = Self.zoom(forSpan: region)
#if !canImport(MapLibre)
                position = .region(region)
#endif
                lastRegion = region
            }
            await model.load(region: lastRegion, zoom: mapZoom, filters: filters)
            model.endInitialSelection()
            refreshMapRender()
            await runQAPanIfRequested()
            // QA (DEBUG) : ouvre la fiche de la première antenne (attend que le
            // niveau de zoom fasse apparaître des antennes individuelles).
            if ProcessInfo.processInfo.arguments.contains("--qa-open-antenna") {
                for _ in 0..<16 {
                    if let first = model.antennas.first { selectedAntenna = first; break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // QA (DEBUG) : ouvre le viewer de la première photo injectée.
            if ProcessInfo.processInfo.arguments.contains("--qa-open-photo") {
                for _ in 0..<16 {
                    if let first = model.publicPhotos.first {
                        selectedPhoto = MapPhotoTarget(id: first.id, thumbnailURL: first.thumbnailUrl)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // Notification/deep link antenne reçu avant l'apparition de la carte.
            openSiteFromRouterIfNeeded()
        }
        .onChangeCompat(of: filters) { _, newValue in
            // Mémorise les couches localement (restaurées au prochain affichage / relance).
            MapFilterStore.save(newValue)
            // Affiche/masque une couche immédiatement, sans attendre le rechargement.
            refreshMapRender()
            scheduleLoad(region: lastRegion)
        }
        .onChangeCompat(of: coverageByGeneration) { _, _ in
            // Bascule Signal ↔ Génération : recolore la couche sans recharger le réseau.
            refreshMapRender()
        }
        .onChangeCompat(of: model.marketFilter) { _, newValue in
            // Pendant la sélection initiale, le `.task` pilote recentrage + load.
            guard !model.initialSelectionInProgress else { return }
            // Le switch automatique (caméra) et le picker manuel partagent ce
            // binding mais pas le même chemin : seul le manuel recentre.
            let isAutoSwitch = model.consumeAutoMarketSwitch()
            Task { await model.alignWithMarket(code: newValue, resetOperator: false) }
            if isAutoSwitch {
                scheduleLoad(region: lastRegion)
            } else {
                // Recentre on the selected market so its data is actually in view
                // (a market switch from France must not leave the camera over France).
                let region = region(forMarketCode: newValue)
                mapCenter = region.center
                mapZoom = Self.zoom(forSpan: region)
#if !canImport(MapLibre)
                position = .region(region)
#endif
                scheduleLoad(region: region)
            }
            MapMarketStore.save(market: model.marketFilter, operator: model.operatorFilter)
        }
        .onChangeCompat(of: model.operatorFilter) { _, _ in
            guard !model.initialSelectionInProgress else { return }
            scheduleLoad(region: lastRegion)
            MapMarketStore.save(market: model.marketFilter, operator: model.operatorFilter)
        }
        .onChangeCompat(of: model.techFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChangeCompat(of: model.bandFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChangeCompat(of: model.sharingFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChangeCompat(of: model.includeObservedSites) { _, _ in scheduleLoad(region: lastRegion) }
        // Données rechargées → reconstruit le cache des couches une seule fois.
        .onChangeCompat(of: model.dataVersion) { _, _ in refreshMapRender() }
        // Le zoom modifie les seuils (azimuts ≥ 14, clustering) : reconstruit aussi.
        .onChangeCompat(of: mapZoom) { _, _ in refreshMapRender() }
        // Notification/deep link antenne : ouvre la fiche du site demandé.
        .onChangeCompat(of: router.openSiteId) { _, _ in openSiteFromRouterIfNeeded() }
    }

    @ViewBuilder
    private var mapLayer: some View {
#if canImport(MapLibre)
        // Migration moteur unique : rendu MapKit (Apple Plan natif). Même interface
        // que l'ancien SQMapLibreMapView (mêmes payloads).
        MapKitMapView(
            annotations: renderedAnnotations,
            coverageHeatFeatures: renderedCoverageFeatures,
            speedtestFeatures: renderedSpeedtestFeatures,
            colorScheme: colorScheme,
            center: $mapCenter,
            zoom: $mapZoom,
            onMoveEnd: { bounds, zoom in
                let region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: (bounds.north + bounds.south) / 2,
                        longitude: (bounds.east + bounds.west) / 2
                    ),
                    span: MKCoordinateSpan(
                        latitudeDelta: abs(bounds.north - bounds.south),
                        longitudeDelta: abs(bounds.east - bounds.west)
                    )
                )
                lastRegion = region
                model.scheduleMarketDetection(center: region.center)
                scheduleLoad(bounds: bounds, zoom: zoom)
            },
            onSelect: selectAnnotation
        )
        .ignoresSafeArea(edges: .bottom)
#else
        Map(position: $position) {
            ForEach(renderedAnnotations) { item in
                Annotation(item.title, coordinate: item.coordinate) {
                    Button {
                        Haptics.light()
                        selectAnnotation(item)
                    } label: {
                        annotation(for: item.kind)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.publicTransport])))
        .ignoresSafeArea(edges: .bottom)
        .onMapCameraChange(frequency: .onEnd) { context in
            model.scheduleMarketDetection(center: context.region.center)
            scheduleLoad(region: context.region)
        }
#endif
    }

    /// Hook QA (DEBUG) : `SQ_QA_PAN_TO="lat,lng[,zoom]"` déplace la caméra
    /// après stabilisation, comme la fin d'un pan utilisateur — le delegate
    /// MapLibre déclenche alors la chaîne réelle de détection de marché.
    private func runQAPanIfRequested() async {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["SQ_QA_PAN_TO"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return }
        try? await Task.sleep(for: .seconds(4))
        if parts.count >= 3 { mapZoom = parts[2] }
        mapCenter = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        #endif
    }

    /// Caméra par défaut d'un marché : centre/zoom du registre quand ils sont
    /// connus, sinon les valeurs statiques historiques.
    private func region(forMarketCode code: String) -> MKCoordinateRegion {
        if let entry = model.registryMarket(forCode: code),
           let lat = entry.defaultCenterLatitude,
           let lng = entry.defaultCenterLongitude {
            let zoom = entry.defaultMapZoom ?? 6
            let lonDelta = min(300.0, max(0.01, 360 / pow(2, zoom)))
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                span: MKCoordinateSpan(
                    latitudeDelta: min(120.0, lonDelta * 0.8),
                    longitudeDelta: lonDelta
                )
            )
        }
        return Self.region(for: code)
    }

    private var controlsLayer: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: SQSpace.sm + 2) {
                    mapTopControlBar
                    if filters.contains(.coverage) {
                        coverageColoringToggle
                        if coverageByGeneration {
                            coverageGenerationLegend
                        } else {
                            coverageQualityLegend
                        }
                    }
                    if !model.searchResults.isEmpty {
                        searchSuggestions
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.top, SQSpace.sm)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Bas-gauche : sélecteur d'opérateur compact + statut.
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            mapStatusToast
                            operatorPill
                        }
                        Spacer()
                    }
                    .padding(.leading, SQSpace.md)
                    .padding(.bottom, SQSpace.lg + 2)
                }

                // Bas-droite : 2 boutons flottants (localiser + rafraîchir).
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        mapFabStack
                    }
                    .padding(.trailing, SQSpace.md)
                    .padding(.bottom, SQSpace.lg + 2)
                }

                if model.isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                            .tint(SQColor.brandRed)
                            .padding(SQSpace.md)
                            .background(SQColor.surface, in: Circle())
                            .overlay { Circle().stroke(SQColor.separator, lineWidth: 1.5) }
                            .shadow(color: mapChromeShadow, radius: 12, y: 5)
                            .padding(.bottom, 18)
                    }
                }

                marketSwitchNoticeOverlay
            }
        }
    }

    /// Bandeau discret « Marché : X » affiché 2 s après un switch automatique :
    /// surface plate bordée, kicker rouge + libellé Archivo, point rouge.
    private var marketSwitchNoticeOverlay: some View {
        VStack {
            if let notice = model.marketSwitchNotice {
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Marché").sqKicker()
                        Text(noticeValue(notice))
                            .font(SQFont.archivo(15, .bold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, SQSpace.md + 2)
                .padding(.vertical, SQSpace.sm + 1)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay { mapChromeBorder(SQRadius.md, strong: true) }
                .shadow(color: mapChromeShadow, radius: 14, y: 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 124)
        .animation(SQMotion.resolve(SQMotion.snappy, reduceMotion), value: model.marketSwitchNotice)
        .allowsHitTesting(false)
    }

    /// Extrait le libellé du marché du message « Marché : X » pour l'afficher
    /// sous le kicker (sans dupliquer le préfixe).
    private func noticeValue(_ notice: String) -> String {
        guard let range = notice.range(of: ":") else { return notice }
        return String(notice[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private var mapTopControlBar: some View {
        HStack(spacing: SQSpace.sm) {
            mapSearchField
            filterButton
        }
        .padding(SQSpace.xs + 1)
        .frame(height: 58)
        .foregroundStyle(SQColor.label)
        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.lg) }
        .shadow(color: mapChromeShadow, radius: 14, y: 6)
    }

    /// Champ de recherche net : loupe rouge, fond surface contrasté, coin net.
    private var mapSearchField: some View {
        HStack(spacing: SQSpace.sm - 1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(SQColor.brandRed)
            TextField("Rechercher", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(SQFont.body(15, .medium))
                .foregroundStyle(SQColor.label)
                .submitLabel(.search)
                .onSubmit { Task { await model.search() } }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    model.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 48)
        .padding(.horizontal, SQSpace.md - 1)
        .background(mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.md) }
    }

    private var filterButton: some View {
        Button {
            Haptics.light()
            showFilterSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay { mapChromeBorder(SQRadius.md) }
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(SQFont.archivo(10, .bold))
                        .frame(minWidth: 17, minHeight: 17)
                        .background(SQColor.brandRed, in: Circle())
                        .foregroundStyle(.white)
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Calques et filtres")
    }

    /// Sélecteur d'opérateur compact (bas-gauche) : menu des opérateurs du marché
    /// courant. Remplace la bande d'opérateurs permanente (désencombrement).
    private var operatorPill: some View {
        Menu {
            ForEach(model.operatorOptions, id: \.self) { op in
                Button {
                    Haptics.selection()
                    model.operatorFilter = op
                } label: {
                    Label(
                        model.operatorShortLabel(op),
                        systemImage: model.operatorFilter == op ? "checkmark"
                            : (op.uppercased() == "ALL" ? "circle.grid.2x2" : "dot.radiowaves.left.and.right")
                    )
                }
            }
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Circle()
                    .fill(model.operatorFilter.uppercased() == "ALL" ? SQColor.brandRed : model.operatorAccent(model.operatorFilter))
                    .frame(width: 9, height: 9)
                Text(model.operatorShortLabel(model.operatorFilter))
                    .font(SQFont.archivo(14, .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .padding(.horizontal, SQSpace.md - 2)
            .frame(height: 42)
            .foregroundStyle(SQColor.label)
            .background(mapChromeBackground, in: Capsule())
            .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1.5) }
            .shadow(color: mapChromeShadow, radius: 12, y: 5)
        }
        .accessibilityLabel("Opérateur affiché : \(model.operatorShortLabel(model.operatorFilter))")
    }

    /// Pile de 2 boutons flottants (bas-droite) : recentrage GPS + rafraîchissement.
    /// Remplace le rail de 4 boutons + les panneaux flottants (désencombrement).
    private var mapFabStack: some View {
        VStack(spacing: SQSpace.sm) {
            mapFab(icon: "location", label: "Recentrer sur ma position") {
                centerOnCurrentLocation()
            }
            mapFab(icon: "arrow.clockwise", label: "Rafraîchir la carte") {
                scheduleLoad(region: lastRegion)
            }
        }
    }

    private func mapFab(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 48, height: 48)
                .foregroundStyle(SQColor.label)
                .background(mapChromeBackground, in: Circle())
                .overlay { Circle().stroke(SQColor.separator, lineWidth: 1.5) }
                .shadow(color: mapChromeShadow, radius: 12, y: 5)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Chrome éditorial (à plat, opaque, bordé — pas de glassmorphism)

    /// Conteneur des contrôles superposés : surface opaque crème/encre, jamais
    /// translucide, pour rester lisible par-dessus la carte.
    private var mapChromeBackground: AnyShapeStyle { AnyShapeStyle(SQColor.surface) }

    /// Remplissage des contrôles internes (champ recherche, boutons) : surface
    /// légèrement contrastée du conteneur.
    private var mapControlFill: Color { SQColor.fill }

    /// Pastille discrète (légende, tags hors conteneur) posée à même la carte.
    private var mapSubtlePillFill: Color { SQColor.surface }

    /// Ombre éditoriale très légère (la profondeur vient surtout de la bordure).
    private var mapChromeShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.30 : 0.10)
    }

    /// Bordure fine encre/separator commune à tous les conteneurs de la carte.
    @ViewBuilder
    private func mapChromeBorder(_ radius: CGFloat, strong: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(strong ? SQColor.label : SQColor.separator, lineWidth: strong ? 2 : 1.5)
    }

    @ViewBuilder
    private var mapStatusToast: some View {
        if let error = model.errorMessage {
            mapToast(error, icon: "exclamationmark.triangle.fill", tint: SQColor.warning)
        } else if renderedAnnotations.isEmpty && renderedCoverageFeatures.isEmpty && !model.isLoading {
            mapToast("Aucune donnée dans cette zone", icon: "map", tint: SQColor.labelSecondary)
        }
    }

    private func mapToast(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: SQSpace.sm - 1) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(SQFont.archivo(13, .semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
        }
        .padding(.horizontal, SQSpace.md - 1)
        .padding(.vertical, SQSpace.sm + 1)
        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.md) }
        .shadow(color: mapChromeShadow, radius: 12, y: 5)
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var activeFilterCount: Int {
        var count = 0
        if model.operatorFilter != model.defaultOperatorKeyForCurrentMarket { count += 1 }
        if !model.techFilters.isEmpty { count += 1 }
        if !model.bandFilters.isEmpty { count += 1 }
        if !model.sharingFilters.isEmpty { count += 1 }
        if model.speedtestDays != 0 { count += 1 }
        if model.coverageDays != 0 { count += 1 }
        if filters != MapFilterStore.defaultFilters { count += 1 }
        return count
    }

    private func centerOnCurrentLocation() {
        Task {
            if let location = await services.location.currentLocation(timeoutSeconds: 8) {
                let coordinate = location.coordinate
                mapCenter = coordinate
                mapZoom = 15
#if !canImport(MapLibre)
                position = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                ))
#endif
                scheduleLoad(region: MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                ))
            } else {
                model.errorMessage = "Position actuelle indisponible"
            }
        }
    }

    private var coverageQualityLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                Text("Qualité RSRP (dBm)").sqKicker()

                ForEach(CoverageQualityBand.visibleBands) { band in
                    HStack(spacing: SQSpace.xs + 1) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(band.swiftUIColor)
                            .frame(width: 9, height: 9)
                        Text("\(band.title) \(band.rangeLabel)")
                            .font(SQFont.archivo(11, .semibold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(mapSubtlePillFill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1.5)
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
        }
        .frame(height: 36)
    }

    /// Bascule de coloration de la couche Couverture : Signal (RSRP) ↔ Génération.
    private var coverageColoringToggle: some View {
        Picker("Coloration couverture", selection: $coverageByGeneration) {
            Text("Signal").tag(false)
            Text("Génération").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .padding(.horizontal, SQSpace.md)
        .accessibilityLabel("Coloration de la couverture : signal ou génération")
    }

    /// Légende de la couche Couverture en mode GÉNÉRATION (distincte du RSRP).
    private var coverageGenerationLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                Text("Génération").sqKicker()

                ForEach(CoverageGenerationBand.visibleBands) { band in
                    HStack(spacing: SQSpace.xs + 1) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(band.swiftUIColor)
                            .frame(width: 9, height: 9)
                        Text(band.title)
                            .font(SQFont.archivo(11, .semibold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(mapSubtlePillFill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1.5)
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
        }
        .frame(height: 36)
    }

    private var searchSuggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                ForEach(model.searchResults.prefix(8)) { site in
                    Button {
                        if let lat = site.latitude, let lng = site.longitude {
                            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                            mapCenter = coordinate
                            mapZoom = 15
#if !canImport(MapLibre)
                            position = .region(MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            ))
#endif
                            model.searchResults = []
                            selectedAntenna = site
                        }
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SQColor.brandRed)
                            Text(site.siteId ?? site.id)
                                .font(SQFont.archivo(14, .bold))
                            if let address = site.address {
                                Text(address)
                                    .font(SQFont.body(13))
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, SQSpace.md - 1)
                        .padding(.vertical, SQSpace.sm + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .overlay { mapChromeBorder(SQRadius.md) }
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .foregroundStyle(SQColor.label)
                }
            }
            .padding(.horizontal, SQSpace.xs)
            .padding(.top, SQSpace.xs)
        }
        .frame(maxHeight: 240)
    }

    /// Reconstruit le cache des couches lourdes. Appelé uniquement sur changement
    /// de données (`model.dataVersion`), de couches actives (`filters`) ou de zoom
    /// — jamais à chaque rendu de `body`.
    private func refreshMapRender() {
        renderedAnnotations = annotationPayloads
        renderedCoverageFeatures = coverageHeatFeatures
        renderedSpeedtestFeatures = speedtestFeatures
    }

    /// Ouvre la fiche du site demandé par le routeur (tap sur notification antenne
    /// ou deep link). Cherche d'abord dans les antennes déjà chargées ; sinon le
    /// récupère par recherche (le site peut être hors de la zone visible) et
    /// recentre la carte dessus.
    private func openSiteFromRouterIfNeeded() {
        guard let siteId = router.openSiteId else { return }
        router.openSiteId = nil
        if let site = model.antennas.first(where: { $0.id == siteId || $0.siteId == siteId }) {
            selectedAntenna = site
            return
        }
        Task {
            let results = (try? await services.antennas.search(query: siteId)) ?? []
            guard let site = results.first(where: { $0.id == siteId || $0.siteId == siteId }) ?? results.first else { return }
            selectedAntenna = site
            if let lat = site.latitude, let lng = site.longitude {
                mapCenter = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                mapZoom = max(mapZoom, 14)
            }
        }
    }

    private var annotationPayloads: [MapAnnotationPayload] {
        var payloads = displayItems.map { item in
            MapAnnotationPayload(
                id: item.id,
                kind: item.kind,
                title: item.title,
                subtitle: item.subtitle,
                coordinate: item.coordinate,
                metric: item.metric,
                backendId: item.backendId,
                details: item.details,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false
            )
        }
        if filters.contains(.antenna) {
            payloads += model.antennaClusters.map { cluster in
                MapAnnotationPayload(
                    id: "antenna-cluster-\(cluster.id)",
                    kind: .antenna,
                    title: "\(cluster.count) antennes",
                    subtitle: "Zoomer pour les détails",
                    coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                    metric: "cluster",
                    backendId: nil,
                    details: MapItemDetails(
                        avgRsrp: cluster.avgRsrp,
                        tech: cluster.tech,
                        timestamp: cluster.latestTimestamp,
                        operatorName: model.operatorLabel(model.operatorFilter),
                        clusterCount: cluster.count
                    ),
                    antennaId: nil,
                    clusterCount: cluster.count,
                    azimuths: [],
                    showsAzimuths: false,
                    tint: model.operatorFilter.uppercased() == "ALL" ? nil : model.operatorAccent(model.operatorFilter)
                )
            }
            let antennaPayloads: [MapAnnotationPayload] = model.antennas.compactMap { site in
                // La liste `/api/antennas` (mode minimal) ne renvoie PAS les
                // bandes par site : le filtrage bande est fait CÔTÉ SERVEUR. On ne
                // ré-applique le filtre client que si l'antenne porte réellement
                // des bandes — sinon `site.bands` vide ferait disparaître TOUTES
                // les antennes dès qu'une bande est sélectionnée (bug « le filtre
                // bande masque tout »).
                guard site.bands.isEmpty || matchesSelectedBands(site.bands) else { return nil }
                guard matchesSelectedSharing(site) else { return nil }
                guard let lat = site.latitude, let lng = site.longitude else { return nil }
                return MapAnnotationPayload(
                    id: "antenna-\(site.id)",
                    kind: .antenna,
                    title: "Site \(site.siteId ?? site.id)",
                    subtitle: [site.operators.joined(separator: "/"), site.technologies.prefix(3).joined(separator: "/")]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "),
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    metric: site.height.map { "\(Int($0)) m" },
                    backendId: site.siteId ?? site.id,
                    details: nil,
                    antennaId: site.id,
                    clusterCount: nil,
                    azimuths: site.azimuths,
                    showsAzimuths: mapZoom >= 14,
                    tint: model.operatorAccent(site.operators.first ?? model.operatorFilter),
                    contributionPhotos: site.photoCount
                )
            }
            payloads += clusteredPayloads(from: antennaPayloads, kind: .antenna, idPrefix: "antenna", minCount: 160, label: { "\($0) antennes" })
        }
        payloads += communitySitePayloads
        payloads += photoPayloads
        payloads += plannedPayloads
        payloads += outagePayloads
        return payloads
    }

    /// Sites prévisionnels : pastille à la couleur de l'opérateur + anneau et
    /// badge de statut (croisement ANFR) — actif (vert ✓), upgrade en attente
    /// (ambre ↑), déclaré / prévu (blanc), comme Android.
    private var plannedPayloads: [MapAnnotationPayload] {
        guard filters.contains(.planned) else { return [] }
        let individual = model.plannedSites.compactMap { site -> MapAnnotationPayload? in
            guard matchesSelectedBands(in: plannedBandSearchFields(site)) else { return nil }
            guard let lat = site.lat, let lon = site.lon else { return nil }
            let status = site.activation?.status ?? .planned
            let techLine = site.technologies.joined(separator: " / ")
            let pending = site.activation?.pendingTechnologies ?? []
            let statusNote: String
            switch status {
            case .active: statusNote = "Site actif — toutes les technos prévues sont en service"
            case .upgradePending:
                statusNote = pending.isEmpty ? "Upgrade en cours" : "Upgrade en attente : \(pending.joined(separator: ", "))"
            case .declared: statusNote = "Station déclarée à l'ANFR (pas encore en service)"
            case .planned: statusNote = "Site prévu (non encore construit)"
            }
            return MapAnnotationPayload(
                id: "planned-\(site.id)",
                kind: .planned,
                title: site.codeSite ?? "Site prévisionnel",
                subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                metric: techLine.isEmpty ? nil : techLine,
                backendId: site.codeSite ?? site.id,
                details: MapItemDetails(
                    tech: techLine.isEmpty ? nil : techLine,
                    operatorName: site.operator.map { model.operatorLabel($0) },
                    note: statusNote
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: site.operator.map { model.operatorAccent($0) },
                plannedStatus: status
            )
        }
        return clusteredPayloads(from: individual, kind: .planned, idPrefix: "planned", minCount: 40, label: { "\($0) prévisionnels" })
    }

    /// Sites en panne (HS) : pastille colorée par type d'incident (panne rouge,
    /// maintenance orange, dégradé jaune) avec le glyphe correspondant, comme Android.
    private var outagePayloads: [MapAnnotationPayload] {
        guard filters.contains(.outage) else { return [] }
        let individual = model.outages.compactMap { site -> MapAnnotationPayload? in
            guard matchesSelectedOutageBands(site) else { return nil }
            guard let lat = site.lat, let lon = site.lon else { return nil }
            let kindKey = (site.issueType ?? "down").lowercased()
            return MapAnnotationPayload(
                id: "outage-\(site.id)",
                kind: .outage,
                title: site.siteId ?? "Site en panne",
                subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                metric: site.status,
                backendId: site.siteId ?? site.id,
                details: MapItemDetails(
                    operatorName: site.operator,
                    note: [site.reason, site.estimatedEnd.map { "Rétabli prévu : \($0)" }].compactMap { $0 }.joined(separator: "\n")
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: Self.outageColor(for: kindKey),
                glyphOverride: Self.outageGlyph(for: kindKey)
            )
        }
        return clusteredPayloads(from: individual, kind: .outage, idPrefix: "outage", minCount: 30, label: { "\($0) sites HS" })
    }

    private static func outageColor(for issueType: String) -> Color {
        switch issueType {
        case "maintenance": return Color(hex: 0xF97316)
        case "degraded": return Color(hex: 0xEAB308)
        default: return Color(hex: 0xEF4444)
        }
    }

    private static func outageGlyph(for issueType: String) -> String {
        switch issueType {
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "degraded": return "exclamationmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    /// Couche Speedtests rendue en GPU (`MLNCircleStyleLayer`) : TOUT s'affiche,
    /// sans cluster ni cap, coloré par débit descendant. Les annotations-vues ne
    /// pourraient pas tenir des milliers de points.
    private var speedtestFeatures: [SpeedtestFeature] {
        guard filters.contains(.speedtest) else { return [] }
        let techs = model.techFilters
        var seen = Set<String>()
        var features: [SpeedtestFeature] = []
        for tile in model.speedtestTiles {
            for marker in tile.markers {
                guard seen.insert(marker.id).inserted else { continue }
                if !techs.isEmpty, !Self.speedtestMatchesTech(marker.tech, selected: techs) { continue }
                guard matchesSelectedBand(marker.band) || matchesSelectedBands(in: [marker.frequency, marker.tech].compactMap { $0 }) else { continue }
                features.append(
                    SpeedtestFeature(
                        id: marker.id,
                        coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                        downloadMbps: marker.downloadMbps,
                        uploadMbps: marker.uploadMbps,
                        pingMs: marker.pingMs,
                        tech: marker.tech,
                        band: marker.band,
                        frequency: marker.frequency,
                        timestamp: marker.timestamp
                    )
                )
            }
        }
        return features
    }

    /// Marqueurs « sites communautaires » (sites probables / cellules
    /// observées), colorés avec la couleur registry de leur opérateur.
    private var communitySitePayloads: [MapAnnotationPayload] {
        let showsLayer = filters.contains(.communitySite) ||
            (model.isCommunityOnlyMarket && filters.contains(.antenna))
        guard showsLayer else { return [] }
        var seen = Set<String>()
        return model.communitySiteTiles.flatMap(\.markers).compactMap { marker in
            guard seen.insert(marker.id).inserted else { return nil }
            guard marker.lat != 0 || marker.lng != 0 else { return nil }
            let isProbable = marker.candidateKind == "community_probable"
            return MapAnnotationPayload(
                id: "community-site-\(marker.id)",
                kind: .communitySite,
                title: isProbable ? "Site probable" : "Cellule observée",
                subtitle: [
                    marker.operatorKey.map { model.operatorShortLabel($0) },
                    marker.radioNodeType,
                    marker.confidenceLevel.map { "confiance \($0)" }
                ].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                metric: marker.enb.map { "eNB \($0)" } ?? marker.gnb.map { "gNB \($0)" },
                backendId: marker.candidateKey ?? marker.id,
                details: MapItemDetails(
                    timestamp: marker.lastObservedAt,
                    operatorName: marker.operatorKey.map { model.operatorLabel($0) },
                    sampleCount: marker.observationCount,
                    note: isProbable ? "Site estimé par les observations communautaires" : "Cellule observée par la communauté"
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: model.operatorAccent(marker.operatorKey ?? "ALL"),
                communityObserved: !isProbable
            )
        }
    }

    /// Couche Photos : vignettes géolocalisées affichées directement sur la
    /// carte. Tap → `MapPhotoViewer` (photo en grand, infos antenne, like,
    /// commentaires). Les doublons de coordonnées sont conservés (MapLibre les
    /// décale légèrement) tant qu'ils ont un id distinct.
    /// Couche Photos : vignettes des photos de TOUS les membres (`publicPhotos`),
    /// clusterisées pour rester fluide (vignettes individuelles seulement quand
    /// elles sont peu nombreuses / zoom élevé ; sinon bulle « N photos »).
    private var photoPayloads: [MapAnnotationPayload] {
        guard filters.contains(.photo) else { return [] }
        var seen = Set<String>()
        let individual = model.publicPhotos.compactMap { photo -> MapAnnotationPayload? in
            guard seen.insert(photo.id).inserted else { return nil }
            return MapAnnotationPayload(
                id: "photo-\(photo.id)",
                kind: .photo,
                title: "Photo",
                subtitle: photo.operator ?? photo.siteId ?? "Site",
                coordinate: CLLocationCoordinate2D(latitude: photo.lat, longitude: photo.lng),
                metric: nil,
                backendId: photo.id,
                details: MapItemDetails(
                    timestamp: photo.uploadedAt,
                    operatorName: photo.operator
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                thumbnailURL: photo.thumbnailUrl
            )
        }
        return clusteredPhotoPayloads(from: individual)
    }

    /// Regroupe les photos quand la carte est dézoomée OU qu'il y en a beaucoup
    /// (> 120 dans le viewport) — borne le nombre de vignettes chargées (anti-lag).
    /// Les bulles de cluster n'ont PAS de vignette (rendu en pastille « N photos »
    /// rose) ; les photos isolées gardent leur vignette polaroïd.
    private func clusteredPhotoPayloads(from payloads: [MapAnnotationPayload]) -> [MapAnnotationPayload] {
        let shouldCluster = mapZoom < 13 || payloads.count > 120
        guard shouldCluster, payloads.count > 1 else { return payloads }
        let cellSize: Double
        switch mapZoom {
        case ..<11: cellSize = 0.06
        case ..<12.5: cellSize = 0.03
        case ..<13.5: cellSize = 0.015
        default: cellSize = 0.008
        }
        struct Cell: Hashable { let lat: Int; let lng: Int }
        let groups = Dictionary(grouping: payloads) { payload in
            Cell(
                lat: Int((payload.coordinate.latitude / cellSize).rounded(.down)),
                lng: Int((payload.coordinate.longitude / cellSize).rounded(.down))
            )
        }
        return groups.map { cell, group in
            guard group.count > 1 else { return group[0] }
            // Coordonnée = CENTRE de cellule (déterministe) plutôt que la moyenne des
            // membres : l'id ET la position restent stables quand on pan (les photos
            // entrant/sortant du viewport ne déplacent plus la pastille) → la couche
            // n'est plus détruite/recréée à chaque déplacement (anti-lag).
            let lat = (Double(cell.lat) + 0.5) * cellSize
            let lng = (Double(cell.lng) + 0.5) * cellSize
            return MapAnnotationPayload(
                id: "photo-cluster-\(cell.lat)-\(cell.lng)",
                kind: .photo,
                title: "\(group.count) photos",
                subtitle: "Zoomer pour le détail",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                metric: "cluster",
                backendId: nil,
                details: nil,
                antennaId: nil,
                clusterCount: group.count,
                azimuths: [],
                showsAzimuths: false
            )
        }
    }

    /// Couleur + clé de regroupement d'un point de couverture selon le mode courant :
    /// par RSRP (signal) ou par génération réseau. Modes mutuellement exclusifs
    /// (jamais mélangés) — la légende suit `coverageByGeneration`.
    private func coverageColorParts(rsrp: Double?, tech: String?) -> (key: String, hex: UInt32, dimmed: Bool) {
        if coverageByGeneration {
            let band = CoverageGenerationBand.band(for: tech)
            return ("g-\(band.rawValue)", band.colorHex, band == .none)
        } else {
            let band = CoverageQualityBand.band(for: rsrp)
            return ("q-\(band.rawValue)", band.colorHex, band == .unknown)
        }
    }

    private var coverageHeatFeatures: [CoverageHeatFeature] {
        guard filters.contains(.coverage) else { return [] }
        let hasBandFilter = !model.bandFilters.isEmpty
        var features: [CoverageHeatFeature] = []
        for tile in model.coverageTiles {
            let render = CoverageRenderPolicy.mode(
                hasPoints: !tile.points.isEmpty, hasClusters: !tile.clusters.isEmpty, hasBandFilter: hasBandFilter
            )
            if render.useClusters {
                features += tile.clusters.map { cluster in
                    // Clusters (région/pays) : génération dominante (`cluster.tech`) en mode génération.
                    let parts = coverageColorParts(rsrp: cluster.avgRsrp, tech: cluster.tech)
                    return CoverageHeatFeature(
                        id: "coverage-heat-cluster-\(cluster.id)",
                        coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                        weight: min(max(Double(cluster.count), 1), 40) / 8,
                        colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed
                    )
                }
            }
            if render.useRawPoints {
                // Tous les points bruts (cap élevé unifié) — le rendu GPU MapLibre les tient.
                features += tile.points.lazy.filter { matchesSelectedBand($0.band) }.prefix(CoverageRenderPolicy.pointCapPerTile).map { point in
                    let parts = coverageColorParts(rsrp: point.rsrp, tech: point.tech)
                    return CoverageHeatFeature(
                        id: "coverage-heat-\(point.id)",
                        coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                        weight: coverageHeatWeight(rsrp: point.rsrp),
                        colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed
                    )
                }
            }
        }
        if features.isEmpty {
            features = model.coverageHeat.lazy.filter { point in
                matchesSelectedBand(point.band) || matchesSelectedBands(in: [point.frequency, point.technology, point.networkType].compactMap { $0 })
            }.prefix(CoverageRenderPolicy.fallbackCap).map { point in
                let parts = coverageColorParts(rsrp: point.signalStrength, tech: point.technology ?? point.networkType)
                return CoverageHeatFeature(
                    id: "coverage-heat-api-\(point.id)",
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    weight: coverageHeatWeight(rsrp: point.signalStrength),
                    colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed
                )
            }
        }
        return features
    }

    /// Filtre « Partage » (mutualisation FR/DROM) appliqué CÔTÉ CLIENT sur les
    /// champs sharingType/crozonLeader/isZTD de l'antenne (parité Android :
    /// le backend ne sait pas exprimer ce multi-select). Sémantique OU.
    private func matchesSelectedSharing(_ site: AntennaSite) -> Bool {
        let selected = model.sharingFilters
        guard !selected.isEmpty else { return true }
        let type = (site.sharingType ?? "").lowercased()
        let leader = (site.crozonLeader ?? "").uppercased()
        return selected.contains { value in
            switch value {
            case "ZB": return type == "zb"
            case "CROZON_LEADER_SFR": return type == "crozon" && leader == "SFR"
            case "CROZON_LEADER_BOUYGUES": return type == "crozon" && leader == "BOUYGUES"
            case "ZTD": return site.isZTD
            default: return false
            }
        }
    }

    /// Filtre techno appliqué à un marqueur speedtest. Le backend ne renvoie que
    /// le TYPE de connexion ("CELLULAR"/"WIFI"/…), pas la génération (la donnée
    /// vit en base mais le endpoint tuiles ne l'expose pas encore). On filtre donc
    /// honnêtement : si `tech` encode une génération, on l'exige ; sinon un test
    /// Wi-Fi/filaire est exclu quand une génération cellulaire est demandée, et un
    /// test cellulaire/inconnu est conservé (au lieu de tout masquer comme avant).
    private static func speedtestMatchesTech(_ raw: String?, selected: Set<String>) -> Bool {
        let t = (raw ?? "").lowercased()
        let generation: String? = {
            if t.contains("5g") || t.contains(" nr") || t == "nr" { return "5G" }
            if t.contains("4g") || t.contains("lte") { return "4G" }
            if t.contains("3g") || t.contains("umts") || t.contains("wcdma") || t.contains("hspa") { return "3G" }
            if t.contains("2g") || t.contains("gsm") || t.contains("edge") || t.contains("gprs") { return "2G" }
            return nil
        }()
        if let generation { return selected.contains(generation) }
        if t.contains("wifi") || t.contains("wi-fi") || t.contains("ethernet")
            || t.contains("wired") || t.contains("filaire") {
            return false
        }
        return true
    }

    private func matchesSelectedBand(_ band: Int?) -> Bool {
        guard !model.bandFilters.isEmpty else { return true }
        guard let band else { return false }
        return model.bandFilters.contains(band)
    }

    private func matchesSelectedBands(_ bands: [Int]) -> Bool {
        guard !model.bandFilters.isEmpty else { return true }
        return !Set(bands).isDisjoint(with: model.bandFilters)
    }

    private func matchesSelectedBands(in values: [String]) -> Bool {
        guard !model.bandFilters.isEmpty else { return true }
        let normalizedValues = values.map(Self.normalizedBandSearchText)
        return model.bandFilters.contains { band in
            let tokens = Self.bandSearchTokens(for: band)
            return normalizedValues.contains { value in
                tokens.contains { token in value.contains(token) }
            }
        }
    }

    private func plannedBandSearchFields(_ site: PlannedSiteLive) -> [String] {
        var fields = site.technologies
        if let activation = site.activation {
            fields += activation.activeTechnologies
            fields += activation.plannedTechnologies
            fields += activation.confirmedTechnologies
            fields += activation.pendingTechnologies
        }
        return fields
    }

    private func matchesSelectedOutageBands(_ site: OutageSiteLive) -> Bool {
        guard !model.bandFilters.isEmpty else { return true }
        let serviceLabels = site.services.map(\.label)
        guard !serviceLabels.isEmpty else { return false }
        let generations = Set(model.bandFilters.flatMap(Self.generationLabels(forBand:)))
        return serviceLabels.contains { label in
            let normalized = Self.normalizedBandSearchText(label)
            return generations.contains { normalized.contains($0) }
        }
    }

    private static func normalizedBandSearchText(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static func bandSearchTokens(for band: Int) -> [String] {
        switch band {
        case 1: return ["b1", "n1", "2100"]
        case 3: return ["b3", "1800"]
        case 7: return ["b7", "2600"]
        case 20: return ["b20", "800"]
        case 28: return ["b28", "n28", "700"]
        case 78: return ["n78", "3500", "3.5", "35ghz"]
        default: return ["b\(band)", "n\(band)"]
        }
    }

    private static func generationLabels(forBand band: Int) -> [String] {
        switch band {
        case 1, 28: return ["4g", "5g"]
        case 78: return ["5g"]
        default: return ["4g"]
        }
    }

    private func coverageHeatWeight(rsrp: Double?) -> Double {
        guard let rsrp else { return 1 }
        switch rsrp {
        case (-85)...: return 2.4
        case -95..<(-85): return 1.9
        case -105..<(-95): return 1.4
        case -115..<(-105): return 1.0
        default: return 0.7
        }
    }

    /// Regroupe en clusters de grille (taille de cellule selon le zoom) une couche
    /// de marqueurs trop dense pour des annotations-vues. Générique : antennes,
    /// prévisionnels, pannes — évite que la carte rame. Au zoom ≥ 14 ou sous le
    /// seuil `minCount`, renvoie les marqueurs individuels tels quels.
    private func clusteredPayloads(
        from payloads: [MapAnnotationPayload],
        kind: MapDisplayItem.Kind,
        idPrefix: String,
        minCount: Int,
        label: (Int) -> String
    ) -> [MapAnnotationPayload] {
        guard mapZoom < 14, payloads.count > minCount else { return payloads }
        let cellSize: Double
        switch mapZoom {
        case ..<11:
            cellSize = 0.08
        case ..<12.5:
            cellSize = 0.045
        case ..<13.5:
            cellSize = 0.025
        default:
            cellSize = 0.012
        }

        struct Cell: Hashable { let lat: Int; let lng: Int }
        let groups = Dictionary(grouping: payloads) { payload in
            Cell(
                lat: Int((payload.coordinate.latitude / cellSize).rounded(.down)),
                lng: Int((payload.coordinate.longitude / cellSize).rounded(.down))
            )
        }

        return groups.values.map { group in
            guard group.count > 1 else { return group[0] }
            let lat = group.reduce(0) { $0 + $1.coordinate.latitude } / Double(group.count)
            let lng = group.reduce(0) { $0 + $1.coordinate.longitude } / Double(group.count)
            return MapAnnotationPayload(
                id: "\(idPrefix)-cluster-\(Int(lat / cellSize))-\(Int(lng / cellSize))",
                kind: kind,
                title: label(group.count),
                subtitle: "Zoomer pour le détail",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                metric: "cluster",
                backendId: nil,
                details: nil,
                antennaId: nil,
                clusterCount: group.count,
                azimuths: [],
                showsAzimuths: false
            )
        }
    }

    private var displayItems: [MapDisplayItem] {
        // Couches « riches » construites hors du mapping générique en pastille :
        //  · photos → `photoPayloads` (vignettes)
        //  · speedtests → couche GPU `speedtestFeatures` (tout afficher, sans cluster)
        //  · couverture → couche GPU (dots RSRP type nPerf)
        //  · prévisionnels/pannes → `plannedPayloads`/`outagePayloads` (statut + couleur)
        // Ne reste ici que le social du snapshot (amis / validations / sessions).
        let socialFilters = filters.subtracting([.speedtest, .coverage, .antenna, .photo, .planned, .outage])
        let items = model.snapshot.displayItems(include: socialFilters)
        return items.filter(matches(filterItem:))
    }

    /// Le filtrage opérateur/techno est désormais SERVEUR (paramètre `operator`
    /// des endpoints tuiles + prévisionnels/pannes). On ne refiltre plus côté
    /// client par sous-chaîne de texte — c'est ce qui masquait à tort des couches
    /// dont la clé opérateur ne figure pas dans le libellé (photos, amis, sessions,
    /// marchés hors-FR). On laisse passer : ces couches sociales sont propres aux
    /// amis et restent volontairement tolérantes (politique identique à Android).
    private func matches(filterItem _: MapDisplayItem) -> Bool {
        true
    }

    private func selectAnnotation(_ annotation: MapAnnotationPayload) {
        Haptics.light()
        if let antennaId = annotation.antennaId,
           let site = model.antennas.first(where: { $0.id == antennaId }) {
            selectedAntenna = site
            return
        }
        // N'importe quel cluster (antennes / prévisionnels / pannes) : on zoome.
        if annotation.clusterCount != nil {
            mapCenter = annotation.coordinate
            mapZoom = min(mapZoom + 1.7, 15.5)
            return
        }
        // Photo : viewer plein écran riche (infos antenne, like, commentaires).
        if annotation.kind == .photo, let photoId = annotation.backendId {
            selectedPhoto = MapPhotoTarget(id: photoId, thumbnailURL: annotation.thumbnailURL)
            return
        }
        // Panne (HS) : sheet dédiée détaillée (raison, services impactés, dates).
        if annotation.kind == .outage {
            let outageId = String(annotation.id.dropFirst("outage-".count))
            if let site = model.outages.first(where: { $0.id == outageId }) {
                selectedOutage = site
                return
            }
        }
        // Site prévisionnel : fiche dédiée (statut d'activation, technos, ANFR).
        if annotation.kind == .planned {
            let plannedId = String(annotation.id.dropFirst("planned-".count))
            if let site = model.plannedSites.first(where: { $0.id == plannedId }) {
                selectedPlanned = site
                return
            }
        }
        selectedItem = MapDisplayItem(
            id: annotation.id,
            kind: annotation.kind,
            title: annotation.title,
            subtitle: annotation.subtitle,
            coordinate: annotation.coordinate,
            metric: annotation.metric,
            backendId: annotation.backendId,
            details: annotation.details
        )
    }

    private func annotation(for kind: MapDisplayItem.Kind) -> some View {
        ZStack {
            Circle()
                .fill(color(for: kind).opacity(0.92))
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            Image(systemName: icon(for: kind))
                .font(.caption.weight(.bold))
                .foregroundStyle(SQColor.label)
        }
    }

    private func scheduleLoad(region: MKCoordinateRegion) {
        lastRegion = region
        let zoom = zoom(for: region)
        let bounds = MapBounds(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        scheduleLoad(bounds: bounds, zoom: zoom)
    }

    private func scheduleLoad(bounds: MapBounds, zoom: Double) {
        MapRegionStore.save(lastRegion)
        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await model.load(bounds: bounds, zoom: zoom, filters: filters, lightweight: true)
        }
    }

    private func zoom(for region: MKCoordinateRegion) -> Double {
        max(4, min(18, log2(360 / max(region.span.longitudeDelta, 0.001))))
    }

    private func icon(for kind: MapDisplayItem.Kind) -> String {
        switch kind {
        case .friend: return "person.fill"
        case .photo: return "camera.fill"
        case .validation: return "checkmark.seal.fill"
        case .session: return "figure.walk"
        case .coverage: return "dot.radiowaves.left.and.right"
        case .speedtest: return "speedometer"
        case .outage: return "exclamationmark.triangle.fill"
        case .planned: return "calendar.badge.clock"
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .communitySite: return "dot.radiowaves.up.forward"
        }
    }

    private func color(for kind: MapDisplayItem.Kind) -> Color {
        switch kind {
        case .speedtest: return SQColor.brandGreen
        case .photo: return SQColor.brandPink
        case .friend: return SQColor.brandBlue
        case .coverage: return SQColor.brandOrange
        case .validation: return SQColor.brandGreen
        case .outage: return .red
        case .planned: return SQColor.brandBlue
        case .antenna: return SQColor.brandBlue
        case .session: return SQColor.brandOrange
        case .communitySite: return SQColor.brandPink
        }
    }

    /// Country/region-level default camera per supported market. The map engine
    /// itself is global (no France-only bounds); this only decides where to look
    /// first when no last-region is restored and where to recentre on a switch.
    static func region(for market: String) -> MKCoordinateRegion {
        switch market {
        case "CA": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 56.13, longitude: -106.35), span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50))
        case "DROM": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 14.95, longitude: -61.0), span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
        case "BE": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 50.64, longitude: 4.67), span: MKCoordinateSpan(latitudeDelta: 2.2, longitudeDelta: 2.6))
        case "CH": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.80, longitude: 8.23), span: MKCoordinateSpan(latitudeDelta: 2.6, longitudeDelta: 3.2))
        case "PT": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.56, longitude: -7.85), span: MKCoordinateSpan(latitudeDelta: 5.5, longitudeDelta: 5.0))
        case "ES": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.10, longitude: -3.65), span: MKCoordinateSpan(latitudeDelta: 9.0, longitudeDelta: 11.0))
        case "BA": return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43.92, longitude: 17.68), span: MKCoordinateSpan(latitudeDelta: 2.6, longitudeDelta: 3.0))
        default: return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.45), span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 9.0))
        }
    }

    static func zoom(forSpan region: MKCoordinateRegion) -> Double {
        max(4, min(18, log2(360 / max(region.span.longitudeDelta, 0.001))))
    }
}

private struct MapAdvancedFilterSheet: View {
    @Binding var market: String
    @Binding var operatorName: String
    @Binding var technologies: Set<String>
    @Binding var bands: Set<Int>
    @Binding var sharing: Set<String>
    @Binding var speedtestDays: Int
    @Binding var coverageDays: Int
    @Binding var layers: Set<MapDisplayItem.Kind>
    @Binding var includeObserved: Bool
    /// Marchés `publicSelectable` du registre, dans l'ordre du backend.
    let allMarkets: [MarketRegistryEntry]
    @Environment(\.dismiss) private var dismiss

    /// La couche communautaire est-elle disponible/active dans cette feuille ?
    private var communityLayerAvailable: Bool {
        selectedEntry?.isCommunityOnly == true || selectedEntry?.capabilities.communityLayers == true
    }

    /// Entrée du registre correspondant au marché sélectionné dans la feuille.
    private var selectedEntry: MarketRegistryEntry? {
        let normalized = market.uppercased()
        return allMarkets.first {
            $0.marketCode.uppercased() == normalized || $0.code.uppercased() == normalized
        }
    }

    private var operatorOptions: [String] {
        guard let entry = selectedEntry else { return ["ALL"] }
        var keys = entry.selectableOperators.map(\.key)
        if !keys.contains(where: { $0.uppercased() == "ALL" }) {
            keys.append("ALL")
        }
        return keys
    }

    /// Code marché normalisé pour le catalogue de filtres : préfère le
    /// `marketCode` du registre (robuste aux pays partageant un marché), sinon
    /// le binding brut. Pilote les sections Technologies/Partage/Bandes.
    private var catalogMarket: String {
        selectedEntry?.marketCode ?? market
    }

    /// Couches proposées : un marché communautaire se limite aux couches
    /// pertinentes (sites communautaires + speedtests).
    private var layerOptions: [(MapDisplayItem.Kind, String, String)] {
        if selectedEntry?.isCommunityOnly == true {
            return [
                (.communitySite, "Sites communautaires", "dot.radiowaves.up.forward"),
                (.speedtest, "Speedtests", "speedometer")
            ]
        }
        var options: [(MapDisplayItem.Kind, String, String)] = [
            (.antenna, "Antennes", "antenna.radiowaves.left.and.right"),
            (.speedtest, "Speedtests", "speedometer"),
            (.photo, "Photos", "photo"),
            (.friend, "Amis", "person.2"),
            (.coverage, "Couverture backend", "dot.radiowaves.left.and.right")
        ]
        // Pannes & Prévisionnels : données ANFR FR/DROM uniquement (le backend ne
        // répond que pour ces marchés ; ailleurs `load()` ne les charge jamais).
        // On ne propose donc pas ces puces mortes hors FR/DROM.
        if ["FR", "DROM"].contains(catalogMarket.uppercased()) {
            options.append((.outage, "Pannes", "exclamationmark.triangle"))
            options.append((.planned, "Prévisionnels", "calendar.badge.clock"))
        }
        if selectedEntry?.capabilities.communityLayers == true {
            options.append((.communitySite, "Sites communautaires", "dot.radiowaves.up.forward"))
        }
        return options
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.md + 2) {
                    filterSection("Calques", icon: "square.3.layers.3d") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(layerOptions, id: \.0.rawValue) { kind, label, icon in
                                filterChip(title: label, icon: icon, active: layers.contains(kind)) {
                                    toggleLayer(kind)
                                }
                            }
                        }
                        if communityLayerAvailable && (layers.contains(.communitySite) || selectedEntry?.isCommunityOnly == true) {
                            Toggle(isOn: $includeObserved) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cellules observées")
                                            .font(SQFont.archivo(14, .semibold))
                                            .foregroundStyle(SQColor.label)
                                        Text("Affiche aussi les cellules captées, en plus des sites probables consolidés")
                                            .font(SQFont.archivo(11, .regular))
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                } icon: {
                                    Image(systemName: "dot.radiowaves.up.forward")
                                        .foregroundStyle(SQColor.brandPink)
                                }
                            }
                            .tint(SQColor.brandRed)
                            .padding(.top, 4)
                        }
                    }

                    filterSection("Opérateur", icon: "antenna.radiowaves.left.and.right") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                        ForEach(operatorOptions, id: \.self) { op in
                                filterChip(
                                    title: operatorLabel(op),
                                    icon: op == "ALL" ? "circle.grid.2x2.fill" : "dot.radiowaves.left.and.right",
                                    active: operatorName == op
                                ) {
                                    operatorName = op
                                }
                            }
                        }
                    }

                    filterSection("Technologies", icon: "cellularbars") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            filterChip(title: "Toutes", icon: "sparkles", active: technologies.isEmpty) {
                                technologies.removeAll()
                            }
                            ForEach(MapFilterCatalog.technologies(forMarket: catalogMarket), id: \.value) { tech in
                                filterChip(title: tech.label, icon: "cellularbars", active: technologies.contains(tech.value)) {
                                    toggleTechnology(tech.value)
                                }
                            }
                        }
                    }

                    // « Partage » (mutualisation d'antennes) : présent uniquement
                    // pour les marchés qui l'exposent (FR/DROM). Masqué ailleurs.
                    let sharingOptions = MapFilterCatalog.sharing(forMarket: catalogMarket)
                    if !sharingOptions.isEmpty {
                        filterSection("Partage", icon: "point.3.connected.trianglepath.dotted") {
                            LazyVGrid(columns: filterColumns, spacing: 8) {
                                ForEach(sharingOptions, id: \.value) { opt in
                                    filterChip(title: opt.label, icon: opt.icon, active: sharing.contains(opt.value)) {
                                        toggleSharing(opt.value)
                                    }
                                }
                            }
                        }
                    }

                    // « Bandes » : catalogue spécifique au pays (repli européen
                    // pour les marchés sans définition dédiée).
                    filterSection("Bandes", icon: "waveform.path.ecg") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(MapFilterCatalog.bands(forMarket: catalogMarket), id: \.band) { opt in
                                filterChip(title: opt.label, icon: "dot.radiowaves.left.and.right", active: bands.contains(opt.band)) {
                                    toggleBand(opt.band)
                                }
                            }
                        }
                    }

                    filterSection("Période", icon: "calendar") {
                        periodPicker("Speedtests", selection: $speedtestDays)
                        periodPicker("Couverture", selection: $coverageDays)
                    }
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Calques & filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Réinitialiser") {
                        market = "FR"
                        operatorName = "SFR"
                        technologies.removeAll()
                        bands.removeAll()
                        sharing.removeAll()
                        speedtestDays = 0
                        coverageDays = 0
                        layers = MapFilterStore.defaultFilters
                        includeObserved = true
                    }
                    .font(SQFont.archivo(15, .semibold))
                    .tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { dismiss() }
                        .font(SQFont.archivo(15, .bold))
                        .tint(SQColor.brandRed)
                }
            }
            // Le réalignement de l'opérateur sur le nouveau marché est géré
            // par la vue parente (alignWithMarket), pas par la feuille.
        }
    }

    private var filterColumns: [GridItem] {
        [GridItem(.flexible(), spacing: SQSpace.sm), GridItem(.flexible(), spacing: SQSpace.sm)]
    }

    private func filterSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label(title, systemImage: icon)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    /// Tag de filtre éditorial : sélectionné = fond rouge plein, texte blanc ;
    /// sinon surface contrastée + bordure separator. Coin net `SQRadius.sm`.
    private func filterChip(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 16)
                Text(title)
                    .font(SQFont.archivo(12, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, SQSpace.sm)
            .background(active ? SQColor.brandRed : SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(active ? Color.clear : SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(active ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: active)
    }

    private func periodPicker(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .font(SQFont.archivo(12, .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            Picker(title, selection: selection) {
                Text("Tout").tag(0)
                Text("7 j").tag(7)
                Text("30 j").tag(30)
                Text("90 j").tag(90)
            }
            .pickerStyle(.segmented)
        }
    }

    private func toggleLayer(_ kind: MapDisplayItem.Kind) {
        if layers.contains(kind) {
            layers.remove(kind)
        } else {
            layers.insert(kind)
        }
    }

    private func toggleTechnology(_ tech: String) {
        if technologies.contains(tech) {
            technologies.remove(tech)
        } else {
            technologies.insert(tech)
        }
    }

    private func toggleBand(_ band: Int) {
        if bands.contains(band) {
            bands.remove(band)
        } else {
            bands.insert(band)
        }
    }

    private func toggleSharing(_ value: String) {
        if sharing.contains(value) {
            sharing.remove(value)
        } else {
            sharing.insert(value)
        }
    }

    private func operatorLabel(_ value: String) -> String {
        if let entry = selectedEntry?.operatorEntry(forKey: value) {
            return entry.label
        }
        return value.uppercased() == "ALL" ? "Tous les opérateurs" : value
    }
}

#if canImport(MapLibre)
// MARK: - Carte MapKit (migration vers moteur unique — remplace SQMapLibreMapView)
// NB : placé sous `#if canImport(MapLibre)` UNIQUEMENT pour accéder à `markerColor`
// pendant la transition. Ce code n'utilise AUCUN type MapLibre ; la phase finale
// retirera le gating et le rendra inconditionnel.

/// Annotation MapKit portant le payload (pour le dispatch tap → fiche).
private final class SQMapKitAnnotation: NSObject, MKAnnotation {
    let payload: MapAnnotationPayload
    let coordinate: CLLocationCoordinate2D
    init(payload: MapAnnotationPayload) {
        self.payload = payload
        self.coordinate = payload.coordinate
    }
}

/// Vue d'annotation native : pastille colorée (opérateur) ou pastille de cluster
/// numérotée. (Vignettes photos / cônes : phases ultérieures.)
private final class SQMapKitMarkerView: MKAnnotationView {
    static let reuseID = "sq-mapkit-marker"
    private let dot = UIView()
    private let countLabel = UILabel()
    private let glyph = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.25
        dot.layer.shadowRadius = 3
        dot.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        countLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countLabel.textAlignment = .center
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        addSubview(dot)
        dot.addSubview(glyph)
        dot.addSubview(countLabel)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ payload: MapAnnotationPayload) {
        let color = UIColor(payload.markerColor)
        if let count = payload.clusterCount {
            let size: CGFloat = count >= 100 ? 40 : 34
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            dot.frame = bounds
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = color
            dot.alpha = 1
            countLabel.frame = dot.bounds
            countLabel.text = count > 999 ? "999+" : "\(count)"
            countLabel.isHidden = false
            glyph.isHidden = true
        } else {
            let size: CGFloat = 22
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            dot.frame = bounds
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = color
            dot.alpha = payload.communityObserved ? 0.6 : 1
            countLabel.isHidden = true
            glyph.frame = dot.bounds.insetBy(dx: 4, dy: 4)
            glyph.image = UIImage(systemName: Self.glyphName(for: payload))?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
            glyph.isHidden = false
        }
    }

    private static func glyphName(for p: MapAnnotationPayload) -> String {
        if let g = p.glyphOverride { return g }
        switch p.kind {
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .photo: return "camera.fill"
        case .friend: return "person.fill"
        case .validation: return "checkmark.seal.fill"
        case .session: return "figure.walk"
        case .outage: return "exclamationmark.triangle.fill"
        case .planned: return "calendar.badge.clock"
        case .communitySite: return "dot.radiowaves.up.forward"
        case .speedtest: return "speedometer"
        case .coverage: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Overlay « nuage de points » dense (couverture / speedtests) dessiné en une passe
/// Core Graphics avec culling viewport — tient des milliers de points (pattern repris
/// de SessionTraceMapView, le moteur de « Mes mesures »).
private final class SQMapKitDotsOverlay: NSObject, MKOverlay {
    struct Dot { let point: MKMapPoint; let color: CGColor }
    let dots: [Dot]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(dots: [Dot]) {
        self.dots = dots
        var rect = MKMapRect.null
        for d in dots { rect = rect.union(MKMapRect(origin: d.point, size: MKMapSize(width: 0.5, height: 0.5))) }
        let bounding = rect.isNull ? MKMapRect.world : rect.insetBy(dx: -rect.size.width * 0.1 - 50, dy: -rect.size.height * 0.1 - 50)
        boundingMapRect = bounding
        coordinate = MKMapPoint(x: bounding.midX, y: bounding.midY).coordinate
    }
}

private final class SQMapKitDotsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? SQMapKitDotsOverlay else { return }
        let radius = max(2.0, 3.0 / zoomScale)
        let pad = radius * 3
        let cull = mapRect.insetBy(dx: -pad, dy: -pad)
        context.setLineWidth(radius * 0.35)
        let stroke = UIColor.black.withAlphaComponent(0.22).cgColor
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.color)
            context.fillEllipse(in: r)
            context.setStrokeColor(stroke)
            context.strokeEllipse(in: r)
        }
    }
}

/// Carte principale rendue avec MapKit (Apple Plan natif). Consomme les MÊMES
/// payloads que l'ancien moteur MapLibre (`renderedAnnotations`, etc.).
private struct MapKitMapView: UIViewRepresentable {
    let annotations: [MapAnnotationPayload]
    let coverageHeatFeatures: [CoverageHeatFeature]   // Phase 2
    let speedtestFeatures: [SpeedtestFeature]          // Phase 2
    let colorScheme: ColorScheme
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onMoveEnd: (MapBounds, Double) -> Void
    let onSelect: (MapAnnotationPayload) -> Void

    private static let referenceWidth: CGFloat = 390

    func makeCoordinator() -> Coordinator {
        Coordinator(center: $center, zoom: $zoom, onMoveEnd: onMoveEnd, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        let config = MKStandardMapConfiguration(elevationStyle: .flat)
        config.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = config
        map.register(SQMapKitMarkerView.self, forAnnotationViewWithReuseIdentifier: SQMapKitMarkerView.reuseID)
        // Tap pour les points speedtest (overlay non-tappable nativement) → hit-test.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSpeedtestTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        let region = MKCoordinateRegion(center: center, span: Coordinator.span(forZoom: zoom, width: Self.referenceWidth))
        map.setRegion(region, animated: false)
        context.coordinator.lastAppliedCenter = center
        context.coordinator.lastAppliedZoom = zoom
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.setCoverage(coverageHeatFeatures, on: map)
        context.coordinator.setSpeedtest(speedtestFeatures, on: map)
        context.coordinator.setCones(from: annotations, on: map)
        context.coordinator.apply(annotations: annotations, on: map)
        context.coordinator.applyCameraIfNeeded(center: center, zoom: zoom, on: map)
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        @Binding var center: CLLocationCoordinate2D
        @Binding var zoom: Double
        private let onMoveEnd: (MapBounds, Double) -> Void
        private let onSelect: (MapAnnotationPayload) -> Void
        private var annotationsById: [String: SQMapKitAnnotation] = [:]
        private var payloadsById: [String: MapAnnotationPayload] = [:]
        var lastAppliedCenter: CLLocationCoordinate2D?
        var lastAppliedZoom: Double?
        private var latestCoverageFeatures: [CoverageHeatFeature] = []
        private var latestSpeedtestFeatures: [SpeedtestFeature] = []
        private var coverageOverlay: SQMapKitDotsOverlay?
        private var speedtestOverlay: SQMapKitDotsOverlay?
        private var conePolygons: [MKPolygon] = []
        private var coneColors: [ObjectIdentifier: UIColor] = [:]
        private var coneSignature = 0

        init(center: Binding<CLLocationCoordinate2D>, zoom: Binding<Double>,
             onMoveEnd: @escaping (MapBounds, Double) -> Void,
             onSelect: @escaping (MapAnnotationPayload) -> Void) {
            _center = center
            _zoom = zoom
            self.onMoveEnd = onMoveEnd
            self.onSelect = onSelect
        }

        // MARK: Zoom ↔ span (slippy-map, compatible avec le z des tuiles)
        static func span(forZoom zoom: Double, width: CGFloat) -> MKCoordinateSpan {
            let lonDelta = Double(width) * 360.0 / (256.0 * pow(2.0, max(zoom, 0.0)))
            return MKCoordinateSpan(latitudeDelta: min(170, lonDelta), longitudeDelta: min(360, lonDelta))
        }
        static func zoom(forRegion region: MKCoordinateRegion, width: CGFloat) -> Double {
            let lonDelta = max(region.span.longitudeDelta, 0.0000001)
            return log2(Double(width) * 360.0 / (256.0 * lonDelta))
        }

        // MARK: Annotations — diff stable par id (add/remove delta)
        func apply(annotations payloads: [MapAnnotationPayload], on map: MKMapView) {
            var incoming: [String: MapAnnotationPayload] = [:]
            incoming.reserveCapacity(payloads.count)
            for p in payloads { incoming[p.id] = p }

            var toRemove: [SQMapKitAnnotation] = []
            for (id, ann) in annotationsById where incoming[id] == nil || incoming[id] != payloadsById[id] {
                toRemove.append(ann)
                annotationsById[id] = nil
                payloadsById[id] = nil
            }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }

            var toAdd: [SQMapKitAnnotation] = []
            for p in payloads where annotationsById[p.id] == nil {
                let ann = SQMapKitAnnotation(payload: p)
                annotationsById[p.id] = ann
                payloadsById[p.id] = p
                toAdd.append(ann)
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        // MARK: Couches denses (couverture + speedtests) — overlay Core Graphics
        func setCoverage(_ features: [CoverageHeatFeature], on map: MKMapView) {
            guard features != latestCoverageFeatures else { return }
            latestCoverageFeatures = features
            if let old = coverageOverlay { map.removeOverlay(old); coverageOverlay = nil }
            guard !features.isEmpty else { return }
            let dots = features.map { f -> SQMapKitDotsOverlay.Dot in
                let alpha: CGFloat = f.dimmed ? 0.32 : 0.78
                return .init(point: MKMapPoint(f.coordinate), color: Self.uiColor(hex: f.colorHex).withAlphaComponent(alpha).cgColor)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            coverageOverlay = overlay
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func setSpeedtest(_ features: [SpeedtestFeature], on map: MKMapView) {
            guard features != latestSpeedtestFeatures else { return }
            latestSpeedtestFeatures = features
            if let old = speedtestOverlay { map.removeOverlay(old); speedtestOverlay = nil }
            guard !features.isEmpty else { return }
            let dots = features.map { f -> SQMapKitDotsOverlay.Dot in
                .init(point: MKMapPoint(f.coordinate), color: Self.speedColor(f.downloadMbps).withAlphaComponent(0.9).cgColor)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            speedtestOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
        }

        /// Cônes de secteur des antennes (affichés z≥14) → polygones MapKit, colorés
        /// par opérateur. Reconstruits seulement quand l'ensemble change.
        func setCones(from annotations: [MapAnnotationPayload], on map: MKMapView) {
            var hasher = Hasher()
            for p in annotations where p.showsAzimuths && !p.azimuths.isEmpty {
                hasher.combine(p.id); hasher.combine(p.coordinate.latitude); hasher.combine(p.coordinate.longitude)
                for a in p.azimuths { hasher.combine(a) }
            }
            let sig = hasher.finalize()
            guard sig != coneSignature else { return }
            coneSignature = sig
            if !conePolygons.isEmpty { map.removeOverlays(conePolygons); conePolygons.removeAll() }
            coneColors.removeAll()
            for p in annotations where p.showsAzimuths && !p.azimuths.isEmpty {
                let color = UIColor(p.markerColor)
                for az in p.azimuths {
                    var coords = AntennaSectorGeometry.sectorConeCoordinates(apex: p.coordinate, azimuth: az, lengthMeters: 320)
                    guard coords.count >= 3 else { continue }
                    let poly = MKPolygon(coordinates: &coords, count: coords.count)
                    coneColors[ObjectIdentifier(poly)] = color
                    conePolygons.append(poly)
                }
            }
            if !conePolygons.isEmpty { map.addOverlays(conePolygons, level: .aboveRoads) }
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let dots = overlay as? SQMapKitDotsOverlay {
                return SQMapKitDotsRenderer(overlay: dots)
            }
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                let color = coneColors[ObjectIdentifier(poly)] ?? .systemOrange
                r.fillColor = color.withAlphaComponent(0.18)
                r.strokeColor = color.withAlphaComponent(0.5)
                r.lineWidth = 1
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        @objc func handleSpeedtestTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView,
                  !latestSpeedtestFeatures.isEmpty else { return }
            let tap = recognizer.location(in: map)
            var best: SpeedtestFeature?
            var bestDist: CGFloat = 22
            for f in latestSpeedtestFeatures {
                let p = map.convert(f.coordinate, toPointTo: map)
                let d = hypot(p.x - tap.x, p.y - tap.y)
                if d < bestDist { bestDist = d; best = f }
            }
            if let best { onSelect(speedtestPayload(from: best)) }
        }

        private func speedtestPayload(from speedtest: SpeedtestFeature) -> MapAnnotationPayload {
            MapAnnotationPayload(
                id: "speed-\(speedtest.id)",
                kind: .speedtest,
                title: "\(Int(speedtest.downloadMbps.rounded())) Mbps",
                subtitle: speedtest.tech ?? "Speedtest",
                coordinate: speedtest.coordinate,
                metric: speedtest.uploadMbps.map { "\(Int($0.rounded())) Mbps up" },
                backendId: speedtest.id,
                details: MapItemDetails(
                    downloadMbps: speedtest.downloadMbps,
                    uploadMbps: speedtest.uploadMbps,
                    pingMs: speedtest.pingMs,
                    tech: speedtest.tech,
                    timestamp: speedtest.timestamp,
                    note: "Données Speedtest"
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false
            )
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        static func uiColor(hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        static func speedColor(_ mbps: Double) -> UIColor {
            let hex: UInt32
            switch mbps {
            case 1000...: hex = 0x3B82F6
            case 600..<1000: hex = 0x06B6D4
            case 300..<600: hex = 0x22C55E
            case 100..<300: hex = 0x84CC16
            case 30..<100: hex = 0xEAB308
            case 10..<30: hex = 0xF97316
            default: hex = 0xEF4444
            }
            return uiColor(hex: hex)
        }

        // MARK: Caméra — n'applique QUE les changements programmatiques (GPS, cluster).
        func applyCameraIfNeeded(center: CLLocationCoordinate2D, zoom: Double, on map: MKMapView) {
            let movedCenter = lastAppliedCenter.map {
                abs($0.latitude - center.latitude) > 0.00005 || abs($0.longitude - center.longitude) > 0.00005
            } ?? true
            let changedZoom = lastAppliedZoom.map { abs($0 - zoom) > 0.01 } ?? true
            guard movedCenter || changedZoom else { return }
            lastAppliedCenter = center
            lastAppliedZoom = zoom
            let width = map.bounds.width > 0 ? map.bounds.width : MapKitMapView.referenceWidth
            map.setRegion(MKCoordinateRegion(center: center, span: Self.span(forZoom: zoom, width: width)), animated: true)
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            let width = map.bounds.width > 0 ? map.bounds.width : MapKitMapView.referenceWidth
            let z = Self.zoom(forRegion: map.region, width: width)
            // Reflète l'état réel dans les bindings (le guard ci-dessus évite la boucle).
            lastAppliedCenter = map.centerCoordinate
            lastAppliedZoom = z
            center = map.centerCoordinate
            zoom = z
            let r = map.region
            let bounds = MapBounds(
                north: r.center.latitude + r.span.latitudeDelta / 2,
                south: r.center.latitude - r.span.latitudeDelta / 2,
                east: r.center.longitude + r.span.longitudeDelta / 2,
                west: r.center.longitude - r.span.longitudeDelta / 2
            )
            onMoveEnd(bounds, z)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let sq = annotation as? SQMapKitAnnotation else { return nil } // position utilisateur → défaut
            let view = map.dequeueReusableAnnotationView(withIdentifier: SQMapKitMarkerView.reuseID, for: annotation) as? SQMapKitMarkerView
                ?? SQMapKitMarkerView(annotation: annotation, reuseIdentifier: SQMapKitMarkerView.reuseID)
            view.annotation = annotation
            view.canShowCallout = false
            view.apply(sq.payload)
            return view
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let sq = view.annotation as? SQMapKitAnnotation {
                onSelect(sq.payload)
            }
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}

private final class SQPointAnnotation: MLNPointAnnotation {
    let payload: MapAnnotationPayload

    init(payload: MapAnnotationPayload) {
        self.payload = payload
        super.init()
        coordinate = payload.coordinate
        title = payload.title
        subtitle = payload.subtitle
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

private struct SQMapLibreMapView: UIViewRepresentable {
    let annotations: [MapAnnotationPayload]
    let coverageHeatFeatures: [CoverageHeatFeature]
    let speedtestFeatures: [SpeedtestFeature]
    let colorScheme: ColorScheme
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onMoveEnd: (MapBounds, Double) -> Void
    let onSelect: (MapAnnotationPayload) -> Void
    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.carto.rawValue
    private var backdrop: MapBackdrop { MapBackdrop(rawValue: backdropRaw) ?? .carto }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMoveEnd: onMoveEnd, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = backdrop.styleURL(dark: colorScheme == .dark)
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = false
        mapView.attributionButton.isHidden = false
        mapView.setCenter(center, zoomLevel: zoom, animated: false)
        mapView.tintColor = UIColor.systemOrange
        // Les speedtests/couverture sont des couches GPU (pas des annotations-vues) :
        // on intercepte le tap pour ouvrir le détail d'un point speedtest touché.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let expectedStyleURL = backdrop.styleURL(dark: colorScheme == .dark)
        if mapView.styleURL != expectedStyleURL {
            mapView.styleURL = expectedStyleURL
        }

        context.coordinator.setCoverageHeatFeatures(coverageHeatFeatures, mapView: mapView)
        context.coordinator.setSpeedtestFeatures(speedtestFeatures, mapView: mapView)
        context.coordinator.applyAnnotations(annotations, mapView: mapView)
        if context.coordinator.shouldApplyCamera(center: center, zoom: zoom) {
            mapView.setCenter(center, zoomLevel: zoom, animated: true)
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
        private let onMoveEnd: (MapBounds, Double) -> Void
        private let onSelect: (MapAnnotationPayload) -> Void
        private var lastCenter: CLLocationCoordinate2D?
        private var lastZoom: Double?
        private var latestCoverageHeatFeatures: [CoverageHeatFeature] = []
        // Couches couverture dynamiques (clé = bande RSRP « q-… » ou génération « g-… »).
        // On retient les ids créés pour vider/cacher ceux de l'autre mode à la bascule.
        private var coverageDotLayerIds: Set<String> = []
        private var coverageDotSourceByLayer: [String: String] = [:]
        private var coverageDotDimmedByLayer: [String: Bool] = [:]
        private var latestSpeedtestFeatures: [SpeedtestFeature] = []
        /// Index id → point speedtest, pour résoudre le tap (couche GPU) en détail.
        private var speedtestFeaturesById: [String: SpeedtestFeature] = [:]
        private var lastStyledZoom: Double = .nan
        /// État de diff des annotations (id → annotation + payload appliqué), pour
        /// ne retirer/ajouter QUE le delta au lieu de tout détruire/recréer à chaque
        /// réévaluation de la vue (cf. audit PERF-01).
        private var annotationsById: [MapAnnotationPayload.ID: SQPointAnnotation] = [:]
        private var annotationPayloadsById: [MapAnnotationPayload.ID: MapAnnotationPayload] = [:]

        init(onMoveEnd: @escaping (MapBounds, Double) -> Void, onSelect: @escaping (MapAnnotationPayload) -> Void) {
            self.onMoveEnd = onMoveEnd
            self.onSelect = onSelect
        }

        func shouldApplyCamera(center: CLLocationCoordinate2D, zoom: Double) -> Bool {
            defer {
                lastCenter = center
                lastZoom = zoom
            }
            guard let lastCenter, let lastZoom else { return true }
            return abs(lastCenter.latitude - center.latitude) > 0.0001 ||
                abs(lastCenter.longitude - center.longitude) > 0.0001 ||
                abs(lastZoom - zoom) > 0.01
        }

        func setCoverageHeatFeatures(_ features: [CoverageHeatFeature], mapView: MLNMapView) {
            // Ne reconstruire la heatmap que si les features ont changé (le rechargement
            // de style ré-applique de son côté via didFinishLoading).
            guard features != latestCoverageHeatFeatures else { return }
            latestCoverageHeatFeatures = features
            updateCoverageHeatmap(mapView: mapView, features: features)
        }

        /// Diff stable des annotations par id : retire les disparues/modifiées et
        /// n'ajoute que les nouvelles, au lieu d'un remove-all/add-all qui faisait
        /// clignoter les marqueurs à chaque update (audit PERF-01).
        func applyAnnotations(_ payloads: [MapAnnotationPayload], mapView: MLNMapView) {
            var incomingById: [MapAnnotationPayload.ID: MapAnnotationPayload] = [:]
            incomingById.reserveCapacity(payloads.count)
            for payload in payloads { incomingById[payload.id] = payload }

            var toRemove: [SQPointAnnotation] = []
            for (id, annotation) in annotationsById {
                let incoming = incomingById[id]
                if incoming == nil || incoming != annotationPayloadsById[id] {
                    toRemove.append(annotation)
                    annotationsById[id] = nil
                    annotationPayloadsById[id] = nil
                }
            }
            if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

            var toAdd: [SQPointAnnotation] = []
            for payload in payloads where annotationsById[payload.id] == nil {
                let annotation = SQPointAnnotation(payload: payload)
                annotationsById[payload.id] = annotation
                annotationPayloadsById[payload.id] = payload
                toAdd.append(annotation)
            }
            if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Un rechargement de style (bascule clair/sombre) efface sources et
            // couches : on ré-applique couverture ET speedtests.
            updateCoverageDots(mapView: mapView, features: latestCoverageHeatFeatures)
            updateSpeedtestLayer(mapView: mapView, features: latestSpeedtestFeatures)
        }

        // MARK: Couverture — champ de pastilles RSRP (type nPerf / Android)

        func updateCoverageHeatmap(mapView: MLNMapView, features: [CoverageHeatFeature]) {
            updateCoverageDots(mapView: mapView, features: features)
        }

        /// Couverture rendue comme un champ dense de pastilles colorées par RSRP
        /// (vert → rouge), comme nPerf / Android — au lieu de l'ancien halo flou,
        /// jugé peu lisible. Une source + une couche cercle par bande de qualité.
        private func updateCoverageDots(mapView: MLNMapView, features: [CoverageHeatFeature]) {
            guard let style = mapView.style else { return }
            // Regroupement par clé de couleur (bande RSRP « q-… » OU génération « g-… ») :
            // une source + une couche cercle par clé. Le mode est encodé dans la feature
            // (couleur figée) → aucun flag à propager jusqu'au coordinator.
            let byKey = Dictionary(grouping: features, by: \.colorKey)
            var activeLayerIds = Set<String>()
            for (key, group) in byKey {
                guard let first = group.first else { continue }
                let sourceId = "sq-coverage-dot-source-\(key)"
                let layerId = "sq-coverage-dot-layer-\(key)"
                activeLayerIds.insert(layerId)
                let pts = group.map { feature -> MLNPointFeature in
                    let point = MLNPointFeature()
                    point.coordinate = feature.coordinate
                    return point
                }
                if let source = style.source(withIdentifier: sourceId) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: pts)
                } else {
                    let source = MLNShapeSource(identifier: sourceId, features: pts, options: nil)
                    style.addSource(source)
                    let layer = MLNCircleStyleLayer(identifier: layerId, source: source)
                    layer.circleColor = NSExpression(forConstantValue: Self.coverageUIColor(hex: first.colorHex))
                    layer.circleStrokeWidth = NSExpression(forConstantValue: 0)
                    style.addLayer(layer)
                }
                style.layer(withIdentifier: layerId)?.isVisible = !pts.isEmpty
                coverageDotLayerIds.insert(layerId)
                coverageDotSourceByLayer[layerId] = sourceId
                coverageDotDimmedByLayer[layerId] = first.dimmed
            }
            // Bascule de mode : vide + cache les couches de l'autre mode (clés absentes).
            for layerId in coverageDotLayerIds where !activeLayerIds.contains(layerId) {
                if let sourceId = coverageDotSourceByLayer[layerId],
                   let source = style.source(withIdentifier: sourceId) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: [])
                }
                style.layer(withIdentifier: layerId)?.isVisible = false
            }
            styleCoverageDots(style: style, zoom: mapView.zoomLevel)
        }

        private static func coverageUIColor(hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1.0)
        }

        private func styleCoverageDots(style: MLNStyle, zoom: Double) {
            let radius = coverageDotRadius(forZoom: zoom)
            for layerId in coverageDotLayerIds {
                guard let layer = style.layer(withIdentifier: layerId) as? MLNCircleStyleLayer else { continue }
                layer.circleRadius = NSExpression(forConstantValue: radius)
                layer.circleOpacity = NSExpression(forConstantValue: (coverageDotDimmedByLayer[layerId] ?? false) ? 0.30 : 0.62)
                layer.circleBlur = NSExpression(forConstantValue: 0.18)
            }
        }

        private func coverageDotRadius(forZoom zoom: Double) -> Double {
            switch zoom {
            case ..<8: return 5.6
            case ..<11: return 5.0
            case ..<13: return 4.5
            case ..<15: return 4.2
            default: return 4.8
            }
        }

        // MARK: Speedtests — couche GPU (tout afficher, sans cluster ni cap)

        func setSpeedtestFeatures(_ features: [SpeedtestFeature], mapView: MLNMapView) {
            guard features != latestSpeedtestFeatures else { return }
            latestSpeedtestFeatures = features
            speedtestFeaturesById = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
            updateSpeedtestLayer(mapView: mapView, features: features)
        }

        /// Un point = une pastille colorée par débit descendant (échelle 7 paliers,
        /// alignée web/Android). Rendu GPU : tient des milliers de points sans
        /// cluster ni cap, là où les annotations-vues s'effondreraient.
        private func updateSpeedtestLayer(mapView: MLNMapView, features: [SpeedtestFeature]) {
            guard let style = mapView.style else { return }
            let byBand = Dictionary(grouping: features, by: { SpeedBand.band(forDownload: $0.downloadMbps) })
            for band in SpeedBand.allCases {
                let pts = (byBand[band] ?? []).map { feature -> MLNPointFeature in
                    let point = MLNPointFeature()
                    point.coordinate = feature.coordinate
                    point.attributes = ["id": feature.id]
                    return point
                }
                let sourceId = speedtestSourceId(for: band)
                if let source = style.source(withIdentifier: sourceId) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: pts)
                } else {
                    let source = MLNShapeSource(identifier: sourceId, features: pts, options: nil)
                    style.addSource(source)
                    let layer = MLNCircleStyleLayer(identifier: speedtestLayerId(for: band), source: source)
                    layer.circleColor = NSExpression(forConstantValue: band.uiColor)
                    layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.55))
                    style.addLayer(layer)
                }
                style.layer(withIdentifier: speedtestLayerId(for: band))?.isVisible = !pts.isEmpty
            }
            styleSpeedtestDots(style: style, zoom: mapView.zoomLevel)
        }

        private func styleSpeedtestDots(style: MLNStyle, zoom: Double) {
            let radius = speedtestDotRadius(forZoom: zoom)
            let stroke = zoom >= 13 ? 0.8 : 0.0
            for band in SpeedBand.allCases {
                guard let layer = style.layer(withIdentifier: speedtestLayerId(for: band)) as? MLNCircleStyleLayer else { continue }
                layer.circleRadius = NSExpression(forConstantValue: radius)
                layer.circleOpacity = NSExpression(forConstantValue: 0.9)
                layer.circleStrokeWidth = NSExpression(forConstantValue: stroke)
            }
        }

        private func speedtestDotRadius(forZoom zoom: Double) -> Double {
            switch zoom {
            case ..<7: return 2.2
            case ..<9: return 2.8
            case ..<11: return 3.4
            case ..<13: return 4.2
            case ..<15: return 5.0
            default: return 6.0
            }
        }

        private var speedtestLayerIdentifiers: Set<String> {
            Set(SpeedBand.allCases.map { speedtestLayerId(for: $0) })
        }

        // MARK: Tap sur une pastille speedtest (couche GPU)

        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView = recognizer.view as? MLNMapView else { return }
            let point = recognizer.location(in: mapView)
            let rect = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
            let hits = mapView.visibleFeatures(in: rect, styleLayerIdentifiers: speedtestLayerIdentifiers)
            guard let feature = hits.first,
                  let id = feature.attribute(forKey: "id") as? String,
                  let speedtest = speedtestFeaturesById[id] else { return }
            onSelect(speedtestPayload(from: speedtest))
        }

        private func speedtestPayload(from speedtest: SpeedtestFeature) -> MapAnnotationPayload {
            MapAnnotationPayload(
                id: "speed-\(speedtest.id)",
                kind: .speedtest,
                title: "\(Int(speedtest.downloadMbps.rounded())) Mbps",
                subtitle: speedtest.tech ?? "Speedtest",
                coordinate: speedtest.coordinate,
                metric: speedtest.uploadMbps.map { "\(Int($0.rounded())) Mbps up" },
                backendId: speedtest.id,
                details: MapItemDetails(
                    downloadMbps: speedtest.downloadMbps,
                    uploadMbps: speedtest.uploadMbps,
                    pingMs: speedtest.pingMs,
                    tech: speedtest.tech,
                    timestamp: speedtest.timestamp,
                    note: "Données Speedtest"
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false
            )
        }

        private func speedtestSourceId(for band: SpeedBand) -> String {
            "sq-speedtest-source-\(band.rawValue)"
        }

        private func speedtestLayerId(for band: SpeedBand) -> String {
            "sq-speedtest-layer-\(band.rawValue)"
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // Redimensionne les pastilles GPU selon le zoom (sans attendre un
            // changement de données), pour un rendu net à toutes les échelles.
            if let style = mapView.style {
                let zoom = mapView.zoomLevel
                if lastStyledZoom.isNaN || abs(zoom - lastStyledZoom) > 0.25 {
                    lastStyledZoom = zoom
                    styleCoverageDots(style: style, zoom: zoom)
                    styleSpeedtestDots(style: style, zoom: zoom)
                }
            }
            let bounds = mapView.visibleCoordinateBounds
            onMoveEnd(
                MapBounds(
                    north: bounds.ne.latitude,
                    south: bounds.sw.latitude,
                    east: bounds.ne.longitude,
                    west: bounds.sw.longitude
                ),
                mapView.zoomLevel
            )
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let point = annotation as? SQPointAnnotation else { return nil }
            let identifier = "sq-\(point.payload.kind.rawValue)"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? SQMapAnnotationView)
                ?? SQMapAnnotationView(reuseIdentifier: identifier)
            view.configure(with: point.payload)
            return view
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let point = annotation as? SQPointAnnotation {
                onSelect(point.payload)
            }
            mapView.deselectAnnotation(annotation, animated: true)
        }
    }
}

/// Cache mémoire + chargement des vignettes photo affichées sur la carte.
/// Partagé entre toutes les vues d'annotation recyclées par MapLibre.
/// `@unchecked Sendable` : NSCache et URLSession sont déjà thread-safe et les
/// deux propriétés sont immuables (`let`).
private final class SQAnnotationImageCache: @unchecked Sendable {
    static let shared = SQAnnotationImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    /// Côté max (px) de la vignette décodée. La pastille fait 60 pt (~180 px @3x) ;
    /// on décode directement à cette taille → coût mémoire/CPU borné même si la
    /// source est une image pleine résolution (repli `imageUrl`).
    private let maxPixelSize: CGFloat = 200

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 48 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
        session = URLSession(configuration: config)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Charge la vignette (cache → réseau) en la décodant à la taille d'affichage.
    /// Retourne `nil` en cas d'échec.
    func loadImage(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        guard let image = Self.downsample(data: data, maxPixelSize: maxPixelSize) ?? UIImage(data: data) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// Décode l'image directement à `maxPixelSize` via ImageIO (pas de décodage
    /// pleine résolution intermédiaire).
    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private final class SQMapAnnotationView: MLNAnnotationView {
    private let fanLayer = CAShapeLayer()
    private let markerView = UIView()
    private let imageView = UIImageView()
    private let label = UILabel()
    private let glyphView = UIImageView()
    /// Pointe (triangle) sous la carte-photo pour l'ancrer à sa position.
    private let photoPointerLayer = CAShapeLayer()
    /// Petit badge appareil-photo en coin de la vignette.
    private let photoBadgeView = UIImageView()
    /// Badge de statut (sites prévisionnels) : ✓ actif / ↑ upgrade en attente.
    private let statusBadgeView = UIImageView()
    /// URL de la vignette en cours de chargement, pour ignorer les réponses
    /// obsolètes lorsqu'une vue d'annotation est recyclée.
    private var pendingThumbnailURL: URL?
    private var thumbnailTask: Task<Void, Never>?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        isOpaque = false
        backgroundColor = .clear
        // La pointe se dessine SOUS la carte (insérée avant markerView).
        photoPointerLayer.isHidden = true
        layer.addSublayer(photoPointerLayer)
        layer.addSublayer(fanLayer)
        addSubview(markerView)
        markerView.addSubview(imageView)
        markerView.addSubview(label)
        markerView.addSubview(glyphView)
        markerView.addSubview(photoBadgeView)
        markerView.addSubview(statusBadgeView)
        statusBadgeView.contentMode = .center
        statusBadgeView.isHidden = true
        statusBadgeView.tintColor = .white
        statusBadgeView.clipsToBounds = true
        statusBadgeView.layer.borderColor = UIColor.white.cgColor
        statusBadgeView.layer.borderWidth = 1
        markerView.layer.shadowColor = UIColor.black.cgColor
        markerView.layer.shadowOpacity = 0.28
        markerView.layer.shadowRadius = 6
        markerView.layer.shadowOffset = CGSize(width: 0, height: 3)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = .white
        photoBadgeView.contentMode = .center
        photoBadgeView.isHidden = true
        photoBadgeView.tintColor = .white
        photoBadgeView.image = UIImage(systemName: "camera.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        photoBadgeView.backgroundColor = UIColor(SQColor.brandPink)
        photoBadgeView.layer.cornerRadius = 9
        photoBadgeView.clipsToBounds = true
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        pendingThumbnailURL = nil
        imageView.image = nil
        imageView.isHidden = true
        glyphView.isHidden = true
        photoPointerLayer.isHidden = true
        photoBadgeView.isHidden = true
        statusBadgeView.isHidden = true
    }

    func configure(with payload: MapAnnotationPayload) {
        let markerSize = payload.markerSize
        let canvasSize: CGFloat = payload.showsAzimuths && !payload.azimuths.isEmpty ? 82 : max(markerSize.width, markerSize.height)
        frame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        centerOffset = CGVector(dx: 0, dy: 0)

        let markerFrame = CGRect(
            x: (canvasSize - markerSize.width) / 2,
            y: (canvasSize - markerSize.height) / 2,
            width: markerSize.width,
            height: markerSize.height
        )
        markerView.frame = markerFrame

        // Couche Photos : marqueur « polaroïd » carré arrondi avec vignette.
        if payload.kind == .photo, let url = payload.thumbnailURL {
            configurePhoto(url: url, markerSize: markerSize)
            return
        }

        markerView.layer.cornerRadius = markerSize.width / 2
        markerView.layer.borderWidth = payload.markerStrokeWidth
        // Cellule seulement observée : anneau et fond plus translucides pour
        // signaler une confiance moindre qu'un site probable consolidé.
        markerView.layer.borderColor = UIColor.white.withAlphaComponent(payload.communityObserved ? 0.55 : 0.86).cgColor
        markerView.backgroundColor = UIColor(payload.markerColor).withAlphaComponent(payload.communityObserved ? 0.55 : 1.0)
        thumbnailTask?.cancel()
        pendingThumbnailURL = nil
        imageView.isHidden = true
        imageView.image = nil
        photoPointerLayer.isHidden = true
        photoBadgeView.isHidden = true
        statusBadgeView.isHidden = true

        // Site prévisionnel : anneau coloré par statut d'activation (croisement
        // ANFR) — vert actif / ambre upgrade en attente / blanc déclaré ou prévu,
        // avec un badge ✓ ou ↑ pour les sites déjà sur le terrain (comme Android).
        if let status = payload.plannedStatus {
            applyPlannedStatus(status, markerSize: markerSize)
        }

        fanLayer.frame = bounds
        fanLayer.path = payload.showsAzimuths ? azimuthPath(azimuths: payload.azimuths, center: CGPoint(x: canvasSize / 2, y: canvasSize / 2), radius: canvasSize / 2 - 4).cgPath : nil
        fanLayer.fillColor = UIColor(payload.markerColor).withAlphaComponent(0.18).cgColor
        fanLayer.strokeColor = UIColor(payload.markerColor).withAlphaComponent(0.72).cgColor
        fanLayer.lineWidth = 1

        if payload.rendersAsPlainCircle {
            glyphView.isHidden = true
            label.isHidden = true
            label.text = nil
        } else if let clusterCount = payload.clusterCount {
            glyphView.isHidden = true
            label.isHidden = false
            label.text = clusterCount > 99 ? "99+" : String(clusterCount)
            label.frame = markerView.bounds
        } else {
            label.isHidden = true
            glyphView.isHidden = false
            glyphView.image = UIImage(systemName: payload.glyphOverride ?? payload.systemImageName)
            glyphView.frame = markerView.bounds.insetBy(dx: 6, dy: 6)
        }

        // Badge « photos disponibles » sur les antennes (comme Android) : indique
        // qu'au moins une photo publique existe sur le site (taper l'antenne →
        // fiche avec la galerie).
        if payload.kind == .antenna && payload.contributionPhotos > 0 {
            let badge: CGFloat = 16
            photoBadgeView.frame = CGRect(x: markerView.bounds.width - badge + 3, y: -4, width: badge, height: badge)
            photoBadgeView.layer.cornerRadius = badge / 2
            photoBadgeView.isHidden = false
        }
    }

    /// Applique l'anneau + le badge de statut d'un site prévisionnel.
    private func applyPlannedStatus(_ status: PlannedActivationStatus, markerSize: CGSize) {
        let ringColor: UIColor
        let badgeGlyph: String?
        switch status {
        case .active:
            ringColor = UIColor(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255, alpha: 1.0)
            badgeGlyph = "checkmark"
        case .upgradePending:
            ringColor = UIColor(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1.0)
            badgeGlyph = "arrow.up"
        case .declared, .planned:
            ringColor = UIColor.white.withAlphaComponent(0.9)
            badgeGlyph = nil
        }
        markerView.layer.borderColor = ringColor.cgColor
        markerView.layer.borderWidth = status.isOnAir ? 2.6 : 2.0

        guard let badgeGlyph else { statusBadgeView.isHidden = true; return }
        let badge: CGFloat = 15
        statusBadgeView.frame = CGRect(x: markerSize.width - badge - 1, y: 1, width: badge, height: badge)
        statusBadgeView.layer.cornerRadius = badge / 2
        statusBadgeView.backgroundColor = ringColor
        statusBadgeView.image = UIImage(systemName: badgeGlyph, withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .heavy))
        statusBadgeView.isHidden = false
    }

    /// Configure le marqueur en mini-photo et déclenche le chargement async de
    /// la vignette (avec cache mémoire et garde anti-recyclage).
    private func configurePhoto(url: URL, markerSize: CGSize) {
        fanLayer.path = nil
        label.isHidden = true
        glyphView.isHidden = true
        imageView.isHidden = false

        let side = markerSize.width
        let pointerHeight: CGFloat = 9
        let totalHeight = side + pointerHeight
        // Recadre la vue pour inclure la pointe et ancre la POINTE à la position
        // (la carte « flotte » au-dessus du point exact, comme une épingle photo).
        frame = CGRect(x: 0, y: 0, width: side, height: totalHeight)
        centerOffset = CGVector(dx: 0, dy: -totalHeight / 2)

        // Carte blanche arrondie (squircle) avec un liseré rose discret.
        let cardRect = CGRect(x: 0, y: 0, width: side, height: side)
        markerView.frame = cardRect
        markerView.backgroundColor = .white
        markerView.layer.cornerRadius = 16
        markerView.layer.borderWidth = 1.5
        markerView.layer.borderColor = UIColor(SQColor.brandPink).withAlphaComponent(0.9).cgColor
        markerView.layer.shadowOpacity = 0.32
        markerView.layer.shadowRadius = 7
        markerView.layer.shadowOffset = CGSize(width: 0, height: 4)

        let inset: CGFloat = 3.5
        imageView.frame = cardRect.insetBy(dx: inset, dy: inset)
        imageView.layer.cornerRadius = 13
        imageView.backgroundColor = UIColor(white: 0.93, alpha: 1)

        // Badge appareil-photo, coin bas-droit de la vignette.
        let badge: CGFloat = 18
        photoBadgeView.frame = CGRect(x: side - badge - 3, y: side - badge - 3, width: badge, height: badge)
        photoBadgeView.isHidden = false

        // Pointe blanche sous la carte, ancrée au point.
        let pointer = UIBezierPath()
        pointer.move(to: CGPoint(x: side / 2 - 8, y: side - 2))
        pointer.addLine(to: CGPoint(x: side / 2, y: totalHeight))
        pointer.addLine(to: CGPoint(x: side / 2 + 8, y: side - 2))
        pointer.close()
        photoPointerLayer.frame = bounds
        photoPointerLayer.path = pointer.cgPath
        photoPointerLayer.fillColor = UIColor.white.cgColor
        photoPointerLayer.shadowColor = UIColor.black.cgColor
        photoPointerLayer.shadowOpacity = 0.26
        photoPointerLayer.shadowRadius = 4
        photoPointerLayer.shadowOffset = CGSize(width: 0, height: 3)
        photoPointerLayer.isHidden = false

        if let cached = SQAnnotationImageCache.shared.image(for: url) {
            imageView.image = cached
            pendingThumbnailURL = nil
            return
        }

        imageView.image = nil
        pendingThumbnailURL = url
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            let image = await SQAnnotationImageCache.shared.loadImage(url)
            guard let image else { return }
            self?.applyThumbnail(image, for: url)
        }
    }

    /// Applique la vignette chargée si elle correspond toujours à l'annotation
    /// courante (garde anti-recyclage). Isolée main actor : accès UIKit sûr.
    @MainActor
    private func applyThumbnail(_ image: UIImage, for url: URL) {
        guard pendingThumbnailURL == url else { return }
        pendingThumbnailURL = nil
        UIView.transition(with: imageView, duration: 0.25, options: .transitionCrossDissolve) {
            self.imageView.image = image
        }
    }

    private func azimuthPath(azimuths: [Double], center: CGPoint, radius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        for azimuth in azimuths.prefix(6) {
            let halfBeam = 32.5
            let start = CGFloat((azimuth - 90 - halfBeam) * .pi / 180)
            let end = CGFloat((azimuth - 90 + halfBeam) * .pi / 180)
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            path.close()
        }
        return path
    }
}

private extension MapAnnotationPayload {
    var rendersAsPlainCircle: Bool {
        kind == .speedtest || kind == .coverage
    }

    var markerSize: CGSize {
        if let clusterCount {
            let side = clusterCount >= 100 ? 42.0 : clusterCount >= 25 ? 36.0 : 30.0
            return CGSize(width: side, height: side)
        }
        switch kind {
        case .speedtest:
            let speed = firstNumber(in: title) ?? 0
            let side = speed >= 500 ? 16.0 : speed >= 200 ? 14.5 : speed >= 100 ? 13.2 : 11.5
            return CGSize(width: side, height: side)
        case .coverage:
            return CGSize(width: 11.6, height: 11.6)
        case .antenna:
            return CGSize(width: 28, height: 28)
        case .communitySite:
            return CGSize(width: 24, height: 24)
        case .photo:
            // Carte-photo « épingle » : assez grande pour reconnaître la photo.
            return CGSize(width: 60, height: 60)
        default:
            return CGSize(width: 30, height: 30)
        }
    }

    var markerStrokeWidth: CGFloat {
        switch kind {
        case .speedtest:
            return 1.2
        case .coverage:
            return 0
        default:
            return 2
        }
    }

    var markerColor: Color {
        // La couleur registry de l'opérateur prime quand elle est connue
        // (antennes, sites communautaires).
        if let tint { return tint }
        if kind == .antenna {
            // TEL-MAP-02 : couleur de marque via la résolution tolérante SQBrand
            // (Orange/Free/SFR/Bouygues + ultramarins) au lieu d'une déduction par
            // sous-chaîne qui renvoyait Orange ET Free en rouge.
            return SQBrand.operatorColor(subtitle)
        }
        switch kind {
        case .speedtest:
            return speedtestColor(downloadMbps: firstNumber(in: title) ?? 0)
        case .photo: return SQColor.brandPink
        case .friend: return SQColor.brandBlue
        case .coverage:
            return coverageColor(rsrp: firstNumber(in: subtitle).map { -abs($0) })
        case .validation: return SQColor.brandGreen
        case .outage: return .red
        case .planned: return SQColor.brandBlue
        case .session: return SQColor.brandOrange
        case .antenna: return .red
        case .communitySite: return SQColor.brandPink
        }
    }

    private func firstNumber(in text: String) -> Double? {
        let pattern = #"[-+]?\d+(?:[.,]\d+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    /// Échelle de couleur des speedtests — alignée sur le web
    /// (`lib/speedColorUtils.ts` SPEED_THRESHOLDS) : rouge → orange → jaune →
    /// vert clair → vert → cyan → bleu.
    private func speedtestColor(downloadMbps: Double) -> Color {
        switch downloadMbps {
        case 1000...:      return Color(hex: 0x3B82F6) // exceptionnel
        case 600..<1000:   return Color(hex: 0x06B6D4) // excellent
        case 300..<600:    return Color(hex: 0x22C55E) // très bon
        case 100..<300:    return Color(hex: 0x84CC16) // bon
        case 30..<100:     return Color(hex: 0xEAB308) // moyen
        case 10..<30:      return Color(hex: 0xF97316) // lent
        default:           return Color(hex: 0xEF4444) // très lent
        }
    }

    /// Échelle de couleur de couverture par RSRP — alignée sur le web
    /// (`lib/signal-quality.ts` QUALITY_HEX / RSRP_SCALE).
    private func coverageColor(rsrp: Double?) -> Color {
        guard let rsrp else { return Color(hex: 0x94A3B8) } // none
        switch rsrp {
        case (-80)...:        return Color(hex: 0x10B981) // excellent
        case -90..<(-80):     return Color(hex: 0x84CC16) // bon
        case -100..<(-90):    return Color(hex: 0xF59E0B) // moyen
        case -110..<(-100):   return Color(hex: 0xF97316) // faible
        default:              return Color(hex: 0xEF4444) // très faible
        }
    }

    var systemImageName: String {
        switch kind {
        case .friend: return "person.fill"
        case .photo: return "camera.fill"
        case .validation: return "checkmark.seal.fill"
        case .session: return "figure.walk"
        case .coverage: return "dot.radiowaves.left.and.right"
        case .speedtest: return "speedometer"
        case .outage: return "exclamationmark.triangle.fill"
        case .planned: return "calendar.badge.clock"
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .communitySite: return "dot.radiowaves.up.forward"
        }
    }
}
#endif

/// Sheet détaillée d'un site en panne / maintenance : type d'incident, raison
/// lisible, services impactés (voix/data par génération), dates de début et de
/// rétablissement prévu, localisation.
struct OutageDetailSheet: View {
    let site: OutageSiteLive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                header
                if !site.services.isEmpty { servicesSection }
                infoSection
            }
            .padding()
        }
        .presentationDetents([.height(440), .medium, .large])
        .presentationBackgroundCompat(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: issueGlyph)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(issueColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(site.commune?.capitalized ?? site.siteId ?? "Site en panne")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SQColor.label)
                Text(issueLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(issueColor)
                if let op = site.operator {
                    Text(op)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Services impactés")
                .font(SQFont.archivo(12, .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(site.services, id: \.label) { service in
                    HStack(spacing: 6) {
                        Circle().fill(serviceColor(service.status)).frame(width: 8, height: 8)
                        Text(service.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        Text(serviceStatusLabel(service.status))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(serviceColor(service.status))
                    }
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, 7)
                    .background(serviceColor(service.status).opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Raison", reasonText)
            infoRow("Début", formattedDate(site.startedAt))
            infoRow("Rétablissement prévu", formattedDate(site.estimatedEnd) ?? "Non communiqué")
            infoRow("Commune", site.commune?.capitalized)
            infoRow("Département", site.departement)
            infoRow("Site", site.siteId)
        }
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().padding(.leading, SQSpace.md)
        }
    }

    // MARK: Présentation

    private var issueKey: String { (site.issueType ?? "").lowercased() }

    private var issueLabel: String {
        switch issueKey {
        case "maintenance": return "Maintenance programmée"
        case "degraded": return "Service dégradé"
        default: return "Panne / hors service"
        }
    }

    private var issueColor: Color {
        switch issueKey {
        case "maintenance": return Color(hex: 0xF97316)
        case "degraded": return Color(hex: 0xEAB308)
        default: return Color(hex: 0xEF4444)
        }
    }

    private var issueGlyph: String {
        switch issueKey {
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "degraded": return "exclamationmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    /// Code opérateur brut → libellé lisible (au lieu d'« INT » / « MAINT »).
    private var reasonText: String {
        switch (site.reason ?? "").uppercased() {
        case "INT": return "Interruption de service"
        case "MAINT": return "Maintenance programmée"
        case "": return site.detail ?? issueLabel
        default: return site.detail ?? (site.reason ?? issueLabel)
        }
    }

    private func serviceStatusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "HS": return "Hors service"
        case "DE": return "Dégradé"
        case "OK": return "OK"
        default: return status
        }
    }

    private func serviceColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "HS": return Color(hex: 0xEF4444)
        case "DE": return Color(hex: 0xF59E0B)
        case "OK": return Color(hex: 0x10B981)
        default: return SQColor.labelSecondary
        }
    }

    /// Parse une date backend (ISO avec/sans fraction, ou « jour seul ») et la
    /// formate en français lisible.
    private func formattedDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) {
            date = d
        } else {
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: raw) {
                date = d
            } else {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = "yyyy-MM-dd"
                date = f.date(from: raw)
            }
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.locale = Locale(identifier: "fr_FR")
        out.dateStyle = .medium
        out.timeStyle = raw.contains("T") ? .short : .none
        return out.string(from: date)
    }
}
