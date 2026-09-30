import XCTest

/// Médias et fichiers d'une conversation (plan 3, vague 2), sur la
/// conversation de démonstration : trois photos et un fichier.
@MainActor
final class ConversationMediaQATests: XCTestCase {
    func testMediaAndFilesOfAConversation() {
        run(locale: "fr", tab: "Communauté", cancel: "Annuler", more: "Plus d’options",
            entry: "Médias et fichiers", photos: "Photos", files: "Fichiers et notes vocales")
    }

    func testEnglishMediaAndFilesOfAConversation() {
        run(locale: "en", tab: "Community", cancel: "Cancel", more: "More options",
            entry: "Media and files", photos: "Photos", files: "Files and voice notes")
    }

    private func run(locale: String, tab: String, cancel: String, more: String, entry: String, photos: String, files: String) {
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
        openConversation(in: app, cancel: cancel)

        let menu = app.buttons[more].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Menu « \(more) » introuvable")
        menu.tap()
        let open = app.buttons[entry].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Entrée « \(entry) » absente du menu")
        open.tap()

        let photoTiles = app.buttons.matching(identifier: "conversationMedia.photo")
        XCTAssertTrue(photoTiles.firstMatch.waitForExistence(timeout: 10), "Aucune photo dans la galerie")
        XCTAssertEqual(photoTiles.count, 3)
        XCTAssertTrue(app.staticTexts[photos].exists)
        XCTAssertTrue(app.staticTexts[files].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversationMedia.file").count, 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "conversation-media-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// La feuille de déverrouillage du chiffrement peut arriver après la liste,
    /// par-dessus elle : on la referme et on retente l'ouverture.
    private func openConversation(in app: XCUIApplication, cancel: String) {
        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        for _ in 0..<3 {
            let unlockCancel = app.buttons[cancel].firstMatch
            if unlockCancel.waitForExistence(timeout: 3) { unlockCancel.tap() }
            let row = app.staticTexts["SignalQuest iOS"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Conversation de démo introuvable")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if field.waitForExistence(timeout: 10) { return }
        }
        XCTFail("La conversation de démo ne s'ouvre pas")
    }
}
