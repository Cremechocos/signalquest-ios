import XCTest

/// Historique de consultation : profils dans Explorer, lieux dans la recherche
/// de la carte (plan 3, vague 1).
@MainActor
final class RecentlyViewedQATests: XCTestCase {
    func testExploreRemembersVisitedProfile() {
        runExplore(locale: "fr", tab: "Communauté", header: "Récents", clearSearch: "Effacer la recherche",
                   profile: "Voir le profil de Camille", clearRecents: "Effacer les récents")
    }

    func testEnglishExploreRemembersVisitedProfile() {
        runExplore(locale: "en", tab: "Community", header: "Recent", clearSearch: "Clear search",
                   profile: "View Camille's profile", clearRecents: "Clear recent items")
    }

    func testMapSearchRemembersChosenPlace() throws {
        try runMap(locale: "fr", tab: "Carte", header: "Récents", clearRecents: "Effacer les récents")
    }

    func testEnglishMapSearchRemembersChosenPlace() throws {
        try runMap(locale: "en", tab: "Map", header: "Recent", clearRecents: "Clear recent items")
    }

    private func runExplore(
        locale: String, tab: String, header: String, clearSearch: String, profile: String, clearRecents: String
    ) {
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

        // L'historique de l'invité de démo survit d'un lancement à l'autre.
        let clear = app.buttons["explore.recents.clear"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        let recent = app.buttons["explore.recent.profile.u1"]
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Cam")
        let result = app.buttons[profile]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Résultat « Camille » introuvable")
        result.tap()
        leaveProfile(named: "Camille", in: app)

        let clearField = app.buttons[clearSearch]
        XCTAssertTrue(clearField.waitForExistence(timeout: 10))
        clearField.tap()
        XCTAssertTrue(app.staticTexts[header].waitForExistence(timeout: 5), "Section « \(header) » absente")
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "Le profil consulté manque aux récents")
        XCTAssertEqual(recent.label, profile)
        capture(app, name: "explore-recents-\(locale)")

        recent.tap()
        leaveProfile(named: "Camille", in: app)
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        XCTAssertEqual(clear.label, clearRecents)
        clear.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5), "« Effacer » doit vider les récents")
    }

    private func leaveProfile(named name: String, in app: XCUIApplication) {
        let bar = app.navigationBars[name]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Profil de \(name) non ouvert")
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10))
    }

    private func runMap(locale: String, tab: String, header: String, clearRecents: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let map = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        map.tap()
        let input = app.descendants(matching: .any)["map.search.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        let clear = app.buttons["map.recents.clear"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))

        input.tap()
        input.typeText("Lyon")
        let place = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.search.result.place.")).firstMatch
        guard place.waitForExistence(timeout: 20) else {
            throw XCTSkip("La recherche de lieux d'Apple n'a rien rendu sur ce simulateur")
        }
        place.tap()
        let clearSearch = app.buttons["map.search.clear"]
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 10), "Le lieu choisi doit poser un repère")
        clearSearch.tap()
        XCTAssertTrue(clearSearch.waitForNonExistence(timeout: 5))

        input.tap()
        XCTAssertTrue(app.staticTexts[header].waitForExistence(timeout: 5), "Section « \(header) » absente")
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.recent.place-")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "Le lieu choisi manque aux récents")
        XCTAssertEqual(clear.label, clearRecents)
        capture(app, name: "map-recents-\(locale)")

        recent.tap()
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 10), "Le récent doit reposer le repère")
        input.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5), "« Effacer » doit vider les récents")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
