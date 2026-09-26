import Foundation
import XCTest

/// Recette UI/API sur PRE-02 uniquement : compte, notifications et panne synthétiques.
@MainActor
final class NotificationsHTTPQATests: XCTestCase {
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
    private struct Notice: Decodable {
        let id: String
        let title: String?
        let read: Bool
    }
    private struct Page: Decodable {
        let notifications: [Notice]
        let nextCursor: String?
        let unreadCount: Int
    }

    func testAuthenticatedActivityPagesRetryBadgeAndRelaunchFRAndEN() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette loopback uniquement sur simulateur")
        #endif
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        func input(_ name: String) -> String? { environment[name] ?? environment["TEST_RUNNER_\(name)"] }
        guard let statePath = input("SQ_RECIPE_STATE"),
              let fixturePath = input("SQ_RECIPE_FIXTURE"),
              let appPath = input("SQ_RECIPE_APP_BUNDLE_PATH") else {
            throw XCTSkip("Banc PRE-02 et binaire Beta isolé requis")
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
              marker.kind == "signalquest-ios-synthetic-v1",
              marker.database == "sq_ios_recipe_test",
              marker.ports["proxy"] == 49141,
              fixture.baseURL == expectedURL,
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

        let first = try await page(cursor: nil, fixture: fixture)
        let second = try await page(cursor: try XCTUnwrap(first.nextCursor), fixture: fixture)
        XCTAssertEqual(first.notifications.count, 50)
        XCTAssertEqual(second.notifications.count, 14)
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(Set((first.notifications + second.notifications).map(\.id)).count, 64)
        let newest = try XCTUnwrap(first.notifications.first?.title)
        let oldest = try XCTUnwrap(second.notifications.last?.title)
        let unread = try XCTUnwrap(first.notifications.first(where: { !$0.read }))
        let unreadTitle = try XCTUnwrap(unread.title)
        let unreadBefore = first.unreadCount

        let reset = XCUIApplication()
        reset.launchArguments = ["--reset-auth", "--reset-onboarding"]
        reset.sqLaunch(locale: "fr")
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: reset)
        reset.terminate()

        var app = launchAuthenticated(fixture: fixture, locale: "fr")
        openActivity(in: app)
        XCTAssertTrue(app.staticTexts[newest].waitForExistence(timeout: 20))
        capture(app, "activity-first-page-fr")

        let more = app.buttons["notifications.loadMore"]
        scroll(upTo: more, in: app, direction: .up, limit: 35)
        XCTAssertEqual(more.label, "Charger la suite")
        try Data(#"{"path":"/api/notifications","mode":"503"}"#.utf8).write(to: fault, options: .atomic)
        more.tap()
        XCTAssertTrue(app.staticTexts["Chargement impossible"].waitForExistence(timeout: 15))
        XCTAssertEqual(more.label, "Réessayer")
        XCTAssertTrue(app.staticTexts["Recette 15"].exists)
        capture(app, "activity-page-error-fr")

        try FileManager.default.removeItem(at: fault)
        more.tap()
        let oldestRow = app.staticTexts[oldest]
        scroll(upTo: oldestRow, in: app, direction: .up, limit: 12)
        capture(app, "activity-page-64-fr")

        let unreadRow = app.staticTexts[unreadTitle]
        scroll(upTo: unreadRow, in: app, direction: .down, limit: 40)
        capture(app, "activity-unread-before-fr")
        unreadRow.tap()
        let unreadAfter = try await waitForUnread(unreadBefore - 1, fixture: fixture)
        XCTAssertEqual(unreadAfter, unreadBefore - 1)
        capture(app, "activity-read-after-fr")
        app.terminate()

        app = launchAuthenticated(fixture: fixture, locale: "fr")
        openActivity(in: app)
        XCTAssertTrue(app.staticTexts[unreadTitle].waitForExistence(timeout: 20))
        let relaunchedUnread = try await page(cursor: nil, fixture: fixture).unreadCount
        XCTAssertEqual(relaunchedUnread, unreadAfter)
        capture(app, "activity-read-relaunch-fr")
        app.terminate()

        app = launchAuthenticated(fixture: fixture, locale: "en")
        openActivity(in: app)
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts[newest].exists)
        let moreEN = app.buttons["notifications.loadMore"]
        scroll(upTo: moreEN, in: app, direction: .up, limit: 35)
        XCTAssertEqual(moreEN.label, "Load more")
        capture(app, "activity-first-page-en")
        app.terminate()
    }

    private func page(cursor: String?, fixture: RecipeFixture) async throws -> Page {
        var components = URLComponents(url: fixture.baseURL.appendingPathComponent("api/notifications"),
                                       resolvingAgainstBaseURL: false)!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var request = URLRequest(url: components.url!)
        request.setValue("auth_token=\(fixture.token)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Page.self, from: data)
    }

    private func waitForUnread(_ expected: Int, fixture: RecipeFixture) async throws -> Int {
        for _ in 0..<25 {
            let count = try await page(cursor: nil, fixture: fixture).unreadCount
            if count == expected { return count }
            try await Task.sleep(for: .milliseconds(200))
        }
        return try await page(cursor: nil, fixture: fixture).unreadCount
    }

    private func launchAuthenticated(fixture: RecipeFixture, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = fixture.token
        app.sqLaunch(locale: locale)
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        return app
    }

    private func openActivity(in app: XCUIApplication) {
        let bell = app.buttons["Notifications"]
        XCTAssertTrue(bell.waitForExistence(timeout: 25))
        bell.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 20))
    }

    private enum ScrollDirection { case up, down }
    private func scroll(upTo element: XCUIElement, in app: XCUIApplication,
                        direction: ScrollDirection, limit: Int) {
        for _ in 0..<limit {
            if element.exists && element.isHittable { break }
            if direction == .up { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable, "L'élément doit rester atteignable")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
