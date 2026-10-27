import XCTest
@testable import SignalQuest

/// Historique commun speedtests + tests d'expérience (F10c3) : fusion par date sans trou,
/// pages tirées à la demande, rien d'un autre compte à l'écran.
@MainActor
final class UnifiedHistoryTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func speedtest(_ seconds: TimeInterval) -> SpeedtestRunResult {
        SpeedtestRunResult(label: "s", downloadMbps: 100, downloadAverageMbps: 100, downloadMaxMbps: 100,
                           durationSeconds: 10, connectionType: .wifi, createdAt: at(seconds))
    }

    private func account(_ id: String, _ seconds: TimeInterval?) -> SocialShareableSpeedtest {
        SocialShareableSpeedtest(id: id, downloadSpeed: 50, uploadSpeed: nil, ping: 20, networkType: "LTE",
                                 mobileOperator: "Orange", timestamp: seconds.map(at))
    }

    private func experience(_ id: String, _ seconds: TimeInterval, delivery: ExperienceDelivery? = nil,
                            highlights: ExperienceHighlights = ExperienceHighlights()) -> ExperienceHistoryItem {
        ExperienceHistoryItem(id: id, measuredAt: at(seconds), platform: "ios", connectionType: "wifi",
                              highlights: highlights, states: [:], delivery: delivery)
    }

    // MARK: Fusion

    func testAllMixesBothKindsByDateWhenNothingIsLeft() {
        let entries = UnifiedHistory.allEntries(
            local: [speedtest(300), speedtest(100)], account: [], accountOnly: [], accountHasMore: false,
            experience: ExperienceHistorySource(items: [experience("e1", 200), experience("e0", 50)])
        )
        XCTAssertEqual(entries.map(\.date), [at(300), at(200), at(100), at(50)])
        XCTAssertEqual(entries.filter { $0.id.hasPrefix("e:") }.count, 2)
    }

    func testAllHidesWhatIsOlderThanTheLastDeliveredPageOfAPagedSource() {
        // Le serveur a livré jusqu'à 200 et a une suite : un test plus ancien pourrait manquer
        // entre deux pages, le speedtest de 100 attend donc la page suivante.
        let source = ExperienceHistorySource(items: [experience("e2", 250), experience("e1", 200)],
                                             hasMore: true, loadedUntil: at(200))
        let entries = UnifiedHistory.allEntries(local: [speedtest(300), speedtest(100)], account: [], accountOnly: [],
                                                accountHasMore: false, experience: source)
        XCTAssertEqual(entries.map(\.date), [at(300), at(250), at(200)])
        let toLoad = UnifiedHistory.sourcesToLoad(account: [], accountHasMore: false, experience: source)
        XCTAssertFalse(toLoad.account)
        XCTAssertTrue(toLoad.experience)
    }

    func testTheAccountBoundCountsWhatWasDeliveredNotWhatIsShown() {
        // Le dernier test du compte livré (150) est aussi sur le téléphone : filtré de la liste,
        // il borne quand même, sinon le speedtest local de 120 passerait devant un trou.
        let delivered = [account("a2", 400), account("a1", 150)]
        let entries = UnifiedHistory.allEntries(
            local: [speedtest(120)], account: delivered, accountOnly: [delivered[0]], accountHasMore: true,
            experience: ExperienceHistorySource(items: [experience("e1", 130)])
        )
        XCTAssertEqual(entries.map(\.id), ["a:a2"])
        let toLoad = UnifiedHistory.sourcesToLoad(account: delivered, accountHasMore: true,
                                                  experience: ExperienceHistorySource())
        XCTAssertTrue(toLoad.account)
        XCTAssertFalse(toLoad.experience)
    }

    func testTheMostRecentBoundWinsAndOnlyItsSourceLoads() {
        let source = ExperienceHistorySource(items: [experience("e1", 500)], hasMore: true, loadedUntil: at(500))
        let delivered = [account("a1", 300)]
        let entries = UnifiedHistory.allEntries(local: [], account: delivered, accountOnly: delivered,
                                                accountHasMore: true, experience: source)
        XCTAssertEqual(entries.map(\.id), ["e:e1"])
        let toLoad = UnifiedHistory.sourcesToLoad(account: delivered, accountHasMore: true, experience: source)
        XCTAssertEqual(toLoad.account, false)
        XCTAssertEqual(toLoad.experience, true)
    }

    func testLocalExperienceRowsWaitForTheServerPageThatCouldPrecedeThem() {
        let pending = ExperienceHistorySource(items: [experience("local", 100, delivery: .pending)], hasMore: true)
        XCTAssertEqual(pending.visibleItems, [])
        XCTAssertEqual(UnifiedHistory.allEntries(local: [speedtest(50)], account: [], accountOnly: [],
                                                 accountHasMore: false, experience: pending), [])
        let done = ExperienceHistorySource(items: pending.items, hasMore: false)
        XCTAssertEqual(done.visibleItems.map(\.id), ["local"])
    }

    func testAnAccountTestWithoutADateGoesToTheBottom() {
        let entries = UnifiedHistory.allEntries(local: [speedtest(10)], account: [account("x", nil)],
                                                accountOnly: [account("x", nil)], accountHasMore: false,
                                                experience: ExperienceHistorySource())
        XCTAssertEqual(entries.map(\.id).last, "a:x")
    }

    // MARK: Ligne

    func testRowSaysOnlyWhatWasMeasured() {
        let highlights = ExperienceHighlights(videoMaxQuality: "4K", videoScore: 87, pageMedianMs: 1_340,
                                              gameMedianMs: 13, gameProbeMethod: "tcp_connect", uploadPhotoMs: nil)
        let row = ExperienceHistoryRow(item: experience("e", 0, highlights: highlights))
        XCTAssertEqual(row.summaryLine, "Vidéo\u{00A0}4K · Note\u{00A0}vidéo\u{00A0}87/100 · Page\u{00A0}1,3\u{00A0}s · Jeu\u{00A0}13\u{00A0}ms",
                       "une valeur ne se coupe jamais, seulement entre deux valeurs")
        XCTAssertFalse(row.summaryLine.contains("—"))
        XCTAssertEqual(ExperienceHistoryRow(item: experience("e", 0)).summaryLine, "Aucun test mesuré")
        let uhd = ExperienceHighlights(videoMaxQuality: "2160p")
        XCTAssertEqual(ExperienceHistoryRow(item: experience("u", 0, highlights: uhd)).summaryLine, "Vidéo\u{00A0}4K")
    }

    func testNetworkLineNamesTheOperatorAndCity() {
        var item = experience("e", 0)
        XCTAssertEqual(item.networkLine, "Wi-Fi")
        item = ExperienceHistoryItem(id: "c", measuredAt: at(0), platform: "android", connectionType: "cellular",
                                     technology: "5G", operatorKey: "orange", city: "Lyon",
                                     highlights: ExperienceHighlights(), states: [:])
        XCTAssertEqual(item.networkLine, "Orange · 5G · Lyon")
    }

    // MARK: Chargement

    private final class Fake {
        var owner = "user:a"
        var local: [ExperienceHistoryItem] = []
        var pages: [Int: Result<ExperienceHistoryPage, Error>] = [:]
        var queries: [ExperienceHistoryQuery] = []
    }

    private func model(_ fake: Fake) -> ExperienceHistoryModel {
        ExperienceHistoryModel(environment: .init(
            ownerScopeId: { fake.owner },
            localItems: { fake.local },
            history: { query in
                fake.queries.append(query)
                return try (fake.pages[query.page] ?? .success(ExperienceHistoryPage(items: [], hasMore: false))).get()
            }
        ))
    }

    func testPagesArePulledOnDemandWithEveryPeriod() async {
        let fake = Fake()
        fake.local = [experience("local", 900, delivery: .pending)]
        fake.pages[1] = .success(ExperienceHistoryPage(items: [experience("r2", 800), experience("r1", 700)], hasMore: true))
        fake.pages[2] = .success(ExperienceHistoryPage(items: [experience("r0", 600)], hasMore: false))
        let history = model(fake)
        await history.refresh()
        XCTAssertEqual(history.source.visibleItems.map(\.id), ["local", "r2", "r1"])
        XCTAssertTrue(history.source.hasMore)
        await history.loadMore()
        XCTAssertEqual(history.source.visibleItems.map(\.id), ["local", "r2", "r1", "r0"])
        XCTAssertFalse(history.source.hasMore)
        XCTAssertEqual(fake.queries.map(\.period), ["all", "all"])
        XCTAssertEqual(fake.queries.map(\.page), [1, 2])
    }

    func testAGuestNeverAsksTheServer() async {
        let fake = Fake()
        fake.owner = "guest"
        fake.local = [experience("local", 100, delivery: .localOnly)]
        let history = model(fake)
        await history.refresh()
        XCTAssertEqual(history.source.visibleItems.map(\.id), ["local"])
        XCTAssertTrue(fake.queries.isEmpty)
    }

    func testAFirstPageFailureShowsThePhoneAloneAndSaysSo() async {
        let fake = Fake()
        fake.local = [experience("local", 100, delivery: .pending)]
        fake.pages[1] = .failure(URLError(.notConnectedToInternet))
        let history = model(fake)
        await history.refresh()
        XCTAssertTrue(history.remoteUnavailable)
        XCTAssertTrue(history.loadFailed)
        XCTAssertEqual(history.source.visibleItems.map(\.id), ["local"])
    }

    func testAConfirmedLocalRowDeletedElsewhereLeavesOnceEveryPageIsIn() async {
        let fake = Fake()
        fake.local = [experience("gone", 100, delivery: .synced), experience("kept", 90, delivery: .pending)]
        fake.pages[1] = .success(ExperienceHistoryPage(items: [experience("r1", 200)], hasMore: false))
        let history = model(fake)
        await history.refresh()
        XCTAssertEqual(history.source.visibleItems.map(\.id), ["r1", "kept"])
    }

    func testNothingOfAnotherAccountStaysOnScreen() async {
        let fake = Fake()
        fake.pages[1] = .success(ExperienceHistoryPage(items: [experience("r1", 200)], hasMore: false))
        let history = model(fake)
        await history.refresh()
        XCTAssertEqual(history.merged.map(\.id), ["r1"])
        fake.owner = "user:b"
        XCTAssertEqual(history.merged, [], "avant la relecture, rien du compte précédent")
        fake.pages[1] = .success(ExperienceHistoryPage(items: [], hasMore: false))
        await history.refresh()
        XCTAssertEqual(history.merged, [])
    }
}
