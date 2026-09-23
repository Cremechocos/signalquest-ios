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
}
