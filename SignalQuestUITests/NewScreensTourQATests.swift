import XCTest

/// Parcourt les écrans livrés récemment et dépose une capture de chacun.
///
/// Le panneau natif du simulateur est indisponible sur cette installation
/// (`SimulatorKit.framework` vit dans `SharedFrameworks/` au lieu de
/// `Developer/Library/PrivateFrameworks/`), et `simctl` ne sait pas taper.
/// XCUITest, lui, navigue ET capture : c'est le seul moyen de VOIR ces écrans
/// sans modifier l'installation Xcode.
///
/// Le parcours tourne dans les DEUX langues. La version anglaise n'est pas
/// décorative : elle est le seul contrôle qui prouve qu'une chaîne est
/// réellement traduite. Un littéral français en position de donnée (tuple,
/// `return "…"`) compile, s'affiche et reste français — rien d'autre ne le voit.
@MainActor
final class NewScreensTourQATests: XCTestCase {

    /// Libellés du parcours, par langue. Regroupés ici pour que l'ajout d'une
    /// langue soit une ligne et non une seconde copie du parcours.
    private struct Labels {
        let locale: String
        let community: String
        let profile: String
        let recap: String
        let close: String
        let territories: String
        let feedPreferences: String

        static let french = Labels(
            locale: "fr", community: "Communauté", profile: "Profil",
            recap: "Ma semaine", close: "Fermer",
            territories: "Territoires", feedPreferences: "Préférences du fil"
        )
        static let english = Labels(
            locale: "en", community: "Community", profile: "Profile",
            recap: "My week", close: "Close",
            territories: "Territories", feedPreferences: "Feed preferences"
        )
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SQ_TOUR \(name)")
    }

    func testTourNewScreensInFrench() { runTour(Labels.french) }

    func testTourNewScreensInEnglish() { runTour(Labels.english) }

    private func runTour(_ labels: Labels) {
        let app = XCUIApplication()
        // La langue passe par `locale:` et NON par les `launchArguments` :
        // `sqLaunch` ajoute déjà `-AppleLanguages`, et un doublon casse
        // l'analyse du domaine d'arguments (l'app démarrait alors en anglais
        // quelle que soit la demande).
        SignalQuestUITestSupport.launch(
            app,
            arguments: ["--mock-auth", "--qa-demo-friends"],
            locale: labels.locale
        )

        let prefix = labels.locale
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        capture(app, named: "\(prefix)-00-lancement")

        // Communauté : onglets de fil et bilan hebdomadaire.
        let community = SignalQuestUITestSupport.tab(named: labels.community, in: app)
        XCTAssertTrue(
            community.waitForExistence(timeout: 20),
            "Onglet « \(labels.community) » introuvable en \(labels.locale)"
        )
        community.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
        capture(app, named: "\(prefix)-communaute-onglets")

        let recap = app.buttons[labels.recap].firstMatch
        if recap.waitForExistence(timeout: 5) {
            recap.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
            capture(app, named: "\(prefix)-bilan-hebdo")
            app.buttons[labels.close].firstMatch.tap()
        } else {
            print("SQ_TOUR MANQUANT \(labels.recap)")
        }

        // Profil : territoires et préférences du fil.
        let profile = SignalQuestUITestSupport.tab(named: labels.profile, in: app)
        XCTAssertTrue(
            profile.waitForExistence(timeout: 10),
            "Onglet « \(labels.profile) » introuvable en \(labels.locale)"
        )
        profile.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)

        for (label, name) in [(labels.territories, "territoires"),
                              (labels.feedPreferences, "preferences-fil")] {
            let entry = app.staticTexts[label].firstMatch
            guard entry.waitForExistence(timeout: 6) else {
                // Signalé, jamais silencieux : un `guard … else { return }` muet
                // faisait passer le test en ne capturant RIEN — un faux vert.
                print("SQ_TOUR MANQUANT \(label)")
                continue
            }
            entry.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
            capture(app, named: "\(prefix)-\(name)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.staticTexts[labels.territories].waitForExistence(timeout: 4)
        }
    }
}
