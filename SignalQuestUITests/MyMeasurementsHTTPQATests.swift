import XCTest

/// Vraie UI SwiftUI/MapKit, vrai API et PostgreSQL de la recette PRE-02.
/// Les données et le jeton restent dans le dossier QA privé.
@MainActor
final class MyMeasurementsHTTPQATests: XCTestCase {
    private struct RecipeFixture: Decodable {
        let baseURL: URL
        let token: String
        let expectedUserID: String
    }
    private struct RecipeMarker: Decodable {
        let kind: String
        let database: String
        let ports: [String: Int]
    }

    func testLargePersonalMapPaginatesWithoutClaimingEveryPointIsDrawn() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette loopback uniquement sur simulateur")
        #endif
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        func input(_ name: String) -> String? { environment[name] ?? environment["TEST_RUNNER_\(name)"] }
        guard let fixturePath = input("SQ_RECIPE_FIXTURE"),
              let appPath = input("SQ_RECIPE_APP_BUNDLE_PATH"),
              let statePath = input("SQ_RECIPE_STATE"),
              let locale = input("SQ_HISTORY_LOCALE"),
              ["fr", "en"].contains(locale) else {
            throw XCTSkip("Banc PRE-02, binaire isolé et locale requis")
        }
        let state = URL(fileURLWithPath: statePath, isDirectory: true).standardizedFileURL
        let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        let marker = try JSONDecoder().decode(RecipeMarker.self,
            from: Data(contentsOf: state.appendingPathComponent("recipe.json")))
        let fixture = try JSONDecoder().decode(RecipeFixture.self, from: Data(contentsOf: fixtureURL))
        let expectedURL = URL(string: "http://127.0.0.1:49141")!
        let bundle = try XCTUnwrap(Bundle(path: appPath))
        guard state.path.hasPrefix("/Users/alexandregermain/Site/qa/"),
              fixtureURL.deletingLastPathComponent() == state,
              marker.kind == "signalquest-ios-synthetic-v1", marker.database == "sq_ios_recipe_test",
              marker.ports["proxy"] == 49141, fixture.baseURL == expectedURL,
              fixture.expectedUserID == "ios_recipe_user_a",
              bundle.bundleIdentifier == "fr.signalquest.ios.beta",
              bundle.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String == expectedURL.absoluteString,
              bundle.object(forInfoDictionaryKey: "SQ_APP_BASE_URL") as? String == expectedURL.absoluteString else {
            XCTFail("Recette refusée hors backend et binaire synthétiques")
            return
        }

        func page(offset: Int) async throws -> [String: Any] {
            var parts = URLComponents(url: expectedURL.appendingPathComponent("api/coverage/sessions"),
                                      resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "offset", value: String(offset)),
                                URLQueryItem(name: "limit", value: "40"),
                                URLQueryItem(name: "mapPoints", value: "1")]
            var request = URLRequest(url: parts.url!)
            request.setValue("auth_token=\(fixture.token)", forHTTPHeaderField: "Cookie")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let first = try await page(offset: 0)
        let pagination = try XCTUnwrap(first["pagination"] as? [String: Any])
        let total = try XCTUnwrap(pagination["total"] as? Int)
        let firstCount = try XCTUnwrap((first["sessions"] as? [Any])?.count)
        let summary = try XCTUnwrap(first["mapPointSummary"] as? [String: Any])
        let located = try XCTUnwrap(summary["locatedCount"] as? Int)
        let returned = try XCTUnwrap(summary["returnedCount"] as? Int)
        XCTAssertGreaterThanOrEqual(total, 41)
        XCTAssertEqual(firstCount, 40)
        XCTAssertGreaterThan(located, 30_000)
        XCTAssertLessThan(returned, located, "La réduction de points doit être expliquée")
        let second = try await page(offset: 40)
        let secondCount = try XCTUnwrap((second["sessions"] as? [Any])?.count)
        XCTAssertGreaterThan(secondCount, 0)

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
        XCTAssertTrue(app.staticTexts["profile.displayName"].waitForExistence(timeout: 20))
        let entry = app.staticTexts[locale == "fr" ? "Mes mesures" : "My measurements"].firstMatch
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(entry, in: app))
        entry.tap()
        XCTAssertTrue(app.navigationBars[locale == "fr" ? "Mes mesures" : "My measurements"]
            .waitForExistence(timeout: 10), "Le titre doit suivre la langue de l’app")

        let firstRange = "1–40 / \(total)"
        XCTAssertTrue(app.staticTexts[firstRange].waitForExistence(timeout: 30),
                      "La première page doit annoncer sa portée réelle")
        let sample = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", locale == "fr" ? "Échantillon" : "Sample"))
            .firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 15), "Le nuage allégé doit être annoncé")
        let back = app.buttons["measurements.previousPage"]
        XCTAssertFalse(back.isEnabled)
        capture(app, "personal-map-first-\(locale)")

        let next = app.buttons["measurements.nextPage"]
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let secondRange = "41–\(40 + secondCount) / \(total)"
        XCTAssertTrue(app.staticTexts[secondRange].waitForExistence(timeout: 30))
        XCTAssertFalse(next.isEnabled)
        capture(app, "personal-map-second-\(locale)")
        XCTAssertTrue(back.isEnabled)
        back.tap()
        XCTAssertTrue(app.staticTexts[firstRange].waitForExistence(timeout: 30),
                      "Le retour doit restaurer la page initiale")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
