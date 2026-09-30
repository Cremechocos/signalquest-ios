import XCTest
import UserNotifications
@testable import SignalQuest

/// Demande des notifications au bon moment (Lot 4g, TRX-01).
@MainActor
final class NotificationPrimingTests: XCTestCase {
    private let suite = "NotificationPrimingTests"
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

    /// iOS n'a jamais posé la question : la feuille s'ouvre une fois, pas deux.
    func testExplainsOnceWhenIOSHasNeverAsked() async {
        var shown: [NotificationPrimingCoordinator.Reason] = []
        let coordinator = NotificationPrimingCoordinator(
            defaults: defaults, isEnabled: { true }, authorizationStatus: { .notDetermined },
            presentSheet: { shown.append($0); return true })
        let first = await coordinator.considerPriming(after: .messageSent)
        let second = await coordinator.considerPriming(after: .postPublished)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(shown, [.messageSent])
    }

    /// Une réponse déjà donnée à iOS, oui ou non, ne se redemande pas.
    func testNeverExplainsOnceIOSHasAnswered() async {
        for status in [UNAuthorizationStatus.authorized, .denied, .provisional] {
            var presented = false
            let coordinator = NotificationPrimingCoordinator(
                defaults: defaults, isEnabled: { true }, authorizationStatus: { status },
                presentSheet: { _ in presented = true; return true })
            let result = await coordinator.considerPriming(after: .antennaAlert)
            XCTAssertFalse(result)
            XCTAssertFalse(presented, "Feuille montrée alors qu’iOS a déjà la réponse (\(status.rawValue))")
        }
    }

    /// Une feuille qui se ferme (le compositeur après publication) retarde la
    /// présentation au lieu de la perdre.
    func testRetriesWhileAnotherSheetCloses() async {
        var attempts = 0
        let coordinator = NotificationPrimingCoordinator(
            defaults: defaults, isEnabled: { true }, authorizationStatus: { .notDetermined },
            presentSheet: { _ in attempts += 1; return attempts >= 3 })
        let result = await coordinator.considerPriming(after: .postPublished)
        XCTAssertTrue(result)
        XCTAssertEqual(attempts, 3)
    }

    /// Démo et tests d'interface : jamais de feuille.
    func testDemoModeNeverExplains() async {
        var presented = false
        let coordinator = NotificationPrimingCoordinator(
            defaults: defaults, isEnabled: { false }, authorizationStatus: { .notDetermined },
            presentSheet: { _ in presented = true; return true })
        let result = await coordinator.considerPriming(after: .messageSent)
        XCTAssertFalse(result)
        XCTAssertFalse(presented)
    }
}
