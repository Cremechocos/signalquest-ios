import XCTest

/// Vérifie les réglages de compte qu'iOS n'exposait pas : zones privées,
/// affichage du `@` dans les classements, unité de distance.
///
/// Le test exige un vrai token : ces trois réglages sont du CONTENU DE COMPTE.
/// En mode démo, l'écran est légitimement vide et n'attesterait rien.
@MainActor
final class AccountSettingsQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testAccountSettingsAreReachable() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "Requiert SQ_AUTH_TOKEN : réglages liés au compte")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.sqLaunch()
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }
        XCTAssertTrue(
            SignalQuestUITestSupport.tab(named: "Profil", in: app).waitForExistence(timeout: 25),
            "dock absent"
        )
        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        Thread.sleep(forTimeInterval: 3)

        let entry = app.staticTexts["Confidentialité"].firstMatch
        XCTAssertTrue(
            SignalQuestUITestSupport.scrollToHittable(entry, in: app),
            "L'entrée « Confidentialité » est introuvable"
        )
        entry.tap()
        Thread.sleep(forTimeInterval: 6)
        snap(app, "reglages-01-haut")

        // Les trois sections nouvelles. On les cherche en défilant : elles sont
        // sous les partages, qui occupent déjà un écran.
        for header in ["Zones privées", "Classements", "Unités"] {
            let section = app.staticTexts[header].firstMatch
            XCTAssertTrue(
                SignalQuestUITestSupport.scrollToHittable(section, in: app),
                "La section « \(header) » manque"
            )
            snap(app, "reglages-\(header.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }

        // La zone réglée depuis le web doit apparaître, pas un état vide.
        XCTAssertFalse(
            app.staticTexts["Aucune zone privée. Tu peux en créer depuis le site ou l'application Android."].exists,
            "Les zones privées du compte ne sont pas remontées"
        )
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
