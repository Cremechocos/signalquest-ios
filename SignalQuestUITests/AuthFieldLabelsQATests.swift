import XCTest

@MainActor
final class AuthFieldLabelsQATests: XCTestCase {
    func testFrenchLoginAndSignupKeepLabelsAfterTyping() {
        continueAfterFailure = false
        let app = launch(locale: "fr")
        defer { app.terminate() }

        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("alex@example.invalid")
        XCTAssertEqual(email.label, "Email", "Nom accessible Email perdu après saisie")
        let loginShot = XCTAttachment(screenshot: app.screenshot())
        loginShot.name = "login-persistent-labels-fr"
        loginShot.lifetime = .keepAlways
        add(loginShot)

        let signup = app.buttons["login.signup"]
        XCTAssertTrue(signup.waitForExistence(timeout: 10))
        signup.tap()
        let name = app.textFields["auth.signup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Alex")
        XCTAssertEqual(name.label, "Nom affiché", "Nom accessible perdu après saisie")
    }

    func testEnglishRecoveryKeepsEmailLabelAfterTyping() {
        continueAfterFailure = false
        let app = launch(locale: "en")
        defer { app.terminate() }
        let recovery = app.buttons["login.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        recovery.tap()
        let email = app.textFields["auth.recovery.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("alex@example.invalid")
        XCTAssertEqual(email.label, "Email", "Email field loses its accessible name")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "recovery-persistent-label-en"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launch(locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: locale)
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 15))
        return app
    }
}
