import XCTest
import MapKit
@testable import SignalQuest

@MainActor
final class MapFeedAvailabilityTests: XCTestCase {
    func testTwoOperatorSourcesCanUseTheSameSiteCodeWithoutLosingAMapIdentity() throws {
        let body = Data(#"{"sites":[{"sourceId":"sfr-feed","operator":"SFR","code_site_op":"42","lat":48.8,"lon":2.3},{"sourceId":"orange-feed","operator":"ORANGE","code_site_op":"42","lat":48.81,"lon":2.31}]}"#.utf8)
        let response = try JSONDecoder.signalQuest.decode(OutageSitesResponse.self, from: body)
        XCTAssertEqual(Set(response.sites.map(\.id)).count, 2, "Map annotations and sheet identities must distinguish their sources")
        XCTAssertEqual(response.sites.map(\.siteId), ["42", "42"], "The raw operator site reference must stay usable")
    }

    func testSourceFailureKeepsDataPartialAddsSuccessAndOnlyTrueEmptyClears() async throws {
        let fixture = FeedAvailabilityHTTPFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: config))
        let folder = "MapFeedAvailabilityTests-\(UUID())"
        let disk = DiskCache(folderName: folder)
        let map = MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0),
                                     feedCacheTTL: 0)
        let model = MapExplorerViewModel(map: map, antennas: AntennasService(api: api), markets: MarketRegistryService(api: api),
                                        communityOutages: CommunityOutageService(api: api))
        model.marketFilter = "FR"; model.operatorFilter = "SFR"
        MockURLProtocol.requestHandler = fixture.response
        defer {
            MockURLProtocol.requestHandler = nil
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(folder))
        }
        let bounds = MapBounds(north: 48.86, south: 48.85, east: 2.36, west: 2.35)
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertEqual(model.plannedSites.map(\.id), ["old-planned"])
        XCTAssertEqual(model.outages.map(\.id), ["old-outage"])
        fixture.phase = .failure
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertEqual(model.plannedSites.map(\.id), ["old-planned"])
        XCTAssertEqual(model.outages.map(\.id), ["old-outage"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasCurrentResponse)
        XCTAssertFalse(model.errorMessage?.contains("private upstream detail") == true)
        fixture.phase = .partial
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertEqual(Set(model.plannedSites.map(\.id)), ["old-planned", "new-planned"])
        XCTAssertEqual(Set(model.outages.map(\.id)), ["old-outage", "new-outage"])
        XCTAssertNotNil(model.errorMessage)
        fixture.phase = .empty
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertTrue(model.plannedSites.isEmpty)
        XCTAssertTrue(model.outages.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasCurrentResponse)
        fixture.phase = .unavailable
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertFalse(model.hasCurrentResponse, "No verified source is different from a verified empty feed")
        XCTAssertFalse(model.displayLimitMessages.isEmpty)
        XCTAssertNil(model.errorMessage, "An unsupported source is information, not a transient failure")
    }
    func testHealthySourceCanClearItsResolvedSitesWhileAnotherSourceFails() async throws {
        let fixture = FeedAvailabilityHTTPFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: config))
        let folder = "MapFeedAvailabilityTests-\(UUID())"
        let disk = DiskCache(folderName: folder)
        let map = MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0),
                                     feedCacheTTL: 0)
        let model = MapExplorerViewModel(map: map, antennas: AntennasService(api: api), markets: MarketRegistryService(api: api),
                                        communityOutages: CommunityOutageService(api: api))
        model.marketFilter = "FR"; model.operatorFilter = "SFR"
        MockURLProtocol.requestHandler = fixture.response
        defer {
            MockURLProtocol.requestHandler = nil
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(folder))
        }
        let bounds = MapBounds(north: 48.86, south: 48.85, east: 2.36, west: 2.35)
        model.operatorFilter = "ALL"
        fixture.phase = .twoSources
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertEqual(model.plannedSites.count, 2)
        XCTAssertEqual(model.outages.count, 2)
        fixture.phase = .resolvedPeerFailed
        await model.load(bounds: bounds, zoom: 14, filters: [.planned, .outage])
        XCTAssertEqual(model.plannedSites.map(\.id), ["orange-planned"])
        XCTAssertEqual(model.outages.map(\.sourceId), ["orange-feed"])
        XCTAssertNotNil(model.errorMessage)
    }

    /// Audit perf du 21/11 : la liste des pannes du marché entier était
    /// retéléchargée à chaque déplacement de carte (115,8 Kio, 21 fois en 7 min).
    func testCompleteMarketFeedsAreReusedUntilAForcedReloadAndIncompleteOnesAreNot() async throws {
        let fixture = FeedAvailabilityHTTPFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: config))
        let folder = "MapFeedAvailabilityTests-\(UUID())"
        let disk = DiskCache(folderName: folder)
        let map = MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0))
        MockURLProtocol.requestHandler = fixture.response
        defer {
            MockURLProtocol.requestHandler = nil
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(folder))
        }
        let incidents = "/api/android/map/incidents", planned = "/api/map/planned-sites"
        for _ in 0..<2 {
            let outages = try await map.outageSitesLayer(market: "FR", operatorName: "SFR")
            let plans = try await map.plannedSitesLayer(market: "FR", operatorName: "SFR")
            XCTAssertEqual(outages.sites.map(\.id), ["old-outage"])
            XCTAssertEqual(plans.sites.map(\.id), ["old-planned"])
        }
        XCTAssertEqual(fixture.requestCount(incidents), 1, "A second pan must reuse the market-wide list")
        XCTAssertEqual(fixture.requestCount(planned), 1)
        _ = try await map.outageSitesLayer(market: "FR", operatorName: "ORANGE")
        XCTAssertEqual(fixture.requestCount(incidents), 2, "Another operator is another list")

        await map.invalidateTiles()
        fixture.phase = .partial
        for _ in 0..<2 { _ = try await map.outageSitesLayer(market: "FR", operatorName: "SFR") }
        XCTAssertEqual(fixture.requestCount(incidents), 4, "A forced reload refetches, and a partial list is asked again next time")
        fixture.phase = .complete
        _ = try await map.outageSitesLayer(market: "FR", operatorName: "SFR")
        _ = try await map.outageSitesLayer(market: "FR", operatorName: "SFR")
        XCTAssertEqual(fixture.requestCount(incidents), 5)
    }
}

