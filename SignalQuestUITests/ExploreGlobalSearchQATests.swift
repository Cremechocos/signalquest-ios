import XCTest

/// Recherche globale d'Explorer (plan 3, vague 2) : la même recherche propose
/// aussi les lieux et les antennes, qui s'ouvrent sur la carte. La démo
/// connaît le lieu « Lyon ».
@MainActor
final class ExploreGlobalSearchQATests: XCTestCase {
    func testSearchOffersPlacesThatOpenTheMap() {
        run(locale: "fr", tab: "Communauté", onMap: "Sur la carte", mapTab: "Carte")
    }

    func testEnglishSearchOffersPlacesThatOpenTheMap() {
        run(locale: "en", tab: "Community", onMap: "On the map", mapTab: "Map")
    }

    private func run(locale: String, tab: String, onMap: String, mapTab: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let explore = app.buttons["community.header.action.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Lyon")
        let place = app.buttons["explore.map.place"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10), "Lieu « Lyon » absent des résultats")
        XCTAssertTrue(app.staticTexts[onMap].exists, "Section « \(onMap) » absente")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "explore-global-search-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        place.tap()
        let map = SignalQuestUITestSupport.tab(named: mapTab, in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: map)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, "Le lieu doit ouvrir la carte")
    }
}
