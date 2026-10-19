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

/// Salons publics (ROOM-1) : « Ton salon » dans l'Explorer, la liste, un salon et l'envoi d'un
/// message. La démo place l'utilisateur chez SFR, en Isère. L'apparence sombre se règle sur le
/// simulateur (`xcrun simctl ui <id> appearance dark`) : aucun argument de lancement ne la force.
@MainActor
final class RoomsQATests: XCTestCase {
    func testFrenchRooms() { run(locale: "fr", tab: "Communauté", extra: [], label: "fr") }

    func testEnglishRooms() { run(locale: "en", tab: "Community", extra: [], label: "en") }

    func testFrenchRoomsAccessibilityText() {
        run(locale: "fr", tab: "Communauté",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"], label: "fr-ax")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func run(locale: String, tab: String, extra: [String], label: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"] + extra, locale: locale)
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let explore = app.buttons["community.header.action.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()

        let yours = app.buttons["explore.rooms.yours"]
        XCTAssertTrue(yours.waitForExistence(timeout: 15), "« Ton salon » absent de l'Explorer")
        XCTAssertTrue(yours.label.contains("Auvergne-Rhône-Alpes"))
        snap(app, "rooms-1-explore-\(label)")

        let all = app.buttons["explore.rooms.all"]
        XCTAssertTrue(all.exists)
        all.tap()
        let row = app.buttons["rooms.row.fr-auvergne-rhone-alpes-orange"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Liste des salons absente")
        XCTAssertTrue(app.buttons["rooms.yours.fr-auvergne-rhone-alpes-sfr"].exists)
        snap(app, "rooms-2-list-\(label)")

        app.buttons["rooms.yours.fr-auvergne-rhone-alpes-sfr"].tap()
        let field = app.textFields["rooms.thread.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Champ d'écriture du salon absent")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Nora'")).firstMatch
            .waitForExistence(timeout: 10), "Partage radio en direct absent")
        snap(app, "rooms-3-thread-\(label)")

        field.tap()
        field.typeText("Bonjour le salon")
        let post = app.buttons["rooms.thread.post"]
        XCTAssertTrue(post.isEnabled)
        post.tap()
        XCTAssertTrue(app.staticTexts["Bonjour le salon"].waitForExistence(timeout: 10), "Message envoyé absent")
        snap(app, "rooms-4-posted-\(label)")
    }
}
