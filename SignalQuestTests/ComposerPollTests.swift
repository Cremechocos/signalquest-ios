import XCTest
@testable import SignalQuest

/// La validation se fait AVANT l'envoi. Un 400 sur le sondage coûterait tout le
/// post — texte et pièce jointe déjà téléversée comprises.
final class ComposerPollTests: XCTestCase {

    func testTwoOptionsAreEnoughAndFourAreTheMaximum() {
        XCTAssertNotNil(CreatePostPoll.make(question: "", options: ["A", "B"], allowMultiple: false))
        XCTAssertNotNil(CreatePostPoll.make(question: "", options: ["A", "B", "C", "D"], allowMultiple: false))
        XCTAssertNil(CreatePostPoll.make(question: "", options: ["A"], allowMultiple: false))
        XCTAssertNil(CreatePostPoll.make(question: "", options: ["A", "B", "C", "D", "E"], allowMultiple: false))
    }

    /// Une ligne laissée en blanc dans le formulaire est une OMISSION, pas une
    /// erreur : on la retire au lieu de refuser tout le sondage.
    func testBlankOptionsAreDroppedNotRejected() {
        let poll = CreatePostPoll.make(question: "", options: ["Fibre", "  ", "4G", ""], allowMultiple: false)
        XCTAssertEqual(poll?.options, ["Fibre", "4G"])
    }

    /// Mais si le retrait passe sous le minimum, le sondage n'est plus valide.
    func testDroppingBlanksCanInvalidateThePoll() {
        XCTAssertNil(CreatePostPoll.make(question: "", options: ["Fibre", "  ", ""], allowMultiple: false))
    }

    /// Deux options identiques rendraient le résultat ininterprétable — et le
    /// serveur ne s'en protège pas.
    func testDuplicateOptionsAreRejectedCaseInsensitively() {
        XCTAssertNil(CreatePostPoll.make(question: "", options: ["Fibre", "fibre"], allowMultiple: false))
        XCTAssertNil(CreatePostPoll.make(question: "", options: ["A", "B", "a"], allowMultiple: false))
    }

    /// Les bornes du serveur sont appliquées par troncature, pas par refus :
    /// perdre la fin d'un libellé vaut mieux que perdre tout le post.
    func testLongValuesAreTruncatedToTheServerLimits() {
        let longOption = String(repeating: "x", count: 200)
        let longQuestion = String(repeating: "q", count: 400)
        let poll = CreatePostPoll.make(question: longQuestion, options: [longOption, "B"], allowMultiple: false)
        XCTAssertEqual(poll?.options.first?.count, 80)
        XCTAssertEqual(poll?.question?.count, 160)
    }

    /// Une question vide est envoyée à `nil`, pas à chaîne vide : le serveur
    /// l'accepte comme facultative.
    func testAnEmptyQuestionBecomesNil() {
        XCTAssertNil(CreatePostPoll.make(question: "   ", options: ["A", "B"], allowMultiple: false)?.question)
    }

    func testAllowMultipleIsCarried() {
        XCTAssertEqual(
            CreatePostPoll.make(question: "", options: ["A", "B"], allowMultiple: true)?.allowMultiple,
            true
        )
    }

    /// Le contrat encodé doit correspondre au schéma zod du serveur.
    func testEncodesTheShapeTheServerExpects() throws {
        let poll = try XCTUnwrap(CreatePostPoll.make(question: "Ton opérateur ?", options: ["Orange", "SFR"], allowMultiple: false))
        let data = try JSONEncoder().encode(poll)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["question"] as? String, "Ton opérateur ?")
        XCTAssertEqual(json["options"] as? [String], ["Orange", "SFR"])
        XCTAssertEqual(json["allowMultiple"] as? Bool, false)
    }
}
