import XCTest

/// Tournée de vérification du redesign « Crème & Terre cuite » : parcourt les
/// écrans principaux (Accueil, Carte, Tester, Communauté, Messages,
/// Conversation, Profil, Classements) et attache une capture par écran, pour
/// comparaison avec les captures du prototype (design_handoff_creme_terracotta).
/// `testRedesignTour` reste un tour visuel en mode démo si aucun token n'est
/// fourni. `testRedesignTourRealAccount` est fail-fast : il exige que
/// `TEST_RUNNER_SQ_AUTH_TOKEN` soit transmis au runner sous `SQ_AUTH_TOKEN` et
/// qu'une conversation réelle soit effectivement ouverte.
@MainActor
final class RedesignTourQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testRedesignTour() {
        runTour(requireRealAccount: false)
    }

    func testRedesignTourRealAccount() {
        runTour(requireRealAccount: true)
    }

    private func runTour(requireRealAccount: Bool) {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        if requireRealAccount && token.isEmpty {
            XCTFail("QA compte réel : TEST_RUNNER_SQ_AUTH_TOKEN requis")
            return
        }
        if token.isEmpty {
            app.launchArguments += ["--mock-auth"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        }
        app.launchArguments += ["--reset-map"]
        app.sqLaunch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        // Ferme la demande système de notifications si présente (SpringBoard).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }

        XCTAssertTrue(SignalQuestUITestSupport.tab(named: "Accueil", in: app).waitForExistence(timeout: 25), "dock absent")
        Thread.sleep(forTimeInterval: 3)
        snap(app, "01-accueil")

        // Onglets du dock.
        tapTab("Carte", in: app); Thread.sleep(forTimeInterval: 8); snap(app, "04-carte")
        tapTab("Tester", in: app); Thread.sleep(forTimeInterval: 4); snap(app, "02-tester-pret")
        tapTab("Communauté", in: app); Thread.sleep(forTimeInterval: 5); snap(app, "05-communaute")
        tapTab("Profil", in: app); Thread.sleep(forTimeInterval: 3); snap(app, "07-profil")

        // Classements depuis le menu Profil.
        let classements = app.staticTexts["Classements"].firstMatch
        if SignalQuestUITestSupport.scrollToHittable(classements, in: app) {
            classements.tap()
            Thread.sleep(forTimeInterval: 4)
            snap(app, "08-classements")
            let back = app.buttons["Retour"].firstMatch
            if back.exists { back.tap() } else { app.swipeRight() }
            Thread.sleep(forTimeInterval: 1)
        }

        // Messages : liste puis 1re conversation.
        tapTab("Communauté", in: app)
        Thread.sleep(forTimeInterval: 2)
        let messages = app.buttons["Messages"].firstMatch
        let messagesExist = messages.waitForExistence(timeout: 6)
        if requireRealAccount {
            XCTAssertTrue(messagesExist, "Le bouton Messages doit être accessible avec le compte réel")
        }
        if messagesExist {
            messages.tap()
            Thread.sleep(forTimeInterval: 3)
            // Ferme la feuille de déverrouillage E2EE AVANT la capture (elle
            // s'ouvre par-dessus la liste quand la clé n'est pas en mémoire).
            for label in ["Annuler", "Fermer", "Plus tard"] {
                let b = app.buttons[label]
                if b.exists { b.tap(); Thread.sleep(forTimeInterval: 1); break }
            }
            Thread.sleep(forTimeInterval: 1)
            snap(app, "06-messages")
            // Ouvre la 1re conversation via son aperçu (rangées = boutons SwiftUI).
            let preview = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Publication SignalQuest' OR label CONTAINS 'Message chiffré'"))
                .firstMatch
            if preview.waitForExistence(timeout: 5) {
                preview.tap()
                Thread.sleep(forTimeInterval: 3)
                // Ferme un éventuel déverrouillage E2EE avant la capture.
                let cancel = app.buttons["Annuler"]
                if cancel.exists { cancel.tap(); Thread.sleep(forTimeInterval: 1) }
                snap(app, "09-conversation")
            } else if requireRealAccount {
                XCTFail("Aucune conversation réelle n'a été ouverte ; le tour ne doit pas valider des données démo")
            }
        }

        print("REDESIGN_TOUR_DONE")
    }

    private func tapTab(_ name: String, in app: XCUIApplication) {
        let btn = SignalQuestUITestSupport.tab(named: name, in: app)
        if btn.waitForExistence(timeout: 6) { btn.tap() }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
