import XCTest

/// Plan 3, lot 6 : le réglage « exclure les navigateurs » d'une conversation
/// chiffrée v2 (§2.7), sur une démonstration, en français et en anglais.
@MainActor
final class E2EEBrowserExclusionQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAnAdminExcludesBrowsersInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-browsers"], locale: "fr")
        defer { app.terminate() }

        let toggle = app.switches["browsers.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertTrue(toggle.label.contains("Exclure les navigateurs"), toggle.label)
        let explanation = app.staticTexts["browsers.explanation"]
        XCTAssertTrue(explanation.label.contains("nouveaux messages"), explanation.label)
        XCTAssertFalse(app.staticTexts["browsers.adminOnly"].exists)

        // L'interrupteur, au bout de la rangée : toucher le libellé ne bascule pas.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("1", of: toggle), "Navigateurs exclus")
        XCTAssertFalse(app.staticTexts["browsers.error"].exists)
    }

    func testAGroupMemberCannotChangeItInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-browsers-member"], locale: "en")
        defer { app.terminate() }

        let toggle = app.switches["browsers.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertTrue(toggle.label.contains("Exclude web browsers"), toggle.label)
        XCTAssertFalse(toggle.isEnabled, "Seul un admin du groupe le règle")
        XCTAssertEqual(app.staticTexts["browsers.adminOnly"].label, "Only a group admin can change this setting.")
        XCTAssertTrue(app.staticTexts["browsers.explanation"].label.contains("new messages"))
    }

    func testARefusedChangeSaysSoAndKeepsTheSettingInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-e2ee-browsers-refused"], locale: "fr")
        defer { app.terminate() }

        let toggle = app.switches["browsers.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let error = app.staticTexts["browsers.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Seul un admin du groupe peut changer ce réglage.")
        XCTAssertEqual(toggle.value as? String, "0", "Le réglage reste tel quel")
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
