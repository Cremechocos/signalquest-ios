import XCTest

/// Tour d'audit du redesign : couvre les écrans NON visités par
/// `RedesignTourQATests` — auth (connexion, inscription, mot de passe oublié),
/// modes invités, et les écrans secondaires accessibles depuis Profil /
/// Communauté / Tester. Chaque étape est défensive (skip si l'élément manque)
/// et attache une capture nommée.
@MainActor
final class RedesignAuditTourQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    // MARK: - Écrans déconnectés (login / signup / mdp oublié / invités)

    func testLoggedOutTour() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-auth", "--reset-map"]
        app.launch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        XCTAssertTrue(app.buttons["Se connecter"].waitForExistence(timeout: 20), "écran de connexion absent")
        snap(app, "a1-connexion")

        if tapIfExists(app.buttons["Créer un compte"], in: app) {
            Thread.sleep(forTimeInterval: 2)
            snap(app, "a2-inscription")
            // L'inscription est une sheet : « J'ai déjà un compte » la referme.
            if !tapIfExists(app.buttons["J'ai déjà un compte"], in: app) { dismissSheet(app) }
            Thread.sleep(forTimeInterval: 1)
        }

        if tapIfExists(app.buttons["Mot de passe oublié ?"], in: app) {
            Thread.sleep(forTimeInterval: 2)
            snap(app, "a3-mdp-oublie")
            if !tapIfExists(app.buttons["Retour à la connexion"], in: app) { dismissSheet(app); back(app) }
            Thread.sleep(forTimeInterval: 1)
        }

        // Mode invité : speedtest sans compte.
        let guestTest = firstExisting([
            app.buttons["Tester sans compte"],
            app.buttons["Lancer un speedtest sans compte"]
        ])
        if let guestTest, guestTest.isHittable {
            guestTest.tap()
            Thread.sleep(forTimeInterval: 4)
            snap(app, "a4-tester-invite")
            tapIfExists(app.buttons["Fermer"], in: app)
        }

        // Mode invité : carte sans compte.
        let guestMap = firstExisting([
            app.buttons["Explorer sans compte"],
            app.buttons["Explorer la carte sans compte"]
        ])
        if let guestMap, guestMap.waitForExistence(timeout: 4), guestMap.isHittable {
            guestMap.tap()
            Thread.sleep(forTimeInterval: 7)
            snap(app, "a5-carte-invite")
        }

        print("AUDIT_LOGGEDOUT_DONE")
    }

    // MARK: - Écrans secondaires (session réelle)

    func testSecondaryScreensTour() throws {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty { app.launchArguments += ["--mock-auth"] }
        else { app.launchEnvironment["SQ_AUTH_TOKEN"] = token }
        app.launchArguments += ["--reset-map"]
        app.launch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        XCTAssertTrue(SignalQuestUITestSupport.tab(named: "Accueil", in: app).waitForExistence(timeout: 25))

        // Centre de notifications (cloche de l'Accueil).
        if tapIfExists(app.buttons["Notifications"], in: app) {
            Thread.sleep(forTimeInterval: 3)
            snap(app, "b1-notifications")
            back(app)
        }

        // Écrans poussés depuis le menu Profil.
        let profileRows: [(String, String)] = [
            ("Réglages", "b2-reglages"),
            ("Récompenses", "b3-recompenses"),
            ("Abonnements", "b4-abonnements"),
            ("Amis", "b5-amis"),
            ("Photos", "b6-photos"),
            ("Mes mesures", "b7-mes-mesures"),
            ("Confidentialité", "b8-confidentialite")
        ]
        for (row, shot) in profileRows {
            gotoTab("Profil", in: app)
            // Remonte en haut du scroll (un back() peut laisser l'écran scrollé
            // en bas, et scrollToHittable ne swipe que vers le bas).
            app.swipeDown(); app.swipeDown()
            Thread.sleep(forTimeInterval: 0.5)
            let element = app.staticTexts[row].firstMatch
            if SignalQuestUITestSupport.scrollToHittable(element, in: app) {
                element.tap()
                Thread.sleep(forTimeInterval: 3)
                snap(app, shot)
                back(app)
            }
        }

        // Éditer le profil (sheet).
        gotoTab("Profil", in: app)
        if tapIfExists(app.buttons["Éditer le profil"], in: app) {
            Thread.sleep(forTimeInterval: 2)
            snap(app, "b9-editer-profil")
            dismissSheet(app)
        }

        // Communauté : explore + composer.
        gotoTab("Communauté", in: app)
        if tapIfExists(app.buttons["Explorer"], in: app) {
            Thread.sleep(forTimeInterval: 3)
            snap(app, "c1-explore")
            back(app)
        }
        gotoTab("Communauté", in: app)
        if tapIfExists(app.buttons["Composer"], in: app) || tapIfExists(app.buttons["Publier"], in: app) {
            Thread.sleep(forTimeInterval: 2)
            snap(app, "c2-composer")
            dismissSheet(app)
        }

        // Tester : Drive Test (bouton d'en-tête gauche).
        gotoTab("Tester", in: app)
        if tapIfExists(app.buttons["Drive Test"], in: app) {
            Thread.sleep(forTimeInterval: 4)
            snap(app, "c3-drive-test")
            tapIfExists(app.buttons["Fermer"], in: app)
            back(app)
        }

        print("AUDIT_SECONDARY_DONE")
    }

    // MARK: - Zoom : activité de la page Récompenses (scroll profond)

    func testRecompensesActivite() throws {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty { app.launchArguments += ["--mock-auth"] }
        else { app.launchEnvironment["SQ_AUTH_TOKEN"] = token }
        app.launch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        XCTAssertTrue(SignalQuestUITestSupport.tab(named: "Profil", in: app).waitForExistence(timeout: 25))
        gotoTab("Profil", in: app)
        app.swipeDown()
        let row = app.staticTexts["Récompenses"].firstMatch
        if SignalQuestUITestSupport.scrollToHittable(row, in: app) {
            row.tap()
            Thread.sleep(forTimeInterval: 4)
            // Descend jusqu'à la section Activité.
            for _ in 0..<5 { app.swipeUp() }
            Thread.sleep(forTimeInterval: 2)
            snap(app, "d1-recompenses-activite")
        }
        print("RECOMPENSES_ACTIVITE_DONE")
    }

    // MARK: - Helpers

    private func gotoTab(_ name: String, in app: XCUIApplication) {
        let btn = SignalQuestUITestSupport.tab(named: name, in: app)
        if btn.waitForExistence(timeout: 6) { btn.tap() }
        Thread.sleep(forTimeInterval: 1.5)
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 4), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func firstExisting(_ elements: [XCUIElement]) -> XCUIElement? {
        for e in elements where e.waitForExistence(timeout: 2) { return e }
        return nil
    }

    /// Retour : bouton custom « Retour », sinon bouton nav système, sinon swipe.
    private func back(_ app: XCUIApplication) {
        let custom = app.buttons["Retour"].firstMatch
        if custom.exists, custom.isHittable { custom.tap() }
        else if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        if app.buttons["Annuler"].exists { app.buttons["Annuler"].tap() }
        else if app.buttons["Fermer"].exists { app.buttons["Fermer"].tap() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
