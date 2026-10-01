import XCTest

/// Plan 3, lot 3 : la clé de ton compte (§2.3, D.12) sur un trousseau de
/// démonstration, en français et en anglais.
@MainActor
final class E2EEAccountKeyQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAnApprovedDeviceComparesThenMarksItsKeyInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-account-key"], locale: "fr")
        defer { app.terminate() }

        let digits = app.descendants(matching: .any)["accountKey.digits"]
        XCTAssertTrue(digits.waitForExistence(timeout: 15))
        let groups = (digits.value as? String)?.components(separatedBy: ", ") ?? []
        XCTAssertEqual(groups.count, 6, "Six groupes de cinq chiffres lus par VoiceOver")
        XCTAssertTrue(app.descendants(matching: .any)["accountKey.status.unverified"].exists)
        XCTAssertTrue(app.staticTexts["accountKey.explanation"].label.contains("sans pouvoir la vérifier seul"))

        let mark = app.buttons["accountKey.markVerified"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(mark, in: app))
        XCTAssertEqual(mark.label, "Les chiffres sont identiques : marquer comme vérifiée")
        mark.tap()
        XCTAssertTrue(app.descendants(matching: .any)["accountKey.status.verified"].waitForExistence(timeout: 5))
        XCTAssertFalse(mark.exists, "Rien à marquer une fois la clé vérifiée")
        XCTAssertEqual(digits.value as? String, groups.joined(separator: ", "), "Les mêmes chiffres")
    }

    func testTheFirstDeviceShowsItsKeyVerifiedInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-account-key-verified"], locale: "en")
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["accountKey.status.verified"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["accountKey.markVerified"].exists)
        let explanation = app.staticTexts["accountKey.explanation"]
        XCTAssertTrue(explanation.label.contains("same on all your devices"), explanation.label)
        XCTAssertTrue(app.navigationBars["Your account key"].exists)
    }

    func testWithoutTheKeyTheScreenSaysSoInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-account-key-missing"], locale: "fr")
        defer { app.terminate() }

        let error = app.descendants(matching: .any)["accountKey.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(error.label, "Cet appareil n’a pas encore la clé de ton compte.")
        XCTAssertFalse(app.descendants(matching: .any)["accountKey.digits"].exists)
    }
}
