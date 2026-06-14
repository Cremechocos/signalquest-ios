import SwiftUI
import MapKit
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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var marketFilter = "FR"
    @Published var operatorFilter = "SFR"
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
        MessageSyncLog.logger.debug("market detect schedule lat=\(center.latitude) lng=\(center.longitude)")
        marketDetectionTask?.cancel()
        marketDetectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.detectMarket(at: center)
        }
    }

    /// À consommer dans `.onChange(of: marketFilter)` : vrai si le changement
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
            MessageSyncLog.logger.debug("market detect: aucun marché à lat=\(center.latitude) lng=\(center.longitude)")
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
            // visualiser/capturer le rendu de la couche Photos sur la carte.
            if ProcessInfo.processInfo.arguments.contains("--qa-demo-photos") {
                snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
            }
            errorMessage = nil
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

        // Le snapshot « lightweight » omet photos/validations/sessions (perf). Quand
        // une de ces couches est active, on charge le snapshot COMPLET — sinon la
        // carte n'affichait JAMAIS aucune photo (le backend renvoie photos: []).
        let needsHeavySnapshot = filters.contains(.photo) || filters.contains(.validation) || filters.contains(.session)
        let snapshotLightweight = lightweight && !needsHeavySnapshot
        async let snapshotResult: (snapshot: SocialMapSnapshot?, error: String?) = {
            do { return (try await svc.snapshot(bounds: bounds, zoom: zoom, lightweight: snapshotLightweight), nil) }
            catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        // tiles non-nil → tuiles disponibles ; tiles nil → repli sur la liste bbox.
        async let antennaRaw: (tiles: [AndroidAntennaTileResponse]?, list: [AntennaSite]) = {
            guard wantsAntenna else { return (nil, []) }
            if let tiles = try? await svc.antennaTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, withAzimuth: true) {
                return (tiles, [])
            }
            let list = (try? await antennasSvc.list(bbox: bounds.asBoundingBox, market: market, operatorName: op, technologies: techs, bands: bands, sharing: sharing)) ?? []
            return (nil, list)
        }()
        async let communityRaw: [AndroidCommunitySiteTileResponse] = {
            guard wantsCommunitySites else { return [] }
            return (try? await svc.communitySiteTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, includeObserved: includeObserved)) ?? []
        }()
        async let speedtestRaw: [AndroidSpeedtestTileResponse] = {
            guard wantsSpeedtest else { return [] }
            return (try? await svc.speedtestTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: stDays)) ?? []
        }()
        async let plannedRaw: [PlannedSiteLive] = {
            guard wantsPlanned else { return [] }
            return ((try? await svc.plannedSites(market: market, operatorName: op, territory: territory)) ?? []).filter { bounds.contains(lat: $0.lat, lon: $0.lon) }
        }()
        async let outageRaw: [OutageSiteLive] = {
            guard wantsOutage else { return [] }
            return ((try? await svc.outageSites(market: market, operatorName: op, territory: territory)) ?? []).filter { bounds.contains(lat: $0.lat, lon: $0.lon) }
        }()
        async let coverageRaw: (tiles: [AndroidCoverageTileResponse], heat: [CoverageHeatPoint]) = {
            guard wantsCoverage else { return ([], []) }
            let tiles = (try? await svc.coverageTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: covDays)) ?? []
            if tiles.isEmpty {
                let points = (try? await svc.coveragePoints(bounds: bounds, market: market, operatorName: op, technology: techs.sorted().first)) ?? []
                return ([], points)
            }
            return (tiles, [])
        }()

        // --- On attend TOUS les résultats AVANT d'assigner ---
        let snap = await snapshotResult
        let antenna = await antennaRaw
        let community = await communityRaw
        let speedtest = await speedtestRaw
        let planned = await plannedRaw
        let outage = await outageRaw
        let coverage = await coverageRaw

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
        return tiles.flatMap(\.markers).compactMap { marker in
            let key = marker.supId ?? marker.anfrCode ?? marker.id
            guard seen.insert(key).inserted else { return nil }
            let operators = (marker.operators.isEmpty ? [marker.operator].compactMap { $0 } : marker.operators)
            return AntennaSite(
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
        lhs.thumbnailURL == rhs.thumbnailURL
    }
}

