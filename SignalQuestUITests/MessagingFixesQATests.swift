import XCTest

/// QA des correctifs messagerie : titre de conversation sans soi-même + sondage
/// dont les options s'affichent. Nécessite SQ_AUTH_TOKEN (compte A). Le compte A
/// a une conversation non chiffrée avec B contenant un sondage « Meilleur
/// opérateur ? » (Orange/SFR/Free).
@MainActor
final class MessagingFixesQATests: XCTestCase {
    func testTitleAndPollRender() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "QA messagerie : SQ_AUTH_TOKEN requis")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Messages"].tap()

        // Le sheet E2EE peut s'auto-présenter (conv chiffrée) : on l'annule pour
        // accéder à la liste.
        let cancel = app.buttons["Annuler"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }

        // Le titre d'une conversation 1:1 ne doit PAS contenir le nom de A.
        let myNameInTitle = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SQ iOS Test")).firstMatch
        XCTAssertFalse(myNameInTitle.waitForExistence(timeout: 6), "Le titre inclut le nom de l'utilisateur courant")
        print("TITLE_OK")

        // Ouvrir la conversation avec B (porteuse du sondage non chiffré).
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SQ Web Test B")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Conversation avec B introuvable")
        row.tap()

        // Le sondage affiche ses options (et non opt_1/opt_2). Les options sont
        // des Button (PollBubble) → on cherche sur n'importe quel élément.
        func anyElement(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }
        let orange = anyElement("Orange")
        for _ in 0..<6 where !orange.exists { app.swipeUp() }
        XCTAssertTrue(orange.waitForExistence(timeout: 8), "Options du sondage non affichées")
        XCTAssertTrue(anyElement("SFR").exists, "Option SFR absente")
        XCTAssertFalse(anyElement("opt_1").exists, "Identifiant d'option brut affiché au lieu du texte")
        print("POLL_OPTIONS_OK")
    }
}
