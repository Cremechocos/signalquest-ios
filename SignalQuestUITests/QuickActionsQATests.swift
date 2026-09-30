import XCTest

/// Actions rapides de l'icône, depuis l'écran d'accueil d'iOS (plan 3, vague 1).
@MainActor
final class QuickActionsQATests: XCTestCase {
    func testHomeScreenQuickActionOpensSpeedtest() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: "fr")
        defer { app.terminate() }
        // Les actions sont posées au premier affichage de l'app.
        XCTAssertTrue(SignalQuestUITestSupport.tab(named: "Accueil", in: app).waitForExistence(timeout: 15))

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["SignalQuest"]
        guard icon.waitForExistence(timeout: 10) else {
            throw XCTSkip("Icône SignalQuest absente de la première page de l'écran d'accueil")
        }
        icon.press(forDuration: 1.5)
        let action = springboard.buttons["Lancer un test"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Action rapide « Lancer un test » absente")
        action.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let speed = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        XCTAssertTrue(speed.isSelected, "L'action rapide doit ouvrir l'onglet Tester")
    }
}
