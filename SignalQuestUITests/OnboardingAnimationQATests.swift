import XCTest

/// QA visuel + fonctionnel de l'onboarding (3 slides).
/// 1. Traverse l'écran jusqu'à la 3e slide par tap sur « Suivant » puis par
///    swipe, avec des pauses pour qu'une vidéo `simctl io recordVideo` lancée
///    à l'extérieur capture chaque transition.
/// 2. Vérifie que tuer l'app sans terminer l'onboarding ne le marque PAS
///    complété (régression du binding `fullScreenCover`).
/// 3. Termine par l'un des trois choix du dernier écran (inscription,
///    connexion, invité) et vérifie que l'onboarding ne revient plus.
/// Nécessite une installation fraîche (sq.hasCompletedOnboarding absent/false).
@MainActor
final class OnboardingAnimationQATests: XCTestCase {
    private enum Exit { case signUp, signIn, guest }

    func testCurrentOnboardingFrenchCopyAndCompletion() throws {
        try checkLocalizedTour(locale: "fr")
    }

    func testCurrentOnboardingEnglishCopyAndCompletion() throws {
        try checkLocalizedTour(locale: "en")
    }

    func testCurrentOnboardingEnglishAtLargestTextSize() throws {
        try checkLocalizedTour(locale: "en", largeText: true)
    }

    func testCreateAccountChoiceFrenchOpensRegistration() throws {
        try checkLocalizedTour(locale: "fr", exit: .signUp)
    }

    func testSignInChoiceEnglishOpensLogin() throws {
        try checkLocalizedTour(locale: "en", exit: .signIn)
    }

