import XCTest

/// Real synthetic account and native settings. Setup returns an injected 503;
/// no secret or usable QR is created, typed or captured in this recipe.
@MainActor
final class TwoFactorErrorQATests: XCTestCase {
    func testEnglishSetupFailureOnIPad() throws { try run(locale: "en", iPad: true) }
    func testFrenchSetupFailureOnSmallIPhone() throws { try run(locale: "fr", iPad: false) }

    private func run(locale: String, iPad: Bool) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated QA simulator required")
        #endif
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard value("SQ_TWO_FACTOR_UI") == "loopback-4321-error-only" else {
            throw XCTSkip("Requires independently verified loopback app and error-only fixture")
        }
        guard let encoded = value("SQ_TWO_FACTOR_UI_FIXTURE_B64"), let data = Data(base64Encoded: encoded),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
              fixture.baseURL == "http://127.0.0.1:4321", fixture.database == "sq_speedtest_interop_20260912_test",
              fixture.email.hasPrefix("twofactor-interop-"), fixture.email.hasSuffix("@local.test") else {
            XCTFail("Invalid isolated fixture"); return
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-onboarding"],
            environment: ["SQ_AUTH_TOKEN": fixture.token, "SQ_QA_SPEEDTEST_AUTORUN": "0", "SQ_QA_SPEEDTEST_EXIT": "0"], locale: locale)
        XCTAssertEqual(min(app.frame.width, app.frame.height) >= 600, iPad)
        let profile = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 30)); profile.tap()
        let settings = app.staticTexts[locale == "fr" ? "Réglages" : "Settings"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(settings, in: app)); settings.tap()
        let activation = app.buttons[locale == "fr" ? "Activer la 2FA" : "Enable 2FA"].firstMatch
        XCTAssertTrue(activation.waitForExistence(timeout: 10)); activation.tap()
        let error = app.descendants(matching: .any).matching(identifier: "two-factor.setup.error").firstMatch
        let retry = app.buttons["two-factor.setup.retry"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "two-factor.setup.secret").firstMatch.exists)
        XCTAssertFalse(app.buttons["two-factor.setup.confirm"].exists)
        capture(app, name: "two-factor-\(locale)-setup-error")
        retry.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(retry.isHittable)
        let close = app.buttons["two-factor.setup.close"]
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(activation.waitForExistence(timeout: 10))
    }
    private struct Fixture: Decodable { let baseURL: String; let database: String; let email: String; let token: String }
    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

/// Native enrollment against loopback-only current API handlers and a disposable QA database.
/// Captures happen only after the secret and QR have been erased from the view.
@MainActor
final class TwoFactorSuccessQATests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:4321")!

    func testFrenchSetupErrorThenConfirmation() async throws { try await run(locale: "fr") }
    func testEnglishSetupErrorThenConfirmation() async throws { try await run(locale: "en") }

    private func run(locale: String) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated QA simulator required")
        #endif
        let fixture = try fixture()
        let scenario: Scenario = try await control("/__qa/scenarios", fixture: fixture, method: "POST", body: [:])
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-onboarding", "-app_pure_black", locale == "en" ? "YES" : "NO"],
            environment: ["SQ_AUTH_TOKEN": scenario.A.token, "SQ_QA_SPEEDTEST_AUTORUN": "0", "SQ_QA_SPEEDTEST_EXIT": "0"], locale: locale)

        let profile = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 30)); profile.tap()
        let settings = app.staticTexts[locale == "fr" ? "Réglages" : "Settings"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(settings, in: app)); settings.tap()
        let activation = app.buttons[locale == "fr" ? "Activer la 2FA" : "Enable 2FA"].firstMatch
        XCTAssertTrue(activation.waitForExistence(timeout: 10)); activation.tap()

        let secret = app.descendants(matching: .any)["two-factor.setup.secret"].firstMatch
        let codeField = app.textFields["two-factor.setup.code"]
        let submit = app.buttons["two-factor.setup.confirm"]
        XCTAssertTrue(secret.waitForExistence(timeout: 20), "A real setup response must expose manual enrollment")
        XCTAssertTrue(codeField.exists)
        XCTAssertEqual(codeField.label, locale == "fr" ? "Code TOTP à 6 chiffres" : "6-digit TOTP code")
        XCTAssertFalse(submit.isEnabled)

        let current: Code = try await control("/__qa/code", fixture: fixture, method: "POST", body: ["scenarioId": scenario.id])
        let invalid = current.code == "000000" ? "111111" : "000000"
        codeField.tap(); codeField.typeText(invalid)
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(submit, in: app)); submit.tap()
        let error = app.descendants(matching: .any)["two-factor.setup.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        let expectedError = locale == "fr"
            ? "Le code est incorrect. Saisis les six chiffres affichés dans ton application d’authentification."
            : "The code is incorrect. Enter the six digits shown in your authenticator app."
        XCTAssertTrue(error.label.contains(expectedError))
        XCTAssertGreaterThanOrEqual(error.frame.minY, codeField.frame.maxY)
        XCTAssertLessThanOrEqual(error.frame.minY - codeField.frame.maxY, 40,
                                 "Verification error must stay directly below the code field")

        let valid: Code = try await control("/__qa/code", fixture: fixture, method: "POST", body: ["scenarioId": scenario.id])
        codeField.tap(); codeField.typeText(valid.code)
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(submit, in: app)); submit.tap()
        let enabled = app.descendants(matching: .any)["two-factor.setup.enabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 20))
        XCTAssertEqual(enabled.label, locale == "fr"
            ? "La double authentification est activée."
            : "Two-factor authentication is enabled.")
        XCTAssertTrue(secret.waitForNonExistence(timeout: 10))
        XCTAssertFalse(codeField.exists)

        let state: State = try await control("/__qa/state?scenarioId=\(scenario.id)", fixture: fixture)
        XCTAssertEqual(state.users.first(where: { $0.id == scenario.A.userId })?.enabled, true)
        XCTAssertEqual(state.users.first(where: { $0.id == scenario.A.userId })?.pending, false)
        XCTAssertEqual(state.users.first(where: { $0.id == scenario.B.userId })?.enabled, false)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "two-factor-setup-confirmed-\(locale)-no-secret"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private struct Fixture: Decodable { let baseURL: String; let controlKey: String; let database: String }
    private struct Actor: Decodable { let userId: String; let token: String }
    private struct Scenario: Decodable { let id: String; let A: Actor; let B: Actor }
    private struct Code: Decodable { let code: String }
    private struct State: Decodable {
        struct User: Decodable { let id: String; let enabled: Bool; let pending: Bool }
        let users: [User]
    }
    private enum FixtureError: Error { case invalidResponse }

    private func fixture() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard value("SQ_TWO_FACTOR_SUCCESS_QA") == "loopback-4321",
              let encoded = value("SQ_TWO_FACTOR_SUCCESS_FIXTURE_B64"),
              let data = Data(base64Encoded: encoded),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
              fixture.baseURL == origin.absoluteString,
              fixture.database == "sq_ios_twofactor_ui_20260927_test",
              fixture.controlKey.count >= 32 else {
            throw XCTSkip("Requires isolated two-factor success fixture")
        }
        return fixture
    }

    private func control<T: Decodable>(_ path: String, fixture: Fixture,
                                       method: String = "GET", body: [String: String]? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: origin) else { throw FixtureError.invalidResponse }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(fixture.controlKey, forHTTPHeaderField: "X-SQ-QA-Key")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            XCTFail("Isolated QA control request failed: \(path)")
            throw FixtureError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
