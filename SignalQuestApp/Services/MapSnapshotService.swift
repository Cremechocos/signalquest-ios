import Foundation
import CoreLocation

protocol MapSnapshotServicing: Sendable {
    /// Opaque login generation; token refreshes keep the same session.
    var sessionIdentifier: UUID { get }
    func invalidateTiles() async
    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool) async throws -> SocialMapSnapshot
    /// Flux temps réel des amis (position + présence + radio), branché sur le SSE
    /// serveur `/api/social/map/stream`. Se reconnecte automatiquement.
    func friendsStream(sse: SSEClient) -> AsyncStream<[SocialFriendLive]>
    /// Repli REST minimal si le SSE se termine définitivement.
    func friendsSnapshot() async throws -> [SocialFriendLive]
    func plannedSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [PlannedSiteLive]
    func outageSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [OutageSiteLive]
    func plannedSitesLayer(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> MapFeedResult<PlannedSiteLive>
    func outageSitesLayer(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> MapFeedResult<OutageSiteLive>
    /// Les incidents déclarés par les opérateurs pour UN site (fiche antenne).
    func operatorIncidents(forSiteId siteId: String?, market: String, operatorName: String?, latitude: Double, longitude: Double, territory: String?) async throws -> SiteOperatorIncidentsResponse
    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?, bands: Set<Int>) async throws -> [CoverageHeatPoint]
    func publicPhotos(bounds: MapBounds, zoom: Double, market: String, operatorName: String, friendsOnly: Bool) async throws -> [MapPublicPhoto]
    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool, bands: Set<Int>) async throws -> [AndroidAntennaTileResponse]
    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidSpeedtestTileResponse]
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidCoverageTileResponse]
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?, focus: AntennaCoverageFocus?) async throws -> [AndroidCoverageTileResponse]
    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool, bands: Set<Int>) async throws -> [AndroidCommunitySiteTileResponse]
    func customSiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String) async throws -> [AndroidCustomSiteTileResponse]
}

struct MapBounds: Equatable, Sendable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double

    /// MapKit peut produire des `span` NaN après certaines transitions de caméra
    /// (rotation, changement de scène, redimensionnement de fenêtre). Or les
    /// conversions `Int(...)` qui construisent les clés de cache et les indices
    /// de tuile **trappent** sur NaN ou infini — ce n'est pas un dépassement
    /// rattrapable, c'est un crash. Même garde que `MarketRegistryService:91`.
    var isFinite: Bool {
        north.isFinite && south.isFinite && east.isFinite && west.isFinite
    }
}

final class MapSnapshotService: MapSnapshotServicing {
    private let api: APIClient
    private let socialCache: TileCache
    private let tileCache: TileCache
    var sessionIdentifier: UUID { api.credentials.snapshot().sessionID }

