import XCTest
@testable import SignalQuest

/// Un appel qui échoue s'explique en mots simples, sans le message brut du
/// transport (SOC-13).
final class CallFailureMessageTests: XCTestCase {

    func testTransportFailureIsExplainedWithoutRawMessage() throws {
        let message = try XCTUnwrap(
            CallManager.failureMessage(for: CallManager.CallError.connectionFailed("could not establish pc connection"))
        )
        XCTAssertFalse(message.contains("pc connection"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("LiveKit"))
        XCTAssertEqual(message, String(localized: "Connexion à l’appel impossible. Vérifie ta connexion et réessaie."))
    }

    func testMissingCredentialsReadsLikeAConnectionFailure() {
        XCTAssertEqual(
            CallManager.failureMessage(for: CallManager.CallError.missingCredentials),
            CallManager.failureMessage(for: CallManager.CallError.connectionFailed("x"))
        )
    }

    func testEncryptionFailureSaysNoCallWasMade() {
        XCTAssertEqual(
            CallManager.failureMessage(for: CallManager.CallError.untrustedE2EESession),
            String(localized: "La vérification du chiffrement de l’appel a échoué. Aucun appel n’a été passé.")
        )
    }

    /// Spec §2.6 (v0.4.13) : resté verrouillé jusqu'à la fin de l'attente,
    /// l'appel est manqué, et l'écran de fin dit pourquoi.
    func testALockedDeviceExplainsTheMissedCall() {
        XCTAssertEqual(
            CallManager.failureMessage(for: CallManager.CallError.deviceLocked),
            String(localized: "Appel chiffré manqué : ton appareil est resté verrouillé.")
        )
    }

    func testCancellationStaysSilent() {
        XCTAssertNil(CallManager.failureMessage(for: CancellationError()))
    }

    func testOfflineUsesTheSharedNetworkMessage() {
        XCTAssertEqual(
            CallManager.failureMessage(for: URLError(.notConnectedToInternet)),
            URLError(.notConnectedToInternet).userFacingMessage
        )
    }
}

/// Audit perf, D1 : le jeton VoIP ne repart que s'il a changé (jeton, appareil,
/// environnement, compte ou session locale), une fois par jour au plus sinon, et
/// toujours après une déconnexion.
final class VoIPTokenSyncRecordTests: XCTestCase {
    func testTheSameTokenIsSentOnceADayAndAnyChangeSendsItAgain() throws {
        let suite = "voip-token-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = VoIPTokenSyncRecord(defaults: defaults)
        let session = LocalAccountSession(ownerScopeId: "user:a", sessionId: "s1")
        let sent = VoIPTokenSyncRecord.fingerprint(token: "t1", deviceID: "d1", environment: "production", session: session)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(record.isSynced(sent, now: start), "Jamais envoyé : il part")
        record.markSynced(sent, now: start)
        let stored = try XCTUnwrap(defaults.dictionary(forKey: "call.voip-token-sync.v1"))
        XCTAssertFalse(stored.values.contains { "\($0)".contains("t1") }, "Le jeton n'est jamais écrit")
        XCTAssertTrue(record.isSynced(sent, now: start.addingTimeInterval(3_600)), "Relancement dans la journée : rien ne part")
        XCTAssertFalse(record.isSynced(sent, now: start.addingTimeInterval(VoIPTokenSyncRecord.maximumAge)), "Un jour après : il repart")
        XCTAssertFalse(record.isSynced(sent, now: start.addingTimeInterval(-60)), "Horloge reculée : il repart")

        for changed in [
            VoIPTokenSyncRecord.fingerprint(token: "t2", deviceID: "d1", environment: "production", session: session),
            VoIPTokenSyncRecord.fingerprint(token: "t1", deviceID: "d2", environment: "production", session: session),
            VoIPTokenSyncRecord.fingerprint(token: "t1", deviceID: "d1", environment: "staging", session: session),
            VoIPTokenSyncRecord.fingerprint(token: "t1", deviceID: "d1", environment: "production",
                                            session: LocalAccountSession(ownerScopeId: "user:b", sessionId: "s1")),
            VoIPTokenSyncRecord.fingerprint(token: "t1", deviceID: "d1", environment: "production",
                                            session: LocalAccountSession(ownerScopeId: "user:a", sessionId: "s2")),
        ] {
            XCTAssertFalse(record.isSynced(changed, now: start.addingTimeInterval(60)))
        }

        record.clear()
        XCTAssertFalse(record.isSynced(sent, now: start.addingTimeInterval(60)), "Après une déconnexion : il repart")
    }
}
