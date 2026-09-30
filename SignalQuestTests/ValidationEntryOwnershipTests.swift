import XCTest
@testable import SignalQuest

/// Le serveur refuse désormais le rejet de sa propre identification ; la ligne
/// qui porte `mine` perd son bouton « Rejeter ».
final class ValidationEntryOwnershipTests: XCTestCase {
    func testMineIsReadAndDefaultsToFalse() throws {
        let json = Data(#"""
        {"enb":[{"value":"123456","validations":3,"rejections":0,"mine":true},{"value":"654321","validations":1,"rejections":1}],
         "pci":[],"cellid":[],"gnb":[]}
        """#.utf8)
        let validations = try JSONDecoder().decode(SiteValidations.self, from: json)
        XCTAssertEqual(validations.enb.map(\.isMine), [true, false], "Sans la clé, le bouton reste affiché")
    }

    func testOwnIdentificationRejectionHasAClearMessage() {
        let error = APIError.http(status: 409, code: "CANNOT_REJECT_OWN_IDENTIFICATION",
                                  message: "Cannot reject own identification", requestId: nil, retryAfter: nil)
        XCTAssertEqual(error.userFacingMessage, String(localized: "Tu ne peux pas rejeter ta propre identification."),
                       "Le libellé traduit passe avant le texte brut du serveur")
    }
}
