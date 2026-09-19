import XCTest

/// QA visuel + fonctionnel de l'onboarding (3 slides).
/// 1. Traverse l'écran jusqu'à la 3e slide par tap sur « Suivant » puis par
///    swipe, avec des pauses pour qu'une vidéo `simctl io recordVideo` lancée
///    à l'extérieur capture chaque transition.
/// 2. Vérifie que tuer l'app sans terminer l'onboarding ne le marque PAS
///    complété (régression du binding `fullScreenCover`).
/// 3. Termine par « Commencer » et vérifie que l'onboarding ne revient plus.
/// Nécessite une installation fraîche (sq.hasCompletedOnboarding absent/false).
@MainActor
final class OnboardingAnimationQATests: XCTestCase {
    func testCurrentOnboardingFrenchCopyAndCompletion() throws {
        try checkLocalizedTour(locale: "fr", destination: "map")
    }

    func testCurrentOnboardingEnglishCopyAndCompletion() throws {
        try checkLocalizedTour(locale: "en")
    }

    func testCurrentOnboardingEnglishAtLargestTextSize() throws {
        try checkLocalizedTour(locale: "en", largeText: true)
    }

    func testFirstChoiceFrenchMeasure() throws {
        try checkLocalizedTour(locale: "fr", destination: "measure")
    }

    func testFirstChoiceEnglishMap() throws {
        try checkLocalizedTour(locale: "en", destination: "map")
    }

    private struct RecipeLogin: Decodable {
        let password: String
        let appBundlePath: String
    }

    func testRealLoginAfterGuestMeasureKeepsMeasureTab() throws {
        try checkRealLogin(destination: "measure", account: "a")
    }

    func testRealLoginAfterGuestMapKeepsMapTab() throws {
        try checkRealLogin(destination: "map", account: "b")
    }

    private func checkRealLogin(destination: String, account: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SQ_ONBOARDING_LOGIN_FIXTURE"] else {
            throw XCTSkip("Requires the isolated recipe and SQ_ONBOARDING_LOGIN_FIXTURE")
        }
        let fixture = try JSONDecoder().decode(RecipeLogin.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let bundle = try XCTUnwrap(Bundle(path: fixture.appBundlePath))
        for key in ["SQ_API_BASE_URL", "SQ_APP_BASE_URL"] {
            guard bundle.object(forInfoDictionaryKey: key) as? String == "http://127.0.0.1:49141" else {
                XCTFail("Refusing an application outside the isolated recipe")
                return
            }
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: "fr")
        let next = app.buttons["Suivant"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        next.tap(); next.tap()
        let choice = app.buttons[destination == "map" ? "onboarding.openMap" : "onboarding.openMeasure"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
        choice.tap()
        let close = app.buttons["guest.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20)); close.tap()
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
        XCTAssertTrue(selected.waitForExistence(timeout: 60), "Real authentication did not reach the chosen tab")
        let later = app.buttons["Plus tard"]
        let systemLater = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Plus tard"]
        for _ in 0..<8 {
            if later.exists { later.tap() }
            else if systemLater.exists { systemLater.tap() }
            if selected.isHittable { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(selected.isSelected, "Authentication lost the chosen destination")
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

    private func checkLocalizedTour(locale: String, largeText: Bool = false, destination: String = "measure") throws {
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
            ? ["données disponibles", "publiés automatiquement", "les données varient"]
            : ["data available", "published automatically", "Data varies"]
        for index in scenes.indices {
            let slide = app.descendants(matching: .any)["onboarding.slide.\(scenes[index])"].firstMatch
            XCTAssertTrue(slide.waitForExistence(timeout: 5))
            XCTAssertTrue(slide.label.contains(expected[index]), slide.label)
            XCTAssertFalse(slide.label.contains("partout en France"))
            XCTAssertFalse(slide.label.contains("uniquement si tu le décides"))
            let indicator = app.buttons["onboarding.page.\(index)"]
            XCTAssertEqual(indicator.label, locale == "fr" ? "Étape \(index + 1) sur 3" : "Step \(index + 1) of 3")
            XCTAssertGreaterThanOrEqual(indicator.frame.height, 44)
            XCTAssertGreaterThanOrEqual(indicator.frame.width, 44)
            if index == 2 {
                XCTAssertTrue(slide.label.contains(locale == "fr" ? "carte vide" : "empty map"))
            }
            if largeText { app.swipeUp() }
            if index < 2 {
                for _ in 0..<6 where !next.isHittable { app.swipeUp() }
            } else {
                let lastChoice = app.buttons["onboarding.openMeasure"]
                for _ in 0..<6 where !lastChoice.isHittable || lastChoice.frame.maxY > app.frame.maxY - 8 { app.swipeUp() }
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "onboarding-\(locale)-\(largeText ? "large" : "normal")-\(index + 1)"
            shot.lifetime = .keepAlways
            add(shot)
            if index < 2 { XCTAssertTrue(next.isHittable); next.tap() }
        }
        let map = app.buttons["onboarding.openMap"]
        let measure = app.buttons["onboarding.openMeasure"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertTrue(measure.isHittable)
        XCTAssertLessThanOrEqual(map.frame.maxY, measure.frame.minY, "Discovery actions must not overlap")
        XCTAssertGreaterThanOrEqual(map.frame.height, 44)
        XCTAssertGreaterThanOrEqual(measure.frame.height, 44)
        if largeText && app.frame.width <= 400 {
            XCTAssertGreaterThan(map.frame.height, 80, "Large multiline labels need an expanded action frame")
            XCTAssertGreaterThan(measure.frame.height, 80)
        }
        XCTAssertEqual(map.label, locale == "fr" ? "Explorer la carte" : "Explore the map")
        XCTAssertEqual(measure.label, locale == "fr" ? "Mesurer mon réseau" : "Measure my network")
        (destination == "map" ? map : measure).tap()
        let close = app.buttons["guest.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["Email"].isHittable, "Login must not be interactive under the guest map")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A destination must not request a permission by itself")
        close.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["login.guestMap"].isHittable)
        XCTAssertTrue(app.buttons["login.guestMeasure"].isHittable)
        app.terminate()
        app.launchArguments = ["--reset-auth"]
        app.sqLaunch(locale: locale)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20))
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

        let start = app.buttons["onboarding.openMap"]
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

        // Terminer pour de vrai : Passer n'existe que hors dernière slide.
        button("Passer").tap()
        // Le bootstrap de session (.checking) peut durer plusieurs secondes au
        // premier démarrage : on attend l'écran de connexion largement.
        XCTAssertTrue(
            button("Explorer").waitForExistence(timeout: 30),
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
