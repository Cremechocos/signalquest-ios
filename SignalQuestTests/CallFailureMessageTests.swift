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