private struct CoverageHeatFeature: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let weight: Double
    let rsrp: Double?

    var quality: CoverageQualityBand {
        CoverageQualityBand.band(for: rsrp)
    }

    static func == (lhs: CoverageHeatFeature, rhs: CoverageHeatFeature) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.weight == rhs.weight &&
            lhs.rsrp == rhs.rsrp
    }
}

private struct CoverageHaloStyle {
    let auraRadius: Double
    let auraOpacity: Double
    let glowRadius: Double
    let glowOpacity: Double
    let glowBlur: Double
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

    var rangeLabel: String {
        switch self {
        case .excellent: return "≥ -80"
        case .good: return "-90"
        case .fair: return "-100"
        case .weak: return "-110"
        case .poor: return "< -110"
        case .unknown: return "n/a"
        }
    }

    // Couleurs QUALITY_HEX du web : #10b981 / #84cc16 / #f59e0b / #f97316 / #ef4444.
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

struct MapExplorerView: View {
    @StateObject private var model: MapExplorerViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var mapZoom: Double
    @State private var filters: Set<MapDisplayItem.Kind> = [.antenna, .speedtest]
    @State private var selectedItem: MapDisplayItem?
    @State private var selectedAntenna: AntennaSite?
    @State private var selectedPhoto: MapPhotoTarget?
    @State private var fetchTask: Task<Void, Never>?
    @State private var lastRegion: MKCoordinateRegion
    @State private var showFilterSheet = false
    @State private var showLayerSwitch = false
    @State private var showQuickActions = false

