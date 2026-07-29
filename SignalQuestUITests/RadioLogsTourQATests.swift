import XCTest

/// Tournée de captures de la page « Logs antennes ».
///
/// Auth : token réel via `SQ_AUTH_TOKEN` si fourni (la page prend alors tout son
/// sens — le journal du compte s'affiche vraiment), sinon mode démo, qui vérifie
/// au moins la navigation, l'état vide et l'absence de plantage.
@MainActor
final class RadioLogsTourQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testRadioLogsTour() throws {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty {
            app.launchArguments += ["--mock-auth"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        }
        app.sqLaunch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        // Demande système de notifications (SpringBoard), sinon elle masque tout.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }

        let profil = SignalQuestUITestSupport.tab(named: "Profil", in: app)
        XCTAssertTrue(profil.waitForExistence(timeout: 25), "dock absent")
        profil.tap()
        Thread.sleep(forTimeInterval: 3)

        let entry = app.staticTexts["Logs antennes"].firstMatch
        XCTAssertTrue(
            SignalQuestUITestSupport.scrollToHittable(entry, in: app),
            "L'entrée « Logs antennes » est absente du menu Profil"
        )
        entry.tap()

        // La page doit s'être ouverte, pas seulement le bouton avoir répondu.
        XCTAssertTrue(
            app.navigationBars["Logs antennes"].waitForExistence(timeout: 15),
            "La page Logs antennes ne s'est pas ouverte"
        )

        // Sur un vrai compte, le rattrapage porte sur des dizaines de milliers de
        // lignes : une pause fixe capturerait une page encore vide et ne prouverait
        // rien. On attend que le compteur cesse d'être à zéro, puis on laisse le
        // balayage poser quelques pastilles.
        let loaded = waitForSites(app, timeout: 120)
        Thread.sleep(forTimeInterval: loaded ? 12 : 4)
        snap(app, "logs-01-liste")
        // On n'exige des données qu'avec un vrai token. En mode démo, la page est
        // légitimement vide — et l'exiger vide serait tout aussi faux, puisqu'un
        // journal déjà synchronisé peut rester en cache sur le simulateur.
        if !token.isEmpty {
            XCTAssertTrue(loaded, "Aucun site n'est apparu après 120 s de rattrapage")
        }

        // Feuille « Trier et filtrer », via le menu de la barre.
        let more = app.buttons["Plus d'options"].firstMatch
        if more.waitForExistence(timeout: 5) {
            more.tap()
            Thread.sleep(forTimeInterval: 1)
            let sort = app.buttons["Trier et filtrer"].firstMatch
            if sort.waitForExistence(timeout: 4) {
                sort.tap()
                Thread.sleep(forTimeInterval: 2)
                snap(app, "logs-02-trier-filtrer")
                dismissSheet(app)
            } else {
                // Referme le menu s'il s'est ouvert sans l'entrée attendue.
                app.tap()
            }
        }

        // Le balayage doit avoir posé des pastilles avant qu'on capture les
        // filtres : sans ça, « Identifiés · 0 » ne prouve rien — ni que le
        // balayage marche, ni qu'il ne marche pas.
        let scanned = waitForScan(app, timeout: 180)
        if !token.isEmpty {
            XCTAssertTrue(scanned, "Le balayage n'a posé aucun statut après 180 s")
        }
        snap(app, "logs-02b-balayage")

        // Filtre « Non identifiés » : c'est la vue qui porte les actions.
        let unidentified = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Non identifiés'"))
            .firstMatch
        if unidentified.waitForExistence(timeout: 5) {
            unidentified.tap()
            Thread.sleep(forTimeInterval: 3)
            snap(app, "logs-03-non-identifies")
        }

        // La file d'identification, puis le choix libre sur la carte.
        //
        // On s'arrête AVANT toute confirmation : identifier écrirait dans la base
        // communautaire, ce qu'une tournée de captures n'a pas à faire.
        let chain = app.buttons
            .matching(NSPredicate(format: "label CONTAINS 'à la suite'"))
            .firstMatch
        if SignalQuestUITestSupport.scrollToHittable(chain, in: app) {
            chain.tap()
            Thread.sleep(forTimeInterval: 10)
            snap(app, "logs-04-file-identification")

            let mapChoice = app.buttons["Choisir une autre antenne sur la carte"].firstMatch
            if SignalQuestUITestSupport.scrollToHittable(mapChoice, in: app) {
                mapChoice.tap()
                XCTAssertTrue(
                    app.navigationBars["Choisir l'antenne"].waitForExistence(timeout: 20),
                    "Le choix d'antenne sur carte ne s'est pas ouvert"
                )
                Thread.sleep(forTimeInterval: 8)
                snap(app, "logs-05-choix-carte")
                app.buttons["Annuler"].firstMatch.tap()
                Thread.sleep(forTimeInterval: 1.5)
            } else if !token.isEmpty {
                XCTFail("Le bouton de choix sur carte est absent de la file")
            }
            app.buttons["Fermer"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }

        // Pas de capture en sombre ici : `XCUIDevice.shared.appearance` reste
        // sans effet sur ce runtime (les captures revenaient en clair), et un pas
        // de test qui n'atteste rien vaut moins que pas de pas du tout. Le sombre
        // se vérifie hors test, par `xcrun simctl ui <device> appearance dark`.
    }

    /// Attend que le catalogue cesse d'être vide.
    ///
    /// On observe la puce « Tous · N » du rail plutôt qu'un compteur de la page :
    /// c'est un bouton, donc un élément d'accessibilité stable, et son libellé
    /// porte le décompte du catalogue ENTIER.
    private func waitForSites(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let nonEmpty = NSPredicate(format: "label BEGINSWITH 'Tous · ' AND NOT (label ==[c] 'Tous · 0')")
        while Date() < deadline {
            if app.buttons.matching(nonEmpty).firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    /// Attend que le balayage ait classé au moins un site.
    ///
    /// On observe « Identifiés · N » ET « Non identifiés · N » : le balayage a
    /// commencé dès que l'un des deux quitte zéro. Attendre le seul « Identifiés »
    /// bloquerait sur un catalogue dont aucun site n'est encore rattaché — un
    /// résultat parfaitement légitime.
    private func waitForScan(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let classified = NSPredicate(
            format: "(label BEGINSWITH 'Identifiés · ' AND NOT (label ==[c] 'Identifiés · 0')) OR (label BEGINSWITH 'Non identifiés · ' AND NOT (label ==[c] 'Non identifiés · 0'))"
        )
        while Date() < deadline {
            if app.buttons.matching(classified).firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 3)
        }
        return false
    }

    /// Referme une feuille SwiftUI présentée en `.medium`.
    ///
    /// Deux pièges, tous deux rencontrés ici :
    /// - `app.sheets` ne correspond à RIEN pour une feuille SwiftUI (elle n'est
    ///   pas exposée comme `sheet` dans l'arbre d'accessibilité), donc partir de
    ///   `app.sheets.firstMatch` retombait sur la fenêtre entière et le geste
    ///   démarrait dans la barre de navigation, au-dessus de la feuille.
    /// - `swipeDown()` vise le centre de l'écran, c'est-à-dire le CORPS de la
    ///   feuille : le geste y défile le contenu au lieu de fermer.
    ///
    /// On tire donc depuis la poignée, un peu sous la mi-hauteur (une feuille
    /// `.medium` occupe la moitié basse), jusqu'en bas de l'écran.
    private func dismissSheet(_ app: XCUIApplication) {
        let window = app.windows.element(boundBy: 0)
        let grabber = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        grabber.press(forDuration: 0.1, thenDragTo: bottom)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
