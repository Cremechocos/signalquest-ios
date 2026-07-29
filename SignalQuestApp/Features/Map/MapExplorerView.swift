import SwiftUI
import MapKit
import ImageIO

/// Un lieu géocodé (ville / adresse / POI) via `MKLocalSearch`, unifié avec les
/// antennes dans les résultats de recherche de la carte.
struct PlaceResult: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double
}

/// Résultat de recherche unifié : une antenne/site OU un lieu (ville/adresse).
enum MapSearchResult: Identifiable, Equatable {
    case antenna(AntennaSite)
    case place(PlaceResult)

    var id: String {
        switch self {
        case .antenna(let site): return "antenna-\(site.id)"
        case .place(let place): return place.id
        }
    }
}

@MainActor
final class MapExplorerViewModel: ObservableObject {
    @Published var snapshot: SocialMapSnapshot = .empty
    /// Amis en temps réel (position + présence + radio) alimentés par le SSE
    /// `/api/social/map/stream`. Tenu à part de `snapshot.friends` pour ne pas
    /// entrer en course avec les rechargements bornés de `load()` : le flux n'est
    /// pas géo-borné et fait autorité dès qu'il a répondu.
    @Published var liveFriends: [SocialFriendLive] = []
    /// Vrai dès que le flux temps réel a livré au moins un instantané : `load()`
    /// cesse alors d'amorcer `liveFriends` depuis le snapshot borné.
    private var friendsFromStream = false
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
    /// Signal SÉPARÉ des instantanés d'amis temps réel (SSE), distinct de
    /// `dataVersion` : à chaque tick la vue ne reconstruit QUE la couche amis
    /// (PERF-MAP-05) au lieu de recalculer antennes / speedtests / couverture.
    @Published private(set) var friendsVersion = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Marché + opérateur initiaux : dernier choix persisté, sinon le pays de la
    // locale appareil (jamais la France imposée). La détection fine (SIM/GPS) est
    // appliquée ensuite dans `resolveInitialSelection`.
    @Published var marketFilter = MapMarketStore.initialMarketCode()
    @Published var operatorFilter = MapMarketStore.initialOperatorKey()
    /// Territoire DROM sous le viewport (Martinique, Réunion…) — restreint la liste
    /// d'opérateurs à ceux du territoire (les opérateurs Outre-mer sont géographiquement
    /// disjoints). `nil` hors DROM. Cf. `DromRegion`.
    @Published var currentDromRegion: DromRegion?
    @Published var techFilters: Set<String> = []
    @Published var bandFilters: Set<Int> = []
    @Published var sharingFilters: Set<String> = []
    /// Statuts prévisionnels visibles (croisement ANFR). Par défaut : les 4.
    /// Filtre 100 % client (les sites sont déjà chargés) → pas de refetch backend.
    @Published var plannedStatusFilters: Set<PlannedActivationStatus> = MapPlannedStatusStore.load()
    /// Inclure les cellules seulement « observées » (vs sites probables
    /// consolidés) dans la couche communautaire.
    @Published var includeObservedSites = true
    @Published var speedtestDays = 0
    @Published var coverageDays = 0
    @Published var searchQuery: String = ""
    @Published var searchResults: [MapSearchResult] = []
    /// Recherche en cours (spinner de la barre) — distinct du chargement des tuiles.
    @Published var isSearching = false
    /// Dernière recherche en échec (réseau/géocodage) → message distinct de « aucun résultat ».
    @Published var searchFailed = false
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
    /// Recherche courante (annulée à chaque nouvelle frappe → pas de résultat obsolète).
    private var searchTask: Task<Void, Never>?
    /// Dernier centre caméra connu — biais de proximité de la recherche de lieux.
    private var lastCenter: CLLocationCoordinate2D?
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
        // Marché : on respecte la sélection persistée si elle correspond au marché
        // détecté (on ne la remplace pas).
        let persistedMarketMatches = MapMarketStore.lastMarket()?.uppercased() == marketCode.uppercased()

        // 2. Opérateur : celui de la SIM/réseau RÉEL (IP/ASN hors VPN → MNC). C'est le
        // DÉFAUT de la carte, appliqué MÊME quand le marché est persisté (avant, l'early-
        // return bloquait l'opérateur sur le dernier choix / « Tous »). Si la détection
        // échoue (WiFi, VPN, pas de cellulaire) on garde l'opérateur courant/persisté.
        var detectedOperator: String?
        if status.connection == .cellular {
            if let detected = await networkOperator.resolve(viaVpn: VPNDetector.isActive()),
               let key = detected.operatorKey,
               entry.operatorEntry(forKey: key) != nil {
                detectedOperator = key
            } else if let mcc = status.operatorMcc, let mnc = status.operatorMnc,
                      let key = entry.radioOperatorKey(mcc: mcc, mnc: mnc) {
                // SIM DROM (MCC 340/647, MNC seul ambigu) → opérateur exact via radioOperators/PLMN.
                detectedOperator = key
            } else if let mnc = status.operatorMnc,
                      let op = entry.selectableOperators.first(where: { $0.mncs.contains(mnc) }) {
                detectedOperator = op.key
            }
        }

