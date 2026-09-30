import XCTest
@testable import SignalQuest

/// Écrans Android du Profil affichés seulement avec des données (Lot 4g, TRX-22).
@MainActor
final class AndroidDataPresenceTests: XCTestCase {
    private let suite = "AndroidDataPresenceTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Masqués seulement quand les trois sources disent « rien ».
    func testHidesOnlyWhenEverySourceSaysNothing() async {
        let presence = AndroidDataPresence(ownerScope: "a", defaults: defaults)
        XCTAssertTrue(presence.showsAndroidScreens, "Visibles tant que rien n'est vérifié")
        await presence.refresh(sessionsTotal: { 0 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertFalse(presence.showsAndroidScreens)

        let other = AndroidDataPresence(ownerScope: "b", defaults: defaults)
        await other.refresh(sessionsTotal: { 0 }, identifications: { 2 }, hasLocalLogs: { false })
        XCTAssertTrue(other.showsAndroidScreens)
    }

    /// Une erreur réseau (réponse inconnue) ne cache rien et n'est pas mémorisée.
    func testUnknownAnswerKeepsScreensVisible() async {
        let presence = AndroidDataPresence(ownerScope: "a", defaults: defaults)
        await presence.refresh(sessionsTotal: { nil }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertTrue(presence.showsAndroidScreens)
        await presence.refresh(sessionsTotal: { 0 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertFalse(presence.showsAndroidScreens, "La réponse inconnue ne devait pas être retenue")
    }

    /// Un « oui » est définitif pour le compte : plus d'appel ensuite.
    func testPositiveAnswerIsRememberedWithoutNewCalls() async {
        let first = AndroidDataPresence(ownerScope: "a", defaults: defaults)
        await first.refresh(sessionsTotal: { 3 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertTrue(first.showsAndroidScreens)

        let reopened = AndroidDataPresence(ownerScope: "a", defaults: defaults)
        var called = false
        await reopened.refresh(sessionsTotal: { called = true; return 0 },
                               identifications: { called = true; return 0 },
                               hasLocalLogs: { false })
        XCTAssertTrue(reopened.showsAndroidScreens)
        XCTAssertFalse(called)
    }

    /// Un « non » se revérifie après un jour : Android a pu se synchroniser.
    func testNegativeAnswerIsRecheckedAfterADay() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let presence = AndroidDataPresence(ownerScope: "a", defaults: defaults, now: { clock })
        await presence.refresh(sessionsTotal: { 0 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertFalse(presence.showsAndroidScreens)

        await presence.refresh(sessionsTotal: { 5 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertFalse(presence.showsAndroidScreens, "Trop tôt pour revérifier")

        clock = clock.addingTimeInterval(AndroidDataPresence.negativeLifetime + 1)
        await presence.refresh(sessionsTotal: { 5 }, identifications: { 0 }, hasLocalLogs: { false })
        XCTAssertTrue(presence.showsAndroidScreens)
    }
}
