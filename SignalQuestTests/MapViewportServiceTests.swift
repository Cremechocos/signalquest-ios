import XCTest
import MapKit
@testable import SignalQuest

@MainActor
final class MapViewportServiceTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func makeService(credentials providedCredentials: CredentialStore? = nil,
                             onFirstResponse: @escaping @Sendable () -> Void = {}) throws -> (MapSnapshotService, MapViewportHTTPFixture, CredentialStore) {
        let credentials = providedCredentials ?? CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-map-owner")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config))
        let name = "MapViewportServiceTests-\(UUID())"
        let disk = DiskCache(folderName: name)
        folders.append(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name))
        let fixture = MapViewportHTTPFixture(onFirstResponse: onFirstResponse)
        MockURLProtocol.requestHandler = fixture.response
        return (MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0)), fixture, credentials)
    }

    func testGuestMapSkipsPrivateSnapshotAndContinuesLoadingPublicTiles() async throws {
        let (service, fixture, credentials) = try makeService()
        credentials.clearAccessToken()
        let bounds = MapBounds(north: 48.8568, south: 48.8564, east: 2.3524, west: 2.3520)
        let snapshot = try await service.snapshot(bounds: bounds, zoom: 14)
        XCTAssertTrue(snapshot.friends.isEmpty)
        XCTAssertEqual(snapshot.sessionsCount, 0)
        XCTAssertTrue(fixture.requests.isEmpty, "A guest must not hit private snapshot or auth refresh")
        let tiles = try await service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
        XCTAssertFalse(tiles.flatMap(\.markers).isEmpty)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.path.contains("/tiles/speedtests/") })
    }

    func testLogoutDoesNotReuseThePreviousPrivateSnapshotOrRequestAFriendsFallback() async throws {
        let (service, fixture, credentials) = try makeService()
        let bounds = MapBounds(north: 2, south: 1, east: 2, west: 1)
        let signedIn = try await service.snapshot(bounds: bounds, zoom: 8)
        XCTAssertEqual(signedIn.photosCount, 7)
        let calls = fixture.requests.count
        credentials.clearAccessToken()
        let signedOut = try await service.snapshot(bounds: bounds, zoom: 8)
        let friends = try await service.friendsSnapshot()
        XCTAssertEqual(signedOut.photosCount, 0)
        XCTAssertTrue(friends.isEmpty)
        XCTAssertEqual(fixture.requests.count, calls)
    }

    func testUnverifiedBandOverviewIsRejectedAndCanRecoverWithAnExactFilter() async throws {
        let (service, fixture, _) = try makeService()
        let bounds = MapBounds(north: 50.51, south: 50.49, east: 4.41, west: 4.39)
        fixture.coverageProof = .missing
        do {
            _ = try await service.coverageTiles(bounds: bounds, zoom: 8, market: "BE", operatorName: "ORANGE", bands: [7])
            XCTFail("A legacy overview does not establish that the requested band was filtered")
        } catch {}
        fixture.coverageProof = .matching
        let tiles = try await service.coverageTiles(bounds: bounds, zoom: 8, market: "BE", operatorName: "ORANGE", bands: [7])
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { CoverageRenderPolicy.mode(for: $0, selectedBands: [7]).useClusters })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.query["market"] == "BE" && $0.query["bands"] == "7" })
        fixture.coverageProof = .wrong
        do {
            _ = try await service.coverageTiles(bounds: bounds, zoom: 8, market: "BE", operatorName: "ORANGE", bands: [7], maxAge: 0)
            XCTFail("A proof for a different band must not be admitted")
        } catch {}
    }

    func testNearbyDifferentViewportsDoNotReuseAnotherSocialSnapshot() async throws {
        let (service, fixture, _) = try makeService()
        let first = MapBounds(north: 48.859, south: 48.851, east: 2.359, west: 2.351)
        let shifted = MapBounds(north: 48.8595, south: 48.8515, east: 2.3595, west: 2.3515)
        _ = try await service.snapshot(bounds: first, zoom: 14)
        _ = try await service.snapshot(bounds: shifted, zoom: 14)
        XCTAssertEqual(fixture.requests.count, 2, "Distinct viewports must not share a rounded cache key")
        XCTAssertEqual(fixture.requests.last?.query["west"], "2.3515")
    }

    func testSpeedtestServiceUsesEveryPlannedTileAtTheReducedZoomInStableOrder() async throws {
        let (service, fixture, _) = try makeService()
        let bounds = MapBounds(north: 48.95, south: 48.75, east: 2.55, west: 2.15)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 14)
        let tiles = try await service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
        XCTAssertEqual(tiles.map(\.tile), plan.tiles)
        XCTAssertEqual(fixture.requests.count, plan.tiles.count)
        XCTAssertLessThanOrEqual(tiles.count, 24)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.query["operator"] == "SFR" && $0.cacheControl == "no-cache" })
        XCTAssertTrue(tiles.allSatisfy { $0.stats?.hasMore == false })
    }

    func testCoverageOverviewFollowsTheChosenTileZoomRatherThanTheCameraZoom() async throws {
        let (service, fixture, _) = try makeService()
        let bounds = MapBounds(north: 85, south: -85, east: 180, west: -180)
        let tiles = try await service.coverageTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
        XCTAssertEqual(tiles.count, 16)
        XCTAssertTrue(tiles.allSatisfy { $0.tile.z == 2 })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.query["detail"] == "overview" })
    }

    func testWrongTileIdentityIsRejectedAndCanRecoverWithoutRecreatingTheService() async throws {
        let (service, fixture, _) = try makeService()
        let bounds = MapBounds(north: 48.8568, south: 48.8564, east: 2.3524, west: 2.3520)
        fixture.wrongTile = true
        do {
            _ = try await service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
            XCTFail("Unexpected identity must not become cached map data")
        } catch {}
        fixture.wrongTile = false
        let recovered = try await service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
        XCTAssertEqual(recovered.map(\.tile), try MapTilePlanner.plan(bounds: bounds, zoom: 14).tiles)
    }

    func testRESTAndSocialRequestsSplitTheAntimeridianWithoutDoublingGlobalCounts() async throws {
        let (service, fixture, _) = try makeService()
        let bounds = MapBounds(north: 2, south: -2, east: 181, west: 179)
        let snapshot = try await service.snapshot(bounds: bounds, zoom: 8)
        XCTAssertEqual(snapshot.photosCount, 8)
        XCTAssertEqual(snapshot.validationsCount, 8)
        XCTAssertEqual(snapshot.sessionsCount, 8)
        XCTAssertEqual(snapshot.coveragePointsCount, 6)
        XCTAssertEqual(snapshot.speedtestsCount, 8)
        let photos = try await service.publicPhotos(bounds: bounds, zoom: 8, market: "FR", operatorName: "ALL", friendsOnly: false)
        XCTAssertEqual(Set(photos.map(\.id)), ["east", "west"])
        let coverage = try await service.coveragePoints(bounds: bounds, market: "FR", operatorName: "SFR", technology: nil)
        XCTAssertEqual(Set(coverage.map(\.id)), ["east", "west"])
        XCTAssertEqual(fixture.requests.count, 6)
        for request in fixture.requests {
            let west = try XCTUnwrap(request.query["west"].flatMap(Double.init))
            let east = try XCTUnwrap(request.query["east"].flatMap(Double.init))
            XCTAssertLessThanOrEqual(west, east)
            XCTAssertGreaterThanOrEqual(west, -180)
            XCTAssertLessThanOrEqual(east, 180)
            XCTAssertLessThanOrEqual(east - west, 1)
        }
    }

    func testAccountChangeStopsTheSecondSocialSegmentAndDiscardsTheFirst() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let (service, fixture, _) = try makeService(credentials: credentials, onFirstResponse: {
            try? credentials.setAccessToken("synthetic-other-owner")
        })
        do {
            _ = try await service.snapshot(bounds: MapBounds(north: 2, south: -2, east: 181, west: 179), zoom: 8)
            XCTFail("A snapshot crossed account scopes")
        } catch { XCTAssertTrue(error.isCancellation) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testFailedSecondRESTSegmentIsNotReturnedAsACompleteHalfViewport() async throws {
        let (service, fixture, _) = try makeService()
        fixture.failWesternREST = true
        let bounds = MapBounds(north: 2, south: -2, east: 181, west: 179)
        do {
            _ = try await service.publicPhotos(bounds: bounds, zoom: 8, market: "FR", operatorName: "ALL", friendsOnly: false)
            XCTFail("A failed half must not become a successful viewport")
        } catch {
            guard case let APIError.http(status, _, _, _, _) = error else { return XCTFail("Expected HTTP unavailable state") }
            XCTAssertEqual(status, 503)
        }
        fixture.failWesternREST = false
        let photos = try await service.publicPhotos(bounds: bounds, zoom: 8, market: "FR", operatorName: "ALL", friendsOnly: false)
        XCTAssertEqual(Set(photos.map(\.id)), ["east", "west"])
    }

    func testInvalidTileViewportCannotReturnAnEmptySuccessOrStartTheNetwork() async throws {
        let (service, fixture, _) = try makeService()
        do {
            _ = try await service.speedtestTiles(bounds: MapBounds(north: .nan, south: 0, east: 1, west: 0), zoom: 14, market: "FR", operatorName: "SFR")
            XCTFail("Invalid geometry must not complete as an empty tile array")
        } catch {
            XCTAssertEqual(error as? MapTilePlanningError, .invalidBounds)
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }
}

private final class MapViewportHTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let query: [String: String]
        let cacheControl: String?
    }
    enum CoverageProof { case missing, matching, wrong }
    private var proof: CoverageProof = .missing
    var coverageProof: CoverageProof {
        get { lock.withLock { proof } }
        set { lock.withLock { proof = newValue } }
    }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var incorrectIdentity = false
    private var failsWesternREST = false
    private let onFirstResponse: @Sendable () -> Void
    init(onFirstResponse: @escaping @Sendable () -> Void) { self.onFirstResponse = onFirstResponse }
    var requests: [Request] { lock.withLock { recorded } }
    var failWesternREST: Bool {
        get { lock.withLock { failsWesternREST } }
        set { lock.withLock { failsWesternREST = newValue } }
    }
    var wrongTile: Bool {
        get { lock.withLock { incorrectIdentity } }
        set { lock.withLock { incorrectIdentity = newValue } }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        let (wrong, first) = lock.withLock {
            recorded.append(Request(path: url.path, query: query, cacheControl: request.value(forHTTPHeaderField: "Cache-Control")))
            return (incorrectIdentity, recorded.count == 1)
        }
        if url.path == "/api/social/map/snapshot", request.value(forHTTPHeaderField: "Cookie") == nil {
            return (HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!,
                    Data(#"{"error":"Unauthorized","code":"UNAUTHORIZED"}"#.utf8))
        }
        if failWesternREST && !url.path.contains("/tiles/") && (query["west"].flatMap(Double.init) ?? 0) < 0 {
            return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                    headerFields: ["Cache-Control": "no-store", "Retry-After": "15"])!,
                    Data(#"{"code":"DATABASE_UNAVAILABLE","error":"Synthetic unavailable segment"}"#.utf8))
        }
        var body: [String: Any]
        if url.path.contains("/tiles/") {
            let coordinates = url.path.split(separator: "/").suffix(3).compactMap { Int($0) }
            guard coordinates.count == 3 else { throw URLError(.badURL) }
            let z = coordinates[0], x = coordinates[1], y = coordinates[2]
            let scale = Double(1 << z)
            let location = MKMapPoint(x: (Double(x) + 0.5) * MKMapRect.world.width / scale,
                                      y: (Double(y) + 0.5) * MKMapRect.world.height / scale).coordinate
            body = ["tile": ["z": z, "x": wrong ? x + 1 : x, "y": y], "clusters": []]
            if url.path.contains("/coverage/") {
                body["points"] = []
                body["stats"] = ["sampleCount": 0, "representation": query["detail"] ?? "points", "hasMore": false]
                if query["bands"] != nil {
                    body["clusters"] = [["id": "coverage-\(x)-\(y)", "lat": location.latitude, "lng": location.longitude,
                                         "count": 1, "tech": "4G", "avgRsrp": -90]]
                    var stats: [String: Any] = ["sampleCount": 1, "representation": "overview", "hasMore": false]
                    if coverageProof != .missing {
                        stats["appliedBandFilter"] = ["version": 1, "bands": coverageProof == .matching ? [7] : [3], "match": "any"]
                    }
                    body["stats"] = stats
                }
            } else {
                body["markers"] = [["id": "\(z)-\(x)-\(y)", "lat": location.latitude, "lng": location.longitude, "downloadMbps": 100]]
                body["stats"] = ["returnedCount": 1, "hasMore": false, "truncated": false]
            }
        } else {
            let east = (query["west"].flatMap(Double.init) ?? 0) >= 0
            let id = east ? "east" : "west"
            let longitude = east ? 179.5 : -179.5
            if url.path == "/api/social/map/snapshot" {
                body = ["friends": [], "photos": [], "validations": [], "sessions": [], "coveragePoints": [], "speedtests": [],
                        "photosCount": east ? 7 : 8, "validationsCount": east ? 7 : 8, "sessionsCount": east ? 7 : 8,
                        "coveragePointsCount": east ? 2 : 4, "speedtestsCount": east ? 3 : 5]
            } else if url.path == "/api/map/photos" {
                body = ["photos": [["id": id, "lat": 0, "lng": longitude, "isFriend": false]]]
            } else if url.path == "/api/coverage/points" {
                body = ["points": [["id": id, "latitude": 0, "longitude": longitude, "technology": "4G"]]]
            } else { throw URLError(.unsupportedURL) }
        }
        if first { onFirstResponse() }
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!,
                try JSONSerialization.data(withJSONObject: body))
    }
}
