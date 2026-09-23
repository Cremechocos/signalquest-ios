import XCTest

/// Settings-only checks. Simulator cases require the verified loopback:9 app;
/// physical cases require the separate Beta recipe on the paired USB backend.
/// No case starts a throughput measurement or an active Drive Test.
@MainActor
final class SpeedtestPublicationSettingsQATests: XCTestCase {
    func testPhysicalFrenchSettingsAndIdleBackgroundReturn() throws {
        try checkPhysicalSettings(locale: "fr")
    }

    func testPhysicalEnglishSettingsAndIdleBackgroundReturn() throws {
        try checkPhysicalSettings(locale: "en")
    }

    private func checkPhysicalSettings(locale: String) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the separate physical Beta recipe")
        #else
        guard ProcessInfo.processInfo.environment["SQ_PHYSICAL_SETTINGS_QA"] == "beta-usb-verified" else {
            throw XCTSkip("First verify the Beta signature, isolated USB origins and synthetic backend")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchGuest(locale: locale)
        defer { app.terminate() }
        try openAndInspectSettings(app, locale: locale)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        let start = app.buttons[locale == "fr" ? "Démarrer le Drive Test" : "Start Drive Test"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        for (identifier, value) in [("drivetest.interval", "1 km"),
                                    ("drivetest.dataCap", locale == "fr" ? "2 Go" : "2 GB")] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].firstMatch.label.contains(value))
        }
        XCTAssertFalse(app.buttons["Arrêter le drive test"].exists)
        capture(app, name: "physical-\(locale)-idle-background-return")
        #endif
    }

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
            "-privacy_share_exact_measurements", "NO",
            "-drivetest_mode", "coverage"
        ], environment: [
            "SQ_QA_SPEEDTEST_AUTORUN": "0",
            "SQ_QA_SPEEDTEST_EXIT": "0"
        ], locale: locale)
        capture(app, name: "publication-\(locale)-login")
        SignalQuestUITestSupport.enterGuestApplication(app, tab: "speed", locale: locale)
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
        // Initialiser par le vrai contrôle : un argument UserDefaults imposé
        // au lancement empêcherait ensuite AppStorage de changer de valeur.
        app.buttons["1"].firstMatch.tap()
        capture(app, name: "publication-\(locale)-settings-top")

        XCTAssertFalse(app.staticTexts["speedtest.publication.info"].exists)
        assertNoPublicationSwitches(app)

        // Les réglages du trajet ne doivent pas apparaître pour un test ponctuel.
        let cap = app.staticTexts[locale == "fr" ? "Plafond de données" : "Data cap"]
        XCTAssertFalse(cap.exists)
        let route = app.buttons[locale == "fr" ? "Trajet" : "Route"]
        let scroll = app.scrollViews["speedtest.settings.scroll"]
        for _ in 0..<8 where !route.isHittable { scroll.swipeDown() }
        XCTAssertTrue(route.isHittable)
        route.tap()
        XCTAssertTrue(cap.waitForExistence(timeout: 5))
        let routeTiming = locale == "fr"
            ? "Prochain test après la distance choisie ou 30 s. « Tester maintenant » le lance aussitôt."
            : "Next test after the selected distance or 30 seconds. “Test now” starts it immediately."
        XCTAssertTrue(app.staticTexts[routeTiming].waitForExistence(timeout: 5))
        capture(app, name: "measurement-\(locale)-route-settings")
        let single = app.buttons["1"].firstMatch
        for _ in 0..<8 where !single.isHittable { scroll.swipeDown() }
        single.tap()
        XCTAssertFalse(cap.exists)
        let advanced = app.buttons["speedtest.settings.advanced"].firstMatch
        XCTAssertTrue(advanced.isHittable)
        advanced.tap()
        XCTAssertTrue(app.buttons["Cloudflare"].waitForExistence(timeout: 5))
        capture(app, name: "measurement-\(locale)-advanced-settings")

        for _ in 0..<8 where !route.isHittable { scroll.swipeDown() }
        route.tap()
        XCTAssertTrue(route.isSelected)

        // Confirm normal dismissal without touching any measurement action.
        let done = app.buttons["OK"].firstMatch
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture(app, name: "publication-\(locale)-guest-still-idle")
        let openDrive = app.buttons[locale == "fr" ? "Ouvrir le Drive Test" : "Open Drive Test"]
        XCTAssertTrue(openDrive.waitForExistence(timeout: 5))
        openDrive.tap() // Opens the dedicated controller; never starts a measurement.
        let acknowledge = app.buttons[locale == "fr" ? "J'ai compris" : "Got it"]
        if acknowledge.waitForExistence(timeout: 3) {
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(acknowledge, in: app))
            acknowledge.tap() // Information only; never starts a drive test.
            XCTAssertTrue(acknowledge.waitForNonExistence(timeout: 5))
        }
        let purpose = locale == "fr" ? "Des speedtests pendant ton trajet" : "Speedtests along your route"
        XCTAssertTrue(app.staticTexts[purpose].waitForExistence(timeout: 10))
        capture(app, name: "measurement-\(locale)-drive-controls")
        for (identifier, choice) in [("drivetest.interval", "1 km"),
                                      ("drivetest.dataCap", locale == "fr" ? "2 Go" : "2 GB")] {
            let control = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertTrue(app.frame.contains(control.frame))
            // SwiftUI menu pickers can report isHittable=false on iOS27;
            // prove the actual touch, menu and selected value instead.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let option = app.buttons[choice].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(control.label.contains(choice))
        }
        XCTAssertFalse(app.buttons["Les deux"].exists)
        XCTAssertFalse(app.buttons["Couverture"].exists)
        XCTAssertTrue(app.buttons[locale == "fr" ? "Démarrer le Drive Test" : "Start Drive Test"].exists)
        capture(app, name: "measurement-\(locale)-drive-test-no-coverage")
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
