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

    /// Run with a dark simulator appearance. The in-app OLED preference and
    /// accessibility text size exercise the actual rendered form, not tokens.
    func testEnglishResetErrorOLEDAtAccessibilityXXXL() {
        run(locale: "en", passwordLabel: "New password",
            lengthError: "The password must be at least 8 characters.",
            extraArguments: ["-app_pure_black", "YES",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    func testEnglishConfirmationMismatchOnIPadAtAccessibilityXXXL() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-auth", "--reset-onboarding", "--qa-password-reset-form",
                        "-app_pure_black", "NO",
                        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            locale: "en")
        XCTAssertGreaterThan(app.frame.width, 600, "Run this recipe on iPad")

        let password = app.secureTextFields["auth.reset.password"]
        let confirmation = app.secureTextFields["auth.reset.confirmation"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        password.tap()
        password.typeText("SyntheticPass-2026!")
        XCTAssertFalse(app.staticTexts["auth.reset.confirmation-error"].exists)

        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(confirmation, in: app))
        confirmation.tap()
        confirmation.typeText("OtherPass-2026!")
        let mismatch = app.staticTexts["auth.reset.confirmation-error"]
        XCTAssertTrue(mismatch.waitForExistence(timeout: 10))
        XCTAssertEqual(mismatch.label, "The two passwords don't match.")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(mismatch, in: app))
        XCTAssertLessThanOrEqual(mismatch.frame.minY - confirmation.frame.maxY, 40)
        XCTAssertFalse(app.buttons["auth.reset.submit"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reset-confirmation-mismatch-en-ipad-dark-axxxl"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func run(locale: String, passwordLabel: String, lengthError: String,
                     extraArguments: [String] = []) {
        #if !targetEnvironment(simulator)
        XCTFail("This recipe requires a simulator-only debug route")
        return
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-auth", "--reset-onboarding", "--qa-password-reset-form"] + extraArguments,
            locale: locale)
        if locale == "en" && extraArguments.isEmpty {
            XCTAssertGreaterThan(app.frame.width, 600, "Run this recipe on iPad")
        }

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
        screenshot.name = "reset-password-length-error-\(locale)\(extraArguments.isEmpty ? "" : "-oled-axxxl")"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        if !extraArguments.isEmpty {
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(issue, in: app))
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(app.buttons["auth.reset.submit"], in: app),
                          "The submit action remains reachable at accessibility XXXL")
        }
    }
}
