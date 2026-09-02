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
    /// Lance l'app dans une langue FORCÉE.
    ///
    /// `TEST_RUNNER_SQ_UI_TEST_LOCALE=…` passé à `xcodebuild` n'atteint PAS ce
    /// processus (vérifié : le parcours « anglais » démarrait en français), d'où
    /// le paramètre explicite. La variable d'environnement reste acceptée en
    /// second recours pour les lancements depuis Xcode.
    ///
    /// ⚠️ Ne jamais ajouter `-AppleLanguages` aux `launchArguments` de l'appelant :
    /// un doublon casse l'analyse du domaine d'arguments et l'app démarre dans la
    /// langue système.
    func sqLaunch(locale: String? = nil) {
        let resolved = locale ?? ProcessInfo.processInfo.environment["SQ_UI_TEST_LOCALE"] ?? "fr"
        launchArguments += ["-AppleLanguages", "(\(resolved))", "-AppleLocale", resolved]
        launch()
    }
}

@MainActor
enum SignalQuestUITestSupport {
    static let tabs = ["Accueil", "Carte", "Tester", "Communauté", "Profil"]

    static func launch(
        _ app: XCUIApplication,
        arguments: [String],
        environment: [String: String] = [:],
        locale: String? = nil
    ) {
        app.launchArguments = arguments
        environment.forEach { app.launchEnvironment[$0.key] = $0.value }
        app.sqLaunch(locale: locale)
        completeOnboardingIfNeeded(in: app)
    }

