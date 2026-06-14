import XCTest

/// Tournée d'audit visuel + test du changement automatique de marché.
/// Nécessite TEST_RUNNER_SQ_AUTH_TOKEN. Phases via TEST_RUNNER_SQ_TOUR :
///  - "tabs"  : visite chaque onglet avec une pause (captures externes via
///    `simctl io screenshot` calées sur les marqueurs TOUR_AT imprimés).
///  - "market" : sur la carte, glisse la vue vers la Belgique et vérifie que
///    le marché bascule automatiquement sans recentrage.
@MainActor
final class AuditTourQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAuditTour() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        let tour = ProcessInfo.processInfo.environment["SQ_TOUR"] ?? ""
        try XCTSkipUnless(!token.isEmpty && !tour.isEmpty, "QA tour: variables d'env manquantes")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        if tour == "market" {
            // Repart de France (efface la région mémorisée), puis pan simulé
            // vers Bruxelles (zoom ~7) par le hook QA.
            app.launchArguments += ["--reset-map"]
            app.launchEnvironment["SQ_QA_PAN_TO"] = "50.85,4.35,7"
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 20))

        if tour == "tabs" {
            // Profil avant Messages : le sheet E2EE auto-présenté sur Messages
            // recouvrirait les onglets suivants.
            for (name, pause) in [("Feed", 5.0), ("Carte", 8.0), ("Speed", 5.0), ("Profil", 5.0), ("Messages", 6.0)] {
                app.tabBars.buttons[name].tap()
                print("TOUR_AT \(name)")
                Thread.sleep(forTimeInterval: pause)
            }
            print("TOUR_DONE")
            return
        }

        // tour == "market" : la caméra est déplacée sur Bruxelles par le hook
        // QA SQ_QA_PAN_TO (lancé via launchEnvironment) — fin de pan simulée,
        // la chaîne onMoveEnd → détection → switch est réelle.
        app.tabBars.buttons["Carte"].tap()
        // Le sélecteur de marché est un Button (libellé pays en MAJUSCULES) : on
        // cherche le marché sur n'importe quel élément, insensible à la casse.
        XCTAssertTrue(marketElement(app, "France").waitForExistence(timeout: 20), "Marché initial France attendu")
        print("TOUR_MARKET_START")

        // Le hook part 4 s après le chargement ; debounce 600 ms + confirmation
        // 700 ms ensuite.
        if marketElement(app, "Belgique").waitForExistence(timeout: 25) {
            print("TOUR_MARKET_OK Belgique")
        } else {
            let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(60).map { $0.label }.filter { !$0.isEmpty }.joined(separator: " | ")
            print("TOUR_MARKET_LABELS: \(labels)")
            XCTFail("Le marché n'a pas basculé sur Belgique après le pan")
        }
        Thread.sleep(forTimeInterval: 2)
    }

    /// Cherche un marché (par nom) sur tout élément (Button du sélecteur, toast,
    /// feuille de filtres), insensible à la casse — le libellé pays est en MAJ.
    private func marketElement(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", name))
            .firstMatch
    }
}
