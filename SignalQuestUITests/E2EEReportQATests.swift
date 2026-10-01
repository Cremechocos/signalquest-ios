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
        XCTAssertFalse(app.textFields["Décris ce qui te pose problème"].exists, "Aucun champ libre pour un message chiffré")
        XCTAssertFalse(app.textViews["Décris ce qui te pose problème"].exists)

        let send = app.buttons["report.send"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(send, in: app))
        send.tap()
        XCTAssertTrue(app.staticTexts["report.qa.sent"].waitForExistence(timeout: 5), "Feuille fermée, envoi confirmé")
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
