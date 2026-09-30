import XCTest

/// « Reprendre où j'en étais » : l'app rouvre le dernier onglet après une
/// fermeture par iOS (plan 3, vague 1).
@MainActor
final class ResumeLastTabQATests: XCTestCase {
    func testLastTabComesBackAfterIOSClosesTheApp() {
        continueAfterFailure = false
        let arguments = ["--mock-auth", "--qa-restore-tab"]
        let app = XCUIApplication()
        leaveAppOnMapThenLetIOSCloseIt(app, arguments: arguments)

        SignalQuestUITestSupport.launch(app, arguments: arguments, locale: "fr")
        defer { app.terminate() }
        let map = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        XCTAssertTrue(map.isSelected, "L'app doit rouvrir la Carte")
    }

    /// Garde-fou des autres tests d'interface : sans le drapeau, la démo repart
    /// toujours de l'Accueil.
    func testDemoWithoutFlagStartsOnHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        leaveAppOnMapThenLetIOSCloseIt(app, arguments: ["--mock-auth"])

        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: "fr")
        defer { app.terminate() }
        let home = SignalQuestUITestSupport.tab(named: "Accueil", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        XCTAssertTrue(home.isSelected, "La démo doit repartir de l'Accueil")
    }

    private func leaveAppOnMapThenLetIOSCloseIt(_ app: XCUIApplication, arguments: [String]) {
        SignalQuestUITestSupport.launch(app, arguments: arguments, locale: "fr")
        let map = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        map.tap()
        XCTAssertTrue(map.isSelected)
        // L'état de la fenêtre s'enregistre au passage en arrière-plan ; iOS
        // ferme ensuite l'app, comme après une longue absence.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
    }
}
