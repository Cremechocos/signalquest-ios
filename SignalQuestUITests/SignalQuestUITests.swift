import XCTest

extension XCUIApplication {
    /// Lance l'app avec la locale figée en français.
    ///
    /// Toute la suite UI matche des libellés français en dur (`tabs`,
    /// `"Passer"`, `"Les reçus sont chiffrés"`…). Sans ce verrou, les tests
    /// dépendent de la langue du simulateur hôte et casseront le jour où
    /// l'anglais sera ajouté au bundle. Passer par cette méthode plutôt que
    /// `launch()` directement.
    ///
    /// `SQ_UI_TEST_LOCALE` permet de forcer une autre locale — prévu pour le
    /// parcours smoke en anglais une fois la localisation livrée. Non défini =
    /// français.
    func sqLaunch() {
        let locale = ProcessInfo.processInfo.environment["SQ_UI_TEST_LOCALE"] ?? "fr"
        launchArguments += ["-AppleLanguages", "(\(locale))", "-AppleLocale", locale]
        launch()
    }
}

@MainActor
enum SignalQuestUITestSupport {
    static let tabs = ["Accueil", "Carte", "Tester", "Communauté", "Profil"]

    static func launch(
        _ app: XCUIApplication,
        arguments: [String],
        environment: [String: String] = [:]
    ) {
        app.launchArguments = arguments
        environment.forEach { app.launchEnvironment[$0.key] = $0.value }
        app.sqLaunch()
        completeOnboardingIfNeeded(in: app)
    }

    static func completeOnboardingIfNeeded(in app: XCUIApplication) {
        let skip = app.buttons["Passer"]
        for attempt in 0..<3 {
            let exists = attempt == 0 ? skip.waitForExistence(timeout: 2) : skip.exists
            guard exists else { return }
            skip.tap()
            if skip.waitForNonExistence(timeout: 2) { return }
        }
    }

    /// Sur iPad, le style SwiftUI `sidebarAdaptable` peut exposer une barre
    /// latérale plutôt qu'un `XCUIElementTypeTabBar`. Le fallback conserve le
    /// même test fonctionnel dans les deux présentations.
    static func tab(named name: String, in app: XCUIApplication) -> XCUIElement {
        let tabBarButton = app.tabBars.buttons[name]
        if tabBarButton.exists { return tabBarButton }
        let sidebarCell = app.cells
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
        if sidebarCell.exists { return sidebarCell }
        return app.buttons[name].firstMatch
    }

    static func openMessages(in app: XCUIApplication) {
        let community = tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 10), "Onglet Communauté absent")
        community.tap()
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10), "Accès Messages absent de Communauté")
        messages.tap()
    }

    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }

    static func waitForLandscape(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.frame.width > app.frame.height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }
}

