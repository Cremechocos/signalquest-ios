import XCTest

/// Native UI and real TerrainService HTTP against the opt-in profile fixture.
/// Geocoding is intentionally synthetic in this mode, not a test of MKLocalSearch.
/// Run each method separately with its documented simulator GPS fixture.
@MainActor
final class MapAntennaProfileQATests: XCTestCase {
    func testFrenchAddressOverridesDistantGPSAndClearRestoresTheDistanceLimit() async throws {
        try requireFixture(gps: "paris")
        try await configure()
        let app = try launchGuest(locale: "fr")
        defer { app.terminate() }

        try selectPlace("grenoble", in: app)
        try openOfficialAntenna(in: app)
        try await assertVisibleStableProfile(in: app, expectedOrigin: "Depuis l’adresse recherchée",
                                             expectedPointTag: "grenoble-address", name: "profile-fr-selected-address")
        try tap(app.buttons["antenna.profile.close"], in: app)
        try tap(app.buttons["antenna.detail.close"], in: app)

        let before = try await fixtureState()
        try tap(app.buttons["map.search.clear"], in: app)
        try openOfficialAntenna(in: app)
        try refreshDevicePosition(in: app)
        try reveal(app.staticTexts["antenna.sight.distance"], in: app)
        XCTAssertGreaterThan(try displayedKilometers(in: app), 30,
                             "The simulated Paris GPS must actually be admitted; a missing fix is not proof of the limit")
        try await assertProfileAbsentAndNoRequests(in: app, since: before)
        capture(app, name: "profile-fr-cleared-address-distant-gps")
    }

    func testEnglishDistantAddressSuppressesNearbyGPSUntilSearchIsCleared() async throws {
        try requireFixture(gps: "grenoble")
        try await configure()
        let app = try launchGuest(locale: "en")
        defer { app.terminate() }

        try selectPlace("paris", in: app)
        let before = try await fixtureState()
        try openOfficialAntenna(in: app)
        try reveal(app.staticTexts["antenna.sight.distance"], in: app)
        XCTAssertGreaterThan(try displayedKilometers(in: app), 30,
                             "The searched Paris origin must remain active after opening the Grenoble antenna")
        try await assertProfileAbsentAndNoRequests(in: app, since: before)
        capture(app, name: "profile-en-distant-address-overrides-nearby-gps")
        try tap(app.buttons["antenna.detail.close"], in: app)

        try tap(app.buttons["map.search.clear"], in: app)
        try openOfficialAntenna(in: app)
        try refreshDevicePosition(in: app)
        try await assertVisibleStableProfile(in: app, expectedOrigin: "From your location",
                                             expectedPointTag: "grenoble-device", name: "profile-en-cleared-address-nearby-gps")
    }

    private func requireFixture(gps: String) throws {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        guard value("SQ_MAP_PROFILE_QA") == "1" else {
            throw XCTSkip("Requires the dedicated loopback 8770 native profile recipe")
        }
        guard value("SQ_MAP_PROFILE_GPS_QA") == gps else {
            throw XCTSkip("Run this method separately with its documented synthetic simulator GPS fixture")
        }
        continueAfterFailure = false
    }

