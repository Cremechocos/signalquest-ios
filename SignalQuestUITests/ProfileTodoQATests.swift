import XCTest

/// « À faire » du Profil (plan 3, vague 2), sur l'aperçu de démonstration :
/// deux missions à réclamer et une photo en cours de vérification.
@MainActor
final class ProfileTodoQATests: XCTestCase {
    func testTodosLeadToWhereTheyAreSettled() {
        run(locale: "fr", profile: "Profil", missions: "Missions à réclamer : 2 (+150 pts)", rewards: "Récompenses")
    }

    func testEnglishTodosLeadToWhereTheyAreSettled() {
        run(locale: "en", profile: "Profile", missions: "Missions to claim: 2 (+150 pts)", rewards: "Rewards")
    }

    private func run(locale: String, profile: String, missions: String, rewards: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let profileTab = SignalQuestUITestSupport.tab(named: profile, in: app)
        XCTAssertTrue(profileTab.waitForExistence(timeout: 20))
        profileTab.tap()

        let missionsLink = app.buttons["profile.todo.missions"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(missionsLink, in: app), "Ligne des missions absente")
        XCTAssertTrue(app.staticTexts[missions].exists, "Libellé attendu : \(missions)")
        XCTAssertTrue(app.buttons["profile.todo.photos"].exists, "Photo en cours de vérification absente")
        XCTAssertFalse(app.buttons["profile.todo.identifications"].exists, "Aucun conflit dans la démo")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "profile-todo-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        missionsLink.tap()
        XCTAssertTrue(app.navigationBars[rewards].waitForExistence(timeout: 10), "Les missions s'ouvrent dans Récompenses")
    }
}
