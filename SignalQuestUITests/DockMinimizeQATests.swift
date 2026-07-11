import XCTest

/// Vérifie la rétraction du dock au scroll (équivalent custom de
/// `tabBarMinimizeBehavior(.onScrollDown)`) : scroll vers le bas → pastille
/// (icône de l'onglet actif seule) ; tap sur la pastille → dock redéployé ;
/// remontée → dock redéployé. Captures attachées à chaque étape.
/// Auth : token réel via `SQ_AUTH_TOKEN` si fourni, sinon mode démo.
@MainActor
final class DockMinimizeQATests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDockMinimizesOnScrollThenExpands() throws {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty {
            app.launchArguments += ["--mock-auth"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        }
        app.launch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        // Ferme les dialogues système résiduels (notifications, « Open in
        // SignalQuest? » laissé par un simctl openurl) — SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        for label in ["Annuler", "Cancel"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); break }
        }

        // Onglet Communauté : le feed est assez long pour rester scrollé
        // (l'Accueil est trop court : le rebond ramène l'offset près du haut,
        // ce qui redéploie aussitôt le dock — comportement voulu).
        let communaute = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(communaute.waitForExistence(timeout: 25), "dock absent")
        communaute.tap()
        Thread.sleep(forTimeInterval: 5)
        snap(app, "dock-01-deploye")

        // Scroll vers le bas → le dock se rétracte en pastille.
        app.swipeUp()
        let pill = app.buttons["Déployer la navigation"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4), "dock non rétracté après un scroll vers le bas")
        snap(app, "dock-02-retracte")

        // Tap sur la pastille → dock redéployé (les 5 onglets reviennent).
        pill.tap()
        XCTAssertTrue(app.buttons["Carte"].waitForExistence(timeout: 4), "dock non redéployé après tap sur la pastille")
        snap(app, "dock-03-redeploye-tap")

        // Re-rétracte (double swipe : le feed peut être revenu en haut après
        // un rechargement), puis remonte : le dock doit se redéployer seul.
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(pill.waitForExistence(timeout: 4), "dock non rétracté au second scroll")
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(app.buttons["Carte"].waitForExistence(timeout: 4), "dock non redéployé après remontée")
        snap(app, "dock-04-redeploye-scroll")

        // Carte : dock verre au-dessus des tuiles (vérif matériau Liquid Glass).
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        Thread.sleep(forTimeInterval: 9)
        snap(app, "dock-05-carte-verre")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
