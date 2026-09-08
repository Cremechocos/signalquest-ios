import XCTest

/// Real guest map, real services and MapKit, against the loopback map fixture.
/// Inspect the attached screen as well: accessibility presence alone is not painting.
@MainActor
final class MapHTTPRuntimeQATests: XCTestCase {
    func testInitialDeviceLocationSelectsCanadaAndFramesItsActualMeasurements() async throws {
        try requireFixture()
        guard ProcessInfo.processInfo.environment["SQ_MAP_LOCATION_QA"] == "1" else {
            throw XCTSkip("Requires the dedicated simulator location set to Montreal and location permission granted")
        }
        let revision = try await configure("baseline")
        let app = try launchGuest(panTo: nil, extraArguments: ["--qa-map-layers"])
        defer { app.terminate() }
        let loaded = NSPredicate { _, _ in self.speedtestElements(in: app).count == 5 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 35), .completed)
        let events = try await state().events.filter {
            $0.scenario.revision == revision && $0.event == "sent" && $0.path.contains("/tiles/speedtests/")
        }
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.query["market"] == ["CA"] })
        capture(app, name: "map-initial-gps-canada-measurements")
        try tap(app.buttons["map.filters"], in: app)
        XCTAssertTrue(app.buttons["map.filters.market"].label.contains("Canada"))
        capture(app, name: "map-initial-gps-country-confirmed")
    }

    func testEnglishFilterEditorKeepsCountryAndExpertControlsAccessible() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest(locale: "en")
        defer { app.terminate() }
        try tap(app.buttons["map.filters"], in: app)
        XCTAssertTrue(app.staticTexts["Country"].exists)
        XCTAssertTrue(app.buttons["map.filters.market"].isHittable)
        XCTAssertTrue(app.buttons["map.filters.done"].label.contains("Apply"))
        capture(app, name: "map-filters-english-country-first")
        let experts = app.buttons["map.filters.experts"]
        try reveal(experts, in: app); experts.tap()
        XCTAssertEqual(experts.value as? String, "Expanded")
        let band = app.buttons["map.filters.band.78"]
        try reveal(band, in: app)
        XCTAssertTrue(band.isHittable)
        let period = app.buttons["map.filters.speedtestDays"]
        try reveal(period, in: app)
        XCTAssertGreaterThanOrEqual(period.frame.height, 44)
        XCTAssertTrue(app.staticTexts["Speedtests"].exists)
        capture(app, name: "map-filters-english-experts")
        try tap(app.buttons["map.filters.cancel"], in: app)
    }

    func testCoverageLegendFitsSmallScreensAtAccessibilityTextSize() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest(locale: "en", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { app.terminate() }
        try selectSFR(in: app)
        try tap(app.buttons["map.filters"], in: app)
        capture(app, name: "map-filters-accessibility-text-size")
        try setLayer("coverage", selected: true, in: app)
        try tap(app.buttons["map.filters.done"], in: app)
        let legend = app.descendants(matching: .any)["map.coverage.legend"].firstMatch
        XCTAssertTrue(legend.waitForExistence(timeout: 15))
        capture(app, name: "map-coverage-accessibility-text-size")
        XCTAssertGreaterThanOrEqual(legend.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(legend.frame.maxX, app.frame.maxX - 8)
        XCTAssertTrue(app.buttons["map.operator"].isHittable)
        XCTAssertTrue(app.buttons["map.filters"].isHittable)
        try tap(app.buttons["map.coverage.legend"], in: app)
        for title in ["Excellent", "Good", "Fair", "Weak", "Very weak"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        }
        capture(app, name: "map-coverage-accessibility-legend-detail")
        try tap(app.buttons["map.coverage.legend.close"], in: app)
        XCTAssertTrue(app.buttons["map.filters"].isHittable)
    }

    func testExpertResetSwipeDismissAndRenderOnlyApply() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        defer { app.terminate() }
        try selectSFR(in: app)
        try tap(app.buttons["map.filters"], in: app)
        XCTAssertGreaterThanOrEqual(app.buttons["map.filters.reset"].frame.height, 44)
        try tap(app.buttons["map.filters.reset"], in: app)
        try tap(app.buttons["map.filters.done"], in: app)
        capture(app, name: "map-azimuth-lines-before-edit")
        try tap(app.buttons["map.filters"], in: app)
        capture(app, name: "map-filters-initial-country-first")
        let experts = app.buttons["map.filters.experts"]
        try reveal(experts, in: app)
        experts.tap()
        guard experts.value as? String == "Développé" else {
            capture(app, name: "map-experts-did-not-expand")
            XCTFail("Tapping the visible expert heading must expand its controls")
            throw RecipeError.missingControl
        }
        capture(app, name: "map-experts-expanded")
        let technology = app.buttons["map.filters.technology.5G"]
        try reveal(technology, in: app); technology.tap()
        let band = app.buttons["map.filters.band.78"]
        try reveal(band, in: app); band.tap()
        let hidden = app.buttons["map.filters.azimuth.hidden"]
        try reveal(hidden, in: app); hidden.tap()
        XCTAssertTrue(hidden.isSelected)
        try await Task.sleep(for: .milliseconds(250))
        capture(app, name: "map-filters-expert-draft")
        try tap(app.buttons["map.filters.reset"], in: app)
        try scrollFiltersToTop(in: app)
        try reveal(technology, in: app)
        XCTAssertFalse(technology.isSelected)
        try reveal(band, in: app)
        XCTAssertFalse(band.isSelected)
        let lines = app.buttons["map.filters.azimuth.lines"]
        try reveal(lines, in: app)
        XCTAssertTrue(lines.isSelected)
        try reveal(hidden, in: app); hidden.tap()
        let navigation = app.navigationBars["Filtres de la carte"]
        for _ in 0..<2 where navigation.exists {
            navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        guard navigation.waitForNonExistence(timeout: 10) else {
            capture(app, name: "map-filters-swipe-not-dismissed")
            throw RecipeError.missingControl
        }
        try tap(app.buttons["map.filters"], in: app)
        try reveal(experts, in: app); experts.tap()
        try reveal(lines, in: app)
        XCTAssertTrue(lines.isSelected, "Swiping away the sheet must not commit its pending azimuth choice")
        try reveal(hidden, in: app); hidden.tap()
        let renderRevision = try await configure("baseline")
        try tap(app.buttons["map.filters.done"], in: app)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            let requests = try await state().events.filter {
                $0.scenario.revision == renderRevision && ($0.query["north"] != nil || $0.path.contains("/map/tiles/"))
                    && $0.path != "/api/social/map/stream"
            }
            XCTAssertTrue(requests.isEmpty, "Azimuth rendering must not trigger a new viewport load")
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        capture(app, name: "map-azimuth-hidden-after-apply")
    }

    func testCountryDraftDoesNotLoadUntilAppliedAndCanBeCancelled() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        defer { app.terminate() }
        try selectSFR(in: app)
        try tap(app.buttons["map.filters"], in: app)
        let draftRevision = try await configure("baseline")
        try tap(app.buttons["map.filters.market"], in: app)
        try tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Canada")).firstMatch, in: app)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            let leaked = try await state().events.contains {
                $0.scenario.revision == draftRevision && $0.query["market"] == ["CA"]
            }
            guard !leaked else {
                capture(app, name: "map-country-draft-leaked-before-apply")
                XCTFail("Choosing a draft country must not load its data before Apply")
                throw RecipeError.missingControl
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        try tap(app.buttons["map.filters.cancel"], in: app)
        XCTAssertTrue(app.buttons["map.operator"].label.contains("SFR"))
        try tap(app.buttons["map.filters"], in: app)
        XCTAssertTrue(app.buttons["map.filters.market"].label.contains("France"))
        try tap(app.buttons["map.filters.market"], in: app)
        try tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Canada")).firstMatch, in: app)
        try tap(app.buttons["map.filters.done"], in: app)
        let appliedDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var loadedCanada = false
        repeat {
            loadedCanada = try await state().events.contains {
                $0.scenario.revision == draftRevision && $0.event == "sent"
                    && $0.query["market"] == ["CA"] && $0.query["operator"] == ["BELL"]
            }
            if loadedCanada { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < appliedDeadline
        XCTAssertTrue(loadedCanada, "Apply must use the chosen country with a compatible operator")
        XCTAssertTrue(app.buttons["map.operator"].label.localizedCaseInsensitiveContains("Bell"))
        capture(app, name: "map-country-draft-applied")
    }

    func testGuestMapPresentsHTTPFixtureMarkers() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        let marker = app.descendants(matching: .any)["map.marker"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 25), "No fixture marker was exposed by the real map")
        XCTAssertFalse(marker.label.isEmpty)
        let loaded = NSPredicate { _, _ in
            let labels = app.descendants(matching: .any).matching(identifier: "map.marker")
                .allElementsBoundByIndex.map(\.label).joined(separator: "\n")
            let antennas = labels.contains("qa-antennas-ORANGE-C") || labels.contains("Groupe de 10 antennes")
            return antennas && labels.contains("SYNTHETIQUE SFR-C")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 25), .completed)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "map-http-baseline-render"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let labels = app.descendants(matching: .any).matching(identifier: "map.marker")
            .allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(labels.contains("qa-antennas-ORANGE-C") || labels.contains("Groupe de 10 antennes"),
                      "The controlled antennas must be visible individually or in their complete native cluster")
        XCTAssertTrue(labels.contains("SYNTHETIQUE SFR-C"), "The controlled custom-site identity must also be present")
        let accessibility = XCTAttachment(string: labels)
        accessibility.name = "map-http-baseline-accessibility-separate-from-painting"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        app.terminate()
    }
    func testPartialSpeedtestLayerRemainsVisibleAndRecoversThroughRetry() async throws {
        try requireFixture()
        let failedRevision = try await configure("error-one")
        let app = try launchGuest()
        try tap(app.buttons["map.filters"], in: app)
        for layer in ["antenna", "customSite", "friend", "coverage"] { try setLayer(layer, selected: false, in: app) }
        try setLayer("speedtest", selected: true, in: app)
        try tap(app.buttons["map.filters.done"], in: app)
        try selectSFR(in: app)
        guard app.buttons["map.status.retry"].waitForExistence(timeout: 45) else {
            capture(app, name: "map-partial-error-not-presented")
            XCTFail("The controlled tile failure must expose a retry action")
            throw RecipeError.missingControl
        }
        XCTAssertTrue(app.buttons["map.operator"].label.contains("SFR"))
        let before = try await state()
        let failedEvents = before.events.filter { $0.scenario.revision == failedRevision && $0.event == "sent" && $0.path.contains("/tiles/speedtests/") && $0.query["operator"] == ["SFR"] }
        XCTAssertTrue(failedEvents.contains { $0.status == 503 })
        guard failedEvents.contains(where: { $0.status == 200 && !($0.syntheticIDs ?? []).isEmpty }) else {
            capture(app, name: "map-no-successful-fixture-tile")
            XCTFail("The received viewport does not contain a nonempty successful fixture tile")
            throw RecipeError.missingControl
        }
        let partial = speedtestElements(in: app)
        capture(app, name: "map-speedtests-partial-render")
        XCTAssertEqual(partial.count, 2, "The two measurements in the successful tile must remain exposed")
        attach(partial.map { $0.label + " | " + String(describing: $0.value) }.joined(separator: "\n"), name: "map-partial-accessibility-separate-from-painting")

        let recoveredRevision = try await configure("baseline")
        try tap(app.buttons["map.status.retry"], in: app)
        guard app.buttons["map.status.retry"].waitForNonExistence(timeout: 45) else {
            capture(app, name: "map-retry-not-recovered")
            XCTFail("The completed retry must clear the partial error state")
            throw RecipeError.missingControl
        }
        capture(app, name: "map-speedtests-after-retry-before-accessibility-check")
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.speedtestElements(in: app).count == 5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed)
        let after = try await state()
        let fresh = after.events.filter { $0.scenario.revision == recoveredRevision && $0.event == "sent" && $0.path.contains("/tiles/speedtests/") && $0.query["operator"] == ["SFR"] }
        XCTAssertFalse(fresh.isEmpty, "Retry must reach the fixture instead of passing only from the old cache")
        XCTAssertTrue(fresh.allSatisfy { $0.status == 200 })
        XCTAssertEqual(Set(fresh.flatMap { $0.syntheticIDs ?? [] }).count, 5)
        XCTAssertTrue(app.buttons["map.operator"].label.contains("SFR"))
        capture(app, name: "map-speedtests-recovered-render")

        let map = app.maps.firstMatch
        guard map.waitForExistence(timeout: 10) else { throw RecipeError.missingControl }
        let centerMeasure = app.buttons.matching(NSPredicate(format: "label == %@", "Mesure de débit 200 Mbps")).firstMatch
        let eastMeasure = app.buttons.matching(NSPredicate(format: "label == %@", "Mesure de débit 160 Mbps")).firstMatch
        let beforePanX = centerMeasure.frame.midX
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.50))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        try await waitForMapGeometry { abs(centerMeasure.frame.midX - beforePanX) > 10 }
        XCTAssertTrue(centerMeasure.isHittable && eastMeasure.isHittable, "Both references must remain visible before measuring the zoom")
        let beforePinch = abs(eastMeasure.frame.midX - centerMeasure.frame.midX)
        map.pinch(withScale: 1.25, velocity: 1)
        try await waitForMapGeometry { abs(eastMeasure.frame.midX - centerMeasure.frame.midX) > beforePinch + 8 }
        XCTAssertTrue(app.buttons["map.operator"].label.contains("SFR"))
        capture(app, name: "map-speedtests-after-pan-and-pinch")

        let selectedMeasure = app.buttons.matching(NSPredicate(format: "label == %@", "Mesure de débit 200 Mbps")).firstMatch
        try tap(selectedMeasure, in: app)
        XCTAssertTrue(app.staticTexts["Speed Test"].waitForExistence(timeout: 10), "Tapping the visible measurement must open its detail")
        capture(app, name: "map-speedtest-touch-selection")
        app.terminate()
    }

    private enum RecipeError: Error { case missingControl }
    private func requireFixture() throws {
        guard ProcessInfo.processInfo.environment["SQ_MAP_HTTP_QA"] == "1" else {
            throw XCTSkip("Requires the loopback map fixture and matching compiled API URLs")
        }
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SQ_MAP_LANDSCAPE_QA"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    private func launchGuest(locale: String = "fr", panTo: String? = "45.188,5.7129,14.5", extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        var environment = ["SQ_MAP_VIEWPORT_QA": "1"]
        if let panTo { environment["SQ_QA_PAN_TO"] = panTo }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-map", "--reset-onboarding"] + extraArguments,
                                       environment: environment, locale: locale)
        try tap(app.buttons["login.guestMap"], in: app)
        guard app.buttons["map.filters"].waitForExistence(timeout: 30) else {
            capture(app, name: "map-entry-not-presented")
            attach(app.debugDescription, name: "map-entry-hierarchy")
            XCTFail("The guest map was not presented after the explicit tap")
            throw RecipeError.missingControl
        }
        if ProcessInfo.processInfo.environment["SQ_MAP_LANDSCAPE_QA"] == "1" {
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
        }
        return app
    }

    private func selectSFR(in app: XCUIApplication) throws {
        let pill = app.buttons["map.operator"]
        if pill.label.hasSuffix(": SFR") { return }
        try tap(pill, in: app)
        let choices = app.buttons.matching(NSPredicate(format: "label == %@", "SFR"))
        guard choices.firstMatch.waitForExistence(timeout: 15) else {
            capture(app, name: "map-sfr-menu-choice-not-hittable")
            throw RecipeError.missingControl
        }
        let choice = choices.firstMatch
        if let menu = app.collectionViews.allElementsBoundByIndex.first(where: {
            $0.buttons.matching(NSPredicate(format: "label == %@", "SFR")).firstMatch.exists
        }) {
            for _ in 0..<4 where choice.frame.minY < menu.frame.minY + 4 {
                menu.swipeDown(velocity: .slow)
            }
        }
        let ready = NSPredicate { _, _ in choice.isHittable && choice.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15), .completed)
        choice.tap()
        let selected = NSPredicate { _, _ in pill.label.hasSuffix(": SFR") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 10), .completed)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 15) else { throw RecipeError.missingControl }
        for _ in 0..<5 {
            if element.isHittable && element.isEnabled { element.tap(); return }
            guard let scroll = app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) else { break }
            scroll.swipeUp()
        }
        capture(app, name: "map-control-not-reachable")
        XCTFail("Control is not reachable: \(element.identifier)")
        throw RecipeError.missingControl
    }

    /// Lazy grids do not expose off-screen controls until their scroll view reaches them.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        for _ in 0..<10 {
            if fullyVisibleInFilters(element, in: app) { return }
            let top = filterNavigation(in: app).frame.maxY + 4
            let above = element.exists && element.frame.minY < top
            try scrollFilterContent(in: app, towardTop: above)
        }
        capture(app, name: "map-filter-control-not-visible")
        XCTFail("Filter control is not reachable inside the sheet's visible scroll area")
        throw RecipeError.missingControl
    }
    private func scrollFiltersToTop(in app: XCUIApplication) throws {
        for _ in 0..<10 {
            if fullyVisibleInFilters(app.buttons["map.filters.market"], in: app) { return }
            try scrollFilterContent(in: app, towardTop: true)
        }
    }
    private func fullyVisibleInFilters(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable,
              app.buttons["map.filters.reset"].exists else { return false }
        let scroll = app.scrollViews["map.filters.content"].frame
        let top = max(scroll.minY, filterNavigation(in: app).frame.maxY) + 4
        let bottom = min(scroll.maxY, app.buttons["map.filters.reset"].frame.minY) - 4
        return element.frame.minY >= top && element.frame.maxY <= bottom
    }
    private func scrollFilterContent(in app: XCUIApplication, towardTop: Bool) throws {
        let scroll = app.scrollViews["map.filters.content"]
        guard scroll.exists, app.buttons["map.filters.reset"].exists else { throw RecipeError.missingControl }
        let rect = scroll.frame
        let top = max(rect.minY, filterNavigation(in: app).frame.maxY + 4)
        let bottom = min(rect.maxY, app.buttons["map.filters.reset"].frame.minY) - 4
        guard bottom - top > 80, rect.height > 0 else { throw RecipeError.missingControl }
        let experts = app.buttons["map.filters.experts"]
        let wasExpanded = experts.exists && ["Développé", "Expanded"].contains(experts.value as? String ?? "")
        let upper = top + (bottom - top) * 0.25
        let lower = top + (bottom - top) * 0.75
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: rect.midX, dy: towardTop ? upper : lower))
        let end = origin.withOffset(CGVector(dx: rect.midX, dy: towardTop ? lower : upper))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        if wasExpanded && experts.exists && ["Réduit", "Collapsed"].contains(experts.value as? String ?? "") {
            capture(app, name: "map-experts-collapsed-by-scroll")
            XCTFail("Scrolling must not collapse the open expert section")
            throw RecipeError.missingControl
        }
    }
    private func filterNavigation(in app: XCUIApplication) -> XCUIElement {
        let french = app.navigationBars["Filtres de la carte"]
        return french.exists ? french : app.navigationBars["Map filters"]
    }

    private func setLayer(_ kind: String, selected: Bool, in app: XCUIApplication) throws {
        let button = app.buttons["map.layer." + kind]
        try reveal(button, in: app)
        if button.isSelected != selected { try tap(button, in: app) }
        XCTAssertEqual(button.isSelected, selected)
    }

    private func speedtestElements(in app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mesure de débit")).allElementsBoundByIndex
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        attach(app.debugDescription, name: name + "-hierarchy")
    }
    private func attach(_ text: String, name: String) {
        let item = XCTAttachment(string: text)
        item.name = name; item.lifetime = .keepAlways; add(item)
    }

    private struct Scenario: Decodable { let revision: String?; let gridRevision: Int? }
    private struct Event: Decodable {
        let event: String, path: String, status: Int, scenario: Scenario
        let query: [String: [String]]
        let syntheticIDs: [String]?
    }
    private struct State: Decodable { let events: [Event] }
    private let origin = URL(string: "http://127.0.0.1:8769")!
    private func configure(_ scenario: String) async throws -> String {
        var request = URLRequest(url: origin.appendingPathComponent("__qa/scenario"))
        request.httpMethod = "POST"
        request.setValue("map-runtime-v1", forHTTPHeaderField: "X-SQ-QA")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scenario": scenario, "layers": ["speedtests"]])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let configured = try JSONDecoder().decode(Scenario.self, from: data)
        guard configured.gridRevision == 2 else {
            XCTFail("The recipe requires the grid split across successful and failed tiles")
            throw RecipeError.missingControl
        }
        return try XCTUnwrap(configured.revision)
    }
    private func state() async throws -> State {
        let (data, response) = try await URLSession.shared.data(from: origin.appendingPathComponent("__qa/state"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(State.self, from: data)
    }

    /// Marker geometry is a direct map observation. A guest intentionally makes
    /// no private snapshot request, and cached public tiles need no extra HTTP.
    private func waitForMapGeometry(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The native map geometry did not react to the gesture")
        throw RecipeError.missingControl
    }

}
