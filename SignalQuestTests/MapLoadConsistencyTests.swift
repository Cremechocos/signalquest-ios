import XCTest
import MapKit
@testable import SignalQuest

@MainActor
final class MapLoadConsistencyTests: XCTestCase {
    private let bounds = MapBounds(north: 48.86, south: 48.85, east: 2.36, west: 2.35)

    func testVisibilityChangeRemovesThePointAndRejectsItsInFlightReload() async throws {
        let (model, service) = makeModel()
        await service.setImmediateSpeedtests([try speedtestTile("hide-me"), try speedtestTile("keep-me")])
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        let started = expectation(description: "old reload")
        await service.expectSpeedtest("SFR", started: started)
        let old = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [started], timeout: 2)
        model.applySpeedtestVisibility(serverID: "hide-me", isSharedOnMap: false)
        XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), ["keep-me"])
        let version = model.dataVersion
        await service.finishSpeedtest("SFR", result: .success([try speedtestTile("hide-me")]))
        await old.value
        XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), ["keep-me"])
        XCTAssertEqual(model.dataVersion, version)
    }

    func testAllTimeCoverageCannotFallBackToTheServersThirtyDayWindow() async {
        let (model, service) = makeModel()
        model.coverageDays = 0
        await service.setCoverage(.failure(APIError.transport("offline")))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        let calls = await service.coverageFallbackCount
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testBandFilteredCoverageCannotUseARepliThatOmitsBands() async {
        let (model, service) = makeModel()
        model.coverageDays = 30
        model.bandFilters = [7]
        await service.setCoverage(.failure(APIError.transport("offline")))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        let calls = await service.coverageFallbackCount
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testExplicitRefreshBypassesSpeedtestAndCoverageCaches() async {
        let (model, service) = makeModel()
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest, .coverage], refresh: true)
        let speedtestAge = await service.lastSpeedtestMaxAge
        let coverageAge = await service.lastCoverageMaxAge
        XCTAssertEqual(speedtestAge, 0)
        XCTAssertEqual(coverageAge, 0)
    }

    func testDirectLoadCompletedLastCannotOverwriteNewerResult() async throws {
        let (model, service) = makeModel()
        let aStarted = expectation(description: "A started")
        let bStarted = expectation(description: "B started")
        await service.expectSpeedtest("SFR", started: aStarted)
        await service.expectSpeedtest("ORANGE", started: bStarted)
        let a = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [aStarted], timeout: 2)
        model.operatorFilter = "ORANGE"
        let b = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [bStarted], timeout: 2)
        await service.finishSpeedtest("ORANGE", result: .success([try speedtestTile("B")]))
        await b.value
        let version = model.dataVersion
        await service.finishSpeedtest("SFR", result: .success([try speedtestTile("A")]))
        await a.value
        XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), ["B"])
        XCTAssertEqual(model.dataVersion, version)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testOldCompletionCannotStopNewLoadSpinnerOrPublishItsError() async throws {
        let (model, service) = makeModel()
        let aStarted = expectation(description: "A started")
        let bStarted = expectation(description: "B started")
        await service.expectSpeedtest("SFR", started: aStarted)
        await service.expectSpeedtest("ORANGE", started: bStarted)
        let a = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [aStarted], timeout: 2)
        model.operatorFilter = "ORANGE"
        let b = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [bStarted], timeout: 2)
        await service.finishSpeedtest("SFR", result: .failure(APIError.transport("old failure")))
        await a.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.errorMessage)
        await service.finishSpeedtest("ORANGE", result: .success([try speedtestTile("B")]))
        await b.value
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testOlderSuccessCannotEraseNewerFailureOrShowWrongOperator() async throws {
        let (model, service) = makeModel()
        let aStarted = expectation(description: "A started")
        let bStarted = expectation(description: "B started")
        await service.expectSpeedtest("SFR", started: aStarted)
        await service.expectSpeedtest("ORANGE", started: bStarted)
        let a = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [aStarted], timeout: 2)
        model.operatorFilter = "ORANGE"
        let b = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [bStarted], timeout: 2)
        await service.finishSpeedtest("ORANGE", result: .failure(APIError.transport("new failure")))
        await b.value
        let error = model.errorMessage
        XCTAssertNotNil(error)
        await service.finishSpeedtest("SFR", result: .success([try speedtestTile("A")]))
        await a.value
        XCTAssertTrue(model.speedtestTiles.isEmpty)
        XCTAssertEqual(model.errorMessage, error)
    }

    func testDebouncedReservationSupersededByDirectLoadDoesNotStartLater() async throws {
        let (model, service) = makeModel()
        let scheduledID = model.prepareLoad(filters: [.speedtest])
        model.operatorFilter = "ORANGE"
        await service.setImmediateSpeedtests([try speedtestTile("direct")])
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        let requestCount = await service.speedtestRequestCount
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest], requestID: scheduledID)
        let countAfterStaleStart = await service.speedtestRequestCount
        XCTAssertEqual(countAfterStaleStart, requestCount)
        XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), ["direct"])
        XCTAssertFalse(model.isLoading)
    }

    func testReservationInvalidatesInFlightInitialLoadBeforeDebounceEnds() async throws {
        let (model, service) = makeModel()
        let started = expectation(description: "initial started")
        await service.expectSpeedtest("SFR", started: started)
        let initial = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [started], timeout: 2)
        let next = model.prepareLoad(filters: [.speedtest])
        await service.finishSpeedtest("SFR", result: .success([try speedtestTile("initial")]))
        await initial.value
        XCTAssertTrue(model.speedtestTiles.isEmpty)
        XCTAssertTrue(model.isLoading)
        await service.setImmediateSpeedtests([try speedtestTile("scheduled")])
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest], requestID: next)
        XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), ["scheduled"])
        XCTAssertFalse(model.isLoading)
    }

    func testFocusedCoverageFailurePreservesCompatibleDataAndNeverBroadensToOperator() async throws {
        let (model, service) = makeModel()
        model.coverageFocus = focus("123")
        await service.setCoverage(.success([try coverageTile("old")]))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        await service.setCoverage(.failure(APIError.transport("coverage unavailable")))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertEqual(model.coverageTiles.flatMap(\.points).map(\.id), ["old"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.coverageHeat.isEmpty)
        let fallbacks = await service.coverageFallbackCount
        XCTAssertEqual(fallbacks, 0)
    }

    func testChangingSiteMarketBandsOrAccountCannotRetainIncompatibleCoverage() async throws {
        for change in ["site", "market", "bands", "account"] {
            let (model, service) = makeModel()
            model.coverageFocus = focus("123")
            await service.setCoverage(.success([try coverageTile("old")]))
            await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
            switch change {
            case "site": model.coverageFocus = focus("456")
            case "market": model.marketFilter = "DROM"
            case "bands": model.bandFilters = [20]
            default: try service.credentials.setAccessToken("synthetic-B")
            }
            await service.setCoverage(.failure(APIError.transport("coverage unavailable")))
            await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
            XCTAssertTrue(model.coverageTiles.isEmpty, change)
            XCTAssertNotNil(model.errorMessage, change)
            let fallbacks = await service.coverageFallbackCount
            XCTAssertEqual(fallbacks, 0, change)
        }
    }

    func testRealEmptyCoverageClearsItsPreviousDataWithoutFallback() async throws {
        let (model, service) = makeModel()
        await service.setCoverage(.success([try coverageTile("old")]))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        await service.setCoverage(.success([try coverageTile(nil)]))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertTrue(model.coverageTiles.flatMap(\.points).isEmpty)
        XCTAssertNil(model.errorMessage)
        let fallbacks = await service.coverageFallbackCount
        XCTAssertEqual(fallbacks, 0)
    }

    func testDateWindowIsNotLostWhenCoverageTilesFail() async {
        let (model, service) = makeModel()
        model.coverageDays = 7
        await service.setCoverage(.failure(APIError.transport("coverage unavailable")))
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertNotNil(model.errorMessage)
        let fallbacks = await service.coverageFallbackCount
        XCTAssertEqual(fallbacks, 0, "The fallback endpoint has no date window")
    }

    func testAccountSwitchDuringDirectRequestDiscardsResponseAndRetainedState() async throws {
        let (model, service) = makeModel()
        await service.setImmediateSpeedtests([try speedtestTile("retained-A")])
        await model.load(bounds: bounds, zoom: 14, filters: [.speedtest])
        let started = expectation(description: "A refresh started")
        await service.expectSpeedtest("SFR", started: started)
        let loading = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
        await fulfillment(of: [started], timeout: 2)
        try service.credentials.setAccessToken("synthetic-B")
        await service.finishSpeedtest("SFR", result: .success([try speedtestTile("late-A")]))
        await loading.value
        XCTAssertTrue(model.speedtestTiles.isEmpty)
        XCTAssertTrue(model.snapshot.friends.isEmpty)
        XCTAssertTrue(model.liveFriends.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testSocialSnapshotDiskCacheDoesNotCrossAccounts() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-A")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config))
        let folder = "MapLoadConsistencyTests-\(UUID())"
        let service = MapSnapshotService(api: api, cache: DiskCache(folderName: folder))
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder)
        defer {
            MockURLProtocol.requestHandler = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
        let fixture = MapLoadHTTPFixture(snapshot: try JSONEncoder.signalQuest.encode(SocialMapSnapshot.empty))
        MockURLProtocol.requestHandler = fixture.response
        let a = try await service.snapshot(bounds: bounds, zoom: 14)
        _ = try await service.snapshot(bounds: bounds, zoom: 14)
        XCTAssertEqual(a.photosCount, 1)
        XCTAssertEqual(fixture.requests.count, 1)
        try credentials.setAccessToken("synthetic-B")
        let b = try await service.snapshot(bounds: bounds, zoom: 14)
        XCTAssertEqual(b.photosCount, 2)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testFocused503ThroughRealServicesRetainsDataThenAcceptsTrueEmpty() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: config))
        let folder = "MapLoadHTTPTests-\(UUID())"
        let disk = DiskCache(folderName: folder)
        let service = MapSnapshotService(api: api, cache: disk,
                                          tileCache: TileCache(disk: disk, memoryTTL: 0, diskTTL: 0))
        let model = MapExplorerViewModel(map: service, antennas: AntennasService(api: api),
                                         markets: MarketRegistryService(api: api),
                                         communityOutages: CommunityOutageService(api: api))
        model.marketFilter = "FR"
        model.operatorFilter = "SFR"
        model.coverageFocus = focus("123")
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder)
        defer {
            MockURLProtocol.requestHandler = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
        let fixture = MapLoadHTTPFixture(snapshot: try JSONEncoder.signalQuest.encode(SocialMapSnapshot.empty))
        MockURLProtocol.requestHandler = fixture.response
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertEqual(Set(model.coverageTiles.flatMap(\.points).map(\.id)), ["live"])
        fixture.setCoveragePhase(.unavailable)
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(Set(model.coverageTiles.flatMap(\.points).map(\.id)), ["live"])
        fixture.setCoveragePhase(.empty)
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.coverageTiles.flatMap(\.points).isEmpty)
        let requests = fixture.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/coverage/points" })
        XCTAssertTrue(requests.allSatisfy {
            let path = $0.url?.path ?? ""
            return path.contains("/tiles/coverage/") || path == "/api/social/map/snapshot"
        })
        let coverageRequests = requests.filter { $0.url?.path.contains("/tiles/coverage/") == true }
        XCTAssertFalse(coverageRequests.isEmpty)
        for request in coverageRequests {
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "enb" })?.value, "123")
        }
    }

    func testDelayedPartialBatchCannotPublishOverNewerContextSuccessOrFailure() async throws {
        for newerFails in [false, true] {
            let (model, service) = makeModel()
            let oldStarted = expectation(description: "old batch started")
            let newStarted = expectation(description: "new batch started")
            await service.expectSpeedtest("SFR", started: oldStarted)
            await service.expectSpeedtest("ORANGE", started: newStarted)
            let old = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
            await fulfillment(of: [oldStarted], timeout: 2)
            model.operatorFilter = "ORANGE"
            let current = Task { await model.load(bounds: bounds, zoom: 14, filters: [.speedtest]) }
            await fulfillment(of: [newStarted], timeout: 2)
            await service.finishSpeedtest("ORANGE", result: newerFails
                ? .failure(APIError.transport("new failure")) : .success([try speedtestTile("current")]))
            await current.value
            let currentError = model.errorMessage
            let admitted = try speedtestTile("old-partial")
            let failed = AndroidMapTile(z: 14, x: 2, y: 1)
            let partial = MapTileBatchFailure(requestedTiles: [admitted.tile, failed],
                successfulTiles: [admitted], failedTiles: [failed], cause: APIError.transport("old failure"))
            await service.finishSpeedtest("SFR", result: .failure(partial))
            await old.value
            XCTAssertEqual(model.speedtestTiles.flatMap(\.markers).map(\.id), newerFails ? [] : ["current"])
            XCTAssertEqual(model.errorMessage, currentError)
            XCTAssertTrue(model.tileLoadIssues.isEmpty)
            XCTAssertFalse(model.isLoading)
        }
    }

    private func makeModel() -> (MapExplorerViewModel, ControlledMapLoadService) {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let api = APIClient(config: .test, credentials: credentials)
        let service = ControlledMapLoadService(credentials: credentials)
        let model = MapExplorerViewModel(map: service, antennas: AntennasService(api: api),
                                         markets: MarketRegistryService(api: api),
                                         communityOutages: CommunityOutageService(api: api))
        model.marketFilter = "FR"
        model.operatorFilter = "SFR"
        return (model, service)
    }

    private func focus(_ enb: String) -> AntennaCoverageFocus {
        AntennaCoverageFocus(siteLabel: "Synthetic site", operatorKey: "SFR", enb: enb, gnb: nil)
    }

    private func speedtestTile(_ id: String) throws -> AndroidSpeedtestTileResponse {
        try JSONDecoder.signalQuest.decode(AndroidSpeedtestTileResponse.self, from: Data("""
        {"tile":{"z":14,"x":1,"y":1},"clusters":[],"markers":[{"id":"\(id)","lat":48.85,"lng":2.35,"downloadMbps":120}]}
        """.utf8))
    }

    private func coverageTile(_ id: String?) throws -> AndroidCoverageTileResponse {
        let points = id.map { """
        [{"id":"\($0)","lat":48.85,"lng":2.35,"tech":"4G"}]
        """ } ?? "[]"
        return try JSONDecoder.signalQuest.decode(AndroidCoverageTileResponse.self, from: Data("""
        {"tile":{"z":14,"x":1,"y":1},"clusters":[],"points":\(points),"stats":{"sampleCount":\(id == nil ? 0 : 1)}}
        """.utf8))
    }
}

