import SwiftUI
import MapKit
import ImageIO
import OSLog

/// Compteurs seulement : aucune coordonnée, identité de compte ou réponse brute.
private enum MapDiagnosticsLog {
    static let logger = Logger(subsystem: "fr.signalquest.ios", category: "map-diagnostics")
}

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
    enum FriendsConnectionState: Equatable {
        case inactive
        case connecting
        case live
        case fallback
        case unavailable
    }

    @Published var snapshot: SocialMapSnapshot = .empty
    /// Amis en temps réel (position + présence + radio) alimentés par le SSE
    /// `/api/social/map/stream`. Tenu à part de `snapshot.friends` pour ne pas
    /// entrer en course avec les rechargements bornés de `load()` : le flux n'est
    /// pas géo-borné et fait autorité dès qu'il a répondu.
    @Published var liveFriends: [SocialFriendLive] = []
    @Published private(set) var friendsConnectionState: FriendsConnectionState = .inactive
    @Published private(set) var friendsConnectionError: String?
    @Published private(set) var friendsLastUpdatedAt: Date?
    /// Vrai dès que le flux temps réel a livré au moins un instantané : `load()`
    /// cesse alors d'amorcer `liveFriends` depuis le snapshot borné.
    private var friendsFromStream = false
    @Published var antennas: [AntennaSite] = []
    @Published var antennaClusters: [AndroidMapCluster] = []
    private var retainedAntennaTiles: [AndroidAntennaTileResponse] = []
    @Published var speedtestTiles: [AndroidSpeedtestTileResponse] = []
    @Published var coverageTiles: [AndroidCoverageTileResponse] = []
    @Published var communitySiteTiles: [AndroidCommunitySiteTileResponse] = []
    @Published var customSiteTiles: [AndroidCustomSiteTileResponse] = []
    @Published var plannedSites: [PlannedSiteLive] = []
    @Published var outages: [OutageSiteLive] = []
    /// Pannes signalées par les membres sous l'emprise courante. Distinctes des
    /// incidents opérateurs ci-dessus, et chargées dès que des antennes sont à
    /// l'écran : couche éteinte, elles restent le badge posé sur le point d'antenne.
    @Published var communityOutages: [CommunityOutage] = []
    @Published var coverageHeat: [CoverageHeatPoint] = []
    /// Photos publiques de tous les membres (couche Photos), ou de mes seuls
    /// amis quand `photosFriendsOnly` est choisi.
    @Published var publicPhotos: [MapPublicPhoto] = []
    /// Incrémenté à chaque publication de couche dans `load`. Sert de signal
    /// O(1) pour reconstruire le cache d'annotations de la vue uniquement quand
    /// les données changent — et non à chaque invalidation de `body`.
    @Published private(set) var dataVersion = 0
    /// Signal SÉPARÉ des instantanés d'amis temps réel (SSE), distinct de
    /// `dataVersion` : à chaque tick la vue ne reconstruit QUE la couche amis
    /// (PERF-MAP-05) au lieu de recalculer antennes / speedtests / couverture.
    @Published private(set) var friendsVersion = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasCurrentResponse = false
    @Published private(set) var tileLoadIssues: [MapDisplayItem.Kind: MapTileLoadIssue] = [:]
    @Published private(set) var displayLimitMessages: [String] = []
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
    /// Comment croiser les bandes cochées (au moins une / toutes / exclusivement).
    /// Sans effet tant qu'aucune bande n'est cochée.
    @Published var bandMatch: BandMatchMode = MapBandMatchStore.last() {
        didSet { MapBandMatchStore.save(bandMatch) }
    }
    /// Rendu des azimuts. Purement local, aucun rechargement de données.
    @Published var azimuthStyle: AzimuthStyle = MapAzimuthStyleStore.last() {
        didSet { MapAzimuthStyleStore.save(azimuthStyle) }
    }
    /// Couverture restreinte à un site. Non nil = la couche couverture ne montre
    /// que les mesures rattachées à son eNB/gNB.
    @Published var coverageFocus: AntennaCoverageFocus?
    @Published var sharingFilters: Set<String> = []
    /// Statuts prévisionnels visibles (croisement ANFR). Par défaut : les 4.
    /// Filtre 100 % client (les sites sont déjà chargés) → pas de refetch backend.
    @Published var plannedStatusFilters: Set<PlannedActivationStatus> = MapPlannedStatusStore.load()
    /// Inclure les cellules seulement « observées » (vs sites probables
    /// consolidés) dans la couche communautaire.
    @Published var includeObservedSites = true
    /// Couche Photos restreinte aux amis, choisie dans la feuille de filtres.
    /// La vue la remet à faux sans compte.
    @Published var photosFriendsOnly = MapPhotosFriendsOnlyStore.load()
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
    let communityOutageService: CommunityOutageServicing

    private var noticeTask: Task<Void, Never>?
    /// Recherche courante (annulée à chaque nouvelle frappe → pas de résultat obsolète).
    private var searchTask: Task<Void, Never>?
    /// Dernier centre caméra connu — biais de proximité de la recherche de lieux.
    private var lastCenter: CLLocationCoordinate2D?
    private var hasResolvedInitialSelection = false
    private var initialCameraConsumed = false
    private var initialSelectionToObserve: (market: String, operatorName: String)?
    private var initialGPSCenter: CLLocationCoordinate2D?
    private var initialResolvedFromManual = false
    private var marketBeforeInitialResolution: String?
    private var marketAlignmentGeneration = UUID()
    private var manualSelectionGeneration = UUID()
    /// Vrai pendant la sélection initiale (cascade marché/opérateur à
    /// l'ouverture) : les `onChange` de marketFilter/operatorFilter doivent alors
    /// court-circuiter recentrage + rechargement, car le `.task` les pilote lui-même.
    private(set) var initialSelectionInProgress = false

    private struct LoadContext: Equatable {
        let session: UUID
        let market: String
        let operatorName: String
        let technologies: Set<String>
        let bands: Set<Int>
        let bandMatch: BandMatchMode
        let focus: AntennaCoverageFocus?
        let sharing: Set<String>
        let includeObserved: Bool
        let photosFriendsOnly: Bool
        let speedtestDays: Int
        let coverageDays: Int
        let filters: Set<MapDisplayItem.Kind>
        let lightweight: Bool
        let communityOnly: Bool
        let supportsCommunity: Bool
    }

    /// Independent responses cross back to the MainActor before publication.
    private enum LayerResult: Sendable {
        case snapshot((snapshot: SocialMapSnapshot?, error: String?))
        case antenna((tiles: MapTileLayerResult<AndroidAntennaTileResponse>?, list: [AntennaSite]?, error: String?))
        case communitySite(MapTileLayerResult<AndroidCommunitySiteTileResponse>)
        case customSite(MapTileLayerResult<AndroidCustomSiteTileResponse>)
        case speedtest(MapTileLayerResult<AndroidSpeedtestTileResponse>)
        case planned((value: MapFeedResult<PlannedSiteLive>?, error: String?))
        case outage((value: MapFeedResult<OutageSiteLive>?, error: String?))
        case communityOutage((value: [CommunityOutage]?, error: String?, atLimit: Bool))
        case coverage((value: (tiles: MapTileLayerResult<AndroidCoverageTileResponse>, heat: [CoverageHeatPoint])?, error: String?))
        case photos((value: [MapPublicPhoto]?, error: String?))
    }

    private var displayedContext: LoadContext?
    private var activeLoad: (id: UUID, context: LoadContext)?

    private func loadContext(filters: Set<MapDisplayItem.Kind>, lightweight: Bool) -> LoadContext {
        LoadContext(
            session: mapService.sessionIdentifier, market: marketFilter, operatorName: operatorFilter,
            technologies: techFilters, bands: bandFilters, bandMatch: bandMatch, focus: coverageFocus,
            sharing: sharingFilters, includeObserved: includeObservedSites,
            photosFriendsOnly: photosFriendsOnly, speedtestDays: speedtestDays, coverageDays: coverageDays, filters: filters,
            lightweight: lightweight, communityOnly: isCommunityOnlyMarket,
            supportsCommunity: supportsCommunityLayers
        )
    }

    /// Reserve before debounce as well as for direct/initial loads. Cancellation
    /// only saves work; this identity is what authorizes publication.
    @discardableResult
    func prepareLoad(filters: Set<MapDisplayItem.Kind>, lightweight: Bool = true) -> UUID {
        let context = loadContext(filters: filters, lightweight: lightweight)
        let id = UUID()
        activeLoad = (id, context)
        discardIncompatibleData(for: context)
        errorMessage = nil
        hasCurrentResponse = false
        tileLoadIssues = [:]
        displayLimitMessages = []
        isLoading = true
        return id
    }

    func cancelPendingLoad() {
        activeLoad = nil
        isLoading = false
    }

    /// Une reconnexion ne relance que la carte visible et incomplète. Le
    /// rafraîchissement force les tuiles, car un cache chaud peut masquer la reprise.
    func recoverAfterNetworkReturn(wasOnline: Bool, isOnline: Bool, isVisible: Bool,
                                   bounds: MapBounds?, zoom: Double,
                                   filters: Set<MapDisplayItem.Kind>) async {
        guard !wasOnline, isOnline, isVisible, let bounds,
              errorMessage != nil || !hasCurrentResponse else { return }
        let requestID = prepareLoad(filters: filters)
        await mapService.invalidateTiles()
        guard !Task.isCancelled else { return }
        await load(bounds: bounds, zoom: zoom, filters: filters, requestID: requestID, refresh: true)
    }

    private func isCurrentLoad(_ id: UUID, context: LoadContext) -> Bool {
        activeLoad?.id == id
            && context == loadContext(filters: context.filters, lightweight: context.lightweight)
    }

    /// Keep a failed layer's previous data only if its meaning has not changed.
    /// Moving the camera can retain nearby data; changing owner or attribution cannot.
    private func discardIncompatibleData(for next: LoadContext) {
        let previous = displayedContext
        displayedContext = next
        guard previous != next else { return }
        let sameAccount = previous?.session == next.session
        let sameMarket = sameAccount && previous?.market == next.market
        let sameOperator = sameMarket && previous?.operatorName == next.operatorName
        let sameBands = sameOperator && previous?.bands == next.bands
        let sameCommunity = sameBands && previous?.communityOnly == next.communityOnly
            && previous?.supportsCommunity == next.supportsCommunity
        func sameLayer(_ kind: MapDisplayItem.Kind) -> Bool {
            previous?.filters.contains(kind) == next.filters.contains(kind)
        }
        if !sameOperator || previous?.lightweight != next.lightweight
            || !sameLayer(.validation) || !sameLayer(.session) {
            snapshot = .empty
        }
        if !sameAccount {
            liveFriends = []
            deactivateFriendsStream()
            friendsVersion &+= 1
        }
        if !sameCommunity || !sameLayer(.antenna) || previous?.technologies != next.technologies
            || previous?.sharing != next.sharing || previous?.bandMatch != next.bandMatch {
            antennas = []
            antennaClusters = []
            retainedAntennaTiles = []
        }
        if !sameCommunity || !sameLayer(.communitySite) || !sameLayer(.antenna)
            || previous?.includeObserved != next.includeObserved {
            communitySiteTiles = []
        }
        if !sameOperator || !sameLayer(.customSite) || !sameLayer(.antenna)
            || previous?.communityOnly != next.communityOnly {
            customSiteTiles = []
        }
        if !sameBands || !sameLayer(.speedtest) || previous?.speedtestDays != next.speedtestDays {
            speedtestTiles = []
        }
        if !sameBands || !sameLayer(.coverage) || previous?.coverageDays != next.coverageDays
            || previous?.technologies != next.technologies || previous?.focus != next.focus {
            coverageTiles = []
            coverageHeat = []
        }
        if !sameBands || !sameLayer(.planned) { plannedSites = [] }
        if !sameBands || !sameLayer(.outage) || !sameLayer(.antenna) { outages = [] }
        if !sameOperator || !sameLayer(.outage) || !sameLayer(.antenna) || !sameLayer(.customSite) {
            communityOutages = []
        }
        if !sameMarket || !sameLayer(.photo) || !sameLayer(.friend) { publicPhotos = [] }
        dataVersion &+= 1
    }

    init(
        map: MapSnapshotServicing,
        antennas: AntennasServicing,
        markets: MarketRegistryServicing,
        communityOutages: CommunityOutageServicing
    ) {
        self.mapService = map
        self.antennasService = antennas
        self.marketsService = markets
        self.communityOutageService = communityOutages
    }

    // MARK: Registre des marchés

    func loadRegistry() async {
        let payload = await marketsService.registry()
        registryMarkets = payload.markets.filter(\.publicSelectable)
        currentMarketEntry = payload.market(forCode: marketFilter)
    }

    /// La position propose le pays une seule fois. Un choix manuel persistant
    /// reste prioritaire aux ouvertures suivantes ; la caméra ne choisit aucun pays.
    func resolveInitialSelection(
        networkPath: NetworkPathMonitor,
        networkOperator: NetworkOperatorServicing,
        location: LocationService
    ) async {
        guard !hasResolvedInitialSelection else { return }
        let manualGeneration = manualSelectionGeneration
        let previousMarket = marketFilter
        let payload = await marketsService.registry()
        guard !Task.isCancelled, manualGeneration == manualSelectionGeneration,
              !payload.markets.isEmpty else { return }

        let manualMarket = MapMarketStore.manualMarket()
        var entry = payload.markets.first {
            $0.publicSelectable && ($0.marketCode.caseInsensitiveCompare(manualMarket ?? "") == .orderedSame
                || $0.code.caseInsensitiveCompare(manualMarket ?? "") == .orderedSame)
        }
        let hasManualCountry = entry != nil
        var locatedCenter: CLLocationCoordinate2D?
        if entry == nil,
           location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways,
           let loc = await location.currentLocation(timeoutSeconds: 4) {
            let resolved = await marketsService.marketForLocation(
                latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude
            )
            if resolved?.publicSelectable == true { entry = resolved; locatedCenter = loc.coordinate }
        }
        guard !Task.isCancelled, manualGeneration == manualSelectionGeneration else { return }
        if entry == nil, let previous = MapMarketStore.lastMarket() {
            entry = payload.markets.first { $0.publicSelectable && $0.marketCode.caseInsensitiveCompare(previous) == .orderedSame }
        }
        networkPath.refreshNow()
        let status = networkPath.status
        // La SIM n'est qu'un repli lorsque la position est indisponible, jamais
        // une preuve du pays visité (itinérance).
        if entry == nil, status.connection == .cellular, let mcc = status.operatorMcc {
            entry = payload.markets.first { $0.publicSelectable && $0.mccs.contains(mcc) }
        }
        if entry == nil { entry = Self.localeMarketEntry(in: payload) }
        if entry == nil { entry = payload.markets.first { $0.publicSelectable } }
        guard let entry else { return }
        let code = entry.marketCode.isEmpty ? entry.code : entry.marketCode

        var selectedOperator = operatorFilter
        if !hasManualCountry, status.connection == .cellular {
            if let detected = await networkOperator.resolve(viaVpn: VPNDetector.isActive()),
               let key = detected.operatorKey, entry.operatorEntry(forKey: key) != nil {
                selectedOperator = key
            } else if let mcc = status.operatorMcc, let mnc = status.operatorMnc,
                      let key = entry.radioOperatorKey(mcc: mcc, mnc: mnc) {
                selectedOperator = key
            }
        }
        guard !Task.isCancelled, manualGeneration == manualSelectionGeneration else { return }
        let mayRestore = hasManualCountry || previousMarket.caseInsensitiveCompare(code) == .orderedSame
        let restoredCenter = mayRestore ? lastCenter ?? MapRegionStore.lastRegion()?.center : nil
        // Un repli de cadrage n'est pas un territoire observé : ne pas éliminer
        // SRR après une exploration manuelle hors des îles.
        let dromRegion = (locatedCenter ?? restoredCenter).flatMap(DromRegion.from)
        let options = MapFilterSelection.operatorOptions(for: entry, dromRegion: dromRegion)
        selectedOperator = options.first { $0.caseInsensitiveCompare(selectedOperator) == .orderedSame } ?? "ALL"
        hasResolvedInitialSelection = true
        initialGPSCenter = locatedCenter
        initialResolvedFromManual = hasManualCountry
        marketBeforeInitialResolution = previousMarket
        initialSelectionInProgress = true
        initialSelectionToObserve = (code, selectedOperator)
        currentMarketEntry = entry
        currentDromRegion = code.uppercased() == "DROM" ? dromRegion : nil
        marketFilter = code
        operatorFilter = selectedOperator
        MapMarketStore.save(market: code, operator: selectedOperator)
    }

    /// Caméra par défaut d'un marché : centre/zoom du registre quand ils sont
    /// connus, sinon les valeurs statiques historiques.
    func defaultMapRegion(forMarketCode code: String) -> MKCoordinateRegion {
        // Le centre global du registre DROM peut être hors de toute île.
        // Une emprise territoriale réelle reste nécessaire pour charger ses sites.
        if code.uppercased() == "DROM" {
            let territory = currentDromRegion ?? lastCenter.flatMap(DromRegion.from) ?? .guadeloupe
            let delta = territory == .guyane ? 6.0 : 2.0
            return MKCoordinateRegion(center: territory.center,
                span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
        }
        if let entry = registryMarket(forCode: code),
           let lat = entry.defaultCenterLatitude,
           let lng = entry.defaultCenterLongitude,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
            let proposedZoom = entry.defaultMapZoom ?? 6
            let zoom = proposedZoom.isFinite ? min(20, max(1, proposedZoom)) : 6
            let lonDelta = min(300.0, max(0.01, 360 / pow(2, zoom)))
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                span: MKCoordinateSpan(
                    latitudeDelta: min(120.0, lonDelta * 0.8),
                    longitudeDelta: lonDelta
                )
            )
        }
        return MapExplorerView.region(for: code)
    }

    func takeInitialMapRegion(restoring saved: MKCoordinateRegion?) -> MKCoordinateRegion? {
        guard hasResolvedInitialSelection, !initialCameraConsumed else { return nil }
        initialCameraConsumed = true
        if initialResolvedFromManual, let saved { return saved }
        if let center = initialGPSCenter {
            return MKCoordinateRegion(center: center, latitudinalMeters: 6000, longitudinalMeters: 6000)
        }
        if marketBeforeInitialResolution?.caseInsensitiveCompare(marketFilter) == .orderedSame, let saved {
            return saved
        }
        return defaultMapRegion(forMarketCode: marketFilter)
    }

    /// SwiftUI observes the country after the startup task has returned. Keep
    /// its origin until that observation so it cannot recenter over the GPS fix.
    func consumeInitialSelectionObservation(_ selection: MapFilterSelection) -> Bool {
        guard let initial = initialSelectionToObserve,
              initial.market == selection.market, initial.operatorName == selection.operatorName else { return false }
        initialSelectionToObserve = nil
        return true
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
    /// (changement explicite) ; sinon on ne corrige que les valeurs invalides.
    func alignWithMarket(code: String, resetOperator: Bool) async {
        let generation = UUID()
        marketAlignmentGeneration = generation
        let entry = await marketsService.market(forCode: code)
        guard marketAlignmentGeneration == generation,
              marketFilter.caseInsensitiveCompare(code) == .orderedSame else { return }
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
        // A manual country switch may still have the previous camera centre.
        // Do not replace its prepared DROM context with that unrelated location.
        if entry.marketCode.uppercased() != "DROM" { currentDromRegion = nil }
        else if let center = lastCenter, DromRegion.from(center) != nil { updateDromRegion(for: center) }
    }

    func filterSelection(layers: Set<MapDisplayItem.Kind>) -> MapFilterSelection {
        MapFilterSelection(market: marketFilter, operatorName: operatorFilter,
            technologies: techFilters, bands: bandFilters, bandMatch: bandMatch,
            azimuthStyle: azimuthStyle, sharing: sharingFilters, speedtestDays: speedtestDays,
            coverageDays: coverageDays, layers: layers, includeObserved: includeObservedSites,
            plannedStatuses: plannedStatusFilters, photosFriendsOnly: photosFriendsOnly)
    }

    /// Commits a complete value on the main actor, before any scheduled load.
    /// The sheet itself never touches these observable values or their stores.
    func applyFilterSelection(_ selection: MapFilterSelection) -> MapFilterSelection? {
        guard let entry = registryMarket(forCode: selection.market), entry.publicSelectable else { return nil }
        let region: DromRegion?
        if entry.marketCode.uppercased() != "DROM" { region = nil }
        else if marketFilter.uppercased() == "DROM" { region = currentDromRegion }
        else if let latitude = entry.defaultCenterLatitude, let longitude = entry.defaultCenterLongitude {
            region = DromRegion.from(latitude: latitude, longitude: longitude) ?? .guadeloupe
        } else { region = .guadeloupe }
        let result = selection.normalized(for: entry, dromRegion: region)
        if marketFilter.caseInsensitiveCompare(result.market) != .orderedSame
            || operatorFilter.caseInsensitiveCompare(result.operatorName) != .orderedSame {
            coverageFocus = nil
        }
        invalidatePendingSelectionResolution()
        currentMarketEntry = entry
        currentDromRegion = region
        marketFilter = result.market
        operatorFilter = result.operatorName
        techFilters = result.technologies
        bandFilters = result.bands
        bandMatch = result.bandMatch
        azimuthStyle = result.azimuthStyle
        sharingFilters = result.sharing
        speedtestDays = result.speedtestDays
        coverageDays = result.coverageDays
        includeObservedSites = result.includeObserved
        plannedStatusFilters = result.plannedStatuses
        photosFriendsOnly = result.photosFriendsOnly
        MapMarketStore.saveManual(market: result.market, operator: result.operatorName)
        return result
    }

    private func invalidatePendingSelectionResolution() {
        manualSelectionGeneration = UUID()
        marketAlignmentGeneration = UUID()
        hasResolvedInitialSelection = true
        initialCameraConsumed = true
        initialSelectionToObserve = nil
    }

    func chooseOperatorManually(_ key: String) {
        guard let canonical = operatorOptions.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return }
        invalidatePendingSelectionResolution()
        if operatorFilter.caseInsensitiveCompare(canonical) != .orderedSame { coverageFocus = nil }
        operatorFilter = canonical
        MapMarketStore.saveManual(market: marketFilter, operator: canonical)
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
        currentMarketEntry.map(Self.defaultOperatorKey(for:)) ?? "ALL"
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
        // « Tous » d'abord : le registre le nomme en français, et la pastille
        // restait « Tous » dans l'app anglaise (TRX-06).
        if key.uppercased() == "ALL" { return String(localized: "Tous") }
        if let entry = currentMarketEntry?.operatorEntry(forKey: key) {
            return entry.shortLabel
        }
        return key
    }

    func operatorLabel(_ key: String) -> String {
        MarketRegistryEntry.operatorLabel(key, in: currentMarketEntry)
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

    // MARK: Contexte géographique de la caméra

    /// Le centre sert à la recherche de lieux et aux territoires DROM.
    /// Un déplacement ne déclenche ni résolution de pays ni changement du choix manuel.
    /// Centre de la carte tel que vu en dernier.
    var viewportCenter: CLLocationCoordinate2D? { lastCenter }

    func recordViewportCenter(_ center: CLLocationCoordinate2D) {
        lastCenter = center
        updateDromRegion(for: center)
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
            showMarketNotice(String(localized: "Territoire : \(region.flag) \(region.shortName)"))
        }
    }

    /// Bandeau passager en haut de la carte (changement de marché, site introuvable).
    func showMarketNotice(_ text: String) {
        noticeTask?.cancel()
        marketSwitchNotice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.marketSwitchNotice = nil
        }
    }

    /// La suppression visuelle précède le prochain await réseau. Les anciennes
    /// réponses déjà en vol perdent aussi leur droit de remplacer ces données.
    func applySpeedtestVisibility(serverID: String, isSharedOnMap: Bool) {
        activeLoad = nil
        isLoading = false
        if !isSharedOnMap {
            speedtestTiles = speedtestTiles.map { tile in
                AndroidSpeedtestTileResponse(tile: tile.tile, clusters: [],
                    markers: tile.markers.filter { $0.id != serverID }, stats: tile.stats)
            }
            let kept = snapshot.speedtests.filter { $0.id != serverID }
            let removed = snapshot.speedtests.count - kept.count
            snapshot = SocialMapSnapshot(timestamp: snapshot.timestamp, friends: snapshot.friends,
                photos: snapshot.photos, validations: snapshot.validations, sessions: snapshot.sessions,
                coveragePoints: snapshot.coveragePoints, speedtests: kept,
                photosCount: snapshot.photosCount, validationsCount: snapshot.validationsCount,
                sessionsCount: snapshot.sessionsCount, coveragePointsCount: snapshot.coveragePointsCount,
                speedtestsCount: max(0, snapshot.speedtestsCount - removed),
                rawCoveragePointsCount: snapshot.rawCoveragePointsCount,
                logicalCoveragePointsCount: snapshot.logicalCoveragePointsCount)
        }
        dataVersion &+= 1
    }

    /// Une zone privée peut masquer plusieurs mesures et trajets d'un coup.
    /// Les tuiles déjà affichées disparaissent avant tout rechargement réseau ;
    /// une réponse antérieure en vol ne peut pas les restaurer.
    func discardPublicMeasurementsAfterPrivacyZoneChange() {
        activeLoad = nil
        isLoading = false
        speedtestTiles = []
        coverageTiles = []
        coverageHeat = []
        tileLoadIssues.removeValue(forKey: .speedtest)
        tileLoadIssues.removeValue(forKey: .coverage)
        snapshot = SocialMapSnapshot(timestamp: snapshot.timestamp, friends: snapshot.friends,
            photos: snapshot.photos, validations: snapshot.validations, sessions: [],
            coveragePoints: [], speedtests: [], photosCount: snapshot.photosCount,
            validationsCount: snapshot.validationsCount, sessionsCount: 0,
            coveragePointsCount: 0, speedtestsCount: 0, rawCoveragePointsCount: 0,
            logicalCoveragePointsCount: 0)
        dataVersion &+= 1
    }

    func load(region: MKCoordinateRegion, zoom: Double, filters: Set<MapDisplayItem.Kind>, lightweight: Bool = true, requestID: UUID? = nil, refresh: Bool = false) async {
        let bounds = MapBounds(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        await load(bounds: bounds, zoom: zoom, filters: filters, lightweight: lightweight, requestID: requestID, refresh: refresh)
    }

    func load(bounds: MapBounds, zoom: Double, filters: Set<MapDisplayItem.Kind>, lightweight: Bool = true, requestID: UUID? = nil, refresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        let id = requestID ?? prepareLoad(filters: filters, lightweight: lightweight)
        guard let context = activeLoad?.context, isCurrentLoad(id, context: context) else { return }
        defer {
            // An older operation must never stop the newer operation's spinner.
            if activeLoad?.id == id {
                discardIncompatibleData(for: loadContext(filters: filters, lightweight: lightweight))
                isLoading = false
            }
        }
        let querySegments: [MapBounds]
        do {
            querySegments = try bounds.canonicalSegments
            let projection = try MapTilePlanner.plan(bounds: bounds, zoom: zoom, tileBudget: 1, maximumZoom: 0)
            if projection.clipsPolarArea {
                displayLimitMessages.append(String(localized: "Une partie de cette zone dépasse la projection de la carte."))
            }
        } catch {
            errorMessage = error.userFacingMessage
            return
        }
        if AppEnvironment.usesDemoData {
            hasCurrentResponse = true
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
        // Fetch independently and publish each response as soon as it arrives.
        // Immutable inputs are captured by Sendable tasks; transformations and
        // generation checks stay on the MainActor in the receiving loop.
        let svc = mapService
        let sessionID = context.session
        let antennasSvc = antennasService
        let outagesSvc = communityOutageService
        let market = marketFilter
        let op = operatorFilter
        let techs = techFilters
        let bands = bandFilters
        let bandMatchMode = bandMatch
        let focus = coverageFocus
        let sharing = sharingFilters
        let includeObserved = includeObservedSites
        let stDays = speedtestDays
        let covDays = coverageDays
        let communityOnly = isCommunityOnlyMarket
        let supportsCommunity = supportsCommunityLayers

        let wantsAntenna = filters.contains(.antenna) && !communityOnly
        let wantsCommunitySites = (filters.contains(.communitySite) || (communityOnly && filters.contains(.antenna))) && supportsCommunity
        // Sites personnalisés : AUCUNE garde de marché. Ils sont saisis à la main,
        // donc ils existent partout — et dans un pays sans open data (Bosnie,
        // Portugal…) ils sont la SEULE antenne que la carte puisse montrer. C'est
        // pourquoi « Antennes » les entraîne sur ces marchés : y demander des
        // antennes sans les obtenir n'aurait aucun sens.
        let wantsCustomSites = filters.contains(.customSite) || (communityOnly && filters.contains(.antenna))
        let wantsSpeedtest = filters.contains(.speedtest)
        // Pannes signalées : chargées AUSSI quand le filtre « Pannes » est éteint,
        // parce qu'elles deviennent alors le badge du point d'antenne. Ne les charger
        // que filtre allumé reviendrait à masquer l'indice au moment précis où l'on
        // regarde l'antenne concernée. Aucune garde de marché, contrairement aux
        // incidents opérateurs : elles ne sortent d'aucun open data.
        //
        // La couche « Sites ajoutés » compte autant que les antennes officielles : une panne
        // s'accroche à un site COMMUNAUTAIRE dans les 44 marchés sans référentiel public, et
        // éteindre « Antennes » y faisait disparaître le badge du seul point qui pouvait le
        // porter — la couche n'était donc pas « toujours chargée » comme l'exige le modèle.
        //
        // « Cellules observées » ne figure PAS ici, et ce n'est pas un oubli : aucun marqueur de
        // cette couche ne peut porter de badge de panne. `resolveOutageTarget` résout `custom` et
        // `community` contre la table `CustomSite` (cf. `apps/web/lib/outages/target.ts`), alors
        // que ces marqueurs viennent des candidats communautaires — leurs identifiants n'y
        // existent pas, donc `communityOutageMarksBySite` ne trouverait jamais de clé. La couche
        // était donc chargée pour rien, à chaque déplacement de carte.
        let wantsCommunityOutages = filters.contains(.outage)
            || filters.contains(.antenna)
            || filters.contains(.customSite)
        // Sites prévisionnels et pannes : FR métropole ET DROM (le backend répond
        // pour FR/DROM). En DROM on déduit le territoire (974, 971…) du centre du
        // viewport pour la résolution opérateur par île, comme le sélecteur web.
        let entry = registryMarket(forCode: market)
        let supportsPlanned = entry?.capabilities.previsionnel ?? ["FR", "DROM"].contains(market.uppercased())
        let supportsOutage = entry?.capabilities.incidents ?? ["FR", "DROM"].contains(market.uppercased())
        let territory = market.uppercased() == "DROM" ? Self.dromTerritory(for: bounds) : nil
        let wantsPlanned = filters.contains(.planned) && supportsPlanned
        // Incidents opérateurs : chargés AUSSI filtre « Pannes » éteint, exactement comme les
        // signalements communautaires — ils deviennent alors le badge du point d'antenne. Sans
        // cela, une antenne que l'OPÉRATEUR déclare hors service ne portait aucune marque, là où
        // un simple signalement d'utilisateur en portait une : c'est l'information la plus fiable
        // qui s'effaçait. La garde de marché reste, elle : ces flux sont FR/DROM.
        let wantsOutage = (filters.contains(.outage) || filters.contains(.antenna)) && supportsOutage
        // Couverture masquée en « Tous » (superposer tous les opérateurs n'a pas de
        // sens) → on ne la télécharge même pas dans ce cas.
        let wantsCoverage = filters.contains(.coverage) && op.uppercased() != "ALL"

        // Photos : couche dédiée `/api/map/photos` (TOUS les membres), ou de mes
        // seuls amis sur choix explicite dans les filtres.
        let wantsPhoto = filters.contains(.photo)
        let photosFriendsOnly = self.photosFriendsOnly
        // Le snapshot « lightweight » omet validations/sessions (perf). On ne charge
        // le snapshot COMPLET que pour ces couches (les photos ont leur endpoint).
        let needsHeavySnapshot = filters.contains(.validation) || filters.contains(.session)
        let snapshotLightweight = lightweight && !needsHeavySnapshot
        let wantsSocialSnapshot = filters.contains(.friend) || needsHeavySnapshot
        let usesAdvancedAntennaFilters = !techs.isEmpty || !bands.isEmpty || !sharing.isEmpty
        do {
            var plans: [MapTilePlan] = []
            if (wantsAntenna && !usesAdvancedAntennaFilters) || wantsCommunitySites || wantsCustomSites || wantsSpeedtest {
                plans.append(try MapTilePlanner.plan(bounds: bounds, zoom: zoom))
            }
            if wantsCoverage {
                let boost = zoom < 11 ? 1 : 0
                plans.append(try MapTilePlanner.plan(bounds: bounds, zoom: zoom, detailBoost: boost, tileBudget: boost > 0 ? 40 : 24))
            }
            if plans.contains(where: \.usesReducedDetail) {
                displayLimitMessages.append(String(localized: "Niveau de détail adapté pour couvrir toute la zone visible. Zoome pour préciser."))
            }
        } catch {
            errorMessage = error.userFacingMessage
            return
        }
        // Retain response metadata for the final, fixed-order status aggregation.
        // The data itself is assigned only in the receiving loop below.
        var snap: (snapshot: SocialMapSnapshot?, error: String?) = (nil, nil)
        var antenna: (tiles: MapTileLayerResult<AndroidAntennaTileResponse>?, list: [AntennaSite]?, error: String?) = (nil, nil, nil)
        var community = MapTileLayerResult<AndroidCommunitySiteTileResponse>(tiles: [])
        var custom = MapTileLayerResult<AndroidCustomSiteTileResponse>(tiles: [])
        var speedtest = MapTileLayerResult<AndroidSpeedtestTileResponse>(tiles: [])
        var planned: (value: MapFeedResult<PlannedSiteLive>?, error: String?) = (nil, nil)
        var outage: (value: MapFeedResult<OutageSiteLive>?, error: String?) = (nil, nil)
        var communityOutage: (value: [CommunityOutage]?, error: String?, atLimit: Bool) = (nil, nil, false)
        var coverage: (value: (tiles: MapTileLayerResult<AndroidCoverageTileResponse>, heat: [CoverageHeatPoint])?, error: String?) = (nil, nil)
        var photos: (value: [MapPublicPhoto]?, error: String?) = (nil, nil)

        await withTaskGroup(of: LayerResult.self) { group in
            group.addTask {
                let result: (snapshot: SocialMapSnapshot?, error: String?) = await {
                    guard wantsSocialSnapshot else { return (.empty, nil) }
                    do { return (try await svc.snapshot(bounds: bounds, zoom: zoom, lightweight: snapshotLightweight), nil) }
                    catch { return (nil, error.isCancellation ? nil : error.userFacingMessage) }
                }()
                return .snapshot(result)
            }
            // Keep admitted tiles until publication. If none was admitted, preserve
            // the existing bbox fallback; an admitted empty tile must not broaden it.
            group.addTask {
                let result: (tiles: MapTileLayerResult<AndroidAntennaTileResponse>?, list: [AntennaSite]?, error: String?) = await {
                    guard wantsAntenna else { return (nil, [], nil) }
                    if !usesAdvancedAntennaFilters {
                        let result = await MapTileLayerResult.load {
                            try await svc.antennaTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, withAzimuth: true, bands: bands)
                        }
                        if result.tiles != nil { return (result, nil, result.errorMessage) }
                        guard result.errorMessage != nil else { return (nil, nil, nil) }
                    }
                    guard !Task.isCancelled, svc.sessionIdentifier == sessionID else { return (nil, nil, nil) }
                    do {
                        var parts: [[AntennaSite]] = []
                        for segment in querySegments {
                            guard !Task.isCancelled, svc.sessionIdentifier == sessionID else { return (nil, nil, nil) }
                            parts.append(try await antennasSvc.list(bbox: segment.asBoundingBox, market: market, operatorName: op,
                                technologies: techs, bands: bands, bandMatch: bandMatchMode, sharing: sharing))
                        }
                        return (nil, MapSnapshotMerging.unique(parts, id: \.id), nil)
                    } catch {
                        return (nil, nil, error.isCancellation ? nil : error.userFacingMessage)
                    }
                }()
                return .antenna(result)
            }
            group.addTask {
                let result = await MapTileLayerResult.load(enabled: wantsCommunitySites) {
                    try await svc.communitySiteTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, includeObserved: includeObserved, bands: bands)
                }
                return .communitySite(result)
            }
            group.addTask {
                let result = await MapTileLayerResult.load(enabled: wantsCustomSites) {
                    try await svc.customSiteTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op)
                }
                return .customSite(result)
            }
            group.addTask {
                let result = await MapTileLayerResult.load(enabled: wantsSpeedtest) {
                    try await svc.speedtestTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: stDays, bands: bands, maxAge: refresh ? 0 : nil)
                }
                return .speedtest(result)
            }
            // Prévisionnels & pannes : respectent le filtre opérateur de la carte
            // (l'opérateur sélectionné `op`, ou ALL quand « Tous » est choisi). Le
            // backend FR accepte ALL comme un opérateur précis.
            group.addTask {
                let result: (value: MapFeedResult<PlannedSiteLive>?, error: String?) = await {
                    guard wantsPlanned else { return (MapFeedResult(sites: []), nil) }
                    do {
                        let sites = try await svc.plannedSitesLayer(market: market, operatorName: op, territory: territory, bands: bands)
                        return (sites.filter { bounds.contains(lat: $0.lat, lon: $0.lon) }, nil)
                    } catch { return (nil, error.isCancellation ? nil : error.userFacingMessage) }
                }()
                return .planned(result)
            }
            group.addTask {
                let result: (value: MapFeedResult<OutageSiteLive>?, error: String?) = await {
                    guard wantsOutage else { return (MapFeedResult(sites: []), nil) }
                    do {
                        let sites = try await svc.outageSitesLayer(market: market, operatorName: op, territory: territory, bands: bands)
                        return (sites.filter { bounds.contains(lat: $0.lat, lon: $0.lon) }, nil)
                    } catch { return (nil, error.isCancellation ? nil : error.userFacingMessage) }
                }()
                return .outage(result)
            }
            group.addTask {
                let result: (value: [CommunityOutage]?, error: String?, atLimit: Bool) = await {
                    guard wantsCommunityOutages else { return ([], nil, false) }
                    do {
                        var parts: [[CommunityOutage]] = []
                        for segment in querySegments {
                            parts.append(try await outagesSvc.outages(in: segment, marketCode: market, operatorKey: op))
                        }
                        return (MapSnapshotMerging.unique(parts, id: \.id), nil, parts.contains { $0.count >= 500 })
                    } catch { return (nil, error.isCancellation ? nil : error.userFacingMessage, false) }
                }()
                return .communityOutage(result)
            }
            group.addTask {
                let result: (value: (tiles: MapTileLayerResult<AndroidCoverageTileResponse>, heat: [CoverageHeatPoint])?, error: String?) = await {
                    guard wantsCoverage else { return ((MapTileLayerResult(tiles: []), []), nil) }
                    let result = await MapTileLayerResult.load {
                        try await svc.coverageTiles(bounds: bounds, zoom: zoom, market: market, operatorName: op, days: covDays, bands: bands, maxAge: refresh ? 0 : nil, focus: focus)
                    }
                    if result.tiles != nil {
                        return ((result, []), result.errorMessage)
                    }
                    guard let tileError = result.errorMessage else { return (nil, nil) }
                    guard !Task.isCancelled, svc.sessionIdentifier == sessionID else { return (nil, nil) }
                    // This legacy fallback cannot represent a site or another time window.
                    guard focus == nil, covDays == 30, techs.count <= 1, bands.isEmpty else {
                        // Without a compatible fallback, retain only failed identities.
                        return result.failure == nil ? (nil, tileError) : ((result, []), tileError)
                    }
                    do {
                        let points = try await svc.coveragePoints(bounds: bounds, market: market, operatorName: op, technology: techs.sorted().first, bands: bands)
                        return ((MapTileLayerResult(tiles: []), points), nil)
                    } catch { return (nil, error.isCancellation ? nil : error.userFacingMessage) }
                }()
                return .coverage(result)
            }
            group.addTask {
                let result: (value: [MapPublicPhoto]?, error: String?) = await {
                    guard wantsPhoto else { return ([], nil) }
                    // Couche communautaire : on veut TOUTES les photos des membres, quel que
                    // soit le filtre opérateur des antennes → opérateur forcé à "ALL". Seul le
                    // choix « amis seulement » restreint l'ensemble.
                    do { return (try await svc.publicPhotos(bounds: bounds, zoom: zoom, market: market, operatorName: "ALL", friendsOnly: photosFriendsOnly), nil) }
                    catch { return (nil, error.isCancellation ? nil : error.userFacingMessage) }
                }()
                return .photos(result)
            }

            for await response in group {
                // A reservation made during debounce revokes every old response,
                // including those from services that ignore cancellation.
                guard !Task.isCancelled, isCurrentLoad(id, context: context) else {
                    group.cancelAll()
                    return
                }
                var didPublish = false
                switch response {
                case .snapshot(let result):
                    snap = result
                    if let value = result.snapshot {
                        // Disabled social layers return .empty: discard their old
                        // seed without invalidating the active layers' rendering.
                        snapshot = value
                        didPublish = wantsSocialSnapshot
                        // Only a successful response can seed friends, and SSE
                        // remains authoritative once it has responded.
                        if wantsSocialSnapshot, !friendsFromStream {
                            liveFriends = value.friends
                        }
                    }
                    #if DEBUG
                    if AppEnvironment.usesDemoPhotos {
                        snapshot = Self.snapshotInjectingQAPhotos(into: snapshot, around: bounds)
                        didPublish = true
                    }
                    #endif
                    #if DEBUG
                    if AppEnvironment.usesDemoFriends {
                        liveFriends = Self.demoFriends(around: bounds)
                        didPublish = true
                    }
                    #endif
                case .antenna(let result):
                    antenna = result
                    if wantsAntenna {
                        if let value = result.tiles, let tiles = value.retaining(retainedAntennaTiles) {
                            tileLoadIssues[.antenna] = value.issue(retaining: retainedAntennaTiles)
                            retainedAntennaTiles = tiles
                            antennaClusters = tiles.flatMap(\.clusters)
                            antennas = Self.antennas(from: tiles).filter(\.hasValidCoordinate)
                            didPublish = true
                        } else if let list = result.list {
                            retainedAntennaTiles = []
                            antennaClusters = []
                            antennas = list.filter(\.hasValidCoordinate)
                            didPublish = true
                        }
                    }
                case .communitySite(let result):
                    community = result
                    if wantsCommunitySites {
                        tileLoadIssues[.communitySite] = result.issue(retaining: communitySiteTiles)
                        if let value = result.retaining(communitySiteTiles) {
                            communitySiteTiles = value
                            didPublish = true
                        }
                    }
                case .customSite(let result):
                    custom = result
                    if wantsCustomSites {
                        tileLoadIssues[.customSite] = result.issue(retaining: customSiteTiles)
                        if let value = result.retaining(customSiteTiles) {
                            customSiteTiles = value
                            didPublish = true
                        }
                    }
                case .speedtest(let result):
                    speedtest = result
                    if wantsSpeedtest {
                        tileLoadIssues[.speedtest] = result.issue(retaining: speedtestTiles)
                        if let value = result.retaining(speedtestTiles) {
                            speedtestTiles = value
                            didPublish = true
                        }
                    }
                case .planned(let result):
                    planned = result
                    if wantsPlanned, let value = result.value {
                        plannedSites = value.retaining(plannedSites.filter { bounds.contains(lat: $0.lat, lon: $0.lon) })
                        didPublish = true
                    }
                case .outage(let result):
                    outage = result
                    if wantsOutage, let value = result.value {
                        outages = value.retaining(outages.filter { bounds.contains(lat: $0.lat, lon: $0.lon) })
                        didPublish = true
                    }
                case .communityOutage(let result):
                    communityOutage = result
                    if wantsCommunityOutages, let value = result.value {
                        communityOutages = value
                        didPublish = true
                    }
                case .coverage(let result):
                    coverage = result
                    if wantsCoverage, let value = result.value {
                        tileLoadIssues[.coverage] = value.tiles.issue(retaining: coverageTiles)
                        if let tiles = value.tiles.retaining(coverageTiles) { coverageTiles = tiles }
                        coverageHeat = value.heat
                        didPublish = true
                    }
                case .photos(let result):
                    photos = result
                    if AppEnvironment.usesDemoPhotos {
                        #if DEBUG
                        publicPhotos = Self.demoPublicPhotos(around: bounds)
                        didPublish = true
                        #endif
                    } else if wantsPhoto, let value = result.value {
                        publicPhotos = value
                        didPublish = true
                    }
                }
                if didPublish { dataVersion &+= 1 }
            }
        }

        // Chargement REMPLACÉ (pan / changement de filtre / d'onglet suivant) : on
        // conserve les données déjà à l'écran au lieu de tout effacer et d'afficher
        // une erreur « Requête annulée ». (Régression du chargement parallèle.)
        guard !Task.isCancelled, isCurrentLoad(id, context: context) else { return }

        // Error priority is stable regardless of the order of arrival. Failed
        // layers retain their data; successful empty results were already applied.
        var layerError = snap.error
        if let error = antenna.error { layerError = layerError ?? error }
        if let error = community.errorMessage { layerError = layerError ?? error }
        if let error = custom.errorMessage { layerError = layerError ?? error }
        if let error = speedtest.errorMessage { layerError = layerError ?? error }
        if let value = planned.value {
            if let error = value.availability.errorMessage { layerError = layerError ?? String(localized: "Prévisionnels") + ": " + error }
            if let info = value.availability.information { displayLimitMessages.append(String(localized: "Prévisionnels") + ": " + info) }
        } else if let error = planned.error { layerError = layerError ?? error }
        // Couche « Pannes » éteinte, les incidents opérateurs ne servent qu'aux
        // badges des antennes : leur source en panne ne doit pas se présenter
        // comme une erreur de toute la carte (AF-CARTE-03).
        let showsOutageLayer = filters.contains(.outage)
        if let value = outage.value {
            if let error = value.availability.errorMessage {
                if showsOutageLayer { layerError = layerError ?? String(localized: "Pannes") + ": " + error }
            }
            if let info = value.availability.information, showsOutageLayer {
                displayLimitMessages.append(String(localized: "Pannes") + ": " + info)
            }
        } else if let error = outage.error, showsOutageLayer { layerError = layerError ?? error }
        // Community outages remain informational rather than a map-wide error.
        if let error = coverage.error { layerError = layerError ?? error }
        if !AppEnvironment.usesDemoPhotos, photos.value == nil, let error = photos.error {
            layerError = layerError ?? error
        }
        // ROB-08 : nil si tout a réussi (errorMessage déjà remis à nil en début de
        // `load`) ; sinon signale l'indisponibilité sans avoir écrasé les couches.
        // Identify each affected layer, and explain when its failed zones retain
        // older data. The existing retry invalidates caches before loading again.
        let tileMessages = tileLoadIssues.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            MapTileLoadIssue.layerName($0.key) + ": " + $0.value.message
        }
        errorMessage = tileMessages.isEmpty ? layerError : tileMessages.joined(separator: "\n")
        hasCurrentResponse = layerError == nil && snap.snapshot != nil
            && (antenna.tiles != nil || antenna.list != nil)
            && community.tiles != nil && custom.tiles != nil && speedtest.tiles != nil
            && planned.value?.availability.isComplete == true && outage.value?.availability.isComplete == true && communityOutage.value != nil
            && coverage.value != nil && photos.value != nil
        if MapDataLimits.speedtests(speedtestTiles) || MapDataLimits.coverage(coverageTiles)
            || MapDataLimits.communitySites(communitySiteTiles) || MapDataLimits.customSites(customSiteTiles)
            || communityOutage.atLimit {
            displayLimitMessages.append(String(localized: "Une limite de données a été atteinte. Zoome pour explorer plus précisément cette zone."))
        }
        if communityOutage.error != nil {
            displayLimitMessages.append(String(localized: "Certains signalements sont momentanément indisponibles."))
        }
        var seenMessages = Set<String>()
        displayLimitMessages = displayLimitMessages.filter { seenMessages.insert($0).inserted }
        let failedTiles = tileLoadIssues.values.reduce(0) { $0 + $1.failedTiles.count }
        let retainedTiles = tileLoadIssues.values.reduce(0) { $0 + $1.retainedCount }
        let speedtestCount = speedtestTiles.reduce(0) { $0 + $1.markers.count }
        let coverageCount = coverageTiles.reduce(0) { $0 + $1.points.count }
        MapDiagnosticsLog.logger.info(
            "load \(id.uuidString, privacy: .public) version=\(self.dataVersion) antennas=\(self.antennas.count) antennaClusters=\(self.antennaClusters.count) speedtests=\(speedtestCount) coverage=\(coverageCount) photos=\(self.publicPhotos.count) failedTiles=\(failedTiles) retainedTiles=\(retainedTiles) error=\(self.errorMessage != nil) complete=\(self.hasCurrentResponse)"
        )
    }

    /// Applique un instantané du flux temps réel des amis. Fait autorité sur
    /// l'amorçage borné : `load()` cesse ensuite de réécrire `liveFriends`.
    func beginFriendsStream() {
        friendsConnectionState = .connecting
        friendsConnectionError = nil
    }

    func applyLiveFriends(_ friends: [SocialFriendLive], isFallback: Bool = false) {
        friendsFromStream = true
        friendsConnectionState = isFallback ? .fallback : .live
        friendsConnectionError = nil
        friendsLastUpdatedAt = Date()
        // PERF-MAP-05 : garde de diff — un tick identique (ami immobile, même
        // présence/radio) ne déclenche AUCUN travail de rendu.
        guard friends != liveFriends else { return }
        liveFriends = friends
        // Ne bumpe PAS `dataVersion` (qui reconstruirait TOUTES les couches) : seul
        // `friendsVersion` → la vue ne rafraîchit que la couche amis (PERF-MAP-05).
        friendsVersion &+= 1
    }

    func friendsStreamDidEnd() {
        friendsFromStream = false
        friendsConnectionState = .unavailable
        friendsConnectionError = String(localized: "Temps réel indisponible — repli périodique")
    }

    func friendsFallbackDidFail(_ error: Error) {
        friendsConnectionState = .unavailable
        friendsConnectionError = error.userFacingMessage
    }

    func deactivateFriendsStream() {
        friendsFromStream = false
        friendsConnectionState = .inactive
        friendsConnectionError = nil
        friendsLastUpdatedAt = nil
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
                ? SocialRadioSnapshot(technology: seed.tech, rsrp: seed.rsrp, rsrq: nil, snr: nil, pci: nil, enb: nil, gnb: nil, cellId: nil, band: seed.tech == "5G" ? 78 : 7, operator: seed.op, city: "Grenoble", updatedAt: Date())
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
        // En recherche dès la frappe : pendant l'anti-rebond, la liste encore vide
        // affichait « Aucun résultat » avant même d'avoir cherché (UI-14).
        isSearching = true
        searchFailed = false
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
        // `nil` : la recherche d'antennes a échoué ; `[]` : elle n'a rien trouvé.
        async let antennasResult = try? await antennasService.quickSearch(
            query: q,
            market: marketFilter,
            department: currentDromRegion?.department
        )
        async let placesResult = geocodePlaces(q)
        let antennas = await antennasResult
        let places = await placesResult
        guard !Task.isCancelled, searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
        let merged = Self.mergeSearchResults(places: places, antennas: antennas ?? [])
        searchResults = merged
        // « Indisponible » seulement si la recherche a échoué : une requête
        // sans résultat n'est pas une panne (AF-CARTE-02).
        searchFailed = merged.isEmpty && !q.isEmpty && antennas == nil
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
        await Self.geocodePlaces(q, near: lastCenter)
    }

    /// Même géocodage, partagé avec la recherche d'Explorer (plan 3, vague 2).
    nonisolated static func geocodePlaces(_ q: String, near center: CLLocationCoordinate2D?) async -> [PlaceResult] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQ_MAP_PROFILE_QA"] == "1" {
            // Fixture dédiée : aucune requête Apple, même en cas d'erreur ou
            // de configuration incorrecte. Les URL proviennent du binaire.
            return await MapProfileQASearch.places(query: q, config: .current)
        }
        #endif
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let center {
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

    /// Groupe les azimuts d'un site partagé par DIRECTION, avec les couleurs des
    /// opérateurs qui la pointent.
    ///
    /// Deux opérateurs déclarant 0° et 1° visent la même chose : les traiter
    /// comme deux directions donnerait deux traits superposés dont un seul
    /// serait visible.
    /// `nonisolated` : la fonction est pure, elle ne touche à rien du modèle —
    /// et les tests doivent pouvoir l'appeler hors du main actor.
    nonisolated static func groupAzimuthBeams(
        operators: [String],
        azimuthsByOperator: [String: [Double]],
        tint: (String) -> Color
    ) -> [AzimuthBeam] {
        // Ordre du site, pas celui du dictionnaire : la séquence des couleurs
        // doit rester stable d'un rendu à l'autre, sinon les tirets sautent.
        let ordered = operators.filter { azimuthsByOperator[$0] != nil }
        let keys = ordered.isEmpty ? azimuthsByOperator.keys.sorted() : ordered

        var beams: [(azimuth: Double, tints: [Color])] = []
        for key in keys {
            let color = tint(key)
            for azimuth in azimuthsByOperator[key] ?? [] {
                if let index = beams.firstIndex(where: { isSameDirection($0.azimuth, azimuth) }) {
                    if !beams[index].tints.contains(color) { beams[index].tints.append(color) }
                } else {
                    beams.append((azimuth, [color]))
                }
            }
        }
        return beams
            .sorted { $0.azimuth < $1.azimuth }
            .map { AzimuthBeam(azimuth: $0.azimuth, tints: $0.tints) }
    }

    /// Deux azimuts à moins de 6° l'un de l'autre pointent la même direction.
    /// Le seuil reste bien sous l'ouverture d'un secteur (65°) : il fusionne des
    /// déclarations voisines, jamais deux secteurs distincts. Le calcul passe par
    /// l'écart circulaire, sinon 358° et 2° sembleraient opposés.
    nonisolated static func isSameDirection(_ a: Double, _ b: Double) -> Bool {
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta) <= 6
    }

    /// Adapte un site relevé à la main en `AntennaSite`, la forme qu'attend la
    /// fiche terrain. On ne remplit que ce que la tuile sait : le reste arrive
    /// avec la réponse de `/map/antenna/{id}`, qui sert les deux types de sites.
    static func antennaSite(from marker: AndroidCustomSiteMarker) -> AntennaSite {
        let radio = marker.radio
        return AntennaSite(
            id: marker.id,
            siteId: marker.id,
            anfrCode: nil,
            latitude: marker.lat,
            longitude: marker.lng,
            operators: [radio?.operatorName].compactMap { $0 },
            technologies: [radio?.technology].compactMap { $0 },
            bands: [radio?.band].compactMap { $0 },
            azimuths: [],
            sharingType: nil,
            crozonLeader: nil,
            address: nil,
            height: nil,
            owner: radio?.operatorName
        )
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
                isZTD: marker.isZTD,
                address: marker.address,
                // La tuile porte `support_info.hauteur` : la retenir évite à la
                // fiche de calculer sa ligne de visée sur une hauteur par défaut
                // en attendant la réponse du détail.
                height: marker.supportHeightMeters,
                owner: marker.operator
            )
            site.photoCount = marker.photoCount
            site.validationCount = marker.validationCount
            site.hasEnb = marker.hasEnb
            site.hasGnb = marker.hasGnb
            site.supportNature = marker.supportNature
            site.radioSystems = marker.radioSystems
            site.azimuthsByOperator = marker.azimutsByOperator
            site.operators5G = marker.operators5G
            return site
        }
    }
}

