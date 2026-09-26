import XCTest

/// Parcours complet fil → commentaires avec API/PG PRE-02 synthétiques.
@MainActor
final class CommentsHTTPQATests: XCTestCase {
    private struct RecipeFixture: Decodable {
        let baseURL: URL
        let token: String
        let expectedUserID: String
    }
    private struct RecipeMarker: Decodable {
        let kind: String
        let database: String
        let ports: [String: Int]
    }

    func testRealCommentAndReplyPagesRecoverAfter503AndDelay() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette loopback uniquement sur simulateur")
        #endif
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        func input(_ name: String) -> String? { environment[name] ?? environment["TEST_RUNNER_\(name)"] }
        guard let fixturePath = input("SQ_RECIPE_FIXTURE"),
              let appPath = input("SQ_RECIPE_APP_BUNDLE_PATH"),
              let statePath = input("SQ_RECIPE_STATE") else {
            throw XCTSkip("Banc PRE-02 et binaire isolé requis")
        }
        let state = URL(fileURLWithPath: statePath, isDirectory: true).standardizedFileURL
        let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        let marker = try JSONDecoder().decode(RecipeMarker.self,
            from: Data(contentsOf: state.appendingPathComponent("recipe.json")))
        let fixture = try JSONDecoder().decode(RecipeFixture.self, from: Data(contentsOf: fixtureURL))
        let expectedURL = URL(string: "http://127.0.0.1:49141")!
        let bundle = try XCTUnwrap(Bundle(path: appPath))
        guard state.path.hasPrefix("/Users/alexandregermain/Site/qa/"),
              fixtureURL.deletingLastPathComponent() == state,
              marker.kind == "signalquest-ios-synthetic-v1", marker.database == "sq_ios_recipe_test",
              marker.ports["proxy"] == 49141, fixture.baseURL == expectedURL,
              fixture.expectedUserID == "ios_recipe_user_a",
              bundle.bundleIdentifier == "fr.signalquest.ios.beta",
              bundle.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String == expectedURL.absoluteString,
              bundle.object(forInfoDictionaryKey: "SQ_APP_BASE_URL") as? String == expectedURL.absoluteString else {
            XCTFail("Recette refusée hors backend et binaire synthétiques")
            return
        }
        let fault = state.appendingPathComponent("fault.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fault.path), "Une autre panne est active")
        defer { try? FileManager.default.removeItem(at: fault) }

        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: "fr")
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["SQ_AUTH_TOKEN"] = fixture.token
        app.sqLaunch(locale: "fr")
        defer { app.terminate() }
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 25))
        community.tap()
        let post = app.descendants(matching: .any)["feed.item.post-ios_recipe_post_0"].firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 25))
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(post, in: app))
        let commentAction = post.buttons["Commenter"].firstMatch
        XCTAssertTrue(commentAction.waitForExistence(timeout: 10))
        commentAction.tap()
        XCTAssertTrue(app.staticTexts["Commentaire synthétique 64"].waitForExistence(timeout: 15))
        capture(app, "comments-initial-50-real-api")

        let loadMore = app.buttons["comments.loadMore"]
        for _ in 0..<26 {
            if loadMore.exists && loadMore.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(loadMore.isHittable, "La suite des parents doit être accessible")
        let parentPath = "/api/social/posts/ios_recipe_post_0/comments"
        try setFault(["path": parentPath, "mode": "503"], at: fault)
        loadMore.tap()
        XCTAssertTrue(app.staticTexts["Impossible de charger les commentaires."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Commentaire synthétique 15"].exists,
                      "La page déjà chargée ne doit pas disparaître sur 503")
        try FileManager.default.removeItem(at: fault)
        loadMore.tap()
        let oldest = app.staticTexts["Commentaire synthétique 1"]
        for _ in 0..<14 {
            if oldest.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(oldest.isHittable, "Le 64e commentaire doit être atteignable après pagination")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Commentaire synthétique 2")).count, 1)
        capture(app, "comments-parent-64-after-retry")

        let author = app.buttons["comment.author.ios_recipe_comment_0"].firstMatch
        for _ in 0..<4 {
            if author.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(author.isHittable)
        author.tap()
        XCTAssertTrue(app.navigationBars["Recette b"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(oldest.waitForExistence(timeout: 10), "Le retour doit conserver la page 51+")

        let replies = app.buttons["comments.replies.ios_recipe_comment_0"].firstMatch
        for _ in 0..<4 {
            if replies.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(replies.isHittable)
        let replyPath = parentPath + "/ios_recipe_comment_0/replies"
        try setFault(["path": replyPath, "mode": "delay", "ms": 1500], at: fault)
        replies.tap()
        XCTAssertTrue(app.staticTexts["Réponse synthétique R129 1"].waitForExistence(timeout: 15))
        try FileManager.default.removeItem(at: fault)
        let moreReplies = app.buttons["comments.replies.loadMore.ios_recipe_comment_0"].firstMatch
        for _ in 0..<8 {
            if moreReplies.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(moreReplies.isHittable)
        moreReplies.tap()
        XCTAssertTrue(app.staticTexts["Réponse synthétique R129 21"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Réponse synthétique R129 20")).count, 1)
        capture(app, "comments-reply-21-real-api")
    }

    private func setFault(_ value: [String: Any], at url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: url, options: .atomic)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
