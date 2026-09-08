import XCTest
@testable import SignalQuest

/// The real HTTP client, admission, tile cache and ViewModel run against four
/// synthetic tiles around the equator. No running server or account is needed.
@MainActor
final class MapPartialTilesTests: XCTestCase {
    private let bounds = MapBounds(north: 0.001, south: -0.001, east: 0.001, west: -0.001)
    private let remainingIDs: Set<String> = ["SFR-8191-8191", "SFR-8191-8192", "SFR-8192-8191"]

    func testSpeedtestTile503KeepsOtherTilesAndReportsIncompleteResponse() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable)

        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])

        XCTAssertEqual(Set(harness.model.speedtestTiles.flatMap(\.markers).map(\.id)), remainingIDs)
        XCTAssertNotNil(harness.model.errorMessage)
        XCTAssertFalse(harness.model.hasCurrentResponse, "A subset must not authorize the genuine-empty state")
    }

    func testFocusedCoverageTile503KeepsOtherTilesWithoutBroadeningTheFocus() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable)
        harness.model.coverageFocus = AntennaCoverageFocus(siteLabel: "Synthetic", operatorKey: "SFR", enb: "123", gnb: nil)

        await harness.model.load(bounds: bounds, zoom: 14, filters: [.coverage])

        XCTAssertEqual(Set(harness.model.coverageTiles.flatMap(\.points).map(\.id)), remainingIDs)
        XCTAssertTrue(harness.model.coverageHeat.isEmpty)
        XCTAssertNotNil(harness.model.errorMessage)
        let requests = harness.fixture.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/coverage/points" })
        let coverageRequests = requests.filter { $0.url?.path.contains("/tiles/coverage/") == true }
        XCTAssertEqual(Set(coverageRequests.compactMap { $0.url?.path }).count, 4)
        XCTAssertTrue(coverageRequests.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "enb", value: "123")) == true
        })
    }

    func testMalformedCustomTileCannotEraseTheThreeAdmittedTiles() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .malformed)

        await harness.model.load(bounds: bounds, zoom: 14, filters: [.customSite])

        XCTAssertEqual(Set(harness.model.customSiteTiles.flatMap(\.markers).map(\.id)), remainingIDs)
        XCTAssertNotNil(harness.model.errorMessage)
        XCTAssertFalse(harness.model.hasCurrentResponse)
    }

    func testSuccessfulEmptyTilesReplaceTheirOldPointsWhileOnlyFailedTileIsRetained() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        XCTAssertEqual(harness.model.speedtestTiles.flatMap(\.markers).count, 4)
        harness.fixture.set(failure: .unavailable, emptySuccesses: true)

        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest], refresh: true)

        XCTAssertEqual(harness.model.speedtestTiles.flatMap(\.markers).map(\.id), ["SFR-8192-8192"])
        XCTAssertNotNil(harness.model.errorMessage)
        XCTAssertFalse(harness.model.hasCurrentResponse)
        harness.fixture.set(failure: .none)
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest], refresh: true)
        XCTAssertEqual(harness.model.speedtestTiles.flatMap(\.markers).count, 4)
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertTrue(harness.model.hasCurrentResponse)
    }

    func testServiceReportsAdmittedAndFailedTileIdentitiesWithoutClaimingSuccess() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable)
        do {
            _ = try await harness.service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
            XCTFail("An incomplete batch must throw its typed error")
        } catch let failure as MapTileBatchFailure<AndroidSpeedtestTileResponse> {
            XCTAssertEqual(failure.requestedTiles.count, 4)
            XCTAssertEqual(Set(failure.successfulTiles.flatMap(\.markers).map(\.id)), remainingIDs)
            XCTAssertEqual(failure.failedTiles, [AndroidMapTile(z: 14, x: 8192, y: 8192)])
            guard case APIError.http(status: 503, code: _, message: _, requestId: _, retryAfter: _) = failure.cause else {
                return XCTFail("The transport failure must remain distinguishable")
            }
        }
    }

    func testAllUnavailableTilesRemainAnErrorAndDoNotBecomeAnEmptySuccess() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .allUnavailable)
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        XCTAssertTrue(harness.model.speedtestTiles.isEmpty)
        XCTAssertFalse(harness.model.hasCurrentResponse)
        XCTAssertNotNil(harness.model.errorMessage)
        XCTAssertEqual(harness.model.tileLoadIssues[.speedtest]?.receivedCount, 0)
        XCTAssertEqual(harness.model.tileLoadIssues[.speedtest]?.failedTiles.count, 4)
    }

    func testCancellationFromOneTileInvalidatesTheEntireBatchWithoutPartialPublication() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .cancelled)
        do {
            _ = try await harness.service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
            XCTFail("Cancellation must invalidate the batch")
        } catch {
            XCTAssertTrue(error.isCancellation)
            XCTAssertFalse(error is MapTileBatchFailure<AndroidSpeedtestTileResponse>)
        }
    }

    func testViewModelCancelledTileBatchKeepsCompatibleDataWithoutAuthorizingAGenuineEmptyState() async throws {
        for (hasPreviousData, wantsSocialSnapshot) in [(false, false), (true, false), (false, true), (true, true)] {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            let filters: Set<MapDisplayItem.Kind> = wantsSocialSnapshot ? [.speedtest, .friend] : [.speedtest]
            if wantsSocialSnapshot { try harness.credentials.setAccessToken("synthetic-map-cancellation") }
            let expectedIDs: Set<String> = hasPreviousData
                ? ["SFR-8191-8191", "SFR-8191-8192", "SFR-8192-8191", "SFR-8192-8192"] : []
            if hasPreviousData {
                await harness.model.load(bounds: bounds, zoom: 14, filters: filters)
                XCTAssertEqual(Set(harness.model.speedtestTiles.flatMap(\.markers).map(\.id)), expectedIDs)
                XCTAssertTrue(harness.model.hasCurrentResponse)
            }
            // A selected social layer may succeed alongside tile cancellation.
            // Public-only browsing must not request a private snapshot at all.
            await harness.service.invalidateTiles()
            harness.fixture.set(failure: .cancelled)
            let previousRequestCount = harness.fixture.requests.count
            let owner = harness.service.sessionIdentifier
            let currentRequest = harness.model.prepareLoad(filters: filters)
            XCTAssertFalse(Task.isCancelled)

            await harness.model.load(bounds: bounds, zoom: 14, filters: filters, requestID: currentRequest, refresh: true)

            XCTAssertFalse(Task.isCancelled, "Only a child tile transport was cancelled")
            XCTAssertEqual(harness.service.sessionIdentifier, owner)
            XCTAssertEqual(harness.fixture.requests.dropFirst(previousRequestCount).contains { $0.url?.path == "/api/social/map/snapshot" }, wantsSocialSnapshot)
            XCTAssertEqual(Set(harness.model.speedtestTiles.flatMap(\.markers).map(\.id)), expectedIDs)
            XCTAssertFalse(harness.model.hasCurrentResponse, "A successful snapshot cannot authorize genuine-empty UI for cancelled tiles")
            XCTAssertFalse(harness.model.isLoading)
            XCTAssertNil(harness.model.errorMessage, "Cancellation must not become a transport failure toast")
        }
    }

    func testAccountReplacementDuringPartialBatchIsCancellationRatherThanDisplayableFailure() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable)
        let credentials = harness.credentials
        harness.fixture.onFailingTile { try? credentials.setAccessToken("synthetic-replacement") }
        do {
            _ = try await harness.service.speedtestTiles(bounds: bounds, zoom: 14, market: "FR", operatorName: "SFR")
            XCTFail("The old account's batch must not be returned")
        } catch {
            XCTAssertTrue(error.isCancellation)
            XCTAssertFalse(error is MapTileBatchFailure<AndroidSpeedtestTileResponse>)
        }
    }

    func testContextChangesNeverRetainOldFailedTiles() async throws {
        for change in ["operator", "market", "bands", "account"] {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
            XCTAssertEqual(harness.model.speedtestTiles.flatMap(\.markers).count, 4)
            switch change {
            case "operator": harness.model.operatorFilter = "ORANGE"
            case "market": harness.model.marketFilter = "BE"
            case "bands": harness.model.bandFilters = [20]
            default: try harness.credentials.setAccessToken("synthetic-next-account")
            }
            harness.fixture.set(failure: .unavailable, emptySuccesses: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest], refresh: true)
            XCTAssertTrue(harness.model.speedtestTiles.flatMap(\.markers).isEmpty, change)
            XCTAssertEqual(harness.model.tileLoadIssues[.speedtest]?.retainedCount, 0, change)
            XCTAssertNotNil(harness.model.errorMessage, change)
        }
    }

    func testWarmCacheRetryRequestsFailedTileAndPreservesAlreadyAdmittedTiles() async throws {
        let harness = try makeHarness(cacheAge: 300)
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable)
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        let firstCount = harness.fixture.requests.count
        harness.fixture.set(failure: .none)
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        XCTAssertEqual(harness.model.speedtestTiles.flatMap(\.markers).count, 4)
        XCTAssertNil(harness.model.errorMessage)
        let replay = harness.fixture.requests.dropFirst(firstCount).filter { $0.url?.path.contains("/tiles/") == true }
        XCTAssertEqual(replay.map { $0.url!.path }, ["/api/android/map/tiles/speedtests/14/8192/8192"])
    }

    func testTransportFailureAndServerTruncationRemainSeparateStates() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.fixture.set(failure: .unavailable, truncated: true)
        await harness.model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        XCTAssertEqual(harness.model.tileLoadIssues[.speedtest]?.failedTiles.count, 1)
        XCTAssertTrue(MapDataLimits.speedtests(harness.model.speedtestTiles))
        XCTAssertFalse(harness.model.displayLimitMessages.isEmpty)
        XCTAssertFalse(harness.model.hasCurrentResponse)
    }

    func testMissingOrUnavailableAntennaTilesKeepTheCompatibleBboxFallback() async throws {
        for status in [404, 501, 503] {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            harness.fixture.set(failure: .none, enableFallbacks: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.antenna])
            XCTAssertEqual(harness.model.antennas.count, 4)
            harness.fixture.set(failure: .allUnavailable, tileFailureStatus: status, enableFallbacks: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.antenna], refresh: true)
            XCTAssertEqual(harness.model.antennas.map(\.id), ["fallback-antenna"], "HTTP \(status)")
            XCTAssertNil(harness.model.errorMessage, "HTTP \(status)")
            XCTAssertTrue(harness.model.hasCurrentResponse, "HTTP \(status)")
            let fallbackRequests = harness.fixture.requests.filter { $0.url?.path == "/api/antennas" }
            XCTAssertEqual(fallbackRequests.count, 1)
            let query = fallbackRequests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            XCTAssertEqual(query?.first { $0.name == "market" }?.value, "FR")
            XCTAssertEqual(query?.first { $0.name == "operator" }?.value, "SFR")
            harness.fixture.set(failure: .allUnavailable, tileFailureStatus: status, enableFallbacks: true, fallbackUnavailable: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.antenna], refresh: true)
            XCTAssertEqual(harness.model.antennas.map(\.id), ["fallback-antenna"])
            XCTAssertNotNil(harness.model.errorMessage)
            XCTAssertFalse(harness.model.hasCurrentResponse)
        }
    }

    func testCoverageTotalTileFailureUsesCompatiblePointsAndKeepsThemIfFallbackLaterFails() async throws {
        for status in [404, 501, 503] {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            harness.model.coverageDays = 30
            harness.model.techFilters = ["4G"]
            harness.fixture.set(failure: .none, enableFallbacks: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.coverage])
            XCTAssertEqual(harness.model.coverageTiles.flatMap(\.points).count, 4)
            harness.fixture.set(failure: .allUnavailable, tileFailureStatus: status, enableFallbacks: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.coverage], refresh: true)
            XCTAssertEqual(harness.model.coverageHeat.map(\.id), ["fallback-coverage"], "HTTP \(status)")
            XCTAssertTrue(harness.model.coverageTiles.isEmpty)
            XCTAssertNil(harness.model.errorMessage, "HTTP \(status)")
            XCTAssertTrue(harness.model.hasCurrentResponse, "HTTP \(status)")
            let fallbackRequests = harness.fixture.requests.filter { $0.url?.path == "/api/coverage/points" }
            XCTAssertEqual(fallbackRequests.count, 1)
            let query = fallbackRequests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            XCTAssertEqual(query?.first { $0.name == "operator" }?.value, "SFR")
            XCTAssertEqual(query?.first { $0.name == "technology" }?.value, "4G")

            harness.fixture.set(failure: .allUnavailable, tileFailureStatus: status, enableFallbacks: true, fallbackUnavailable: true)
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.coverage], refresh: true)
            XCTAssertEqual(harness.model.coverageHeat.map(\.id), ["fallback-coverage"])
            XCTAssertNotNil(harness.model.errorMessage)
            XCTAssertFalse(harness.model.hasCurrentResponse)
        }
    }

    func testCoverageFallbackCannotBroadenScopeOrReplaceAnAdmittedEmptyPartialTile() async throws {
        for restriction in ["focus", "bands", "period", "technologies", "partial-empty", "cancellation", "account"] {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            harness.model.coverageDays = 30
            switch restriction {
            case "focus": harness.model.coverageFocus = AntennaCoverageFocus(siteLabel: "Synthetic", operatorKey: "SFR", enb: "123", gnb: nil)
            case "bands": harness.model.bandFilters = [20]
            case "period": harness.model.coverageDays = 7
            case "technologies": harness.model.techFilters = ["4G", "5G"]
            default: break
            }
            let failure: PartialTileHTTPFixture.Failure = restriction == "partial-empty" ? .unavailable
                : restriction == "cancellation" ? .cancelled : .allUnavailable
            harness.fixture.set(failure: failure, emptySuccesses: true, tileFailureStatus: 404, enableFallbacks: true)
            if restriction == "account" {
                let credentials = harness.credentials
                harness.fixture.onFailingTile { try? credentials.setAccessToken("synthetic-next-account") }
            }
            await harness.model.load(bounds: bounds, zoom: 14, filters: [.coverage])
            XCTAssertTrue(harness.model.coverageHeat.isEmpty, restriction)
            XCTAssertFalse(harness.fixture.requests.contains { $0.url?.path == "/api/coverage/points" }, restriction)
            if restriction == "partial-empty" {
                XCTAssertEqual(harness.model.coverageTiles.count, 3)
                XCTAssertEqual(harness.model.tileLoadIssues[.coverage]?.receivedCount, 3)
            }
            XCTAssertFalse(harness.model.hasCurrentResponse, restriction)
        }
    }

    private func makeHarness(cacheAge: TimeInterval = 0) throws -> PartialTileHarness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let api = APIClient(config: .test, credentials: credentials, session: session)
        let folder = "MapPartialTiles-\(UUID())"
        let disk = DiskCache(folderName: folder)
        let service = MapSnapshotService(api: api, cache: disk, tileCache: TileCache(disk: disk, memoryTTL: cacheAge, diskTTL: cacheAge))
        let model = MapExplorerViewModel(map: service, antennas: AntennasService(api: api),
                                         markets: MarketRegistryService(api: api), communityOutages: CommunityOutageService(api: api))
        model.marketFilter = "FR"
        model.operatorFilter = "SFR"
        let fixture = PartialTileHTTPFixture(snapshot: try JSONEncoder.signalQuest.encode(SocialMapSnapshot.empty))
        MockURLProtocol.requestHandler = fixture.response
        return PartialTileHarness(model: model, service: service, fixture: fixture, session: session, folder: folder, credentials: credentials)
    }
}