/// Controlled service boundary: the actual ViewModel runs every concurrent
/// layer and publication branch; requests finish in an explicit test order.
private actor ControlledMapLoadService: MapSnapshotServicing {
    func invalidateTiles() async {}
    nonisolated let credentials: CredentialStore
    nonisolated var sessionIdentifier: UUID { credentials.snapshot().sessionID }
    private var speedtestExpectations: [String: XCTestExpectation] = [:]
    private var speedtestContinuations: [String: CheckedContinuation<[AndroidSpeedtestTileResponse], Error>] = [:]
    private var immediateSpeedtests: [AndroidSpeedtestTileResponse] = []
    private var coverage: Result<[AndroidCoverageTileResponse], Error> = .success([])
    private(set) var lastSpeedtestMaxAge: TimeInterval?
    private(set) var lastCoverageMaxAge: TimeInterval?
    private(set) var speedtestRequestCount = 0
    private(set) var coverageFallbackCount = 0

    init(credentials: CredentialStore) { self.credentials = credentials }
    func expectSpeedtest(_ operatorName: String, started: XCTestExpectation) {
        speedtestExpectations[operatorName] = started
    }
    func finishSpeedtest(_ operatorName: String, result: Result<[AndroidSpeedtestTileResponse], Error>) {
        speedtestContinuations.removeValue(forKey: operatorName)?.resume(with: result)
    }
    func setImmediateSpeedtests(_ value: [AndroidSpeedtestTileResponse]) { immediateSpeedtests = value }
    func setCoverage(_ value: Result<[AndroidCoverageTileResponse], Error>) { coverage = value }
    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidSpeedtestTileResponse] {
        lastSpeedtestMaxAge = maxAge
        speedtestRequestCount += 1
        guard let started = speedtestExpectations.removeValue(forKey: operatorName) else { return immediateSpeedtests }
        return try await withCheckedThrowingContinuation { continuation in
            speedtestContinuations[operatorName] = continuation
            started.fulfill()
        }
    }
    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool) async throws -> SocialMapSnapshot { .empty }
    nonisolated func friendsStream(sse: SSEClient) -> AsyncStream<[SocialFriendLive]> { AsyncStream { $0.finish() } }
    func friendsSnapshot() async throws -> [SocialFriendLive] { [] }
    func plannedSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [PlannedSiteLive] { [] }
    func outageSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [OutageSiteLive] { [] }
    func operatorIncidents(forSiteId siteId: String?, market: String, operatorName: String?, latitude: Double, longitude: Double, territory: String?) async throws -> SiteOperatorIncidentsResponse { throw APIError.cancelled }
    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?, bands: Set<Int>) async throws -> [CoverageHeatPoint] {
        coverageFallbackCount += 1
        return []
    }
    func publicPhotos(bounds: MapBounds, zoom: Double, market: String, operatorName: String, friendsOnly: Bool) async throws -> [MapPublicPhoto] { [] }
    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool, bands: Set<Int>) async throws -> [AndroidAntennaTileResponse] { [] }
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidCoverageTileResponse] { try coverage.get() }
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?, focus: AntennaCoverageFocus?) async throws -> [AndroidCoverageTileResponse] {
        lastCoverageMaxAge = maxAge
        return try coverage.get()
    }
    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool, bands: Set<Int>) async throws -> [AndroidCommunitySiteTileResponse] { [] }
    func customSiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String) async throws -> [AndroidCustomSiteTileResponse] { [] }
}

