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

    /// Planche Classement du 24/11 : la mesure et la période sont à l'écran, seule la
    /// portée vit dans la feuille « Affiner » ; sa pastille ne compte qu'elle, et
    /// « Réinitialiser » ne touche qu'elle.
    func testSheetFilterCountAndResetOnlyTouchTheSheetFilters() async throws {
        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        XCTAssertEqual(model.sheetFilterCount, 0)

        model.period = "month"
        model.category = "upload"
        XCTAssertEqual(model.sheetFilterCount, 0, "la période et la mesure ne sont pas des filtres de la feuille")
        model.scope = "friends"
        XCTAssertEqual(model.sheetFilterCount, 1)

        model.resetSheetFilters()
        XCTAssertEqual(model.sheetFilterCount, 0)
        XCTAssertEqual([model.period, model.scope, model.category], ["month", "global", "upload"])
        try await waitForRequests(service.speed, count: 1)
        try await waitForRequests(service.points, count: 1)
        let speedRequests = await service.speed.signatures
        let pointsRequests = await service.points.signatures
        XCTAssertEqual(speedRequests, ["month/global/upload"])
        XCTAssertEqual(pointsRequests, ["month/global"])
        await service.speed.succeed(0)
        await service.points.succeed(0)
    }

    /// Le segmenté Points | Download | Upload pilote l'onglet et la catégorie servie ;
    /// « Sessions » n'en fait plus partie.
    func testMetricSegmentDrivesTabAndCategory() async throws {
        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        XCTAssertEqual(model.metric, .download)
        XCTAssertEqual(LeaderboardMetric.allCases, [.points, .download, .upload])

        model.selectMetric(.upload)
        XCTAssertEqual(model.tab, .speed)
        XCTAssertEqual(model.category, "upload")
        XCTAssertEqual(model.metric, .upload)
        try await waitForRequests(service.speed, count: 1)
        let speedRequests = await service.speed.signatures
        XCTAssertEqual(speedRequests, ["week/global/upload"])

        model.selectMetric(.points)
        XCTAssertEqual(model.tab, .points)
        XCTAssertEqual(model.metric, .points)

        model.selectMetric(.download)
        XCTAssertEqual(model.tab, .speed)
        XCTAssertEqual(model.metric, .download)
        await service.speed.succeed(0)
    }

    /// IOS-076 : la date d'une rangée se lit « il y a 16 s », jamais « -16 s ».
    func testRowDateReadsAsAgoInBothLanguages() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func text(_ locale: String, _ seconds: TimeInterval) -> String {
            LeaderboardRowDate.makeFormatter(locale: Locale(identifier: locale))
                .localizedString(for: now.addingTimeInterval(-seconds), relativeTo: now)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(text("fr_FR", 16), "il y a 16 s")
        XCTAssertEqual(text("fr_FR", 3 * 86_400), "il y a 3 j")
        XCTAssertEqual(text("en_US", 16), "16 sec. ago")
        for seconds: TimeInterval in [16, 5 * 3_600, 3 * 86_400] {
            XCTAssertFalse(text("fr_FR", seconds).hasPrefix("-"), "Pas de signe moins en français")
        }
    }

    /// Contrat classements v1 : opérateur et réseau ne partent que pour les débits, et la
    /// pastille compte les trois filtres de la feuille ; « Réinitialiser » les retire en une
    /// seule relecture.
    func testOperatorAndNetworkFiltersReachTheSpeedRequestOnly() async throws {
        let speedQuery = LeaderboardService.query(period: "week", scope: "department", category: "download",
                                                  filters: LeaderboardFilters(operatorKey: "SFR", tech: "5G"))
        XCTAssertEqual(speedQuery.map { "\($0.name)=\($0.value ?? "")" },
                       ["period=week", "scope=department", "category=download", "operator=SFR", "tech=5G"])
        let pointsQuery = LeaderboardService.query(period: "month", scope: "global", category: "points",
                                                   filters: LeaderboardFilters(operatorKey: "SFR", tech: "5G"))
        XCTAssertEqual(pointsQuery.map(\.name), ["period", "scope", "category"], "Points ne porte pas les filtres de débit")

        let service = OrderedLeaderboardService()
        let model = LeaderboardsViewModel(service: service)
        model.setOperator("ORANGE")
        try await waitForRequests(service.speed, count: 1)
        model.setTech("4G")
        try await waitForRequests(service.speed, count: 2)
        model.scope = "friends"
        XCTAssertEqual(model.sheetFilterCount, 3)
        let speedRequests = await service.speed.signatures
        XCTAssertEqual(speedRequests, ["week/global/download/ORANGE", "week/global/download/ORANGE+4G"])

        model.resetSheetFilters()
        XCTAssertEqual(model.sheetFilterCount, 0)
        XCTAssertNil(model.operatorKey)
        XCTAssertNil(model.tech)
        XCTAssertEqual(model.scope, "global")
        try await waitForRequests(service.speed, count: 3)
        try await waitForRequests(service.points, count: 1)
        let afterReset = await service.speed.signatures
        XCTAssertEqual(afterReset.last, "week/global/download")
        let pointsRequests = await service.points.signatures
        XCTAssertEqual(pointsRequests, ["week/global"], "Points relu une fois, sur la route commune")
        for index in 0..<3 { await service.speed.succeed(index) }
        await service.points.succeed(0)
    }

    /// Les champs du contrat v1 se décodent, et une valeur malformée ne fait tomber ni
    /// l'entrée ni mon rang ; « +N places » ne paraît que pour un gain.
    func testVersionOneFieldsDecodeWithoutEverDroppingAnEntryOrTheRank() throws {
        let raw = #"""
        {"category":"download","period":"week","scope":"department",
         "department":{"code":"30","name":"Gard"},
         "entries":[
          {"rank":1,"user":{"id":"a","name":"A"},"value":1046.4,"unit":"Mbps","tech":"5G NSA","operator":"Orange",
           "city":"Nîmes","capturedAt":"2026-11-24T18:02:11.000Z","speedtestId":"st-1"},
          {"rank":2,"user":{"id":"b","name":"B"},"value":900,"unit":"Mbps","speedtestId":{"bad":true},"city":null}
         ],
         "myRank":{"rank":4,"total":13,"entry":null,"gapToNext":{"value":12.3,"unit":"Mbps"},"previousRank":6}}
        """#
        let result = try JSONDecoder.signalQuest.decode(LeaderboardResult.self, from: Data(raw.utf8))
        XCTAssertEqual(result.department, LeaderboardDepartment(code: "30", name: "Gard"))
        XCTAssertEqual(result.entries.count, 2, "un speedtestId malformé ne fait pas tomber l'entrée")
        XCTAssertEqual(result.entries[0].speedtestId, "st-1")
        XCTAssertNil(result.entries[1].speedtestId)
        XCTAssertEqual(result.myRank?.gapToNext, LeaderboardGap(value: 12.3, unit: "Mbps"))
        XCTAssertEqual(result.myRank?.placesGained, 2)

        let malformedRank = #"{"entries":[],"myRank":{"rank":4,"total":13,"gapToNext":"x","previousRank":"y"}}"#
        let degraded = try JSONDecoder.signalQuest.decode(LeaderboardResult.self, from: Data(malformedRank.utf8))
        XCTAssertEqual(degraded.myRank?.rank, 4, "un gapToNext malformé ne fait pas tomber mon rang")
        XCTAssertNil(degraded.myRank?.gapToNext)
        XCTAssertNil(degraded.myRank?.placesGained)

        XCTAssertNil(LeaderboardMyRank(rank: 6, total: 13, entry: nil, previousRank: 4).placesGained, "un recul n'affiche rien")
        XCTAssertNil(LeaderboardMyRank(rank: 6, total: 13, entry: nil, previousRank: 6).placesGained)
    }

    /// « Mon dép. » sans département : un état dédié, pas une panne.
    func testMissingDepartmentIsNotAnOutage() {
        XCTAssertTrue(LeaderboardsViewModel.isDepartmentMissing(
            APIError.http(status: 400, code: "DEPARTMENT_REQUIRED", message: "", requestId: nil, retryAfter: nil)))
        XCTAssertFalse(LeaderboardsViewModel.isDepartmentMissing(
            APIError.http(status: 400, code: "INVALID_FILTER", message: "", requestId: nil, retryAfter: nil)))
        XCTAssertFalse(LeaderboardsViewModel.isDepartmentMissing(APIError.transport("offline")))
    }

    /// Reçu de `POST /api/speedtests` (contrat v1) : lu à part, il ne peut jamais faire échouer
    /// l'accusé de réception ; absent, nul ou malformé, il n'existe simplement pas.
    func testSpeedtestReceiptNeverBreaksTheAcknowledgement() throws {
        func body(_ leaderboard: String?) -> Data {
            let extra = leaderboard.map { #","leaderboard":\#($0)"# } ?? ""
            return Data(#"{"success":true,"id":"st-9"\#(extra)}"#.utf8)
        }
        let cases: [(String?, Bool)] = [
            (nil, false), ("null", false), (#""oops""#, false), ("[1,2]", false),
            (#"{"period":"week","exclusionReason":null,"download":{"rankBefore":7,"rankAfter":3,"total":14,"rankedValue":300,"peakValue":320,"previousRecord":30},"upload":null}"#, true)
        ]
        for (leaderboard, present) in cases {
            let data = body(leaderboard)
            let ack = try JSONDecoder.signalQuest.decode(SpeedtestSaveResponse.self, from: data)
            XCTAssertTrue(ack.success, "l'accusé se décode quel que soit le reçu : \(leaderboard ?? "absent")")
            XCTAssertEqual(ack.resolvedID, "st-9")
            XCTAssertEqual(SpeedtestLeaderboardReceipt.decode(fromSaveResponse: data) != nil, present, leaderboard ?? "absent")
        }

        let valid = try XCTUnwrap(SpeedtestLeaderboardReceipt.decode(fromSaveResponse: body(cases[4].0)))
        XCTAssertEqual(valid.shown?.category, .download)
        XCTAssertEqual(valid.shown?.line.rankAfter, 3)
        XCTAssertTrue(valid.isDisplayable)

        // Un champ malformé ne fait tomber que lui ; l'upload sert quand le download n'est pas classé.
        let partial = try XCTUnwrap(SpeedtestLeaderboardReceipt.decode(fromSaveResponse: body(
            #"{"period":"week","download":{"rankBefore":"x","rankAfter":null,"rankedValue":12},"upload":{"rankBefore":"y","rankAfter":5,"total":14,"rankedValue":40,"peakValue":55}}"#)))
        XCTAssertNil(partial.download?.rankBefore)
        XCTAssertEqual(partial.shown?.category, .upload)
        XCTAssertNil(partial.shown?.line.rankBefore, "entrée au classement")

        let wifi = try XCTUnwrap(SpeedtestLeaderboardReceipt.decode(fromSaveResponse: body(
            #"{"period":"week","exclusionReason":"WIFI","download":null,"upload":null}"#)))
        XCTAssertNil(wifi.shown)
        XCTAssertTrue(wifi.isDisplayable, "hors classement : la feuille dit pourquoi")
        let empty = SpeedtestLeaderboardReceipt(period: "week", exclusionReason: nil, download: nil, upload: nil)
        XCTAssertFalse(empty.isDisplayable, "rien à dire : pas de feuille")

        SpeedtestLeaderboardReceiptStore.put(valid, forClientId: "client-1")
        XCTAssertEqual(SpeedtestLeaderboardReceiptStore.take(forClientId: "client-1"), valid)
        XCTAssertNil(SpeedtestLeaderboardReceiptStore.take(forClientId: "client-1"), "lu une seule fois")
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

    func leaderboard(period: String, scope: String, category: String, filters: LeaderboardFilters) async throws -> LeaderboardResult {
        // Points passe par la même route depuis le 25/11 : sa porte reste à part pour les tests.
        if category == "points" {
            try await points.request("\(period)/\(scope)")
        } else {
            let suffix = [filters.operatorKey, filters.tech].compactMap { $0 }.joined(separator: "+")
            try await speed.request("\(period)/\(scope)/\(category)" + (suffix.isEmpty ? "" : "/\(suffix)"))
        }
        return LeaderboardResult(category: category, period: period, scope: scope,
                                 entries: [], myRank: nil, generatedAt: nil, requestId: nil)
    }

    func pointsLeaderboard(period: String, scope: String) async throws -> PointsLeaderboardResult {
        try await points.request("\(period)/\(scope)")
        return PointsLeaderboardResult(scope: scope, period: period, entries: [], currentUserRank: nil)
    }
}
