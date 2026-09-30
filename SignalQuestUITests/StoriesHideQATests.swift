import XCTest

/// Masquer les stories d'un membre depuis le rail du fil (plan 3, vague 1).
@MainActor
final class StoriesHideQATests: XCTestCase {
    func testHideStoriesFromRailThenUndo() {
        run(
            locale: "fr",
            tab: "Communauté",
            bubble: "Story de Camille",
            hide: "Masquer les stories de Camille",
            undo: "Annuler"
        )
    }

    func testEnglishHideStoriesFromRailThenUndo() {
        run(
            locale: "en",
            tab: "Community",
            bubble: "Camille's story",
            hide: "Hide Camille’s stories",
            undo: "Cancel"
        )
    }

    private func run(locale: String, tab: String, bubble: String, hide: String, undo: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()

        let camille = app.buttons[bubble]
        XCTAssertTrue(camille.waitForExistence(timeout: 15), "Bulle de story introuvable : \(bubble)")
        camille.press(forDuration: 1.2)
        let hideButton = app.buttons[hide]
        XCTAssertTrue(hideButton.waitForExistence(timeout: 5), "Action « \(hide) » introuvable")
        hideButton.tap()
        XCTAssertTrue(camille.waitForNonExistence(timeout: 5), "La bulle masquée reste affichée")

        let undoButton = app.buttons[undo]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), "Annulation introuvable")
        undoButton.tap()
        XCTAssertTrue(app.buttons[bubble].waitForExistence(timeout: 5), "L'annulation ne rend pas la bulle")
    }
}
