import XCTest

/// QA runtime du partage Speedtest : ouvre une mesure déterministe, vérifie la
/// prévisualisation et ses choix de confidentialité, puis la feuille système.
/// Aucun compte ni réseau n'est nécessaire ; la fixture n'existe qu'en DEBUG.
@MainActor
final class SpeedtestShareQATests: XCTestCase {
    func testPreviewOptionsAndShareSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-auth", "--qa-speedtest-share-preview"]
        app.sqLaunch()

        XCTAssertTrue(
            app.staticTexts["Vérifier le partage"].waitForExistence(timeout: 15),
            "La prévisualisation du partage ne s'est pas ouverte"
        )
        XCTAssertTrue(
            app.images["Aperçu de l’image Speedtest à partager"]
                .waitForExistence(timeout: 10),
            "Le PNG exact n'est pas affiché"
        )
        let fullPreview = XCTAttachment(screenshot: app.screenshot())
        fullPreview.name = "Speedtest share preview — all details"
        fullPreview.lifetime = .keepAlways
        add(fullPreview)

        let networkToggle = app.switches["Réseau utilisé"]
        XCTAssertTrue(networkToggle.exists, "L'option Réseau utilisé est absente")
        XCTAssertEqual(networkToggle.value as? String, "1")
        networkToggle.tap()
        XCTAssertEqual(networkToggle.value as? String, "0")

        let shareButton = app.buttons["Partager"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        let shareReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: shareButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shareReady], timeout: 5), .completed)
        let privatePreview = XCTAttachment(screenshot: app.screenshot())
        privatePreview.name = "Speedtest share preview — network hidden"
        privatePreview.lifetime = .keepAlways
        add(privatePreview)

        let start = Date()
        shareButton.tap()

        // Le PNG partagé est exactement celui de l'aperçu ; aucune nouvelle
        // carte n'est rendue au moment d'ouvrir UIActivityViewController.
        let activity = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copier"]
        let appeared = activity.waitForExistence(timeout: 6) || copy.waitForExistence(timeout: 6)
        let elapsed = Date().timeIntervalSince(start)
        print("SHARE_SHEET_OPEN appeared=\(appeared) elapsed=\(String(format: "%.2f", elapsed))s")
        XCTAssertTrue(appeared, "La feuille de partage ne s'est pas affichée")
        XCTAssertLessThan(elapsed, 5.0, "Ouverture du partage trop lente")

        // Referme la feuille système pour que le runner termine proprement et
        // que le fichier temporaire soit supprimé par la vue.
        if activity.exists {
            activity.swipeDown()
        } else {
            app.swipeDown()
        }
    }
}
