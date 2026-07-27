import XCTest
@testable import SignalQuest

/// La détection du jeton est de la logique pure, et c'est là que tout se joue :
/// un jeton mal délimité insère la suggestion au mauvais endroit, découpe un mot
/// ou duplique le `@`. Aucun de ces défauts n'échoue à la compilation, et un
/// test visuel les rate une fois sur deux.
final class MentionAutocompleteTests: XCTestCase {

    private func token(_ text: String) -> MentionAutocomplete.Token? {
        MentionAutocomplete.activeToken(in: text, cursor: text.endIndex)
    }

    func testDetectsAMentionBeingTyped() {
        let t = token("Salut @nor")
        XCTAssertEqual(t?.kind, .mention)
        XCTAssertEqual(t?.query, "nor")
    }

    func testDetectsAHashtagBeingTyped() {
        XCTAssertEqual(token("Test en #5")?.kind, .hashtag)
        XCTAssertEqual(token("Test en #5")?.query, "5")
    }

    /// Le cas qui compte : une adresse e-mail ne doit PAS ouvrir la liste de
    /// mentions. C'est le faux positif le plus fréquent et le plus agaçant.
    func testAnEmailAddressDoesNotOpenMentions() {
        XCTAssertNil(token("écris à contact@signalquest"))
    }

    /// Un jeton terminé par une espace ou une ponctuation est FINI : garder la
    /// liste ouverte empêcherait de continuer à écrire.
    func testACompletedTokenClosesTheList() {
        XCTAssertNil(token("Salut @nora "))
        XCTAssertNil(token("Salut @nora,"))
        XCTAssertNil(token("Salut @nora."))
    }

    func testPlainTextHasNoToken() {
        XCTAssertNil(token("Aucun jeton ici"))
        XCTAssertNil(token(""))
    }

    /// Le préfixe juste après une parenthèse ouvre bien un jeton — cas courant
    /// quand on cite quelqu'un entre parenthèses.
    func testAfterAnOpeningParenthesisIsValid() {
        XCTAssertEqual(token("(@no")?.query, "no")
    }

    /// L'insertion remplace le jeton ENTIER, préfixe compris — sinon on obtient
    /// « @@nora ».
    func testApplyReplacesTheWholeTokenAndAddsASpace() {
        let text = "Salut @nor"
        let t = try! XCTUnwrap(token(text))
        let result = MentionAutocomplete.apply("nora", to: text, token: t)
        XCTAssertEqual(result.text, "Salut @nora ")
        XCTAssertEqual(result.cursorOffset, result.text.count)
    }

    /// Insertion au MILIEU d'un texte : le reste ne doit pas être écrasé.
    func testApplyPreservesWhatFollows() {
        let text = "Salut @nor comment ça va"
        let cursor = text.index(text.startIndex, offsetBy: 10)
        let t = try! XCTUnwrap(MentionAutocomplete.activeToken(in: text, cursor: cursor))
        let result = MentionAutocomplete.apply("nora", to: text, token: t)
        XCTAssertEqual(result.text, "Salut @nora  comment ça va")
    }

    func testExtractsMentionedHandles() {
        let handles = MentionAutocomplete.mentionedHandles(in: "Merci @nora et @camille_2 !")
        XCTAssertEqual(handles, ["nora", "camille_2"])
    }

    /// Mentionner deux fois la même personne ne doit pas produire deux
    /// notifications.
    func testHandlesAreDeduplicatedCaseInsensitively() {
        let handles = MentionAutocomplete.mentionedHandles(in: "@Nora puis @nora encore")
        XCTAssertEqual(handles, ["Nora"])
    }

    /// Une adresse e-mail ne doit pas être extraite comme mention.
    func testEmailIsNotExtractedAsAMention() {
        XCTAssertTrue(MentionAutocomplete.mentionedHandles(in: "contact@signalquest.fr").isEmpty)
    }
}
