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
    func testTourThroughThirdSlide() throws {
        let app = XCUIApplication()
        app.launch()

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

        let start = button("Commencer")
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Bouton final absent sur la 3e slide")

        // Kill sans terminer : au relancement l'onboarding doit ENCORE être là
        // (avant correctif, le démontage du fullScreenCover écrivait le flag).
        app.terminate()
        app.launch()
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
        app.launch()
        XCTAssertFalse(
            button("Suivant").waitForExistence(timeout: 6),
            "L'onboarding revient alors qu'il a été complété"
        )
        print("QA_ONBOARDING_TOUR_DONE")
    }
}
