import XCTest

/// Outil « Flouter » de l'éditeur « Modifier » (plan 3, vague 1 ; E1), ouvert
/// sur une image générée sans visage (`--qa-blur-editor`, Debug seulement).
@MainActor
final class BlurEditorQATests: XCTestCase {
    func testDrawingRemovingAndApplyingAnArea() {
        run(locale: "fr", noFace: "Aucun visage repéré", oneArea: "Zones à flouter : 1", remove: "Retirer la zone 1")
    }

    func testEnglishDrawingRemovingAndApplyingAnArea() {
        run(locale: "en", noFace: "No faces found", oneArea: "Areas to blur: 1", remove: "Remove area 1")
    }

    private func run(locale: String, noFace: String, oneArea: String, remove: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--qa-blur-editor"], locale: locale)
        defer { app.terminate() }

        let status = app.staticTexts["blur.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Éditeur « Flouter » introuvable")
        XCTAssertTrue(waitForLabel(of: status, startingWith: noFace), "Aucun visage sur l'image de recette : \(status.label)")
        let apply = app.buttons["photoEditor.done"]
        XCTAssertTrue(app.buttons["photoEditor.tool.blur"].isSelected, "L'éditeur s'ouvre sur Flouter")

        drawArea(in: app)
        XCTAssertTrue(waitForLabel(of: status, startingWith: oneArea), status.label)
        let removeButton = app.buttons["blur.region.remove.1"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5))
        XCTAssertEqual(removeButton.label, remove)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "blur-editor-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        removeButton.tap()
        XCTAssertTrue(waitForLabel(of: status, startingWith: noFace), "La zone retirée reste comptée")

        drawArea(in: app)
        XCTAssertTrue(waitForLabel(of: status, startingWith: oneArea))

        // Recadrer : pivoter, puis cadre carré ; la zone floutée suit la photo.
        app.buttons["photoEditor.tool.crop"].tap()
        let rotate = app.buttons["photoEditor.rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5))
        rotate.tap()
        app.buttons["photoEditor.ratio.square"].tap()
        XCTAssertTrue(app.buttons["photoEditor.ratio.square"].isSelected)
        XCTAssertTrue(app.buttons["photoEditor.reset"].exists, "« Réinitialiser » apparaît après une modification")
        let crop = XCTAttachment(screenshot: app.screenshot())
        crop.name = "crop-tool-\(locale)"
        crop.lifetime = .keepAlways
        add(crop)
        app.buttons["photoEditor.tool.blur"].tap()
        XCTAssertTrue(waitForLabel(of: status, startingWith: oneArea), "La zone floutée survit au recadrage")
        apply.tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5), "« Valider » doit refermer l'éditeur")
    }

    /// Glisser le doigt sur la photo trace une zone.
    private func drawArea(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.36))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func waitForLabel(of element: XCUIElement, startingWith prefix: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
