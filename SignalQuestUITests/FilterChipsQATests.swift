import XCTest

/// TRX-11 (restes du plan 2) : pastilles de filtre faites main remplacées par
/// `SQChip` — filtres de l'écran ANFR, portée « Amis » des Classements,
/// coloration de « Mes mesures ». Même rendu, cible de 44 pt, état
/// sélectionné annoncé, liseré OLED, libellés traduits.
@MainActor
final class FilterChipsQATests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFilterChipsFrench() { run(locale: "fr") }

    func testFilterChipsEnglish() { run(locale: "en") }

    private func run(locale: String) {
        let fr = locale == "fr"

        // Écran ANFR, par les filtres de la carte : le chemin de l'utilisateur.
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--reset-map"], locale: locale)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }
        let map = SignalQuestUITestSupport.tab(named: fr ? "Carte" : "Map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 25), "Onglet Carte absent en \(locale)")
        map.tap()
        let filters = app.buttons["map.filters"].firstMatch
        XCTAssertTrue(filters.waitForExistence(timeout: 15), "Bouton des filtres absent")
        filters.tap()
        let anfrStats = app.buttons["map.filters.anfr.stats"].firstMatch
        XCTAssertTrue(anfrStats.waitForExistence(timeout: 10), "Entrée des statistiques ANFR absente")
        _ = SignalQuestUITestSupport.scrollToHittable(anfrStats, in: app)
        anfrStats.tap()
        let band = app.buttons[fr ? "5G 3,5 GHz" : "5G 3.5 GHz"]
        XCTAssertTrue(band.waitForExistence(timeout: 25), "Filtre 5G 3,5 GHz absent en \(locale)")
        assertChip(band)
        band.tap()
        XCTAssertTrue(band.isSelected, "Le filtre choisi est annoncé comme sélectionné")
        capture(app, "\(locale)-anfr-filtres")
        back(app, fr: fr)

        // Classements : portée « Amis ».
        let profile = SignalQuestUITestSupport.tab(named: fr ? "Profil" : "Profile", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 25), "Onglet Profil absent en \(locale)")
        profile.tap()
        let tile = app.buttons["profile.progression.tile.Classements"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "Tuile Classements absente")
        tile.tap()
        let friends = app.buttons[fr ? "Amis" : "Friends"]
        XCTAssertTrue(friends.waitForExistence(timeout: 15), "Pastille Amis absente en \(locale)")
        assertChip(friends)
        capture(app, "\(locale)-classements")
        back(app, fr: fr)

        // Mes mesures : coloration, affichée seulement s'il y a des points.
        let row = app.staticTexts[fr ? "Mes mesures" : "My measurements"].firstMatch
        if row.waitForExistence(timeout: 10), SignalQuestUITestSupport.scrollToHittable(row, in: app) {
            row.tap()
            let signal = app.buttons["Signal"]
            if signal.waitForExistence(timeout: 12) {
                assertChip(signal)
                assertChip(app.buttons[fr ? "Génération" : "Generation"])
            } else {
                print("SQ_CHIPS Mes mesures : pas de points en démo, sélecteur non affiché")
            }
            capture(app, "\(locale)-mes-mesures")
        }
    }

    /// Les Classements ont leur propre bouton « Retour » ; ailleurs, la barre
    /// de navigation système.
    private func back(_ app: XCUIApplication, fr: Bool) {
        let custom = app.buttons[fr ? "Retour" : "Back"].firstMatch
        if custom.exists { custom.tap(); return }
        let system = app.navigationBars.buttons.element(boundBy: 0)
        if system.exists { system.tap() } else { app.swipeRight() }
    }

    private func assertChip(_ chip: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(chip.exists, "Pastille absente", file: file, line: line)
        XCTAssertTrue(chip.isHittable, "Pastille « \(chip.label) » non touchable", file: file, line: line)
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44, "Cible de 44 pt pour « \(chip.label) »", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
