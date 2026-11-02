import XCTest

/// Outil « Flouter » de l'éditeur « Modifier » (plan 3, vague 1 ; E1), ouvert
/// sur une image générée sans visage (`--qa-blur-editor`, Debug seulement).
@MainActor
final class BlurEditorQATests: XCTestCase {
    func testDrawingRemovingAndApplyingAnArea() {
        run(locale: "fr", noFace: "Aucun visage repéré", oneArea: "Zones à flouter : 1", remove: "Retirer la zone 1",
            done: "Valider", keepEditing: "Continuer", filters: "Filtres", adjust: "Réglages", warm: "Chaud", contrast: "Contraste")
    }

    func testEnglishDrawingRemovingAndApplyingAnArea() {
        run(locale: "en", noFace: "No faces found", oneArea: "Areas to blur: 1", remove: "Remove area 1",
            done: "Done", keepEditing: "Keep editing", filters: "Filters", adjust: "Adjust", warm: "Warm", contrast: "Contrast")
    }

    private func run(locale: String, noFace: String, oneArea: String, remove: String, done: String, keepEditing: String,
                     filters: String, adjust: String, warm: String, contrast: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--qa-blur-editor"], locale: locale)
        defer { app.terminate() }

        let status = app.staticTexts["blur.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Éditeur « Flouter » introuvable")
        XCTAssertTrue(waitForLabel(of: status, startingWith: noFace), "Aucun visage sur l'image de recette : \(status.label)")
        let apply = app.buttons["photoEditor.done"]
        XCTAssertEqual(apply.label, done)
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

        // Filtres : Chaud, puis son intensité ; Réglages : contraste.
        let filtersTool = app.buttons["photoEditor.tool.filters"]
        XCTAssertEqual(filtersTool.label, filters)
        filtersTool.tap()
        let warmFilter = app.buttons["photoEditor.filter.warm"]
        XCTAssertTrue(warmFilter.waitForExistence(timeout: 5))
        XCTAssertEqual(warmFilter.label, warm)
        warmFilter.tap()
        XCTAssertTrue(warmFilter.isSelected)
        XCTAssertTrue(app.sliders["photoEditor.filterStrength"].waitForExistence(timeout: 5), "Intensité après un filtre")
        let adjustTool = app.buttons["photoEditor.tool.adjust"]
        XCTAssertEqual(adjustTool.label, adjust)
        adjustTool.tap()
        let contrastChip = app.buttons["photoEditor.adjust.contrast"]
        XCTAssertTrue(contrastChip.waitForExistence(timeout: 5))
        contrastChip.tap()
        let value = app.sliders["photoEditor.adjust.value"]
        XCTAssertEqual(value.label, contrast)
        value.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(app.buttons["photoEditor.adjust.reset"].waitForExistence(timeout: 5), "« Réinitialiser » après un réglage")
        let color = XCTAttachment(screenshot: app.screenshot())
        color.name = "adjust-tool-\(locale)"
        color.lifetime = .keepAlways
        add(color)
        app.buttons["photoEditor.tool.blur"].tap()
        XCTAssertTrue(waitForLabel(of: status, startingWith: oneArea), "La zone floutée survit aux couleurs")

        // Annuler avec des modifications : on peut reprendre la retouche.
        app.buttons["photoEditor.cancel"].tap()
        let keep = app.buttons[keepEditing]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "« \(keepEditing) » attendu")
        keep.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "L'éditeur reste ouvert")
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
