import XCTest

/// QA runtime du partage Speedtest : lance un vrai test (autorun), attend le
/// bouton « Partager le résultat », l'appuie, et vérifie que la feuille de
/// partage système apparaît rapidement (image pré-rendue). Nécessite
/// SQ_AUTH_TOKEN.
@MainActor
final class SpeedtestShareQATests: XCTestCase {
    func testShareSheetOpensQuickly() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "QA partage : SQ_AUTH_TOKEN requis")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.launchArguments = ["--qa-speedtest-run"]
        app.launch()

        let shareButton = app.buttons["Partager le résultat"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 90), "Le test ne s'est pas terminé / bouton Partager absent")

        let start = Date()
        shareButton.tap()

        // La feuille de partage doit s'ouvrir vite (image pré-rendue). On cherche
        // un élément caractéristique de l'UIActivityViewController.
        let activity = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copier"]
        let appeared = activity.waitForExistence(timeout: 6) || copy.waitForExistence(timeout: 6)
        let elapsed = Date().timeIntervalSince(start)
        print("SHARE_SHEET_OPEN appeared=\(appeared) elapsed=\(String(format: "%.2f", elapsed))s")
        XCTAssertTrue(appeared, "La feuille de partage ne s'est pas affichée")
        XCTAssertLessThan(elapsed, 5.0, "Ouverture du partage trop lente")
    }
}