    // Dossier DÉDIÉ. `MapSnapshotService` et `MarketRegistryService` prenaient
    // tous deux le `DiskCache()` par défaut, donc le même dossier — deux acteurs
    // distincts sur un même répertoire : le throttle d'éviction est par
    // instance, le scan tournait deux fois plus souvent, et chacun pouvait
    // supprimer les fichiers de l'autre en atteignant le plafond de 64 Mo. Leurs
    // TTL n'ont rien à voir (snapshot 30 s, registre 24 h).
    init(api: APIClient, cache: DiskCache = DiskCache(folderName: "SignalQuestMapCache"), tileCache: TileCache = TileCache()) {
        self.api = api
        self.socialCache = TileCache(disk: cache, memoryTTL: 30, diskTTL: 30)
        self.tileCache = tileCache
    }

    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool = true) async throws -> SocialMapSnapshot {
        // Les `Int(...)` de la clé de cache trappent sur NaN/infini. `.cancelled`
        // plutôt qu'une vraie erreur : une région dégénérée n'est pas un échec à
        // montrer à l'utilisateur, il n'y a simplement rien à charger — et
        // `Error.isCancellation` fait déjà taire ce cas chez tous les appelants.
        guard bounds.isFinite, zoom.isFinite else { throw APIError.cancelled }
        let owner = api.credentials.snapshot()
        // Les couches sociales sont privées ; un invité ne doit ni les demander
        // ni déclencher un refresh de session à chaque déplacement de carte.
        guard owner.accessToken?.isEmpty == false else { return .empty }
        let segments = try bounds.canonicalSegments
        var parts: [SocialMapSnapshot] = []
        for segment in segments {
            guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
            parts.append(try await snapshotSegment(bounds: segment, zoom: zoom, lightweight: lightweight, owner: owner))
        }
        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
        return try MapSnapshotMerging.social(parts, lightweight: lightweight)
    }

    private func snapshotSegment(bounds: MapBounds, zoom: Double, lightweight: Bool,
                                 owner: CredentialStore.Snapshot) async throws -> SocialMapSnapshot {
        let key = "social-map-v2-\(owner.sessionID)-\(bounds.north.bitPattern)-\(bounds.south.bitPattern)-\(bounds.east.bitPattern)-\(bounds.west.bitPattern)-\(zoom.bitPattern)-\(lightweight)"
        let bytes = try await socialCache.data(for: key, maxAge: 30, validate: {
            _ = try JSONDecoder.signalQuest.decode(SocialMapSnapshot.self, from: $0)
        }) { [api] in
            try await api.requestData(
                APIEndpoint(
                    path: "/api/social/map/snapshot",
                    query: [
                        URLQueryItem(name: "north", value: "\(bounds.north)"),
                        URLQueryItem(name: "south", value: "\(bounds.south)"),
                        URLQueryItem(name: "east", value: "\(bounds.east)"),
                        URLQueryItem(name: "west", value: "\(bounds.west)"),
                        URLQueryItem(name: "zoom", value: "\(zoom)"),
                        URLQueryItem(name: "lightweight", value: lightweight ? "1" : "0"),
                    ],
                    headers: ["Cache-Control": "no-cache"]
                ),
                expectedSessionID: owner.sessionID
            )
        }
        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
        return try JSONDecoder.signalQuest.decode(SocialMapSnapshot.self, from: bytes)
    }

    /// Amis en temps réel via le SSE `/api/social/map/stream` (le backend re-poll
    /// son snapshot toutes les 5 s). `full=false` = snapshot allégé. Le flux n'est
    /// pas géo-borné : on n'en extrait QUE les amis (peu nombreux), décodés via une
    /// enveloppe partielle pour rester robuste aux autres couches. Les positions
    /// sont déjà gatées serveur par `shareLiveLocationWithFriends`.
    func friendsStream(sse: SSEClient) -> AsyncStream<[SocialFriendLive]> {
        struct FriendsEnvelope: Decodable { let friends: [SocialFriendLive] }
        return AsyncStream { continuation in
            let task = Task {
                let decoder = JSONDecoder.signalQuest
                for await (_, data) in sse.dataStream(
                    path: "/api/social/map/stream",
                    query: [
                        URLQueryItem(name: "full", value: "false"),
                        URLQueryItem(name: "only", value: "friends")
                    ],
                    keep: ["snapshot"]
                ) {
                    guard let payload = data.data(using: .utf8),
                          let envelope = try? decoder.decode(FriendsEnvelope.self, from: payload)
                    else { continue }
                    continuation.yield(envelope.friends)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func friendsSnapshot() async throws -> [SocialFriendLive] {
        guard api.credentials.snapshot().accessToken?.isEmpty == false else { return [] }
        struct FriendsEnvelope: Decodable { let friends: [SocialFriendLive] }
        let envelope: FriendsEnvelope = try await api.request(
            APIEndpoint(
                path: "/api/social/map/snapshot",
                query: [
                    URLQueryItem(name: "lightweight", value: "1"),
                    URLQueryItem(name: "only", value: "friends")
                ]
            ),
            as: FriendsEnvelope.self
        )
        return envelope.friends
    }

    func plannedSites(market: String, operatorName: String, territory: String? = nil, bands: Set<Int> = []) async throws -> [PlannedSiteLive] {
        try await plannedSitesLayer(market: market, operatorName: operatorName, territory: territory, bands: bands).sites
    }

    func plannedSitesLayer(market: String, operatorName: String, territory: String? = nil, bands: Set<Int> = []) async throws -> MapFeedResult<PlannedSiteLive> {
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName)
        ]
        if let territory, !territory.isEmpty {
            query.append(URLQueryItem(name: "territory", value: territory))
        }
        query.append(contentsOf: Self.bandQueryItems(bands))
        let response: PlannedSitesResponse = try await api.request(
            APIEndpoint(path: "/api/map/planned-sites", query: query),
            as: PlannedSitesResponse.self
        )
        return MapFeedResult(sites: response.sites, availability: response.availability)
    }

    func outageSites(market: String, operatorName: String, territory: String? = nil, bands: Set<Int> = []) async throws -> [OutageSiteLive] {
        try await outageSitesLayer(market: market, operatorName: operatorName, territory: territory, bands: bands).sites
    }

    func outageSitesLayer(market: String, operatorName: String, territory: String? = nil, bands: Set<Int> = []) async throws -> MapFeedResult<OutageSiteLive> {
        // `/api/android/map/incidents` accepte « ALL » pour FR (tous opérateurs
        // confondus, ~800 incidents) comme pour DROM/CA — pas besoin d'agréger.
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName)
        ]
        if let territory, !territory.isEmpty {
            query.append(URLQueryItem(name: "territory", value: territory))
        }
        query.append(contentsOf: Self.bandQueryItems(bands))
        // `/api/android/map/incidents` (le même endpoint qu'Android) renvoie des
        // coordonnées `lat`/`lon` minuscules + un `issueType` exploitable, là où
        // `/api/sites-hs` renvoyait `Lat`/`Lon` (majuscules) que iOS ne décodait
        // pas → les pannes ne s'affichaient jamais.
        let response: OutageSitesResponse = try await api.request(
            APIEndpoint(path: "/api/android/map/incidents", query: query, authenticated: false),
            as: OutageSitesResponse.self
        )
        return MapFeedResult(sites: response.sites, availability: response.availability)
    }

    /// Les incidents qu'un opérateur déclare LUI-MÊME sur un site précis.
    ///
    /// Route dédiée, et pas un champ de plus dans la lecture des pannes communautaires : sa
    /// réponse est la même pour tout le monde donc cacheable (5 min côté serveur), là où
    /// `myVote`/`canVote`/`canClose` interdisent tout cache à l'autre. Les deux lectures partent
    /// donc en parallèle depuis la fiche antenne, et chaque bloc s'affiche dès qu'il arrive.
    ///
    /// `lat`/`lon` sont OBLIGATOIRES côté serveur : le code de site d'un opérateur n'est pas le
    /// `sup_id` de l'ANFR, si bien que l'égalité de clé ne se déclenche presque jamais et que
    /// c'est la distance qui rapproche réellement les deux référentiels.
    func operatorIncidents(
        forSiteId siteId: String?,
        market: String,
        operatorName: String?,
        latitude: Double,
        longitude: Double,
        territory: String? = nil
    ) async throws -> SiteOperatorIncidentsResponse {
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "lat", value: "\(latitude)"),
            URLQueryItem(name: "lon", value: "\(longitude)")
        ]
        // « ALL » n'est pas un opérateur : le transmettre restreindrait le flux à un opérateur
        // nommé « ALL », qui n'existe pas. L'omettre rend tous les opérateurs du pylône, ce qui
        // est le comportement voulu sur un support partagé.
        if let operatorName, !operatorName.isEmpty, operatorName.uppercased() != "ALL" {
            query.append(URLQueryItem(name: "operator", value: operatorName))
        }
        if let siteId, !siteId.isEmpty {
            query.append(URLQueryItem(name: "siteKey", value: siteId))
        }
        if let territory, !territory.isEmpty {
            query.append(URLQueryItem(name: "territory", value: territory))
        }
        // Le contenu est public, mais la ROUTE ne l'est pas : elle est gardée par
        // `policy: 'first-party-or-api-key'`, contrairement à `/api/android/map/incidents` juste
        // au-dessus qui, elle, n'appelle pas du tout `authorizeApiAccess`.
        //
        // Or iOS ne porte NI `x-first-party-token` (l'attestation est un mécanisme Android :
        // `APIClient.clientInfoHeaders` n'émet que `X-Client-Platform`/`Os`/`Model`/`App-Version`),
        // NI `Origin`/`Referer` (donc `isProbablyTrustedFirstPartyWebRequest` rend `false`), NI
        // clé d'API. Le cookie de session est le SEUL laissez-passer dont il dispose, via le repli
        // `allowSessionFallback` d'`authorizeApiAccess`. L'ôter rendait 401 à tout le monde et
        // vidait définitivement le bloc « Déclaré par l'opérateur » de la fiche antenne.
        //
        // Vérifié en production sur la route sœur de MÊME politique, `/api/sites-hs`, appelée
        // exactement comme le ferait cette app sans cookie : HTTP 401 `API_KEY_REQUIRED`.
        //
        // Conséquence assumée : un visiteur non connecté ne voit pas ce bloc. La lever demanderait
        // de passer la route en `policy: 'public'` côté serveur — décision serveur, pas cliente.
        return try await api.request(
            APIEndpoint(path: "/api/network-incidents/site", query: query),
            as: SiteOperatorIncidentsResponse.self
        )
    }

    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?, bands: Set<Int> = []) async throws -> [CoverageHeatPoint] {
        let owner = api.credentials.snapshot()
        let segments = try bounds.canonicalSegments
        var parts: [[CoverageHeatPoint]] = []
        for segment in segments {
            guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
            parts.append(try await coveragePointsSegment(bounds: segment, market: market, operatorName: operatorName, technology: technology, bands: bands, owner: owner))
        }
        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
        return MapSnapshotMerging.unique(parts, id: \.id)
    }

    private func coveragePointsSegment(bounds: MapBounds, market: String, operatorName: String, technology: String?, bands: Set<Int>, owner: CredentialStore.Snapshot) async throws -> [CoverageHeatPoint] {
        var query = [
            URLQueryItem(name: "north", value: "\(bounds.north)"),
            URLQueryItem(name: "south", value: "\(bounds.south)"),
            URLQueryItem(name: "east", value: "\(bounds.east)"),
            URLQueryItem(name: "west", value: "\(bounds.west)"),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName),
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "expanded", value: "false")
        ]
        if let technology, !technology.isEmpty {
            query.append(URLQueryItem(name: "technology", value: technology))
        }
        query.append(contentsOf: Self.bandQueryItems(bands))
        let response: AvailableTile<CoveragePointsResponse> = try await api.request(
            APIEndpoint(path: "/api/coverage/points", query: query, headers: ["Cache-Control": "no-cache"]),
            as: AvailableTile<CoveragePointsResponse>.self, expectedSessionID: owner.sessionID
        )
        return response.value.points
    }

    /// Photos publiques de tous les membres dans la zone (endpoint additif
    /// `/api/map/photos`). Filtre par opérateur DE LA PHOTO ; `friendsOnly`
    /// restreint aux amis (mode « Amis »). Coords résolues côté backend.
    func publicPhotos(bounds: MapBounds, zoom: Double, market: String, operatorName: String, friendsOnly: Bool) async throws -> [MapPublicPhoto] {
        let owner = api.credentials.snapshot()
        let segments = try bounds.canonicalSegments
        var parts: [[MapPublicPhoto]] = []
        for segment in segments {
            guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
            parts.append(try await publicPhotosSegment(bounds: segment, zoom: zoom, market: market, operatorName: operatorName, friendsOnly: friendsOnly, owner: owner))
        }
        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
        return MapSnapshotMerging.unique(parts, id: \.id)
    }

    private func publicPhotosSegment(bounds: MapBounds, zoom: Double, market: String, operatorName: String, friendsOnly: Bool, owner: CredentialStore.Snapshot) async throws -> [MapPublicPhoto] {
        guard zoom.isFinite else { throw MapTilePlanningError.invalidZoom }
        let query = [
            URLQueryItem(name: "north", value: "\(bounds.north)"),
            URLQueryItem(name: "south", value: "\(bounds.south)"),
            URLQueryItem(name: "east", value: "\(bounds.east)"),
            URLQueryItem(name: "west", value: "\(bounds.west)"),
            URLQueryItem(name: "zoom", value: "\(Int(min(20, max(0, floor(zoom)))))"),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName),
            URLQueryItem(name: "friendsOnly", value: friendsOnly ? "1" : "0")
        ]
        let response: MapPublicPhotosResponse = try await api.request(
            APIEndpoint(path: "/api/map/photos", query: query),
            as: MapPublicPhotosResponse.self, expectedSessionID: owner.sessionID
        )
        return response.photos
    }

    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool = true, bands: Set<Int> = []) async throws -> [AndroidAntennaTileResponse] {
        let bandKey = Self.bandCacheKey(bands)
        return try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                // `antennas-v2` : la tuile porte désormais hasEnb/hasGnb et les
                // composants d'adresse. Cette version de clé distingue les
                // anciens contrats ; la purge actuelle vide aussi le disque.
                "antennas-v2:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):az=\(withAzimuth):bands=\(bandKey)"
            },
            endpoint: { tile in
                var query = [
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "operator", value: operatorName),
                    URLQueryItem(name: "withAzimuth", value: withAzimuth ? "true" : "false")
                ]
                query.append(contentsOf: Self.bandQueryItems(bands))
                return APIEndpoint(
                    path: "/api/android/map/tiles/antennas/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: query
                )
            }
        )
    }

    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int = 0, bands: Set<Int> = [], maxAge: TimeInterval? = nil) async throws -> [AndroidSpeedtestTileResponse] {
        // Pagination bornée : les limites restantes restent visibles dans stats.
        // Le plan couvre l'emprise entière en adaptant son niveau avant énumération.
        let tiles = try MapTilePlanner.plan(bounds: bounds, zoom: zoom).tiles
        let owner = api.credentials.snapshot()
        return try await Self.collectTiles(tiles, api: api, owner: owner) { [api, tileCache] tile in
            try await Self.fetchSpeedtestTilePaged(
                api: api, tileCache: tileCache, tile: tile, market: market,
                operatorName: operatorName, days: days, bands: bands, maxAge: maxAge,
                owner: owner
            )
        }
    }

    private static let speedtestPageSize = 5000
    private static let speedtestMaxPages = 4

    private static func fetchSpeedtestTilePaged(
        api: APIClient,
        tileCache: TileCache,
        tile: AndroidMapTile,
        market: String,
        operatorName: String,
        days: Int,
        bands: Set<Int>,
        maxAge: TimeInterval?,
        owner: CredentialStore.Snapshot
    ) async throws -> AndroidSpeedtestTileResponse {
        var merged: [AndroidSpeedtestMarker] = []
        var tileMeta: AndroidMapTile?
        var lastStats: AndroidSpeedtestStats?
        var offset = 0
        for _ in 0..<speedtestMaxPages {
            try Task.checkCancellation()
            guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
            let pageOffset = offset
            let key = "speedtests:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):days=\(days):bands=\(bandCacheKey(bands)):off=\(pageOffset)"
            let data = try await tileCache.data(for: key, maxAge: maxAge, validate: {
                _ = try MapTileAdmission.decode(AndroidSpeedtestTileResponse.self, from: $0, expectedTile: tile)
            }) {
                var query = [
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "operator", value: operatorName),
                    URLQueryItem(name: "days", value: days <= 0 ? "all" : String(days)),
                    URLQueryItem(name: "limit", value: String(speedtestPageSize)),
                    URLQueryItem(name: "offset", value: String(pageOffset))
                ]
                query.append(contentsOf: bandQueryItems(bands))
                return try await api.requestData(
                    APIEndpoint(
                        path: "/api/android/map/tiles/speedtests/\(tile.z)/\(tile.x)/\(tile.y)",
                        query: query,
                        headers: ["Cache-Control": "no-cache"],
                        authenticated: false
                    ), expectedSessionID: owner.sessionID
                )
            }
            let page = try JSONDecoder.signalQuest.decode(AndroidSpeedtestTileResponse.self, from: data)
            tileMeta = page.tile
            lastStats = page.stats
            merged.append(contentsOf: page.markers)
            guard page.stats?.hasMore == true, let next = page.stats?.nextOffset, next > pageOffset else { break }
            offset = next
        }
        guard let tileMeta else { throw APIError.decoding("Missing speedtest tile page") }
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        let remaining = lastStats?.hasMore == true || lastStats?.truncated == true
        return AndroidSpeedtestTileResponse(tile: tileMeta, clusters: [], markers: merged,
            stats: AndroidSpeedtestStats(returnedCount: merged.count, hasMore: remaining,
                                          nextOffset: remaining ? lastStats?.nextOffset : nil, truncated: remaining))
    }

    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int = 0, bands: Set<Int> = [], maxAge: TimeInterval? = nil) async throws -> [AndroidCoverageTileResponse] {
        try await coverageTiles(bounds: bounds, zoom: zoom, market: market, operatorName: operatorName, days: days, bands: bands, maxAge: maxAge, focus: nil)
    }

    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int = 0, bands: Set<Int> = [], maxAge: TimeInterval? = nil, focus: AntennaCoverageFocus?) async throws -> [AndroidCoverageTileResponse] {
        let bandKey = Self.bandCacheKey(bands)
        // Le focus entre dans la CLÉ de cache : sans ça, la couverture isolée
        // d'un site servirait les tuiles déjà en cache pour « tout l'opérateur ».
        let focusKey = focus.map { "|focus=\($0.id)" } ?? ""
        // COV-DENSITY : au DÉZOOM uniquement (z<11), tuiles PLUS FINES (tile.z +1). Le
        // backend plafonne ~2000 pts/tuile ; des tuiles plus petites = moins d'écrêtage
        // = plus de points (trails continus, moins de « sauts »). On limite le boost au
        // dézoom où les tuiles de base sont peu nombreuses : le ×4 reste sous le plafond
        // (pas de troncature = pas de nouveaux trous) et le nombre de requêtes borné.
        // Idem overview : grille plus fine = clusters plus denses.
        let boost = zoom < 11 ? 1 : 0
        return try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            detailBoost: boost,
            maxTiles: boost > 0 ? 40 : 24,
            maxAge: maxAge,
            cacheKey: { tile in
                // Le z fait partie de la clé, donc detail/limit (dérivés du z)
                // sont couverts ; days et bandes doivent être explicites.
                "coverage-bands-v2:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):days=\(days):bands=\(bandKey)\(focusKey)"
            },
            endpoint: { tile in
                var query = [
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "operator", value: operatorName),
                    URLQueryItem(name: "days", value: days <= 0 ? "all" : String(days))
                ]
                query.append(contentsOf: Self.bandQueryItems(bands))
                // Couverture isolée : le backend croise eNB et gNB en OU.
                if let focus { query.append(contentsOf: focus.queryItems) }
                // Points bruts dès le « zoom ville » (z11) ; clusters (overview) en
                // dessous. Seuil iOS uniquement — Android garde sa propre constante (z13).
                if tile.z < CoverageRenderPolicy.rawPointsFromZoom {
                    query.append(URLQueryItem(name: "detail", value: "overview"))
                } else {
                    query.append(URLQueryItem(name: "limit", value: String(CoverageRenderPolicy.pointCapPerTile)))
                }
                return APIEndpoint(
                    path: "/api/android/map/tiles/coverage/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: query,
                    authenticated: false
                )
            },
            validate: { try CoverageRenderPolicy.validate($0, selectedBands: bands) }
        )
    }

    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool, bands: Set<Int> = []) async throws -> [AndroidCommunitySiteTileResponse] {
        let bandKey = Self.bandCacheKey(bands)
        return try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                "community-sites:\(market):\(operatorName):obs\(includeObserved ? 1 : 0):bands=\(bandKey):\(tile.z)/\(tile.x)/\(tile.y)"
            },
            endpoint: { tile in
                var query = [
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "operator", value: operatorName),
                    // Le backend inclut les cellules observées par défaut ;
                    // on ne restreint qu'en envoyant explicitement « false ».
                    URLQueryItem(name: "includeObserved", value: includeObserved ? "true" : "false")
                ]
                query.append(contentsOf: Self.bandQueryItems(bands))
                return APIEndpoint(
                    path: "/api/android/map/tiles/community-sites/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: query
                )
            }
        )
    }

    /// Sites ajoutés à la main par les membres.
    ///
    /// Pas de filtre `bands` ni `includeObserved` : la route n'accepte que
    /// `market` et `operator`. Et pas de garde de marché côté client — c'est la
    /// seule couche d'antennes qui existe là où il n'y a pas d'open data.
    func customSiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String) async throws -> [AndroidCustomSiteTileResponse] {
        try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in "custom-sites:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y)" },
            endpoint: { tile in
                APIEndpoint(
                    path: "/api/android/map/tiles/custom-sites/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: [
                        URLQueryItem(name: "market", value: market),
                        URLQueryItem(name: "operator", value: operatorName)
                    ]
                )
            }
        )
    }

    private func fetchTiles<T: MapTilePayload>(
        bounds: MapBounds,
        zoom: Double,
        detailBoost: Int = 0,
        maxTiles: Int = 24,
        maxAge: TimeInterval? = nil,
        cacheKey: @escaping @Sendable (AndroidMapTile) -> String,
        endpoint: @escaping @Sendable (AndroidMapTile) -> APIEndpoint,
        validate: @escaping @Sendable (T) throws -> Void = { _ in }
    ) async throws -> [T] {
        let tiles = try MapTilePlanner.plan(bounds: bounds, zoom: zoom,
                                             detailBoost: detailBoost, tileBudget: maxTiles).tiles
        let owner = api.credentials.snapshot()
        return try await Self.collectTiles(tiles, api: api, owner: owner) { [api, tileCache] tile in
            let data = try await tileCache.data(for: cacheKey(tile), maxAge: maxAge, validate: {
                let value = try MapTileAdmission.decode(T.self, from: $0, expectedTile: tile)
                try validate(value)
            }) {
                var request = endpoint(tile)
                request.headers["Cache-Control"] = "no-cache"
                return try await api.requestData(request, expectedSessionID: owner.sessionID)
            }
            return try JSONDecoder.signalQuest.decode(T.self, from: data)
        }
    }

    private static func collectTiles<T: MapTilePayload>(
        _ tiles: [AndroidMapTile], api: APIClient, owner: CredentialStore.Snapshot,
        fetch: @escaping @Sendable (AndroidMapTile) async throws -> T
    ) async throws -> [T] {
        try Task.checkCancellation()
        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
        return try await withThrowingTaskGroup(of: (Int, Result<T, Error>).self) { group in
            for (index, tile) in tiles.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
                        let value = try await fetch(tile)
                        try Task.checkCancellation()
                        guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
                        return (index, .success(value))
                    } catch {
                        // Cancellation (including cache invalidation or account
                        // replacement) invalidates the batch, never just one tile.
                        guard !error.isCancellation, !Task.isCancelled,
                              api.credentials.isCurrent(owner) else { throw APIError.cancelled }
                        return (index, .failure(error))
                    }
                }
            }
            var results: [(Int, Result<T, Error>)] = []
            for try await result in group { results.append(result) }
            try Task.checkCancellation()
            guard api.credentials.isCurrent(owner) else { throw APIError.cancelled }
            var successful: [T] = []
            var failed: [AndroidMapTile] = []
            var firstError: Error?
            for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
                switch result {
                case .success(let value): successful.append(value)
                case .failure(let error):
                    failed.append(tiles[index])
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw MapTileBatchFailure(requestedTiles: tiles, successfulTiles: successful,
                                          failedTiles: failed, cause: firstError)
            }
            return successful
        }
    }

    /// Supprime les tuiles persistées et invalide les réponses antérieures.
    /// Utilisé après une mutation de visibilité ou un changement de contrat.
    func invalidateTiles() async {
        async let tiles: Void = tileCache.removeAll()
        async let social: Void = socialCache.removeAll()
        _ = await (tiles, social)
    }

    private struct AvailableTile<Value: Decodable>: Decodable {
        let value: Value
        private enum CodingKeys: String, CodingKey { case degraded }
        init(from decoder: Decoder) throws {
            let flags = try decoder.container(keyedBy: CodingKeys.self)
            if try flags.decodeIfPresent(Bool.self, forKey: .degraded) == true {
                throw APIError.http(status: 503, code: "DATABASE_UNAVAILABLE",
                    message: "Données cartographiques temporairement indisponibles", requestId: nil, retryAfter: 15)
            }
            value = try Value(from: decoder)
        }
    }

    private static func bandQueryItems(_ bands: Set<Int>) -> [URLQueryItem] {
        let values = bands.sorted()
        guard !values.isEmpty else { return [] }
        let bandValue = values.map(String.init).joined(separator: ",")
        var items = [
            URLQueryItem(name: "bands", value: bandValue),
            URLQueryItem(name: "band", value: bandValue),
            URLQueryItem(name: "frequencyBands", value: bandValue)
        ]
        let frequencyValue = values.compactMap(frequencyMHz(forBand:)).map(String.init).joined(separator: ",")
        if !frequencyValue.isEmpty {
            items.append(URLQueryItem(name: "frequencies", value: frequencyValue))
            items.append(URLQueryItem(name: "frequency", value: frequencyValue))
        }
        return items
    }

    private static func bandCacheKey(_ bands: Set<Int>) -> String {
        bands.isEmpty ? "all" : bands.sorted().map(String.init).joined(separator: "-")
    }

    private static func frequencyMHz(forBand band: Int) -> Int? {
        switch band {
        case 1: return 2100
        case 3: return 1800
        case 7: return 2600
        case 20: return 800
        case 28: return 700
        case 78: return 3500
        default: return nil
        }
    }


}

