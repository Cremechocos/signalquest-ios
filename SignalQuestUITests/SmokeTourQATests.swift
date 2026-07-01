import XCTest

/// Tournée de « smoke test » visuel en mode démo (`--mock-auth`, aucune auth réseau) :
/// parcourt chaque onglet + ouvre une conversation, et attache une capture par page
/// (extraites du .xcresult). Détecte crash / page blanche / layout cassé après les
/// optimisations de perf. N'exige aucun token.
@MainActor
final class SmokeTourQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testSmokeTour() throws {
        let app = XCUIApplication()
        // Si un token est fourni (appareil réel, Keychain fonctionnel) → VRAIES données ;
        // sinon mode démo (`--mock-auth`) pour le simulateur.
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if token.isEmpty {
            app.launchArguments += ["--mock-auth"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        }
        app.launchArguments += ["--reset-map"]
        app.launch()

        // Ferme la demande système de notifications si présente (elle est sur SpringBoard).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }

        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 25), "tab bar absente")
        snap(app, "01-Feed")

        for (name, wait) in [("Carte", 8.0), ("Speed", 4.0), ("Profil", 4.0)] {
            let btn = app.tabBars.buttons[name]
            if btn.waitForExistence(timeout: 6) { btn.tap() }
            Thread.sleep(forTimeInterval: wait)
            snap(app, name)
        }

        // Messagerie : liste puis 1re conversation (teste le composer isolé du Lot E).
        if app.tabBars.buttons["Messages"].waitForExistence(timeout: 6) {
            app.tabBars.buttons["Messages"].tap()
            Thread.sleep(forTimeInterval: 3)
            snap(app, "05-Messages")
            for label in ["Fermer", "Annuler", "Plus tard"] {
                let b = app.buttons[label]
                if b.exists { b.tap(); Thread.sleep(forTimeInterval: 1); break }
            }
            // Les lignes de conversation sont des boutons/liens SwiftUI, pas des `cells` :
            // on ouvre la conversation non chiffrée « SignalQuest iOS » par son libellé.
            let convo = app.staticTexts["SignalQuest iOS"].firstMatch
            if convo.waitForExistence(timeout: 5) {
                convo.tap()
                Thread.sleep(forTimeInterval: 3)
                snap(app, "06-Conversation")
                // Tape dans le composer pour vérifier qu'il ne fige/casse pas la liste.
                let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
                if field.waitForExistence(timeout: 3) {
                    field.tap()
                    field.typeText("Test perf composer")
                    Thread.sleep(forTimeInterval: 1)
                    snap(app, "07-Composer-saisie")
                }
            }
        }
        print("SMOKE_TOUR_DONE")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