        // 3. Application (les onChange court-circuitent grâce au flag).
        initialSelectionInProgress = true
        currentMarketEntry = entry
        if let detectedOperator, operatorFilter.uppercased() != detectedOperator.uppercased() {
            operatorFilter = detectedOperator
        }
        if !persistedMarketMatches, marketFilter.uppercased() != marketCode.uppercased() {
            marketFilter = marketCode
        }
        MapMarketStore.save(market: persistedMarketMatches ? marketFilter : marketCode, operator: operatorFilter)
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
        // DROM : caler le territoire courant (et purger un opérateur d'un autre DOM)
        // dès le changement de marché, sans attendre le prochain arrêt caméra.
        if let center = lastCenter { updateDromRegion(for: center) }
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
        // DROM : restreindre aux opérateurs du TERRITOIRE courant (Martinique ≠ Réunion).
        // Sans ça, la liste mélange les 9 opérateurs Outre-mer tous territoires confondus
        // (« les DROM ne sont pas séparés »).
        if entry.marketCode.uppercased() == "DROM", let region = currentDromRegion {
            keys = keys.filter { region.allows(operatorKey: $0) }
        }
        if !keys.contains(where: { $0.uppercased() == "ALL" }) {
            keys.append("ALL")
        }
        return keys
    }

    func operatorShortLabel(_ key: String) -> String {
        if let entry = currentMarketEntry?.operatorEntry(forKey: key) {
            return entry.shortLabel
        }
        return key.uppercased() == "ALL" ? String(localized: "Tous") : key
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

    // Les jeux de démonstration ci-dessous contiennent des identifiants de
    // photos et des URLs S3 de PRODUCTION. `#if DEBUG` porte sur la déclaration
    // elle-même, et pas seulement sur les appels : l'élimination de branche
    // morte ne garantit pas que le compilateur retire les littéraux de la
    // section `__cstring` du binaire. C'est le seul moyen sûr qu'ils ne soient
    // pas lisibles dans une archive signée (SECURITY-04).
    #if DEBUG
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
    #endif

    // MARK: Changement automatique de marché (caméra idle)

    /// Appelé à chaque fin de déplacement caméra. Debounce 600 ms puis
    /// résolution du marché sous le centre de la carte.
    func scheduleMarketDetection(center: CLLocationCoordinate2D) {
        lastCenter = center   // biais de proximité pour la recherche de lieux (MKLocalSearch)
        updateDromRegion(for: center)
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
        if let center = lastCenter { updateDromRegion(for: center) }
        showMarketNotice("Marché : \(entry.label)")
    }

    /// Met à jour le territoire DROM courant depuis le centre du viewport, et réaligne
    /// l'opérateur (retour « Tous ») si le courant n'appartient pas au nouveau territoire
    /// — sinon un opérateur d'un autre DOM resterait sélectionné (ex. SRR en Martinique).
    /// Hors marché DROM : `nil`.
    func updateDromRegion(for center: CLLocationCoordinate2D) {
        guard marketFilter.uppercased() == "DROM" else {
            if currentDromRegion != nil { currentDromRegion = nil }
            return
        }
        let region = DromRegion.from(center)
        guard region != currentDromRegion else { return }
        currentDromRegion = region
        if let region {
            if !region.allows(operatorKey: operatorFilter) {
                operatorFilter = "ALL"
            }
            showMarketNotice("Territoire : \(region.flag) \(region.shortName)")
        }
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
            #if DEBUG
            // QA (DEBUG) : injecte de vraies photos géolocalisées même en démo pour
            // visualiser/capturer le rendu de la couche Photos (publicPhotos).
            if AppEnvironment.usesDemoPhotos {
                snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
                publicPhotos = Self.demoPublicPhotos(around: bounds)
            }
            if AppEnvironment.usesDemoFriends {
                liveFriends = Self.demoFriends(around: bounds)
                publicPhotos = Self.demoPublicPhotos(around: bounds)
                snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
            }
            #endif
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
        // Couverture masquée en « Tous » (superposer tous les opérateurs n'a pas de
        // sens) → on ne la télécharge même pas dans ce cas.
        let wantsCoverage = filters.contains(.coverage) && op.uppercased() != "ALL"

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
        // tiles non-nil → tuiles disponibles ; list non-nil → repli sur la liste bbox.
        // ROB-08 : `tiles`/`list` nil AVEC `error` non-nil ⇒ échec réseau réel (la
        // couche précédente sera conservée + toast) ; nil SANS error ⇒ annulation
        // (couche conservée, sans toast). Le repli tuiles→liste reste silencieux
        // (best-effort) ; seul l'échec TERMINAL (liste indisponible) est signalé.
        async let antennaRaw: (tiles: [AndroidAntennaTileResponse]?, list: [AntennaSite]?, error: String?) = {
            guard wantsAntenna else { return (nil, [], nil) }
            let usesAdvancedAntennaFilters = !techs.isEmpty || !bands.isEmpty || !sharing.isEmpty
            if !usesAdvancedAntennaFilters,
               let tiles = try? await svc.antennaTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, withAzimuth: true, bands: bands) {
                return (tiles, nil, nil)
            }
            do {
                let list = try await antennasSvc.list(bbox: bounds.asBoundingBox, market: market, operatorName: op, technologies: techs, bands: bands, sharing: sharing)
                return (nil, list, nil)
            } catch {
                return (nil, nil, error.isCancellation ? nil : error.localizedDescription)
            }
        }()
        async let communityRaw: (value: [AndroidCommunitySiteTileResponse]?, error: String?) = {
            guard wantsCommunitySites else { return ([], nil) }
            do { return (try await svc.communitySiteTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, includeObserved: includeObserved, bands: bands), nil) }
            catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        async let speedtestRaw: (value: [AndroidSpeedtestTileResponse]?, error: String?) = {
            guard wantsSpeedtest else { return ([], nil) }
            do { return (try await svc.speedtestTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: stDays, bands: bands, maxAge: nil), nil) }
            catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        // Prévisionnels & pannes : respectent le filtre opérateur de la carte
        // (l'opérateur sélectionné `op`, ou ALL quand « Tous » est choisi). Le
        // backend FR accepte ALL comme un opérateur précis.
        async let plannedRaw: (value: [PlannedSiteLive]?, error: String?) = {
            guard wantsPlanned else { return ([], nil) }
            do {
                let sites = try await svc.plannedSites(market: market, operatorName: op, territory: territory, bands: bands)
                return (sites.filter { bounds.contains(lat: $0.lat, lon: $0.lon) }, nil)
            } catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        async let outageRaw: (value: [OutageSiteLive]?, error: String?) = {
            guard wantsOutage else { return ([], nil) }
            do {
                let sites = try await svc.outageSites(market: market, operatorName: op, territory: territory, bands: bands)
                return (sites.filter { bounds.contains(lat: $0.lat, lon: $0.lon) }, nil)
            } catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
        }()
        async let coverageRaw: (value: (tiles: [AndroidCoverageTileResponse], heat: [CoverageHeatPoint])?, error: String?) = {
            guard wantsCoverage else { return (([], []), nil) }
            let tiles = (try? await svc.coverageTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: covDays, bands: bands, maxAge: nil)) ?? []
            if tiles.isEmpty {
                // Repli points bruts : source TERMINALE de la couche → son échec est
                // signalé (couche conservée) au lieu d'être avalé en « vide ».
                do {
                    let points = try await svc.coveragePoints(bounds: bounds, market: market, operatorName: op, technology: techs.sorted().first, bands: bands)
                    return (([], points), nil)
                } catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
            }
            return ((tiles, []), nil)
        }()
        async let photosRaw: (value: [MapPublicPhoto]?, error: String?) = {
            guard wantsPhoto else { return ([], nil) }
            // Couche communautaire : on veut TOUTES les photos des membres, quel que
            // soit le filtre opérateur des antennes → opérateur forcé à "ALL". Seul le
            // mode « Amis » restreint l'ensemble.
            do { return (try await svc.publicPhotos(bounds: bounds, zoom: zoom, market: market, operatorName: "ALL", friendsOnly: photosFriendsOnly), nil) }
            catch { return (nil, error.isCancellation ? nil : error.localizedDescription) }
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

        // ROB-08 : agrège les échecs RÉELS de couche. Chaque assignation ci-dessous
        // est gardée — une couche qui échoue CONSERVE ses données précédentes et
        // alimente ce message ; une couche « chargée mais vide » écrase normalement
        // (état vide légitime). Publié en fin de `load` via le toast d'erreur existant.
        var layerError: String?

        if let value = snap.snapshot {
            snapshot = value
        } else if let error = snap.error {
            // Snapshot indisponible : on conserve le précédent (validations / sessions
            // / amorçage amis déjà affichés) plutôt que de tout vider en « aucune donnée ».
            layerError = error
        }
        #if DEBUG
        // QA (DEBUG) : injecte de vraies photos publiques géolocalisées pour
        // vérifier le rendu des vignettes + le viewer.
        if AppEnvironment.usesDemoPhotos {
            snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
        }
        #endif

        if let tiles = antenna.tiles {
            antennaClusters = tiles.flatMap(\.clusters)
            antennas = Self.antennas(from: tiles).filter(\.hasValidCoordinate)
        } else if let list = antenna.list {
            antennaClusters = []
            antennas = list.filter(\.hasValidCoordinate)
        } else if let error = antenna.error {
            // Échec réseau : on garde les antennes/clusters déjà affichés.
            layerError = layerError ?? error
        }

        if let value = community.value { communitySiteTiles = value }
        else if let error = community.error { layerError = layerError ?? error }

        if let value = speedtest.value { speedtestTiles = value }
        else if let error = speedtest.error { layerError = layerError ?? error }

        if let value = planned.value { plannedSites = value }
        else if let error = planned.error { layerError = layerError ?? error }

        if let value = outage.value { outages = value }
        else if let error = outage.error { layerError = layerError ?? error }

        if let value = coverage.value {
            coverageTiles = value.tiles
            coverageHeat = value.heat
        } else if let error = coverage.error {
            layerError = layerError ?? error
        }
        // QA (DEBUG) : injecte des photos publiques de démo pour visualiser la
        // couche (le compte de test n'a pas forcément de photos géolocalisées).
        if AppEnvironment.usesDemoPhotos {
            #if DEBUG
            publicPhotos = Self.demoPublicPhotos(around: bounds)
            #endif
        } else if let value = photos.value {
            publicPhotos = value
        } else if let error = photos.error {
            // Échec réseau : on garde les photos déjà affichées.
            layerError = layerError ?? error
        }
        // Amorçage des amis vivants depuis le snapshot borné tant que le flux
        // temps réel n'a rien livré (fallback si le SSE est indisponible).
        if !friendsFromStream {
            liveFriends = snapshot.friends
        }
        // QA (DEBUG) : amis de démo pour visualiser/capturer le rendu « Find My ».
        if AppEnvironment.usesDemoFriends {
            #if DEBUG
            liveFriends = Self.demoFriends(around: bounds)
            #endif
        }
        // ROB-08 : nil si tout a réussi (errorMessage déjà remis à nil en début de
        // `load`) ; sinon signale l'indisponibilité sans avoir écrasé les couches.
        errorMessage = layerError
        dataVersion &+= 1
    }

    /// Applique un instantané du flux temps réel des amis. Fait autorité sur
    /// l'amorçage borné : `load()` cesse ensuite de réécrire `liveFriends`.
    func applyLiveFriends(_ friends: [SocialFriendLive]) {
        friendsFromStream = true
        // PERF-MAP-05 : garde de diff — un tick identique (ami immobile, même
        // présence/radio) ne déclenche AUCUN travail de rendu.
        guard friends != liveFriends else { return }
        liveFriends = friends
        // Ne bumpe PAS `dataVersion` (qui reconstruirait TOUTES les couches) : seul
        // `friendsVersion` → la vue ne rafraîchit que la couche amis (PERF-MAP-05).
        friendsVersion &+= 1
    }

    // Idem : identifiants et URLs S3 de production, plus des amis fictifs
    // nommés. Déclarations gardées, pas seulement les appels.
    #if DEBUG
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

    /// Amis vivants de démonstration (QA) autour du viewport : présence, cap et
    /// snapshot radio variés pour visualiser/capturer le rendu « Find My » sans
    /// amis réels partageant leur position.
    static func demoFriends(around bounds: MapBounds) -> [SocialFriendLive] {
        // Coordonnées ABSOLUES fixes (Grenoble). En prod les positions viennent du
        // serveur, stables entre deux relevés d'un ami immobile ; ici on ne les
        // ancre PAS au centre du viewport (qui micro-varie à chaque `load()` et
        // recréerait les annotations en boucle, empêchant l'avatar de se rendre).
        let lat = 45.1885
        let lon = 5.7245
        struct Seed {
            let name: String; let avatar: String?; let status: String
            let dLat: Double; let dLon: Double; let heading: Double?
            let tech: String?; let op: String?; let rsrp: Double?
        }
        let seeds: [Seed] = [
            Seed(name: "Camille", avatar: "https://s3.signalquest.fr/photos/thumbnails/615909_1781215890861_thumb.webp", status: "online", dLat: 0.0032, dLon: 0.0021, heading: 40, tech: "5G", op: "Orange", rsrp: -92),
            Seed(name: "Malik", avatar: "https://s3.signalquest.fr/photos/thumbnails/615909_1781215888538_thumb.webp", status: "online", dLat: -0.0026, dLon: 0.0040, heading: 175, tech: "4G", op: "Free", rsrp: -105),
            Seed(name: "Léa", avatar: nil, status: "away", dLat: 0.0041, dLon: -0.0030, heading: nil, tech: nil, op: "SFR", rsrp: nil),
            Seed(name: "Yannick", avatar: "https://s3.signalquest.fr/photos/thumbnails/615909_1781215885580_thumb.webp", status: "dnd", dLat: -0.0040, dLon: -0.0026, heading: 300, tech: "5G", op: "Bouygues", rsrp: -78)
        ]
        return seeds.enumerated().map { index, seed in
            let radio: SocialRadioSnapshot? = (seed.tech != nil || seed.op != nil)
                ? SocialRadioSnapshot(technology: seed.tech, rsrp: seed.rsrp, rsrq: nil, snr: nil, pci: nil, enb: nil, gnb: nil, cellId: nil, band: seed.tech == "5G" ? 78 : 7, `operator`: seed.op, city: "Grenoble", updatedAt: Date())
                : nil
            return SocialFriendLive(
                id: "demo-friend-\(index)",
                name: seed.name,
                avatarUrl: seed.avatar.flatMap { URL(string: $0) },
                presence: SocialPresence(status: seed.status, customStatus: nil, lastSeenAt: Date(), isOnline: seed.status == "online"),
                location: SocialLiveLocation(lat: lat + seed.dLat, lng: lon + seed.dLon, accuracy: 30, heading: seed.heading, speed: seed.heading != nil ? 4 : 0, updatedAt: Date()),
                radio: radio,
                privacy: nil
            )
        }
    }
    #endif

    /// Recherche à la frappe : anti-rebond ~300 ms + annulation de la précédente.
    /// Appelée depuis `.onChange(searchQuery)`.
    func scheduleSearch() {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []; isSearching = false; searchFailed = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(q)
        }
    }

    /// Recherche immédiate (touche Entrée) : annule tout anti-rebond en cours.
    func search() async {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        await performSearch(q)
    }

    /// Exécute la recherche : antennes (backend) ET lieux (ville/adresse via
    /// MKLocalSearch, Apple) EN PARALLÈLE, puis fusionne. Annulable.
    private func performSearch(_ q: String) async {
        isSearching = true
        searchFailed = false
        async let antennasResult = (try? await antennasService.quickSearch(query: q)) ?? []
        async let placesResult = geocodePlaces(q)
        let antennas = await antennasResult
        let places = await placesResult
        guard !Task.isCancelled, searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
        let merged = Self.mergeSearchResults(places: places, antennas: antennas)
        searchResults = merged
        searchFailed = merged.isEmpty && !q.isEmpty
        isSearching = false
    }

    /// Fusionne lieux (ville/adresse) et antennes : **lieux d'abord** (l'intention
    /// « ville/adresse » prime), jusqu'à 4, puis les antennes ; plafonné à 8. Pur et
    /// testable.
    static func mergeSearchResults(places: [PlaceResult], antennas: [AntennaSite]) -> [MapSearchResult] {
        Array((places.prefix(4).map { MapSearchResult.place($0) }
            + antennas.map { MapSearchResult.antenna($0) }).prefix(8))
    }

    /// Géocodage ville / adresse / POI via MapKit (moteur carte unique). Biaisé vers
    /// la région courante de la carte. Ne jette jamais (échec → liste vide).
    private func geocodePlaces(_ q: String) async -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let center = lastCenter {
            request.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
            )
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(6).compactMap { item -> PlaceResult? in
            let coord = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coord), !(coord.latitude == 0 && coord.longitude == 0) else { return nil }
            let name = item.name ?? item.placemark.title ?? q
            return PlaceResult(
                id: "place-\(coord.latitude)-\(coord.longitude)-\(name)",
                name: name,
                subtitle: item.placemark.title == name ? nil : item.placemark.title,
                latitude: coord.latitude,
                longitude: coord.longitude
            )
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