@MainActor
final class SignalQuestUITests: XCTestCase {
    func testLaunchShowsLogin() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth"])
        XCTAssertTrue(app.staticTexts["SignalQuest"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Se connecter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Explorer la carte sans compte"].exists)
        XCTAssertTrue(app.buttons["Lancer un speedtest sans compte"].exists)
    }

    func testFiveTabsAndPrimaryStatesWithMockAuth() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])

        for name in SignalQuestUITestSupport.tabs {
            XCTAssertTrue(
                SignalQuestUITestSupport.tab(named: name, in: app).waitForExistence(timeout: 10),
                "Onglet \(name) absent"
            )
        }

        // L'Accueil n'a plus de navigationTitle depuis la refonte (en-tête
        // custom) : on ancre sur la tuile d'action, dont l'identifiant est
        // stable quel que soit le libellé ou la langue.
        XCTAssertTrue(
            app.descendants(matching: .any)["home.action.speedtest"]
                .firstMatch.waitForExistence(timeout: 10)
        )

        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        XCTAssertTrue(app.buttons["Calques et filtres"].waitForExistence(timeout: 10))

        SignalQuestUITestSupport.tab(named: "Tester", in: app).tap()
        XCTAssertTrue(app.buttons["Lancer le test"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["speedtest.history"].firstMatch.exists)

        SignalQuestUITestSupport.tab(named: "Communauté", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["feed.header"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Messages"].exists)

        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile.displayName"].firstMatch.waitForExistence(timeout: 10))
    }

    func testCommunityRendersMockedPost() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.tab(named: "Communauté", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["feed.header"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Speedtest iOS partagé depuis Paris. Radio détaillée indisponible sur iOS, mais débit et latence contribuent à la carte."].waitForExistence(timeout: 5))
    }

    func testMapRendersMockedAnnotations() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        XCTAssertTrue(app.buttons["Calques et filtres"].waitForExistence(timeout: 5))
    }

    func testSpeedtestIdleState() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.tab(named: "Tester", in: app).tap()
        XCTAssertTrue(app.buttons["Lancer le test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["speedtest.history"].firstMatch.exists)
    }

    func testGuestCanExploreMapWithoutAccount() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth"])

        let guestMap = app.buttons["Explorer la carte sans compte"]
        XCTAssertTrue(guestMap.waitForExistence(timeout: 10))
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(guestMap, in: app))
        guestMap.tap()

        XCTAssertTrue(app.staticTexts["Explorer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Fermer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Se connecter"].exists)
        XCTAssertTrue(app.buttons["Calques et filtres"].waitForExistence(timeout: 10))
    }

    func testGuestCanOpenSpeedtestAndReceiptsWithoutAccount() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth"])

        let guestSpeedtest = app.buttons["Lancer un speedtest sans compte"]
        XCTAssertTrue(guestSpeedtest.waitForExistence(timeout: 10))
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(guestSpeedtest, in: app))
        guestSpeedtest.tap()

        XCTAssertTrue(app.buttons["Lancer le test"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Fermer"].exists)
        XCTAssertTrue(app.buttons["Mes reçus"].exists)
        app.buttons["Mes reçus"].tap()
        XCTAssertTrue(app.navigationBars["Reçus invités"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Les reçus sont chiffrés")
            ).firstMatch.waitForExistence(timeout: 10)
        )
    }

    func testIPadLandscapeKeepsPrimaryNavigationUsable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        try XCTSkipUnless(min(app.frame.width, app.frame.height) >= 600, "Gate réservé à une destination iPad")
        defer { XCUIDevice.shared.orientation = .portrait }

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(SignalQuestUITestSupport.waitForLandscape(app), "L'app ne passe pas en paysage sur iPad")

        for name in SignalQuestUITestSupport.tabs {
            let tab = SignalQuestUITestSupport.tab(named: name, in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Navigation \(name) absente en paysage")
            tab.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["profile.displayName"].firstMatch.waitForExistence(timeout: 10))
    }

    func testRealSpeedtestRunWithInjectedAuthToken() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "Real speedtest QA requires SQ_AUTH_TOKEN")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.sqLaunch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let tester = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(tester.waitForExistence(timeout: 20))
        tester.tap()

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
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.openMessages(in: app)
        let conversation = app.staticTexts["SignalQuest iOS"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        // The row text lives inside a hittable List button, so it isn't independently
        // hittable; tap its coordinate to forward the tap to the row.
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Tu peux partager un post, une photo ou un speedtest vers cette conversation."].waitForExistence(timeout: 5))
    }

    func testProfilePhotosAndLeaderboardsRender() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile.displayName"].firstMatch.waitForExistence(timeout: 5))

        app.staticTexts["Photos"].tap()
        XCTAssertTrue(app.staticTexts["Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paris centre"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.staticTexts["Classements"].tap()
        // La carte « Mon rang » et les colonnes du podium regroupent leurs
        // enfants (accessibilityElement(children: .combine)) : on matche donc
        // l'identifiant de la carte et le label combiné du podium.
        let myRank = app.descendants(matching: .any)["Mon rang"].firstMatch
        XCTAssertTrue(myRank.waitForExistence(timeout: 5))
        let camille = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Camille'"))
            .firstMatch
        XCTAssertTrue(camille.waitForExistence(timeout: 5))
        let speedShot = XCTAttachment(screenshot: app.screenshot())
        speedShot.name = "Leaderboards — onglet Vitesse"
        speedShot.lifetime = .keepAlways
        add(speedShot)

        // Onglet Points : pastilles de niveau dans les rangées du classement.
        app.buttons["Points"].tap()
        let levelBadge = app.descendants(matching: .any)["leaderboard.levelPill"].firstMatch
        XCTAssertTrue(levelBadge.waitForExistence(timeout: 5))
        let pointsShot = XCTAttachment(screenshot: app.screenshot())
        pointsShot.name = "Leaderboards — onglet Points"
        pointsShot.lifetime = .keepAlways
        add(pointsShot)
    }
}
