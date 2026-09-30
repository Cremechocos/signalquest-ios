import XCTest

/// Clavier de l'iPad (plan 3, vague 1) : palette ⌘K, ⌘R et ⌘F. Les touches
/// passent par les commandes de la fenêtre, comme ⌘1…⌘5.
@MainActor
final class KeyboardShortcutsQATests: XCTestCase {
    func testPaletteAndShortcutsReachTheirScreens() {
        run(locale: "fr", home: "Accueil", community: "Communauté", speed: "Tester")
    }

    func testEnglishPaletteAndShortcutsReachTheirScreens() {
        run(locale: "en", home: "Home", community: "Community", speed: "Test")
    }

    private func run(locale: String, home: String, community: String, speed: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }
        XCTAssertTrue(SignalQuestUITestSupport.tab(named: home, in: app).waitForExistence(timeout: 15))

        // ⌘K puis quelques lettres et Entrée : la première action trouvée part.
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "La palette ⌘K ne s'ouvre pas")
        field.typeText(community + "\n")
        let communityTab = SignalQuestUITestSupport.tab(named: community, in: app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "La palette doit se refermer")
        XCTAssertTrue(communityTab.waitForExistence(timeout: 5))
        XCTAssertTrue(communityTab.isSelected, "La palette doit ouvrir \(community)")

        app.typeKey("r", modifierFlags: .command)
        let speedTab = SignalQuestUITestSupport.tab(named: speed, in: app)
        XCTAssertTrue(speedTab.waitForExistence(timeout: 5))
        XCTAssertTrue(speedTab.isSelected, "⌘R doit ouvrir l'onglet \(speed)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "keyboard-cmd-r-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // La confirmation du test peut s'afficher : on la laisse, ⌘F change d'écran.
        let cancel = app.buttons[locale == "fr" ? "Annuler" : "Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }

        app.typeKey("f", modifierFlags: .command)
        let input = app.descendants(matching: .any)["map.search.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "⌘F doit ouvrir la carte")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: input
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "⌘F doit donner le clavier à la recherche de la carte")
    }
}