    init(service: MapSnapshotServicing = MapSnapshotService(api: APIClient()),
         antennas: AntennasServicing = AntennasService(api: APIClient()),
         markets: MarketRegistryServicing = MarketRegistryService(api: APIClient())) {
        _model = StateObject(wrappedValue: MapExplorerViewModel(map: service, antennas: antennas, markets: markets))
        // QA : `--reset-map` efface la région mémorisée pour repartir de France.
        if ProcessInfo.processInfo.arguments.contains("--reset-map") {
            MapRegionStore.reset()
        }
        // Restore the last viewed region, otherwise fall back to a country-level
        // view of the default market — never a hard-coded city.
        let region = MapRegionStore.lastRegion() ?? Self.region(for: "FR")
        _position = State(initialValue: .region(region))
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
            .presentationBackground(SQColor.bg)
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
            await model.load(region: lastRegion, zoom: mapZoom, filters: filters)
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
                    if let first = model.snapshot.photos.first {
                        selectedPhoto = MapPhotoTarget(id: first.id, thumbnailURL: first.thumbnailUrl)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        .onChange(of: filters) { _, _ in
            scheduleLoad(region: lastRegion)
        }
        .onChange(of: model.marketFilter) { _, newValue in
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
                position = .region(region)
                scheduleLoad(region: region)
            }
        }
        .onChange(of: model.operatorFilter) { _, _ in scheduleLoad(region: lastRegion) }
        .onChange(of: model.techFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChange(of: model.bandFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChange(of: model.sharingFilters) { _, _ in scheduleLoad(region: lastRegion) }
        .onChange(of: model.includeObservedSites) { _, _ in scheduleLoad(region: lastRegion) }
    }

    @ViewBuilder
    private var mapLayer: some View {
#if canImport(MapLibre)
        SQMapLibreMapView(
            annotations: annotationPayloads,
            coverageHeatFeatures: coverageHeatFeatures,
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
            ForEach(annotationPayloads) { item in
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
                    operatorQuickStrip
                    if filters.contains(.coverage) {
                        coverageQualityLegend
                    }
                    if !model.searchResults.isEmpty {
                        searchSuggestions
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.top, SQSpace.sm)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack {
                    Spacer()
                    HStack {
                        mapStatusToast
                        Spacer()
                    }
                    .padding(.leading, SQSpace.md)
                    .padding(.bottom, 70)
                }

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: SQSpace.md) {
                        Spacer()
                        mapFloatingPanel
                        mapActionRail
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
            marketPicker
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

    /// Pastille marché : point rouge opérateur + libellé pays/opérateur en
    /// Archivo. Bloc encadré 2px encre, coins nets (signature éditoriale).
    private var marketPicker: some View {
        Button {
            Haptics.light()
            showFilterSheet = true
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Circle()
                    .fill(model.operatorAccent(model.operatorFilter))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentMarketLabel)
                        .font(SQFont.archivo(11, .bold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityLabel(model.currentMarketLabel)
                        .accessibilityIdentifier(model.currentMarketLabel)
                    Text(model.operatorShortLabel(model.operatorFilter))
                        .font(SQFont.archivo(15, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .padding(.horizontal, SQSpace.md - 2)
            .frame(width: 124, height: 48, alignment: .leading)
            .background(mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay { mapChromeBorder(SQRadius.md, strong: true) }
        }
        .buttonStyle(SQPressButtonStyle())
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
        .accessibilityLabel("Filtres")
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

    private var operatorQuickStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm - 1) {
                ForEach(model.operatorOptions, id: \.self) { op in
                    operatorChip(op)
                }
            }
            .padding(.horizontal, SQSpace.xs)
        }
        .frame(height: 40)
    }

    /// Tag opérateur éditorial : sélectionné = fond plein couleur opérateur
    /// (rouge pour « Tous »), texte blanc ; sinon surface + bordure separator.
    /// Coin net `SQRadius.sm`, pastille de couleur à gauche du libellé.
    private func operatorChip(_ op: String) -> some View {
        let isSelected = model.operatorFilter == op
        let isAll = op.uppercased() == "ALL"
        let accent = isAll ? SQColor.brandRed : model.operatorAccent(op)
        return Button {
            Haptics.selection()
            model.operatorFilter = op
        } label: {
            HStack(spacing: SQSpace.xs + 2) {
                Circle()
                    .fill(isSelected ? Color.white : accent)
                    .frame(width: 7, height: 7)
                Text(model.operatorShortLabel(op))
                    .font(SQFont.archivo(13, .bold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .padding(.horizontal, SQSpace.md - 2)
            .frame(height: 34)
            .background(
                isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(mapSubtlePillFill),
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(isSelected ? Color.clear : SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(isSelected ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: isSelected)
    }

    @ViewBuilder
    private var mapStatusToast: some View {
        if let error = model.errorMessage {
            mapToast(error, icon: "exclamationmark.triangle.fill", tint: SQColor.warning)
        } else if annotationPayloads.isEmpty && coverageHeatFeatures.isEmpty && !model.isLoading {
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

    @ViewBuilder
    private var mapFloatingPanel: some View {
        if showQuickActions {
            mapQuickActionsPanel
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
        } else if showLayerSwitch {
            mapLayerPanel
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    private var mapActionRail: some View {
        VStack(spacing: SQSpace.sm - 1) {
            railButton(icon: showLayerSwitch ? "xmark" : "square.3.layers.3d", active: showLayerSwitch, label: showLayerSwitch ? "Fermer les couches" : "Couches de la carte") {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    showLayerSwitch.toggle()
                    if showLayerSwitch { showQuickActions = false }
                }
            }
            railButton(icon: showQuickActions ? "xmark" : "bolt.horizontal.circle", active: showQuickActions, label: showQuickActions ? "Fermer les actions" : "Actions rapides") {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    showQuickActions.toggle()
                    if showQuickActions { showLayerSwitch = false }
                }
            }
            Rectangle()
                .fill(SQColor.separator)
                .frame(width: 26, height: 1.5)
            railButton(icon: "location", active: false, label: "Recentrer sur ma position") {
                centerOnCurrentLocation()
            }
            railButton(icon: "arrow.clockwise", active: false, label: "Rafraîchir la carte") {
                scheduleLoad(region: lastRegion)
            }
        }
        .padding(SQSpace.xs + 1)
        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.lg) }
        .shadow(color: mapChromeShadow, radius: 14, y: 6)
        .frame(width: 56)
    }

    private func railButton(icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 44, height: 44)
                .background(active ? SQColor.brandRed : mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(active ? Color.clear : SQColor.separator, lineWidth: 1.5)
                }
                .foregroundStyle(active ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
    }

    private var mapQuickActionsPanel: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            panelHeader("Actions", value: model.currentMarketLabel)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm) {
                quickAction(title: "Amis", icon: "person.2.fill", active: filters.contains(.friend)) {
                    toggleMapLayer(.friend)
                }
                quickAction(title: "Pannes", icon: "exclamationmark.triangle.fill", active: filters.contains(.outage)) {
                    toggleMapLayer(.outage)
                }
                quickAction(title: "Prévisions", icon: "calendar.badge.clock", active: filters.contains(.planned)) {
                    toggleMapLayer(.planned)
                }
                quickAction(title: "Filtres", icon: "line.3.horizontal.decrease", active: activeFilterCount > 0) {
                    showFilterSheet = true
                    showQuickActions = false
                }
            }
        }
        .padding(SQSpace.md)
        .frame(width: 252, alignment: .leading)
        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.lg) }
        .shadow(color: mapChromeShadow, radius: 14, y: 6)
    }

    private var mapLayerPanel: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            panelHeader("Couches", value: "\(activeLayerCount)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm) {
                ForEach(layerPanelOptions, id: \.0.rawValue) { kind, title, icon in
                    layerChip(kind: kind, title: title, icon: icon)
                }
            }
        }
        .padding(SQSpace.md)
        .frame(width: 268, alignment: .leading)
        .background(mapChromeBackground, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay { mapChromeBorder(SQRadius.lg) }
        .shadow(color: mapChromeShadow, radius: 14, y: 6)
        .foregroundStyle(SQColor.label)
    }

    /// En-tête de panneau : kicker éditorial rouge + compteur en tag net.
    private func panelHeader(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sqKicker()
            Spacer()
            Text(value)
                .font(SQFont.archivo(11, .bold))
                .tracking(0.4)
                .textCase(.uppercase)
                .lineLimit(1)
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, SQSpace.xs)
                .foregroundStyle(SQColor.brandRed)
                .background(SQColor.brandRed.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                        .stroke(SQColor.brandRed.opacity(0.45), lineWidth: 1)
                }
        }
    }

    private func quickAction(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(spacing: SQSpace.xs + 2) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(SQFont.archivo(12, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(active ? SQColor.brandRed : mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(active ? Color.clear : SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(active ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: active)
    }

    private func layerChip(kind: MapDisplayItem.Kind, title: String, icon: String) -> some View {
        let isOn = filters.contains(kind)
        let accent = color(for: kind)
        return Button {
            Haptics.light()
            toggleMapLayer(kind)
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 17)
                Text(title)
                    .font(SQFont.archivo(12, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(isOn ? accent : mapControlFill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(isOn ? Color.clear : SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(isOn ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: isOn)
    }

    private func toggleMapLayer(_ kind: MapDisplayItem.Kind) {
        if filters.contains(kind) {
            filters.remove(kind)
        } else {
            filters.insert(kind)
        }
    }

    /// Couches proposées dans le panneau : un marché communautaire ne montre
    /// que les couches pertinentes (sites communautaires + speedtests).
    private var layerPanelOptions: [(MapDisplayItem.Kind, String, String)] {
        if model.isCommunityOnlyMarket {
            return [
                (.communitySite, "Sites comm.", "dot.radiowaves.up.forward"),
                (.speedtest, "Speed", "speedometer")
            ]
        }
        var options: [(MapDisplayItem.Kind, String, String)] = [
            (.antenna, "Antennes", "antenna.radiowaves.left.and.right"),
            (.speedtest, "Speed", "speedometer"),
            (.coverage, "Couverture", "dot.radiowaves.left.and.right"),
            (.photo, "Photos", "photo"),
            (.validation, "Valid.", "checkmark.seal"),
            (.friend, "Amis", "person.2")
        ]
        if model.supportsCommunityLayers {
            options.append((.communitySite, "Sites comm.", "dot.radiowaves.up.forward"))
        }
        return options
    }

    private var activeLayerCount: Int {
        [.antenna, .speedtest, .coverage, .photo, .validation, .friend, .outage, .planned, .communitySite]
            .filter(filters.contains)
            .count
    }

    private var activeFilterCount: Int {
        var count = 0
        if model.marketFilter != "FR" { count += 1 }
        if model.operatorFilter != model.defaultOperatorKeyForCurrentMarket { count += 1 }
        if !model.techFilters.isEmpty { count += 1 }
        if !model.bandFilters.isEmpty { count += 1 }
        if !model.sharingFilters.isEmpty { count += 1 }
        if model.speedtestDays != 0 { count += 1 }
        if model.coverageDays != 0 { count += 1 }
        if filters != [.antenna, .speedtest] { count += 1 }
        return count
    }

    private func centerOnCurrentLocation() {
        Task {
            if let location = await services.location.currentLocation(timeoutSeconds: 8) {
                let coordinate = location.coordinate
                mapCenter = coordinate
                mapZoom = 15
                position = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                ))
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
                Text("Qualité RSRP").sqKicker()

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

    private var searchSuggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                ForEach(model.searchResults.prefix(8)) { site in
                    Button {
                        if let lat = site.latitude, let lng = site.longitude {
                            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                            mapCenter = coordinate
                            mapZoom = 15
                            position = .region(MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            ))
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
                    tint: model.operatorAccent(site.operators.first ?? model.operatorFilter)
                )
            }
            payloads += clusteredAntennaPayloads(from: antennaPayloads)
        }
        payloads += communitySitePayloads
        payloads += photoPayloads
        return payloads
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
    private var photoPayloads: [MapAnnotationPayload] {
        guard filters.contains(.photo) else { return [] }
        var seen = Set<String>()
        return model.snapshot.photos.compactMap { photo -> MapAnnotationPayload? in
            guard let lat = photo.lat, let lng = photo.lng else { return nil }
            guard seen.insert(photo.id).inserted else { return nil }
            return MapAnnotationPayload(
                id: "photo-\(photo.id)",
                kind: .photo,
                title: "Photo",
                subtitle: photo.siteId ?? "Site",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                metric: nil,
                backendId: photo.id,
                details: MapItemDetails(
                    timestamp: photo.uploadedAt,
                    note: photo.description
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                thumbnailURL: photo.thumbnailUrl ?? photo.imageUrl
            )
        }
    }

    private var coverageHeatFeatures: [CoverageHeatFeature] {
        guard filters.contains(.coverage) else { return [] }
        var features: [CoverageHeatFeature] = []
        for tile in model.coverageTiles {
            features += tile.clusters.map { cluster in
                CoverageHeatFeature(
                    id: "coverage-heat-cluster-\(cluster.id)",
                    coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                    weight: min(max(Double(cluster.count), 1), 40) / 8,
                    rsrp: cluster.avgRsrp
                )
            }
            let shouldIncludeRawPoints = mapZoom >= 13 || tile.clusters.isEmpty
            if shouldIncludeRawPoints {
                let pointLimit = mapZoom >= 13 ? 900 : 250
                features += tile.points.prefix(pointLimit).map { point in
                    CoverageHeatFeature(
                        id: "coverage-heat-\(point.id)",
                        coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                        weight: coverageHeatWeight(rsrp: point.rsrp),
                        rsrp: point.rsrp
                    )
                }
            }
        }
        if features.isEmpty {
            features = model.coverageHeat.prefix(1200).map { point in
                CoverageHeatFeature(
                    id: "coverage-heat-api-\(point.id)",
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    weight: coverageHeatWeight(rsrp: point.signalStrength),
                    rsrp: point.signalStrength
                )
            }
        }
        return features
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

    private func clusteredAntennaPayloads(from payloads: [MapAnnotationPayload]) -> [MapAnnotationPayload] {
        guard mapZoom < 14, payloads.count > 160 else { return payloads }
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
            let operators = Set(group.map(\.subtitle).filter { !$0.isEmpty }).prefix(2).joined(separator: " · ")
            return MapAnnotationPayload(
                id: "antenna-cluster-\(Int(lat / cellSize))-\(Int(lng / cellSize))",
                kind: .antenna,
                title: "\(group.count) antennes",
                subtitle: operators.isEmpty ? "Zoomer pour les détails" : operators,
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
        // Les photos ont leur propre couche riche (vignettes) construite dans
        // `photoPayloads` ; on les retire du mapping générique en pastille.
        let socialFilters = filters.subtracting([.speedtest, .coverage, .antenna, .photo])
        var items = model.snapshot.displayItems(include: socialFilters)
        if filters.contains(.speedtest) {
            items += model.speedtestTiles.flatMap { tile in
                tile.clusters.map { cluster in
                    MapDisplayItem(
                        id: "speed-cluster-\(cluster.id)",
                        kind: .speedtest,
                        title: "\(cluster.count) speedtests",
                        subtitle: model.operatorLabel(model.operatorFilter),
                        coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                        metric: "cluster",
                        details: MapItemDetails(
                            tech: cluster.tech,
                            timestamp: cluster.latestTimestamp,
                            operatorName: model.operatorLabel(model.operatorFilter),
                            clusterCount: cluster.count
                        )
                    )
                } + tile.markers.map { marker in
                    MapDisplayItem(
                        id: "speed-\(marker.id)",
                        kind: .speedtest,
                        title: "\(Int(marker.downloadMbps.rounded())) Mbps",
                        subtitle: [model.operatorLabel(model.operatorFilter), marker.tech].compactMap { $0 }.joined(separator: " · "),
                        coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                        metric: marker.uploadMbps.map { "\(Int($0.rounded())) Mbps up" },
                        backendId: marker.id,
                        details: MapItemDetails(
                            downloadMbps: marker.downloadMbps,
                            uploadMbps: marker.uploadMbps,
                            pingMs: marker.pingMs,
                            tech: marker.tech,
                            timestamp: marker.timestamp,
                            operatorName: model.operatorLabel(model.operatorFilter),
                            note: "Données Speedtest backend"
                        )
                    )
                }
            }
        }
        // Coverage intentionally stays out of annotation payloads: the visible
        // layer is only the soft halo rendered by addCoverageQualityLayers.
        if filters.contains(.planned) {
            items += model.plannedSites.compactMap { site in
                guard let lat = site.lat, let lon = site.lon else { return nil }
                return MapDisplayItem(
                    id: "planned-\(site.id)",
                    kind: .planned,
                    title: site.codeSite ?? "Site previsionnel",
                    subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    metric: site.technologies.joined(separator: " / ")
                )
            }
        }
        if filters.contains(.outage) {
            items += model.outages.compactMap { site in
                guard let lat = site.lat, let lon = site.lon else { return nil }
                return MapDisplayItem(
                    id: "outage-\(site.id)",
                    kind: .outage,
                    title: site.siteId ?? "Site en panne",
                    subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    metric: site.status
                )
            }
        }
        return items.filter(matches(filterItem:))
    }

    private func matches(filterItem item: MapDisplayItem) -> Bool {
        if item.kind == .antenna { return true }
        let haystack = "\(item.title) \(item.subtitle) \(item.metric ?? "")".lowercased()
        if model.operatorFilter != "ALL" && !haystack.contains(model.operatorFilter.lowercased()) {
            return false
        }
        if !model.techFilters.isEmpty {
            let any = model.techFilters.contains { haystack.contains($0.lowercased()) }
            if !any { return false }
        }
        return true
    }

    private func selectAnnotation(_ annotation: MapAnnotationPayload) {
        Haptics.light()
        if let antennaId = annotation.antennaId,
           let site = model.antennas.first(where: { $0.id == antennaId }) {
            selectedAntenna = site
            return
        }
        if annotation.id.hasPrefix("antenna-cluster-") {
            mapCenter = annotation.coordinate
            mapZoom = min(mapZoom + 1.7, 15.5)
            return
        }
        // Photo : viewer plein écran riche (infos antenne, like, commentaires).
        if annotation.kind == .photo, let photoId = annotation.backendId {
            selectedPhoto = MapPhotoTarget(id: photoId, thumbnailURL: annotation.thumbnailURL)
            return
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

    private var marketOptions: [(String, String)] {
        guard !allMarkets.isEmpty else {
            // Registre pas encore chargé : au moins la France reste sélectionnable.
            return [("FR", "France")]
        }
        var seen = Set<String>()
        return allMarkets.compactMap { entry in
            let code = entry.marketCode.isEmpty ? entry.code : entry.marketCode
            guard seen.insert(code.uppercased()).inserted else { return nil }
            return (code, entry.label)
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
            (.coverage, "Couverture backend", "dot.radiowaves.left.and.right"),
            (.validation, "Validations", "checkmark.seal"),
            (.outage, "Pannes", "exclamationmark.triangle"),
            (.planned, "Prévisionnels", "calendar.badge.clock")
        ]
        if selectedEntry?.capabilities.communityLayers == true {
            options.append((.communitySite, "Sites communautaires", "dot.radiowaves.up.forward"))
        }
        return options
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.md + 2) {
                    filterSection("Zone", icon: "globe.europe.africa.fill") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(marketOptions, id: \.0) { code, label in
                                filterChip(title: label, icon: "mappin.and.ellipse", active: market == code) {
                                    market = code
                                }
                            }
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
                            ForEach(["2G", "3G", "4G", "5G"], id: \.self) { tech in
                                filterChip(title: tech, icon: "cellularbars", active: technologies.contains(tech)) {
                                    toggleTechnology(tech)
                                }
                            }
                        }
                    }

                if market == "FR" {
                        filterSection("Partage", icon: "point.3.connected.trianglepath.dotted") {
                            LazyVGrid(columns: filterColumns, spacing: 8) {
                                filterChip(title: "ZB", icon: "antenna.radiowaves.left.and.right", active: sharing.contains("ZB")) {
                                    toggleSharing("ZB")
                                }
                                filterChip(title: "Crozon SFR", icon: "arrow.triangle.branch", active: sharing.contains("CROZON_LEADER_SFR")) {
                                    toggleSharing("CROZON_LEADER_SFR")
                                }
                                filterChip(title: "Crozon Bytel", icon: "arrow.triangle.branch", active: sharing.contains("CROZON_LEADER_BOUYGUES")) {
                                    toggleSharing("CROZON_LEADER_BOUYGUES")
                                }
                                filterChip(title: "ZTD", icon: "building.2.fill", active: sharing.contains("ZTD")) {
                                    toggleSharing("ZTD")
                                }
                            }
                    }

                        filterSection("Bandes", icon: "waveform.path.ecg") {
                            LazyVGrid(columns: filterColumns, spacing: 8) {
                        ForEach([(1, "B1 / n1 (2100)"), (3, "B3 (1800)"), (7, "B7 (2600)"), (20, "B20 (800)"), (28, "B28 (700)"), (78, "n78 (3500)")], id: \.0) { band, label in
                                    filterChip(title: label, icon: "dot.radiowaves.left.and.right", active: bands.contains(band)) {
                                        toggleBand(band)
                                    }
                                }
                            }
                        }
                    }

                    filterSection("Période", icon: "calendar") {
                        periodPicker("Speedtests", selection: $speedtestDays)
                        periodPicker("Couverture", selection: $coverageDays)
                    }

                    filterSection("Couches", icon: "square.3.layers.3d") {
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
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Filtres carte")
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
                        layers = [.antenna, .speedtest]
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
    let colorScheme: ColorScheme
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onMoveEnd: (MapBounds, Double) -> Void
    let onSelect: (MapAnnotationPayload) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMoveEnd: onMoveEnd, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Self.styleURL(for: colorScheme)
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = false
        mapView.attributionButton.isHidden = false
        mapView.setCenter(center, zoomLevel: zoom, animated: false)
        mapView.tintColor = UIColor.systemOrange
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let expectedStyleURL = Self.styleURL(for: colorScheme)
        if mapView.styleURL != expectedStyleURL {
            mapView.styleURL = expectedStyleURL
        }

        context.coordinator.setCoverageHeatFeatures(coverageHeatFeatures, mapView: mapView)
        context.coordinator.applyAnnotations(annotations, mapView: mapView)
        if context.coordinator.shouldApplyCamera(center: center, zoom: zoom) {
            mapView.setCenter(center, zoomLevel: zoom, animated: true)
        }
    }

    private static func styleURL(for colorScheme: ColorScheme) -> URL {
        let style = colorScheme == .dark ? "dark-matter-gl-style" : "positron-gl-style"
        if let url = URL(string: "https://basemaps.cartocdn.com/gl/\(style)/style.json") { return url }
        if let bundled = Bundle.main.url(forResource: "MapLibreStyle", withExtension: "json") { return bundled }
        // Constant fallback; URL(fileURLWithPath:) is non-failable so we never crash.
        return URL(string: "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json")
            ?? URL(fileURLWithPath: "/")
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let onMoveEnd: (MapBounds, Double) -> Void
        private let onSelect: (MapAnnotationPayload) -> Void
        private var lastCenter: CLLocationCoordinate2D?
        private var lastZoom: Double?
        private var latestCoverageHeatFeatures: [CoverageHeatFeature] = []
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
            updateCoverageHeatmap(mapView: mapView, features: latestCoverageHeatFeatures)
        }

        func updateCoverageHeatmap(mapView: MLNMapView, features: [CoverageHeatFeature]) {
            guard let style = mapView.style else { return }
            let featuresByQuality = Dictionary(grouping: features, by: \.quality)
            for band in CoverageQualityBand.allCases {
                let pointFeatures = (featuresByQuality[band] ?? []).map { feature -> MLNPointFeature in
                    let point = MLNPointFeature()
                    point.coordinate = feature.coordinate
                    point.attributes = [
                        "weight": max(0.2, min(feature.weight, 6.0)),
                        "rsrp": feature.rsrp ?? -999
                    ]
                    return point
                }
                let shape = MLNShapeCollectionFeature(shapes: pointFeatures)
                let sourceId = coverageSourceId(for: band)
                if let source = style.source(withIdentifier: sourceId) as? MLNShapeSource {
                    source.shape = shape
                } else {
                    let source = MLNShapeSource(identifier: sourceId, features: pointFeatures, options: nil)
                    style.addSource(source)
                    addCoverageQualityLayers(for: band, source: source, style: style)
                }

                let hidden = pointFeatures.isEmpty
                style.layer(withIdentifier: coverageAuraLayerId(for: band))?.isVisible = !hidden
                style.layer(withIdentifier: coverageGlowLayerId(for: band))?.isVisible = !hidden
                applyCoverageHaloStyle(for: band, style: style, zoom: mapView.zoomLevel)
            }
        }

        private func addCoverageQualityLayers(for band: CoverageQualityBand, source: MLNShapeSource, style: MLNStyle) {
            // Halo only: a broad aura keeps coverage legible when zoomed out,
            // while the closer glow preserves signal-quality color at street level.
            let auraLayer = MLNCircleStyleLayer(identifier: coverageAuraLayerId(for: band), source: source)
            auraLayer.circleBlur = NSExpression(forConstantValue: 1.0)
            auraLayer.circleColor = NSExpression(forConstantValue: band.uiColor)
            style.addLayer(auraLayer)

            let glowLayer = MLNCircleStyleLayer(identifier: coverageGlowLayerId(for: band), source: source)
            glowLayer.circleColor = NSExpression(forConstantValue: band.uiColor)
            style.addLayer(glowLayer)
            applyCoverageHaloStyle(for: band, style: style, zoom: 11)
        }

        private func applyCoverageHaloStyle(for band: CoverageQualityBand, style: MLNStyle, zoom: Double) {
            let halo = coverageHaloStyle(for: band, zoom: zoom)
            if let auraLayer = style.layer(withIdentifier: coverageAuraLayerId(for: band)) as? MLNCircleStyleLayer {
                auraLayer.circleRadius = NSExpression(forConstantValue: halo.auraRadius)
                auraLayer.circleOpacity = NSExpression(forConstantValue: halo.auraOpacity)
            }
            if let glowLayer = style.layer(withIdentifier: coverageGlowLayerId(for: band)) as? MLNCircleStyleLayer {
                glowLayer.circleRadius = NSExpression(forConstantValue: halo.glowRadius)
                glowLayer.circleBlur = NSExpression(forConstantValue: halo.glowBlur)
                glowLayer.circleOpacity = NSExpression(forConstantValue: halo.glowOpacity)
            }
        }

        private func coverageHaloStyle(for band: CoverageQualityBand, zoom: Double) -> CoverageHaloStyle {
            let zoomScale: Double
            switch zoom {
            case ..<7: zoomScale = 2.25
            case ..<9: zoomScale = 1.85
            case ..<11: zoomScale = 1.45
            case ..<13: zoomScale = 1.15
            default: zoomScale = 0.92
            }
            let unknownScale = band == .unknown ? 0.72 : 1
            let lowZoomBoost = zoom < 9 ? 1.12 : 1
            return CoverageHaloStyle(
                auraRadius: 42 * zoomScale * unknownScale,
                auraOpacity: (band == .unknown ? 0.08 : 0.15) * lowZoomBoost,
                glowRadius: 24 * zoomScale * unknownScale,
                glowOpacity: (band == .unknown ? 0.18 : 0.42) * lowZoomBoost,
                glowBlur: zoom < 10 ? 0.97 : 0.9
            )
        }

        private func coverageSourceId(for band: CoverageQualityBand) -> String {
            "sq-coverage-quality-source-\(band.rawValue)"
        }

        private func coverageAuraLayerId(for band: CoverageQualityBand) -> String {
            "sq-coverage-quality-aura-\(band.rawValue)"
        }

        private func coverageGlowLayerId(for band: CoverageQualityBand) -> String {
            "sq-coverage-quality-glow-\(band.rawValue)"
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
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

    private init() {
        cache.countLimit = 240
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        session = URLSession(configuration: config)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Charge la vignette (cache → réseau). Retourne `nil` en cas d'échec.
    func loadImage(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await session.data(from: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
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
            glyphView.image = UIImage(systemName: payload.systemImageName)
            glyphView.frame = markerView.bounds.insetBy(dx: 6, dy: 6)
        }
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
            await self?.applyThumbnail(image, for: url)
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
            if subtitle.localizedCaseInsensitiveContains("Bouygues") { return Color(red: 0.0, green: 0.62, blue: 0.86) }
            if subtitle.localizedCaseInsensitiveContains("SFR") { return .red }
            return .red
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
