import XCTest

/// Partage du dernier trajet depuis le Drive Test (plan 3, vague 1). La démo
/// charge un trajet complet : résumé, tracé et mesures.
@MainActor
final class DriveShareQATests: XCTestCase {
    func testSharingTheLastTripShowsACardWithPrivacyOptions() {
        run(locale: "fr", tab: "Tester", entry: "Mode Drive Test", acknowledge: "J'ai compris", share: "Partager le trajet")
    }

    func testEnglishSharingTheLastTripShowsACardWithPrivacyOptions() {
        run(locale: "en", tab: "Test", entry: "Drive Test mode", acknowledge: "Got it", share: "Share the trip")
    }

    private func run(locale: String, tab: String, entry: String, acknowledge: String, share: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let speed = SignalQuestUITestSupport.tab(named: tab, in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 20))
        speed.tap()
        let open = app.buttons[entry].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Entrée « \(entry) » introuvable")
        open.tap()
        let understood = app.buttons[acknowledge].firstMatch
        if understood.waitForExistence(timeout: 5) { understood.tap() }

        let shareButton = app.buttons["drivetest.lastTrip.share"]
        for _ in 0..<6 where !(shareButton.exists && shareButton.isHittable) { app.swipeUp() }
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10), "Bouton de partage du trajet introuvable")
        XCTAssertEqual(shareButton.label, share)
        shareButton.tap()

        let preview = app.descendants(matching: .any)["driveShare.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Aperçu de la carte introuvable")
        let hidesEnds = app.switches["driveShare.hidesEnds"].firstMatch
        XCTAssertTrue(hidesEnds.waitForExistence(timeout: 5))
        XCTAssertEqual(hidesEnds.value as? String, "1", "Départ et arrivée masqués par défaut")
        XCTAssertTrue(app.buttons["driveShare.share"].waitForExistence(timeout: 10), "Bouton « Partager » absent")
        capture(app, "drive-share-\(locale)")

        // Sans tracé, l'option des bouts n'a plus d'objet.
        let showsRoute = app.switches["driveShare.showsRoute"].firstMatch
        showsRoute.tap()
        XCTAssertEqual(showsRoute.value as? String, "0")
        XCTAssertFalse(hidesEnds.isEnabled, "Masquer les bouts n'a pas de sens sans tracé")
        capture(app, "drive-share-no-route-\(locale)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
