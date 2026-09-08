import XCTest
import MapKit
@testable import SignalQuest

/// Verifies the loopback recipe through the production HTTP and tile decoders.
/// These assertions do not prove that MapKit has painted any of the points.
@MainActor
final class MapHTTPFixtureAdmissionTests: XCTestCase {
    func testInternationalPublicLayersFollowEachSelectedCountryAndOperator() async throws {
        guard ProcessInfo.processInfo.environment["SQ_MAP_HTTP_QA"] == "1" else {
            throw XCTSkip("Requires the international loopback fixture on port 8769")
        }
        let keys = [MapMarketStore.marketKey, MapMarketStore.operatorKey, MapMarketStore.manualMarketKey,
                    MapBandMatchStore.key, MapAzimuthStyleStore.key]
        let saved = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = UserDefaults.standard.object(forKey: key)
        }
        defer { for key in keys { UserDefaults.standard.set(saved[key], forKey: key) } }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:8769"))
        let api = APIClient(config: AppConfig(appBaseURL: origin, apiBaseURL: origin, debugLogsEnabled: false),
                            credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: URLSession(configuration: .ephemeral))
        let folder = "InternationalMapFixture-\(UUID())"
        let disk = DiskCache(folderName: folder)
        defer {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(folder))
        }
        let service = MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0))
        let model = MapExplorerViewModel(map: service, antennas: AntennasService(api: api),
            markets: MarketRegistryService(api: api), communityOutages: CommunityOutageService(api: api))
        await model.loadRegistry()
        let cases: [(String, String, Double, Double, Bool)] = [
            ("FR", "SFR", 45.1883, 5.7132, true), ("CA", "BELL", 45.5019, -73.5674, true),
            ("DROM", "SRR", -20.8823, 55.4504, true), ("BE", "PROXIMUS_BE", 50.4669, 4.86746, true),
            ("CH", "SWISSCOM_CH", 46.948, 7.4474, true), ("DE", "TELEKOM_DE", 52.52, 13.405, false),
            ("US", "ATT_US", 40.7128, -74.006, false), ("BA", "BH_MOBILE_BA", 43.8563, 18.4131, false)
        ]
        for (country, op, lat, lng, official) in cases {
            model.marketFilter = country
            model.recordViewportCenter(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            let applied = try XCTUnwrap(model.applyFilterSelection(.defaults(market: country, operatorName: op)))
            XCTAssertEqual(applied.operatorName, op, country)
            let bounds = MapBounds(north: lat + 0.02, south: lat - 0.02, east: lng + 0.02, west: lng - 0.02)
            await model.load(bounds: bounds, zoom: 14, filters: [.antenna, .customSite, .speedtest, .coverage], refresh: true)
            XCTAssertNil(model.errorMessage, country)
            XCTAssertTrue(model.hasCurrentResponse, country)
            let prefix = country == "FR" ? op : country + "-" + op
            let expected = Set(["NW", "NE", "C", "SW", "SE"].map { "qa-speedtests-" + prefix + "-" + $0 })
            XCTAssertEqual(Set(model.speedtestTiles.flatMap(\.markers).map(\.id)), expected, country)
            XCTAssertEqual(model.customSiteTiles.flatMap(\.markers).count, 5, country)
            XCTAssertEqual(model.coverageTiles.flatMap(\.points).count, 5, country)
            XCTAssertEqual(model.antennas.count, official ? 5 : 0, country)
            model.recordViewportCenter(CLLocationCoordinate2D(latitude: 0, longitude: 0))
            XCTAssertEqual(model.marketFilter, country, "A camera move must keep " + country)
        }
    }

    func testBaselineRecipeIsAdmittedForEveryPublicMapLayer() async throws {
        guard ProcessInfo.processInfo.environment["SQ_MAP_HTTP_QA"] == "1" else {
            throw XCTSkip("Requires the baseline loopback map fixture on port 8769")
        }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:8769"))
        let config = AppConfig(appBaseURL: origin, apiBaseURL: origin, debugLogsEnabled: false)
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let api = APIClient(config: config, credentials: credentials, session: session)
        let folder = "MapHTTPFixture-\(UUID())"
        let disk = DiskCache(folderName: folder)
        defer {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(folder))
        }
        let service = MapSnapshotService(api: api, cache: disk,
                                         tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0))
        let bounds = MapBounds(north: 45.199, south: 45.175, east: 5.740, west: 5.700)
        let zoom = 14.5
        let expectedKeys = ["NW", "NE", "C", "SW", "SE"]
        func expected(_ layer: String) -> Set<String> {
            Set(expectedKeys.map { "qa-\(layer)-ORANGE-\($0)" })
        }
        let snapshot = try await service.snapshot(bounds: bounds, zoom: zoom, lightweight: true)
        XCTAssertTrue(snapshot.friends.isEmpty)
        XCTAssertEqual(snapshot.speedtestsCount, 0)
        let antennas = try await service.antennaTiles(bounds: bounds, zoom: zoom, market: "FR",
                                                      operatorName: "ORANGE", withAzimuth: true, bands: [])
        XCTAssertEqual(Set(antennas.flatMap(\.markers).map(\.id)), expected("antennas"))
        let speedtests = try await service.speedtestTiles(bounds: bounds, zoom: zoom, market: "FR",
                                                          operatorName: "ORANGE", days: 0, bands: [], maxAge: 0)
        XCTAssertEqual(Set(speedtests.flatMap(\.markers).map(\.id)), expected("speedtests"))
        XCTAssertEqual(Set(speedtests.flatMap(\.markers).map(\.downloadMbps)), [120, 160, 200, 240, 280])
        let coverage = try await service.coverageTiles(bounds: bounds, zoom: zoom, market: "FR",
                                                       operatorName: "ORANGE", days: 0, bands: [], maxAge: 0)
        XCTAssertEqual(Set(coverage.flatMap(\.points).map(\.id)), expected("coverage").union(["qa-coverage-ORANGE-IOS"]))
        let community = try await service.communitySiteTiles(bounds: bounds, zoom: zoom, market: "FR",
                                                             operatorName: "ORANGE", includeObserved: true, bands: [])
        XCTAssertEqual(Set(community.flatMap(\.markers).map(\.id)), expected("community-sites"))
        let custom = try await service.customSiteTiles(bounds: bounds, zoom: zoom, market: "FR", operatorName: "ORANGE")
        XCTAssertEqual(Set(custom.flatMap(\.markers).map(\.id)), expected("custom-sites"))
        XCTAssertNil(credentials.snapshot().accessToken)
    }
}
