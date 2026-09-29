import Foundation
import XCTest
@testable import SignalQuest

/// Lot 3d : chaque erreur affichée dit ce qui s'est passé en clair, sans nom de
/// type ni vocabulaire de protocole (TRX-26, SOC-29, MES-16).
final class UserFacingErrorTests: XCTestCase {
    private enum SilentFailure: Error { case boom }

    func testDescribedErrorsKeepTheirOwnMessage() {
        let api = APIError.transport("socket closed")
        XCTAssertEqual(api.userFacingMessage, api.errorDescription)
        XCTAssertEqual(IPerf3Error.accessDenied.userFacingMessage,
            "Ce serveur de mesure est occupé. Réessaie dans un instant, ou choisis-en un autre.")
    }

    func testIPerfFailuresNoLongerShowProtocolDetails() {
        for error in [IPerf3Error.connectionClosed(got: 12, expected: 40), .unexpectedState(7), .invalidJSON, .accessDenied] {
            let message = error.userFacingMessage
            XCTAssertFalse(message.contains("iPerf3"), message)
            XCTAssertFalse(message.contains("ACCESS_DENIED"), message)
            XCTAssertFalse(message.contains("octets"), message)
        }
    }

    func testNetworkFailuresUsePlainWords() {
        XCTAssertEqual(URLError(.notConnectedToInternet).userFacingMessage,
            "Pas de connexion Internet. Vérifie ton réseau puis réessaie.")
        XCTAssertEqual(URLError(.timedOut).userFacingMessage, "Le serveur met trop de temps à répondre. Réessaie.")
    }

    func testSystemErrorsKeepTheirTranslatedText() {
        let system = NSError(domain: "PHPhotosErrorDomain", code: 3311,
            userInfo: [NSLocalizedDescriptionKey: "Accès à la photothèque refusé."])
        XCTAssertEqual(system.userFacingMessage, "Accès à la photothèque refusé.")
    }

    func testKeychainFailuresNoLongerShowTheirStatusCode() {
        for error in [KeychainError.unexpectedStatus(-34018), .invalidData] {
            let message = error.userFacingMessage
            XCTAssertFalse(message.contains("Keychain"), message)
            XCTAssertFalse(message.contains("-34018"), message)
            XCTAssertTrue(message.hasPrefix("Le stockage sécurisé"), message)
        }
    }

    func testSilentInternalErrorsNeverExposeTheirTypeName() {
        let encryption = E2EEV2MessageCryptoError.invalidEnvelope.userFacingMessage
        XCTAssertTrue(encryption.hasPrefix("Le chiffrement n’a pas abouti"), encryption)
        let silent = SilentFailure.boom.userFacingMessage
        XCTAssertEqual(silent, "Une erreur inattendue est survenue. Réessaie.")
        XCTAssertFalse(silent.contains("SilentFailure"))
    }
}
