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

    func testDisplaySettingsDotFollowsDefaultsAndResetReloadsBoth() async throws {
        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        XCTAssertFalse(model.hasCustomFilters)

        model.scope = "friends"
        model.category = "sessions"
        XCTAssertTrue(model.hasCustomFilters)

        model.resetFilters()
        XCTAssertFalse(model.hasCustomFilters)
        XCTAssertEqual([model.period, model.scope, model.category], ["week", "global", "download"])
        try await waitForRequests(service.speed, count: 1)
        try await waitForRequests(service.points, count: 1)
        let speedRequests = await service.speed.signatures
        let pointsRequests = await service.points.signatures
        XCTAssertEqual(speedRequests, ["week/global/download"])
        XCTAssertEqual(pointsRequests, ["week/global"])
        await service.speed.succeed(0)
        await service.points.succeed(0)
    }

    func testRankedValuesUseBitsPerSecondAndKeepOtherUnits() {
        let speed = LeaderboardsView.valueText(712, unit: "Mbps")
        XCTAssertTrue(speed.hasPrefix("712"), speed)
        XCTAssertTrue(speed.hasSuffix("Mb/s"), speed)
        XCTAssertEqual(LeaderboardsView.valueText(12, unit: "sessions"), "12 sessions")
    }

    func testBadgeMedallionComesFromCatalogThenServerThenIdentifier() {
        func badge(_ id: String, category: String? = nil, rarity: String? = nil) -> GamificationBadge {
            GamificationBadge(id: id, title: nil, description: nil, iconUrl: nil, icon: "🚀",
                              unlockedAt: nil, tier: nil, category: category, rarity: rarity)
        }
        let known = badge("speedtester_gold")
        XCTAssertEqual(known.family, .speedtest)
        XCTAssertEqual(known.symbol, "speedometer")
        XCTAssertEqual(known.rarityLevel, .rare)
        XCTAssertEqual(badge("speedtester_gold", rarity: "epic").rarityLevel, .epic)

        let fromServer = badge("new_badge", category: "coverage")
        XCTAssertEqual(fromServer.family, .coverage)
        XCTAssertEqual(fromServer.symbol, GamificationBadgeFamily.coverage.fallbackSymbol)
        XCTAssertNil(fromServer.rarityLevel)

        XCTAssertEqual(badge("photographer_diamond").family, .contribution)
        XCTAssertEqual(badge("mystery").family, .special)
    }

    func testActivityPointsCarryTheirSignAndAgreement() {
        XCTAssertEqual(GamificationView.pointsDeltaText(6), "+" + String(localized: "\(6) pts"))
        XCTAssertEqual(GamificationView.pointsDeltaText(-3), "−" + String(localized: "\(3) pts"))
        XCTAssertEqual(GamificationView.pointsDeltaText(0), String(localized: "\(0) pts"))
        // Accord : « 1 pt », pas « 1 pts ».
        XCTAssertFalse(GamificationView.pointsDeltaText(1).hasSuffix("pts"))
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
