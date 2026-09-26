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

    func testIPadAccessibilityTextKeepsLoginActionsReadable() {
        continueAfterFailure = false
        for locale in ["fr", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-auth", "--reset-onboarding",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.sqLaunch(locale: locale)
            SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
            defer { app.terminate() }

            let email = app.textFields["Email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15))
            XCTAssertLessThan(email.frame.width, 600, "Login field stretches across the iPad")

            let recovery = app.buttons["login.recovery"]
            let signup = app.buttons["login.signup"]
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(recovery, in: app))
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(signup, in: app))
            XCTAssertGreaterThanOrEqual(signup.frame.minY, recovery.frame.maxY - 1,
                                        "Accessibility actions must stack instead of colliding")
            for element in [recovery, signup] {
                XCTAssertGreaterThanOrEqual(element.frame.height, 44)
                XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
            }

            let terms = app.descendants(matching: .any)["login.terms"].firstMatch
            let privacy = app.descendants(matching: .any)["login.privacy"].firstMatch
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(terms, in: app))
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(privacy, in: app))
            XCTAssertGreaterThanOrEqual(privacy.frame.minY, terms.frame.maxY - 1)
            XCTAssertGreaterThanOrEqual(terms.frame.height, 44)
            XCTAssertGreaterThanOrEqual(privacy.frame.height, 44)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "login-ipad-accessibility-\(locale)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func launch(locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: locale)
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 15))
        return app
    }
}
