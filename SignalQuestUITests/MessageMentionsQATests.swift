import XCTest

/// Mentions dans un groupe non chiffré (plan 3, vague 2) : « @ca » propose
/// Camille, et la toucher complète son pseudo. Le même groupe montre
/// l'aperçu d'un lien.
@MainActor
final class MessageMentionsQATests: XCTestCase {
    func testMentionSuggestionCompletesTheHandle() {
        run(locale: "fr", tab: "Communauté", cancel: "Annuler")
    }

    func testEnglishMentionSuggestionCompletesTheHandle() {
        run(locale: "en", tab: "Community", cancel: "Cancel")
    }

    /// SOC-26 : en OLED sombre, la bulle reçue garde un liseré sur le fond
    /// noir. Capture pour la relecture à l'œil. Le sombre se règle sur le
    /// simulateur (`xcrun simctl ui <id> appearance dark`) : un argument de
    /// lancement ou `XCUIDevice.appearance` ne suffisent pas (voir
    /// OledTourQATests).
    func testOledReceivedBubbleStandsOut() throws {
        guard XCUIDevice.shared.appearance == .dark else {
            throw XCTSkip("Simulateur en clair : xcrun simctl ui <id> appearance dark")
        }
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "-app_pure_black", "YES"], locale: "fr")
        defer { app.terminate() }
        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10))
        messages.tap()
        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        for _ in 0..<3 where !field.exists {
            let unlockCancel = app.buttons["Annuler"].firstMatch
            if unlockCancel.waitForExistence(timeout: 3) { unlockCancel.tap() }
            let row = app.staticTexts["Équipe terrain"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = field.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(app.descendants(matching: .any)["message.linkPreview"].firstMatch.waitForExistence(timeout: 10),
                      "Message de démo absent")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "oled-received-bubble"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func run(locale: String, tab: String, cancel: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10))
        messages.tap()

        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        var opened = false
        for _ in 0..<3 where !opened {
            let unlockCancel = app.buttons[cancel].firstMatch
            if unlockCancel.waitForExistence(timeout: 3) { unlockCancel.tap() }
            let row = app.staticTexts["Équipe terrain"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Groupe de démo introuvable")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            opened = field.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(opened, "Le groupe de démo ne s'ouvre pas")

        // Le message de Léa porte un lien : sa carte montre le domaine réel.
        let linkCard = app.descendants(matching: .any)["message.linkPreview"].firstMatch
        XCTAssertTrue(linkCard.waitForExistence(timeout: 10), "Aperçu du lien absent")
        XCTAssertTrue(linkCard.label.contains("signalquest.fr"), linkCard.label)

        // Un brouillon d'un passage précédent revient dans le champ : on part
        // d'un champ vide, curseur en fin de texte.
        clear(field)
        field.typeText("Rendez-vous @ca")
        let camille = app.buttons["composer.mention.camille"]
        XCTAssertTrue(camille.waitForExistence(timeout: 5),
                      "Aucune suggestion après « @ca » ; champ : \(field.value as? String ?? "?")")
        XCTAssertFalse(app.buttons["composer.mention.lea"].exists, "Léa ne commence pas par « ca »")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "message-mention-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        camille.tap()
        XCTAssertEqual(field.value as? String, "Rendez-vous @camille ")
        XCTAssertTrue(camille.waitForNonExistence(timeout: 5), "Les suggestions doivent se refermer")
        clear(field)
    }

    /// Vide le champ en effaçant depuis la fin : toucher son milieu y plaçait
    /// le curseur, et le texte tapé s'insérait avant le brouillon.
    private func clear(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        guard !current.isEmpty, current != "Message…" else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    }
}