@MainActor
private struct PartialTileHarness {
    let model: MapExplorerViewModel
    let service: MapSnapshotService
    let fixture: PartialTileHTTPFixture
    let session: URLSession
    let folder: String
    let credentials: CredentialStore

    func cleanUp() {
        session.invalidateAndCancel()
        MockURLProtocol.requestHandler = nil
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent(folder))
    }
}

/// URLProtocol calls this object off MainActor; mutable recipe state is locked.
private final class PartialTileHTTPFixture: @unchecked Sendable {
    enum Failure { case none, unavailable, malformed, allUnavailable, cancelled }
    private let lock = NSLock()
    private let snapshot: Data
    private var failure: Failure = .none
    private var emptySuccesses = false
    private var truncated = false
    private var tileFailureStatus = 503
    private var enableFallbacks = false
    private var fallbackUnavailable = false
    private var failingTileAction: (@Sendable () -> Void)?
    private var recordedRequests: [URLRequest] = []

    init(snapshot: Data) { self.snapshot = snapshot }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func set(failure: Failure, emptySuccesses: Bool = false, truncated: Bool = false,
             tileFailureStatus: Int = 503, enableFallbacks: Bool = false, fallbackUnavailable: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.failure = failure
        self.emptySuccesses = emptySuccesses
        self.truncated = truncated
        self.tileFailureStatus = tileFailureStatus
        self.enableFallbacks = enableFallbacks
        self.fallbackUnavailable = fallbackUnavailable
    }

