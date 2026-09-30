import XCTest

/// Brouillons de messagerie : le texte commencé revient à la réouverture, et la
/// liste des conversations le signale (plan 3, vague 1).
@MainActor
final class MessageDraftsQATests: XCTestCase {
    func testDraftComesBackAndShowsInTheList() {
        run(locale: "fr", tab: "Communauté", cancel: "Annuler", back: "Retour", marker: "Brouillon · ")
    }

    func testEnglishDraftComesBackAndShowsInTheList() {
        run(locale: "en", tab: "Community", cancel: "Cancel", back: "Back", marker: "Draft · ")
    }

    private func run(locale: String, tab: String, cancel: String, back: String, marker: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10))
        messages.tap()

        let text = "Rendez-vous demain 18h"
        let draft = app.staticTexts["messages.row.draft"]
        let field = openConversation(in: app, cancel: cancel)
        field.tap()
        field.typeText(text)
        leaveConversation(in: app, back: back)

        XCTAssertTrue(draft.waitForExistence(timeout: 10), "Le brouillon n'apparaît pas dans la liste")
        XCTAssertEqual(draft.label, marker + text)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "messages-draft-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        _ = openConversation(in: app, cancel: cancel)
        XCTAssertEqual(field.value as? String, text, "Le brouillon doit revenir dans le champ")
        // Curseur en fin de texte : toucher le milieu du champ l'y plaçait au
        // milieu, et seul le début du brouillon s'effaçait.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 4))
        XCTAssertNotEqual(field.value as? String, text)
        leaveConversation(in: app, back: back)
        XCTAssertTrue(draft.waitForNonExistence(timeout: 10), "Un champ vidé ne laisse pas de brouillon")
    }

    /// La feuille de déverrouillage du chiffrement peut arriver après la liste,
    /// par-dessus elle : on la referme et on retente l'ouverture.
    private func openConversation(in app: XCUIApplication, cancel: String) -> XCUIElement {
        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        for _ in 0..<3 {
            let unlockCancel = app.buttons[cancel].firstMatch
            if unlockCancel.waitForExistence(timeout: 3) { unlockCancel.tap() }
            let row = app.staticTexts["SignalQuest iOS"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Conversation de démo introuvable")
            // Le texte vit dans le bouton de la rangée : on touche sa position.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if field.waitForExistence(timeout: 10) { return field }
        }
        XCTFail("La conversation de démo ne s'ouvre pas")
        return field
    }

    private func leaveConversation(in app: XCUIApplication, back: String) {
        let button = app.buttons[back].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
