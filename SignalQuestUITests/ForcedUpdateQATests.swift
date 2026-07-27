import XCTest

/// Vérifie de bout en bout le kill-switch de version, y compris l'appel réseau
/// réel à `/api/app/version-policy?platform=ios`.
///
/// À exécuter sur un binaire construit avec un `CURRENT_PROJECT_VERSION`
/// inférieur au `minVersionCode` servi par le backend :
///
///     xcodebuild build-for-testing … CURRENT_PROJECT_VERSION=0
///     SQ_EXPECT_FORCED_UPDATE=1 xcodebuild test-without-building …
///
/// Le test est skippé sans cette variable, parce qu'il ne peut pas passer sur un
/// binaire à jour — et c'est précisément ce que vérifie l'assertion inverse dans
/// la suite principale (l'écran ne doit jamais apparaître en usage normal).
@MainActor
final class ForcedUpdateQATests: XCTestCase {

    func testObsoleteBuildIsBlocked() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SQ_EXPECT_FORCED_UPDATE"] == "1",
            "Nécessite un binaire construit avec CURRENT_PROJECT_VERSION obsolète"
        )
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])

        let screen = app.descendants(matching: .any)["forcedUpdate.screen"].firstMatch
        XCTAssertTrue(
            screen.waitForExistence(timeout: 25),
            "Une version sous le minimum serveur doit afficher l'écran bloquant"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Kill-switch — mise à jour requise"
        shot.lifetime = .keepAlways
        add(shot)

        // Le blocage doit être TOTAL : la hiérarchie applicative n'est pas
        // seulement recouverte, elle n'est pas construite. Un simple `.overlay`
        // laissait le dock atteignable en dessous.
        for name in SignalQuestUITestSupport.tabs {
            XCTAssertFalse(app.tabBars.buttons[name].exists, "L'onglet \(name) ne doit plus exister")
            XCTAssertFalse(app.buttons[name].firstMatch.exists, "Aucun bouton \(name) ne doit subsister")
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["home.action.speedtest"].firstMatch.exists,
            "Le contenu de l'Accueil ne doit pas être construit"
        )
    }

    /// Contrôle inverse : sur un binaire à jour, l'écran ne doit JAMAIS
    /// apparaître. C'est le risque principal de cette fonctionnalité.
    func testCurrentBuildIsNotBlocked() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SQ_EXPECT_FORCED_UPDATE"] == "1",
            "Le binaire est volontairement obsolète : c'est l'autre test qui s'applique"
        )
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"])
        XCTAssertTrue(
            SignalQuestUITestSupport.tab(named: "Accueil", in: app).waitForExistence(timeout: 20),
            "L'app doit démarrer normalement"
        )
        // Laisse le temps à l'appel réseau de revenir avant de conclure.
        _ = app.descendants(matching: .any)["forcedUpdate.screen"].firstMatch.waitForExistence(timeout: 8)
        XCTAssertFalse(
            app.descendants(matching: .any)["forcedUpdate.screen"].firstMatch.exists,
            "Un binaire à jour ne doit jamais être bloqué"
        )
    }
}
