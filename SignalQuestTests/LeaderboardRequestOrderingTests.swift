import XCTest
@testable import SignalQuest

@MainActor
final class LeaderboardRequestOrderingTests: XCTestCase {
    func testOlderCategoryResponseCannotReplaceCurrentSpeedRanking() async throws {
        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        let old = Task { await model.loadSpeed() }
        try await waitForRequests(service.speed, count: 1)

        model.category = "upload"
        XCTAssertEqual(model.speedResult.entries.count, 0)
        let current = Task { await model.loadSpeed() }
        try await waitForRequests(service.speed, count: 2)
        let speedRequests = await service.speed.signatures
        XCTAssertEqual(speedRequests, ["week/global/download", "week/global/upload"])

        await service.speed.succeed(1)
        await current.value
        await service.speed.succeed(0)
        await old.value

        XCTAssertEqual(model.speedResult.category, "upload")
        XCTAssertEqual(model.speedStamp, 1)
        XCTAssertNil(model.speedError)
        XCTAssertFalse(model.isLoadingSpeed)
    }

    func testOlderPointsFailureCannotStopNewPeriodAndScopeLoad() async throws {
        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        let old = Task { await model.loadPoints() }
        try await waitForRequests(service.points, count: 1)

        model.period = "month"
        model.scope = "friends"
        let current = Task { await model.loadPoints() }
        try await waitForRequests(service.points, count: 2)
        let pointsRequests = await service.points.signatures
        XCTAssertEqual(pointsRequests, ["week/global", "month/friends"])

        await service.points.fail(0)
        await old.value
        XCTAssertTrue(model.isLoadingPoints)
        XCTAssertNil(model.pointsError)

        await service.points.succeed(1)
        await current.value
        XCTAssertEqual(model.pointsResult.period, "month")
        XCTAssertEqual(model.pointsResult.scope, "friends")
        XCTAssertEqual(model.pointsStamp, 1)
        XCTAssertFalse(model.isLoadingPoints)
    }

    private func waitForRequests(_ gate: OrderedLeaderboardGate, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.count < count {
            guard ContinuousClock.now < deadline else { throw OrderedLeaderboardError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum OrderedLeaderboardError: Error { case failed, timeout }

private actor OrderedLeaderboardGate {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var signatures: [String] = []
    var count: Int { signatures.count }

    func request(_ signature: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending[signatures.count] = continuation
            signatures.append(signature)
        }
    }

    func succeed(_ index: Int) {
        pending.removeValue(forKey: index)?.resume()
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: OrderedLeaderboardError.failed)
    }
}

private struct OrderedLeaderboardService: LeaderboardServicing {
    let speed = OrderedLeaderboardGate()
    let points = OrderedLeaderboardGate()

    func leaderboard(period: String, scope: String, category: String) async throws -> LeaderboardResult {
        try await speed.request("\(period)/\(scope)/\(category)")
        return LeaderboardResult(category: category, period: period, scope: scope,
                                 entries: [], myRank: nil, generatedAt: nil, requestId: nil)
    }

    func pointsLeaderboard(period: String, scope: String) async throws -> PointsLeaderboardResult {
        try await points.request("\(period)/\(scope)")
        return PointsLeaderboardResult(scope: scope, period: period, entries: [], currentUserRank: nil)
    }
}