    /// « Passer » ne termine plus l'onboarding : il amène aux trois choix.
    func testSkipLeadsToTheThreeChoices() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: "fr")
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20))
        skip.tap()
        XCTAssertTrue(app.buttons["onboarding.createAccount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.signIn"].exists)
        XCTAssertTrue(app.buttons["onboarding.continueAsGuest"].exists)
        XCTAssertFalse(skip.exists, "Skip disappears once the choices are shown")
        XCTAssertFalse(app.buttons["login.submit"].exists, "Skipping must not decide for the user")
    }

    func testGuestApplicationFrenchNavigationAndPersistence() throws {
        try checkGuestApplication(locale: "fr")
    }

    func testGuestApplicationEnglishLegacyDockAndPersistence() throws {
        try checkGuestApplication(locale: "en", legacyDock: true)
    }

    private func checkGuestApplication(locale: String, legacyDock: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        let extras = legacyDock ? ["--qa-legacy-dock"] : []
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"] + extras,
            environment: ["SQ_QA_SPEEDTEST_AUTORUN": "0", "SQ_QA_SPEEDTEST_EXIT": "0"], locale: locale)
        XCTAssertFalse(app.buttons["login.guestMap"].exists)
        XCTAssertFalse(app.buttons["login.guestMeasure"].exists)
        SignalQuestUITestSupport.enterGuestApplication(app, tab: "home", locale: locale)
        XCTAssertTrue(app.staticTexts[locale == "fr" ? "Bienvenue sur" : "Welcome to"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[locale == "fr" ? "Notifications" : "Notifications"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "guest-application-\(locale)-home"; shot.lifetime = .keepAlways; add(shot)
        for (title, identifier) in [(locale == "fr" ? "Carte" : "Map", "map.filters"),
                                     (locale == "fr" ? "Tester" : "Test", "speedtest.settings")] {
            let tab = SignalQuestUITestSupport.tab(named: title, in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["guest.close"].exists)
        }
        XCTAssertTrue(app.buttons[locale == "fr" ? "Mes tests partagés" : "My shared tests"].exists)
        for title in [locale == "fr" ? "Profil" : "Profile", locale == "fr" ? "Communauté" : "Community"] {
            SignalQuestUITestSupport.tab(named: title, in: app).tap()
            XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.textFields["Email"].exists)
            XCTAssertFalse(app.buttons["login.continueGuest"].exists)
        }
        SignalQuestUITestSupport.tab(named: locale == "fr" ? "Carte" : "Map", in: app).tap()
        XCTAssertTrue(app.buttons["map.filters"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = extras
        app.sqLaunch(locale: locale)
        XCTAssertTrue(SignalQuestUITestSupport.tab(named: locale == "fr" ? "Accueil" : "Home", in: app)
            .waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["onboarding.page.0"].exists)
        SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app).tap()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 15))
    }

    private struct RecipeLogin: Decodable {
        let password: String
        let appBundlePath: String?
        let apiBaseURL: String?
    }

    func testRealLoginFromGuestProfileCanReturnToMeasure() throws {
        try checkRealLogin(destination: "measure", account: "a")
    }

    func testRealLoginFromGuestProfileCanReturnToMap() throws {
        try checkRealLogin(destination: "map", account: "b")
    }

    private func checkRealLogin(destination: String, account: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture: RecipeLogin
        if let encoded = environment["SQ_ONBOARDING_LOGIN_FIXTURE_B64"], let data = Data(base64Encoded: encoded) {
            fixture = try JSONDecoder().decode(RecipeLogin.self, from: data)
            guard environment["SQ_ONBOARDING_PHYSICAL_LOGIN"] == "beta-usb-verified",
                  let raw = fixture.apiBaseURL, let origin = URL(string: raw),
                  origin.scheme == "http", origin.port == 49144,
                  (origin.host ?? "").contains(":") else {
                XCTFail("Physical login requires the independently verified paired USB Beta recipe")
                return
            }
        } else {
            guard let path = environment["SQ_ONBOARDING_LOGIN_FIXTURE"] else {
                throw XCTSkip("Requires an explicitly verified isolated login recipe")
            }
            fixture = try JSONDecoder().decode(RecipeLogin.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let bundle = try XCTUnwrap(Bundle(path: try XCTUnwrap(fixture.appBundlePath)))
            for key in ["SQ_API_BASE_URL", "SQ_APP_BASE_URL"] {
                guard bundle.object(forInfoDictionaryKey: key) as? String == "http://127.0.0.1:49141" else {
                    XCTFail("Refusing an application outside the isolated recipe")
                    return
                }
            }
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: "fr")
        let next = app.buttons["Suivant"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        next.tap(); next.tap()
        let choice = app.buttons["onboarding.continueAsGuest"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
        choice.tap()
        if destination == "measure" {
            let measure = SignalQuestUITestSupport.tab(named: "Tester", in: app)
            XCTAssertTrue(measure.waitForExistence(timeout: 20)); measure.tap()
        }
        let profile = SignalQuestUITestSupport.tab(named: "Profil", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 20)); profile.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        for _ in 0..<4 where !email.isHittable { app.swipeUp() }
        email.tap(); email.typeText("\(account)@recipe.invalid")
        let password = app.secureTextFields.firstMatch
        for _ in 0..<4 where !password.isHittable { app.swipeUp() }
        password.tap(); password.typeText(fixture.password)
        let submit = app.buttons["login.submit"]
        for _ in 0..<4 where !submit.isHittable { app.swipeUp() }
        submit.tap()
        let icon = destination == "map" ? "map" : "speedometer"
        let labels = destination == "map" ? ["Carte", "Map"] : ["Tester", "Test"]
        let selected = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label IN %@", icon, labels)).firstMatch
        XCTAssertTrue(app.staticTexts["profile.displayName"].waitForExistence(timeout: 60),
                      "Real authentication must reveal the account profile")
        XCTAssertTrue(submit.waitForNonExistence(timeout: 10))
        XCTAssertTrue(selected.exists)
        let later = app.buttons["Plus tard"]
        let systemLater = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Plus tard"]
        for _ in 0..<8 {
            if later.exists { later.tap() }
            else if systemLater.exists { systemLater.tap() }
            if selected.isHittable { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertFalse(app.buttons["login.submit"].exists, "Authentication must leave the protected login screen")
        XCTAssertTrue(profile.isSelected, "Authentication must preserve the Profile destination used to sign in")
        func declineRecipeNotificationsIfPresented() {
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let prompt = system.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "notifications")).firstMatch
            if prompt.exists && system.buttons["Refuser"].exists { system.buttons["Refuser"].tap() }
        }
        declineRecipeNotificationsIfPresented()
        selected.tap()
        if !selected.isSelected {
            declineRecipeNotificationsIfPresented()
            selected.tap()
        }
        XCTAssertTrue(selected.isSelected)
        let interactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: TimeInterval(ProcessInfo.processInfo.environment["SQ_ONBOARDING_SYSTEM_PROMPT_WAIT"] ?? "10") ?? 10), .completed)
        if destination == "measure" {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Prêt à mesurer")).firstMatch.exists)
            XCTAssertFalse(app.buttons["Arrêter"].exists)
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "onboarding-real-login-\(destination)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func checkLocalizedTour(locale: String, largeText: Bool = false, exit: Exit = .guest) throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.sqLaunch(locale: locale)
        let next = app.buttons[locale == "fr" ? "Suivant" : "Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields.firstMatch.exists, "Login must not remain under the introduction")
        let scenes = ["radioWaves", "speedDial", "liveMap"]
        let expected = locale == "fr"
            ? ["données disponibles", "apparaissent sur la carte", "D’un pays à l’autre"]
            : ["data available", "appear on the map", "From one country to the next"]
        for index in scenes.indices {
            let slide = app.descendants(matching: .any)["onboarding.slide.\(scenes[index])"].firstMatch
            XCTAssertTrue(slide.waitForExistence(timeout: 5))
            for inactive in scenes.indices where inactive != index {
                let hidden = app.descendants(matching: .any)["onboarding.slide.\(scenes[inactive])"].firstMatch
                XCTAssertTrue(hidden.waitForNonExistence(timeout: 3),
                    "VoiceOver must not encounter page \(inactive + 1) while page \(index + 1) is active")
            }
            XCTAssertTrue(slide.label.contains(expected[index]), slide.label)
            XCTAssertFalse(slide.label.contains("partout en France"))
            XCTAssertFalse(slide.label.contains("uniquement si tu le décides"))
            let indicator = app.buttons["onboarding.page.\(index)"]
            XCTAssertEqual(indicator.label, locale == "fr" ? "Étape \(index + 1) sur 3" : "Step \(index + 1) of 3")
            XCTAssertGreaterThanOrEqual(indicator.frame.height, 44)
            XCTAssertGreaterThanOrEqual(indicator.frame.width, 44)
            if index == 2 {
                XCTAssertTrue(slide.label.contains(locale == "fr" ? "contributions de la communauté" : "community contributions"))
            }
            if largeText { app.swipeUp() }
            if index < 2 {
                for _ in 0..<6 where !next.isHittable { app.swipeUp() }
            } else {
                let lastChoice = app.buttons["onboarding.continueAsGuest"]
                for _ in 0..<6 where !lastChoice.isHittable || lastChoice.frame.maxY > app.frame.maxY - 8 { app.swipeUp() }
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "onboarding-\(locale)-\(largeText ? "large" : "normal")-\(index + 1)"
            shot.lifetime = .keepAlways
            add(shot)
            if index < 2 { XCTAssertTrue(next.isHittable); next.tap() }
        }
        let create = app.buttons["onboarding.createAccount"]
        let signIn = app.buttons["onboarding.signIn"]
        let guest = app.buttons["onboarding.continueAsGuest"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(signIn.isHittable)
        XCTAssertTrue(guest.isHittable)
        XCTAssertLessThanOrEqual(create.frame.maxY, signIn.frame.minY, "Account actions must not overlap")
        XCTAssertLessThanOrEqual(signIn.frame.maxY, guest.frame.minY)
        for choice in [create, signIn, guest] { XCTAssertGreaterThanOrEqual(choice.frame.height, 44) }
        if largeText && app.frame.width <= 400 {
            XCTAssertGreaterThan(create.frame.height, 80, "Large multiline labels need an expanded action frame")
            XCTAssertGreaterThan(signIn.frame.height, 80)
        }
        XCTAssertEqual(create.label, locale == "fr" ? "Créer un compte" : "Create an account")
        XCTAssertEqual(signIn.label, locale == "fr" ? "J’ai déjà un compte" : "I already have an account")
        XCTAssertEqual(guest.label, locale == "fr" ? "Continuer sans compte" : "Continue without an account")
        XCTAssertFalse(app.buttons["onboarding.skip"].exists, "The last screen only offers its three choices")
        switch exit {
        case .signUp:
            create.tap()
            XCTAssertTrue(app.textFields["auth.signup.email"].waitForExistence(timeout: 20),
                          "Create an account must open the registration form")
            app.terminate()
            app.launchArguments = []
            app.sqLaunch(locale: locale)
            XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.textFields["auth.signup.email"].exists, "Registration only opens right after the introduction")
        case .signIn:
            signIn.tap()
            XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["login.continueGuest"].exists)
            XCTAssertFalse(app.textFields["auth.signup.email"].exists)
        case .guest:
            guest.tap()
            let map = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Carte" : "Map", in: app)
            XCTAssertTrue(map.waitForExistence(timeout: 20))
            XCTAssertTrue(map.isSelected)
            XCTAssertFalse(app.textFields["Email"].isHittable)
            XCTAssertFalse(app.buttons["guest.close"].exists)
            XCTAssertFalse(app.alerts.firstMatch.exists, "A destination must not request a permission by itself")
            let profile = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
            profile.tap()
            XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["login.guestMap"].exists)
            XCTAssertFalse(app.buttons["login.guestMeasure"].exists)
            app.terminate()
            app.launchArguments = []
            app.sqLaunch(locale: locale)
            XCTAssertTrue(SignalQuestUITestSupport.tab(named: locale == "fr" ? "Carte" : "Map", in: app)
                .waitForExistence(timeout: 20), "Guest access must persist after relaunch")
        }
        XCTAssertFalse(app.buttons["onboarding.page.0"].exists)
    }

    func testTourThroughThirdSlide() throws {
        let app = XCUIApplication()
        // La suite complète partage le même simulateur : partir explicitement
        // d'un onboarding vierge plutôt que de dépendre de l'ordre des tests.
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch()

        // L'alerte système de notifications (Firebase) peut recouvrir l'écran :
        // on la ferme pour dégager la scène.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Autoriser"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }

        func button(_ text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }

        let next = button("Suivant")
        if !next.waitForExistence(timeout: 15) {
            print("QA_ONBOARDING_ABSENT — hiérarchie: \(app.debugDescription.prefix(4000))")
            XCTFail("Onboarding non affiché")
        }

        sleep(3)                     // slide 1 posée (chorégraphie d'entrée)
        next.tap()                   // → slide 2
        print("QA_TAP_TO_SLIDE2")
        sleep(3)
        next.tap()                   // → slide 3 (le bouton devient « Commencer »)
        print("QA_TAP_TO_SLIDE3")
        sleep(4)

        // Même arrivée mais par geste (chemin utilisateur le plus courant).
        app.swipeRight()             // retour slide 2
        print("QA_SWIPE_BACK_TO_SLIDE2")
        sleep(3)
        app.swipeLeft()              // → slide 3 par swipe
        print("QA_SWIPE_TO_SLIDE3")
        sleep(4)

        let start = app.buttons["onboarding.createAccount"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Bouton final absent sur la 3e slide")

        // Kill sans terminer : au relancement l'onboarding doit ENCORE être là
        // (avant correctif, le démontage du fullScreenCover écrivait le flag).
        app.terminate()
        app.launchArguments = ["--reset-auth"]
        app.sqLaunch()
        XCTAssertTrue(
            button("Suivant").waitForExistence(timeout: 15),
            "Onboarding marqué complété par un simple kill de l'app"
        )
        print("QA_SURVIVES_RELAUNCH")

        // Terminer pour de vrai : « Passer » mène au dernier écran, puis
        // « J’ai déjà un compte » ouvre la connexion.
        button("Passer").tap()
        let signIn = app.buttons["onboarding.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "Passer doit mener aux trois choix")
        signIn.tap()
        // Le bootstrap de session (.checking) peut durer plusieurs secondes au
        // premier démarrage : on attend l'écran de connexion largement.
        XCTAssertTrue(
            app.buttons["login.continueGuest"].waitForExistence(timeout: 30),
            "L'écran de connexion n'apparaît pas après la fin de l'onboarding"
        )
        print("QA_FINISHED_TO_LOGIN")

        // Après complétion explicite, il ne revient plus.
        app.terminate()
        app.launchArguments = ["--reset-auth"]
        app.sqLaunch()
        XCTAssertFalse(
            button("Suivant").waitForExistence(timeout: 6),
            "L'onboarding revient alors qu'il a été complété"
        )
        print("QA_ONBOARDING_TOUR_DONE")
    }
}
