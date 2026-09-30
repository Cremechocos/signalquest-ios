import XCTest
@testable import SignalQuest

/// Service de préférences en mémoire : garde chaque PATCH reçu.
private final class PrefsUserService: UserServicing, @unchecked Sendable {
    enum Unused: Error { case notImplemented }
    var stored = NotificationPreferences.empty
    var patches: [NotificationPreferences] = []
    var failNextPatch = false
    /// Reproduit le PATCH serveur qui oubliait `notifySocialPush` dans sa réponse.
    var omitSocialInResponse = false

    func notificationPreferences() async throws -> NotificationPreferences { stored }

    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws -> NotificationPreferences {
        patches.append(prefs)
        if failNextPatch {
            failNextPatch = false
            throw APIError.http(status: 500, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        if let value = prefs.notifyMessagesPush { stored.notifyMessagesPush = value }
        if let value = prefs.notifySocialPush { stored.notifySocialPush = value }
        if let value = prefs.callsDoNotDisturb { stored.callsDoNotDisturb = value }
        var response = stored
        if omitSocialInResponse { response.notifySocialPush = nil }
        return response
    }

    func exportPersonalData() async throws -> Data { throw Unused.notImplemented }
    func profile() async throws -> AuthUser { throw Unused.notImplemented }
    func updateProfile(_ patch: UserProfilePatch) async throws -> AuthUser { throw Unused.notImplemented }
    func checkHandleAvailability(_ handle: String) async throws -> HandleAvailability { throw Unused.notImplemented }
    func uploadAvatar(data: Data, filename: String, mimeType: String) async throws -> AuthUser { throw Unused.notImplemented }
    func stats() async throws -> UserStats { throw Unused.notImplemented }
    func heartbeat() async throws { throw Unused.notImplemented }
    func accountDeletionPreview() async throws -> AccountDeletionPreview { throw Unused.notImplemented }
    func requestAccountDeletionEmailCode() async throws -> AccountDeletionEmailChallenge { throw Unused.notImplemented }
    func deleteAccount(using proof: AccountDeletionProof) async throws -> AccountDeletionResult { throw Unused.notImplemented }
}

/// Réglages de notifications enregistrés au geste (Lot 4g, TRX-03).
@MainActor
final class NotificationSettingsAutosaveTests: XCTestCase {
    private func makeModel(_ service: PrefsUserService) -> NotificationSettingsModel {
        NotificationSettingsModel(userService: service)
    }

    /// Les interrupteurs restent grisés tant que les préférences sont inconnues.
    func testTogglesWaitForTheFirstLoad() async {
        let service = PrefsUserService()
        service.stored.notifyMessagesPush = true
        let model = makeModel(service)
        XCTAssertFalse(model.prefsLoaded)
        await model.load()
        XCTAssertTrue(model.prefsLoaded)
        XCTAssertEqual(model.prefs.notifyMessagesPush, true)
    }

    /// Un geste = un PATCH qui ne contient que ce réglage.
    func testEachToggleSendsOnlyItsOwnField() async {
        let service = PrefsUserService()
        let model = makeModel(service)
        await model.load()
        model.setPreference(\.notifyMessagesPush, to: true)
        model.setPreference(\.callsDoNotDisturb, to: true)
        await model.waitForPendingWrites()
        XCTAssertEqual(service.patches.count, 2)
        XCTAssertEqual(service.patches[0].notifyMessagesPush, true)
        XCTAssertNil(service.patches[0].callsDoNotDisturb)
        XCTAssertEqual(service.patches[1].callsDoNotDisturb, true)
        XCTAssertNil(service.patches[1].notifyMessagesPush)
        XCTAssertEqual(model.prefs.notifyMessagesPush, true)
        XCTAssertEqual(model.prefs.callsDoNotDisturb, true)
    }

    /// Un échec ne ramène que le réglage concerné, et le dit.
    func testAFailedWriteRollsBackOnlyThatToggle() async {
        let service = PrefsUserService()
        service.stored.notifyMessagesPush = false
        let model = makeModel(service)
        await model.load()
        service.failNextPatch = true
        model.setPreference(\.notifyMessagesPush, to: true)
        model.setPreference(\.callsDoNotDisturb, to: true)
        await model.waitForPendingWrites()
        XCTAssertEqual(model.prefs.notifyMessagesPush, false)
        XCTAssertEqual(model.prefs.callsDoNotDisturb, true)
        XCTAssertNotNil(model.errorMessage)
    }

    /// Réponse muette sur un champ : la valeur envoyée reste affichée (l'ancien
    /// « Enregistrer » affichait « non » juste après avoir enregistré « oui »).
    func testAResponseWithoutTheFieldKeepsTheSentValue() async {
        let service = PrefsUserService()
        service.omitSocialInResponse = true
        let model = makeModel(service)
        await model.load()
        model.setPreference(\.notifySocialPush, to: true)
        await model.waitForPendingWrites()
        XCTAssertEqual(model.prefs.notifySocialPush, true)
        XCTAssertEqual(service.stored.notifySocialPush, true)
    }
}
