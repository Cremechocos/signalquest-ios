import XCTest

/// Synthetic HTTPS fixture: real native login and 2FA form, no real account or TOTP secret.
@MainActor
final class TwoFactorLoginFieldQATests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated QA simulator required")
        #endif
        guard ProcessInfo.processInfo.environment["SQ_TWO_FACTOR_LOGIN_QA"] == "1" else {
            throw XCTSkip("Requires the trusted loopback HTTPS fixture")
        }
    }

    func testFrenchFailureStaysBesideCode() async throws { try await run(locale: "fr", label: "Code à 6 chiffres") }
    func testEnglishFailureStaysBesideCode() async throws { try await run(locale: "en", label: "6-digit code") }

    func testFrenchFailureWithoutPasswordSheet() async throws {
        let healthURL = URL(string: "https://127.0.0.1:4325/health")!
        let (health, response) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: health, encoding: .utf8), "{\"fixture\":\"two-factor-login-error-only\"}")

        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-auth", "--reset-onboarding", "--qa-two-factor-login"], locale: "fr")
        let code = app.textFields["login.twoFactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        XCTAssertEqual(code.label, "Code à 6 chiffres")
        code.tap(); code.typeText("123456")
        XCTAssertEqual(code.label, "Code à 6 chiffres", "Accessible name must survive input")
        app.buttons["login.twoFactor.submit"].tap()

        let error = app.descendants(matching: .any)["login.twoFactor.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("Code de vérification invalide"), "Expected server error, not a local mock")
        XCTAssertGreaterThanOrEqual(error.frame.minY, code.frame.maxY)
        XCTAssertLessThanOrEqual(error.frame.minY - code.frame.maxY, 40)
        XCTAssertTrue(app.buttons["login.twoFactor.cancel"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "two-factor-login-error-fr-direct-qa"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func run(locale: String, label: String) async throws {
        let healthURL = URL(string: "https://127.0.0.1:4325/health")!
        let (health, response) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: health, encoding: .utf8), "{\"fixture\":\"two-factor-login-error-only\"}")

        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: locale)
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap(); email.typeText("twofactor-login@example.invalid")
        let password = app.secureTextFields[locale == "fr" ? "Mot de passe" : "Password"]
        XCTAssertTrue(password.exists)
        password.tap(); password.typeText("Synthetic-Only-2026!")
        app.buttons["login.submit"].tap()

        let code = app.textFields["login.twoFactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        XCTAssertEqual(code.label, label)
        // iOS presents the password-save sheet in SafariViewService, not in
        // SpringBoard. It intercepts taps on the code field until dismissed.
        let systemService = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let later = systemService.buttons["Plus tard"].exists
            ? systemService.buttons["Plus tard"] : systemService.buttons["Not Now"]
        if later.waitForExistence(timeout: 2) {
            later.tap()
            XCTAssertTrue(later.waitForNonExistence(timeout: 3))
        }
        code.tap(); code.typeText("123456")
        XCTAssertEqual(code.label, label, "2FA field must retain its accessible name after typing")
        app.buttons["login.twoFactor.submit"].tap()

        let error = app.descendants(matching: .any)["login.twoFactor.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(error.frame.minY - code.frame.maxY, 40,
                                 "2FA error must stay directly below the code field")
        XCTAssertTrue(app.buttons["login.twoFactor.cancel"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "two-factor-login-error-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
