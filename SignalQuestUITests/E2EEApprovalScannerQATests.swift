import XCTest

/// Plan 3, lot 6 : le lecteur du QR d'un appareil à approuver. Le simulateur
/// n'a pas de caméra : on y vérifie le repli, en français et en anglais ; la
/// lecture elle-même se vérifie sur un iPhone.
@MainActor
final class E2EEApprovalScannerQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testWithoutACameraTheScannerSaysWhatToDoInFrench() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-approval-scanner"], locale: "fr")
        defer { app.terminate() }

        let message = app.descendants(matching: .any)["approvalScanner.unavailable"]
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        XCTAssertTrue(message.label.contains("Colle le contenu du code"), message.label)
        XCTAssertTrue(app.navigationBars["Approuver un appareil"].exists)
        XCTAssertTrue(app.buttons["Annuler"].exists)
    }

    func testWithoutACameraTheScannerSaysWhatToDoInEnglish() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--qa-approval-scanner"], locale: "en")
        defer { app.terminate() }

        let message = app.descendants(matching: .any)["approvalScanner.unavailable"]
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        XCTAssertTrue(message.label.contains("Paste the code’s content"), message.label)
        XCTAssertTrue(app.navigationBars["Approve a device"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }
}
