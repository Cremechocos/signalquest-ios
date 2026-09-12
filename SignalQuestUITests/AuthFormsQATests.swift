import XCTest

/// Real native forms and WKWebView, against loopback-only response fixtures.
/// No account, mail, production challenge or deployed universal link is created.
@MainActor
final class AuthFormsQATests: XCTestCase {
    private let origin = URL(string: "https://127.0.0.1:4325")!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SQ_AUTH_FORMS_QA"] == "1" else {
            throw XCTSkip("Requires the isolated HTTPS form fixture and dedicated simulator trust root")
        }
    }

    func testFrenchRecoveryAcknowledgementAndChangeAddress() async throws {
        try await configure("disabled")
        let app = launch("fr")
        try tap(app.buttons["login.recovery"], in: app)
        try fill(app.textFields["auth.recovery.email"], "recovery-fr@example.invalid", in: app)
        try tap(app.buttons["auth.recovery.submit"], in: app)
        XCTAssertTrue(app.staticTexts["auth.recovery.sent"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["auth.recovery.sent"].label, "Consulte tes e-mails")
        XCTAssertFalse(app.textFields["Code à 8 caractères"].exists)
        let stats = try await metrics()
        XCTAssertEqual(stats.forgot, 1)
        XCTAssertEqual(stats.challenges, 1)
        XCTAssertTrue(stats.hasEmail)
        XCTAssertFalse(stats.tokenInURL)
        capture("auth-recovery-fr-ack")
        try tap(app.buttons["Utiliser une autre adresse"], in: app)
        XCTAssertEqual(app.textFields["auth.recovery.email"].value as? String, "recovery-fr@example.invalid")
        XCTAssertTrue(app.buttons["auth.recovery.submit"].isEnabled)
        app.terminate()
    }

    func testEnglishRecoveryServerErrorRequiresExplicitRetryAndPreservesEmail() async throws {
        try await configure("first-error")
        let app = launch("en")
        try tap(app.buttons["login.recovery"], in: app)
        try fill(app.textFields["auth.recovery.email"], "recovery-en@example.invalid", in: app)
        try tap(app.buttons["auth.recovery.submit"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["auth.recovery.error"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["auth.recovery.sent"].exists)
        XCTAssertEqual(app.textFields["auth.recovery.email"].value as? String, "recovery-en@example.invalid")
        let before = try await metrics()
        XCTAssertEqual(before.forgot, 1, "An uncertain POST must not retry itself")
        capture("auth-recovery-en-error")
        try tap(app.buttons["auth.recovery.submit"], in: app)
        XCTAssertTrue(app.staticTexts["auth.recovery.sent"].waitForExistence(timeout: 20))
        let after = try await metrics()
        XCTAssertEqual(after.forgot, 2)
        XCTAssertEqual(after.challenges, 2, "The explicit retry must load the challenge page again")
        XCTAssertFalse(after.tokenInURL)
        capture("auth-recovery-en-retry-ack")
        app.terminate()
    }

    func testChallengeCancellationKeepsFormAndAllowsANewChallenge() async throws {
        try await configure("hold")
        let app = launch("fr")
        try tap(app.buttons["login.recovery"], in: app)
        try fill(app.textFields["auth.recovery.email"], "cancel@example.invalid", in: app)
        try tap(app.buttons["auth.recovery.submit"], in: app)
        try tap(app.buttons["auth.challenge.cancel"], in: app)
        XCTAssertTrue(app.buttons["auth.challenge.cancel"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.textFields["auth.recovery.email"].value as? String, "cancel@example.invalid")
        let cancelled = try await metrics()
        XCTAssertEqual(cancelled.forgot, 0, "No form POST is admitted after cancellation")
        try await configure("disabled")
        try tap(app.buttons["auth.recovery.submit"], in: app)
        XCTAssertTrue(app.staticTexts["auth.recovery.sent"].waitForExistence(timeout: 20))
        let retried = try await metrics()
        XCTAssertEqual(retried.forgot, 1)
        XCTAssertEqual(retried.challenges, 1)
        app.terminate()
    }

    func testSignupConsentAndServerRejectionKeepTheDraftForRetry() async throws {
        try await configure("disabled")
        let app = launch("en")
        try tap(app.buttons["login.signup"], in: app)
        try fill(app.textFields["auth.signup.name"], "Synthetic QA", in: app)
        try fill(app.textFields["auth.signup.email"], "signup@example.invalid", in: app)
        try fill(app.secureTextFields["auth.signup.password"], "Synthetic-Only-2026!", in: app)
        try fill(app.secureTextFields["auth.signup.confirmation"], "Synthetic-Only-2026!", in: app)
        let submit = app.buttons["auth.signup.submit"]
        try reveal(submit, in: app)
        XCTAssertFalse(submit.isEnabled, "Consent must still be required")
        try tap(app.switches["auth.signup.terms"], in: app)
        try tap(submit, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["auth.signup.error"].firstMatch.waitForExistence(timeout: 20))
        let first = try await metrics()
        XCTAssertEqual(first.signup, 1)
        XCTAssertTrue(first.acceptedTerms && first.hasEmail && first.hasPassword)
        XCTAssertFalse(first.tokenInURL)
        XCTAssertEqual(app.textFields["auth.signup.name"].value as? String, "Synthetic QA")
        XCTAssertEqual(app.textFields["auth.signup.email"].value as? String, "signup@example.invalid")
        XCTAssertTrue(submit.isEnabled, "Matching passwords and consent must remain valid after rejection")
        capture("auth-signup-en-error-preserved")
        try tap(submit, in: app)
        let error = app.descendants(matching: .any)["auth.signup.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        let retry = try await waitForSignupCount(2)
        XCTAssertEqual(retry.signup, 2)
        XCTAssertEqual(retry.challenges, 2)
        app.terminate()
    }

    private func launch(_ locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--reset-auth", "--reset-onboarding"], locale: locale)
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 15))
        return app
    }

    private enum InteractionError: Error { case unavailable, incompleteInput }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 15) else {
            XCTFail("Missing form element: \(element.identifier)")
            throw InteractionError.unavailable
        }
        for _ in 0..<6 {
            if element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            let frame = scroll.exists ? scroll.frame : app.frame
            let keyboard = app.keyboards.firstMatch
            let top = max(frame.minY, app.frame.minY) + 30
            let bottom = min(frame.maxY, keyboard.exists ? keyboard.frame.minY : app.frame.maxY) - 25
            guard bottom - top > 50 else { break }
            let upwards = element.frame.minY >= top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: frame.midX, dy: upwards ? bottom : top))
            let end = origin.withOffset(CGVector(dx: frame.midX, dy: upwards ? top : bottom))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        guard element.isHittable else {
            captureFieldGeometry(app, stage: "unreachable")
            capture("auth-element-unreachable")
            XCTFail("Form element remains unreachable above the keyboard: \(element.identifier)")
            throw InteractionError.unavailable
        }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) throws {
        try reveal(element, in: app)
        element.tap()
    }

    private func fill(_ element: XCUIElement, _ value: String, in app: XCUIApplication) throws {
        try tap(element, in: app)
        if element.elementType == .secureTextField {
            try dismissStrongPasswordOffer(in: app)
            captureFieldGeometry(app, stage: "before-secure-entry")
        }
        element.typeText(value)
        if element.elementType == .secureTextField { captureFieldGeometry(app, stage: "after-secure-entry") }
        if element.elementType != .secureTextField {
            let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
            guard XCTWaiter.wait(for: [entered], timeout: 3) == .completed else {
                capture("auth-input-before-submit")
                XCTFail("The automated input is incomplete before submitting the form")
                throw InteractionError.incompleteInput
            }
        }
    }

    private func dismissStrongPasswordOffer(in app: XCUIApplication) throws {
        // The simulator's system language can differ from the app's forced locale.
        let labels = ["Utiliser un mot de passe robuste", "Use Strong Password", "Use a Strong Password"]
        let surfaces = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        for surface in surfaces {
            let offer = surface.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            guard offer.waitForExistence(timeout: 2) else { continue }
            capture("auth-system-strong-password-offer")
            let close = surface.buttons.matching(NSPredicate(format: "label IN %@", ["Fermer", "Close", "Dismiss", "Annuler", "Cancel"])).firstMatch
            if close.exists && close.isHittable {
                close.tap()
            } else {
                // iOS 27's protected remote offer is visible in the screen recording
                // but its controls are not hittable through the app's AX tree.
                // This fallback is bounded to the inspected 402x874 simulator view.
                guard abs(app.frame.width - 402) < 1, abs(app.frame.height - 874) < 1 else {
                    XCTFail("The system offer needs a dismissal recipe for this device")
                    throw InteractionError.unavailable
                }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.922, dy: 0.580)).tap()
            }
            guard offer.waitForNonExistence(timeout: 5) else {
                throw InteractionError.unavailable
            }
            return
        }
    }

    private func captureFieldGeometry(_ app: XCUIApplication, stage: String) {
        let fields = app.secureTextFields.allElementsBoundByIndex.map { field in
            "id=\(field.identifier), label=\(field.label), frame=\(field.frame), hittable=\(field.isHittable), enabled=\(field.isEnabled), valueLength=\((field.value as? String)?.count ?? -1)"
        }
        let attachment = XCTAttachment(string: "keyboard=\(app.keyboards.firstMatch.exists)\n" + fields.joined(separator: "\n"))
        attachment.name = "auth-field-geometry-" + stage
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Metrics: Decodable {
        let challenges: Int, forgot: Int, signup: Int
        let acceptedTerms: Bool, hasEmail: Bool, hasPassword: Bool, tokenInURL: Bool
    }

    private func configure(_ mode: String) async throws {
        var request = URLRequest(url: origin.appendingPathComponent("qa/forms/config"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func metrics() async throws -> Metrics {
        let (data, response) = try await URLSession.shared.data(from: origin.appendingPathComponent("qa/forms/stats"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Metrics.self, from: data)
    }

    private func waitForSignupCount(_ count: Int) async throws -> Metrics {
        for _ in 0..<30 {
            let value = try await metrics()
            if value.signup >= count { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        return try await metrics()
    }
}
