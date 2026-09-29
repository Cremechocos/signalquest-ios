import XCTest

/// Tour visuel de l'audit 2 : photographie les écrans accessibles en mode démo
/// (`--mock-auth --qa-demo-friends`), sans compte ni réseau réel.
///
/// L'apparence (clair/sombre) et la taille du texte se règlent sur le
/// simulateur (`simctl ui … appearance|content_size`) avant le lancement ; le
/// mode OLED passe par son argument. Chaque étape est défensive : un élément
/// absent est journalisé (`SQ_AUDIT2 MANQUANT …`) et le tour continue, pour
/// qu'un écran cassé n'empêche pas de photographier les suivants.
///
/// Les captures sont nommées `<préfixe>-<nn>-<écran>` : `xcresulttool export
/// attachments` les restitue avec ce nom dans `manifest.json`.
///
/// Long (plusieurs minutes par langue) : ne tourne que sur demande, avec
/// `TEST_RUNNER_SQ_AUDIT2_TOUR=1`, comme les autres tours ; sinon il est
/// signalé « ignoré » dans la suite complète.
@MainActor
final class Audit2TourQATests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SQ_AUDIT2_TOUR"] == "1",
                          "Tour audit 2 : TEST_RUNNER_SQ_AUDIT2_TOUR=1 requis")
        continueAfterFailure = true
    }

    func testTourFrench() { runTour(locale: "fr", prefix: "fr") }

    func testTourEnglish() { runTour(locale: "en", prefix: "en") }

    func testTourFrenchOLED() { runTour(locale: "fr", prefix: "fr-oled", extra: ["-app_pure_black", "YES"]) }

    /// Écrans profonds ouverts directement par les crochets QA de lancement.
    func testDeepScreensFrench() { runDeepScreens(locale: "fr") }

    func testDeepScreensEnglish() { runDeepScreens(locale: "en") }

    // MARK: - Parcours principal

    private func runTour(locale: String, prefix: String, extra: [String] = []) {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(
            app,
            arguments: ["--mock-auth", "--qa-demo-friends", "--qa-demo-photos", "--reset-map"] + extra,
            locale: locale
        )
        dismissSystemAlerts()
        let fr = locale == "fr"
        func t(_ french: String, _ english: String) -> String { fr ? french : english }
        var step = 0
        func snap(_ name: String) {
            step += 1
            capture(app, String(format: "%@-%02d-%@", prefix, step, name))
        }

        // Accueil
        XCTAssertTrue(
            SignalQuestUITestSupport.tab(named: t("Accueil", "Home"), in: app).waitForExistence(timeout: 25),
            "Onglet Accueil introuvable en \(locale)"
        )
        goTab(t("Accueil", "Home"), in: app)
        pause(3)
        snap("accueil")
        app.swipeUp()
        pause(1)
        snap("accueil-bas")
        app.swipeDown(); app.swipeDown()
        if tapIfExists(app.buttons["Notifications"].firstMatch, in: app) {
            pause(3)
            snap("notifications")
            back(app)
        }

        // Carte
        goTab(t("Carte", "Map"), in: app)
        pause(6)
        snap("carte")
        if tapIfExists(identified("map.filters", in: app), in: app) {
            pause(2)
            snap("carte-filtres")
            app.swipeUp()
            pause(1)
            snap("carte-filtres-bas")
            dismissSheet(app)
        }
        if tapIfExists(identified("map.operator", in: app), in: app) {
            pause(1.5)
            snap("carte-operateur")
            dismissMenu(app)
        }
        if tapIfExists(identified("map.coverage.legend", in: app), in: app) {
            pause(1.5)
            snap("carte-legende")
            dismissMenu(app)
        }
        // La recherche ouvre le clavier, qui masque la barre d'onglets : on la
        // photographie en dernier sur cet écran et on referme le clavier.
        if tapIfExists(identified("map.search.input", in: app), in: app) {
            pause(1.5)
            snap("carte-recherche")
            dismissKeyboard(app)
        }

        // Tester
        goTab(t("Tester", "Test"), in: app)
        pause(3)
        snap("tester")
        app.swipeUp()
        pause(1)
        snap("tester-bas")
        app.swipeDown(); app.swipeDown()
        if tapIfExists(identified("speedtest.settings", in: app), in: app) {
            pause(2)
            snap("tester-reglages")
            app.swipeUp()
            pause(1)
            snap("tester-reglages-bas")
            dismissSheet(app)
        }
        if tapIfExists(identified("speedtest.history", in: app), in: app) {
            pause(2)
            snap("tester-historique")
            back(app)
        }
        if tapIfExists(identified("speedtest.driveTest", in: app), in: app) {
            pause(4)
            snap("drivetest")
            if tapIfExists(app.buttons[t("Fermer", "Close")].firstMatch, in: app) {
                pause(1.5)
                snap("drivetest-apres-divulgation")
            }
            back(app)
        }

        // Communauté
        goTab(t("Communauté", "Community"), in: app)
        pause(4)
        snap("communaute")
        app.swipeUp()
        pause(1.5)
        snap("communaute-bas")
        app.swipeDown(); app.swipeDown()
        for tab in ["latest", "following", "friends", "telecom", "photos", "saved"] {
            if tapIfExists(identified("feed.tab.\(tab)", in: app), in: app) {
                pause(2.5)
                snap("fil-\(tab)")
            }
        }
        _ = tapIfExists(identified("feed.tab.forYou", in: app), in: app)
        pause(2)
        let firstPost = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.item.'"))
            .firstMatch
        if tapIfExists(firstPost, in: app) {
            pause(3)
            snap("publication-detail")
            back(app)
        }
        let firstStory = identified("feed.story.name", in: app)
        if tapIfExists(firstStory, in: app) {
            pause(2.5)
            snap("story")
            dismissSheet(app)
        }
        if tapIfExists(identified("community.header.action.explore", in: app), in: app) {
            pause(3)
            snap("explorer")
            back(app)
        }
        if tapIfExists(identified("community.header.action.publish", in: app), in: app) {
            pause(2)
            snap("composer")
            dismissSheet(app)
        }
        let menuItems: [(String, String, String)] = [
            ("Amis", "Friends", "amis"),
            ("Notifications", "Notifications", "notifications-communaute"),
            ("Appels", "Calls", "appels"),
            ("Ma semaine", "My week", "ma-semaine"),
            ("Préférences du fil", "Feed preferences", "preferences-fil")
        ]
        for (french, english, shot) in menuItems {
            goTab(t("Communauté", "Community"), in: app)
            guard tapIfExists(app.buttons[t("Plus", "More")].firstMatch, in: app) else {
                print("SQ_AUDIT2 MANQUANT menu Plus")
                break
            }
            pause(1)
            if tapIfExists(app.buttons[t(french, english)].firstMatch, in: app) {
                pause(3)
                snap(shot)
                dismissSheet(app)
                back(app)
            } else {
                dismissMenu(app)
            }
        }

        // Messages (données de démo : aucune conversation réelle)
        goTab(t("Communauté", "Community"), in: app)
        if tapIfExists(identified("community.header.action.messages", in: app), in: app) {
            pause(3)
            snap("messages")
            let conversation = app.cells.firstMatch
            if tapIfExists(conversation, in: app) {
                pause(3)
                snap("conversation")
                app.swipeDown()
                pause(1)
                snap("conversation-haut")
                back(app)
            }
            if tapIfExists(app.buttons[t("Nouvelle conversation", "New conversation")].firstMatch, in: app) {
                pause(2)
                snap("nouvelle-conversation")
                dismissSheet(app)
            }
            back(app)
        }

        // Profil
        goTab(t("Profil", "Profile"), in: app)
        pause(3)
        snap("profil")
        app.swipeUp()
        pause(1)
        snap("profil-milieu")
        app.swipeUp()
        pause(1)
        snap("profil-bas")
        for (french, english, shot) in [
            ("Récompenses", "Rewards", "recompenses"),
            ("Classements", "Leaderboards", "classements"),
            ("Territoires", "Territories", "territoires")
        ] {
            goTab(t("Profil", "Profile"), in: app)
            app.swipeDown(); app.swipeDown()
            let tile = firstExisting([
                identified("profile.progression.tile.\(french)", in: app),
                identified("profile.progression.tile.\(english)", in: app),
                app.buttons[t(french, english)].firstMatch
            ])
            if let tile, tapIfExists(tile, in: app) {
                pause(3)
                snap(shot)
                back(app)
            }
        }
        // Les titres du menu Profil ne sont pas localisés (TRX-06) : on cherche
        // le libellé français, puis l'anglais.
        let rows: [(String, String, String)] = [
            ("Mes enregistrements de trajet", "My trip recordings", "trajets"),
            ("Mes mesures", "My measurements", "mes-mesures"),
            ("Logs antennes", "Antenna logs", "logs-antennes"),
            ("Mes identifications", "My identifications", "identifications"),
            ("Mes signalements d'antenne", "My antenna reports", "signalements-antenne"),
            ("Pannes signalées", "Reported outages", "pannes"),
            ("Photos", "Photos", "photos"),
            ("Abonnements", "Subscriptions", "abonnements"),
            ("Confidentialité", "Privacy", "confidentialite"),
            ("Réglages", "Settings", "reglages")
        ]
        for (french, english, shot) in rows {
            goTab(t("Profil", "Profile"), in: app)
            app.swipeDown(); app.swipeDown()
            pause(0.5)
            let candidates = [app.staticTexts[french].firstMatch, app.staticTexts[english].firstMatch]
            guard let row = candidates.first(where: { $0.exists }) ?? scrollFind(candidates, in: app) else {
                print("SQ_AUDIT2 MANQUANT ligne \(french)")
                continue
            }
            guard SignalQuestUITestSupport.scrollToHittable(row, in: app) else { continue }
            row.tap()
            pause(3)
            snap(shot)
            if shot == "reglages" || shot == "confidentialite" || shot == "abonnements" {
                for index in 1...4 {
                    app.swipeUp()
                    pause(1)
                    snap("\(shot)-\(index)")
                }
            }
            back(app)
        }
        goTab(t("Profil", "Profile"), in: app)
        app.swipeDown(); app.swipeDown()
        if tapIfExists(app.buttons[t("Éditer le profil", "Edit profile")].firstMatch, in: app) {
            pause(2)
            snap("editer-profil")
            dismissSheet(app)
        }
        print("SQ_AUDIT2_DONE \(prefix) \(step) captures")
    }

    // MARK: - Écrans profonds (crochets QA)

    private func runDeepScreens(locale: String) {
        let hooks: [(String, [String])] = [
            ("fiche-antenne", ["--qa-open-antenna"]),
            ("anfr-carte", ["--qa-anfr-map"]),
            ("anfr-stats", ["--qa-anfr-stats"]),
            ("commentaires", ["--qa-comments"]),
            ("commentaires-reponses", ["--qa-comments-replies"]),
            ("photo", ["--qa-demo-photos", "--qa-open-photo"]),
            ("ami-carte", ["--qa-demo-friends", "--qa-open-friend"]),
            ("sentinelle-alertes", ["--qa-sentinelle-alerts"]),
            ("partage-speedtest", ["--qa-speedtest-share-preview"]),
            ("carte-couches", ["--qa-map-layers", "--start-map"])
        ]
        for (index, hook) in hooks.enumerated() {
            let app = XCUIApplication()
            SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map"] + hook.1, locale: locale)
            dismissSystemAlerts()
            pause(7)
            capture(app, String(format: "%@-deep-%02d-%@", locale, index + 1, hook.0))
            app.swipeUp()
            pause(1.5)
            capture(app, String(format: "%@-deep-%02d-%@-bas", locale, index + 1, hook.0))
            app.terminate()
        }
        print("SQ_AUDIT2_DEEP_DONE \(locale)")
    }

    // MARK: - Outils

    private func identified(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func goTab(_ name: String, in app: XCUIApplication) {
        dismissKeyboard(app)
        let tab = SignalQuestUITestSupport.tab(named: name, in: app)
        if tab.waitForExistence(timeout: 6) { tab.tap() } else { print("SQ_AUDIT2 MANQUANT onglet \(name)") }
        pause(1.5)
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 4) else {
            print("SQ_AUDIT2 MANQUANT \(element.debugDescription.prefix(120))")
            return false
        }
        guard element.isHittable || SignalQuestUITestSupport.scrollToHittable(element, in: app) else { return false }
        element.tap()
        return true
    }

    private func firstExisting(_ elements: [XCUIElement]) -> XCUIElement? {
        for element in elements where element.waitForExistence(timeout: 1.5) { return element }
        return nil
    }

    private func scrollFind(_ elements: [XCUIElement], in app: XCUIApplication) -> XCUIElement? {
        for _ in 0..<5 {
            if let hit = elements.first(where: { $0.exists }) { return hit }
            app.swipeUp()
        }
        return elements.first(where: { $0.exists })
    }

    /// Retour : bouton de navigation, sinon bouton « Retour/Back », sinon balayage.
    private func back(_ app: XCUIApplication) {
        let custom = [app.buttons["Retour"].firstMatch, app.buttons["Back"].firstMatch].first { $0.exists && $0.isHittable }
        if let custom {
            custom.tap()
        } else if app.navigationBars.buttons.firstMatch.exists, app.navigationBars.buttons.firstMatch.isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        pause(1.2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        let closers = ["Fermer", "Close", "Annuler", "Cancel", "OK", "Terminé", "Done"]
            .map { app.buttons[$0].firstMatch }
        if let closer = closers.first(where: { $0.exists && $0.isHittable }) {
            closer.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        pause(1.2)
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        pause(0.8)
    }

    /// Referme le clavier s'il est ouvert : touche d'action du clavier, sinon
    /// bouton Annuler, sinon retour chariot.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let labels = ["Rechercher", "Search", "search", "Retour", "Return", "return", "OK", "Terminé", "Done"]
        let key = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        let cancel = [app.buttons["Annuler"].firstMatch, app.buttons["Cancel"].firstMatch].first { $0.exists && $0.isHittable }
        if key.exists {
            key.tap()
        } else if let cancel {
            cancel.tap()
        } else {
            app.typeText("\n")
        }
        pause(1)
        if app.keyboards.count > 0 { app.swipeDown(); pause(0.5) }
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            var tapped = false
            for label in ["Autoriser une fois", "Allow Once", "Autoriser", "Allow", "Ne pas autoriser", "Don’t Allow", "Don't Allow", "Refuser"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 1.5) {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { return }
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SQ_AUDIT2 \(name)")
    }
}
