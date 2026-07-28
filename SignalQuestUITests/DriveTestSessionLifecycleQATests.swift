import XCTest

/// Cycle de vie d'une session Drive Test.
///
/// Une session Drive Test dure un trajet entier. Elle doit survivre à tout ce que
/// l'utilisateur fait pendant ce trajet — et en particulier à un aller-retour vers
/// la carte pour regarder où il en est.
///
/// `DriveTestView.onDisappear` appelle `stop()` sans condition, et SwiftUI émet
/// `onDisappear` sur le contenu de l'onglet quittté. Ce test existe pour établir si
/// ce chemin se déclenche réellement au changement d'onglet, puis pour empêcher la
/// régression une fois corrigé.
@MainActor
final class DriveTestSessionLifecycleQATests: XCTestCase {

    private let stopLabel = "Arrêter le drive test"

    /// Dépose une capture + l'inventaire des boutons visibles. Sans cela, un échec
    /// dit seulement « bouton introuvable » sans dire ce qui était à l'écran.
    private func diagnose(_ app: XCUIApplication, _ moment: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "diag-\(moment)"
        shot.lifetime = .keepAlways
        add(shot)
        let labels = app.buttons.allElementsBoundByIndex.prefix(30).map { element in
            let identifier = element.identifier
            let label = element.label
            return identifier.isEmpty ? label : "\(identifier)|\(label)"
        }
        print("SQ_DIAG \(moment) boutons=\(labels)")
    }

    /// Ouvre le Drive Test depuis l'onglet Tester et démarre une session en mode
    /// « Couverture » — le seul mode qui ne lance aucun test de débit, donc le seul
    /// utilisable dans une suite automatisée.
    private func startCoverageSession(in app: XCUIApplication) throws {
        let speedTab = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speedTab.waitForExistence(timeout: 20), "Onglet Tester introuvable")
        speedTab.tap()

        let entry = app.buttons["Mode Drive Test"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Bouton « Mode Drive Test » introuvable")
        entry.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)

        // L'information « ce qu'un Drive Test partage » s'affiche une fois, avant
        // le premier trajet, et couvre l'écran. Elle est volontairement non
        // esquivable au geste : on la franchit par son bouton, comme l'utilisateur.
        let acknowledge = app.buttons["J'ai compris"].firstMatch
        if acknowledge.waitForExistence(timeout: 5) {
            acknowledge.tap()
            _ = acknowledge.waitForNonExistence(timeout: 5)
        }
        diagnose(app, "01-drivetest-ouvert")

        // Mode « Couverture » : enregistre la génération sans enchaîner de speedtests.
        let coverageMode = app.buttons["Couverture"].firstMatch
        if coverageMode.waitForExistence(timeout: 6) { coverageMode.tap() }

        let start = app.buttons["Démarrer l'enregistrement couverture"].firstMatch
        guard start.waitForExistence(timeout: 8) else {
            diagnose(app, "02-demarrage-introuvable")
            throw XCTSkip("Bouton de démarrage absent — mode Couverture non sélectionnable")
        }
        start.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 4)
        diagnose(app, "03-apres-demarrage")

        XCTAssertTrue(
            app.buttons[stopLabel].waitForExistence(timeout: 10),
            "La session n'a pas démarré : le bouton d'arrêt n'apparaît pas"
        )
    }

    /// Le scénario réel : je roule, je vais voir la carte, je reviens.
    func testSessionSurvivesTabSwitch() throws {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        try startCoverageSession(in: app)

        // Aller sur la carte, puis revenir à l'onglet Tester.
        let mapTab = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        XCTAssertTrue(mapTab.waitForExistence(timeout: 10), "Onglet Carte introuvable")
        mapTab.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)

        let speedTab = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speedTab.waitForExistence(timeout: 10), "Onglet Tester introuvable au retour")
        speedTab.tap()

        let stop = app.buttons[stopLabel].firstMatch
        XCTAssertTrue(
            stop.waitForExistence(timeout: 10),
            "La session Drive Test a été arrêtée par le changement d'onglet — "
            + "`onDisappear` appelle `stop()` alors que l'utilisateur n'a fait que consulter la carte."
        )

        // Ne pas laisser une session ouverte derrière soi.
        if stop.exists { stop.tap() }
    }

    /// Contrôle de référence : le bouton d'arrêt n'est pas un faux positif qui
    /// resterait affiché quoi qu'il arrive. Un arrêt explicite doit bien le faire
    /// disparaître.
    func testExplicitStopEndsSession() throws {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        try startCoverageSession(in: app)

        app.buttons[stopLabel].firstMatch.tap()
        XCTAssertTrue(
            app.buttons[stopLabel].firstMatch.waitForNonExistence(timeout: 8),
            "Le bouton d'arrêt reste affiché après un arrêt explicite"
        )
    }
}
