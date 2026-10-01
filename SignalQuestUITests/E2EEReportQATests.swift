import XCTest

/// Plan 3, lot 5 : la feuille de signalement d'un message chiffré v2, sur une
/// démonstration, en français et en anglais.
@MainActor
final class E2EEReportQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheWarningComesFirstAndTheReportLeavesWithoutFreeTextInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-report"], locale: "fr")
        defer { app.terminate() }

        let notice = app.staticTexts["report.notice"]
        if !notice.waitForExistence(timeout: 10) { app.buttons["report.qa.open"].tap() }
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("équipe de modération"), notice.label)
        XCTAssertTrue(notice.label.contains("versions précédentes"), "Les versions précédentes partent avec le message")
        XCTAssertFalse(app.descendants(matching: .any)["report.comment"].exists, "Aucun champ libre pour un message chiffré")
        let send = app.buttons["report.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertLessThan(notice.frame.minY, send.frame.minY, "L'avertissement vient avant l'envoi")

        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(send, in: app))
        send.tap()
        let sent = app.staticTexts["report.qa.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "Feuille fermée, envoi confirmé")
        XCTAssertEqual(sent.label, "SPAM · -", "Motif transmis, aucun commentaire")
        XCTAssertTrue(send.waitForNonExistence(timeout: 5), "La feuille s'est fermée")
    }

    /// Témoin : la même recherche trouve le champ libre quand il existe.
    func testTheCommentFieldIsFoundWhenTheSheetHasOne() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-report-comment"], locale: "fr")
        defer { app.terminate() }
        let send = app.buttons["report.send"]
        if !send.waitForExistence(timeout: 10) { app.buttons["report.qa.open"].tap() }
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["report.comment"].exists)
    }

    func testWithoutAModerationKeyTheSheetSaysSoInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-report-unavailable"], locale: "en")
        defer { app.terminate() }

        let notice = app.staticTexts["report.notice"]
        if !notice.waitForExistence(timeout: 10) { app.buttons["report.qa.open"].tap() }
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("moderation team"), notice.label)

        let send = app.buttons["report.send"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(send, in: app))
        send.tap()
        let error = app.staticTexts["report.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Reporting an encrypted message isn’t available yet in this version of the app.")
        XCTAssertFalse(app.staticTexts["report.qa.sent"].exists)
    }
}