/// URLProtocol invokes its handler on a Foundation networking thread. Build the
/// response outside the test's MainActor, serialize mutable fixture state, and
/// inspect the recorded requests only after awaiting the actual service calls.
/// Assertions in a @MainActor closure handed to URLProtocol can trap in Swift 6.
private final class MapLoadHTTPFixture: @unchecked Sendable {
    enum CoveragePhase { case populated, unavailable, empty }
    private let lock = NSLock()
    private let snapshot: Data
    private var phase: CoveragePhase = .populated
    private var recordedRequests: [URLRequest] = []

    init(snapshot: Data) { self.snapshot = snapshot }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func setCoveragePhase(_ phase: CoveragePhase) {
        lock.lock()
        defer { lock.unlock() }
        self.phase = phase
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        recordedRequests.append(request)
        let currentPhase = phase
        lock.unlock()
        guard let url = request.url else { throw URLError(.badURL) }
        var status = 200
        let data: Data
        if url.path.contains("/tiles/coverage/") {
            if currentPhase == .unavailable {
                status = 503
                data = Data(#"{"code":"DATABASE_UNAVAILABLE","error":"Coverage unavailable"}"#.utf8)
            } else {
                let points = currentPhase == .populated ? #"[{"id":"live","lat":48.85,"lng":2.35,"tech":"4G"}]"# : "[]"
                let components = url.path.split(separator: "/").suffix(3).compactMap { Int($0) }
                guard components.count == 3 else { throw URLError(.badURL) }
                data = Data("""
                {"tile":{"z":\(components[0]),"x":\(components[1]),"y":\(components[2])},"points":\(points),"clusters":[]}
                """.utf8)
            }
        } else if url.path == "/api/coverage/points" {
            data = Data(#"{"points":[]}"#.utf8)
        } else if url.path == "/api/social/map/snapshot" {
            guard var payload = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
                throw URLError(.cannotDecodeContentData)
            }
            payload["photosCount"] = request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-B") == true ? 2 : 1
            data = try JSONSerialization.data(withJSONObject: payload)
        } else {
            throw URLError(.unsupportedURL)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                            headerFields: ["Cache-Control": "no-store"]) else {
            throw URLError(.badServerResponse)
        }
        return (response, data)
    }
}