    private func launchGuest(locale: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app,
            arguments: ["--reset-auth", "--reset-map", "--reset-onboarding"],
            environment: ["SQ_MAP_PROFILE_QA": "1"], locale: locale)
        try tap(app.buttons["login.guestMap"], in: app)
        guard app.buttons["map.filters"].waitForExistence(timeout: 30) else {
            capture(app, name: "profile-map-entry-missing")
            throw RecipeFailure.missingControl
        }
        return app
    }

    private func selectPlace(_ city: String, in app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)["map.search.input"].firstMatch
        try tap(field, in: app)
        field.typeText(city == "grenoble" ? "QA Grenoble" : "QA Paris")
        let place = app.buttons["map.search.result.place.qa-place-" + city]
        guard place.waitForExistence(timeout: 20) else {
            capture(app, name: "profile-synthetic-place-missing-" + city)
            XCTFail("Synthetic address result missing: verify the DEBUG loopback geocoding seam, not Apple search")
            throw RecipeFailure.missingControl
        }
        try tap(place, in: app)
        XCTAssertTrue(app.buttons["map.search.clear"].waitForExistence(timeout: 10),
                      "The selected address must remain explicitly clearable after the keyboard closes")
        capture(app, name: "profile-place-selected-" + city)
    }

    private func openOfficialAntenna(in app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)["map.search.input"].firstMatch
        try tap(field, in: app)
        field.typeText("QA ANTENNE")
        let result = app.buttons["map.search.result.antenna.qa-profile-official-grenoble"]
        guard result.waitForExistence(timeout: 20) else {
            capture(app, name: "profile-synthetic-antenna-missing")
            throw RecipeFailure.missingControl
        }
        try tap(result, in: app)
        XCTAssertTrue(app.buttons["antenna.detail.close"].waitForExistence(timeout: 15))
    }

    private func assertVisibleStableProfile(
        in app: XCUIApplication, expectedOrigin: String, expectedPointTag: String, name: String
    ) async throws {
        try reveal(app.staticTexts["antenna.sight.distance"], in: app)
        try await waitForProfileRequests(originTag: expectedPointTag)
        let open = app.buttons["antenna.profile.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        try reveal(open, in: app)
        try tap(open, in: app)
        let chart = app.descendants(matching: .any)["antenna.profile.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        let profileScroll = app.scrollViews.containing(.any, identifier: "antenna.profile.chart").firstMatch
        let origin = profileScroll.staticTexts["antenna.profile.origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        XCTAssertEqual(origin.label, expectedOrigin)
        XCTAssertGreaterThan(chart.frame.width, 100)
        XCTAssertGreaterThan(chart.frame.height, 100)
        let summary = chart.label
        XCTAssertFalse(summary.isEmpty)
        capture(app, name: name + "-opened")

        // Presentation may cancel/disappear its source view. The actual modal
        // must retain its graph and origin across that native transition.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(chart.exists)
            XCTAssertEqual(chart.label, summary)
            XCTAssertEqual(origin.label, expectedOrigin)
            XCTAssertTrue(app.buttons["antenna.profile.close"].isHittable)
        }
        capture(app, name: name + "-stable")
        attachState(try await fixtureState(), name: name + "-http-evidence")
    }

    private func assertProfileAbsentAndNoRequests(in app: XCUIApplication, since before: ProfileState) async throws {
        // Observe a bounded interval after the valid distant distance is shown;
        // a single immediate absence check could precede the profile task.
        for _ in 0..<10 {
            XCTAssertFalse(app.buttons["antenna.profile.open"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["antenna.profile.chart"].firstMatch.exists)
            let current = try await fixtureState()
            XCTAssertEqual(current.counters.terrain, before.counters.terrain)
            XCTAssertEqual(current.counters.clutter, before.counters.clutter)
            try await Task.sleep(for: .milliseconds(200))
        }
        attachState(try await fixtureState(), name: "profile-no-request-after-distance-limit")
    }

    private func displayedKilometers(in app: XCUIApplication) throws -> Double {
        let label = app.staticTexts["antenna.sight.distance"].label
        guard label.lowercased().contains("km") else { throw RecipeFailure.expectedDistantOrigin }
        let numeric = label.replacingOccurrences(of: "\u{202f}", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .filter { "0123456789.".contains($0) }
        guard let kilometers = Double(numeric), kilometers.isFinite else { throw RecipeFailure.expectedDistantOrigin }
        return kilometers
    }

    private func refreshDevicePosition(in app: XCUIApplication) throws {
        let refresh = app.buttons.matching(NSPredicate(format: "label IN %@",
            ["Actualiser ma position", "Refresh my location"])).firstMatch
        try reveal(refresh, in: app)
        try tap(refresh, in: app)
        // L'ouverture ne doit pas présenter un ancien trajet pendant que la
        // position demandée peut encore remplacer l'origine du graphique.
        let open = app.buttons["antenna.profile.open"]
        if refresh.exists && !refresh.isEnabled && open.exists {
            XCTAssertFalse(open.isEnabled)
        }
        let refreshFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshFinished], timeout: 15), .completed,
                       "Wait for the native refresh to finish before checking a stable GPS profile")
        XCTAssertTrue(app.staticTexts["antenna.sight.distance"].waitForExistence(timeout: 15),
                      "The actual location service must admit the simulator fix after its native refresh action")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        let scroll = app.scrollViews["antenna.detail.scroll"]
        guard scroll.waitForExistence(timeout: 15) else { throw RecipeFailure.missingControl }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp()
        }
        capture(app, name: "profile-detail-target-not-reached")
        throw RecipeFailure.missingControl
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 15), element.isHittable else {
            capture(app, name: "profile-control-not-hittable")
            throw RecipeFailure.missingControl
        }
        element.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private struct Scenario: Decodable { let revision: String? }
    private struct ProfileState: Decodable, Encodable {
        struct Counters: Decodable, Encodable { let places: Int; let search: Int; let detail: Int; let terrain: Int; let clutter: Int }
        struct Event: Decodable, Encodable {
            struct Metadata: Decodable, Encodable {
                let kind: String
                let queryCase: String?
                let originTag: String?
                let destinationTag: String?
                let accepted: Bool?
                let pointCount: Int?
            }
            let requestId: String
            let path: String
            let status: Int
            let profile: Metadata
        }
        let profileQARevision: Int
        let counters: Counters
        let events: [Event]
    }
    private enum RecipeFailure: Error { case missingControl, fixtureMismatch, expectedDistantOrigin, missingNativeProfileRequests }
    private let server = URL(string: "http://127.0.0.1:8770")!

    private func configure() async throws {
        var request = URLRequest(url: server.appendingPathComponent("__qa/scenario"))
        request.httpMethod = "POST"
        request.setValue("map-runtime-v1", forHTTPHeaderField: "X-SQ-QA")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scenario": "profile-origin", "layers": ["antennas", "custom-sites"]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try JSONDecoder().decode(Scenario.self, from: data).revision != nil else { throw RecipeFailure.fixtureMismatch }
        let state = try await fixtureState()
        XCTAssertEqual(state.profileQARevision, 1)
        XCTAssertEqual(state.counters.terrain + state.counters.clutter, 0)
    }

    private func fixtureState() async throws -> ProfileState {
        var request = URLRequest(url: server.appendingPathComponent("__qa/profile/state"))
        request.setValue("map-runtime-v1", forHTTPHeaderField: "X-SQ-QA")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RecipeFailure.fixtureMismatch }
        return try JSONDecoder().decode(ProfileState.self, from: data)
    }

    private func waitForProfileRequests(originTag: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let state = try await fixtureState()
            let terrain = state.events.filter { $0.profile.kind == "terrain" }
            let clutter = state.events.filter { $0.profile.kind == "clutter" }
            if !terrain.isEmpty && !clutter.isEmpty {
                XCTAssertTrue(terrain.allSatisfy { $0.status == 200 && $0.profile.accepted == true })
                XCTAssertTrue(clutter.allSatisfy { $0.status == 200 && $0.profile.accepted == true })
                XCTAssertTrue(terrain.contains { $0.profile.originTag == originTag },
                              "The native TerrainService must sample from the expected synthetic origin")
                XCTAssertTrue(terrain.contains { $0.profile.destinationTag == "official-antenna" })
                XCTAssertGreaterThan(state.counters.places, 0)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RecipeFailure.missingNativeProfileRequests
    }

    private func attachState(_ state: ProfileState, name: String) {
        guard let data = try? JSONEncoder().encode(state), let text = String(data: data, encoding: .utf8) else { return }
        // This schema contains only fixture tags/counts/IDs, never coordinates,
        // free-form searches, payload bodies, credentials or device identity.
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
