import XCTest

/// Pannes près de mes lieux (plan 3, vague 2), depuis Réglages ›
/// Notifications, sur les réglages de démonstration : panne oui, dégradation
/// non, Orange surveillé, heures calmes de 22 h à 7 h.
@MainActor
final class ZoneAlertSettingsQATests: XCTestCase {
    func testOutageAlertsNearMyPlaces() {
        run(locale: "fr", profile: "Profil", settings: "Réglages")
    }

    func testEnglishOutageAlertsNearMyPlaces() {
        run(locale: "en", profile: "Profile", settings: "Settings")
    }

    private func run(locale: String, profile: String, settings: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: locale)
        defer { app.terminate() }

        let profileTab = SignalQuestUITestSupport.tab(named: profile, in: app)
        XCTAssertTrue(profileTab.waitForExistence(timeout: 20))
        profileTab.tap()
        let settingsEntry = app.staticTexts[settings]
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 15), "Entrée « \(settings) » introuvable")
        settingsEntry.tap()
        let notifications = app.descendants(matching: .any)["settings.notifications"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(notifications, in: app), "Entrée Notifications inaccessible")
        notifications.tap()
        let zoneAlerts = app.descendants(matching: .any)["notifications.zoneAlerts"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(zoneAlerts, in: app), "« Pannes près de mes lieux » absent")
        zoneAlerts.tap()

        let down = app.switches["zoneAlerts.down"].firstMatch
        XCTAssertTrue(down.waitForExistence(timeout: 10), "Écran des alertes de panne introuvable")
        XCTAssertEqual(down.value as? String, "1")
        XCTAssertEqual(app.switches["zoneAlerts.degraded"].firstMatch.value as? String, "0")

        // Deux opérateurs au plus : le troisième attend qu'on en décoche un.
        let orange = app.buttons["zoneAlerts.operator.ORANGE"].firstMatch
        let free = app.buttons["zoneAlerts.operator.FREE"].firstMatch
        let sfr = app.buttons["zoneAlerts.operator.SFR"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(free, in: app))
        XCTAssertTrue(orange.isSelected, "Orange est surveillé dans la démo")
        free.tap()
        XCTAssertTrue(free.isSelected)
        XCTAssertFalse(sfr.isEnabled, "Un troisième opérateur ne peut pas être coché")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "zone-alerts-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let quiet = app.switches["zoneAlerts.quietHours"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(quiet, in: app))
        XCTAssertEqual(quiet.value as? String, "1")
        let from = app.descendants(matching: .any)["zoneAlerts.quietFrom"].firstMatch
        XCTAssertTrue(from.exists, "Heure de début des heures calmes absente")
        // L'interrupteur, au bout de la rangée : toucher le libellé ne bascule pas.
        quiet.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(from.waitForNonExistence(timeout: 5), "Sans heures calmes, plus d'horaires")
        XCTAssertEqual(quiet.value as? String, "0")
    }
}
