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

    /// « Rechercher » referme le clavier : le champ est multiligne, et rien d'autre
    /// ne le fermait avant le choix d'un résultat ; il cachait la barre d'onglets
    /// (tour « après » du 30/09).
    func testSearchKeyClosesTheKeyboard() {
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Clavier encore ouvert après « Rechercher »")
        XCTAssertTrue(map.isHittable, "Barre d'onglets encore cachée")
    }

    /// Champ et bouton Filtres côte à côte : même hauteur et même ligne, à la taille
    /// par défaut comme au plus grand texte (audit de la carte du 21/11).
    func testSearchFieldAndFilterButtonShareTheirHeight() {
        for size in ["L", "AccessibilityXXXL"] {
            let app = XCUIApplication()
            SignalQuestUITestSupport.launch(
                app,
                arguments: ["--mock-auth", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"],
                locale: "fr"
            )
            let map = SignalQuestUITestSupport.tab(named: "Carte", in: app)
            XCTAssertTrue(map.waitForExistence(timeout: 15))
            map.tap()
            let bar = app.descendants(matching: .any)["map.search.bar"].firstMatch
            let filters = app.buttons["map.filters"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 15), "Barre de recherche absente (\(size))")
            XCTAssertTrue(filters.waitForExistence(timeout: 5), "Bouton Filtres absent (\(size))")
            XCTAssertEqual(bar.frame.height, filters.frame.height, accuracy: 0.5, "Hauteurs différentes (\(size))")
            XCTAssertEqual(bar.frame.midY, filters.frame.midY, accuracy: 0.5, "Centres décalés (\(size))")
            XCTAssertEqual(app.descendants(matching: .any)["map.search.input"].firstMatch.label,
                           "Rechercher un lieu ou un site", "Nom VoiceOver différent du texte affiché")
            app.terminate()
        }
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
        XCTAssertEqual(input.label, "Search for a place or site")
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
