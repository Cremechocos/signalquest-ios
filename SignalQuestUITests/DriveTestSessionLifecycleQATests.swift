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

    /// Ouvre le Drive Test depuis l'onglet Tester et démarre un trajet. Au
    /// simulateur, la connexion est vue en Wi-Fi ou filaire : le trajet démarre
    /// en pause et aucun test de débit ne part, la suite reste hors réseau.
    private func startSession(in app: XCUIApplication) throws {
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

        let start = app.buttons["drivetest.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Bouton de démarrage introuvable")
        start.tap()

        // Localisation pas encore accordée : la vérification avant départ bloque
        // et propose « Autoriser », puis iOS pose sa question.
        let authorize = app.buttons["Autoriser"].firstMatch
        if authorize.waitForExistence(timeout: 4) {
            authorize.tap()
            allowLocation()
            XCTAssertTrue(start.waitForExistence(timeout: 8), "Retour au bouton de démarrage après l'autorisation")
            start.tap()
        }
        // Wi-Fi et position encore absente : des avertissements, pas un blocage.
        let anyway = app.buttons["Démarrer quand même"].firstMatch
        if anyway.waitForExistence(timeout: 5) { anyway.tap() }
        diagnose(app, "02-apres-demarrage")

        XCTAssertTrue(
            app.buttons[stopLabel].waitForExistence(timeout: 10),
            "Le trajet n'a pas démarré : le bouton d'arrêt n'apparaît pas"
        )
    }

    /// Accepte la question de localisation d'iOS, en français comme en anglais.
    private func allowLocation() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 6) else { return }
        let allow = alert.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'active' OR label CONTAINS[c] 'While Using' OR label CONTAINS[c] 'une fois' OR label CONTAINS[c] 'Once'"
        )).firstMatch
        if allow.exists { allow.tap() } else { alert.buttons.element(boundBy: 1).tap() }
        _ = alert.waitForNonExistence(timeout: 5)
    }

    /// Le scénario réel : je roule, je vais voir la carte, je reviens.
    func testSessionSurvivesTabSwitch() throws {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        try startSession(in: app)

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

    /// MES-10 : l'explication du Drive Test passe avant la demande système de
    /// localisation. Ni l'ouverture de l'écran ni la fermeture de l'explication
    /// ne la déclenchent : elle vient du préflight de « Démarrer ».
    func testExplanationComesBeforeLocationPrompt() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        SignalQuestUITestSupport.launch(app, arguments: [
            "--mock-auth", "-drivetest_speedtests_disclosure_seen_v2", "NO"
        ])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let speedTab = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speedTab.waitForExistence(timeout: 20), "Onglet Tester introuvable")
        speedTab.tap()
        let entry = app.buttons["Mode Drive Test"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Bouton « Mode Drive Test » introuvable")
        entry.tap()

        let acknowledge = app.buttons["J'ai compris"].firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 8), "L'explication du Drive Test n'apparaît pas")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "Demande de localisation affichée avant l'explication")
        acknowledge.tap()
        XCTAssertTrue(acknowledge.waitForNonExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "Demande de localisation affichée dès la fermeture de l'explication")
        diagnose(app, "mes10-apres-explication")
    }

    /// Contrôle de référence : le bouton d'arrêt n'est pas un faux positif qui
    /// resterait affiché quoi qu'il arrive. Un arrêt explicite doit bien le faire
    /// disparaître.
    func testExplicitStopEndsSession() throws {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        try startSession(in: app)

        app.buttons[stopLabel].firstMatch.tap()
        XCTAssertTrue(
            app.buttons[stopLabel].firstMatch.waitForNonExistence(timeout: 8),
            "Le bouton d'arrêt reste affiché après un arrêt explicite"
        )
    }
}
