import XCTest

/// QA : la fiche d'antenne propose bien d'ajouter une photo. Ouvre la première
/// antenne (pan zoomé sur Paris via le hook QA), scrolle la sheet et vérifie le
/// bouton d'ajout de photo. Nécessite SQ_AUTH_TOKEN.
@MainActor
final class AntennaPhotoQATests: XCTestCase {
    func testAntennaSheetOffersAddPhoto() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "QA photo antenne : SQ_AUTH_TOKEN requis")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.launchEnvironment["SQ_QA_PAN_TO"] = "48.857,2.352,14" // Paris, zoom 14
        app.launchArguments += ["--start-map", "--reset-map", "--qa-open-antenna"]
        app.launch()

        // La fiche s'ouvre (kicker « Fiche site »).
        let fiche = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Fiche site")).firstMatch
        XCTAssertTrue(fiche.waitForExistence(timeout: 40), "La fiche d'antenne ne s'est pas ouverte")

        // Le bouton d'ajout de photo est plus bas : on scrolle la sheet.
        let addPhoto = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "photo du site")).firstMatch
        for _ in 0..<6 where !addPhoto.exists {
            app.swipeUp()
        }
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5), "Bouton « Choisir une photo du site » introuvable dans la fiche")
        // Le sélecteur s'ouvre bien au tap (l'envoi réel est couvert séparément :
        // l'endpoint /api/photos a été validé en direct, le câblage iOS réutilise
        // `PhotoService.uploadPhoto`). On évite d'automatiser le PHPicker système,
        // trop instable en UI test.
        addPhoto.tap()
        let picker = app.navigationBars.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "Le sélecteur de photos ne s'est pas ouvert")
        print("ANTENNA_ADD_PHOTO_OK")
    }
}
