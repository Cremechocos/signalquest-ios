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
