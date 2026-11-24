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

    /// Audit perf D1 (résidu, IOS-026) : le même jeton FCM ne part qu'une fois par heure
    /// pour une même empreinte ; une autre langue, un autre compte, un échec ou une
    /// déconnexion relancent.
    func testFCMRegistrationIsSentOncePerFingerprintAndHour() {
        let suffix = UUID().uuidString
        let fr = PushNotificationService.registrationFingerprint(
            owner: "owner-a-\(suffix)", token: "token", deviceID: "device", environment: "production",
            locale: "fr", timeZone: "Europe/Paris")
        let en = PushNotificationService.registrationFingerprint(
            owner: "owner-a-\(suffix)", token: "token", deviceID: "device", environment: "production",
            locale: "en", timeZone: "Europe/Paris")
        let start = Date()
        XCTAssertTrue(PushNotificationService.reserveRegistration(fr, now: start))
        XCTAssertFalse(PushNotificationService.reserveRegistration(fr, now: start.addingTimeInterval(1)), "Doublon du lancement")
        XCTAssertTrue(PushNotificationService.reserveRegistration(en, now: start.addingTimeInterval(2)), "Autre langue : envoi")
        XCTAssertTrue(PushNotificationService.reserveRegistration(fr, now: start.addingTimeInterval(3_601)), "Une heure après : envoi")
        PushNotificationService.releaseRegistration(fr)
        XCTAssertTrue(PushNotificationService.reserveRegistration(fr, now: start.addingTimeInterval(3_602)), "Après un échec : envoi")
        PushNotificationService.resetRegistrations()
        XCTAssertTrue(PushNotificationService.reserveRegistration(fr, now: start.addingTimeInterval(3_603)), "Après une déconnexion : envoi")
    }

    /// IOS-015 : l'accord des notifications allume « Messages privés », et lui seul.
    func testGrantTurnsOnPrivateMessagesOnly() throws {
        let body = try JSONEncoder().encode(PushNotificationService.messagePushAfterGrant)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object.count, 1, "Aucun autre réglage dans le PATCH : \(object.keys.sorted())")
        XCTAssertEqual(object["notifyMessagesPush"] as? Bool, true)
    }
}
