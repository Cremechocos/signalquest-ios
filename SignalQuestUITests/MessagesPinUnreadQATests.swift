import XCTest

/// Épingler une conversation et la marquer non lue depuis la liste (plan 3,
/// vague 2), sur les conversations de démonstration.
@MainActor
final class MessagesPinUnreadQATests: XCTestCase {
    func testPinningAndMarkingUnread() {
        run(locale: "fr", tab: "Communauté", cancel: "Annuler",
            labels: Labels(pin: "Épingler", unpin: "Désépingler", read: "Lu", unread: "Non lu", pinned: "Épinglée"))
    }

    func testEnglishPinningAndMarkingUnread() {
        run(locale: "en", tab: "Community", cancel: "Cancel",
            labels: Labels(pin: "Pin", unpin: "Unpin", read: "Read", unread: "Unread", pinned: "Pinned"))
    }

    private struct Labels {
        let pin, unpin, read, unread, pinned: String
    }

    private func run(locale: String, tab: String, cancel: String, labels: Labels) {
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
        // Feuille de déverrouillage du chiffrement, proposée une fois par lancement.
        let unlockCancel = app.buttons[cancel].firstMatch
        if unlockCancel.waitForExistence(timeout: 5) { unlockCancel.tap() }

        let titles = app.staticTexts.matching(identifier: "messages.row.title")
        // Par le titre de la rangée : en français, l'aperçu de la conversation
        // chiffrée vide porte le même texte que son titre.
        let plain = titles.matching(NSPredicate(format: "label == %@", "SignalQuest iOS")).firstMatch
        let encrypted = titles.matching(NSPredicate(format: "label == %@", "Conversation chiffrée")).firstMatch
        XCTAssertTrue(encrypted.waitForExistence(timeout: 10), "Conversations de démo introuvables")
        XCTAssertEqual(titles.firstMatch.label, "SignalQuest iOS")
        let pinMark = app.images["messages.row.pinned"]
        XCTAssertFalse(pinMark.exists)

        // Épingler : la conversation passe en tête, avec l'épingle.
        encrypted.swipeRight()
        tapAction(labels.pin, in: app)
        XCTAssertTrue(pinMark.waitForExistence(timeout: 5), "Épingle absente")
        XCTAssertEqual(pinMark.label, labels.pinned)
        XCTAssertEqual(titles.firstMatch.label, "Conversation chiffrée", "L'épinglée doit passer en tête")

        // Lu, puis non lu : l'action du balayage bascule.
        plain.swipeRight()
        tapAction(labels.read, in: app)
        plain.swipeRight()
        tapAction(labels.unread, in: app)
        plain.swipeRight()
        XCTAssertTrue(app.buttons[labels.read].waitForExistence(timeout: 5), "« Lu » doit revenir après « Non lu »")
        capture(app, "messages-pin-unread-\(locale)")
        app.buttons[labels.read].tap()

        // Désépingler à l'appui long : l'ordre par date revient.
        encrypted.press(forDuration: 1.2)
        tapAction(labels.unpin, in: app)
        XCTAssertTrue(pinMark.waitForNonExistence(timeout: 5), "L'épingle doit disparaître")
        XCTAssertEqual(titles.firstMatch.label, "SignalQuest iOS")
    }

    private func tapAction(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Action « \(label) » introuvable")
        button.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
