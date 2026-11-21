import XCTest

/// Vérifie que les marqueurs de carte sont réellement exposés au lecteur
/// d'écran dans l'app qui tourne. Les tests unitaires valident le TEXTE des
/// descriptions ; seul un parcours réel prouve que les vues d'annotation sont
/// devenues des éléments d'accessibilité.
@MainActor
final class MapAccessibilityQATests: XCTestCase {

    func testMapMarkersAreExposedToAssistiveTechnologies() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map", "--qa-demo-friends", "--qa-demo-photos"])
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        XCTAssertTrue(app.buttons["map.filters"].waitForExistence(timeout: 20))

        // Ancré sur l'identifiant du marqueur, pas sur son libellé : « Photos »
        // et « Antennes » existent aussi comme puces de filtre, donc matcher le
        // texte passerait même sans aucune annotation exposée.
        let marker = app.descendants(matching: .any)["map.marker"].firstMatch
        var found = false
        for _ in 0..<12 {
            if marker.exists { found = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(found, "Aucun marqueur de carte n'est exposé au lecteur d'écran")
        XCTAssertFalse(marker.label.isEmpty, "Un marqueur exposé doit porter un libellé")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Carte — marqueurs accessibles"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Feuille Carte : les opérateurs tiennent sur une ligne à la taille par défaut, le
    /// choix est annoncé « sélectionné », et la tuile Couverture n'est proposée qu'avec
    /// un opérateur (audit de la carte du 21/11).
    func testOperatorPickerKeepsOneRowAndOffersCoverageOnlyWithAnOperator() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map"], locale: "fr")
        defer { app.terminate() }
        SignalQuestUITestSupport.tab(named: "Carte", in: app).tap()
        let pill = app.buttons["map.operator"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20))
        pill.tap()
        let all = app.buttons["map.operator.option.ALL"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), "Feuille Carte absente")
        all.tap()
        XCTAssertTrue(all.isSelected)

        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.operator.option."))
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(options.count, 5)
        let rows = Set(options.map { Int($0.frame.minY.rounded()) })
        XCTAssertEqual(rows.count, 1, "Opérateurs sur plusieurs lignes : \(rows.sorted())")
        XCTAssertFalse(app.buttons["map.layer.coverage"].exists, "Couverture proposée en « Tous »")

        let orange = app.buttons["map.operator.option.ORANGE"]
        orange.tap()
        XCTAssertTrue(orange.isSelected)
        XCTAssertFalse(all.isSelected)
        XCTAssertTrue(app.buttons["map.layer.coverage"].waitForExistence(timeout: 5), "Couverture absente avec un opérateur")
    }
}