struct MapExplorerView: View {
    @StateObject private var model: MapExplorerViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mapCenter: CLLocationCoordinate2D
    @State private var mapZoom: Double
    /// Dernier palier de zoom qui affecte le RENDU des couches (clustering/cônes).
    /// Tant qu'il ne change pas, un changement de `mapZoom` ne reconstruit PAS les
    /// couches (PERF-MAP-01) : entre deux frontières, `annotationPayloads` est identique.
    @State private var lastZoomRenderBucket: Int = 0
    // Cache des couches lourdes de la carte : reconstruit uniquement quand les
    // données (`model.dataVersion`) ou les couches actives (`filters`) changent,
    // pour ne plus recalculer des milliers de structs à chaque invalidation de `body`.
    @State private var renderedAnnotations: [MapAnnotationPayload] = []
    @State private var renderedCoverageFeatures: [CoverageHeatFeature] = []
    @State private var renderedSpeedtestFeatures: [SpeedtestFeature] = []
    /// Version monotone incrémentée à chaque `refreshMapRender()` (PERF-MAP-03) :
    /// signale au MKMapView que les couches ont changé (vs simple déplacement caméra).
    @State private var renderVersion = 0
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
    @State private var selectedFriend: SocialFriendLive?
    @State private var fetchTask: Task<Void, Never>?
    @State private var lastRegion: MKCoordinateRegion
    @State private var showFilterSheet = false
    // Écrans ANFR, repris du menu Profil : c'est ici qu'on cherche une carte.
    @State private var showsANFRMap = false
    @State private var showsANFRStats = false

