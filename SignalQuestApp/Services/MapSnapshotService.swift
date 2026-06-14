import Foundation
import CoreLocation

protocol MapSnapshotServicing: Sendable {
    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool) async throws -> SocialMapSnapshot
    func plannedSites(market: String, operatorName: String, territory: String?) async throws -> [PlannedSiteLive]
    func outageSites(market: String, operatorName: String, territory: String?) async throws -> [OutageSiteLive]
    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?) async throws -> [CoverageHeatPoint]
    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool) async throws -> [AndroidAntennaTileResponse]
    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int) async throws -> [AndroidSpeedtestTileResponse]
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int) async throws -> [AndroidCoverageTileResponse]
    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool) async throws -> [AndroidCommunitySiteTileResponse]
}

struct MapBounds: Equatable, Sendable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double
}

final class MapSnapshotService: MapSnapshotServicing {
    private let api: APIClient
    private let cache: DiskCache
    private let tileCache: TileCache

    init(api: APIClient, cache: DiskCache = DiskCache(), tileCache: TileCache = TileCache()) {
        self.api = api
        self.cache = cache
        self.tileCache = tileCache
    }

    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool = true) async throws -> SocialMapSnapshot {
        let key = "social-map-\(Int(bounds.north * 100))-\(Int(bounds.south * 100))-\(Int(bounds.east * 100))-\(Int(bounds.west * 100))-\(Int(zoom))-\(lightweight)"
        if let cached = try await cache.read(SocialMapSnapshot.self, for: key, maxAge: 30) {
            return cached
        }
        let snapshot: SocialMapSnapshot = try await api.request(
            APIEndpoint(
                path: "/api/social/map/snapshot",
                query: [
                    URLQueryItem(name: "north", value: "\(bounds.north)"),
                    URLQueryItem(name: "south", value: "\(bounds.south)"),
                    URLQueryItem(name: "east", value: "\(bounds.east)"),
                    URLQueryItem(name: "west", value: "\(bounds.west)"),
                    URLQueryItem(name: "zoom", value: "\(zoom)"),
                    URLQueryItem(name: "lightweight", value: lightweight ? "1" : "0")
                ]
            ),
            as: SocialMapSnapshot.self
        )
        try? await cache.write(snapshot, for: key)
        return snapshot
    }

    func plannedSites(market: String, operatorName: String, territory: String? = nil) async throws -> [PlannedSiteLive] {
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName)
        ]
        if let territory, !territory.isEmpty {
            query.append(URLQueryItem(name: "territory", value: territory))
        }
        let response: PlannedSitesResponse = try await api.request(
            APIEndpoint(path: "/api/map/planned-sites", query: query),
            as: PlannedSitesResponse.self
        )
        return response.sites
    }

    func outageSites(market: String, operatorName: String, territory: String? = nil) async throws -> [OutageSiteLive] {
        // En France, le backend ne supporte pas « ALL » pour les incidents : on
        // agrège SFR + Bouygues. Les autres marchés (DROM, CA) acceptent ALL.
        if operatorName == "ALL" && market == "FR" {
            async let sfr = outageSites(market: market, operatorName: "SFR")
            async let bouygues = outageSites(market: market, operatorName: "BOUYGUES")
            return ((try? await sfr) ?? []) + ((try? await bouygues) ?? [])
        }
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName)
        ]
        if let territory, !territory.isEmpty {
            query.append(URLQueryItem(name: "territory", value: territory))
        }
        let response: OutageSitesResponse = try await api.request(
            APIEndpoint(path: "/api/sites-hs", query: query),
            as: OutageSitesResponse.self
        )
        return response.sites
    }

    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?) async throws -> [CoverageHeatPoint] {
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
        let response: CoveragePointsResponse = try await api.request(
            APIEndpoint(path: "/api/coverage/points", query: query),
            as: CoveragePointsResponse.self
        )
        return response.points
    }

    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool = true) async throws -> [AndroidAntennaTileResponse] {
        try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                "antennas:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):az=\(withAzimuth)"
            },
            endpoint: { tile in
                APIEndpoint(
                    path: "/api/android/map/tiles/antennas/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: [
                        URLQueryItem(name: "market", value: market),
                        URLQueryItem(name: "operator", value: operatorName),
                        URLQueryItem(name: "withAzimuth", value: withAzimuth ? "true" : "false")
                    ]
                )
            }
        )
    }

    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int = 0) async throws -> [AndroidSpeedtestTileResponse] {
        try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                "speedtests:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):days=\(days)"
            },
            endpoint: { tile in
                APIEndpoint(
                    path: "/api/android/map/tiles/speedtests/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: [
                        URLQueryItem(name: "market", value: market),
                        URLQueryItem(name: "operator", value: operatorName),
                        URLQueryItem(name: "days", value: days <= 0 ? "all" : String(days))
                    ],
                    authenticated: false
                )
            }
        )
    }

    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int = 0) async throws -> [AndroidCoverageTileResponse] {
        try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                // Le z fait partie de la clé, donc detail/limit (dérivés du z)
                // sont couverts ; seul days doit être explicité.
                "coverage:\(market):\(operatorName):\(tile.z)/\(tile.x)/\(tile.y):days=\(days)"
            },
            endpoint: { tile in
                var query = [
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "operator", value: operatorName),
                    URLQueryItem(name: "days", value: days <= 0 ? "all" : String(days))
                ]
                if tile.z < 13 {
                    query.append(URLQueryItem(name: "detail", value: "overview"))
                } else {
                    query.append(URLQueryItem(name: "limit", value: "2500"))
                }
                return APIEndpoint(
                    path: "/api/android/map/tiles/coverage/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: query,
                    authenticated: false
                )
            }
        )
    }

    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool) async throws -> [AndroidCommunitySiteTileResponse] {
        try await fetchTiles(
            bounds: bounds,
            zoom: zoom,
            cacheKey: { tile in
                "community-sites:\(market):\(operatorName):obs\(includeObserved ? 1 : 0):\(tile.z)/\(tile.x)/\(tile.y)"
            },
            endpoint: { tile in
                APIEndpoint(
                    path: "/api/android/map/tiles/community-sites/\(tile.z)/\(tile.x)/\(tile.y)",
                    query: [
                        URLQueryItem(name: "market", value: market),
                        URLQueryItem(name: "operator", value: operatorName),
                        // Le backend inclut les cellules observées par défaut ;
                        // on ne restreint qu'en envoyant explicitement « false ».
                        URLQueryItem(name: "includeObserved", value: includeObserved ? "true" : "false")
                    ]
                )
            }
        )
    }

    private func fetchTiles<T: Decodable & Sendable>(
        bounds: MapBounds,
        zoom: Double,
        cacheKey: @escaping @Sendable (AndroidMapTile) -> String,
        endpoint: @escaping @Sendable (AndroidMapTile) -> APIEndpoint
    ) async throws -> [T] {
        let tiles = Self.visibleTiles(bounds: bounds, zoom: zoom)
        guard !tiles.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: T.self) { group in
            for tile in tiles {
                group.addTask { [api, tileCache] in
                    let data = try await tileCache.data(for: cacheKey(tile)) {
                        try await api.requestData(endpoint(tile))
                    }
                    return try JSONDecoder.signalQuest.decode(T.self, from: data)
                }
            }
            var responses: [T] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }
    }

    private static func visibleTiles(bounds: MapBounds, zoom: Double) -> [AndroidMapTile] {
        let z = min(16, max(4, Int(zoom.rounded(.down))))
        let north = min(85.05112878, max(-85.05112878, bounds.north))
        let south = min(85.05112878, max(-85.05112878, bounds.south))
        let west = min(180, max(-180, bounds.west))
        let east = min(180, max(-180, bounds.east))
        let topLeft = tileXY(lat: north, lon: west, z: z)
        let bottomRight = tileXY(lat: south, lon: east, z: z)
        let minX = min(topLeft.x, bottomRight.x)
        let maxX = max(topLeft.x, bottomRight.x)
        let minY = min(topLeft.y, bottomRight.y)
        let maxY = max(topLeft.y, bottomRight.y)
        let maxTileCount = 24
        var tiles: [AndroidMapTile] = []
        for x in minX...maxX {
            for y in minY...maxY {
                tiles.append(AndroidMapTile(z: z, x: x, y: y))
                if tiles.count >= maxTileCount { return tiles }
            }
        }
        return tiles
    }

    private static func tileXY(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(z))
        let latRad = lat * .pi / 180
        let x = Int(((lon + 180.0) / 360.0 * n).rounded(.down))
        let y = Int(((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n).rounded(.down))
        let maxIndex = Int(n) - 1
        return (min(max(x, 0), maxIndex), min(max(y, 0), maxIndex))
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
