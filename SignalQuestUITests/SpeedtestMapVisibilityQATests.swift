import XCTest

/// Uses a real synthetic account, real API/SQL, a seeded local history and MapKit.
/// This proves the visibility journey, not collection or throughput measurement.
@MainActor
final class SpeedtestMapVisibilityQATests: XCTestCase {
    func testOwnerHideRemovesRenderedPointEvenWhenTheNextTilesFail() async throws {
        let fixture = try Fixture.load()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        defer { app.terminate() }
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-map", "--reset-onboarding", "--qa-map-layers"],
            environment: ["SQ_AUTH_TOKEN": fixture.profile.token,
                "SQ_MAP_VIEWPORT_QA": "1",
                "SQ_QA_PAN_TO": "\(fixture.coordinate.latitude),\(fixture.coordinate.longitude),17",
                "SQ_QA_SPEEDTEST_AUTORUN": "0", "SQ_QA_SPEEDTEST_EXIT": "0"], locale: "fr")
        let mapTab = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        guard mapTab.waitForExistence(timeout: 30) else {
            capture(app, "map-mask-auth-not-ready")
            return XCTFail("The real synthetic account must reach the app shell")
        }
        mapTab.tap()
        XCTAssertTrue(app.buttons["map.filters"].waitForExistence(timeout: 20))
        let operatorButton = app.buttons["map.operator"]
        if !operatorButton.label.hasSuffix(": SFR") {
            operatorButton.tap()
            let sfr = app.buttons.matching(NSPredicate(format: "label == %@", "SFR")).firstMatch
            XCTAssertTrue(sfr.waitForExistence(timeout: 10))
            sfr.tap()
        }
        let marker = app.buttons.matching(NSPredicate(format: "label == %@", "Mesure de débit 100 Mbps")).firstMatch
        let displayed = NSPredicate { _, _ in marker.exists && marker.isHittable }
        let appeared = await fulfillmentResult(displayed, timeout: 40)
        capture(app, "map-mask-before")
        XCTAssertTrue(appeared, "A visible measurement is required before testing its removal")
        let initial = try await fixture.state()
        XCTAssertTrue(initial.events.contains { $0.markerIDs.contains(fixture.serverID) })
        XCTAssertTrue(try XCTUnwrap(initial.measurements.first { $0.id == fixture.serverID }).isVisibleOnMap)

        // Freeze the next tile reads in a real HTTP failure, so a successful
        // refresh cannot conceal a stale point left in the rendered model.
        try await fixture.failTiles()
        let testTab = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(testTab.isHittable)
        testTab.tap()
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "100 Mbps")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(history, in: app))
        history.tap()
        XCTAssertTrue(app.navigationBars["Détails du test"].waitForExistence(timeout: 10))
        let hide = app.buttons["speedtest.visibility.hide"]
        for _ in 0..<12 {
            if hide.exists && hide.isHittable { break }
            app.swipeUp()
        }
        capture(app, "map-mask-owner-control")
        XCTAssertTrue(hide.isHittable)
        hide.tap()
        XCTAssertTrue(app.staticTexts["speedtest.visibility.confirmation"].waitForExistence(timeout: 20))
        capture(app, "map-mask-confirmed")
        let committed = try await fixture.state()
        XCTAssertFalse(try XCTUnwrap(committed.measurements.first { $0.id == fixture.serverID }).isVisibleOnMap)
        XCTAssertTrue(committed.events.contains { $0.method == "PATCH" && $0.status == 200 })
        app.navigationBars.buttons["Fermer"].firstMatch.tap()
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        XCTAssertTrue(app.buttons["map.filters"].waitForExistence(timeout: 10))
        let removed = NSPredicate { _, _ in !marker.exists }
        let disappeared = await fulfillmentResult(removed, timeout: 15)
        XCTAssertTrue(disappeared)
        XCTAssertTrue(app.buttons["map.status.retry"].waitForExistence(timeout: 40))
        capture(app, "map-mask-after-tile-failure")
        XCTAssertFalse(marker.exists)
        let final = try await fixture.state()
        XCTAssertTrue(final.events.contains { $0.path.contains("/tiles/speedtests/") && $0.status == 503 })
        XCTAssertFalse(try XCTUnwrap(final.measurements.first { $0.id == fixture.serverID }).isVisibleOnMap)
    }

    private func fulfillmentResult(_ predicate: NSPredicate, timeout: TimeInterval) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        return result == .completed
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-AX"; ax.lifetime = .keepAlways; add(ax)
    }

    private struct Fixture: Decodable {
        struct Profile: Decodable { let token: String; let email: String }
        struct Coordinate: Decodable { let latitude: Double; let longitude: Double }
        let baseURL: URL
        let controlKey: String
        let database: String
        let scenarioId: String
        let serverID: String
        let profile: Profile
        let coordinate: Coordinate
        static func load() throws -> Self {
            #if !targetEnvironment(simulator)
            throw XCTSkip("Dedicated simulator required")
            #endif
            let env = ProcessInfo.processInfo.environment
            func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
            guard value("SQ_MAP_MASK_UI") == "loopback-4321-verified" else { throw XCTSkip("Map masking UI recipe not requested") }
            guard let raw = value("SQ_MAP_MASK_FIXTURE_B64"), let data = Data(base64Encoded: raw), data.count < 8192,
                  let fixture = try? JSONDecoder().decode(Self.self, from: data),
                  fixture.baseURL.absoluteString == "http://127.0.0.1:4321",
                  fixture.database == "sq_speedtest_interop_20260912_test",
                  fixture.profile.email.hasPrefix("speedtest-interop-"), fixture.profile.email.hasSuffix("@local.test") else {
                throw RecipeError.invalidFixture
            }
            return fixture
        }
        struct State: Decodable {
            struct Row: Decodable { let id: String; let isVisibleOnMap: Bool }
            struct Event: Decodable { let path: String; let method: String; let status: Int; let markerIDs: [String] }
            let measurements: [Row]
            let events: [Event]
        }
        func state() async throws -> State {
            let data = try await request("state?scenarioId=" + scenarioId)
            return try JSONDecoder().decode(State.self, from: data)
        }
        func failTiles() async throws {
            _ = try await request("map-fault", body: ["scenarioId": scenarioId, "tileError": true])
        }
        private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
            var request = URLRequest(url: baseURL.appendingPathComponent("__qa/" + path.components(separatedBy: "?")[0]))
            if let query = path.components(separatedBy: "?").dropFirst().first {
                var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                components.percentEncodedQuery = query; request.url = components.url
            }
            request.timeoutInterval = 15
            request.setValue(controlKey, forHTTPHeaderField: "X-SQ-QA-Key")
            if let body {
                request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RecipeError.controlFailed }
            return data
        }
    }
    private enum RecipeError: Error { case invalidFixture, controlFailed }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
