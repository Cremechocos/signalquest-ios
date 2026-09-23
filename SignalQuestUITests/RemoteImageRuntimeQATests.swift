import XCTest

@MainActor
final class RemoteImageRuntimeQATests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:49243")!

    func testFrench404RetryAndCellReuse() async throws {
        try await requireFixture()
        continueAfterFailure = false
        try await control(mode: "404", reset: true)
        let app = launch(locale: "fr", version: Int(Date().timeIntervalSince1970))
        defer { app.terminate() }
        let failure = app.staticTexts["remoteImage.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let retry = app.buttons["remoteImage.retry"]
        XCTAssertTrue(retry.exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        capture(app, "photo-404-fr")
        let failedHits = try await state().hits
        XCTAssertEqual(failedHits, 1)

        try await control(mode: "success")
        retry.tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
        XCTAssertFalse(failure.exists)
        capture(app, "photo-recovered-fr")
        let loadedHits = try await state().hits
        XCTAssertEqual(loadedHits, 2, "Le réessai doit relire malgré le cache du 404")

        app.buttons["remoteImage.qa.recreate"].tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 5))
        _ = app.screenshot()
        let reusedHits = try await state().hits
        XCTAssertEqual(reusedHits, loadedHits, "La cellule réutilisée doit prendre l'image mémoire")

        try await control(mode: "corrupt")
        app.buttons["remoteImage.qa.next"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let corruptHits = try await state().hits
        XCTAssertEqual(corruptHits, loadedHits + 1)
        try await control(mode: "success")
        app.buttons["remoteImage.retry"].tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
        capture(app, "photo-corrupt-recovered-fr")

        let beforeDelayed = try await state().hits
        try await control(mode: "delayed404")
        app.buttons["remoteImage.qa.next"].tap()
        try await waitForHits(beforeDelayed + 1)
        try await control(mode: "success")
        app.buttons["remoteImage.qa.next"].tap()
        try await waitForHits(beforeDelayed + 2)
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
        try await Task.sleep(for: .milliseconds(2_300))
        XCTAssertFalse(failure.exists, "Une ancienne réponse tardive ne doit pas remplacer l'image courante")
        capture(app, "photo-late-failure-ignored-fr")

        try await control(mode: "timeout")
        app.buttons["remoteImage.qa.next"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        capture(app, "photo-http-408-fr")
        try await control(mode: "success")
        app.buttons["remoteImage.retry"].tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
    }

    func testEnglishOfflineThenRecovery() async throws {
        try await requireFixture()
        continueAfterFailure = false
        try await control(mode: "offline", reset: true)
        let app = launch(locale: "en", version: Int(Date().timeIntervalSince1970) + 1_000)
        defer { app.terminate() }
        let failure = app.staticTexts["remoteImage.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertEqual(failure.label, "Photo unavailable")
        capture(app, "photo-offline-en")
        try await control(mode: "success")
        app.buttons["remoteImage.retry"].tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
        capture(app, "photo-recovered-en")
    }

    func testSyntheticTransportTimeoutThenRecovery() async throws {
        try await requireFixture()
        continueAfterFailure = false
        try await control(mode: "success", reset: true)
        let app = launch(locale: "en", version: Int(Date().timeIntervalSince1970) + 2_000,
                         syntheticTimeout: true)
        defer { app.terminate() }
        let failure = app.staticTexts["remoteImage.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let beforeRetry = try await state().hits
        XCTAssertEqual(beforeRetry, 0, "Le timeout synthétique doit précéder le transport")
        capture(app, "photo-timeout-en")
        app.buttons["remoteImage.retry"].tap()
        XCTAssertTrue(app.images["remoteImage.loaded"].waitForExistence(timeout: 15))
        let afterRetry = try await state().hits
        XCTAssertEqual(afterRetry, 1)
        capture(app, "photo-timeout-recovered-en")
    }

    private func launch(locale: String, version: Int, syntheticTimeout: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SQ_QA_IMAGE_VERSION"] = String(version)
        app.launchEnvironment["SQ_QA_IMAGE_TIMEOUT_ONCE"] = syntheticTimeout ? "1" : "0"
        SignalQuestUITestSupport.launch(app,
            arguments: ["--mock-auth", "--qa-remote-image"], locale: locale)
        return app
    }

    private struct State: Decodable { let hits: Int }
    private struct Control: Encodable { let mode: String; let reset: Bool }

    private func requireFixture() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette locale réservée au simulateur")
        #endif
        var request = URLRequest(url: origin.appendingPathComponent("__qa/state"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Requiert le serveur d'images synthétique 127.0.0.1:49243")
        }
    }

    private func state() async throws -> State {
        var request = URLRequest(url: origin.appendingPathComponent("__qa/state"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func control(mode: String, reset: Bool = false) async throws {
        var request = URLRequest(url: origin.appendingPathComponent("__qa/control"))
        request.httpMethod = "POST"
        request.setValue("remote-image-v1", forHTTPHeaderField: "X-SQ-QA")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Control(mode: mode, reset: reset))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitForHits(_ expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await state().hits >= expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Requête d'image absente de la fixture")
        throw NSError(domain: "SQRemoteImageQA", code: 1)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