    func onFailingTile(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        failingTileAction = action
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        recordedRequests.append(request)
        let failure = self.failure
        let emptySuccesses = self.emptySuccesses
        let truncated = self.truncated
        let tileFailureStatus = self.tileFailureStatus
        let enableFallbacks = self.enableFallbacks
        let fallbackUnavailable = self.fallbackUnavailable
        let failingTileAction = request.url?.path.hasSuffix("/8192/8192") == true ? self.failingTileAction : nil
        if failingTileAction != nil { self.failingTileAction = nil }
        lock.unlock()
        failingTileAction?()
        guard let url = request.url else { throw URLError(.badURL) }
        var status = 200
        let data: Data
        if url.path == "/api/social/map/snapshot" {
            data = snapshot
        } else if enableFallbacks && ["/api/antennas", "/api/coverage/points"].contains(url.path) {
            if fallbackUnavailable {
                status = 503
                data = Data(#"{"code":"DATABASE_UNAVAILABLE","error":"Synthetic fallback unavailable"}"#.utf8)
            } else if url.path == "/api/antennas" {
                data = Data(#"{"antennas":[{"id":"fallback-antenna","siteId":"synthetic-site","latitude":0.0005,"longitude":0.0005,"operators":["SFR"],"technologies":["4G"],"bands":[20],"azimuths":[120]}]}"#.utf8)
            } else {
                data = Data(#"{"points":[{"id":"fallback-coverage","latitude":0.0005,"longitude":0.0005,"signalStrength":-95,"technology":"4G","networkType":"LTE","band":20,"source":"android"}]}"#.utf8)
            }
        } else if enableFallbacks && url.path == "/api/android/map/incidents" {
            data = Data(#"{"sites":[]}"#.utf8)
        } else if enableFallbacks && url.path == "/api/community-outages" {
            data = Data(#"{"outages":[],"hasMore":false}"#.utf8)
        } else if url.path.contains("/tiles/") {
            let indices = url.path.split(separator: "/").suffix(3).compactMap { Int($0) }
            guard indices.count == 3, indices[0] == 14,
                  [8191, 8192].contains(indices[1]), [8191, 8192].contains(indices[2]) else {
                throw URLError(.unsupportedURL)
            }
            let failingTile = indices[1] == 8192 && indices[2] == 8192
            if failingTile && failure == .cancelled { throw URLError(.cancelled) }
            if failure == .allUnavailable || (failingTile && failure == .unavailable) {
                status = tileFailureStatus
                data = Data(#"{"code":"DATABASE_UNAVAILABLE","error":"Synthetic tile unavailable"}"#.utf8)
            } else if failingTile && failure == .malformed {
                data = Data(#"{"tile":{"z":14,"x":8192,"y":8192},"markers":"unavailable"}"#.utf8)
            } else {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let op = query?.first { $0.name == "operator" }?.value ?? "missing"
                let latitude = indices[2] == 8191 ? 0.0005 : -0.0005
                let longitude = indices[1] == 8191 ? -0.0005 : 0.0005
                let item = "{\"id\":\"\(op)-\(indices[1])-\(indices[2])\",\"lat\":\(latitude),\"lng\":\(longitude),\"downloadMbps\":120,\"tech\":\"4G\"}"
                let key = url.path.contains("/coverage/") ? "points" : "markers"
                let items = emptySuccesses ? "[]" : "[\(item)]"
                let stats = truncated && key == "markers" ? ",\"stats\":{\"returnedCount\":1,\"truncated\":true}" : ""
                data = Data("{\"tile\":{\"z\":14,\"x\":\(indices[1]),\"y\":\(indices[2])},\"\(key)\":\(items),\"clusters\":[]\(stats)}".utf8)
            }
        } else {
            throw URLError(.unsupportedURL)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store"]) else {
            throw URLError(.badServerResponse)
        }
        return (response, data)
    }
}
