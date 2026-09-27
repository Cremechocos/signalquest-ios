import XCTest

/// Parcours authentifié contre API/PostgreSQL/SMTP synthétiques en loopback.
@MainActor
final class EmailVerificationHTTPQATests: XCTestCase {
    private let api = URL(string: "http://127.0.0.1:49240")!
    private let mail = URL(string: "http://127.0.0.1:49126")!

    func testFrenchResendAndRefreshAfterConfirmation() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette limitée au simulateur et à la boîte SMTP synthétique")
        #endif
        continueAfterFailure = false
        let token = try await fixtureToken(\.tokenA)
        let initialMailCount = try await mailIDs().count
        let app = launchAuthenticated(token: token, locale: "fr")
        defer { app.terminate() }
        openProfile(in: app, locale: "fr")
        let cardTitle = app.staticTexts["Confirme ton adresse e-mail"]
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 20))
        capture(app, "email-verification-pending-fr")

        let resend = app.buttons["profile.emailVerification.resend"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(resend, in: app))
        resend.tap()
        XCTAssertTrue(app.staticTexts["Lien envoyé. Vérifie ta boîte e-mail."].waitForExistence(timeout: 15))
        let messageID = try await waitForNewMail(after: initialMailCount)
        let tokenFromMail = try await verificationToken(in: messageID)
        var verify = URLRequest(url: api.appendingPathComponent("api/auth/verify-email"))
        verify.httpMethod = "POST"
        verify.setValue("application/json", forHTTPHeaderField: "Content-Type")
        verify.httpBody = try JSONEncoder().encode(["token": tokenFromMail])
        let (_, response) = try await URLSession.shared.data(for: verify)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let refresh = app.buttons["profile.emailVerification.refresh"]
        XCTAssertTrue(SignalQuestUITestSupport.scrollToHittable(refresh, in: app))
        refresh.tap()
        XCTAssertTrue(cardTitle.waitForNonExistence(timeout: 15))
        capture(app, "email-verification-confirmed-fr")
    }

    func testEnglishAccountShowsClearResendAndRefreshActions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recette limitée au simulateur synthétique")
        #endif
        continueAfterFailure = false
        let app = launchAuthenticated(token: try await fixtureToken(\.tokenB), locale: "en")
        defer { app.terminate() }
        openProfile(in: app, locale: "en")
        XCTAssertTrue(app.staticTexts["Confirm your email address"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["profile.emailVerification.resend"].exists)
        XCTAssertTrue(app.buttons["profile.emailVerification.refresh"].exists)
        capture(app, "email-verification-pending-en")
    }

    private func launchAuthenticated(token: String, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: locale)
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.sqLaunch(locale: locale)
        SignalQuestUITestSupport.completeOnboardingIfNeeded(in: app)
        return app
    }

    private func openProfile(in app: XCUIApplication, locale: String) {
        let tab = SignalQuestUITestSupport.tab(named: locale == "fr" ? "Profil" : "Profile", in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()
    }

    private struct Credentials: Decodable { let tokenA: String; let tokenB: String }

    private func fixtureToken(_ key: KeyPath<Credentials, String>) async throws -> String {
        let fixture = URL(string: "http://127.0.0.1:49241/__qa/credentials")!
        var request = URLRequest(url: fixture)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Requiert la recette locale API/PostgreSQL/SMTP explicitement démarrée")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)[keyPath: key]
    }

    private struct MailList: Decodable { let messages: [MailSummary] }
    private struct MailSummary: Decodable { let ID: String }
    private struct MailDetail: Decodable { let Text: String }

    private func mailIDs() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: mail.appendingPathComponent("api/v1/messages"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(MailList.self, from: data).messages.map(\.ID)
    }

    private func waitForNewMail(after count: Int) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let ids = try await mailIDs()
            if ids.count > count, let id = ids.first { return id }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Aucun e-mail capturé par la boîte SMTP locale")
        throw NSError(domain: "SQEmailVerificationQA", code: 1)
    }

    private func verificationToken(in messageID: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: mail.appendingPathComponent("api/v1/message/\(messageID)"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try JSONDecoder().decode(MailDetail.self, from: data).Text
        let pattern = #"[?&]token=([0-9a-f]{64})"#
        guard let range = body.range(of: pattern, options: .regularExpression) else {
            XCTFail("Lien de confirmation absent du message local")
            throw NSError(domain: "SQEmailVerificationQA", code: 2)
        }
        return String(body[range]).split(separator: "=").last.map(String.init) ?? ""
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
