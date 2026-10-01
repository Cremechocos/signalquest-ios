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