/// Échec du recentrage GPS, avec l'action qui correspond à sa cause.
private enum MapLocationIssue {
    case denied
    case unavailable

    var message: String {
        switch self {
        case .denied: return String(localized: "Localisation désactivée. Active-la dans Réglages > SignalQuest pour te localiser sur la carte.")
        case .unavailable: return String(localized: "Position actuelle indisponible")
        }
    }

    var actionTitle: String {
        switch self {
        case .denied: return String(localized: "Ouvrir les Réglages")
        case .unavailable: return String(localized: "Réessayer la position")
        }
    }
}

/// Un point choisi par appui long sur la carte. Il se déplace sans refermer la feuille.
private struct ZoneCompareTarget: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
}

struct MapExplorerView: View {
    private struct FriendsStreamTaskKey: Hashable {
        let enabled: Bool
        let session: UUID?
        let generation: Int
    }

    @StateObject private var model: MapExplorerViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFieldFocused: Bool

    @State private var mapCenter: CLLocationCoordinate2D
    @State private var mapZoom: Double
    /// État de scène, pas une donnée métier : le pin de recherche survit à une
    /// recréation de cette vue (rotation / restauration SwiftUI), mais n'est
    /// jamais envoyé à l'API ni enregistré dans le catalogue utilisateur.
    @SceneStorage("map.searchPin.latitude.v1") private var searchPinLatitude = ""
    @SceneStorage("map.searchPin.longitude.v1") private var searchPinLongitude = ""
    @SceneStorage("map.searchPin.title.v1") private var searchPinTitle = ""
    @SceneStorage("map.searchPin.subtitle.v1") private var searchPinSubtitle = ""
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
    /// Sites et lieux consultés récemment, proposés quand on touche la
    /// recherche sans rien saisir (plan 3, vague 1).
    @State private var recentItems: [RecentlyViewedStore.Item] = []
    @State private var selectedPhoto: MapPhotoTarget?
    /// Fiche ouverte depuis la visionneuse photo, par-dessus elle.
    @State private var photoSiteAntenna: AntennaSite?
    @State private var selectedOutage: OutageSiteLive?
    /// Panne signalée par la communauté ouverte depuis la carte. Distincte de
    /// `selectedOutage` (incident opérateur) : deux sources, deux feuilles.
    @State private var selectedCommunityOutage: CommunityOutage?
    @State private var selectedPlanned: PlannedSiteLive?
    @State private var selectedFriend: SocialFriendLive?
    @State private var selectedFriendFilterID: String?
    @State private var friendsStreamGeneration = 0
    @State private var friendFreshnessNow = Date()
    @State private var selectedCustomSite: AndroidCustomSiteMarker?
    @State private var selectedObservedCell: AndroidCommunitySiteMarker?
    /// Cellules retenues pour créer un site — non vide = l'écran de création
    /// est présenté.
    @State private var cellsForNewSite: [AndroidCommunitySiteMarker] = []
    @State private var fetchTask: Task<Void, Never>?
    /// Échec du recentrage GPS : un état à part de `model.errorMessage`, dont le
    /// « Réessayer » recharge la carte et non la position.
    @State private var locationIssue: MapLocationIssue?
    /// Demande de position arrivée à échéance pendant la fenêtre d'autorisation :
    /// le recentrage reprend dès que l'accès est accordé, sans message d'échec.
    @State private var recentersWhenAuthorized = false
    @State private var lastRegion: MKCoordinateRegion
    @State private var viewportGate = MapViewportLoadGate()
    @State private var viewportRefreshID = 0
    @State private var seenPrivacyZoneMapRevision: UInt64 = 0
    @State private var showFilterSheet = false
    /// Point touché longuement sur la carte : ouvre le comparatif d'opérateurs de la zone.
    @State private var zoneCompareTarget: ZoneCompareTarget?
    /// Rayon montré sur la carte par la comparaison ouverte, et cadrage demandé.
    @State private var zoneCompareRadiusMeters: Double = Double(ANFRZoneRadius.default.kilometers) * 1000
    @State private var zoneCompareFitToken = 0
    /// Marqueur touché pendant la comparaison : ouvert une fois la feuille refermée.
    @State private var selectionAfterZoneCompare: MapAnnotationPayload?
    /// Astuce de l'appui long : montrée une fois, à partir de la 2e ouverture de la carte.
    @AppStorage("map_zone_compare_tip_visits") private var zoneCompareTipVisits = 0
    @AppStorage("map_zone_compare_tip_done") private var zoneCompareTipDone = false
    /// Feuille Carte : opérateur, couches, fond, pays, légende et registre ANFR.
    @State private var showLayersSheet = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filterSheetDetent: PresentationDetent = .large
    // Écrans ANFR, repris du menu Profil : c'est ici qu'on cherche une carte.
    @State private var showsANFRMap = false
    @State private var showsANFRStats = false
    /// Écran ANFR demandé depuis la feuille de filtres, ouvert à sa fermeture :
    /// naviguer pendant la transition de la feuille échouait.
    @State private var pendingANFR: MapANFRDestination?

