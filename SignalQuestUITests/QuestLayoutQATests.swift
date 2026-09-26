import XCTest

@MainActor
final class QuestLayoutQATests: XCTestCase {
    func testSkeletonAndLoadedQuestFitTheViewport() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette réservée au service synthétique local")
        #endif
        let environment = ProcessInfo.processInfo.environment
        let recipe = environment["SQ_QUESTS_LAYOUT_QA"]
            ?? environment["TEST_RUNNER_SQ_QUESTS_LAYOUT_QA"]
        guard recipe == "loopback-8773-verified" else {
            throw XCTSkip("Compiler l’app Beta QA avec ses deux origines sur loopback:8773")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        let accessibilityXXL = environment["SQ_QUESTS_AX_XXL"] == "1"
            || environment["TEST_RUNNER_SQ_QUESTS_AX_XXL"] == "1"
        let arguments = accessibilityXXL
            ? ["--mock-auth", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
            : ["--mock-auth"]
        SignalQuestUITestSupport.launch(app, arguments: arguments, locale: "fr")
        defer { app.terminate() }

        let profile = SignalQuestUITestSupport.tab(named: "Profil", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        let rewards = app.descendants(matching: .any)["profile.progression.tile.Récompenses"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(rewards, in: app))
        rewards.tap()

        let skeleton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Quêtes, chargement en cours")).firstMatch
        XCTAssertTrue(skeleton.waitForExistence(timeout: 5), "Squelette Quêtes non visible pendant la réponse retardée")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(skeleton, in: app))
        capture(app, "quests-skeleton")
        XCTAssertGreaterThanOrEqual(skeleton.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(skeleton.frame.maxX, app.frame.maxX + 1)

        let firstQuest = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Premier trajet")).firstMatch
        XCTAssertTrue(firstQuest.waitForExistence(timeout: 15), "Quête chargée absente")
        XCTAssertFalse(skeleton.exists, "Le squelette reste affiché après succès")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(firstQuest, in: app))
        XCTAssertGreaterThanOrEqual(firstQuest.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(firstQuest.frame.maxX, app.frame.maxX + 1)
        XCTAssertTrue(app.staticTexts["Quêtes"].exists)
        capture(app, "quests-loaded")
        if accessibilityXXL {
            app.swipeUp()
            capture(app, "quests-loaded-ax-full-text")
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
