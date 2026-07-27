import XCTest

/// Parcourt l'app EN ANGLAIS et déverse tous les textes visibles.
///
/// Le compteur de clés traduites ne prouve rien : un libellé qui transite par un
/// paramètre `String` contourne le catalogue, et un littéral passé en argument
/// nommé n'y a même jamais été versé. Les deux se voient uniquement à l'écran.
///
/// Ce test ne juge pas — il RELÈVE. Le tri se fait ensuite hors de Xcode, en
/// croisant cette liste avec les clés françaises du catalogue : tout ce qui
/// matche est du français resté affiché. Automatiser le tri ici obligerait à
/// embarquer le catalogue dans la cible de test pour un gain nul.
@MainActor
final class UntranslatedSweepQATests: XCTestCase {

    private func dump(_ app: XCUIApplication, screen: String) {
        // `allElementsBoundByAccessibilityElement` sur staticTexts capture aussi
        // les libellés hors-écran d'un ScrollView, ce qui élargit utilement le
        // relevé sans avoir à faire défiler.
        var seen = Set<String>()
        for element in app.staticTexts.allElementsBoundByAccessibilityElement {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label).inserted else { continue }
            print("SQ_TEXT\t\(screen)\t\(label)")
        }
        for element in app.buttons.allElementsBoundByAccessibilityElement {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label).inserted else { continue }
            print("SQ_TEXT\t\(screen)\t\(label)")
        }
    }

    func testSweepEveryTabInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(
            app,
            arguments: [
                "--mock-auth", "--qa-demo-friends",
                // Force la langue du PROCESSUS app : c'est le seul moyen fiable
                // de la fixer, indépendamment des réglages du simulateur.
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
            ]
        )

        // Noms ANGLAIS : `SignalQuestUITestSupport.tabs` est en français et ne
        // retrouverait aucun onglet ici.
        for name in ["Home", "Map", "Test", "Community", "Profile"] {
            let tab = SignalQuestUITestSupport.tab(named: name, in: app)
            guard tab.waitForExistence(timeout: 20) else { continue }
            tab.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
            dump(app, screen: name)
        }

        // Réglages : le plus dense en libellés, et jamais atteint par les tours
        // existants.
        SignalQuestUITestSupport.tab(named: "Profile", in: app).tap()
        let settings = app.staticTexts["Settings"].firstMatch
        if settings.waitForExistence(timeout: 8) { settings.tap() }
        _ = app.switches.firstMatch.waitForExistence(timeout: 8)
        dump(app, screen: "Reglages")
    }
}
