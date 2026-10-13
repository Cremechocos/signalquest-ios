import XCTest

/// Vérifie la réorganisation du menu Profil : chaque destination déplacée est
/// bien ATTEIGNABLE là où elle vit désormais, et n'est plus dans le Profil.
///
/// Un test de captures ne suffisait pas ici : déplacer une entrée sans casser
/// son accès est précisément ce qui peut rater en silence.
@MainActor
final class ProfileReorgQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testReorganisedNavigation() throws {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty {
            app.launchArguments += ["--mock-auth"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        }
        app.launchArguments += ["--reset-map"]
        app.sqLaunch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }
        XCTAssertTrue(
            SignalQuestUITestSupport.tab(named: "Accueil", in: app).waitForExistence(timeout: 25),
            "dock absent"
        )

        // ── Profil : allégé, et la progression remontée en tuiles ────────────
        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        Thread.sleep(forTimeInterval: 3)
        snap(app, "reorg-01-profil")

        // Territoires a quitté les tuiles pour « Mes contributions » (Lot 4g).
        for tile in ["Récompenses", "Classements"] {
            XCTAssertTrue(
                app.staticTexts[tile].firstMatch.waitForExistence(timeout: 5),
                "La tuile « \(tile) » manque sous l'en-tête du profil"
            )
        }
        for section in ["Suivis", "Contributions", "Avec l’app Android", "Compte"] {
            // Intertitres en capitales : comparaison sans la casse.
            let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", section)).firstMatch
            XCTAssertTrue(header.exists, "L'intertitre « \(section) » manque")
        }
        // Ce qui est parti ne doit plus être là : une entrée laissée en double
        // serait pire que pas de refonte du tout.
        for moved in ["Carte ANFR", "Statistiques ANFR", "Amis", "Appels", "Préférences du fil"] {
            XCTAssertFalse(
                app.staticTexts[moved].firstMatch.exists,
                "« \(moved) » est resté dans le menu Profil"
            )
        }

        // ── Carte : les deux écrans ANFR, dans la feuille Carte ──────────────
        // (plus de bouton permanent sur la carte).
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(SignalQuestUITestSupport.openMapANFRMenu(in: app), "Le Registre ANFR manque dans la feuille Carte")
        let anfrStats = app.buttons["map.filters.anfr.stats"].firstMatch
        XCTAssertTrue(anfrStats.waitForExistence(timeout: 10), "Le menu ANFR ne propose pas les statistiques")
        snap(app, "reorg-02-carte-filtres-anfr")
        XCTAssertTrue(app.buttons["map.filters.anfr.map"].firstMatch.exists)
        anfrStats.tap()
        // L'écran s'ouvre à la fermeture de la feuille Carte.
        XCTAssertTrue(app.staticTexts["Statistiques ANFR"].firstMatch.waitForExistence(timeout: 10),
                      "Les statistiques ANFR ne se sont pas ouvertes")
        Thread.sleep(forTimeInterval: 3)
        snap(app, "reorg-03-anfr-stats")
        back(app)

        // ── Communauté : le menu de débordement ──────────────────────────────
        SignalQuestUITestSupport.tab(named: "Communauté", in: app).tap()
        Thread.sleep(forTimeInterval: 4)
        let overflow = app.buttons["Plus"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Le menu « Plus » manque dans Communauté")
        overflow.tap()
        Thread.sleep(forTimeInterval: 1)
        snap(app, "reorg-04-communaute-menu")
        for entry in ["Amis", "Notifications", "Appels", "Ma semaine", "Préférences du fil"] {
            XCTAssertTrue(
                app.buttons[entry].firstMatch.waitForExistence(timeout: 4),
                "« \(entry) » manque au menu de Communauté"
            )
        }
        app.buttons["Amis"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        snap(app, "reorg-05-amis")
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() } else { app.swipeRight() }
        Thread.sleep(forTimeInterval: 2)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
