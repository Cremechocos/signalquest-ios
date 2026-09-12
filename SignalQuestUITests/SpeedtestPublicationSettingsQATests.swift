import XCTest

/// Native settings-only proof. Requires an independently verified loopback:9
/// Debug app and dedicated QA simulators; never starts a throughput measurement.
@MainActor
final class SpeedtestPublicationSettingsQATests: XCTestCase {
    func testFrenchGuestPublicationNoticeOnSmallIPhoneWithLegacyOptOuts() throws {
        try checkRecipeOptIn()
        let app = launchGuest(locale: "fr")
        defer { app.terminate() }
        XCTAssertLessThanOrEqual(min(app.frame.width, app.frame.height), 390,
                                 "Use the dedicated small iPhone QA destination")
        try openAndInspectSettings(app, locale: "fr")
    }

    func testEnglishGuestPublicationNoticeOnIPadWithLegacyOptOuts() throws {
        try checkRecipeOptIn()
        let app = launchGuest(locale: "en")
        defer { app.terminate() }
        XCTAssertGreaterThanOrEqual(min(app.frame.width, app.frame.height), 600,
                                    "Use the dedicated iPad QA destination")
        try openAndInspectSettings(app, locale: "en")
    }

    private func checkRecipeOptIn() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This settings recipe is restricted to QA simulators")
        #endif
        let environment = ProcessInfo.processInfo.environment
        let optIn = environment["SQ_SPEEDTEST_SETTINGS_QA"]
            ?? environment["TEST_RUNNER_SQ_SPEEDTEST_SETTINGS_QA"]
        guard optIn == "loopback-9-verified" else {
            throw XCTSkip("First verify the built app API/app Info.plist URLs equal http://127.0.0.1:9")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchGuest(locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: [
            "--reset-auth", "--reset-onboarding",
            "-speedtest_publish_to_map", "NO",
            "-privacy_share_exact_measurements", "NO"
        ], environment: [
            "SQ_QA_SPEEDTEST_AUTORUN": "0",
            "SQ_QA_SPEEDTEST_EXIT": "0"
        ], locale: locale)
        let guestLabel = locale == "fr"
            ? "Lancer un speedtest sans compte" : "Run a speedtest without an account"
        let guest = app.buttons[guestLabel].firstMatch
        XCTAssertTrue(guest.waitForExistence(timeout: 10), "Guest entry absent in expected language")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(guest, in: app))
        capture(app, name: "publication-\(locale)-login")
        guest.tap() // Opens the guest screen; does not start a measurement.
        XCTAssertTrue(app.buttons["speedtest.settings"].waitForExistence(timeout: 15))
        capture(app, name: "publication-\(locale)-guest-idle")
        return app
    }

    private func openAndInspectSettings(_ app: XCUIApplication, locale: String) throws {
        let settings = app.buttons["speedtest.settings"]
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars[locale == "fr" ? "Réglages" : "Settings"]
            .waitForExistence(timeout: 10), "Settings sheet not presented in expected language")
        capture(app, name: "publication-\(locale)-settings-top")

        let notice = app.staticTexts["speedtest.publication.info"].firstMatch
        for index in 0..<12 {
            assertNoPublicationSwitches(app)
            if notice.exists && notice.isHittable { break }
            let scrollView = app.scrollViews["speedtest.settings.scroll"]
            if scrollView.exists { scrollView.swipeUp() } else { app.swipeUp() }
            if index == 11 { capture(app, name: "publication-\(locale)-notice-missing") }
        }
        XCTAssertTrue(notice.exists && notice.isHittable, "Publication notice must be readable in the sheet")
        let text = notice.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let expected = locale == "fr"
            ? ["automatique", "cellulaire", "exacte", "zones privees", "wi-fi", "vpn", "historique"]
            : ["automatic", "cellular", "exact", "private zones", "wi-fi", "vpn", "history"]
        for fragment in expected {
            XCTAssertTrue(text.contains(fragment), "Notice missing expected \(locale) meaning: \(fragment)")
        }
        assertNoPublicationSwitches(app)
        capture(app, name: "publication-\(locale)-settings-notice")

        // Confirm normal dismissal without touching any measurement action.
        let done = app.buttons["OK"].firstMatch
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture(app, name: "publication-\(locale)-guest-still-idle")
    }

    private func assertNoPublicationSwitches(_ app: XCUIApplication) {
        for label in ["Publier sur la carte communautaire", "Publish to the community map",
                      "Partager ma position exacte pour ce test", "Share my exact location for this test"] {
            XCTAssertFalse(app.switches.matching(NSPredicate(format: "label CONTAINS %@", label))
                .firstMatch.exists, "Obsolete publication opt-out remains: \(label)")
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = name + "-AX"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}
