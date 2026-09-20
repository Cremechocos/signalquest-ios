import XCTest
@testable import SignalQuest

@MainActor
final class OutageContextTests: XCTestCase {
    private func waitForRequests<Value: Sendable>(_ queue: VMRequestQueue<Value>, _ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await queue.count < count {
            guard ContinuousClock.now < deadline else { throw VMTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForIdle(_ model: CommunityOutagesListViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isLoading {
            guard ContinuousClock.now < deadline else { throw VMTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func outage(_ id: String) throws -> CommunityOutage {
        try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: Data("{\"id\":\"\(id)\"}".utf8))
    }

    func testOutageOldScopeCannotReplaceCurrentScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let old = Task { await model.reload() }
        try await waitForRequests(service.loads, 1)
        model.scope = .mine
        try await waitForRequests(service.loads, 2)
        await service.loads.succeed(1, (outages: [try outage("mine")], hasMore: false))
        // Wait for application of the response, not an arbitrary transport delay.
        try await waitForIdle(model)
        await service.loads.succeed(0, (outages: [try outage("all")], hasMore: false))
        await old.value
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
        XCTAssertNil(model.errorMessage)
    }

    func testOutageOldFailureCannotEraseNewPageOrStopLoading() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let old = Task { await model.reload() }
        try await waitForRequests(service.loads, 1)
        let current = Task { await model.reload() }
        try await waitForRequests(service.loads, 2)
        await service.loads.fail(0)
        await old.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.errorMessage)
        await service.loads.succeed(1, (outages: [try outage("new")], hasMore: true))
        await current.value
        XCTAssertEqual(model.outages.map(\.id), ["new"])
    }

    func testOutageOldPaginationCannotAppendToNewScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let initial = Task { await model.reload() }
        try await waitForRequests(service.loads, 1)
        let item = try outage("all")
        await service.loads.succeed(0, (outages: [item], hasMore: true))
        await initial.value
        let more = Task { await model.loadMoreIfNeeded(after: item) }
        try await waitForRequests(service.loads, 2)
        model.scope = .mine
        try await waitForRequests(service.loads, 3)
        await service.loads.succeed(2, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        await service.loads.fail(1)
        await more.value
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testLatePaginationSuccessCannotAppendOrRestoreHasMoreInAnotherScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let initial = Task { await model.reload() }
        try await waitForRequests(service.loads, 1)
        let item = try outage("all")
        await service.loads.succeed(0, (outages: [item], hasMore: true))
        await initial.value
        let more = Task { await model.loadMoreIfNeeded(after: item) }
        try await waitForRequests(service.loads, 2)
        model.scope = .mine
        try await waitForRequests(service.loads, 3)
        await service.loads.succeed(2, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        await service.loads.succeed(1, (outages: [try outage("all-next")], hasMore: true))
        await more.value
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
        XCTAssertFalse(model.hasMore)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testLateVoteFailureDoesNotPolluteAnotherScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let vote = Task { await model.vote(outageId: "old", kind: "confirm") }
        try await waitForRequests(service.votes, 1)
        model.scope = .mine
        try await waitForRequests(service.loads, 1)
        await service.loads.succeed(0, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        await service.votes.fail(0)
        await vote.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
    }

    func testLateCloseFailureDoesNotPolluteAnotherScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let close = Task { await model.close(outageId: "old") }
        try await waitForRequests(service.closes, 1)
        model.scope = .mine
        try await waitForRequests(service.loads, 1)
        await service.loads.succeed(0, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        await service.closes.fail(0)
        await close.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.closingId)
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
    }

    func testLateVoteSuccessDoesNotReloadAnotherScope() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let vote = Task { await model.vote(outageId: "old", kind: "confirm") }
        try await waitForRequests(service.votes, 1)
        model.scope = .mine
        try await waitForRequests(service.loads, 1)
        await service.loads.succeed(0, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        await service.votes.succeed(0, .init(outage: nil, award: nil, awards: nil))
        await vote.value
        let count = await service.loads.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.outages.map(\.id), ["mine"])
    }

    func testOldCloseCannotStopANewCloseAfterScopeChange() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let old = Task { await model.close(outageId: "old") }
        try await waitForRequests(service.closes, 1)
        model.scope = .mine
        try await waitForRequests(service.loads, 1)
        await service.loads.succeed(0, (outages: [try outage("mine")], hasMore: false))
        try await waitForIdle(model)
        let current = Task { await model.close(outageId: "mine") }
        try await waitForRequests(service.closes, 2)
        await service.closes.fail(0); await old.value
        XCTAssertEqual(model.closingId, "mine")
        XCTAssertNil(model.errorMessage)
        await service.closes.fail(1); await current.value
        XCTAssertNil(model.closingId)
        XCTAssertNotNil(model.errorMessage)
    }

    func testMutationFeedbackIsDiscardedAfterAccountChange() async throws {
        let previous = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "qa-outage-a")
        defer {
            if let previous { LocalAccountScope.activate(userId: previous) }
            else { LocalAccountScope.deactivate() }
        }
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let vote = Task { await model.vote(outageId: "old", kind: "confirm") }
        try await waitForRequests(service.votes, 1)
        LocalAccountScope.activate(userId: "qa-outage-b")
        await service.votes.fail(0); await vote.value
        XCTAssertNil(model.errorMessage)
        let count = await service.loads.count
        XCTAssertEqual(count, 0)
    }

