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
        XCTAssertTrue(app.buttons["Calques et filtres"].waitForExistence(timeout: 20))

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
}
