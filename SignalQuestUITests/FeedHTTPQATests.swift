import XCTest

@MainActor
final class FeedHTTPQATests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:8772")!

    func testDelayedTabsHashtagsReturnAndSSEReconnectKeepTheCurrentFeed() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The loopback feed UI recipe requires its dedicated simulator")
        #endif
        guard ProcessInfo.processInfo.environment["SQ_FEED_HTTP_QA"] == "loopback-8772-verified",
              let token = ProcessInfo.processInfo.environment["SQ_FEED_UI_TOKEN"] else {
            throw XCTSkip("Requires the isolated feed recipe and verified compiled URLs")
        }
        continueAfterFailure = false
        try await control(["reset": true])
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: "fr")
        XCTAssertTrue(app.buttons["login.continueGuest"].waitForExistence(timeout: 20))
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.sqLaunch(locale: "fr")
        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 30)); community.tap()
        try await waitEvent("received", key: "old")
        tap("feed.tab.latest", in: app)
        XCTAssertTrue(card("recent", in: app).waitForExistence(timeout: 20))
        try await waitEvent("sent", key: "old")
        XCTAssertFalse(card("old", in: app).exists)

        tap("feed.hashtag.alpha", in: app)
        try await waitEvent("received", key: "alpha")
        tap("feed.hashtag.beta", in: app)
        XCTAssertTrue(card("beta", in: app).waitForExistence(timeout: 20))
        try await waitEvent("sent", key: "alpha")
        XCTAssertFalse(card("alpha", in: app).exists)
        capture(app, "feed-current-beta-after-late-alpha")

        let current = card("beta", in: app)
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(current, in: app))
        current.tap()
        let close = app.buttons["Fermer"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(card("beta", in: app).waitForExistence(timeout: 15))
        let before = try await state().connections
        try await control(["live": true, "disconnect": true])
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < end {
            if try await state().connections > before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = try await state().connections
        XCTAssertGreaterThan(after, before, "The real HTTP stream must reconnect")
        XCTAssertTrue(app.buttons["feed.pending"].waitForExistence(timeout: 20))
        XCTAssertFalse(card("new", in: app).exists, "Live posts must not move the current reading")
        tap("feed.pending", in: app)
        XCTAssertTrue(card("new", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["feed.pending"].exists)
        XCTAssertFalse(card("alpha", in: app).exists)
        capture(app, "feed-beta-after-explicit-live-refresh")
    }

    private func card(_ key: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["feed.item.qa-feed-" + key].firstMatch
    }
    private func tap(_ id: String, in app: XCUIApplication) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        for _ in 0..<6 where !button.isHittable { app.swipeDown() }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private struct Event: Decodable { let kind: String; let key: String }
    private struct State: Decodable { let connections: Int; let events: [Event] }
    private func state() async throws -> State {
        let (data, response) = try await URLSession.shared.data(from: origin.appendingPathComponent("__qa/feed/state"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(State.self, from: data)
    }
    private func control(_ command: [String: Bool]) async throws {
        var request = URLRequest(url: origin.appendingPathComponent("__qa/feed/control"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(command)
        request.setValue("feed-runtime-v1", forHTTPHeaderField: "X-SQ-QA")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func waitEvent(_ kind: String, key: String) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < end {
            if try await state().events.contains(where: { $0.kind == kind && $0.key == key }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Missing fixture event: \(kind)/\(key)")
    }
}
