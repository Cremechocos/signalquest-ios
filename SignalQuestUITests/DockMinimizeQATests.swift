import XCTest

/// Vérifie la rétraction du DOCK CUSTOM pré-iOS 26 au scroll (équivalent
/// custom de `tabBarMinimizeBehavior(.onScrollDown)`) : scroll vers le bas →
/// libellés masqués, cinq icônes gardées (dock Halo) ; tap sur un onglet → dock
/// redéployé ; remontée → dock redéployé. Captures attachées à chaque étape.
/// Le simulateur iOS 26+ affiche la barre système native : `--qa-legacy-dock`
/// force le dock custom pour tester le chemin pré-iOS 26.
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
        app.launchArguments += ["--qa-legacy-dock"]
        app.sqLaunch()
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

        // Dock Halo : rétracté, il garde ses cinq onglets et masque leurs libellés.
        // Le signe observable est donc la hauteur de la barre, pas une pastille.
        let dock = app.descendants(matching: .any)["main.navigation"]
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "dock absent")
        let deployed = dock.frame.height

        // Scroll vers le bas → libellés masqués.
        app.swipeUp()
        XCTAssertTrue(waitForHeight(of: dock, { $0 < deployed - 4 }), "dock non rétracté après un scroll vers le bas")
        snap(app, "dock-02-retracte")

        // Tap sur l'onglet courant de la barre rétractée → dock redéployé.
        communaute.tap()
        XCTAssertTrue(waitForHeight(of: dock, { $0 >= deployed - 1 }), "dock non redéployé après un tap")
        snap(app, "dock-03-redeploye-tap")

        // Re-rétracte (double swipe : le feed peut être revenu en haut après
        // un rechargement), puis remonte : le dock doit se redéployer seul.
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitForHeight(of: dock, { $0 < deployed - 4 }), "dock non rétracté au second scroll")
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(waitForHeight(of: dock, { $0 >= deployed - 1 }), "dock non redéployé après remontée")
        snap(app, "dock-04-redeploye-scroll")

        // Carte : dock verre au-dessus des tuiles (vérif matériau Liquid Glass).
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        Thread.sleep(forTimeInterval: 9)
        snap(app, "dock-05-carte-verre")
    }

    /// Attend (4 s au plus) que la hauteur de l'élément vérifie la condition : la
    /// rétraction est animée.
    private func waitForHeight(of element: XCUIElement, _ condition: (CGFloat) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if condition(element.frame.height) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition(element.frame.height)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
