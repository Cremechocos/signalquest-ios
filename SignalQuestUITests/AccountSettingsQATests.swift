import XCTest

/// Vérifie les réglages de compte qu'iOS n'exposait pas : zones privées,
/// affichage du `@` dans les classements, unité de distance.
///
/// Le test exige un vrai token : ces trois réglages sont du CONTENU DE COMPTE.
/// En mode démo, l'écran est légitimement vide et n'attesterait rien.
@MainActor
final class AccountSettingsQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private struct RecipeFixture: Decodable {
        let baseURL: URL
        let token: String
        let expectedUserID: String
    }

    private struct AccountScopeFixture: Decodable {
        let baseURL: URL
        let tokenA: String
        let tokenB: String
        let zoneID: String
        let zoneName: String
        let expectedA: String
        let expectedB: String
    }

    func testPrivateZoneFromAccountAIsAbsentAfterSwitchToAccountB() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette locale uniquement sur simulateur")
        #endif
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["SQ_ZONE_AB_FIXTURE"] ?? environment["TEST_RUNNER_SQ_ZONE_AB_FIXTURE"],
              let appPath = environment["SQ_RECIPE_APP_BUNDLE_PATH"] ?? environment["TEST_RUNNER_SQ_RECIPE_APP_BUNDLE_PATH"] else {
            throw XCTSkip("Requiert les comptes A/B synthétiques et le binaire isolé")
        }
        let fixture = try JSONDecoder().decode(AccountScopeFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let expectedURL = URL(string: "http://127.0.0.1:49141")!
        let bundle = try XCTUnwrap(Bundle(path: appPath))
        guard fixture.baseURL == expectedURL,
              fixture.expectedA == "ios_recipe_user_a", fixture.expectedB == "ios_recipe_user_b",
              fixture.zoneName.hasPrefix("Zone QA AB "), !fixture.zoneID.isEmpty,
              bundle.bundleIdentifier == "fr.signalquest.ios.beta",
              bundle.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String == expectedURL.absoluteString,
              bundle.object(forInfoDictionaryKey: "SQ_APP_BASE_URL") as? String == expectedURL.absoluteString else {
            XCTFail("La recette A/B refuse un compte ou un binaire hors loopback")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: "fr")
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        app.terminate()
        defer { app.terminate() }

        func openPrivacy(locale: String) {
            let tab = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 25))
            tab.tap()
            XCTAssertTrue(app.staticTexts["profile.displayName"].waitForExistence(timeout: 20))
            let title = locale == "fr" ? "Confidentialité" : "Privacy"
            let entry = app.staticTexts[title].firstMatch
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(entry, in: app))
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            let create = app.buttons["privacy.zone.create"]
            XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(create, in: app))
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        }

        app.launchArguments = []
        app.launchEnvironment["SQ_AUTH_TOKEN"] = fixture.tokenA
        app.sqLaunch(locale: "fr")
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        openPrivacy(locale: "fr")
        let owned = app.buttons["privacy.zone.row.\(fixture.zoneID)"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(owned, in: app))
        XCTAssertTrue(owned.label.contains(fixture.zoneName))
        app.terminate()

        app.launchEnvironment["SQ_AUTH_TOKEN"] = fixture.tokenB
        app.sqLaunch(locale: "en")
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        openPrivacy(locale: "en")
        XCTAssertTrue(app.staticTexts["No private zones saved. Add a place to protect."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["privacy.zone.row.\(fixture.zoneID)"].exists,
                       "B must not inherit A's private zone or stale list")
    }

    func testPrivateZoneEditorCreatePauseAndDeleteAgainstIsolatedBackend() throws {
        try checkPrivateZoneCRUD(locale: "fr")
    }

    func testEnglishPrivateZoneEditorCRUDOnIPadAgainstIsolatedBackend() throws {
        try checkPrivateZoneCRUD(locale: "en")
    }

    private func checkPrivateZoneCRUD(locale: String) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette locale uniquement sur simulateur")
        #endif
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["SQ_RECIPE_FIXTURE"] ?? environment["TEST_RUNNER_SQ_RECIPE_FIXTURE"],
              let appPath = environment["SQ_RECIPE_APP_BUNDLE_PATH"] ?? environment["TEST_RUNNER_SQ_RECIPE_APP_BUNDLE_PATH"] else {
            throw XCTSkip("Requiert la recette isolée explicite et son binaire compilé")
        }
        let fixture = try JSONDecoder().decode(RecipeFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let expectedURL = URL(string: "http://127.0.0.1:49141")!
        let bundle = try XCTUnwrap(Bundle(path: appPath))
        guard fixture.baseURL == expectedURL, fixture.expectedUserID == "ios_recipe_user_a",
              bundle.bundleIdentifier == "fr.signalquest.ios.beta",
              bundle.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String == expectedURL.absoluteString,
              bundle.object(forInfoDictionaryKey: "SQ_APP_BASE_URL") as? String == expectedURL.absoluteString else {
            XCTFail("La recette refuse un compte ou un binaire hors du loopback isolé")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth", "--reset-onboarding"]
        app.sqLaunch(locale: locale)
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["SQ_AUTH_TOKEN"] = fixture.token
        app.sqLaunch(locale: locale)
        defer { app.terminate() }
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)

        let profile = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 25))
        profile.tap()
        XCTAssertTrue(app.staticTexts["profile.displayName"].waitForExistence(timeout: 20),
                      "Le jeton de recette doit ouvrir le vrai profil avant les réglages")
        let privacyTitle = locale == "fr" ? "Confidentialité" : "Privacy"
        let privacy = app.staticTexts[privacyTitle].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(privacy, in: app))
        privacy.tap()
        XCTAssertTrue(app.navigationBars[privacyTitle].waitForExistence(timeout: 10),
                      "Le tap doit ouvrir les réglages de confidentialité, pas un lien légal")
        let create = app.buttons["privacy.zone.create"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(create, in: app))
        let canCreate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [canCreate], timeout: 8), .completed)
        create.tap()

        XCTAssertTrue(app.navigationBars[locale == "fr" ? "Nouvelle zone privée" : "New private zone"]
            .waitForExistence(timeout: 10))
        let name = "Zone QA R120 \(UUID().uuidString.prefix(6))"
        let latitude = "\(Int.random(in: 10...59)).\(Int.random(in: 10_000...99_999))"
        let longitude = "\(Int.random(in: 20...119)).\(Int.random(in: 10_000...99_999))"
        let nameField = app.textFields["privacy-zone.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name + "\n")
        let form = app.tables.firstMatch.exists ? app.tables.firstMatch : app.scrollViews.firstMatch
        for (id, value) in [("privacy-zone.latitude", latitude),
                            ("privacy-zone.longitude", longitude)] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<6 where !field.isHittable { form.swipeUp() }
            XCTAssertTrue(field.isHittable)
            field.tap()
            field.typeText(value + "\n")
        }
        let save = app.buttons["privacy-zone.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 6), .completed)
        save.tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "La réponse serveur doit apparaître dans la liste")
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(row, in: app))
        row.tap()
        let editTitle = locale == "fr" ? "Modifier la zone" : "Edit zone"
        XCTAssertTrue(app.navigationBars[editTitle].waitForExistence(timeout: 10))
        let active = app.switches["privacy-zone.active"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(active, in: app))
        active.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let switchedOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: active)
        XCTAssertEqual(XCTWaiter.wait(for: [switchedOff], timeout: 5), .completed,
                       "Le switch doit réellement passer sur désactivé avant l'enregistrement")
        let updateEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        let updateResult = XCTWaiter.wait(for: [updateEnabled], timeout: 6)
        if updateResult != .completed {
            print("Zone pause UI: switch=\(active.value ?? "nil") saveEnabled=\(save.isEnabled) editor=\(app.navigationBars[editTitle].exists)")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "privacy-zone-pause-save-disabled"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertEqual(updateResult, .completed)
        save.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.navigationBars[editTitle].waitForExistence(timeout: 10))
        let paused = app.switches["privacy-zone.active"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(paused, in: app))
        XCTAssertEqual(paused.value as? String, "0")
        let remove = app.buttons["privacy-zone.delete"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(remove, in: app))
        remove.tap()
        let confirm = app.buttons.matching(identifier: "privacy-zone.confirmDelete")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(confirm)
        confirm?.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 15))
    }

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