    static func completeOnboardingIfNeeded(in app: XCUIApplication) {
        // Le bouton est cherché dans LES DEUX langues : l'app est désormais
        // bilingue, et un test lancé en anglais restait bloqué sur l'onboarding
        // en cherchant « Passer ». Un identifiant stable serait mieux — c'est le
        // seul écran qui n'en a pas encore.
        let skip = app.buttons["Passer"].exists ? app.buttons["Passer"] : app.buttons["Skip"]
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
    func testFrenchEnglishAndUnsupportedLanguageNavigation() {
        let englishTabs = ["Home", "Map", "Test", "Community", "Profile"]
        for legacyDock in [false, true] {
            for (locale, expectedTabs) in [("fr", SignalQuestUITestSupport.tabs), ("en", englishTabs), ("ja", englishTabs)] {
                let app = XCUIApplication()
                let arguments = legacyDock ? ["--mock-auth", "--qa-legacy-dock"] : ["--mock-auth"]
                SignalQuestUITestSupport.launch(app, arguments: arguments, locale: locale)
                for title in expectedTabs {
                    let tab = legacyDock
                        ? app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
                        : SignalQuestUITestSupport.tab(named: title, in: app)
                    XCTAssertTrue(tab.waitForExistence(timeout: 10), "Locale \(locale), legacy=\(legacyDock) : onglet \(title) absent")
                }
                XCTAssertTrue(app.descendants(matching: .any)["home.action.speedtest"].firstMatch.waitForExistence(timeout: 10))
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "localization-\(locale)-\(legacyDock ? "legacy" : "native")"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                app.terminate()
            }
        }
    }

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

    func testCommunityPostCardAndDetailRemainReadable() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        SignalQuestUITestSupport.tab(named: "Communauté", in: app).tap()

        let header = app.descendants(matching: .any)["feed.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertEqual(header.label, "Communauté")

        let postText = app.staticTexts[
            "Speedtest iOS partagé depuis Paris. Radio détaillée indisponible sur iOS, mais débit et latence contribuent à la carte."
        ]
        XCTAssertTrue(postText.waitForExistence(timeout: 8))

        let cardScreenshot = XCTAttachment(screenshot: app.screenshot())
        cardScreenshot.name = "community-post-card-readable"
        cardScreenshot.lifetime = .keepAlways
        add(cardScreenshot)

        postText.tap()

        XCTAssertTrue(app.navigationBars["Speedtest partagé"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Fermer"].exists)
        XCTAssertTrue(app.staticTexts["Réception"].exists)
        XCTAssertTrue(app.staticTexts["Envoi"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "community-post-detail-readable"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUpdatedHomeSpeedtestAndCommunityVisualStates() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])

        XCTAssertTrue(app.descendants(matching: .any)["home.action.speedtest"].firstMatch.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "updated-home")

        SignalQuestUITestSupport.tab(named: "Tester", in: app).tap()
        XCTAssertTrue(app.buttons["Lancer le test"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "updated-speedtest-idle")

        SignalQuestUITestSupport.tab(named: "Communauté", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["feed.header"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Messages"].exists)
        XCTAssertTrue(app.buttons["Explorer"].exists)
        XCTAssertTrue(app.buttons["Créer une publication"].exists)
        attachScreenshot(app, name: "updated-community")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    /// P0-03-03 — vrai parcours authentifié, sans mock d'auth dans l'app.
    ///
    /// Le même test est lancé en deux phases sur le même simulateur :
    /// 1. `switch` avec le backend local actif : A → brouillon → logout → B ;
    /// 2. `offline-relaunch` après arrêt du backend : B doit repartir de sa session
    ///    locale et ne toujours pas voir le brouillon de A.
    ///
    /// Le chemin du fichier 0600 et les identifiants restent exclusivement dans
    /// l'environnement du runner XCUITest. Ils ne sont jamais copiés dans
    /// `XCUIApplication.launchEnvironment` ni dans les arguments de l'app.
    func testAuthenticatedAccountSwitchKeepsDraftPrivate() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["SQ_ACCOUNT_SWITCH_FIXTURE_PATH"] else {
            throw XCTSkip("Fixture P0-03-03 absente")
        }
        let phase = try XCTUnwrap(
            AccountSwitchPhase(rawValue: environment["SQ_ACCOUNT_SWITCH_PHASE"] ?? ""),
            "SQ_ACCOUNT_SWITCH_PHASE doit valoir switch ou offline-relaunch"
        )
        let fixture = try AccountSwitchFixture.loadSecurely(from: fixturePath)
        let draftSentinel = "P0-03-03-\(fixture.runId)-A-PRIVATE"
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        XCTAssertNil(app.launchEnvironment["SQ_ACCOUNT_SWITCH_FIXTURE_PATH"])
        addTeardownBlock { app.terminate() }

        switch phase {
        case .switchAccounts:
            SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--qa-tab-profile"])
            login(fixture.users.a, in: app)
            assertAuthenticatedUser(fixture.users.a, in: app)

            relaunch(app, arguments: ["--qa-tab-community"])
            openComposer(in: app)
            let draft = composerTextField(in: app)
            if !composerText(in: draft).isEmpty {
                let clear = app.buttons["Supprimer le brouillon"]
                XCTAssertTrue(clear.waitForExistence(timeout: 5), "Ancien brouillon synthétique impossible à réinitialiser")
                clear.tap()
            }
            XCTAssertEqual(composerText(in: composerTextField(in: app)), "", "Le compte A de fixture doit commencer sans ancien brouillon")
            draft.tap()
            draft.typeText(draftSentinel)
            XCTAssertEqual(composerText(in: composerTextField(in: app)), draftSentinel)
            app.buttons["Annuler"].tap()

            relaunch(app, arguments: ["--qa-tab-profile"])
            assertAuthenticatedUser(fixture.users.a, in: app)
            logoutFromProfile(in: app)
            login(fixture.users.b, in: app)
            assertAuthenticatedUser(fixture.users.b, in: app)
            relaunch(app, arguments: ["--qa-tab-community"])
            assertComposerDoesNotContain(draftSentinel, in: app)

        case .offlineRelaunch:
            // Aucun `--reset-auth` : on valide le cold start optimiste du compte B
            // avec les credentials et le cache utilisateur laissés par la phase 1.
            SignalQuestUITestSupport.launch(app, arguments: ["--qa-tab-profile"])
            assertAuthenticatedUser(fixture.users.b, in: app)
            relaunch(app, arguments: ["--qa-tab-community"])
            assertComposerDoesNotContain(draftSentinel, in: app)
        }
    }

    private func login(_ user: AccountSwitchFixture.User, in app: XCUIApplication) {
        let email = app.textFields["Email"]
        let password = app.secureTextFields["Mot de passe"]
        XCTAssertTrue(email.waitForExistence(timeout: 15), "Champ e-mail absent")
        XCTAssertTrue(password.waitForExistence(timeout: 5), "Champ mot de passe absent")
        email.tap()
        email.typeText(user.email)
        password.tap()
        password.typeText(user.password)

        let submit = app.buttons["Se connecter"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(submit, in: app), "Bouton de connexion inaccessible")
        submit.tap()
        dismissNotificationPermissionIfPresent(in: app)
        XCTAssertTrue(
            SignalQuestUITestSupport.tab(named: "Profil", in: app).waitForExistence(timeout: 20),
            "La connexion locale n'a pas ouvert l'application"
        )
    }

    private func dismissNotificationPermissionIfPresent(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyFrench = springboard.buttons["Ne pas autoriser"]
        let denyEnglish = springboard.buttons["Don’t Allow"]
        let deny = denyFrench.exists ? denyFrench : denyEnglish
        if deny.waitForExistence(timeout: 3) {
            deny.tap()
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "L'app ne revient pas au premier plan après la permission")
        }
    }

    private func assertAuthenticatedUser(_ user: AccountSwitchFixture.User, in app: XCUIApplication) {
        let displayName = app.descendants(matching: .any)["profile.displayName"].firstMatch
        XCTAssertTrue(displayName.waitForExistence(timeout: 15), "Profil authentifié absent")
        XCTAssertEqual(displayName.label, user.name, "Le profil visible n'est pas celui attendu")
    }

    private func logoutFromProfile(in app: XCUIApplication) {
        let logout = app.buttons["Déconnexion"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(logout, in: app), "Déconnexion inaccessible")
        logout.tap()
        XCTAssertTrue(app.buttons["Se connecter"].waitForExistence(timeout: 20), "Le logout n'a pas rouvert la connexion")
    }

    private func openComposer(in app: XCUIApplication) {
        let create = app.buttons["Créer une publication"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "Action de création absente")
        create.tap()
        XCTAssertTrue(composerTextField(in: app).waitForExistence(timeout: 10), "Champ du brouillon absent")
    }

    private func assertComposerDoesNotContain(_ sentinel: String, in app: XCUIApplication) {
        openComposer(in: app)
        let draft = composerTextField(in: app)
        XCTAssertEqual(composerText(in: draft), "", "Le compte B voit un brouillon privé qui ne lui appartient pas")
        XCTAssertNotEqual(composerText(in: draft), sentinel)
        app.buttons["Annuler"].tap()
    }

    private func composerTextField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["feed.composer.text"].firstMatch
    }

    private func composerText(in element: XCUIElement) -> String {
        let placeholder = "Quoi de neuf sur le réseau ?"
        guard let value = element.value as? String, value != placeholder else { return "" }
        return value
    }

    private func relaunch(_ app: XCUIApplication, arguments: [String]) {
        app.terminate()
        SignalQuestUITestSupport.launch(app, arguments: arguments)
    }
}

private enum AccountSwitchPhase: String {
    case switchAccounts = "switch"
    case offlineRelaunch = "offline-relaunch"
}

private struct AccountSwitchFixture: Decodable {
    struct User: Decodable {
        let id: String
        let email: String
        let password: String
        let name: String

        fileprivate var isValid: Bool {
            !id.isEmpty && !email.isEmpty && email.contains("@") && !password.isEmpty && !name.isEmpty
        }
    }

    struct Users: Decodable {
        let a: User
        let b: User

        enum CodingKeys: String, CodingKey {
            case a = "A"
            case b = "B"
        }
    }

    let version: Int
    let runId: String
    let baseUrl: String
    let users: Users

    static func loadSecurely(from path: String) throws -> Self {
        let fileURL = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard permissions & 0o777 == 0o600,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AccountSwitchFixtureError.insecureFile
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= 64 * 1024 else { throw AccountSwitchFixtureError.invalidFixture }
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        guard fixture.version == 1,
              !fixture.runId.isEmpty,
              fixture.users.a.isValid,
              fixture.users.b.isValid,
              fixture.users.a.id != fixture.users.b.id,
              fixture.users.a.email != fixture.users.b.email,
              let url = URLComponents(string: fixture.baseUrl),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port == 4182,
              url.path.isEmpty || url.path == "/" else {
            throw AccountSwitchFixtureError.invalidFixture
        }
        return fixture
    }
}

private enum AccountSwitchFixtureError: Error {
    case insecureFile
    case invalidFixture
}
