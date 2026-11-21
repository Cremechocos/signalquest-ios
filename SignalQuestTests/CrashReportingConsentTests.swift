import XCTest
@testable import SignalQuest

/// Rapports de plantage sur consentement, comme sur Android (choix d'Alexandre du
/// 21/11) : collecte coupée par l'Info.plist, un « oui » la rallume et envoie les
/// rapports en attente, un « non » la coupe et les supprime.
@MainActor
final class CrashReportingConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "CrashReportingConsentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Ce que l'app a demandé au SDK, dans l'ordre.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func collector(_ calls: Calls) -> CrashReportingConsent.Collector {
        CrashReportingConsent.Collector(
            setCollectionEnabled: { calls.append($0 ? "enable" : "disable") },
            sendUnsentReports: { calls.append("send") },
            deleteUnsentReports: { calls.append("delete") }
        )
    }

    /// Sans cette clé, le SDK collecterait dès `FirebaseApp.configure()`, avant toute question.
    func testInfoPlistTurnsAutomaticCollectionOff() {
        let value = Bundle.main.object(forInfoDictionaryKey: "FirebaseCrashlyticsCollectionEnabled")
        XCTAssertEqual(value as? Bool, false)
    }

    func testNothingIsSentOrDeletedBeforeAChoice() {
        let calls = Calls()
        CrashReportingConsent.applyAtLaunch(defaults: defaults, collector: collector(calls))
        XCTAssertEqual(calls.all, [])
        XCTAssertNil(CrashReportingConsent.choice(in: defaults))
        XCTAssertFalse(CrashReportingConsent.allowsReports(in: defaults))
    }

    func testConsentEnablesCollectionAndSendsPendingReports() {
        let calls = Calls()
        CrashReportingConsent.record(.granted, defaults: defaults, collector: collector(calls))
        XCTAssertEqual(calls.all, ["enable", "send"])
        XCTAssertTrue(CrashReportingConsent.allowsReports(in: defaults))

        let nextLaunch = Calls()
        CrashReportingConsent.applyAtLaunch(defaults: defaults, collector: collector(nextLaunch))
        XCTAssertEqual(nextLaunch.all, ["enable"])
    }

    func testRefusalDisablesCollectionAndDeletesPendingReports() {
        let calls = Calls()
        CrashReportingConsent.record(.granted, defaults: defaults, collector: collector(calls))
        CrashReportingConsent.record(.denied, defaults: defaults, collector: collector(calls))
        XCTAssertEqual(calls.all, ["enable", "send", "disable", "delete"])
        XCTAssertFalse(CrashReportingConsent.allowsReports(in: defaults))

        // Le réglage du SDK ne vaut qu'au lancement suivant : ce qui a été noté entre-temps part à la corbeille.
        let nextLaunch = Calls()
        CrashReportingConsent.applyAtLaunch(defaults: defaults, collector: collector(nextLaunch))
        XCTAssertEqual(nextLaunch.all, ["disable", "delete"])
    }

    /// Clone sans `GoogleService-Info.plist` : le choix est gardé, rien n'est demandé au SDK.
    func testChoiceIsKeptWithoutFirebase() {
        CrashReportingConsent.record(.denied, defaults: defaults, collector: nil)
        XCTAssertEqual(CrashReportingConsent.choice(in: defaults), .denied)
    }

    func testTheQuestionIsAskedOnceThenAnsweredForGood() {
        let calls = Calls()
        let store = CrashReportingConsentStore(defaults: defaults, asks: true, collector: { self.collector(calls) })
        XCTAssertTrue(store.needsDecision)
        XCTAssertTrue(store.isAvailable)

        store.choose(.denied)
        XCTAssertFalse(store.needsDecision)
        XCTAssertEqual(store.choice, .denied)
        XCTAssertEqual(calls.all, ["disable", "delete"])

        // Au lancement suivant, la réponse est relue : plus de question.
        let relaunched = CrashReportingConsentStore(defaults: defaults, asks: true, collector: { nil })
        XCTAssertFalse(relaunched.needsDecision)
        XCTAssertEqual(relaunched.choice, .denied)
        XCTAssertFalse(relaunched.isAvailable)
    }

    /// Démo, tests UI, poste de développement sans `--qa-crash-consent` : pas d'écran.
    func testTheQuestionIsNotAskedWhereItWouldBlockAScriptedRun() {
        let store = CrashReportingConsentStore(defaults: defaults, asks: false, collector: { nil })
        XCTAssertFalse(store.needsDecision)
        XCTAssertNil(store.choice)
    }
}