private final class FeedAvailabilityHTTPFixture: @unchecked Sendable {
    enum Phase { case complete, failure, partial, empty, unavailable, twoSources, resolvedPeerFailed }
    private let lock = NSLock()
    private var current: Phase = .complete
    var phase: Phase {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    private var counts: [String: Int] = [:]
    func requestCount(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        lock.withLock { counts[url.path, default: 0] += 1 }
        let state = phase
        var body: [String: Any]
        if url.path == "/api/community-outages" { body = ["outages": []] }
        else {
            guard url.path == "/api/map/planned-sites" || url.path == "/api/android/map/incidents" else {
                throw URLError(.unsupportedURL)
            }
            let suffix = url.path.contains("planned") ? "planned" : "outage"
            let id = (state == .partial ? "new-" : "old-") + suffix
            let sites: [[String: Any]] = state == .complete || state == .partial
                ? [["id": id, "plannedKey": id, "operator": "SFR", "lat": 48.8566, "lon": 2.3522]] : []
            body = ["sites": sites, "available": state != .failure && state != .unavailable,
                    "sourceErrors": state == .failure || state == .partial
                        ? [["source": ["id": "fixture-feed", "operator": "SFR"], "error": "private upstream detail"]] : [],
                    "unavailableSources": state == .unavailable ? [["id": "fixture-feed", "operator": "SFR"]] : []]
            if state == .twoSources || state == .resolvedPeerFailed {
                let rows: [[String: Any]] = state == .twoSources ? [
                    ["id": "sfr-" + suffix, "plannedKey": "sfr-" + suffix, "sourceId": "sfr-feed", "operator": "SFR", "lat": 48.8566, "lon": 2.3522],
                    ["id": "orange-" + suffix, "plannedKey": "orange-" + suffix, "sourceId": "orange-feed", "operator": "ORANGE", "lat": 48.8566, "lon": 2.3522]
                ] : []
                body = ["sites": rows, "available": true,
                        "sources": state == .twoSources ? [["id": "sfr-feed"], ["id": "orange-feed"]] : [["id": "sfr-feed"]],
                        "sourceErrors": state == .resolvedPeerFailed ? [["source": ["id": "orange-feed"], "error": "private upstream detail"]] : []]
            }
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Cache-Control": "no-store"]))
        return (response, try JSONSerialization.data(withJSONObject: body))
    }
}
