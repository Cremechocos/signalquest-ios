import XCTest

@MainActor
final class SignalQuestUITests: XCTestCase {
    func testLaunchShowsLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth"]
        app.launch()
        XCTAssertTrue(app.staticTexts["SignalQuest"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Se connecter"].waitForExistence(timeout: 5))
    }

    func testTabsVisibleWithMockAuth() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Carte"].exists)
        XCTAssertTrue(app.tabBars.buttons["Speed"].exists)
        XCTAssertTrue(app.tabBars.buttons["Messages"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profil"].exists)
    }

    func testFeedRendersMockedPost() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Feed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Speedtest iOS partagé depuis Paris. Radio détaillée indisponible sur iOS, mais débit et latence contribuent à la carte."].waitForExistence(timeout: 5))
    }

    func testMapRendersMockedAnnotations() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        app.tabBars.buttons["Carte"].tap()
        XCTAssertTrue(app.buttons["Filtres"].waitForExistence(timeout: 5))
    }

    func testSpeedtestIdleState() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        app.tabBars.buttons["Speed"].tap()
        XCTAssertTrue(app.buttons["Lancer le test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Historique"].exists)
    }

    func testRealSpeedtestRunWithInjectedAuthToken() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "Real speedtest QA requires SQ_AUTH_TOKEN")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Speed"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Speed"].tap()

        let startButton = app.buttons["Lancer le test"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowOnce = springboard.buttons["Autoriser une fois"]
        if allowOnce.waitForExistence(timeout: 3) {
            allowOnce.tap()
        }

        XCTAssertTrue(app.staticTexts["Résultat"].waitForExistence(timeout: 120))
        let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        print("REAL_SPEEDTEST_LABELS: \(labels)")

        XCTAssertTrue(app.staticTexts["DL moyen"].exists)
        XCTAssertTrue(app.staticTexts["DL max"].exists)
        XCTAssertTrue(app.staticTexts["UL moyen"].exists)
        XCTAssertTrue(app.staticTexts["UL max"].exists)
        XCTAssertTrue(app.staticTexts["Ping"].exists)
        XCTAssertTrue(app.staticTexts["Jitter"].exists)
        XCTAssertTrue(app.staticTexts["Réseau"].exists)
        XCTAssertFalse(app.staticTexts["P90"].exists)
        XCTAssertFalse(app.staticTexts["P95"].exists)
        XCTAssertFalse(app.staticTexts["Ping médian"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "SignalQuest real speedtest result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMessagesListAndDetailRender() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        app.tabBars.buttons["Messages"].tap()
        let conversation = app.staticTexts["SignalQuest iOS"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        // The row text lives inside a hittable List button, so it isn't independently
        // hittable; tap its coordinate to forward the tap to the row.
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Tu peux partager un post, une photo ou un speedtest vers cette conversation."].waitForExistence(timeout: 5))
    }

    func testProfilePhotosAndLeaderboardsRender() {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth"]
        app.launch()
        app.tabBars.buttons["Profil"].tap()
        XCTAssertTrue(app.staticTexts["SignalQuest iOS"].waitForExistence(timeout: 5))

        app.staticTexts["Photos"].tap()
        XCTAssertTrue(app.staticTexts["Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paris centre"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.staticTexts["Classement"].tap()
        XCTAssertTrue(app.staticTexts["Mon rang"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Camille"].exists)
    }
}
