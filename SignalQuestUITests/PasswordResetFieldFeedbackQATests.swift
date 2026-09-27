import XCTest

@MainActor
final class PasswordResetFieldFeedbackQATests: XCTestCase {
    func testFrenchResetLengthErrorStaysBesidePassword() {
        run(locale: "fr", passwordLabel: "Nouveau mot de passe",
            lengthError: "Le mot de passe doit faire au moins 8 caractères.")
    }

    func testEnglishResetLengthErrorStaysBesidePasswordOnIPad() {
        run(locale: "en", passwordLabel: "New password",
            lengthError: "The password must be at least 8 characters.")
    }

    private func run(locale: String, passwordLabel: String, lengthError: String) {
        #if !targetEnvironment(simulator)
        XCTFail("This recipe requires a simulator-only debug route")
        return
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-auth", "--reset-onboarding", "--qa-password-reset-form"],
            locale: locale)
        if locale == "en" { XCTAssertGreaterThan(app.frame.width, 600, "Run this recipe on iPad") }

        let password = app.secureTextFields["auth.reset.password"]
        let confirmation = app.secureTextFields["auth.reset.confirmation"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        XCTAssertTrue(confirmation.exists)
        XCTAssertEqual(password.label, passwordLabel)
        password.tap()
        password.typeText("abc")

        let issue = app.staticTexts["auth.reset.password-error"]
        XCTAssertTrue(issue.waitForExistence(timeout: 10))
        XCTAssertEqual(issue.label, lengthError)
        XCTAssertLessThanOrEqual(issue.frame.minY - password.frame.maxY, 40)
        XCTAssertLessThan(issue.frame.maxY, confirmation.frame.minY,
                          "Length feedback must precede the confirmation field")
        XCTAssertFalse(app.staticTexts["auth.reset.confirmation-error"].exists)
        XCTAssertFalse(app.buttons["auth.reset.submit"].isEnabled)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reset-password-length-error-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