    private static let resetStoresOnce: Void = {
        MapRegionStore.reset()
        MapMarketStore.reset()
    }()

    init(service: MapSnapshotServicing,
         antennas: AntennasServicing,
         markets: MarketRegistryServicing,
         communityOutages: CommunityOutageServicing) {
        _model = StateObject(wrappedValue: MapExplorerViewModel(
            map: service, antennas: antennas, markets: markets, communityOutages: communityOutages
        ))
        // QA : `--reset-map` oublie région + marché/opérateur pour rejouer la détection,
        // une seule fois par lancement : SwiftUI recrée cette vue à chaque rendu de son
        // parent, et l'effacement répété faisait tourner l'app en boucle sous XCTest.
        if AppEnvironment.resetsMapOnLaunch { _ = Self.resetStoresOnce }
        // Restaure la dernière région, sinon vue pays du marché initial (dernier
        // choix persisté ou pays de la locale) — jamais une ville ni la France imposée.
        let region = MapRegionStore.lastRegion() ?? Self.region(for: MapMarketStore.initialMarketCode())
        let initialZoom = SQMapProjection.zoom(forRegion: region, width: SQMapProjection.referenceWidth)
        _mapCenter = State(initialValue: region.center)
        _lastRegion = State(initialValue: region)
        _mapZoom = State(initialValue: initialZoom)
        _lastZoomRenderBucket = State(initialValue: Self.zoomRenderBucket(for: initialZoom))
    }

