import XCTest

/// Real guest map, real services and MapKit, against the loopback map fixture.
/// Inspect the attached screen as well: accessibility presence alone is not painting.
@MainActor
final class MapHTTPRuntimeQATests: XCTestCase {

    func testCompactCoverageControlsKeepDetailsAndColorSwitchAccessible() async throws {
        try await exerciseCompactCoverageControls(locale: "fr")
    }

    func testCompactCoverageControlsKeepEnglishDetailsAndSelection() async throws {
        try await exerciseCompactCoverageControls(locale: "en")
    }

    /// La carte ne garde que la pastille « Vue partielle » ; les couleurs de la
    /// couverture se règlent dans la Légende de la feuille Carte.
    private func exerciseCompactCoverageControls(locale: String) async throws {
        try requireFixture()
        _ = try await configure("partial")
        let app = try launchGuest(locale: locale, extraArguments: ["--qa-map-layers"])
        defer { app.terminate() }
        try selectSFR(in: app)
        let limits = app.buttons["map.status.limit"]
        XCTAssertTrue(limits.waitForExistence(timeout: 25))
        XCTAssertGreaterThanOrEqual(limits.frame.height, 44)
        XCTAssertLessThan(limits.frame.width, app.frame.width - 16)
        capture(app, name: "map-context-compact-partial")

        try tap(limits, in: app)
        XCTAssertTrue(app.staticTexts["map.status.limit.detail"].waitForExistence(timeout: 10))
        capture(app, name: "map-context-limit-detail")
        try tap(app.buttons["map.status.limit.close"], in: app)
        try openLayers(in: app)
        let legend = app.buttons["map.legend"]
        try reveal(legend, in: app, sheet: Self.layersSheet)
        try tap(legend, in: app)
        // Le mode est mémorisé entre lancements : exercer une vraie bascule,
        // quel que soit le réglage laissé par une autre recette.
        try tap(app.buttons["map.coverage.mode.false"], in: app)
        let generation = app.buttons["map.coverage.mode.true"]
        try tap(generation, in: app)
        XCTAssertTrue(generation.isSelected)
        XCTAssertEqual(generation.label, locale == "en" ? "Generation" : "Génération")
        XCTAssertTrue(app.staticTexts["5G"].exists)
        capture(app, name: "map-context-generation-detail")
        try tap(app.buttons["map.legend.back"], in: app)
        try closeLayers(in: app)
        XCTAssertTrue(app.buttons["map.operator"].isHittable)
        XCTAssertTrue(app.buttons["map.filters"].isHittable)
        capture(app, name: "map-context-compact-generation")
    }

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
        try openLayers(in: app)
        let country = app.buttons["map.filters.market"]
        try reveal(country, in: app, sheet: Self.layersSheet)
        XCTAssertTrue(country.label.contains("Canada"))
        capture(app, name: "map-initial-gps-country-confirmed")
    }

    func testEnglishFilterEditorKeepsScopedControlsAccessible() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest(locale: "en", extraArguments: ["--qa-map-layers"])
        defer { app.terminate() }
        try tap(app.buttons["map.filters"], in: app)
        // Les titres de section sont en petites capitales, y compris pour l'accessibilité.
        XCTAssertTrue(app.staticTexts["TECHNOLOGIES"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["map.filters.done"].label.contains("Show results"))
        XCTAssertTrue(app.buttons["map.filters.technology.5G"].isHittable)
        capture(app, name: "map-filters-english-scoped")
        let bands = app.buttons["map.filters.bands"]
        try reveal(bands, in: app)
        try tap(bands, in: app)
        let band = app.buttons["map.filters.band.78"]
        try tap(band, in: app)
        XCTAssertTrue(band.isSelected)
        XCTAssertTrue(app.buttons["map.filters.bandMatch.any"].exists)
        capture(app, name: "map-filters-english-bands")
        try tap(app.buttons["map.filters.bands.confirm"], in: app)
        let period = app.buttons["map.filters.speedtestDays.30"]
        try reveal(period, in: app)
        XCTAssertGreaterThanOrEqual(period.frame.height, 44)
        XCTAssertTrue(app.staticTexts["Throughput"].exists)
        // Chaque segment annonce sa durée ; le titre ne nomme que le groupe.
        XCTAssertEqual(period.label, "30 d")
        capture(app, name: "map-filters-english-period")
        try tap(app.buttons["map.filters.cancel"], in: app)
    }

    func testCoverageLegendFitsSmallScreensAtAccessibilityTextSize() async throws {
        try requireFixture()
        _ = try await configure("partial")
        let app = try launchGuest(locale: "en", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "--qa-map-layers"
        ])
        defer { app.terminate() }
        try selectSFR(in: app)
        try openLayers(in: app)
        capture(app, name: "map-layers-accessibility-text-size")
        try setLayer("coverage", selected: true, in: app)
        try closeLayers(in: app)
        XCTAssertTrue(app.buttons["map.operator"].isHittable)
        XCTAssertTrue(app.buttons["map.filters"].isHittable)
        let limits = app.buttons["map.status.limit"]
        XCTAssertTrue(limits.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(limits.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(limits.frame.maxX, app.frame.maxX - 8)
        XCTAssertTrue(limits.isHittable)
        XCTAssertLessThanOrEqual(limits.frame.maxY + 4, app.buttons["map.operator"].frame.minY,
                                 "La pastille « Vue partielle » doit dégager la pastille d'état")
        capture(app, name: "map-context-accessibility-text-size")
        try tap(limits, in: app)
        XCTAssertTrue(app.staticTexts["map.status.limit.detail"].waitForExistence(timeout: 10))
        capture(app, name: "map-context-limit-accessibility-detail")
        try tap(app.buttons["map.status.limit.close"], in: app)
        try openLayers(in: app)
        let legend = app.buttons["map.legend"]
        try reveal(legend, in: app, sheet: Self.layersSheet)
        try tap(legend, in: app)
        // Les segments s'empilent aux très grandes tailles. Ne pas supposer que
        // la préférence persistée est encore « Signal ».
        let signal = app.buttons["map.coverage.mode.false"]
        try tap(signal, in: app)
        // Libellés du contrat quality-scale v1.
        for title in ["Excellent", "Good", "Fair", "Poor", "Critical", "No network found"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        }
        capture(app, name: "map-coverage-accessibility-legend-detail")
        // L'iPhone est verrouillé en portrait dans Info.plist ; l'iPad prend
        // en charge les deux orientations et exerce le redimensionnement.
        if ProcessInfo.processInfo.environment["SQ_MAP_LANDSCAPE_QA"] == "1" {
            let wasLandscape = app.frame.width > app.frame.height
            XCUIDevice.shared.orientation = wasLandscape ? .portrait : .landscapeLeft
            let rotated = NSPredicate { _, _ in (app.frame.width > app.frame.height) != wasLandscape }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 15), .completed)
            XCTAssertTrue(app.buttons["map.legend.back"].isHittable)
            XCTAssertTrue(signal.isSelected, "La feuille et sa sélection doivent survivre à la rotation")
            capture(app, name: "map-legend-kept-after-rotation")
            XCUIDevice.shared.orientation = wasLandscape ? .landscapeLeft : .portrait
        }
        try tap(app.buttons["map.legend.back"], in: app)
        try closeLayers(in: app)
        XCTAssertTrue(app.buttons["map.filters"].isHittable)
    }

    func testFilterResetSwipeDismissAndRenderOnlyApply() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        defer { app.terminate() }
        try selectSFR(in: app)
        try tap(app.buttons["map.filters"], in: app)
        let reset = app.buttons["map.filters.reset"]
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        if reset.isEnabled { try tap(reset, in: app) }
        try tap(app.buttons["map.filters.done"], in: app)
        capture(app, name: "map-azimuth-lines-before-edit")
        try tap(app.buttons["map.filters"], in: app)
        capture(app, name: "map-filters-initial")
        // Toutes cochées au départ : décocher la 5G restreint aux autres.
        let technology = app.buttons["map.filters.technology.5G"]
        try reveal(technology, in: app); technology.tap()
        XCTAssertFalse(technology.isSelected)
        let bands = app.buttons["map.filters.bands"]
        try reveal(bands, in: app); try tap(bands, in: app)
        let band = app.buttons["map.filters.band.78"]
        try tap(band, in: app)
        XCTAssertTrue(band.isSelected)
        try tap(app.buttons["map.filters.bands.back"], in: app)
        let hidden = app.buttons["map.filters.azimuth.hidden"]
        try reveal(hidden, in: app); hidden.tap()
        XCTAssertTrue(hidden.isSelected)
        try await Task.sleep(for: .milliseconds(250))
        capture(app, name: "map-filters-draft")
        try tap(reset, in: app)
        try reveal(technology, in: app)
        XCTAssertTrue(technology.isSelected)
        try reveal(bands, in: app); try tap(bands, in: app)
        XCTAssertFalse(band.isSelected)
        try tap(app.buttons["map.filters.bands.back"], in: app)
        let lines = app.buttons["map.filters.azimuth.lines"]
        try reveal(lines, in: app)
        XCTAssertTrue(lines.isSelected)
        try reveal(hidden, in: app); hidden.tap()
        let close = app.buttons["map.filters.cancel"]
        for _ in 0..<2 where close.exists {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: close.frame.minY - 10))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        guard close.waitForNonExistence(timeout: 10) else {
            capture(app, name: "map-filters-swipe-not-dismissed")
            throw RecipeError.missingControl
        }
        try tap(app.buttons["map.filters"], in: app)
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

    /// Le pays se choisit dans la feuille Carte et s'applique tout de suite,
    /// avec un opérateur du pays choisi.
    func testCountryChoiceAppliesAtOnceWithCompatibleOperator() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        defer { app.terminate() }
        try selectSFR(in: app)
        try openLayers(in: app)
        let country = app.buttons["map.filters.market"]
        try reveal(country, in: app, sheet: Self.layersSheet)
        XCTAssertTrue(country.label.contains("France"))
        let revision = try await configure("baseline")
        try tap(country, in: app)
        try tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Canada")).firstMatch, in: app)
        let appliedDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var loadedCanada = false
        repeat {
            loadedCanada = try await state().events.contains {
                $0.scenario.revision == revision && $0.event == "sent"
                    && $0.query["market"] == ["CA"] && $0.query["operator"] == ["BELL"]
            }
            if loadedCanada { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < appliedDeadline
        XCTAssertTrue(loadedCanada, "Choosing a country must load it with a compatible operator")
        try closeLayers(in: app)
        XCTAssertTrue(operatorState(in: app).localizedCaseInsensitiveContains("Bell"))
        capture(app, name: "map-country-applied")
    }

    func testGuestMapPresentsHTTPFixtureMarkers() async throws {
        try requireFixture()
        _ = try await configure("baseline")
        let app = try launchGuest()
        // `--reset-map` ne remet pas les couches : ne pas hériter de la recette précédente.
        try openLayers(in: app)
        for layer in ["antenna", "customSite"] { try setLayer(layer, selected: true, in: app) }
        try closeLayers(in: app)
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
        try await checkPartialSpeedtestRecovery(scenario: "error-one")
    }

    func testTimedOutSpeedtestTilePreservesOtherPointsAndRecoversThroughRetry() async throws {
        try await checkPartialSpeedtestRecovery(scenario: "timeout-one")
    }

    private func checkPartialSpeedtestRecovery(scenario: String) async throws {
        try requireFixture()
        let failedRevision = try await configure(scenario)
        let app = try launchGuest()
        defer { app.terminate() }
        try openLayers(in: app)
        for layer in ["antenna", "customSite", "coverage"] { try setLayer(layer, selected: false, in: app) }
        try setLayer("speedtest", selected: true, in: app)
        try closeLayers(in: app)
        try selectSFR(in: app)
        guard app.buttons["map.status.retry"].waitForExistence(timeout: scenario == "timeout-one" ? 130 : 45) else {
            capture(app, name: "map-partial-error-not-presented")
            XCTFail("The controlled tile failure must expose a retry action")
            throw RecipeError.missingControl
        }
        XCTAssertTrue(operatorState(in: app).hasPrefix("SFR"))
        let before = try await state()
        let failedEvents = before.events.filter { $0.scenario.revision == failedRevision && $0.event == "sent" && $0.path.contains("/tiles/speedtests/") && $0.query["operator"] == ["SFR"] }
        if scenario == "timeout-one" {
            let timedOut = before.events.filter {
                $0.scenario.revision == failedRevision && $0.path.contains("/tiles/speedtests/")
                    && $0.query["operator"] == ["SFR"] && $0.event == "client-disconnected"
                    && $0.status == 0 && ($0.elapsedSeconds ?? 0) >= 25
            }
            XCTAssertFalse(timedOut.isEmpty, "The native client must close a silent tile at its network deadline")
            XCTAssertFalse(failedEvents.contains { $0.status >= 400 }, "This campaign must inject silence, not an HTTP error")
            attach(try String(decoding: JSONEncoder().encode(timedOut), as: UTF8.self), name: "map-explicit-transport-timeout")
        } else {
            XCTAssertTrue(failedEvents.contains { $0.status == 503 })
        }
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
        XCTAssertTrue(operatorState(in: app).hasPrefix("SFR"))
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
        XCTAssertTrue(operatorState(in: app).hasPrefix("SFR"))
        capture(app, name: "map-speedtests-after-pan-and-pinch")

        let selectedMeasure = app.buttons.matching(NSPredicate(format: "label == %@", "Mesure de débit 200 Mbps")).firstMatch
        try tap(selectedMeasure, in: app)
        XCTAssertTrue(app.scrollViews["map.item.content"].waitForExistence(timeout: 10), "Tapping the visible measurement must open its detail")
        capture(app, name: "map-speedtest-touch-selection")
        app.terminate()
    }

    private enum RecipeError: Error { case missingControl }
    private func requireFixture() throws {
        guard ProcessInfo.processInfo.environment["SQ_MAP_HTTP_QA"] == "1" else {
            throw XCTSkip("Requires the loopback map fixture and matching compiled API URLs")
        }
        if origin != URL(string: "http://127.0.0.1:8769")! {
            let host = (origin.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard ProcessInfo.processInfo.environment["SQ_MAP_PHYSICAL_QA"] == "paired-usb-verified",
                  origin.scheme == "http", origin.port == 49144, host.contains(":"),
                  host.hasPrefix("fd") || host.hasPrefix("fc") else {
                XCTFail("Refusing a map fixture outside the verified loopback or paired USB recipe")
                throw RecipeError.missingControl
            }
        }
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SQ_MAP_LANDSCAPE_QA"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    private func launchGuest(locale: String = "fr", panTo: String? = "45.188,5.7129,14.5", extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        var environment = ["SQ_MAP_VIEWPORT_QA": "1", "SQ_MAP_CACHE_QA": UUID().uuidString]
        if let panTo { environment["SQ_QA_PAN_TO"] = panTo }
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-map", "--reset-onboarding"] + extraArguments,
                                       environment: environment, locale: locale)
        SignalQuestUITestSupport.enterGuestApplication(app, tab: "map", locale: locale)
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

    /// Valeur de la pastille d'état : « SFR, Antennes et Débits ».
    private func operatorState(in app: XCUIApplication) -> String {
        app.buttons["map.operator"].value as? String ?? ""
    }

    private func openLayers(in app: XCUIApplication) throws {
        try tap(app.buttons["map.layers"], in: app)
        guard app.buttons["map.layers.close"].waitForExistence(timeout: 10) else {
            capture(app, name: "map-layers-not-presented")
            throw RecipeError.missingControl
        }
    }

    private func closeLayers(in app: XCUIApplication) throws {
        let close = app.buttons["map.layers.close"]
        // L'en-tête défile avec le contenu : remonter avant de fermer.
        let content = app.scrollViews["map.layers.content"]
        for _ in 0..<8 where close.exists && !close.isHittable && content.exists { content.swipeDown() }
        if close.exists { try tap(close, in: app) }
        guard close.waitForNonExistence(timeout: 10) else { throw RecipeError.missingControl }
    }

    /// L'opérateur se choisit dans la feuille Carte et s'applique tout de suite.
    private func selectSFR(in app: XCUIApplication) throws {
        if operatorState(in: app).hasPrefix("SFR") { return }
        try openLayers(in: app)
        let choice = app.buttons["map.operator.option.SFR"]
        try reveal(choice, in: app, sheet: Self.layersSheet)
        choice.tap()
        XCTAssertTrue(choice.isSelected)
        try closeLayers(in: app)
        let selected = NSPredicate { _, _ in self.operatorState(in: app).hasPrefix("SFR") }
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

    /// Une feuille de la carte : sa zone défilante, son en-tête et son pied.
    private struct SheetScroll { let scroll: String; let header: String; let footer: String? }
    private static let filtersSheet = SheetScroll(scroll: "map.filters.content", header: "map.filters.cancel", footer: "map.filters.reset")
    private static let layersSheet = SheetScroll(scroll: "map.layers.content", header: "map.layers.close", footer: nil)

    /// Les grilles paresseuses n'exposent un contrôle qu'une fois atteint par le défilement.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, sheet: SheetScroll = MapHTTPRuntimeQATests.filtersSheet) throws {
        for _ in 0..<10 {
            if fullyVisible(element, in: app, sheet: sheet) { return }
            let top = app.buttons[sheet.header].frame.maxY + 4
            let above = element.exists && element.frame.minY < top
            try scrollContent(in: app, sheet: sheet, towardTop: above)
        }
        capture(app, name: "map-sheet-control-not-visible")
        XCTFail("Control is not reachable inside the sheet's visible scroll area")
        throw RecipeError.missingControl
    }
    private func visibleBounds(in app: XCUIApplication, sheet: SheetScroll) -> (top: CGFloat, bottom: CGFloat, rect: CGRect)? {
        let scroll = app.scrollViews[sheet.scroll]
        guard scroll.exists else { return nil }
        let rect = scroll.frame
        let top = max(rect.minY, app.buttons[sheet.header].frame.maxY) + 4
        var bottom = rect.maxY - 4
        if let footer = sheet.footer {
            let button = app.buttons[footer]
            guard button.exists else { return nil }
            bottom = min(bottom, button.frame.minY - 4)
        }
        return (top, bottom, rect)
    }
    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication, sheet: SheetScroll) -> Bool {
        guard element.exists, element.isHittable, let bounds = visibleBounds(in: app, sheet: sheet) else { return false }
        return element.frame.minY >= bounds.top && element.frame.maxY <= bounds.bottom
    }
    private func scrollContent(in app: XCUIApplication, sheet: SheetScroll, towardTop: Bool) throws {
        guard let bounds = visibleBounds(in: app, sheet: sheet),
              bounds.bottom - bounds.top > 80, bounds.rect.height > 0 else { throw RecipeError.missingControl }
        let upper = bounds.top + (bounds.bottom - bounds.top) * 0.25
        let lower = bounds.top + (bounds.bottom - bounds.top) * 0.75
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: bounds.rect.midX, dy: towardTop ? upper : lower))
        let end = origin.withOffset(CGVector(dx: bounds.rect.midX, dy: towardTop ? lower : upper))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Les couches s'appliquent dès le toucher, dans la feuille Carte.
    private func setLayer(_ kind: String, selected: Bool, in app: XCUIApplication) throws {
        let button = app.buttons["map.layer." + kind]
        try reveal(button, in: app, sheet: Self.layersSheet)
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

    private struct Scenario: Codable { let revision: String?; let gridRevision: Int? }
    private struct Event: Codable {
        let event: String, path: String, status: Int, scenario: Scenario
        let query: [String: [String]]
        let syntheticIDs: [String]?
        let elapsedSeconds: Double?
    }
    private struct State: Decodable { let events: [Event] }
    private var origin: URL {
        URL(string: ProcessInfo.processInfo.environment["SQ_MAP_FIXTURE_ORIGIN"] ?? "http://127.0.0.1:8769")!
    }
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