    init(service: MapSnapshotServicing,
         antennas: AntennasServicing,
         markets: MarketRegistryServicing) {
        _model = StateObject(wrappedValue: MapExplorerViewModel(map: service, antennas: antennas, markets: markets))
        // QA : `--reset-map` oublie région + marché/opérateur pour rejouer la détection.
        if AppEnvironment.resetsMapOnLaunch {
            MapRegionStore.reset()
            MapMarketStore.reset()
        }
        // Restaure la dernière région, sinon vue pays du marché initial (dernier
        // choix persisté ou pays de la locale) — jamais une ville ni la France imposée.
        let region = MapRegionStore.lastRegion() ?? Self.region(for: MapMarketStore.initialMarketCode())
        let initialZoom = Self.zoom(forSpan: region)
        _mapCenter = State(initialValue: region.center)
        _lastRegion = State(initialValue: region)
        _mapZoom = State(initialValue: initialZoom)
        _lastZoomRenderBucket = State(initialValue: Self.zoomRenderBucket(for: initialZoom))
    }

    var body: some View {
        ZStack {
            mapLayer
            controlsLayer
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showsANFRMap) {
            ANFRMapView(service: services.anfr)
        }
        .navigationDestination(isPresented: $showsANFRStats) {
            ANFRStatsView(service: services.anfr)
        }
        .sheet(item: $selectedItem) { item in MapItemSheet(item: item) }
        .sheet(item: $selectedOutage) { site in
            OutageDetailSheet(site: site)
        }
        .sheet(item: $selectedPlanned) { site in
            PlannedDetailSheet(site: site, operatorLabel: model.operatorLabel(site.operator ?? "ALL"), operatorAccent: model.operatorAccent(site.operator ?? "ALL"))
        }
        .sheet(item: $selectedFriend) { friend in
            FriendLiveSheet(friend: friend, userLocation: services.location.lastLocation)
                .presentationDetents([.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
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
                plannedStatuses: $model.plannedStatusFilters,
                allMarkets: model.registryMarkets
            )
            .presentationDetents([.medium, .large])
            .presentationBackgroundCompat(SQColor.bg)
        }
        .task {
            // QA (DEBUG) : pré-active les couches pour capturer leurs couleurs.
            if AppEnvironment.opensMapLayers {
                filters = [.antenna, .speedtest, .coverage]
            }
            if AppEnvironment.usesDemoPhotos {
                filters = [.photo]
            }
            if AppEnvironment.usesDemoFriends {
                filters = [.friend, .photo, .antenna]
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
                lastRegion = region
            }
            // QA (DEBUG) : cadre ville pour visualiser les marqueurs amis individuels
            // (avatars, cônes de cap, présence) plutôt qu'un cluster continental.
            if AppEnvironment.usesDemoFriends {
                let region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 45.188, longitude: 5.724),
                    latitudinalMeters: 2200, longitudinalMeters: 2200
                )
                mapCenter = region.center
                mapZoom = 14.5
                lastRegion = region
            }
            await model.load(region: lastRegion, zoom: mapZoom, filters: filters)
            model.endInitialSelection()
            refreshMapRender()
            #if DEBUG
            await runQAPanIfRequested()
            #endif
            // QA (DEBUG) : ouvre la fiche de la première antenne (attend que le
            // niveau de zoom fasse apparaître des antennes individuelles).
            if AppEnvironment.opensAntennaSheet {
                for _ in 0..<16 {
                    if let first = model.antennas.first { selectedAntenna = first; break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // QA (DEBUG) : ouvre le viewer de la première photo injectée.
            if AppEnvironment.opensPhotoSheet {
                for _ in 0..<16 {
                    if let first = model.publicPhotos.first {
                        selectedPhoto = MapPhotoTarget(id: first.id, thumbnailURL: first.thumbnailUrl)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // QA (DEBUG) : ouvre la fiche du premier ami vivant géolocalisé.
            if AppEnvironment.opensFriendSheet {
                for _ in 0..<16 {
                    if let first = model.liveFriends.first(where: { $0.location != nil }) {
                        selectedFriend = first
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // QA (DEBUG) : fait « marcher » les amis démo pour visualiser le
            // déplacement animé du marqueur (mise à jour périodique de la position).
            if AppEnvironment.walksDemoFriends {
                #if DEBUG
                Task { @MainActor [model] in
                    var friends = MapExplorerViewModel.demoFriends(around: MapBounds(north: 0, south: 0, east: 0, west: 0))
                    for _ in 0..<12 {
                        // ~4 s entre deux fixes (cadence réaliste « observé ») → le
                        // marqueur glisse en continu sur tout l'intervalle.
                        try? await Task.sleep(for: .milliseconds(4000))
                        friends = friends.map { f in
                            guard let loc = f.location else { return f }
                            return SocialFriendLive(
                                id: f.id, name: f.name, avatarUrl: f.avatarUrl, presence: f.presence,
                                location: SocialLiveLocation(lat: loc.lat + 0.0011, lng: loc.lng + 0.0006,
                                                             accuracy: loc.accuracy, heading: 55, speed: 7, updatedAt: Date()),
                                radio: f.radio, privacy: f.privacy
                            )
                        }
                        model.applyLiveFriends(friends)
                    }
                }
                #endif
            }
            // Notification/deep link antenne reçu avant l'apparition de la carte.
            openSiteFromRouterIfNeeded()
        }
        // Couche « Amis » active : publie ma présence/position (selon le toggle de
        // confidentialité + le mode) et consomme le flux temps réel des amis. Le
        // `.task(id:)` redémarre quand on active/désactive le calque ; il est
        // annulé (donc le flux se ferme) à la disparition de la carte.
        .task(id: filters.contains(.friend)) {
            guard filters.contains(.friend) else {
                services.livePresence.mapDidDisappear()
                return
            }
            services.livePresence.mapDidAppear()
            await services.livePresence.refreshSharingSettings()
            for await friends in services.map.friendsStream(sse: services.sse) {
                model.applyLiveFriends(friends)
            }
        }
        .onDisappear {
            services.livePresence.mapDidDisappear()
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
        .onChangeCompat(of: model.plannedStatusFilters) { _, newValue in
            // Filtre 100 % client : les sites prévisionnels sont déjà chargés →
            // on reconstruit juste le rendu, sans requête backend.
            MapPlannedStatusStore.save(newValue)
            refreshMapRender()
        }
        // Données rechargées → reconstruit le cache des couches une seule fois.
        .onChangeCompat(of: model.dataVersion) { _, _ in refreshMapRender() }
        // Tick SSE amis → ne reconstruit QUE la couche amis (PERF-MAP-05).
        .onChangeCompat(of: model.friendsVersion) { _, _ in refreshFriendsRender() }
        // Le zoom modifie les seuils (azimuts ≥ 14, clustering) : reconstruit aussi.
        .onChangeCompat(of: mapZoom) { _, _ in
            // Ne reconstruire les couches que si le zoom franchit une frontière de
            // rendu (clustering/cônes). Un pinch/pan continu ne recompose plus des
            // milliers de structs à chaque cran sur le main thread — PERF-MAP-01.
            let bucket = Self.zoomRenderBucket(for: mapZoom)
            guard bucket != lastZoomRenderBucket else { return }
            lastZoomRenderBucket = bucket
            refreshMapRender()
        }
        // Notification/deep link antenne : ouvre la fiche du site demandé.
        .onChangeCompat(of: router.openSiteId) { _, _ in openSiteFromRouterIfNeeded() }
        // Test de l'historique : cadre la carte sur le lieu de la mesure.
        .onChangeCompat(of: router.pendingMapFocus) { _, _ in focusFromRouterIfNeeded() }
        .onAppear { focusFromRouterIfNeeded() }
    }

    /// Cadre la carte sur la coordonnée demandée depuis un test de l'historique.
    /// Consommée une fois : l'onglet peut réapparaître sans re-cadrer.
    private func focusFromRouterIfNeeded() {
        guard let focus = router.pendingMapFocus else { return }
        router.pendingMapFocus = nil
        let coordinate = CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude)
        mapCenter = coordinate
        mapZoom = 15
        scheduleLoad(region: MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        ))
    }

    private var mapLayer: some View {
        // Moteur unique : rendu MapKit (Apple Plan natif).
        MapKitMapView(
            annotations: renderedAnnotations,
            coverageHeatFeatures: renderedCoverageFeatures,
            speedtestFeatures: renderedSpeedtestFeatures,
            renderVersion: renderVersion,
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
        // La carte file sous la barre de statut / Dynamic Island (comme Plans),
        // au lieu de laisser une bande systemBackground non-crème en haut (UI-09).
        // Les contrôles du haut sont dans un overlay qui respecte la safe area.
        .ignoresSafeArea()
    }

    #if DEBUG
    /// Hook QA (DEBUG) : `SQ_QA_PAN_TO="lat,lng[,zoom]"` déplace la caméra
    /// après stabilisation, comme la fin d'un pan utilisateur — le delegate
    /// MapKit déclenche alors la chaîne réelle de détection de marché.
    private func runQAPanIfRequested() async {
        guard let raw = ProcessInfo.processInfo.environment["SQ_QA_PAN_TO"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return }
        try? await Task.sleep(for: .seconds(4))
        if parts.count >= 3 { mapZoom = parts[2] }
        mapCenter = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
    #endif

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
                        .padding(.horizontal, SQSpace.md)
                    // Chips de couches : composant transverse déjà restylé
                    // (capsules casse normale, actif brique plein).
                    MapFilterBar(filters: $filters)
                    // Les contrôles de coloration couverture (bascule + légende) ont
                    // quitté la colonne haute (surchargée) → carte flottante bas-centre
                    // (cf. `coverageControlsOverlay`).
                    // Panneau de recherche : visible dès qu'une requête est saisie
                    // (résultats, ou message « aucun résultat »/erreur).
                    if !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchSuggestions
                            .padding(.horizontal, SQSpace.md)
                    }
                }
                .padding(.top, SQSpace.sm)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Bas-gauche : pilule opérateur seule (le statut/toast est passé au
                // centre pour ne plus se disputer la place avec les contrôles couverture).
                VStack {
                    Spacer()
                    HStack {
                        operatorPill
                        Spacer()
                    }
                    .padding(.leading, SQSpace.md)
                    .padding(.bottom, mapControlsBottomInset)
                }

                // Bas-droite : FAB localiser (unique).
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        mapFabStack
                    }
                    .padding(.trailing, SQSpace.md)
                    .padding(.bottom, mapControlsBottomInset)
                }

                // Bas-centre : statut transitoire + contrôles de coloration couverture,
                // empilés au-dessus de la rangée pilule/FAB (jamais au même niveau
                // qu'elles). Le spinner de chargement a rejoint la barre de recherche.
                coverageControlsOverlay

                marketSwitchNoticeOverlay
            }
        }
    }

    /// Dégagement bas des contrôles flottants de la carte pour la barre de navigation.
    /// Avec la barre NATIVE Liquid Glass (iOS 26+), la safe area est DÉJÀ décalée par
    /// la barre → un petit dégagement suffit. Avec le dock custom (avant iOS 26, ou QA
    /// `--qa-legacy-dock`), c'est une simple superposition qui ne décale PAS la safe
    /// area → il faut réserver toute sa hauteur (`SQDock.clearance`). Sans cette
    /// distinction, les 98 pt du dock custom s'ajoutaient PAR-DESSUS l'inset natif →
    /// grand vide entre les boutons et la barre.
    private var mapControlsBottomInset: CGFloat {
        if #available(iOS 26.0, *), !Self.forcesLegacyDock {
            return SQSpace.lg
        } else {
            return SQSpace.lg + 2 + SQDock.clearance
        }
    }

    private static var forcesLegacyDock: Bool {
        #if DEBUG
        AppEnvironment.usesLegacyDock
        #else
        false
        #endif
    }

    /// Contrôles de coloration couverture (bascule Signal/Génération + légende),
    /// affichés seulement quand la couche Couverture est active. Déplacés de la
    /// colonne haute (qui empilait jusqu'à 5 blocs). Empilé avec le statut transitoire
    /// (toast) dans une colonne centrée, ancrée juste au-dessus de la rangée basse
    /// (pilule opérateur à gauche, FAB à droite) — plus jamais en conflit avec elles.
    private var coverageControlsOverlay: some View {
        VStack(spacing: SQSpace.sm) {
            Spacer()
            if filters.contains(.coverage) {
                coverageColoringToggle
                coverageLegendCompact
            }
            mapStatusToast
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SQSpace.md)
        // Juste au-dessus de la rangée basse (pilule/FAB) : on part du même dégagement
        // qu'elle + la hauteur d'une rangée, pour empiler sans la chevaucher.
        .padding(.bottom, mapControlsBottomInset + 50)
    }

    /// Légende couverture COMPACTE : une seule capsule avec des pastilles inline
    /// (au lieu d'une pastille par bande) — beaucoup moins de « boutons » à l'écran.
    /// Suit le mode courant (génération ou RSRP).
    private var coverageLegendCompact: some View {
        HStack(spacing: SQSpace.sm + 1) {
            if coverageByGeneration {
                ForEach(CoverageGenerationBand.visibleBands) { band in
                    legendDot(color: band.swiftUIColor, text: band.title)
                }
            } else {
                ForEach(CoverageQualityBand.visibleBands) { band in
                    legendDot(color: band.swiftUIColor, text: band.title)
                }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 3)
        .background { mapGlassBackground(Capsule(style: .continuous)) }
        .sqShadowSoft()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(coverageByGeneration ? "Légende génération" : "Légende qualité du signal")
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(SQFont.body(10.5, .semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
        }
    }

    /// Bandeau discret « Marché : X » affiché 2 s après un switch automatique :
    /// capsule crème + point brique, ombre douce (langage des surfaces carte).
    /// Ancré EN BAS (toast transitoire au-dessus du dock) : à ~124 pt du haut il
    /// chevauchait la zone haute (chips / bascule couverture / légende).
    private var marketSwitchNoticeOverlay: some View {
        VStack {
            Spacer()
            if let notice = model.marketSwitchNotice {
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 8, height: 8)
                    Text(notice)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm + 2)
                .background { mapGlassBackground(Capsule(style: .continuous)) }
                .sqShadowCard()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, mapControlsBottomInset)
        .animation(SQMotion.resolve(SQMotion.snappy, reduceMotion), value: model.marketSwitchNotice)
        .allowsHitTesting(false)
    }

    private var mapTopControlBar: some View {
        HStack(spacing: SQSpace.sm) {
            mapSearchField
            filterButton
            anfrButton
        }
    }

    /// Accès aux données ANFR — le référentiel public des antennes.
    ///
    /// Elles vivaient dans le menu du Profil, où personne ne va chercher une
    /// carte. Elles appartiennent à l'onglet Carte : c'est la même matière que
    /// ce qui est affiché ici, sous un autre angle.
    private var anfrButton: some View {
        Menu {
            Button { showsANFRMap = true } label: {
                Label("Carte ANFR", systemImage: "map.fill")
            }
            Button { showsANFRStats = true } label: {
                Label("Statistiques ANFR", systemImage: "chart.bar.xaxis")
            }
        } label: {
            Image(systemName: "building.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 42, height: 42)
                .background { mapGlassBackground(Circle()) }
                .sqShadowCard()
        }
        .accessibilityLabel("Données ANFR")
    }

    /// Barre de recherche flottante : capsule 42 pt « verre crème » + blur,
    /// loupe + placeholder Figtree 15 secondaire, ombre carte — sans bordure.
    private var mapSearchField: some View {
        HStack(spacing: SQSpace.sm) {
            // Slot de tête à largeur fixe : loupe au repos, spinner pendant un
            // chargement de carte (remplace l'ancien ProgressView bas-centre qui
            // chevauchait le dock). Largeur figée → pas de saut de mise en page.
            ZStack {
                if model.isLoading || model.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(SQColor.brandRed)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(!(model.isLoading || model.isSearching))
            .accessibilityLabel(model.isSearching ? "Recherche en cours" : (model.isLoading ? "Chargement de la carte" : ""))
            TextField("Rechercher une ville, une adresse, un site…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(SQFont.body(15))
                .foregroundStyle(SQColor.label)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await model.search() } }
                // Suggestions à la frappe (anti-rebond + annulation côté modèle).
                .onChangeCompat(of: model.searchQuery) { _, _ in model.scheduleSearch() }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    model.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, SQSpace.md + 2)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background { mapGlassBackground(Capsule(style: .continuous)) }
        .sqShadowCard()
    }

    private var filterButton: some View {
        Button {
            Haptics.light()
            showFilterSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .background { mapGlassBackground(Circle()) }
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(SQFont.body(10, .bold))
                        .frame(minWidth: 17, minHeight: 17)
                        .background(SQColor.brandRed, in: Circle())
                        .foregroundStyle(SQColor.onAccent)
                        .offset(x: 4, y: -4)
                }
            }
            .sqShadowCard()
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
                    .font(SQFont.body(13.5, .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(height: 42)
            .foregroundStyle(SQColor.label)
            .background { mapGlassBackground(Capsule(style: .continuous)) }
            .sqShadowCard()
        }
        .accessibilityLabel("Opérateur affiché : \(model.operatorShortLabel(model.operatorFilter))")
    }

    /// Pile de 2 boutons flottants (bas-droite) : recentrage GPS + rafraîchissement.
    /// Cercles 46 pt « verre crème » + blur : flèche de localisation brique,
    /// second bouton encre — ombre carte, sans bordure.
    private var mapFabStack: some View {
        // Un seul FAB (recentrage GPS) : le bouton « rafraîchir » a été retiré — la
        // carte recharge déjà automatiquement à chaque déplacement/zoom (onMoveEnd),
        // il faisait doublon et alourdissait la bande basse.
        mapFab(icon: "location", tint: SQColor.brandRed, label: "Recentrer sur ma position") {
            centerOnCurrentLocation()
        }
    }

    private func mapFab(icon: String, tint: Color = SQColor.label, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .foregroundStyle(tint)
                .background { mapGlassBackground(Circle()) }
                .sqShadowCard()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
    }

    // MARK: Chrome « Crème & Terre cuite » (verre crème + ombres douces, zéro bordure)

    /// Fond commun des contrôles posés sur la carte : `surfaceGlass` (crème 92 %)
    /// sur blur système — la profondeur vient des ombres, jamais d'une bordure.
    private func mapGlassBackground<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(SQColor.surfaceGlass)
            .background(.ultraThinMaterial, in: shape)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.sm + 2)
        .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)) }
        .sqShadowCard()
        // Bornée à 280 (repli 2 lignes pour les erreurs longues) et CENTRÉE dans la
        // colonne bas-centre (alignement centré par défaut du `.frame`) — plus
        // d'alignement `.leading` hérité de l'ancienne position bas-gauche.
        .frame(maxWidth: 280)
    }

    private var activeFilterCount: Int {
        var count = 0
        // L'opérateur n'est plus compté ici : il n'est plus dans la feuille (section
        // retirée, source unique = la pilule bas-gauche qui affiche déjà son état +
        // sa couleur). Le badge ne reflète donc que ce qui est réellement filtrable
        // dans la feuille.
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
                scheduleLoad(region: MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                ))
            } else {
                // Distinguer le refus d'autorisation (l'utilisateur peut agir) d'une
                // simple indisponibilité, au lieu d'un message générique opaque (UXP-08).
                let status = services.location.authorizationStatus
                if status == .denied || status == .restricted {
                    model.errorMessage = "Localisation désactivée. Active-la dans Réglages > SignalQuest pour te localiser sur la carte."
                } else {
                    model.errorMessage = "Position actuelle indisponible"
                }
            }
        }
    }

    /// Bascule de coloration de la couche Couverture : Signal (RSRP) ↔ Génération.
    private var coverageColoringToggle: some View {
        Picker("Coloration couverture", selection: $coverageByGeneration) {
            Text("Signal").tag(false)
            Text("Génération").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(SQSpace.xs)
        .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)) }
        .sqShadowSoft()
        .frame(maxWidth: 280)
        .padding(.horizontal, SQSpace.md)
        .accessibilityLabel("Coloration de la couverture : signal ou génération")
    }

    private var searchSuggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                if model.searchResults.isEmpty {
                    searchStatusRow
                } else {
                    ForEach(model.searchResults) { result in
                        Button { selectSearchResult(result) } label: {
                            searchResultRow(result)
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .foregroundStyle(SQColor.label)
                    }
                }
            }
            .padding(.horizontal, SQSpace.xs)
            .padding(.top, SQSpace.xs)
        }
        .frame(maxHeight: 240)
    }

    /// Rangée « aucun résultat » / « recherche indisponible » (rien pendant la
    /// recherche : le spinner de la barre suffit). Distingue vide d'erreur.
    @ViewBuilder
    private var searchStatusRow: some View {
        if !model.isSearching {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: model.searchFailed ? "exclamationmark.triangle" : "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                Text(model.searchFailed ? "Recherche indisponible" : "Aucun résultat")
                    .font(SQFont.body(14, .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
            }
            .padding(.horizontal, SQSpace.md + 2)
            .padding(.vertical, SQSpace.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)) }
            .sqShadowSoft()
        }
    }

    @ViewBuilder
    private func searchResultRow(_ result: MapSearchResult) -> some View {
        HStack(spacing: SQSpace.sm) {
            switch result {
            case .antenna(let site):
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text(site.siteId ?? site.id)
                    .font(SQFont.body(14, .semibold))
                    .lineLimit(1)
                if let address = site.address {
                    Text(address)
                        .font(SQFont.body(13))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
            case .place(let place):
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text(place.name)
                    .font(SQFont.body(14, .semibold))
                    .lineLimit(1)
                if let subtitle = place.subtitle {
                    Text(subtitle)
                        .font(SQFont.body(13))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)) }
        .sqShadowSoft()
    }

    private func selectSearchResult(_ result: MapSearchResult) {
        dismissSearch()
        switch result {
        case .place(let place):
            mapCenter = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            mapZoom = 14
        case .antenna(let site):
            if site.hasValidCoordinate, let lat = site.latitude, let lng = site.longitude {
                mapCenter = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                mapZoom = 15
            }
            // Ouvre la fiche même sans coordonnées valides (corrige l'ancien tap mort).
            selectedAntenna = site
        }
    }

    private func dismissSearch() {
        model.searchQuery = ""
        model.searchResults = []
        model.isSearching = false
        model.searchFailed = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Reconstruit le cache des couches lourdes. Appelé uniquement sur changement
    /// de données (`model.dataVersion`), de couches actives (`filters`) ou de zoom
    /// — jamais à chaque rendu de `body`.
    /// Palier de zoom affectant le RENDU des annotations (clustering + cônes).
    /// Frontières : 11, 12,5, 13, 13,5, 14 — exactement les seuils utilisés par
    /// `clusteredPayloads`/`clusteredPhotoPayloads` (taille de cellule, `shouldCluster`)
    /// et `showsAzimuths` (cônes ≥ z14). Entre deux frontières, `annotationPayloads`
    /// est identique pour des données constantes → reconstruction inutile.
    private static func zoomRenderBucket(for zoom: Double) -> Int {
        switch zoom {
        case ..<11:    return 0
        case ..<12.5:  return 1
        case ..<13:    return 2
        case ..<13.5:  return 3
        case ..<14:    return 4
        default:       return 5
        }
    }

    private func refreshMapRender() {
        renderedAnnotations = annotationPayloads
        renderedCoverageFeatures = coverageHeatFeatures
        renderedSpeedtestFeatures = speedtestFeatures
        renderVersion &+= 1
    }

    /// PERF-MAP-05 : ne reconstruit QUE la couche amis (marqueurs de présence).
    /// Appelée à chaque instantané SSE d'amis (`model.friendsVersion`). Les couches
    /// lourdes (antennes, speedtests, couverture, photos, prévisionnels, pannes)
    /// restent telles quelles dans `renderedAnnotations` : on n'y remplace que le
    /// sous-ensemble `.friend`, au lieu de recalculer des milliers de structs par tick.
    private func refreshFriendsRender() {
        renderedAnnotations = renderedAnnotations.filter { $0.kind != .friend } + friendPayloads
        renderVersion &+= 1
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
        payloads += friendPayloads
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
            // Filtre par statut (masquer/afficher actif/upgrade/déclaré/prévu).
            guard model.plannedStatusFilters.contains(status) else { return nil }
            let techLine = site.technologies.joined(separator: " / ")
            let pending = site.activation?.pendingTechnologies ?? []
            let statusNote: String
            switch status {
            case .active: statusNote = String(localized: "Site actif — toutes les technos prévues sont en service")
            case .upgradePending:
                statusNote = pending.isEmpty
                    ? String(localized: "Upgrade en cours")
                    : String(localized: "Upgrade en attente : \(pending.joined(separator: ", "))")
            case .declared: statusNote = String(localized: "Station déclarée à l'ANFR (pas encore en service)")
            case .planned: statusNote = String(localized: "Site prévu (non encore construit)")
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
                tint: Self.plannedStatusColor(status),
                plannedStatus: status,
                glyphOverride: Self.plannedStatusGlyph(status)
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
                title: site.siteId ?? String(localized: "Site en panne"),
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

    /// Indicateur visuel d'un site prévisionnel selon son croisement ANFR : la
    /// pastille prend la couleur du statut et un glyphe parlant — actif ✓ (vert),
    /// upgrade en attente ↑ (ambre), déclaré mais pas en service ⧗ (bleu), simplement
    /// prévu 📅 (gris). Rend les 4 états lisibles d'un coup d'œil sur la carte.
    static func plannedStatusColor(_ status: PlannedActivationStatus) -> Color {
        // Couleurs fixes saturées (mi-luminance) : le glyphe blanc reste lisible sur
        // le fond de carte en clair ET en sombre, contrairement aux couleurs sémantiques
        // qui s'éclaircissent en mode sombre. Progression gris→bleu→ambre→vert = du
        // « juste prévu » au « pleinement actif ».
        switch status {
        case .active: return Color(hex: 0x16A34A)        // vert — en service
        case .upgradePending: return Color(hex: 0xF59E0B) // ambre — upgrade en attente
        case .declared: return Color(hex: 0x2563EB)       // bleu — déclaré, pas en service
        case .planned: return Color(hex: 0x64748B)        // ardoise — prévu, pas construit
        }
    }

    static func plannedStatusGlyph(_ status: PlannedActivationStatus) -> String {
        switch status {
        case .active: return "checkmark"
        case .upgradePending: return "arrow.up"
        case .declared: return "hourglass"
        case .planned: return "calendar"
        }
    }

    /// Libellé court du statut, pour les fiches et l'accessibilité.
    static func plannedStatusLabel(_ status: PlannedActivationStatus) -> String {
        switch status {
        case .active: return String(localized: "Actif")
        case .upgradePending: return String(localized: "Upgrade en attente")
        case .declared: return String(localized: "Déclaré")
        case .planned: return String(localized: "Prévu")
        }
    }

    /// Couche Speedtests rendue en couche dense (MKOverlay) : TOUT s'affiche,
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
    /// commentaires). Les doublons de coordonnées sont conservés (le rendu dense les
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
    private func coverageColorParts(rsrp: Double?, tech: String?) -> (key: String, hex: UInt32, dimmed: Bool, rank: Int) {
        if coverageByGeneration {
            let band = CoverageGenerationBand.band(for: tech)
            // `band.rank` (5G=5 > 4G=4 > … > aucun=0) pilote le z-order (cf. tri en
            // fin de `coverageHeatFeatures`).
            return ("g-\(band.rawValue)", band.colorHex, band == .none, band.rank)
        } else {
            let band = CoverageQualityBand.band(for: rsrp)
            // Rang neutre en mode RSRP → le tri par génération est un no-op.
            return ("q-\(band.rawValue)", band.colorHex, band == .unknown, 0)
        }
    }

    private func coverageFeature(from point: AndroidCoveragePoint) -> CoverageHeatFeature {
        let parts = coverageColorParts(rsrp: point.rsrp, tech: point.tech)
        return CoverageHeatFeature(
            id: "coverage-heat-\(point.id)",
            coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
            weight: coverageHeatWeight(rsrp: point.rsrp),
            colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed,
            generationRank: parts.rank
        )
    }

    /// 5G NSA : le backend renvoie, pour une même mesure, des points frères co-localisés
    /// (ancre LTE taguée « 4G » + cellule NR taguée « 5G ») partageant un `groupId`. Sans
    /// arbitrage, la pastille 4G (opaque, RSRP réel) recouvre la 5G (souvent sans RSRP).
    /// On réduit chaque groupe à son point de génération la plus élevée (5G > 4G > 3G > 2G),
    /// en conservant l'ordre d'apparition. Les points sans `groupId` restent distincts.
    private static func dominantGenerationPoints<S: Sequence>(_ points: S) -> [AndroidCoveragePoint]
    where S.Element == AndroidCoveragePoint {
        var indexByGroup: [String: Int] = [:]
        var result: [AndroidCoveragePoint] = []
        for point in points {
            let key = point.groupId ?? point.id
            if let index = indexByGroup[key] {
                if CoverageGenerationBand.band(for: point.tech).rank > CoverageGenerationBand.band(for: result[index].tech).rank {
                    result[index] = point
                }
            } else {
                indexByGroup[key] = result.count
                result.append(point)
            }
        }
        return result
    }

    /// Pendant de `dominantGenerationPoints` pour le REPLI bbox `/api/coverage/points`.
    /// Le modèle `CoverageHeatPoint` n'a pas de `groupId` → on regroupe par COORDONNÉE
    /// (les frères NSA 4G+5G sont co-localisés à lat/lng identiques) et on ne conserve
    /// que la génération la plus élevée du groupe. Ordre d'apparition préservé.
    private static func dominantGenerationHeatPoints(_ points: [CoverageHeatPoint]) -> [CoverageHeatPoint] {
        var indexByKey: [String: Int] = [:]
        var result: [CoverageHeatPoint] = []
        for point in points {
            let key = "\(point.latitude),\(point.longitude)"
            let rank = CoverageGenerationBand.band(for: point.technology ?? point.networkType).rank
            if let index = indexByKey[key] {
                let current = CoverageGenerationBand.band(for: result[index].technology ?? result[index].networkType).rank
                if rank > current { result[index] = point }
            } else {
                indexByKey[key] = result.count
                result.append(point)
            }
        }
        return result
    }

    private var coverageHeatFeatures: [CoverageHeatFeature] {
        guard filters.contains(.coverage) else { return [] }
        // La couverture n'a de sens que pour UN opérateur donné (superposer tous les
        // opérateurs n'est pas exploitable) → masquée quand l'opérateur est « Tous ».
        guard model.operatorFilter.uppercased() != "ALL" else { return [] }
        let hasBandFilter = !model.bandFilters.isEmpty
        var features: [CoverageHeatFeature] = []
        for tile in model.coverageTiles {
            let render = CoverageRenderPolicy.mode(
                hasPoints: !tile.points.isEmpty, hasClusters: !tile.clusters.isEmpty, hasBandFilter: hasBandFilter
            )
            if render.useClusters {
                // Couche SIGNAL : on exclut les clusters de couverture iOS « génération seule »
                // (source == "ios", sans RSRP), comme pour les points bruts. La couche
                // génération les conserve.
                let clusters = coverageByGeneration ? tile.clusters : tile.clusters.filter { $0.source != "ios" }
                features += clusters.map { cluster in
                    // Clusters (région/pays) : couleur = génération dominante backend
                    // (`cluster.tech`), gardée VERBATIM — le backend ne renvoie qu'UNE
                    // génération + `count` + `avgRsrp`, pas la distribution par génération,
                    // donc iOS ne peut pas ré-arbitrer un cluster vers le 5G sans donnée
                    // supplémentaire (ce serait une modif backend). Le tri par génération
                    // (fin de `coverageHeatFeatures`) s'applique néanmoins : un cluster 5G
                    // passe au-dessus d'un cluster 4G chevauchant.
                    let parts = coverageColorParts(rsrp: cluster.avgRsrp, tech: cluster.tech)
                    return CoverageHeatFeature(
                        id: "coverage-heat-cluster-\(cluster.id)",
                        coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                        weight: min(max(Double(cluster.count), 1), 40) / 8,
                        colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed,
                        generationRank: parts.rank
                    )
                }
            }
            if render.useRawPoints {
                // En 5G NSA, le backend éclate une mesure en points frères co-localisés
                // (ancre LTE taguée « 4G » + cellule NR taguée « 5G ») partageant un
                // `groupId`. En mode génération on ne garde qu'UNE pastille par groupe — la
                // génération la plus élevée — sinon la 4G (opaque) recouvre la 5G (parité
                // carte Android). En mode RSRP on garde tous les points (chacun porte son
                // signal propre) et la séquence reste paresseuse (rien de matérialisé).
                let filtered = tile.points.lazy.filter { matchesSelectedBand($0.band) }
                let cap = CoverageRenderPolicy.pointCapPerTile
                if coverageByGeneration {
                    features += Self.dominantGenerationPoints(filtered).prefix(cap).map { coverageFeature(from: $0) }
                } else {
                    // Couche SIGNAL (RSRP) : on exclut la couverture iOS « génération seule »
                    // (source == "ios", aucun RSRP) — elle n'a de sens que sur la couche
                    // génération. Filtrage par SOURCE et non par rsrp==nil, pour ne pas
                    // masquer les vraies zones blanches Android (RSRP absent mais réel).
                    features += filtered.filter { $0.source != "ios" }.prefix(cap).map { coverageFeature(from: $0) }
                }
            }
        }
        if features.isEmpty {
            let matches = model.coverageHeat.lazy.filter { point in
                // Couche SIGNAL : exclure la couverture iOS génération-seule (source == "ios",
                // sans RSRP) ; la couche génération les conserve. Parité tuiles/points.
                guard coverageByGeneration || point.source != "ios" else { return false }
                return matchesSelectedBand(point.band) || matchesSelectedBands(in: [point.frequency, point.technology, point.networkType].compactMap { $0 })
            }
            // Mode génération : dédupliquer les frères NSA co-localisés (le repli
            // `CoverageHeatPoint` n'a PAS de `groupId` → clé = coordonnée) et ne garder
            // que la génération la plus élevée, comme `dominantGenerationPoints` pour les
            // tuiles. Idempotent : `/api/coverage/points?expanded=false` collapse déjà
            // côté serveur → filet de sécurité. En RSRP : chemin paresseux inchangé.
            let source: [CoverageHeatPoint] = coverageByGeneration
                ? Self.dominantGenerationHeatPoints(Array(matches))
                : Array(matches.prefix(CoverageRenderPolicy.fallbackCap))
            features = source.prefix(CoverageRenderPolicy.fallbackCap).map { point in
                let parts = coverageColorParts(rsrp: point.signalStrength, tech: point.technology ?? point.networkType)
                return CoverageHeatFeature(
                    id: "coverage-heat-api-\(point.id)",
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    weight: coverageHeatWeight(rsrp: point.signalStrength),
                    colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed,
                    generationRank: parts.rank
                )
            }
        }
        // Tri STABLE par rang de génération croissant → la génération la plus élevée
        // est dessinée EN DERNIER (au-dessus) par le renderer (ordre du tableau), donc
        // un vrai 5G n'est jamais recouvert par une 4G chevauchante — y compris entre
        // tuiles voisines. `Array.sorted` n'étant pas stable en Swift, on départage par
        // l'index d'origine pour préserver l'ordre backend/temporel à rang égal (sortie
        // déterministe → le garde de diff de `setCoverage` tient). Mode génération
        // uniquement ; en RSRP `generationRank == 0` partout → no-op de toute façon.
        if coverageByGeneration {
            features = features.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.generationRank != rhs.element.generationRank
                        ? lhs.element.generationRank < rhs.element.generationRank
                        : lhs.offset < rhs.offset
                }
                .map(\.element)
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
        //  · speedtests → couche dense `speedtestFeatures` (tout afficher, sans cluster)
        //  · couverture → couche dense (dots RSRP type nPerf)
        //  · prévisionnels/pannes → `plannedPayloads`/`outagePayloads` (statut + couleur)
        // Ne restent ici que validations / sessions du snapshot. Les amis passent
        // par `friendPayloads` (rendu « Find My » riche, alimenté par le flux live).
        let socialFilters = filters.subtracting([.speedtest, .coverage, .antenna, .photo, .planned, .outage, .friend])
        let items = model.snapshot.displayItems(include: socialFilters)
        return items.filter(matches(filterItem:))
    }

    /// Amis géolocalisés de la couche « Amis », rendus en marqueur avatar « Find
    /// My » (avatar + anneau de présence + cône de cap + badge). Alimentés par le
    /// flux temps réel (`model.liveFriends`), pas par le snapshot borné.
    private var friendPayloads: [MapAnnotationPayload] {
        guard filters.contains(.friend) else { return [] }
        return model.liveFriends.compactMap { friend in
            guard let location = friend.location else { return nil }
            let info = FriendAnnotationInfo(
                userId: friend.id,
                displayName: friend.name ?? "Ami",
                avatarURL: friend.avatarUrl,
                presence: friend.presenceStatus,
                heading: location.heading.flatMap { $0 >= 0 ? $0 : nil },
                speedMps: location.speed.flatMap { $0 >= 0 ? $0 : nil },
                accuracyMeters: location.accuracy.flatMap { $0 > 0 ? $0 : nil },
                technology: friend.radio?.technology,
                operatorName: friend.radio?.operator,
                isStale: friend.hasStaleLocation()
            )
            let subtitle = friend.radio?.technology
                ?? friend.presence?.customStatus
                ?? friend.presenceStatus.label
            return MapAnnotationPayload(
                id: "friend-\(friend.id)",
                kind: .friend,
                title: friend.name ?? "Ami",
                subtitle: subtitle,
                coordinate: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng),
                metric: friend.radio?.operator,
                backendId: friend.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                friend: info
            )
        }
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
        // Ami vivant : fiche riche (présence, radio, distance, raccourcis message/profil).
        if annotation.kind == .friend, let friendId = annotation.backendId,
           let friend = model.liveFriends.first(where: { $0.id == friendId }) {
            selectedFriend = friend
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
        // Garde à la source : MapKit livre parfois un centre ou un span NaN
        // pendant une transition de caméra. Filtrer ici protège d'un coup les 7
        // points d'entrée de MapSnapshotService, dont les conversions `Int(...)`
        // trapperaient. On ne mémorise pas non plus une `lastRegion` corrompue,
        // qui serait rejouée à chaque rechargement.
        guard region.center.latitude.isFinite, region.center.longitude.isFinite,
              region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else { return }
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

// MARK: - Carte MapKit (moteur unique)

// MARK: - Style des marqueurs MapKit (couleur / taille / glyphe par type)