    var body: some View {
        ZStack {
            mapLayer
            controlsLayer
                // Les contrôles flottants partagent l'espace de la carte : à la
                // taille AX maximale, leurs libellés se chevauchent. La fiche et
                // les panneaux restent au Dynamic Type demandé par le système.
                .dynamicTypeSize(dynamicTypeSize.isAccessibilitySize ? .xxxLarge : dynamicTypeSize)
        }
        .overlay(alignment: .leading) { antennaSidePanel }
        .animation(SQMotion.resolve(SQMotion.snappy, reduceMotion), value: usesAntennaSidePanel ? selectedAntenna?.id : nil)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showsANFRMap) {
            ANFRMapView(service: services.anfr)
        }
        .navigationDestination(isPresented: $showsANFRStats) {
            ANFRStatsView(service: services.anfr)
        }
        .sheet(item: $selectedItem) { item in MapItemSheet(item: item) }
        .sheet(item: $zoneCompareTarget, onDismiss: {
            guard let annotation = selectionAfterZoneCompare else { return }
            selectionAfterZoneCompare = nil
            selectAnnotation(annotation)
        }) { target in
            NearbyOperatorComparisonSheet(
                metric: .download,
                latitude: target.coordinate.latitude,
                longitude: target.coordinate.longitude,
                startsOnAntennas: true,
                isChosenPoint: true,
                onRadiusChange: { meters, committed in
                    zoneCompareRadiusMeters = meters
                    if committed { zoneCompareFitToken &+= 1 }
                }
            )
        }
        .sheet(item: $selectedOutage) { site in
            OutageDetailSheet(site: site, operatorLabel: model.operatorLabel)
        }
        .sheet(item: $selectedCommunityOutage) { outage in
            CommunityOutageDetailSheet(
                outage: outage,
                service: services.communityOutages,
                // Le libellé du registre, comme le marqueur : la feuille montrait la
                // CLÉ brute (« BOUYGUES_TELECOM »), donc deux noms pour un même
                // opérateur selon qu'on lisait la carte ou ce qu'elle ouvre.
                operatorLabel: model.operatorLabel(outage.operatorKey),
                // Un arbitrage change les compteurs de la carte : sans rechargement,
                // le marqueur garderait l'état d'avant le vote.
                onChanged: { Task { await reloadCurrentRegion() } }
            )
        }
        .sheet(item: $selectedCustomSite) { site in
            customSiteSheet(site)
        }
        .sheet(item: $selectedObservedCell) { cell in
            observedCellSheet(cell)
        }
        .sheet(isPresented: Binding(
            get: { !cellsForNewSite.isEmpty },
            set: { if !$0 { cellsForNewSite = [] } }
        )) {
            CreateSiteFromCellsView(
                cells: cellsForNewSite,
                operatorLabel: { model.operatorLabel($0) },
                service: services.customSites,
                onCreated: { Task { await reloadCurrentRegion() } }
            )
        }
        .sheet(item: $selectedPlanned) { site in
            PlannedDetailSheet(site: site, operatorLabel: model.operatorLabel(site.operator ?? "ALL"), operatorAccent: model.operatorAccent(site.operator ?? "ALL"))
        }
        .sheet(item: $selectedFriend) { friend in
            // L'ami vivant relu par son identifiant : la valeur du tap resterait figée
            // alors que présence, position et radio évoluent avec le flux temps réel.
            FriendLiveSheet(
                friend: model.liveFriends.first(where: { $0.id == friend.id }) ?? friend,
                userLocation: services.location.cachedLocation()
            )
                .presentationDetents([.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
        }
        // iPhone : la fiche en feuille. iPad : en panneau à gauche (`antennaSidePanel`).
        .sheet(item: compactAntennaSelection) { site in
            antennaDetail(site)
        }
        .fullScreenCover(item: $selectedPhoto) { target in
            let site = photoSite(for: target.id)
            MapPhotoViewer(
                items: photoSiblings(of: target),
                initialId: target.id,
                service: services.photos,
                operatorAccent: { model.operatorAccent($0) },
                operatorLabel: { model.operatorLabel($0) },
                site: site.map(photoViewerSite),
                onOpenSite: site.map { found in { photoSiteAntenna = found } }
            )
            // La fiche s'ouvre PAR-DESSUS la photo : la fermer ramène à la photo.
            .sheet(item: $photoSiteAntenna) { site in
                AntennaDetailSheet(
                    site: site,
                    market: model.marketFilter,
                    operatorName: model.operatorFilter,
                    service: services.antennas,
                    sightOrigin: sightOrigin,
                    onIsolateCoverage: { focus in
                        photoSiteAntenna = nil
                        selectedPhoto = nil
                        isolateCoverage(focus)
                    },
                    onOutageChanged: { Task { await reloadCurrentRegion() } }
                )
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            MapAdvancedFilterSheet(
                selection: filterSelection,
                allMarkets: model.registryMarkets,
                dromRegion: model.currentDromRegion,
                onApply: applyFilterSelection
            )
            .presentationDetents([.medium, .large], selection: $filterSheetDetent)
            .sqSheet()
        }
        .sheet(isPresented: $showLayersSheet, onDismiss: openPendingANFR) {
            MapLayersSheet(
                market: model.marketFilter,
                operatorName: model.operatorFilter,
                layers: $filters,
                photosFriendsOnly: $model.photosFriendsOnly,
                byGeneration: $coverageByGeneration,
                allMarkets: model.registryMarkets,
                showsFriendsLayer: services.auth.hasStoredCredentials(),
                operatorOptions: model.operatorOptions,
                operatorLabel: { model.operatorShortLabel($0) },
                operatorAccent: { model.operatorAccent($0) },
                antennaOperators: antennaLegendOperators,
                onChooseOperator: { model.chooseOperatorManually($0) },
                onChooseMarket: { entry in
                    var next = filterSelection
                    next.market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
                    _ = applyFilterSelection(next)
                },
                onOpenANFR: { pendingANFR = $0 }
            )
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .sqSheet()
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
            // Avant le 1er chargement : sans compte, aucune restriction aux amis.
            if !services.auth.hasStoredCredentials() { model.photosFriendsOnly = false }
            await model.loadRegistry()
            // Sélection initiale du pays + opérateur (choix manuel/GPS/replis) AVANT le 1er
            // chargement : évite le flash « France/SFR puis Canada/Bell ».
            await model.resolveInitialSelection(
                networkPath: services.networkPath,
                networkOperator: services.networkOperator,
                location: services.location
            )
            guard !Task.isCancelled else { model.endInitialSelection(); return }
            // 1er lancement sans région mémorisée : recentre sur le marché résolu.
            if let region = model.takeInitialMapRegion(restoring: MapRegionStore.lastRegion()) {
                requestCamera(region: region)
            }
            // QA (DEBUG) : cadre ville pour visualiser les marqueurs amis individuels
            // (avatars, cônes de cap, présence) plutôt qu'un cluster continental.
            if AppEnvironment.usesDemoFriends {
                let region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 45.188, longitude: 5.724),
                    latitudinalMeters: 2200, longitudinalMeters: 2200
                )
                requestCamera(center: region.center, zoom: 14.5)
            }
            model.endInitialSelection()
            viewportGate.configure()
            scheduleCurrentViewport()
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
            openANFRFromRouterIfNeeded()
        }
        // Le calque pilote uniquement la CONSOMMATION des amis. La diffusion de
        // ma propre position « carte ouverte » est liée à l'écran via onAppear.
        .task(id: FriendsStreamTaskKey(
            enabled: filters.contains(.friend),
            session: services.map.sessionIdentifier,
            generation: friendsStreamGeneration
        )) {
            // La démo n'a pas de serveur à joindre : le flux ne s'ouvre pas et l'état reste neutre.
            guard filters.contains(.friend), services.auth.hasStoredCredentials(), !AppEnvironment.usesDemoData else {
                model.deactivateFriendsStream()
                selectedFriendFilterID = nil
                return
            }
            model.beginFriendsStream()
            for await friends in services.map.friendsStream(sse: services.sse) {
                model.applyLiveFriends(friends)
            }
            guard !Task.isCancelled else { return }
            model.friendsStreamDidEnd()

            // Refus définitif ou terminaison du SSE : ne pas figer le dernier état.
            // Un snapshot minimal reprend la main toutes les 30 s.
            while !Task.isCancelled, filters.contains(.friend) {
                do {
                    let friends = try await services.map.friendsSnapshot()
                    guard !Task.isCancelled else { return }
                    model.applyLiveFriends(friends, isFallback: true)
                } catch is CancellationError {
                    return
                } catch {
                    model.friendsFallbackDidFail(error)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // La fraîcheur progresse sans paquet réseau : estompage à 3 min et retrait
        // à 15 min restent vrais même pendant une panne du flux. Seulement quand le
        // calque des amis est affiché : sinon la carte se réveillait toutes les
        // 30 s pour rien (MES-31).
        .task(id: filters.contains(.friend)) {
            guard filters.contains(.friend) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                friendFreshnessNow = Date()
                refreshFriendsRender()
            }
        }
        .onDisappear {
            viewportGate.pause()
            services.livePresence.mapDidDisappear()
            fetchTask?.cancel()
            model.cancelPendingLoad()
            model.deactivateFriendsStream()
        }
        .onChangeCompat(of: filterSelection) { previous, current in
            filtersDidChange(from: previous, to: current)
        }
        .onChangeCompat(of: selectedFriendFilterID) { _, _ in
            refreshFriendsRender()
        }
        .onChangeCompat(of: coverageByGeneration) { _, _ in
            // Bascule Signal ↔ Génération : recolore la couche sans recharger le réseau.
            refreshMapRender()
        }
        // Données rechargées → reconstruit le cache des couches une seule fois.
        .onChangeCompat(of: model.dataVersion) { _, _ in refreshMapRender() }
        // L'autorisation accordée efface le message de refus et reprend un
        // recentrage resté en attente de la réponse.
        .onReceive(services.location.$authorizationStatus) { status in
            guard LocationFixPolicy.isAuthorized(status) else { return }
            locationIssue = nil
            if recentersWhenAuthorized {
                recentersWhenAuthorized = false
                centerOnCurrentLocation()
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .sqSpeedtestMapVisibilityChanged).receive(on: DispatchQueue.main)) { notification in
            guard let change = notification.object as? SpeedtestMapVisibilityChange,
                  change.session == services.speedtest.visibilitySession else { return }
            fetchTask?.cancel()
            model.applySpeedtestVisibility(serverID: change.serverID, isSharedOnMap: change.isSharedOnMap)
            if selectedItem?.kind == .speedtest, selectedItem?.backendId == change.serverID {
                selectedItem = nil
            }
            refreshMapRender()
            fetchTask = Task { await reloadCurrentRegion() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sqPrivacyZoneMapChanged).receive(on: DispatchQueue.main)) { _ in
            handlePrivacyZoneMapChange()
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            guard phase == .active, router.selectedTab == .map else { return }
            fetchTask?.cancel()
            fetchTask = Task { await reloadCurrentRegion() }
        }
        .onChangeCompat(of: networkPath.isOnline) { wasOnline, isOnline in
            guard !wasOnline, isOnline, scenePhase == .active, router.selectedTab == .map,
                  let viewport = viewportGate.admitted,
                  model.errorMessage != nil || !model.hasCurrentResponse else { return }
            fetchTask?.cancel()
            let requestedFilters = filters
            fetchTask = Task {
                await model.recoverAfterNetworkReturn(
                    wasOnline: wasOnline, isOnline: isOnline,
                    isVisible: scenePhase == .active && router.selectedTab == .map,
                    bounds: viewport.bounds, zoom: viewport.zoom, filters: requestedFilters
                )
            }
        }
        // Notification/deep link antenne : ouvre la fiche du site demandé.
        .onChangeCompat(of: router.openSiteId) { _, _ in openSiteFromRouterIfNeeded() }
        // Notification de mise à jour ANFR : l'écran ANFR, comme depuis la feuille Carte.
        .onChangeCompat(of: router.openANFRMap) { _, _ in openANFRFromRouterIfNeeded() }
        .onChangeCompat(of: searchFieldFocused) { _, focused in
            if focused { recentItems = RecentlyViewedStore.items() }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecentlyViewedStore.didChange)) { _ in
            recentItems = RecentlyViewedStore.items()
        }
        // ⌘F sur iPad : la recherche prend le clavier, carte déjà ouverte ou non.
        .onAppear { focusSearchIfRequested() }
        .onChangeCompat(of: router.focusMapSearch) { _, requested in
            if requested { focusSearchIfRequested() }
        }
        // Test de l'historique : cadre la carte sur le lieu de la mesure.
        .onChangeCompat(of: router.pendingMapFocus) { _, _ in focusFromRouterIfNeeded() }
        // Ligne de « Pannes signalées » : ouvre la feuille de la panne demandée.
        .onChangeCompat(of: router.openCommunityOutage) { _, _ in openCommunityOutageFromRouterIfNeeded() }
        // Tap sur une notification de panne : seul l'identifiant a voyagé.
        .onChangeCompat(of: router.openCommunityOutageId) { _, _ in openCommunityOutageFromNotificationIfNeeded() }
        // Alerte de partage de position : la fiche de l'ami.
        .onChangeCompat(of: router.pendingLiveFriendId) { _, _ in openLiveFriendFromRouterIfNeeded() }
        .onAppear {
            viewportRefreshID &+= 1
            if !zoneCompareTipDone { zoneCompareTipVisits += 1 }
            // L'onglet Carte peut ne pas être monté pendant une modification de zone.
            // Dans ce cas, aucun observer n'a reçu l'événement : vider puis recharger
            // au retour, même si l'emprise et le zoom n'ont pas changé.
            if seenPrivacyZoneMapRevision != SQPrivacyZoneMapChange.revision {
                handlePrivacyZoneMapChange()
            }
            services.livePresence.mapDidAppear()
            Task { await services.livePresence.refreshSharingSettings() }
            focusFromRouterIfNeeded()
            openCommunityOutageFromRouterIfNeeded()
            openCommunityOutageFromNotificationIfNeeded()
            openLiveFriendFromRouterIfNeeded()
        }
    }

    /// Ouvre la feuille d'une panne désignée depuis la page « Pannes signalées ».
    ///
    /// Elle vient de l'objet transporté par le routeur et non de `model.communityOutages` : cette
    /// page est paginée sans tenir compte de l'emprise, la panne demandée est donc en général
    /// absente de ce que la carte a chargé. Le cadrage est déjà fait par `pendingMapFocus`, posé
    /// dans le même geste.
    private func openCommunityOutageFromRouterIfNeeded() {
        guard let outage = router.openCommunityOutage else { return }
        router.openCommunityOutage = nil
        selectedCommunityOutage = outage
    }

    /// Ouvre la feuille d'une panne désignée par une NOTIFICATION.
    ///
    /// Un push ne transporte que des chaînes : on va donc chercher la fiche, que seule la route de
    /// détail rend en entier — et qui, elle, accepte aussi les pannes closes. C'est indispensable
    /// ici : « Rétabli sur… » notifie précisément une panne qu'aucune liste ne rend plus.
    ///
    /// Une fois l'objet en main, on repasse par le chemin de la page « Pannes signalées » : cadrage
    /// et ouverture de feuille restent décidés à un seul endroit. Un échec le dit par le bandeau
    /// de la carte : panne supprimée ou close, ou la vraie cause (hors ligne, session expirée).
    private func openCommunityOutageFromNotificationIfNeeded() {
        guard let outageId = router.openCommunityOutageId else { return }
        router.openCommunityOutageId = nil
        Task {
            do {
                let outage = try await services.communityOutages.detail(outageId: outageId)
                router.route(toCommunityOutage: outage)
            } catch {
                guard !error.isCancellation else { return }
                if case .http(404, _, _, _, _)? = error as? APIError {
                    model.showMarketNotice(String(localized: "Cette panne n’est plus disponible"))
                } else {
                    model.showMarketNotice(error.userFacingMessage)
                }
            }
        }
    }

    /// Ouvre la fiche de l'ami visé par une alerte de partage de position, cadrée sur lui.
    /// Les amis vivants arrivent après l'ouverture de la carte : brève attente, puis la carte
    /// reste telle quelle si l'ami n'y figure pas.
    private func openLiveFriendFromRouterIfNeeded() {
        guard let friendId = router.pendingLiveFriendId else { return }
        router.pendingLiveFriendId = nil
        Task {
            for _ in 0..<8 {
                if let friend = model.liveFriends.first(where: { $0.id == friendId }) {
                    selectedFriend = friend
                    if let location = friend.location {
                        requestCamera(center: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng), zoom: 15)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Cadre la carte sur la coordonnée demandée depuis un test de l'historique.
    /// Consommée une fois : l'onglet peut réapparaître sans re-cadrer.
    private func focusFromRouterIfNeeded() {
        guard let focus = router.pendingMapFocus else { return }
        router.pendingMapFocus = nil
        if let layer = router.pendingMapLayer {
            router.pendingMapLayer = nil
            if !filters.contains(layer) {
                filters.insert(layer)
                MapFilterStore.save(filters)
            }
        }
        let coordinate = CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude)
        requestCamera(center: coordinate, zoom: 15)
    }

    private var mapLayer: some View {
        // Moteur unique : rendu MapKit (Apple Plan natif).
        MapKitMapView(
            annotations: renderedAnnotations,
            coverageHeatFeatures: renderedCoverageFeatures,
            speedtestFeatures: renderedSpeedtestFeatures,
            renderVersion: renderVersion,
            viewportRefreshID: viewportRefreshID,
            colorScheme: colorScheme,
            // iPad : la mention légale d'Apple passe au-dessus de la rangée du bas
            // (pastille opérateur de 44 pt), qui la masquait en partie.
            ornamentBottomInset: horizontalSizeClass == .regular
                ? SQDock.floatingContentInset + 44 + SQSpace.xs
                : SQDock.clearance,
            center: $mapCenter,
            zoom: $mapZoom,
            onMoveEnd: { viewport, region in
                let changed = viewportGate.latest != viewport
                viewportGate.record(viewport)
                lastRegion = region
                model.recordViewportCenter(region.center)
                if changed { scheduleCurrentViewport() }
            },
            onSelect: selectAnnotation,
            onLongPress: { coordinate in openZoneCompare(at: coordinate) },
            zoneCompare: zoneCompareTarget.map {
                MapZoneCompareOverlay(
                    coordinate: $0.coordinate,
                    radiusMeters: zoneCompareRadiusMeters,
                    fitToken: zoneCompareFitToken,
                    // iPad : la feuille est centrée, elle ne cache pas le bas de la carte.
                    sheetCover: horizontalSizeClass == .regular ? .none : .half
                )
            },
            onZoneCompareMove: { coordinate in zoneCompareTarget?.coordinate = coordinate }
        )
        // La carte file sous la barre de statut / Dynamic Island (comme Plans),
        // au lieu de laisser une bande systemBackground non-crème en haut (UI-09).
        // Les contrôles du haut sont dans un overlay qui respecte la safe area.
        .ignoresSafeArea()
    }

    #if DEBUG
    /// Hook QA (DEBUG) : `SQ_QA_PAN_TO="lat,lng[,zoom]"` déplace la caméra
    /// après stabilisation, comme la fin d'un pan utilisateur — le delegate
    /// MapKit déclenche alors la chaîne réelle de chargement du pays choisi.
    private func runQAPanIfRequested() async {
        guard let raw = ProcessInfo.processInfo.environment["SQ_QA_PAN_TO"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return }
        try? await Task.sleep(for: .seconds(4))
        if parts.count >= 3 { mapZoom = parts[2] }
        mapCenter = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
    #endif

    private func region(forMarketCode code: String) -> MKCoordinateRegion {
        model.defaultMapRegion(forMarketCode: code)
    }

    private var controlsLayer: some View {
        GeometryReader { proxy in
            ZStack {
                // La pile se dimensionne selon les contrôles : aucun décalage
                // fixe ne peut faire chevaucher une grande police et l'opérateur.
                mapBottomControls
                    .padding(.leading, sidePanelInset(in: proxy.size.width))

                // Pendant la recherche, la carte s'estompe derrière les résultats ;
                // la toucher referme la recherche.
                if searchIsActive {
                    SQColor.bg.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { dismissSearch() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                VStack(spacing: SQSpace.sm2) {
                    mapTopControlBar
                        .padding(.horizontal, SQSpace.md)
                    if filters.contains(.friend), services.auth.hasStoredCredentials() {
                        if showsFriendsStatusPanel {
                            friendsStatusPanel
                                .padding(.horizontal, SQSpace.md)
                                .transition(.move(edge: .top))
                        } else if showsFriendsEmptyPill {
                            friendsEmptyPill
                                .padding(.horizontal, SQSpace.md)
                                .transition(.opacity)
                        }
                    }
                    // Le mode de couverture et les limites restent dans la rangée basse.
                    // Panneau de recherche : visible dès qu'une requête est saisie
                    // (résultats, ou message « aucun résultat »/erreur).
                    // Retours à la ligne compris : le champ multiligne en accepte, et une
                    // requête faite d'un seul retour ouvrait le panneau sur « Aucun résultat ».
                    // Rien pendant le premier chargement : le spinner du champ suffit.
                    if !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !(model.searchResults.isEmpty && model.isSearching) {
                            searchSuggestions
                                .padding(.horizontal, SQSpace.md)
                        }
                    } else if searchFieldFocused, !recentSearchResults.isEmpty {
                        recentsPanel
                            .padding(.horizontal, SQSpace.md)
                    }
                }
                .padding(.top, SQSpace.sm)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // iPad : la recherche et les contrôles se rangent à droite du panneau.
                .padding(.leading, sidePanelInset(in: proxy.size.width))
            }
            .animation(SQMotion.resolve(SQMotion.standard, reduceMotion), value: searchIsActive)
        }
    }

    /// Champ en saisie, ou requête en cours : les résultats prennent le devant.
    private var searchIsActive: Bool {
        searchFieldFocused || !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveFriendFilterID: String? {
        guard let selectedFriendFilterID,
              model.liveFriends.contains(where: { $0.id == selectedFriendFilterID })
        else { return nil }
        return selectedFriendFilterID
    }

    private var effectiveFriendsConnectionState: MapExplorerViewModel.FriendsConnectionState {
        // La démo n'a pas de serveur : son état ne se périme pas.
        if !AppEnvironment.usesDemoData,
           model.friendsConnectionState == .live,
           let updatedAt = model.friendsLastUpdatedAt,
           friendFreshnessNow.timeIntervalSince(updatedAt) > 20 {
            return .connecting
        }
        return model.friendsConnectionState
    }

    /// Le panneau complet n'apparaît que s'il a quelque chose à montrer : des amis, ou un flux en
    /// panne qu'on peut relancer. Sans ami, un simple « Inactif · 0/0 » masquait le haut de la carte.
    private var showsFriendsStatusPanel: Bool {
        !model.liveFriends.isEmpty || effectiveFriendsConnectionState == .unavailable
    }

    /// Flux ouvert mais personne ne partage : une pastille discrète le dit, sans bande pleine largeur.
    private var showsFriendsEmptyPill: Bool {
        model.liveFriends.isEmpty
            && (effectiveFriendsConnectionState == .live || effectiveFriendsConnectionState == .fallback)
    }

    private var friendsEmptyPill: some View {
        Text("Aucun ami ne partage de position récente.")
            .font(SQType.caption)
            .foregroundStyle(SQColor.label)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs2)
            .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowSoft()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("map.friends.empty")
    }

    private var friendsConnectionPresentation: (label: String, icon: String, color: Color) {
        switch effectiveFriendsConnectionState {
        case .inactive:
            // Sans flux (démo), l'état reste neutre : le nom de la couche, sans « Inactif ».
            return (String(localized: "Amis"), "person.2", SQColor.labelTertiary)
        case .connecting:
            // « Reconnexion… » seulement après un flux qui a déjà répondu ; à l'ouverture, on se connecte.
            return model.friendsLastUpdatedAt == nil
                ? (String(localized: "Connexion…"), "arrow.triangle.2.circlepath", SQColor.warning)
                : (String(localized: "Reconnexion…"), "arrow.triangle.2.circlepath", SQColor.warning)
        case .live:
            return (String(localized: "En direct"), "dot.radiowaves.left.and.right", SQColor.success)
        case .fallback:
            return (String(localized: "Repli périodique"), "clock.arrow.circlepath", SQColor.warning)
        case .unavailable:
            return (String(localized: "Indisponible"), "exclamationmark.triangle.fill", SQColor.danger)
        }
    }

    private var friendsWithRecentLocation: [SocialFriendLive] {
        model.liveFriends.filter { friend in
            friend.location != nil && !friend.hasExpiredLocation(now: friendFreshnessNow)
        }
    }

    private var friendsStatusPanel: some View {
        let presentation = friendsConnectionPresentation
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                if effectiveFriendsConnectionState == .connecting {
                    SQSpinner()
                        .controlSize(.mini)
                        .tint(presentation.color)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(presentation.color)
                }
                Text(presentation.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map.friends.state")
                Spacer(minLength: SQSpace.sm)
                Text("\(friendsWithRecentLocation.count)/\(model.liveFriends.count) localisés")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map.friends.count")
                if effectiveFriendsConnectionState == .unavailable {
                    Button {
                        friendsStreamGeneration &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Réessayer le flux des amis")
                }
            }

            if model.liveFriends.isEmpty {
                Text(effectiveFriendsConnectionState == .connecting
                     ? String(localized: "Connexion à la carte des amis…")
                     : String(localized: "Aucun ami ne partage de position récente."))
                    .font(.caption)
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map.friends.empty")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SQSpace.sm) {
                        friendFilterButton(
                            title: String(localized: "Tous"),
                            isSelected: effectiveFriendFilterID == nil,
                            friend: nil
                        )
                        ForEach(model.liveFriends) { friend in
                            friendFilterButton(
                                title: friend.name ?? String(localized: "Ami"),
                                isSelected: effectiveFriendFilterID == friend.id,
                                friend: friend
                            )
                        }
                    }
                }
            }

            if effectiveFriendsConnectionState == .unavailable,
               let error = model.friendsConnectionError,
               !error.isEmpty {
                Text(error)
                    .font(SQFont.archivo(12, .regular))
                    .foregroundStyle(SQColor.dangerInk)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .sqShadowSoft()
        .animation(SQMotion.resolve(SQMotion.snappy, reduceMotion), value: effectiveFriendsConnectionState)
    }

    private func friendFilterButton(
        title: String,
        isSelected: Bool,
        friend: SocialFriendLive?
    ) -> some View {
        Button {
            selectedFriendFilterID = friend?.id
            if let friend,
               let location = friend.location,
               !friend.hasExpiredLocation(now: friendFreshnessNow) {
                mapCenter = CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng)
                mapZoom = max(mapZoom, 14)
            }
        } label: {
            HStack(spacing: SQSpace.xs + 1) {
                if let friend {
                    SQAvatar(url: friend.avatarUrl, name: friend.name ?? "Ami", size: 24)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .sqSingleLine()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.label)
            .padding(.horizontal, SQSpace.sm2)
            .frame(minHeight: 44)
            .background(isSelected ? SQColor.accentSoft : SQColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(friend == nil ? "Afficher tous les amis" : "Filtrer sur \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Dégagement bas des contrôles flottants de la carte pour la barre de navigation.
    /// Avec la barre NATIVE Liquid Glass (iOS 26+), la safe area est DÉJÀ décalée par
    /// la barre → un petit dégagement suffit. Avec le dock custom (avant iOS 26, ou QA
    /// `--qa-legacy-dock`), c'est une simple superposition qui ne décale PAS la safe
    /// area → il faut réserver toute sa hauteur (`SQDock.clearance`). Sans cette
    /// distinction, les 98 pt du dock custom s'ajoutaient PAR-DESSUS l'inset natif →
    /// grand vide entre les boutons et la barre.
    private var mapControlsBottomInset: CGFloat { SQDock.floatingContentInset }

    private static var forcesLegacyDock: Bool {
        #if DEBUG
        AppEnvironment.usesLegacyDock
        #else
        false
        #endif
    }

    /// Une seule rangée compacte ; les réglages et explications s'ouvrent au toucher.
    /// Les grandes tailles de texte se replient sans réduire les cibles tactiles.
    private var mapBottomControls: some View {
        VStack(spacing: SQSpace.sm) {
            Spacer()
            marketSwitchNotice
            if showsZoneCompareTip {
                zoneCompareTip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsCoverageKey { coverageFocusBanner }
            MapContextControls(limitMessages: showsDisplayLimit ? model.displayLimitMessages : [])
            mapStatusToast
            HStack(alignment: .bottom) {
                mapStatePill
                Spacer(minLength: SQSpace.sm)
                mapFabStack
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SQSpace.md)
        .padding(.bottom, mapControlsBottomInset)
        .animation(SQMotion.resolve(SQMotion.standard, reduceMotion), value: showsCoverageKey)
        .animation(SQMotion.resolve(SQMotion.standard, reduceMotion), value: showsDisplayLimit)
        .animation(SQMotion.resolve(SQMotion.standard, reduceMotion), value: showsZoneCompareTip)
    }

    /// Rien ne signale l'appui long sur la carte : une astuce, une seule fois, là où le
    /// comparatif des antennes répond (France et outre-mer), jamais dans les tests UI.
    private var showsZoneCompareTip: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQ_QA_ZONE_COMPARE_TIP"] == "1" { return !zoneCompareTipDone }
        #endif
        return !zoneCompareTipDone && zoneCompareTipVisits >= 2 && zoneCompareTarget == nil
            && !searchIsActive && !AppEnvironment.usesDemoData && !AppEnvironment.resetsMapOnLaunch
            && ANFRZoneMarket.apiCode(forMarket: model.marketFilter) != nil
    }

    private var zoneCompareTip: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "hand.tap")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.accentInk)
                .accessibilityHidden(true)
            Text("Appui long sur la carte : compare les opérateurs autour d’un point.")
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Haptics.light()
                openZoneCompare(at: mapCenter)
            } label: {
                Text("Essayer")
                    .font(SQType.chip)
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.zoneCompareTip.try")
            Button {
                zoneCompareTipDone = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Masquer l’astuce"))
            .accessibilityIdentifier("map.zoneCompareTip.close")
        }
        .padding(.leading, SQSpace.md)
        .padding(.vertical, SQSpace.xxs)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .sqShadowCard()
        .accessibilityElement(children: .contain)
    }

    private var showsCoverageKey: Bool {
        filters.contains(.coverage) && model.operatorFilter.uppercased() != "ALL"
    }

    private var showsDisplayLimit: Bool {
        model.errorMessage == nil && !model.displayLimitMessages.isEmpty
    }

    /// Notice transitoire dans la même pile : elle ne masque aucun contrôle.
    private var marketSwitchNotice: some View {
        VStack {
            if let notice = model.marketSwitchNotice {
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 8, height: 8)
                    Text(notice)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm2)
                .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                .sqShadowCard()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(SQMotion.resolve(SQMotion.standard, reduceMotion), value: model.marketSwitchNotice)
        .allowsHitTesting(false)
    }

    private var mapTopControlBar: some View {
        HStack(spacing: SQSpace.sm) {
            mapSearchField
            // Pendant la recherche, le champ prend toute la largeur ; sa croix
            // ramène à la carte.
            if !searchIsActive {
                filterButton
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    /// Barre de recherche flottante Halo : carte blanche de 46 pt à 13 pt de
    /// coins, ombre carte, filet carmin pendant la saisie.
    private var mapSearchField: some View {
        HStack(spacing: SQSpace.sm) {
            // Slot de tête à largeur fixe : loupe au repos, spinner pendant un
            // chargement de carte (remplace l'ancien ProgressView bas-centre qui
            // chevauchait le dock). Largeur figée → pas de saut de mise en page.
            ZStack {
                if model.isLoading || model.isSearching {
                    SQSpinner()
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
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                if !model.searchQuery.isEmpty {
                    Text("Recherche")
                        .font(.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("map.search.label")
                }
                TextField(
                    "Rechercher un lieu ou un site", text: $model.searchQuery,
                    prompt: Text("Rechercher un lieu ou un site").foregroundColor(SQColor.labelSecondary),
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .tint(SQColor.brandRed)
                    .focused($searchFieldFocused)
                    .lineLimit(1...2)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Rechercher une ville, une adresse ou un site")
                    .accessibilityIdentifier("map.search.input")
                    .onSubmit { Task { await model.search() } }
                    // Suggestions à la frappe (anti-rebond + annulation côté modèle).
                    .onChangeCompat(of: model.searchQuery) { _, newValue in
                        // Le champ est multiligne pour afficher deux lignes : la touche
                        // Retour y insère un saut au lieu de lancer la recherche.
                        if newValue.contains("\n") {
                            model.searchQuery = newValue.replacingOccurrences(of: "\n", with: "")
                            // « Rechercher » referme le clavier, comme ailleurs sur iOS :
                            // rien d'autre ne le fermait avant le choix d'un résultat,
                            // et il cachait la barre d'onglets.
                            searchFieldFocused = false
                            Task { await model.search() }
                            return
                        }
                        model.scheduleSearch()
                    }
            }
            if searchIsActive || sightOrigin != .device {
                Button {
                    let closesSearch = searchIsActive
                    model.searchQuery = ""
                    model.searchResults = []
                    clearSearchPin()
                    if closesSearch {
                        searchFieldFocused = false
                        dismissSearch()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(searchIsActive ? "Fermer la recherche" : "Effacer la recherche")
                .accessibilityIdentifier("map.search.clear")
            }
        }
        .padding(.leading, SQSpace.md2)
        .padding(.trailing, !searchIsActive && sightOrigin == .device ? SQSpace.md2 : 0)
        .frame(minHeight: 46)
        .frame(maxWidth: .infinity)
        // Toute la barre donne le focus au champ, pas seulement sa ligne de texte.
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { searchFieldFocused = true }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(searchFieldFocused ? SQColor.brandRed : .clear, lineWidth: 1.5)
        }
        .sqShadowCard()
    }

    private var filterButton: some View {
        Button {
            Haptics.light()
            filterSheetDetent = .large
            showFilterSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 46, height: 46)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .sqShadowCard()
                if activeFilterCount > 0 && !dynamicTypeSize.isAccessibilitySize {
                    SQCountBadge(count: activeFilterCount)
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text("Filtres"))
        .accessibilityValue(Text("Filtres actifs : \(activeFilterCount)"))
        .accessibilityIdentifier("map.filters")
        .disabled(model.registryMarkets.isEmpty)
    }

    /// Couches affichées, dans l'ordre de la feuille Carte.
    /// Sans compte, la couche Amis n'affiche rien : elle ne compte pas.
    private var shownLayers: [MapDisplayItem.Kind] {
        let signedIn = services.auth.hasStoredCredentials()
        return MapLayersSheet.layerOrder.filter { filters.contains($0) && ($0 != .friend || signedIn) }
    }

    /// Pastille d'état (bas-gauche) : l'opérateur et la couche principale, plus
    /// le nombre des autres. Elle ouvre la feuille Carte, où tout se règle.
    private var mapStatePill: some View {
        let layers = shownLayers
        let primary = layers.first.map { MapLayersSheet.layerTitle($0, communityOnly: model.isCommunityOnlyMarket) }
        let others = max(layers.count - 1, 0)
        let operatorText = model.operatorShortLabel(model.operatorFilter)
        return Button {
            Haptics.light()
            showLayersSheet = true
        } label: {
            HStack(spacing: SQSpace.xs2) {
                Circle()
                    .fill(model.operatorFilter.uppercased() == "ALL" ? SQColor.label : model.operatorAccent(model.operatorFilter))
                    .frame(width: 10, height: 10)
                Text(operatorText)
                    .font(SQFont.body(13, .heavy, relativeTo: .footnote))
                    .foregroundStyle(SQColor.label)
                    .accessibilityIdentifier("map.operator.label")
                Circle()
                    .fill(SQColor.labelTertiary)
                    .frame(width: 3, height: 3)
                    .accessibilityHidden(true)
                Text(primary ?? String(localized: "Aucune couche"))
                    .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(SQColor.label)
                    .accessibilityIdentifier("map.layers.primary")
                if others > 0 {
                    Text(verbatim: "+\(others)")
                        .font(SQFont.body(11, .semibold, relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.chipInk)
                        .accessibilityIdentifier("map.layers.more")
                        .padding(.horizontal, SQSpace.xs2)
                        .frame(minHeight: 20)
                        .background(SQColor.chip, in: Capsule())
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, SQSpace.md2)
            .frame(minHeight: 44)
            .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowCard()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Carte"))
        .accessibilityValue(Text(stateAccessibilityValue(operatorText: operatorText, layers: layers)))
        .accessibilityHint(Text("Choisir l’opérateur, les couches et le fond"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("map.operator")
    }

    private func stateAccessibilityValue(operatorText: String, layers: [MapDisplayItem.Kind]) -> String {
        let titles = layers.map { MapLayersSheet.layerTitle($0, communityOnly: model.isCommunityOnlyMarket) }
        let layersText = titles.isEmpty ? String(localized: "Aucune couche") : ListFormatter.localizedString(byJoining: titles)
        return "\(operatorText), \(layersText)"
    }

    /// Boutons flottants (bas-droite) : la feuille Carte, puis le recentrage GPS.
    /// La carte recharge seule à chaque déplacement : pas de bouton « rafraîchir ».
    private var mapFabStack: some View {
        VStack(spacing: SQSpace.sm2) {
            mapFab(icon: "square.3.layers.3d", label: "Couches") {
                showLayersSheet = true
            }
            .accessibilityIdentifier("map.layers")
            mapFab(icon: "location", tint: SQColor.brandRed, label: "Recentrer sur ma position") {
                centerOnCurrentLocation()
            }
        }
    }

    private func mapFab(icon: String, tint: Color = SQColor.label, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(tint)
                .sqSurface(SQColor.surface, in: Circle())
                .sqShadowCard()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
    }

    // MARK: Chrome « Crème & Terre cuite » (verre crème + ombres douces, zéro bordure)

    /// Fond commun des contrôles posés sur la carte : `surfaceGlass` (crème 92 %)
    /// sur blur système — la profondeur vient des ombres, jamais d'une bordure.
    /// Bandeau « couverture isolée » : sans lui, une carte presque vide passerait
    /// pour un bug alors que c'est un filtre volontaire — et rien ne dirait
    /// comment en sortir.
    @ViewBuilder
    private var coverageFocusBanner: some View {
        if let focus = model.coverageFocus {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Couverture de ce site seulement")
                        .font(SQFont.body(13, .semibold))
                    Text(focus.summary)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SQSpace.sm)
                Button {
                    Haptics.light()
                    clearCoverageFocus()
                } label: {
                    Text("Tout voir").font(SQFont.body(13, .semibold)).frame(minHeight: 44)
                }
                .buttonStyle(SQPressButtonStyle())
                .tint(SQColor.brandRed)
            }
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowCard()
            .padding(.horizontal, SQSpace.lg)
        }
    }

    @ViewBuilder
    private var mapStatusToast: some View {
        if let issue = locationIssue {
            VStack(spacing: SQSpace.xs) {
                mapToast(issue.message, icon: "location.slash", tint: SQColor.warning)
                Button(issue.actionTitle) {
                    switch issue {
                    case .denied:
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    case .unavailable:
                        centerOnCurrentLocation()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SQColor.brandRed)
                .foregroundStyle(SQColor.onAccent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("map.location.action")
            }
        } else if let error = model.errorMessage {
            VStack(spacing: SQSpace.xs) {
                mapToast(error, icon: "exclamationmark.triangle.fill", tint: SQColor.warning)
                Button("Réessayer") { fetchTask = Task { await reloadCurrentRegion() } }
                    .buttonStyle(.borderedProminent)
                    .tint(SQColor.brandRed)
                    .foregroundStyle(SQColor.onAccent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("map.status.retry")
            }
        } else if !model.displayLimitMessages.isEmpty {
            // Le contrôle « Vue partielle » porte cet état et son explication.
            EmptyView()
        } else if viewportGate.admitted == nil {
            mapToast(String(localized: "Préparation de la carte…"), icon: "map", tint: SQColor.labelSecondary)
        } else if filters.contains(.coverage), model.operatorFilter.uppercased() == "ALL" {
            mapToast(String(localized: "Choisis un opérateur pour afficher la couverture."), icon: "line.3.horizontal.decrease.circle", tint: SQColor.labelSecondary)
        } else if !model.isLoading && model.hasCurrentResponse && renderedAnnotations.isEmpty
                    && renderedCoverageFeatures.isEmpty && renderedSpeedtestFeatures.isEmpty {
            mapToast(String(localized: "Aucun résultat reçu pour cette vue et ces filtres."), icon: "map", tint: SQColor.labelSecondary)
        } else if !model.isLoading && !model.hasCurrentResponse {
            mapToast(String(localized: "Chargement interrompu. Déplace la carte pour réessayer."), icon: "arrow.clockwise", tint: SQColor.labelSecondary)
        }
    }

    private func mapToast(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: SQSpace.sm - 1) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("map.status.text")
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm2)
        .sqCardBackground(cornerRadius: SQRadius.md)
        // Bornée à 280 (repli 2 lignes pour les erreurs longues) et CENTRÉE dans la
        // colonne bas-centre (alignement centré par défaut du `.frame`) — plus
        // d'alignement `.leading` hérité de l'ancienne position bas-gauche.
        .frame(maxWidth: 340)
        .accessibilityElement(children: .combine)
    }

    private var filterSelection: MapFilterSelection { model.filterSelection(layers: filters) }

    private func applyFilterSelection(_ selection: MapFilterSelection) -> Bool {
        // Even an unchanged Apply confirms an explicit choice and invalidates
        // automatic resolution that might still be waiting from startup.
        guard let committed = model.applyFilterSelection(selection) else { return false }
        filters = committed.layers
        return true
    }

    private func filtersDidChange(from previous: MapFilterSelection, to current: MapFilterSelection) {
        if previous.layers != current.layers { MapFilterStore.save(current.layers) }
        if previous.plannedStatuses != current.plannedStatuses { MapPlannedStatusStore.save(current.plannedStatuses) }
        if previous.photosFriendsOnly != current.photosFriendsOnly { MapPhotosFriendsOnlyStore.save(current.photosFriendsOnly) }
        if previous.layers != current.layers || previous.azimuthStyle != current.azimuthStyle
            || previous.plannedStatuses != current.plannedStatuses {
            refreshMapRender()
        }
        guard !model.consumeInitialSelectionObservation(current), !model.initialSelectionInProgress else { return }
        if previous.market != current.market {
            Task { await model.alignWithMarket(code: current.market, resetOperator: false) }
            requestCamera(region: region(forMarketCode: current.market))
        } else if current.requiresNetworkReload(comparedTo: previous) {
            scheduleCurrentViewport()
        }
        if previous.market != current.market || previous.operatorName != current.operatorName {
            MapMarketStore.save(market: current.market, operator: current.operatorName)
        }
    }

    private var activeFilterCount: Int { filterSelection.activeRefinementCount }

    /// Écran ANFR demandé depuis la feuille Carte, ouvert une fois celle-ci fermée.
    private func openPendingANFR() {
        guard let destination = pendingANFR else { return }
        pendingANFR = nil
        switch destination {
        case .map: showsANFRMap = true
        case .stats: showsANFRStats = true
        case .zoneCompare:
            if let center = model.viewportCenter { openZoneCompare(at: center) }
        }
    }

    /// Ouvre la comparaison sur ce point ; déjà ouverte, elle y déplace son épingle.
    private func openZoneCompare(at coordinate: CLLocationCoordinate2D) {
        zoneCompareTipDone = true
        if zoneCompareTarget != nil {
            zoneCompareTarget?.coordinate = coordinate
        } else {
            zoneCompareRadiusMeters = Double(ANFRZoneRadius.default.kilometers) * 1000
            zoneCompareTarget = ZoneCompareTarget(coordinate: coordinate)
        }
    }

    private func openANFRFromRouterIfNeeded() {
        guard router.openANFRMap else { return }
        router.openANFRMap = false
        showsANFRMap = true
    }

    private func centerOnCurrentLocation() {
        locationIssue = nil
        Task {
            if let location = await services.location.currentLocation(timeoutSeconds: 8) {
                let coordinate = location.coordinate
                requestCamera(center: coordinate, zoom: 15)
            } else {
                // Distinguer le refus d'autorisation (l'utilisateur peut agir) d'une
                // simple indisponibilité, au lieu d'un message générique opaque (UXP-08).
                // État propre à la position : ne passe pas par `model.errorMessage`,
                // dont l'action recharge la carte.
                let status = services.location.authorizationStatus
                if status == .notDetermined {
                    recentersWhenAuthorized = true
                    return
                }
                let issue: MapLocationIssue = (status == .denied || status == .restricted) ? .denied : .unavailable
                locationIssue = issue
                // Un message qui s'efface seul : la carte reste lisible si l'on n'agit pas.
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if locationIssue == issue { locationIssue = nil }
            }
        }
    }

    /// Résultats dans une seule carte : les sites, puis les lieux.
    private var searchSuggestions: some View {
        let sites = model.searchResults.filter { if case .antenna = $0 { return true } else { return false } }
        let places = model.searchResults.filter { if case .place = $0 { return true } else { return false } }
        return searchCard {
            if model.searchResults.isEmpty {
                searchStatusRow
            } else {
                if !sites.isEmpty {
                    searchSection("Sites", count: sites.count, results: sites) { selectSearchResult($0) }
                }
                if !sites.isEmpty, !places.isEmpty {
                    Divider().overlay(SQColor.separator).padding(.vertical, SQSpace.xs)
                }
                if !places.isEmpty {
                    searchSection("Lieux", count: nil, results: places) { selectSearchResult($0) }
                }
            }
        }
    }

    /// Carte blanche à la taille du contenu ; elle défile seulement quand
    /// la liste dépasse la place laissée par le clavier.
    private func searchCard<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        let body = VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
        // Le fond se pose dans chaque variante : `ViewThatFits` prend la
        // hauteur proposée, la carte doit épouser ses lignes.
        return ViewThatFits(in: .vertical) {
            body.modifier(SearchCardBackground())
            ScrollView { body }.frame(maxHeight: 420).modifier(SearchCardBackground())
        }
        .frame(maxHeight: 420, alignment: .top)
    }

    private struct SearchCardBackground: ViewModifier {
        func body(content: Content) -> some View {
            content
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .sqShadowCard()
        }
    }

    @ViewBuilder
    private func searchSection(_ title: LocalizedStringKey, count: Int?, results: [MapSearchResult],
                               action: @escaping (MapSearchResult) -> Void) -> some View {
        HStack {
            Text(title).sqKicker().accessibilityAddTraits(.isHeader)
            Spacer()
            if let count {
                Text("\(count)").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, SQSpace.sm)
        .padding(.bottom, SQSpace.xxs)
        ForEach(results) { result in
            Button { action(result) } label: { searchResultRow(result) }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel(searchResultAccessibilityLabel(result))
                .accessibilityIdentifier(searchResultIdentifier(result))
        }
    }

    /// Sites et lieux consultés récemment. Les sites du pays affiché
    /// seulement : leur fiche se charge dans ce pays.
    private var recentSearchResults: [MapSearchResult] {
        recentItems.compactMap { item in
            switch item.kind {
            case .place:
                return item.placeResult.map(MapSearchResult.place)
            case .site:
                guard item.market?.caseInsensitiveCompare(model.marketFilter) == .orderedSame else { return nil }
                return item.antennaSite.map(MapSearchResult.antenna)
            case .profile:
                return nil
            }
        }
    }

    private var recentsPanel: some View {
        searchCard {
            HStack(spacing: SQSpace.sm) {
                Text("Récents").sqKicker().accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Haptics.light()
                    RecentlyViewedStore.clear([.site, .place])
                } label: {
                    Text("Effacer")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.ink2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Effacer les récents")
                .accessibilityIdentifier("map.recents.clear")
            }
            ForEach(recentSearchResults) { result in
                Button { openRecent(result) } label: { searchResultRow(result) }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityLabel(searchResultAccessibilityLabel(result))
                    .accessibilityIdentifier("map.recent.\(result.id)")
            }
        }
    }

    private func focusSearchIfRequested() {
        guard router.focusMapSearch else { return }
        router.focusMapSearch = false
        searchFieldFocused = true
    }

    /// La fiche complète si le site est déjà chargé ; sinon celle rebâtie
    /// depuis l'historique, dont le détail se recharge à l'ouverture.
    private func openRecent(_ result: MapSearchResult) {
        if case .antenna(let stored) = result,
           let loaded = model.antennas.first(where: { $0.id == stored.id }) {
            selectSearchResult(.antenna(loaded))
        } else {
            selectSearchResult(result)
        }
    }

    /// État « aucun résultat » / « recherche indisponible » (rien pendant la
    /// recherche : le spinner du champ suffit). Distingue vide d'erreur.
    @ViewBuilder
    private var searchStatusRow: some View {
        if !model.isSearching {
            VStack(spacing: SQSpace.xs) {
                Image(systemName: model.searchFailed ? "exclamationmark.triangle" : "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SQColor.ink2)
                    .frame(width: 46, height: 46)
                    .background(SQColor.chip, in: Circle())
                    .accessibilityHidden(true)
                Text(model.searchFailed ? "Recherche indisponible" : "Aucun résultat")
                    .font(SQType.stateTitle)
                    .foregroundStyle(SQColor.label)
                Text(model.searchFailed
                     ? "Vérifie ta connexion, puis réessaie."
                     : "Cherche un numéro de support ANFR, une adresse ou une commune.")
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func searchResultIdentifier(_ result: MapSearchResult) -> String {
        switch result {
        case .place(let place): return "map.search.result.place.\(place.id)"
        case .antenna(let site): return "map.search.result.antenna.\(site.id)"
        }
    }

    private func searchResultRow(_ result: MapSearchResult) -> some View {
        HStack(spacing: SQSpace.sm2) {
            Image(systemName: {
                if case .antenna = result { return "antenna.radiowaves.left.and.right" }
                return "mappin.and.ellipse"
            }())
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(SQColor.ink2)
                .frame(width: 38, height: 38)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                switch result {
                case .antenna(let site):
                    // L'adresse d'abord, le numéro ensuite : « 37199 40 av leclerc
                    // 69007 » accolait les deux sur une ligne (UI-10).
                    Text(site.address ?? String(localized: "Site \(site.siteId ?? site.id)"))
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                    antennaSearchDetails(site)
                case .place(let place):
                    Text(place.name)
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                    if let subtitle = place.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: SQSpace.xs)
            if let distance = searchDistance(result) {
                Text(distance)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, SQSpace.sm)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// N° de support, couleurs des opérateurs et technologies : on reconnaît
    /// le bon site avant de l'ouvrir.
    private func antennaSearchDetails(_ site: AntennaSite) -> some View {
        var seen = Set<String>()
        let operators = site.operators.filter { seen.insert($0.uppercased()).inserted }
        let technologies = Array(Set(site.technologies.map { $0.uppercased() })).sorted(by: >).prefix(3)
        return HStack(spacing: 6) {
            if let number = site.siteId, !number.isEmpty, site.address != nil {
                Text(number)
                    .font(SQType.caption(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if !operators.isEmpty {
                HStack(spacing: 3) {
                    ForEach(operators.prefix(4), id: \.self) { key in
                        Circle().fill(model.operatorAccent(key)).frame(width: 8, height: 8)
                    }
                }
            }
            ForEach(Array(technologies), id: \.self) { tech in
                MapTechTag(technology: tech, label: tech)
            }
        }
        .lineLimit(1)
    }

    /// Distance depuis la dernière position connue, si elle est récente.
    private func searchDistance(_ result: MapSearchResult) -> String? {
        guard let here = services.location.cachedLocation() else { return nil }
        let target: CLLocation
        switch result {
        case .antenna(let site):
            guard site.hasValidCoordinate, let lat = site.latitude, let lng = site.longitude else { return nil }
            target = CLLocation(latitude: lat, longitude: lng)
        case .place(let place):
            target = CLLocation(latitude: place.latitude, longitude: place.longitude)
        }
        return SQUnits.distance(meters: here.distance(from: target))
    }

    private func searchResultAccessibilityLabel(_ result: MapSearchResult) -> String {
        var parts: [String]
        switch result {
        case .antenna(let site):
            parts = [site.address ?? String(localized: "Site \(site.siteId ?? site.id)"), antennaSearchSubtitle(site)]
            parts.append(contentsOf: Array(Set(site.technologies.map { $0.uppercased() })).sorted(by: >))
        case .place(let place):
            parts = [place.name, place.subtitle ?? ""]
        }
        if let distance = searchDistance(result) { parts.append(distance) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Opérateurs du marché affiché, dans la couleur exacte de leurs marqueurs.
    private var antennaLegendOperators: [MapAntennaLegendOperator] {
        (model.currentMarketEntry?.operators ?? [])
            .filter { $0.key.uppercased() != "ALL" }
            .map { MapAntennaLegendOperator(key: $0.key, label: $0.label, color: model.operatorAccent($0.key)) }
    }

    /// « Orange · Free · site n° 37199 ». Le numéro n'apparaît que s'il vient du
    /// registre (pas un identifiant interne) et que l'adresse fait déjà le titre.
    private func antennaSearchSubtitle(_ site: AntennaSite) -> String {
        var seen = Set<String>()
        var parts = site.operators
            .filter { seen.insert($0.uppercased()).inserted }
            .map(searchOperatorLabel)
        if site.address != nil, let number = site.siteId, !number.isEmpty {
            parts.append(String(localized: "site n° \(number)"))
        }
        return parts.joined(separator: " · ")
    }

    /// La recherche couvre tous les pays : une clé d'un autre marché
    /// (« ORANGE_LU ») se nomme dans le registre de son pays, désigné par son
    /// suffixe.
    private func searchOperatorLabel(_ key: String) -> String {
        let label = model.operatorLabel(key)
        guard label == key, let suffix = key.split(separator: "_").last, suffix.count == 2,
              let entry = model.registryMarket(forCode: String(suffix)) else { return label }
        return MarketRegistryEntry.operatorLabel(key, in: entry)
    }

    private func selectSearchResult(_ result: MapSearchResult) {
        dismissSearch()
        switch result {
        case .place(let place):
            setSearchPin(place)
            mapCenter = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            mapZoom = 14
            RecentlyViewedStore.record(.place(place))
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

    private var sightOrigin: AntennaSightOrigin {
        AntennaSightOrigin.resolve(
            query: model.searchQuery,
            latitudeText: searchPinLatitude,
            longitudeText: searchPinLongitude,
            title: searchPinTitle
        )
    }

    private var searchPinPayload: MapAnnotationPayload? {
        MapAnnotationPayload.searchPin(
            latitudeText: searchPinLatitude,
            longitudeText: searchPinLongitude,
            title: searchPinTitle,
            subtitle: searchPinSubtitle
        )
    }

    private func setSearchPin(_ place: PlaceResult) {
        searchPinLatitude = String(place.latitude)
        searchPinLongitude = String(place.longitude)
        searchPinTitle = place.name
        searchPinSubtitle = place.subtitle ?? ""
        refreshMapRender()
    }

    private func clearSearchPin() {
        guard !searchPinLatitude.isEmpty || !searchPinLongitude.isEmpty || !searchPinTitle.isEmpty else { return }
        searchPinLatitude = ""
        searchPinLongitude = ""
        searchPinTitle = ""
        searchPinSubtitle = ""
        refreshMapRender()
    }

    /// Reconstruit le cache des couches lourdes. Appelé uniquement sur changement
    /// de données (`model.dataVersion`), de couches actives (`filters`) ou de zoom
    /// — jamais à chaque rendu de `body`.
    /// Palier de zoom affectant le RENDU des annotations (clustering + lobes).
    /// Frontières : 11, 12,5, 13, 13,5, 14 — exactement les seuils utilisés par
    /// `clusteredPayloads`/`clusteredPhotoPayloads` (taille de cellule, `shouldCluster`)
    /// et `showsAzimuths` (lobes ≥ z14) — plus 15 et 16, où la longueur des lobes
    /// change (`azimuthReach`). Entre deux frontières, `annotationPayloads` est
    /// identique pour des données constantes → reconstruction inutile.
    private static func zoomRenderBucket(for zoom: Double) -> Int {
        switch zoom {
        case ..<11:    return 0
        case ..<12.5:  return 1
        case ..<13:    return 2
        case ..<13.5:  return 3
        case ..<14:    return 4
        case ..<15:    return 5
        case ..<16:    return 6
        default:       return 7
        }
    }

    /// Longueur des lobes d'azimut en points d'écran, selon le zoom.
    ///
    /// Elle CROÎT avec le zoom, ce qui paraît contre-intuitif mais correspond à ce
    /// qu'on voit : plus on zoome, plus deux sites voisins s'écartent à l'écran, et
    /// plus il y a de place pour déployer leurs secteurs. C'est à z14, en centre
    /// dense, que des lobes longs se recouvriraient au point de ne plus être
    /// attribuables à un pylône.
    // Définie dans `SQMapProjection` depuis que CarPlay dessine aussi des lobes :
    // les deux surfaces doivent les dimensionner pareil.
    static func azimuthReach(for zoom: Double) -> CGFloat {
        SQMapProjection.azimuthReach(forZoom: zoom)
    }

    private func refreshMapRender() {
        renderedAnnotations = annotationPayloads
        renderedCoverageFeatures = coverageHeatFeatures
        renderedSpeedtestFeatures = speedtestFeatures
        renderVersion &+= 1
        MapDiagnosticsLog.logger.debug(
            "render version=\(self.model.dataVersion) annotations=\(self.renderedAnnotations.count) coverage=\(self.renderedCoverageFeatures.count) speedtests=\(self.renderedSpeedtestFeatures.count) zoomBucket=\(Self.zoomRenderBucket(for: self.mapZoom))"
        )
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
        // Un favori d'un autre pays se cherche dans son marché, pas dans celui affiché.
        let market = router.openSiteMarket ?? model.marketFilter
        router.openSiteMarket = nil
        let isShownMarket = market.caseInsensitiveCompare(model.marketFilter) == .orderedSame
        if isShownMarket,
           let site = model.antennas.first(where: { $0.id == siteId || $0.siteId == siteId }) {
            selectedAntenna = site
            return
        }
        Task {
            let results: [AntennaSite]
            do {
                results = try await services.antennas.quickSearch(
                    query: siteId,
                    market: market,
                    department: isShownMarket ? model.currentDromRegion?.department : nil
                )
            } catch {
                // Hors ligne, « Site introuvable » accusait le lien : on dit la vraie cause.
                if !error.isCancellation { model.showMarketNotice(error.userFacingMessage) }
                return
            }
            // Correspondance exacte seulement : `results.first` ouvrait un site au
            // texte voisin, c'est-à-dire la fiche d'une autre antenne (AF-CARTE-07).
            guard let site = results.first(where: { $0.id == siteId || $0.siteId == siteId }) else {
                model.showMarketNotice(String(localized: "Site introuvable"))
                return
            }
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
                    title: String(localized: "\(cluster.count) antennes"),
                    subtitle: String(localized: "Zoomer pour les détails"),
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
            // Badges de panne : uniquement quand le filtre « Pannes » est ÉTEINT.
            // Allumé, la panne a son propre marqueur, et la doubler d'un badge
            // ferait compter deux fois le même incident. Les DEUX sources sont
            // traitées pareil — l'opérateur comme la communauté —, avec des formes
            // distinctes : une antenne déclarée hors service par son opérateur ne
            // doit pas être la seule à ne porter aucune marque.
            let showsBadges = !filters.contains(.outage)
            let outageMarks: [String: CommunityOutageMark] =
                showsBadges ? communityOutageMarksBySite : [:]
            let incidentMarks: [String: OperatorIncidentMark] =
                showsBadges ? operatorIncidentMarksByAntenna : [:]
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
                    title: String(localized: "Site \(site.siteId ?? site.id)"),
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
                    showsAzimuths: mapZoom >= 13,
                    // Filtré sur un opérateur, un site partagé (ZB, Crozon) prend sa
                    // couleur : son premier opérateur peut être l'autre partenaire.
                    tint: model.operatorAccent(
                        model.operatorFilter.uppercased() == "ALL"
                            ? (site.operators.first ?? model.operatorFilter)
                            : model.operatorFilter
                    ),
                    contributionPhotos: site.photoCount,
                    hasEnb: site.hasEnb,
                    hasGnb: site.hasGnb,
                    has5G: site.has5G,
                    azimuthReachPoints: Self.azimuthReach(for: mapZoom),
                    operatorTints: operatorTints(for: site),
                    azimuthStyle: model.azimuthStyle,
                    fiveGTintIndices: fiveGTintIndices(for: site),
                    azimuthBeams: azimuthBeams(for: site),
                    communityOutage: outageMarks[site.siteId ?? site.id],
                    operatorIncident: incidentMarks[site.id]
                )
            }
            payloads += clusteredPayloads(from: antennaPayloads, kind: .antenna, idPrefix: "antenna", minCount: 160, label: { String(localized: "\($0) antennes") })
        }
        payloads += communitySitePayloads
        payloads += customSitePayloads
        payloads += photoPayloads
        payloads += plannedPayloads
        payloads += outagePayloads
        payloads += communityOutagePayloads
        if let searchPinPayload { payloads.append(searchPinPayload) }
        return payloads
    }

    /// Pannes en cours indexées par identifiant de site, pour accrocher le badge au
    /// bon point d'antenne.
    ///
    /// La clé est `targetId` — l'identifiant du site — et non une proximité
    /// géographique : une panne est déclarée SUR un site, et un rapprochement par
    /// distance poserait le badge sur le pylône voisin dès qu'ils sont serrés.
    /// C'est bien la même clé des deux côtés : `OutageReportSheet` envoie
    /// `site.siteId ?? site.id` comme `targetId`.
    private var communityOutageMarksBySite: [String: CommunityOutageMark] {
        var marks: [String: CommunityOutageMark] = [:]
        for outage in model.communityOutages where outage.state.isVisible && !outage.targetId.isEmpty {
            let mark = CommunityOutageMark(severity: outage.severity, confirmed: outage.state == .confirmed)
            // Un site peut porter deux pannes (deux opérateurs). Le badge unique
            // affiche alors la plus grave, puis la mieux établie — sinon il
            // dépendrait de l'ordre de la réponse serveur.
            if let current = marks[outage.targetId], !Self.outranks(mark, current) { continue }
            marks[outage.targetId] = mark
        }
        return marks
    }

    private static func outranks(_ candidate: CommunityOutageMark, _ current: CommunityOutageMark) -> Bool {
        if candidate.severity != current.severity { return candidate.severity == .down }
        return candidate.confirmed && !current.confirmed
    }

    /// Rayon en deçà duquel un incident opérateur et un point d'antenne désignent le même pylône.
    ///
    /// La même valeur que `INCIDENT_SITE_MATCH_RADIUS_METERS` côté serveur, et pour la même
    /// raison : `code_site_op` est le code INTERNE de l'opérateur, pas le `sup_id` de l'ANFR, si
    /// bien que l'égalité de clé ne se déclenche quasiment jamais et que c'est la distance qui
    /// tranche. Elle se trompe parfois sur un toit urbain — c'est pourquoi le badge se contente
    /// d'ALERTER, et que la fiche antenne, elle, dit explicitement quand le rattachement s'est
    /// fait par proximité.
    private static let operatorIncidentMatchRadiusMeters: Double = 120

    /// Incidents opérateurs rapprochés du point d'antenne qu'ils désignent, indexés par
    /// identifiant d'antenne.
    ///
    /// Rapprochement GÉOGRAPHIQUE, contrairement au signalement communautaire qui, lui, porte
    /// l'identifiant du site sur lequel il a été déposé. Ce n'est pas une préférence : les deux
    /// référentiels n'ont aucune clé commune, et joindre sur `siteId` ne rapprocherait rien.
    ///
    /// ⚠️ Ce croisement est un PRODUIT de deux listes, et aucune des deux n'est petite :
    /// `/api/android/map/incidents` ne prend PAS d'emprise — il rend le pays entier, mesuré à
    /// 1 335 lignes pour `market=FR&operator=ALL` — quand `model.antennas` compte les milliers
    /// d'antennes du viewport. D'où le pré-filtre en boîte, en DEGRÉS, avant toute trigonométrie :
    /// c'est exactement ce que fait `selectOperatorIncidentsForSite` côté serveur, et pour la même
    /// raison. Sans lui, il resterait plusieurs millions de distances haversine à calculer sur le
    /// MainActor, à chaque reconstruction du cache d'annotations.
    ///
    /// Ce calcul ne tourne qu'à cette reconstruction (`refreshMapRender`), pas à chaque rendu.
    private var operatorIncidentMarksByAntenna: [String: OperatorIncidentMark] {
        guard !model.outages.isEmpty, !model.antennas.isEmpty else { return [:] }
        let radius = Self.operatorIncidentMatchRadiusMeters
        // Dépliés une fois : re-déballer `lat`/`lon` et re-normaliser `issueType` au cœur de la
        // boucle interne coûterait autant que la distance elle-même.
        let incidents: [(lat: Double, lon: Double, issueType: String)] = model.outages.compactMap {
            guard let lat = $0.lat, let lon = $0.lon else { return nil }
            return (lat, lon, ($0.issueType ?? "down").lowercased())
        }
        guard !incidents.isEmpty else { return [:] }
        // 120 m en degrés de latitude. La longitude se resserre vers les pôles : la borne est
        // recalculée par antenne, à sa propre latitude.
        let latDelta = radius / 111_320
        var marks: [String: OperatorIncidentMark] = [:]
        for site in model.antennas {
            guard let lat = site.latitude, let lng = site.longitude else { continue }
            let lonDelta = latDelta / max(cos(lat * .pi / 180), 0.01)
            var best: (distance: Double, issueType: String)?
            for incident in incidents {
                // Comparaisons de flottants d'abord : elles écartent la quasi-totalité du pays
                // avant qu'on paie une seule racine carrée.
                guard abs(incident.lat - lat) <= latDelta, abs(incident.lon - lng) <= lonDelta else { continue }
                let distance = CLLocation(latitude: lat, longitude: lng)
                    .distance(from: CLLocation(latitude: incident.lat, longitude: incident.lon))
                guard distance <= radius else { continue }
                // Le plus proche gagne : en zone dense, plusieurs supports tombent dans le rayon,
                // et c'est celui-là que le badge doit désigner. Même arbitrage que le serveur.
                if let current = best, current.distance <= distance { continue }
                best = (distance, incident.issueType)
            }
            if let best { marks[site.id] = OperatorIncidentMark(issueType: best.issueType) }
        }
        return marks
    }

    /// Pannes signalées, en marqueur de plein droit : le filtre « Pannes » est
    /// allumé, c'est elles qu'on est venu voir. Même taille que les incidents
    /// opérateurs, posées À CÔTÉ du point d'antenne (cf. `communityOutageOffset`).
    ///
    /// `antennaId` reste nil, délibérément : `selectAnnotation` route sur lui en
    /// premier, et le renseigner ferait ouvrir la fiche antenne depuis un marqueur
    /// de panne — une cible, deux destinations.
    private var communityOutagePayloads: [MapAnnotationPayload] {
        guard filters.contains(.outage) else { return [] }
        let individual = model.communityOutages.compactMap { outage -> MapAnnotationPayload? in
            guard outage.state.isVisible else { return nil }
            // Le serveur résout la position depuis son référentiel ; une panne dont
            // il n'a pas su la placer arriverait en (0, 0), au large du Ghana.
            guard outage.latitude != 0 || outage.longitude != 0 else { return nil }
            return MapAnnotationPayload(
                id: "community-outage-\(outage.id)",
                kind: .communityOutage,
                title: [outage.siteName, outage.targetId]
                    .compactMap { $0 }
                    .first { !$0.isEmpty } ?? String(localized: "Panne signalée"),
                subtitle: Self.communityOutageSubtitle(
                    operatorLabel: model.operatorLabel(outage.operatorKey),
                    outage: outage
                ),
                coordinate: CLLocationCoordinate2D(latitude: outage.latitude, longitude: outage.longitude),
                metric: outage.severity == .degraded
                    ? String(localized: "Service dégradé")
                    : String(localized: "Plus aucun service"),
                backendId: outage.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                communityOutage: CommunityOutageMark(
                    severity: outage.severity,
                    confirmed: outage.state == .confirmed
                )
            )
        }
        return clusteredPayloads(
            from: individual,
            kind: .communityOutage,
            idPrefix: "community-outage",
            minCount: 30,
            label: { String(localized: "\($0) pannes signalées") }
        )
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
                title: site.codeSite ?? String(localized: "Site prévisionnel"),
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
        return clusteredPayloads(from: individual, kind: .planned, idPrefix: "planned", minCount: 40, label: { String(localized: "\($0) prévisionnels") })
    }

    /// Sites en panne déclarés par les OPÉRATEURS : pastille à la couleur de la gravité
    /// (`OperatorIncidentCard.tint` — rouge pour une coupure, ambre pour un dégradé comme pour
    /// une maintenance) et glyphe de la source (`OperatorIncidentCard.glyph`).
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
                    note: [site.reason, OutageFeedDate.display(site.estimatedEnd).map { String(localized: "Rétablissement prévu : \($0)") }].compactMap { $0 }.joined(separator: "\n")
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: Self.outageColor(for: kindKey),
                glyphOverride: Self.outageGlyph(for: kindKey)
            )
        }
        return clusteredPayloads(from: individual, kind: .outage, idPrefix: "outage", minCount: 30, label: { String(localized: "\($0) sites HS") })
    }

    /// La gravité d'un incident opérateur, résolue à UN seul endroit.
    ///
    /// Cette fonction avait sa propre échelle (orange #F97316, jaune #EAB308, rouge #EF4444), si
    /// bien qu'un même incident changeait de couleur selon que le filtre « Pannes » était allumé —
    /// marqueur peint ici — ou éteint — badge peint par `OperatorIncidentCard.tint`. Le jaune du
    /// mode allumé était en prime celui que les essais sur appareil ont déclaré illisible
    /// (1,80:1 sur la crème), remplacé partout ailleurs par l'ambre profond `OutageTint.degraded`.
    ///
    /// La forme, elle, reste distincte (cf. `outageGlyph`) : c'est elle qui dit QUI affirme, la
    /// couleur ne répondant qu'à « à quel point ? ».
    static func outageColor(for issueType: String) -> Color {
        OperatorIncidentCard.tint(for: issueType)
    }

    /// Le glyphe d'un incident opérateur, résolu au même endroit que celui de sa carte.
    ///
    /// Il rendait `exclamationmark.circle.fill` pour un `degraded` — c'est-à-dire EXACTEMENT le
    /// glyphe du signalement communautaire (`SQMapKitMarkerView.glyphName`, cas
    /// `.communityOutage`). Tant que les deux couches avaient des échelles de couleur séparées, le
    /// jaune contre l'ambre les distinguait encore ; depuis que la couleur est unifiée sur
    /// `OperatorIncidentCard.tint`, un incident opérateur « dégradé » et une panne communautaire
    /// « dégradée » confirmée devenaient deux disques ambre au glyphe identique. Or c'est
    /// précisément la forme qui doit dire QUI affirme, et le flux SFR de production comptait
    /// 107 incidents `degraded` au moment de la correction — pas un cas d'école.
    ///
    /// Délégué à `OperatorIncidentCard.glyph`, comme la couleur juste au-dessus : le triangle (ou
    /// la clé à molette d'une maintenance) reste à l'opérateur, le point d'exclamation cerclé à la
    /// communauté, sur la carte comme dans la fiche antenne.
    static func outageGlyph(for issueType: String) -> String {
        OperatorIncidentCard.glyph(for: issueType)
    }

    /// « Orange · Internet, Voix · 4G, 5G » — le sous-titre du marqueur d'une panne signalée.
    ///
    /// Les GÉNÉRATIONS y étaient absentes : le marqueur, sa bulle et l'annonce VoiceOver
    /// (`SQAnnotationDescription`, qui lit ce même `subtitle`) n'énonçaient que les services,
    /// alors que le formulaire les demande et que la fiche antenne, la feuille et la carte de fil
    /// les écrivent. La carte est pourtant le premier écran où l'on croise une panne.
    ///
    /// `affectedLabel` et non une composition locale : c'est lui qui pose le point médian entre
    /// services et générations, et qui n'écrit rien quand aucune technologie n'est déclarée — une
    /// panne d'avant le champ ne doit pas gagner un séparateur orphelin.
    ///
    /// Statique, comme `outageGlyph` juste au-dessus, parce qu'un test le tient : c'est la seule
    /// façon de vérifier ce que le marqueur dit vraiment sans monter la carte entière.
    static func communityOutageSubtitle(operatorLabel: String, outage: CommunityOutage) -> String {
        [operatorLabel, outage.affectedLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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

    /// Le statut en version ENCRE : les hex ci-dessus sont calibrés pour une pastille portant un
    /// glyphe blanc, pas pour écrire. Posé en texte, l'ambre tombe à ~2:1 et aucun de ces hex ne
    /// s'adapte au mode sombre. Le hex reste pour les pastilles et les fonds teintés.
    static func plannedStatusInk(_ status: PlannedActivationStatus) -> Color {
        switch status {
        case .active: return OutageTint.resolvedInk
        case .upgradePending: return OutageTint.degradedInk
        case .declared: return dynamicInk(light: 0x1D4ED8, dark: 0x93B4FF)
        case .planned: return SQColor.labelSecondary
        }
    }

    private static func dynamicInk(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
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
        let payloads: [MapAnnotationPayload] = model.communitySiteTiles.flatMap(\.markers).compactMap { marker in
            guard seen.insert(marker.id).inserted else { return nil }
            guard marker.lat != 0 || marker.lng != 0 else { return nil }
            let isProbable = marker.candidateKind == "community_probable"
            return MapAnnotationPayload(
                id: "community-site-\(marker.id)",
                kind: .communitySite,
                title: isProbable ? String(localized: "Site probable") : String(localized: "Cellule observée"),
                subtitle: [
                    marker.operatorKey.map { model.operatorShortLabel($0) },
                    marker.radioNodeType,
                    marker.confidenceLevel.map { String(localized: "confiance \($0)") }
                ].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                metric: marker.enb.map { "eNB \($0)" } ?? marker.gnb.map { "gNB \($0)" },
                backendId: marker.candidateKey ?? marker.id,
                details: MapItemDetails(
                    timestamp: marker.lastObservedAt,
                    operatorName: marker.operatorKey.map { model.operatorLabel($0) },
                    sampleCount: marker.observationCount,
                    note: isProbable ? String(localized: "Site estimé par les observations communautaires") : String(localized: "Cellule observée par la communauté")
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: model.operatorAccent(marker.operatorKey ?? "ALL"),
                communityObserved: !isProbable
            )
        }
        // Sans regroupement, le Luxembourg affiche ses cellules et ses 693 sites
        // ajoutés d'un coup à z10 : plus de 700 `MKAnnotationView` vivantes, et
        // la carte devient pâteuse. Les antennes étaient déjà clusterisées, pas
        // ces deux couches-là.
        return clusteredPayloads(
            from: payloads,
            kind: .communitySite,
            idPrefix: "community-site",
            minCount: Self.communityClusterThreshold,
            label: { String(localized: "\($0) cellules") }
        )
    }

    /// Couche « Sites ajoutés » : pylônes pointés à la main par les membres.
    ///
    /// Visible sur TOUS les marchés, contrairement aux couches dérivées de l'open
    /// data. Sans elle, un pays sans régulateur ouvert (Bosnie, Portugal, Espagne)
    /// affiche une carte vide alors que la donnée existe côté serveur.
    private var customSitePayloads: [MapAnnotationPayload] {
        // Sur un marché sans open data, « Antennes » entraîne cette couche : c'est
        // la seule qui puisse répondre à la demande.
        guard filters.contains(.customSite)
            || (model.isCommunityOnlyMarket && filters.contains(.antenna)) else { return [] }
        // Un site posé à la main porte le badge de panne au même titre qu'une antenne officielle,
        // et c'est ce qui rend le modèle vrai partout : dans les 44 marchés sans référentiel
        // public, c'est le SEUL point qui puisse en porter un. La clé est `targetId` — l'id du
        // `CustomSite` —, celle-là même que `OutageReportSheet` envoie pour `targetKind = custom`.
        let outageMarks: [String: CommunityOutageMark] =
            filters.contains(.outage) ? [:] : communityOutageMarksBySite
        var seen = Set<String>()
        let payloads: [MapAnnotationPayload] = model.customSiteTiles.flatMap(\.markers).compactMap { marker in
            guard seen.insert(marker.id).inserted else { return nil }
            guard marker.lat != 0 || marker.lng != 0 else { return nil }
            let radio = marker.radio
            return MapAnnotationPayload(
                id: "custom-site-\(marker.id)",
                kind: .customSite,
                title: marker.name ?? marker.typeLabel ?? String(localized: "Site ajouté"),
                subtitle: [
                    marker.typeLabel,
                    radio?.operatorName,
                    radio?.technology
                ].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                metric: radio?.enb.map { "eNB \($0)" } ?? radio?.gnb.map { "gNB \($0)" },
                backendId: marker.id,
                details: MapItemDetails(
                    timestamp: marker.createdAt,
                    operatorName: radio?.operatorName,
                    note: marker.description
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                // Le registre d'abord : la plupart des sites ajoutés portent déjà
                // une CLÉ de registre (« TANGO_LU », « POST_LU »), que `SQBrand`
                // — qui ne connaît que la France — rendait en gris neutre. Le nom
                // libre (« BH Mobile ») retombe sur la résolution tolérante.
                tint: marker.operatorTint(resolve: { model.operatorAccent($0) }),
                contributionPhotos: marker.photoCount,
                hasEnb: marker.isValidated,
                communityOutage: outageMarks[marker.id]
            )
        }
        return clusteredPayloads(
            from: payloads,
            kind: .customSite,
            idPrefix: "custom-site",
            minCount: Self.communityClusterThreshold,
            label: { String(localized: "\($0) sites ajoutés") }
        )
    }

    /// Seuil de regroupement des couches communautaires.
    ///
    /// Plus bas que celui des antennes (160) : ces couches s'AJOUTENT aux
    /// antennes déjà à l'écran, donc elles partagent le même budget de
    /// marqueurs. Et à z < 14, sept cents points ne distinguent plus rien.
    private static let communityClusterThreshold = 60

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
                title: String(localized: "Photo"),
                subtitle: photo.operator ?? photo.siteId ?? String(localized: "Site"),
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
                title: String(localized: "\(group.count) photos"),
                subtitle: String(localized: "Zoomer pour le détail"),
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
    private func coverageColorParts(rsrp: Double?, tech: String?) -> (key: String, hex: UInt32, dimmed: Bool, rank: Int, hatched: Bool) {
        if coverageByGeneration {
            let band = CoverageGenerationBand.band(for: tech)
            // `band.rank` (5G=5 > 4G=4 > … > aucun=0) pilote le z-order (cf. tri en
            // fin de `coverageHeatFeatures`).
            return ("g-\(band.rawValue)", band.colorHex, band == .none, band.rank, false)
        } else {
            // Seuils de la technologie du point, « sans réseau constaté » avant
            // toute valeur (contrat quality-scale v1, comme Android et le web).
            let band = CoverageQualityBand.band(forDbm: rsrp, technology: tech)
            // Rang neutre en mode RSRP → le tri par génération est un no-op.
            return ("q-\(band.rawValue)", band.colorHex, band == .unknown, 0, band.isHatched)
        }
    }

    private func coverageFeature(from point: AndroidCoveragePoint) -> CoverageHeatFeature {
        let parts = coverageColorParts(rsrp: point.rsrp, tech: point.tech)
        return CoverageHeatFeature(
            id: "coverage-heat-\(point.id)",
            coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
            weight: coverageHeatWeight(rsrp: point.rsrp),
            colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed, hatched: parts.hatched,
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
        var features: [CoverageHeatFeature] = []
        for tile in model.coverageTiles {
            let render = CoverageRenderPolicy.mode(for: tile, selectedBands: model.bandFilters)
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
                        colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed, hatched: parts.hatched,
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
                let filtered = tile.points.lazy.filter { CoverageRenderPolicy.matches($0, selectedBands: model.bandFilters) }
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
                    colorKey: parts.key, colorHex: parts.hex, dimmed: parts.dimmed, hatched: parts.hatched,
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

    /// Couleurs des opérateurs d'un site, pour le camembert des sites partagés.
    ///
    /// Vide dès qu'un opérateur précis est sélectionné : le backend ne renvoie
    /// alors que sa facette du site, donc découper le point donnerait un
    /// camembert d'une seule part — ou pire, ferait croire à un partage là où
    /// c'est juste le filtre qui masque les autres.
    private func operatorTints(for site: AntennaSite) -> [Color] {
        guard model.operatorFilter.uppercased() == "ALL", site.operators.count > 1 else { return [] }
        var seen = Set<String>()
        return site.operators
            .filter { seen.insert($0.uppercased()).inserted }
            .map { model.operatorAccent($0) }
    }

    /// Indices, dans `operatorTints`, des opérateurs qui émettent en 5G.
    ///
    /// On travaille en INDICES et non en couleurs : deux opérateurs peuvent
    /// partager une teinte (registre incomplet), et il faut alors distinguer
    /// leurs parts. L'anneau se découpe sur les mêmes secteurs que le camembert,
    /// donc l'arc 5G d'un opérateur coiffe exactement sa part.
    private func fiveGTintIndices(for site: AntennaSite) -> [Int] {
        let tints = operatorTints(for: site)
        guard tints.count > 1, !site.operators5G.isEmpty else { return [] }
        var seen = Set<String>()
        let ordered = site.operators.filter { seen.insert($0.uppercased()).inserted }
        let fiveG = Set(site.operators5G.map { $0.uppercased() })
        return ordered.enumerated()
            .filter { $0.offset < tints.count && fiveG.contains($0.element.uppercased()) }
            .map(\.offset)
    }

    /// Regroupe les azimuts d'un site partagé par DIRECTION, avec les couleurs
    /// des opérateurs qui la pointent.
    ///
    /// Deux opérateurs déclarant 0° et 1° visent la même chose : les traiter
    /// comme deux directions donnerait deux traits qui se chevauchent et dont un
    /// seul serait visible. La tolérance les fond en un seul faisceau bicolore.
    private func azimuthBeams(for site: AntennaSite) -> [AzimuthBeam] {
        guard model.operatorFilter.uppercased() == "ALL",
              site.azimuthsByOperator.count > 1 else { return [] }
        return MapExplorerViewModel.groupAzimuthBeams(
            operators: site.operators,
            azimuthsByOperator: site.azimuthsByOperator,
            tint: { [model] key in model.operatorAccent(key) }
        )
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
        Self.clusteredPayloads(from: payloads, kind: kind, idPrefix: idPrefix,
                               minCount: minCount, zoom: mapZoom, label: label)
    }

    static func clusteredPayloads(
        from payloads: [MapAnnotationPayload],
        kind: MapDisplayItem.Kind,
        idPrefix: String,
        minCount: Int,
        zoom: Double,
        label: (Int) -> String
    ) -> [MapAnnotationPayload] {
        guard zoom < 14, payloads.count > minCount else { return payloads }
        let cellSize: Double
        switch zoom {
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

        return groups.map { cell, group in
            guard group.count > 1 else { return group[0] }
            let lat = group.reduce(0) { $0 + $1.coordinate.latitude } / Double(group.count)
            let lng = group.reduce(0) { $0 + $1.coordinate.longitude } / Double(group.count)
            return MapAnnotationPayload(
                // The grouping uses floor. Truncating a negative centroid toward
                // zero gives the same ID as the adjacent positive cell at 0.
                id: "\(idPrefix)-cluster-\(cell.lat)-\(cell.lng)",
                kind: kind,
                title: label(group.count),
                subtitle: String(localized: "Zoomer pour le détail"),
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
        //  · pannes signalées → `communityOutagePayloads` (gravité + confirmation),
        //    portées par le MÊME filtre `.outage` que les incidents opérateurs
        // Ne restent ici que validations / sessions du snapshot. Les amis passent
        // par `friendPayloads` (rendu « Find My » riche, alimenté par le flux live).
        let socialFilters = filters.subtracting([.speedtest, .coverage, .antenna, .photo, .planned, .outage, .friend])
        return model.snapshot.displayItems(include: socialFilters)
    }

    /// Amis géolocalisés de la couche « Amis », rendus en marqueur avatar « Find
    /// My » (avatar + anneau de présence + cône de cap + badge). Alimentés par le
    /// flux temps réel (`model.liveFriends`), pas par le snapshot borné.
    private var friendPayloads: [MapAnnotationPayload] {
        guard filters.contains(.friend) else { return [] }
        let selectedID = effectiveFriendFilterID
        return model.liveFriends.compactMap { friend in
            if let selectedID, friend.id != selectedID { return nil }
            guard let location = friend.location else { return nil }
            guard !friend.hasExpiredLocation(now: friendFreshnessNow) else { return nil }
            let info = FriendAnnotationInfo(
                userId: friend.id,
                displayName: friend.name ?? String(localized: "Ami"),
                avatarURL: friend.avatarUrl,
                presence: friend.presenceStatus,
                heading: location.heading.flatMap { $0 >= 0 ? $0 : nil },
                speedMps: location.speed.flatMap { $0 >= 0 ? $0 : nil },
                accuracyMeters: location.accuracy.flatMap { $0 > 0 ? $0 : nil },
                technology: friend.radio?.technology,
                operatorName: friend.radio?.operator,
                isStale: friend.hasStaleLocation(now: friendFreshnessNow)
            )
            let subtitle = friend.radio?.technology
                ?? friend.presence?.customStatus
                ?? friend.presenceStatus.label
            return MapAnnotationPayload(
                id: "friend-\(friend.id)",
                kind: .friend,
                title: friend.name ?? String(localized: "Ami"),
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

    /// Sur iPad (largeur régulière), la fiche antenne s'ouvre en panneau à gauche :
    /// la carte reste visible et manipulable à droite.
    private var usesAntennaSidePanel: Bool { horizontalSizeClass == .regular }

    /// Jamais plus étroit qu’un iPhone, la largeur pour laquelle la fiche est mise en page.
    private func sidePanelWidth(in containerWidth: CGFloat) -> CGFloat {
        min(420, max(402, containerWidth * 0.45))
    }

    private func sidePanelInset(in containerWidth: CGFloat) -> CGFloat {
        guard usesAntennaSidePanel, selectedAntenna != nil else { return 0 }
        return sidePanelWidth(in: containerWidth) + SQSpace.lg
    }

    private var compactAntennaSelection: Binding<AntennaSite?> {
        Binding(
            get: { usesAntennaSidePanel ? nil : selectedAntenna },
            set: { selectedAntenna = $0 }
        )
    }

    private func antennaDetail(_ site: AntennaSite, onClose: (() -> Void)? = nil) -> some View {
        AntennaDetailSheet(
            site: site,
            market: model.marketFilter,
            operatorName: model.operatorFilter,
            service: services.antennas,
            sightOrigin: sightOrigin,
            onIsolateCoverage: { focus in isolateCoverage(focus) },
            onClose: onClose,
            // Signaler, confirmer ou clore une panne change son marqueur : on recharge la région.
            onOutageChanged: { Task { await reloadCurrentRegion() } }
        )
        // Tous les chemins mènent ici : recherche, carte, lien, historique.
        .onAppear { RecentlyViewedStore.record(.site(site, market: model.marketFilter)) }
    }

    @ViewBuilder
    private var antennaSidePanel: some View {
        if usesAntennaSidePanel, let site = selectedAntenna {
            GeometryReader { geo in
                antennaDetail(site, onClose: { selectedAntenna = nil })
                    // Un autre site remplace la fiche au lieu de garder l'état du précédent.
                    .id(site.id)
                    .frame(width: sidePanelWidth(in: geo.size.width))
                    .frame(maxHeight: .infinity)
                    .background(SQColor.bg)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .sqShadowSoft()
                    .padding(.leading, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// Les photos du même site, dans l'ordre de la carte, pour défiler de
    /// l'une à l'autre ; une photo sans site reste seule.
    private func photoSiblings(of target: MapPhotoTarget) -> [MapPhotoTarget] {
        let siteId = model.publicPhotos.first { $0.id == target.id }?.siteId
        guard let siteId, !siteId.isEmpty else { return [target] }
        let siblings = model.publicPhotos
            .filter { $0.siteId == siteId }
            .map { MapPhotoTarget(id: $0.id, thumbnailURL: $0.thumbnailUrl, date: $0.uploadedAt) }
        return siblings.contains { $0.id == target.id } ? siblings : [target]
    }

    /// Le site d'une photo, s'il est chargé sur la carte.
    private func photoSite(for photoId: String) -> AntennaSite? {
        guard let siteId = model.publicPhotos.first(where: { $0.id == photoId })?.siteId, !siteId.isEmpty else { return nil }
        return model.antennas.first { $0.siteId == siteId || $0.id == siteId }
    }

    private func photoViewerSite(_ site: AntennaSite) -> MapPhotoSite {
        let distance = services.location.cachedLocation().flatMap { here -> String? in
            guard let latitude = site.latitude, let longitude = site.longitude else { return nil }
            return SQUnits.distance(meters: here.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
        }
        let number = site.siteId.flatMap { $0.isEmpty ? nil : String(localized: "Support \($0)") }
        return MapPhotoSite(
            kicker: number,
            title: site.address.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Site \(site.siteId ?? site.id)"),
            caption: distance,
            operators: site.operators.map { MapPhotoSite.Operator(label: model.operatorLabel($0), color: model.operatorAccent($0)) },
            technologies: site.technologies,
            height: site.height.map { "\(Int($0.rounded())) m" }
        )
    }

    private func selectAnnotation(_ annotation: MapAnnotationPayload) {
        Haptics.light()
        if annotation.isSearchPin { return }
        // Comme sur le web, ouvrir un repère ferme la comparaison : une seule feuille à la fois.
        // Un groupe ne fait que zoomer, la comparaison reste.
        if zoneCompareTarget != nil, annotation.clusterCount == nil {
            selectionAfterZoneCompare = annotation
            zoneCompareTarget = nil
            return
        }
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
        // Panne signalée : feuille dédiée à la panne, jamais la fiche antenne.
        // Aucune ambiguïté avec le test précédent — un marqueur d'antenne porte un
        // `antennaId` et est déjà parti, un marqueur de panne n'en porte pas. Et la
        // garde de filtre vaut ceinture et bretelles : sans elle, un payload survivant
        // à l'extinction du filtre rouvrirait une feuille qu'on ne peut plus viser.
        if annotation.kind == .communityOutage, filters.contains(.outage),
           let outageId = annotation.backendId,
           let outage = model.communityOutages.first(where: { $0.id == outageId }) {
            selectedCommunityOutage = outage
            return
        }
        // Panne opérateur (HS) : sheet dédiée détaillée (raison, services impactés, dates).
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
        // Cellule observée : fiche dédiée. Ce n'est PAS un site — sa position est
        // un centroïde de mesures — et la fiche propose justement d'en poser un.
        if annotation.kind == .communitySite, let cellId = annotation.backendId ?? annotation.antennaId,
           let cell = model.communitySiteTiles.flatMap(\.markers)
               .first(where: { $0.id == cellId || $0.candidateKey == cellId }) {
            selectedObservedCell = cell
            return
        }
        // Site ajouté à la main : même fiche terrain que les antennes officielles.
        if annotation.kind == .customSite, let siteId = annotation.backendId,
           let site = model.customSiteTiles.flatMap(\.markers).first(where: { $0.id == siteId }) {
            selectedCustomSite = site
            return
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

    /// Fiche d'un site relevé à la main : la MÊME que pour une antenne officielle.
    /// `/map/antenna/{id}` sert les deux, et un site relevé mérite la boussole, le
    /// profil d'altitude, les photos et les speedtests proches comme les autres.
    ///
    /// Extraite de la chaîne de `.sheet` : en ligne, l'inférence de type du
    /// compilateur explosait sur l'empilement de modificateurs.
    private func customSiteSheet(_ site: AndroidCustomSiteMarker) -> some View {
        let operatorName = site.radio?.operatorName ?? model.operatorFilter
        return AntennaDetailSheet(
            site: MapExplorerViewModel.antennaSite(from: site),
            market: model.marketFilter,
            operatorName: operatorName,
            service: services.antennas,
            customSite: site,
            sightOrigin: sightOrigin,
            onIsolateCoverage: { focus in isolateCoverage(focus) },
            onOutageChanged: { Task { await reloadCurrentRegion() } }
        )
    }

    private func requestCamera(region: MKCoordinateRegion) {
        let width = viewportGate.latest.map { CGFloat($0.widthPoints) } ?? SQMapProjection.referenceWidth
        requestCamera(center: region.center, zoom: SQMapProjection.zoom(forRegion: region, width: width))
    }

    private func requestCamera(center: CLLocationCoordinate2D, zoom: Double) {
        guard CLLocationCoordinate2DIsValid(center), zoom.isFinite else { return }
        let changed = abs(mapCenter.latitude - center.latitude) > 0.00005
            || abs(mapCenter.longitude - center.longitude) > 0.00005 || abs(mapZoom - zoom) > 0.01
        if changed {
            fetchTask?.cancel()
            model.cancelPendingLoad()
            viewportGate.invalidateCamera()
            mapCenter = center
            mapZoom = zoom
        } else { scheduleCurrentViewport() }
    }

    private func scheduleCurrentViewport() {
        guard let viewport = viewportGate.admitted else { return }
        MapRegionStore.save(lastRegion)
        fetchTask?.cancel()
        let requestedFilters = filters
        let requestID = model.prepareLoad(filters: requestedFilters)
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await model.load(bounds: viewport.bounds, zoom: viewport.zoom, filters: requestedFilters,
                             lightweight: true, requestID: requestID)
        }
    }

    /// N'affiche plus que la couverture d'UN site.
    ///
    /// La couche couverture exige un opérateur précis (superposer tous les
    /// opérateurs n'a pas de sens) : on cale donc le filtre sur celui de la
    /// fiche, sinon la couche resterait muette en « Tous ».
    private func isolateCoverage(_ focus: AntennaCoverageFocus) {
        guard focus.isUsable else { return }
        let key = model.registryMarket(forCode: model.marketFilter)?.operatorEntry(forKey: focus.operatorKey)?.key ?? focus.operatorKey
        model.chooseOperatorManually(key)
        guard model.operatorFilter.caseInsensitiveCompare(key) == .orderedSame else { return }
        model.coverageFocus = AntennaCoverageFocus(siteLabel: focus.siteLabel, operatorKey: key, enb: focus.enb, gnb: focus.gnb)
        filters.insert(.coverage)
        MapFilterStore.save(filters)
        Task { await reloadCurrentRegion() }
    }

    private func clearCoverageFocus() {
        model.coverageFocus = nil
        Task { await reloadCurrentRegion() }
    }

    /// Recharge la zone visible. Appelé après création d'un site pour que le
    /// marqueur apparaisse sans attendre le prochain déplacement de carte.
    private func reloadCurrentRegion() async {
        guard let viewport = viewportGate.admitted else { return }
        let requestedFilters = filters
        let requestID = model.prepareLoad(filters: requestedFilters)
        await model.mapService.invalidateTiles()
        guard !Task.isCancelled else { return }
        await model.load(bounds: viewport.bounds, zoom: viewport.zoom, filters: requestedFilters,
                         requestID: requestID, refresh: true)
    }

    private func handlePrivacyZoneMapChange() {
        seenPrivacyZoneMapRevision = SQPrivacyZoneMapChange.revision
        fetchTask?.cancel()
        model.discardPublicMeasurementsAfterPrivacyZoneChange()
        if let kind = selectedItem?.kind, [.session, .coverage, .speedtest].contains(kind) {
            selectedItem = nil
        }
        refreshMapRender()
        fetchTask = Task { await reloadCurrentRegion() }
    }

    /// Fiche d'une cellule observée, avec les autres cellules du même endroit
    /// proposées au regroupement (un pylône porte souvent plusieurs opérateurs).
    private func observedCellSheet(_ cell: AndroidCommunitySiteMarker) -> some View {
        let nearby = model.communitySiteTiles.flatMap(\.markers).filter { other in
            other.id != cell.id && Self.isSameSpot(cell, other)
        }
        return ObservedCellSheet(
            cell: cell,
            nearbyCells: nearby,
            operatorLabel: { model.operatorLabel($0) },
            onCreateSite: { selected in
                selectedObservedCell = nil
                // Laisser la première feuille se fermer avant d'en présenter une
                // autre : deux `sheet` simultanées s'annulent sous iOS 16.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    cellsForNewSite = selected
                }
            }
        )
    }

    /// Deux cellules « au même endroit » : moins de 150 m. Assez large pour
    /// réunir les opérateurs d'un même pylône dont les centroïdes diffèrent,
    /// assez serré pour ne pas agréger deux sites d'une même rue.
    private static func isSameSpot(_ a: AndroidCommunitySiteMarker, _ b: AndroidCommunitySiteMarker) -> Bool {
        CLLocation(latitude: a.lat, longitude: a.lng)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lng)) <= 150
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


}

// MARK: - Carte MapKit (moteur unique)

// MARK: - Style des marqueurs MapKit (couleur / taille / glyphe par type)

#if DEBUG
/// Recherche synthétique réservée au banc local du profil, absente de Release.
private enum MapProfileQASearch {
    private struct Response: Decodable {
        struct Place: Decodable {
            let id: String
            let name: String
            let subtitle: String?
            let latitude: Double
            let longitude: Double
        }
        let places: [Place]
    }

    static func places(query: String, config: AppConfig) async -> [PlaceResult] {
        let fixtureBase = "http://127.0.0.1:8770"
        guard config.apiBaseURL.absoluteString == fixtureBase,
              config.appBaseURL.absoluteString == fixtureBase,
              var components = URLComponents(string: fixtureBase + "/__qa/profile/places") else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                  response.statusCode == 200, response.url == url else { return [] }
            return try JSONDecoder().decode(Response.self, from: data).places.prefix(6).compactMap { place in
                let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                guard CLLocationCoordinate2DIsValid(coordinate), !place.id.isEmpty else { return nil }
                return PlaceResult(id: place.id, name: place.name, subtitle: place.subtitle,
                                   latitude: place.latitude, longitude: place.longitude)
            }
        } catch { return [] }
    }

    /// Une redirection ne doit jamais exporter la requête hors du banc.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
#endif

struct MapItemSheet: View {
    let item: MapDisplayItem
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var speedtestDetail: SpeedtestDetail?
    @State private var detailError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                switch item.kind {
                case .speedtest:
                    speedtestContent
                case .coverage:
                    coverageContent
                default:
                    genericContent
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .accessibilityIdentifier("map.item.content")
        .task(id: item.backendId) { await loadSpeedtestDetailIfNeeded() }
        .presentationDetents([.height(360), .medium, .large])
        // Fond papier : les tuiles et les détails sont des cartes blanches.
        .sqSheet(background: SQColor.bg)
    }

    /// Le débit de réception fait le titre ; envoi, latence et gigue en
    /// tuiles ; maximums et latence minimale dans les détails.
    private var speedtestContent: some View {
        let detail = speedtestDetail
        let local = item.details
        let downloadAverage = detail?.averageSpeed ?? detail?.downloadAvg ?? detail?.downloadSpeed ?? local?.downloadMbps
        let downloadMax = detail?.downloadMax ?? detail?.downloadPeakMbps ?? detail?.maxSpeed ?? detail?.downloadSpeed ?? local?.downloadMbps
        let uploadAverage = detail?.uploadAvg ?? detail?.uploadSpeed ?? local?.uploadMbps
        let uploadMax = detail?.uploadMax ?? detail?.uploadPeakMbps ?? detail?.uploadSpeed ?? local?.uploadMbps
        let pingMin = detail?.pingMin ?? detail?.ping ?? local?.pingMs
        let pingAverage = detail?.pingAvg ?? detail?.ping ?? local?.pingMs
        let tech = detail?.networkType ?? local?.tech
        let network = [detail?.connectionType, detail?.networkType].compactMap { $0 }.joined(separator: " / ")
        return VStack(alignment: .leading, spacing: SQSpace.lg) {
            header(
                kicker: [String(localized: "Speedtest"), detail?.mobileOperator ?? local?.operatorName, tech],
                value: downloadAverage.map { SQUnits.throughputValue(mbps: $0) } ?? "—",
                unit: downloadAverage.map { String(localized: "\(SQUnits.throughputUnit(mbps: $0)) en réception") },
                caption: [formatDate(detail?.timestamp ?? local?.timestamp), distanceText]
            )
            tiles([
                ("Envoi", uploadAverage.map { SQUnits.throughputValue(mbps: $0) }, uploadAverage.map { SQUnits.throughputUnit(mbps: $0) }),
                ("Latence", pingAverage.map { "\(Int($0.rounded()))" }, "ms"),
                ("Gigue", detail?.jitter.map { $0.formatted(.number.precision(.fractionLength(0...1))) }, "ms")
            ])
            detailRows([
                // Un maximum égal au chiffre du titre ne dit rien de plus.
                ("Réception max", downloadMax == downloadAverage ? nil : downloadMax.map(SignalFormatters.speed)),
                ("Envoi max", uploadMax == uploadAverage ? nil : uploadMax.map(SignalFormatters.speed)),
                ("Latence min", pingMin.map(SignalFormatters.ms)),
                ("Réseau", network),
                ("Serveur de mesure", detail?.downloadServerName ?? detail?.server),
                ("Flux simultanés", detail?.streams.map(String.init)),
                ("Durée", SignalFormatters.duration(detail?.testDuration)),
                ("Appareil", [detail?.deviceType, detail?.deviceModel].compactMap { $0 }.joined(separator: " ")),
                ("Position", coordinatesText(lat: detail?.latitude ?? item.coordinate.latitude, lon: detail?.longitude ?? item.coordinate.longitude))
            ])
            if let detailError {
                SQNotice(message: detailError)
            }
        }
    }

    /// La qualité se lit dans l'adjectif et sur le point de la carte, pas
    /// dans la couleur du chiffre, trop peu contrastée.
    private var coverageContent: some View {
        let details = item.details
        let rsrp = details?.rsrp ?? details?.avgRsrp
        let quality = SQQualityScale.Signal(dbm: rsrp, technology: details?.tech)
        let points = details?.clusterCount ?? details?.sampleCount
        let aggregated = details?.clusterCount.map { String(localized: "Agrégé sur \($0) points") }
        return VStack(alignment: .leading, spacing: SQSpace.lg) {
            header(
                kicker: [details?.clusterCount == nil ? String(localized: "Couverture") : String(localized: "Couverture agrégée"),
                         details?.operatorName, details?.tech,
                         details?.band.map { SQUnits.band($0, technology: details?.tech) }],
                value: rsrp.map { "\(Int($0.rounded()))" } ?? "—",
                unit: rsrp.map { _ in String(localized: "dBm · signal \(quality.label.lowercased())") },
                caption: [aggregated, formatDate(details?.timestamp), distanceText]
            )
            tiles([
                ("RSRQ", details?.rsrq.map { "\(Int($0.rounded()))" }, "dB"),
                ("SNR", details?.snr.map { "\(Int($0.rounded()))" }, "dB"),
                ("Points", points.map { SignalFormatters.count($0) }, nil)
            ])
            detailRows([
                ("Source", details?.note ?? "SignalQuest"),
                ("Cellule primaire", details?.isPrimary.map { $0 ? String(localized: "Oui") : String(localized: "Non") }),
                ("Groupe", details?.groupId),
                ("Clusters", (details?.returnedClusters ?? details?.totalClusters).map { SignalFormatters.count($0) }),
                ("Type", details?.cellType ?? details?.representation),
                ("Position", coordinatesText(lat: item.coordinate.latitude, lon: item.coordinate.longitude))
            ])
        }
    }

    private var genericContent: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(kindLabel).sqKicker()
                    Text(item.title)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(SQType.subhead(.regular))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                closeButton
            }
            if let metric = item.metric {
                detailRows([("Donnée", metric)])
            }
        }
    }

    private var closeButton: some View {
        MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "map.item.close") { dismiss() }
    }

    /// Petites capitales qui disent quoi, quel opérateur, quelle technologie ;
    /// grand chiffre d'encre et son unité ; date et distance.
    private func header(kicker: [String?], value: String, unit: String?, caption: [String?]) -> some View {
        let kickerText = kicker.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let captionText = caption.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(kickerText).sqKicker()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(SQFont.display(34, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    if let unit {
                        Text(unit)
                            .font(SQType.callout(.semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !captionText.isEmpty {
                    Text(captionText)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            closeButton
        }
    }

    @ViewBuilder
    private func tiles(_ values: [(String, String?, String?)]) -> some View {
        // Trois tirets n'apprennent rien : sans aucune valeur, pas de tuiles.
        if values.contains(where: { $0.1 != nil }) {
            tileGrid(values)
        }
    }

    private func tileGrid(_ values: [(String, String?, String?)]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : values.count)
        return LazyVGrid(columns: columns, spacing: SQSpace.sm) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, tile in
                SQStatTile(label: tile.0, value: tile.1 ?? "—", unit: tile.1 == nil ? nil : tile.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(SQSpace.sm2)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
        }
    }

    /// Distance depuis la dernière position connue, si elle est récente.
    private var distanceText: String? {
        guard let here = services.location.cachedLocation() else { return nil }
        let point = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
        return String(localized: "à \(SQUnits.distance(meters: here.distance(from: point))) de toi")
    }

    private func loadSpeedtestDetailIfNeeded() async {
        guard item.kind == .speedtest, let id = item.backendId, !id.hasPrefix("speed-cluster") else { return }
        do {
            speedtestDetail = try await services.speedtest.details(id: id)
            detailError = nil
        } catch APIError.http(_, "SPEEDTEST_DETAILS_HIDDEN", _, _, _) {
            // Test fait dans une zone privée : seul son auteur en voit le détail.
            detailError = String(localized: "Détails masqués : seul l’auteur peut les voir")
        } catch {
            detailError = String(localized: "Le détail de cette mesure n’a pas pu être chargé. \(error.userFacingMessage)")
        }
    }

    /// Nom du genre d'élément, jamais sa valeur technique (TRX-26).
    private var kindLabel: String {
        switch item.kind {
        case .friend: String(localized: "Ami")
        case .photo: String(localized: "Photo")
        case .validation: String(localized: "Validation")
        case .session: String(localized: "Session de couverture")
        case .coverage: String(localized: "Couverture")
        case .speedtest: String(localized: "Speedtest")
        case .outage: String(localized: "Panne")
        case .communityOutage: String(localized: "Panne signalée")
        case .planned: String(localized: "Site prévu")
        case .antenna: String(localized: "Antenne")
        case .communitySite: String(localized: "Site communautaire")
        case .customSite: String(localized: "Site ajouté par un membre")
        }
    }

    /// Lignes à points de conduite ; les lignes vides restent masquées.
    @ViewBuilder
    private func detailRows(_ rows: [(String, String?)]) -> some View {
        let visibleRows = rows.compactMap { row -> (String, String)? in
            guard let text = row.1?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text != "—" else { return nil }
            return (row.0, text)
        }
        if !visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Détails").sqKicker().accessibilityAddTraits(.isHeader)
                VStack(spacing: SQSpace.sm) {
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                        SQFactRow(label: row.0, value: row.1)
                    }
                }
                .padding(SQSpace.md)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
        }
    }

    private func formatDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String? {
        guard let lat, let lon else { return nil }
        return String(format: "%.5f, %.5f", lat, lon)
    }
}
