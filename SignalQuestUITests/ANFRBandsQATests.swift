import XCTest

/// Statistiques ANFR par génération et par bande (plan 3, lot 10) : entrée
/// depuis l'écran des statistiques, générations de la 2G à la 5G, bandes de la
/// génération choisie, opérateur en filtre, en français et en anglais.
@MainActor
final class ANFRBandsQATests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGenerationsAndBandsInFrench() { run(locale: "fr") }

    func testGenerationsAndBandsInEnglish() { run(locale: "en") }

    /// Évolution en plein écran (refonte Halo) : le graphique s'ouvre tourné en
    /// paysage, la période se choisit, et l'écran revient en portrait à la fermeture.
    func testTrendFullScreenTurnsToLandscapeAndBack() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map", "--qa-anfr-stats"], locale: "fr")
        defer { app.terminate() }

        let expand = app.buttons["anfr.stats.fullscreen"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 45), "Bouton « Agrandir » absent")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(expand, in: app))
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(window.frame.height, window.frame.width, "L'écran des statistiques reste en portrait")
        expand.tap()

        XCTAssertTrue(app.descendants(matching: .any)["anfr.stats.fullscreen.chart"].waitForExistence(timeout: 10))
        let landscape = NSPredicate { _, _ in window.frame.width > window.frame.height }
        wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 10)
        let oneYear = app.buttons["anfr.stats.fullscreen.range.oneYear"]
        XCTAssertTrue(oneYear.waitForExistence(timeout: 5))
        oneYear.tap()
        XCTAssertTrue(oneYear.isSelected, "La période choisie est annoncée")
        capture(app, "fr-anfr-evolution-plein-ecran")

        app.buttons["anfr.stats.fullscreen.close"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        let portrait = NSPredicate { _, _ in window.frame.height > window.frame.width }
        wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: nil)], timeout: 10)
    }

    private func run(locale: String) {
        let fr = locale == "fr"
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map", "--qa-anfr-stats"], locale: locale)
        defer { app.terminate() }

        // Premier lancement après remise à zéro : l'écran des statistiques peut être lent.
        let entry = app.buttons["anfr.stats.bands"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 45), "Entrée « Générations et bandes » absente en \(locale)")
        _ = SignalQuestUITestSupport.scrollToHittable(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars[fr ? "Générations et bandes" : "Generations and bands"].waitForExistence(timeout: 15))

        for generation in ["2g", "3g", "4g", "5g"] {
            XCTAssertTrue(app.buttons["anfr.bands.generation.\(generation)"].waitForExistence(timeout: 15),
                          "Génération \(generation) absente")
        }
        let threeG = app.buttons["anfr.bands.generation.3g"]
        XCTAssertTrue(threeG.label.contains(fr ? "de son pic" : "of its peak"), threeG.label)
        XCTAssertTrue(app.buttons["anfr.bands.generation.5g"].isSelected, "La 5G est choisie d'abord")
        XCTAssertTrue(app.descendants(matching: .any)["anfr.bands.band.n78"].waitForExistence(timeout: 10))

        threeG.tap()
        let band = app.descendants(matching: .any)["anfr.bands.band.3g2100"]
        XCTAssertTrue(band.waitForExistence(timeout: 10), "Bandes de la 3G absentes")
        XCTAssertTrue(band.label.contains(fr ? "3G 2100 MHz" : "3G 2100 MHz"), band.label)
        XCTAssertTrue(app.buttons["anfr.bands.generation.3g"].isSelected)

        let orange = app.buttons["anfr.bands.operator.orange"]
        XCTAssertTrue(orange.waitForExistence(timeout: 10))
        orange.tap()
        XCTAssertTrue(app.buttons["anfr.bands.operator.orange"].isSelected, "L'opérateur choisi est annoncé")
        XCTAssertTrue(app.descendants(matching: .any)["anfr.bands.band.3g900"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[fr ? "Tous" : "All"].exists)
        capture(app, "\(locale)-anfr-bandes")
        let lastBand = app.descendants(matching: .any)["anfr.bands.band.3g2100"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(lastBand, in: app), "Lignes de bande hors d'atteinte")
        capture(app, "\(locale)-anfr-bandes-detail")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
