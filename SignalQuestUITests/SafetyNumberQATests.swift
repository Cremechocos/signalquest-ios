import XCTest

/// Plan 3, lot 3 : l'écran du numéro de sécurité (§2.4, D.12) sur un annuaire
/// de démonstration, en français et en anglais.
@MainActor
final class SafetyNumberQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testVerifyingThenClearingInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-safety-number"], locale: "fr")
        defer { app.terminate() }

        let digits = app.descendants(matching: .any)["safetyNumber.digits"]
        XCTAssertTrue(digits.waitForExistence(timeout: 15))
        let groups = (digits.value as? String)?.components(separatedBy: ", ") ?? []
        XCTAssertEqual(groups.count, 12, "Douze groupes lus par VoiceOver")
        XCTAssertTrue(app.staticTexts["Numéro de sécurité"].exists || app.navigationBars["Numéro de sécurité"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.status.unverified"].exists)

        let mark = app.buttons["safetyNumber.markVerified"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(mark, in: app))
        XCTAssertEqual(mark.label, "Marquer comme vérifié")
        mark.tap()
        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.status.verified"].waitForExistence(timeout: 5))

        let clear = app.buttons["safetyNumber.clearVerification"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(clear, in: app))
        clear.tap()
        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.status.unverified"].waitForExistence(timeout: 5))
    }

    func testAChangedVerifiedNumberNeedsANewVerificationInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-safety-number-changed-verified"], locale: "en")
        defer { app.terminate() }

        let notice = app.descendants(matching: .any)["safetyNumber.changed"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        let title = app.descendants(matching: .any)["safetyNumber.changed.title"]
        XCTAssertTrue(title.exists)
        XCTAssertTrue(title.label.contains("Bruno has a new safety number"), title.label)
        XCTAssertFalse(title.label.contains("This happens when"), "L'en-tête ne porte que le titre, pas le paragraphe")
        XCTAssertFalse(app.buttons["safetyNumber.acceptWithoutVerifying"].exists,
                       "Un numéro vérifié ne s'accepte pas sans nouvelle vérification")

        let mark = app.buttons["safetyNumber.markVerified"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(mark, in: app))
        XCTAssertEqual(mark.label, "I compared: mark as verified")
        mark.tap()
        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.status.verified"].waitForExistence(timeout: 5))
        XCTAssertFalse(notice.exists, "Plus d'avis une fois le nouveau numéro vérifié")
    }

    func testAChangedNumberCanBeAcceptedWithoutVerifyingInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-safety-number-changed"], locale: "fr")
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.changed"].waitForExistence(timeout: 15))
        let accept = app.buttons["safetyNumber.acceptWithoutVerifying"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(accept, in: app))
        XCTAssertEqual(accept.label, "Accepter sans vérifier")
        accept.tap()
        XCTAssertTrue(app.descendants(matching: .any)["safetyNumber.status.unverified"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["safetyNumber.changed"].exists)
        XCTAssertTrue(app.buttons["safetyNumber.markVerified"].exists, "Le nouveau numéro reste à vérifier")
    }
}