extension SocialMapSnapshot {
    func displayItems(include filters: Set<MapDisplayItem.Kind>) -> [MapDisplayItem] {
        var items: [MapDisplayItem] = []
        if filters.contains(.friend) {
            items += friends.compactMap { friend in
                guard let location = friend.location else { return nil }
                return MapDisplayItem(
                    id: "friend-\(friend.id)",
                    kind: .friend,
                    title: friend.name ?? "Ami",
                    subtitle: friend.radio?.technology ?? friend.presence?.status ?? "Presence",
                    coordinate: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng),
                    metric: friend.radio?.operator
                )
            }
        }
        if filters.contains(.photo) {
            items += photos.compactMap { photo in
                guard let lat = photo.lat, let lng = photo.lng else { return nil }
                return MapDisplayItem(id: "photo-\(photo.id)", kind: .photo, title: "Photo", subtitle: photo.siteId ?? "Site", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), metric: nil)
            }
        }
        if filters.contains(.speedtest) {
            items += speedtests.compactMap { speedtest in
                guard let lat = speedtest.latitude, let lng = speedtest.longitude else { return nil }
                return MapDisplayItem(id: "speed-\(speedtest.id)", kind: .speedtest, title: "\(Int(speedtest.averageSpeed)) Mbps", subtitle: speedtest.mobileOperator ?? speedtest.networkType ?? "Speedtest", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), metric: speedtest.uploadAvg.map { "\(Int($0)) up" })
            }
        }
        if filters.contains(.coverage) {
            items += coveragePoints.map { point in
                MapDisplayItem(id: "coverage-\(point.id)", kind: .coverage, title: point.technology ?? "Couverture", subtitle: point.rsrp.map { "\(Int($0)) dBm" } ?? "Signal serveur", coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng), metric: point.band.map { "B\($0)" })
            }
        }
        if filters.contains(.validation) {
            items += validations.compactMap { validation in
                guard let lat = validation.lat, let lng = validation.lng else { return nil }
                return MapDisplayItem(id: "validation-\(validation.id)", kind: .validation, title: validation.value ?? "Validation", subtitle: validation.operator ?? validation.siteId ?? "Site", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), metric: validation.type)
            }
        }
        if filters.contains(.session) {
            items += sessions.compactMap { session in
                guard let lat = session.lat, let lng = session.lng else { return nil }
                return MapDisplayItem(id: "session-\(session.id)", kind: .session, title: session.isActive == true ? "Session active" : "Session", subtitle: "\(session.totalPoints ?? 0) points", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), metric: session.technologiesDetected.first)
            }
        }
        return items
    }

    static let empty = SocialMapSnapshot(
        timestamp: Date(),
        friends: [],
        photos: [],
        validations: [],
        sessions: [],
        coveragePoints: [],
        speedtests: [],
        photosCount: 0,
        validationsCount: 0,
        sessionsCount: 0,
        coveragePointsCount: 0,
        speedtestsCount: 0,
        rawCoveragePointsCount: 0,
        logicalCoveragePointsCount: 0
    )

    static let demo = SocialMapSnapshot(
        timestamp: Date(),
        friends: [],
        photos: [],
        validations: [],
        sessions: [],
        coveragePoints: [],
        speedtests: [
            SocialSpeedtestLive(id: "demo-speed-1", userId: nil, latitude: 48.8566, longitude: 2.3522, averageSpeed: 412, uploadAvg: 64, pingAvg: 18, timestamp: Date(), networkType: "CELLULAR", mobileOperator: "SignalQuest"),
            SocialSpeedtestLive(id: "demo-speed-2", userId: nil, latitude: 48.8666, longitude: 2.3422, averageSpeed: 228, uploadAvg: 42, pingAvg: 24, timestamp: Date(), networkType: "WIFI", mobileOperator: "iOS demo")
        ],
        photosCount: 0,
        validationsCount: 0,
        sessionsCount: 0,
        coveragePointsCount: 0,
        speedtestsCount: 2,
        rawCoveragePointsCount: 0,
        logicalCoveragePointsCount: 0
    )
}

extension MapSnapshotServicing {
    func plannedSitesLayer(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> MapFeedResult<PlannedSiteLive> {
        MapFeedResult(sites: try await plannedSites(market: market, operatorName: operatorName, territory: territory, bands: bands))
    }
    func outageSitesLayer(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> MapFeedResult<OutageSiteLive> {
        MapFeedResult(sites: try await outageSites(market: market, operatorName: operatorName, territory: territory, bands: bands))
    }
}
