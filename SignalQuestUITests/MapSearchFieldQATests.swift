import XCTest

@MainActor
final class MapSearchFieldQATests: XCTestCase {
    func testSearchKeepsItsLabelAfterTypingAndClearsItWithTheQuery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: "fr")
        defer { app.terminate() }

        let map = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        map.tap()
        let input = app.descendants(matching: .any)["map.search.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Paris")
        let label = app.staticTexts["map.search.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5), "Libellé absent après la saisie")
        XCTAssertEqual(label.label, "Recherche")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "map-search-persistent-label-focus"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let clear = app.buttons["map.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(label.exists, "Le libellé compact reste visible après effacement")
    }

    func testEnglishSearchKeepsItsLabelAtLargeTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(
            app,
            arguments: ["--mock-auth", "-app_pure_black", "YES",
                        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            locale: "en"
        )
        defer { app.terminate() }

        let map = SignalQuestUITestSupport.tab(named: "Map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        map.tap()
        let input = app.descendants(matching: .any)["map.search.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(input.label, "Search for a city, address, or site")
        input.tap()
        input.typeText("Paris")
        let label = app.staticTexts["map.search.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertEqual(label.label, "Search")
        XCTAssertGreaterThanOrEqual(label.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(label.frame.maxX, app.frame.maxX)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "map-search-en-oled-ax-xxxl"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