    func testFailedRefreshKeepsCompatibleReading() async throws {
        let service = VMOutageService()
        let model = CommunityOutagesListViewModel(service: service, markets: VMMarketsService())
        let initial = Task { await model.reload() }
        try await waitForRequests(service.loads, 1)
        await service.loads.succeed(0, (outages: [try outage("retained")], hasMore: false))
        await initial.value
        let refresh = Task { await model.reload() }
        try await waitForRequests(service.loads, 2)
        await service.loads.fail(1); await refresh.value
        XCTAssertEqual(model.outages.map(\.id), ["retained"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
}

private enum VMTestError: Error { case failed, unexpectedCall, timeout }

private actor VMRequestQueue<Value: Sendable> {
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private(set) var count = 0

    func request() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            pending[count] = continuation
            count += 1
        }
    }

    func succeed(_ index: Int, _ value: Value) {
        guard let continuation = pending.removeValue(forKey: index) else {
            XCTFail("No pending request at index \(index)")
            return
        }
        continuation.resume(returning: value)
    }

    func fail(_ index: Int, _ error: Error = VMTestError.failed) {
        guard let continuation = pending.removeValue(forKey: index) else {
            XCTFail("No pending request at index \(index)")
            return
        }
        continuation.resume(throwing: error)
    }
}

private struct VMOutageService: CommunityOutageServicing {
    let votes = VMRequestQueue<OutageWriteResponse>()
    let closes = VMRequestQueue<OutageWriteResponse>()
    let loads = VMRequestQueue<(outages: [CommunityOutage], hasMore: Bool)>()
    func outages(forSiteId siteId: String, targetKind: String, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage] { throw VMTestError.unexpectedCall }
    func outages(in bounds: MapBounds, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage] { throw VMTestError.unexpectedCall }
    func feed(scope: OutageFeedScope, offset: Int, limit: Int) async throws -> (outages: [CommunityOutage], hasMore: Bool) { return try await loads.request() }
    func detail(outageId: String) async throws -> CommunityOutage { throw VMTestError.unexpectedCall }
    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse { throw VMTestError.unexpectedCall }
    func vote(outageId: String, kind: String, latitude: Double?, longitude: Double?, accuracyMeters: Double?) async throws -> OutageWriteResponse { try await votes.request() }
    func close(outageId: String) async throws -> OutageWriteResponse { try await closes.request() }
}

private struct VMMarketsService: MarketRegistryServicing {
    func registry() async -> MarketRegistryPayload { return .empty }
    func market(forCode code: String?) async -> MarketRegistryEntry? { return nil }
    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? { return nil }
    func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool { return false }
    func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool { return false }
}
