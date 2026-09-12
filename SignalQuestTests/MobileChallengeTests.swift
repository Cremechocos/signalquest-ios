import XCTest
@testable import SignalQuest

final class MobileChallengeTests: XCTestCase {
    private let identifier = UUID(uuidString: "123e4567-e89b-42d3-a456-426614174000")!
    private func attempt() throws -> MobileChallengeAttempt {
        try MobileChallengeAttempt(origin: URL(string: "https://app.example.invalid")!,
            action: .signup, language: "fr", theme: "dark", id: identifier)
    }

    func testChallengeURLContainsOnlyThePublicContext() throws {
        let value = try attempt()
        XCTAssertEqual(value.url.absoluteString,
            "https://app.example.invalid/api/auth/mobile-challenge?action=signup&attempt=123e4567-e89b-42d3-a456-426614174000&lang=fr&theme=dark")
    }

    func testInsecureCredentialedOrNonOriginConfigurationIsRejected() {
        for origin in ["http://app.example.invalid", "file:///tmp/challenge", "https://user:secret@app.example.invalid",
                       "https://app.example.invalid/elsewhere", "https://app.example.invalid?secret=value", "https://app.example.invalid#token"] {
            XCTAssertThrowsError(try MobileChallengeAttempt(origin: URL(string: origin)!,
                action: .signup, language: "en", theme: "auto"), origin)
        }
    }

    func testMainDocumentCannotRedirectToAnotherPathAttemptOrOrigin() throws {
        let value = try attempt()
        for candidate in ["https://app.example.invalid/other", value.url.absoluteString + "#token",
                          value.url.absoluteString.replacingOccurrences(of: "app.example.invalid", with: "app.example.invalid.attacker.invalid"),
                          value.url.absoluteString.replacingOccurrences(of: "action=signup", with: "action=password-reset")] {
            XCTAssertFalse(value.isMainDocument(URL(string: candidate)))
        }
        XCTAssertTrue(value.isMainDocument(value.url))
    }

    func testSubframesAllowTheProviderAndRequiredAboutDocumentsOnly() throws {
        let value = try attempt()
        for candidate in ["about:blank", "about:srcdoc", "https://challenges.cloudflare.com/turnstile/v0/test", "https://app.example.invalid/frame"] {
            XCTAssertTrue(value.allowsSubframe(URL(string: candidate)), candidate)
        }
        for candidate in ["https://challenges.cloudflare.com.attacker.invalid/frame", "http://challenges.cloudflare.com", "https://challenges.cloudflare.com:444/frame", "javascript:alert(1)", "file:///tmp/page", "https://attacker.invalid"] {
            XCTAssertFalse(value.allowsSubframe(URL(string: candidate)), candidate)
        }
    }

    func testSecurityOriginIncludesSchemeAndPort() throws {
        let value = try attempt()
        XCTAssertTrue(value.acceptsOrigin(scheme: "https", host: "app.example.invalid", port: 0))
        XCTAssertTrue(value.acceptsOrigin(scheme: "https", host: "app.example.invalid", port: 443))
        XCTAssertFalse(value.acceptsOrigin(scheme: "http", host: "app.example.invalid", port: 443))
        XCTAssertFalse(value.acceptsOrigin(scheme: "https", host: "app.example.invalid", port: 444))
        XCTAssertFalse(value.acceptsOrigin(scheme: "https", host: "attacker.invalid", port: 443))
    }

    private var tokenMessage: [String: Any] {
        ["version": 1, "action": "signup", "attempt": "123E4567-E89B-42D3-A456-426614174000",
         "event": "token", "token": "synthetic-challenge-token"]
    }

    func testCorrectCallbackDecodesItsTokenAndCaseInsensitiveUUID() throws {
        let message = try XCTUnwrap(MobileChallengeMessage.decode(tokenMessage, for: try attempt()))
        XCTAssertEqual(message.event, .token)
        XCTAssertEqual(message.token, "synthetic-challenge-token")
    }

    func testOldAttemptOtherActionAndUnknownVersionCannotCompleteTheCurrentForm() throws {
        let invalid: [(String, Any)] = [("attempt", "123e4567-e89b-42d3-a456-426614174001"),
                                          ("action", "password-reset"), ("version", 2), ("version", true),
                                          ("event", "verified"), ("unexpected", "field")]
        for (key, wrong) in invalid {
            var body = tokenMessage
            body[key] = wrong
            XCTAssertNil(MobileChallengeMessage.decode(body, for: try attempt()), key)
        }
    }

    func testMalformedEmptyOversizedAndMisplacedTokensAreRejected() throws {
        for invalid: Any in ["", " whitespace ", String(repeating: "x", count: 2049), 42, ["not": "a token"]] {
            var body = tokenMessage; body["token"] = invalid
            XCTAssertNil(MobileChallengeMessage.decode(body, for: try attempt()))
        }
        var misplaced = tokenMessage; misplaced["event"] = "disabled"
        XCTAssertNil(MobileChallengeMessage.decode(misplaced, for: try attempt()))
        misplaced.removeValue(forKey: "token")
        XCTAssertEqual(MobileChallengeMessage.decode(misplaced, for: try attempt())?.event, .disabled)
    }

    func testProofIsConsumedOnceAndRedactedWhenDescribed() throws {
        let proof = MobileChallengeProof(action: .signup, token: "synthetic-once", issuedAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(String(describing: proof).contains("synthetic-once"))
        XCTAssertFalse(String(reflecting: proof).contains("synthetic-once"))
        XCTAssertEqual(try proof.consume(for: .signup, now: Date(timeIntervalSince1970: 101)), "synthetic-once")
        XCTAssertThrowsError(try proof.consume(for: .signup, now: Date(timeIntervalSince1970: 102)))
    }

    func testExpiredOrWrongActionProofCannotBeReused() {
        let issued = Date(timeIntervalSince1970: 100)
        let expired = MobileChallengeProof(action: .signup, token: "synthetic-expired", issuedAt: issued)
        XCTAssertThrowsError(try expired.consume(for: .signup, now: Date(timeIntervalSince1970: 400)))
        XCTAssertThrowsError(try expired.consume(for: .signup, now: Date(timeIntervalSince1970: 101)))
        let wrong = MobileChallengeProof(action: .signup, token: "synthetic-wrong", issuedAt: issued)
        XCTAssertThrowsError(try wrong.consume(for: .passwordReset, now: Date(timeIntervalSince1970: 101)))
        XCTAssertThrowsError(try wrong.consume(for: .signup, now: Date(timeIntervalSince1970: 101)))
    }

    func testConcurrentConsumersCannotReplayTheSameToken() async {
        let proof = MobileChallengeProof(action: .signup, token: "synthetic-concurrent")
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 { group.addTask { (try? proof.consume(for: .signup)) == "synthetic-concurrent" } }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
    }
}

@MainActor
final class MobileChallengePresenterTests: XCTestCase {
    func testWebKitNavigationPoliciesAreRegisteredAsObjectiveCDelegateMethods() throws {
        let attempt = try MobileChallengeAttempt(origin: URL(string: "https://app.example.invalid")!,
            action: .signup, language: "en", theme: "light")
        let coordinator = MobileChallengeWebView.Coordinator(attempt: attempt, onCompletion: { _ in })
        // Regression: a closure missing @MainActor compiled with a near-match
        // warning, so these optional ObjC methods were never invoked by WebKit.
        XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
    }

    private func pending(_ presenter: MobileChallengePresenter) async throws -> MobileChallengeAttempt {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while presenter.attempt == nil, ContinuousClock.now < deadline { await Task.yield() }
        return try XCTUnwrap(presenter.attempt)
    }

    private func request(_ presenter: MobileChallengePresenter) -> Task<MobileChallengeProof, Error> {
        Task {
            try await presenter.request(origin: URL(string: "https://app.example.invalid")!,
                                        action: .signup, language: "en", theme: "light")
        }
    }

    func testCancellationResumesTheCallerAndAllowsANewAttemptAfterDismissal() async throws {
        let presenter = MobileChallengePresenter()
        let task = request(presenter)
        _ = try await pending(presenter)
        presenter.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail the awaiting operation") }
        catch { XCTAssertEqual(error as? MobileChallengeError, .cancelled) }
        XCTAssertNil(presenter.attempt)
        XCTAssertTrue(presenter.isDismissing)
        presenter.didDismiss()
        let next = request(presenter)
        let attempt = try await pending(presenter)
        presenter.complete(id: attempt.id, result: .success(MobileChallengeProof(action: .signup, token: "synthetic-second")))
        let proof = try await next.value
        XCTAssertEqual(try proof.consume(for: .signup), "synthetic-second")
        presenter.didDismiss()
        XCTAssertFalse(presenter.isBusy)
    }

    func testOldCompletionCannotFulfilAnotherAttempt() async throws {
        let presenter = MobileChallengePresenter()
        let first = request(presenter)
        let old = try await pending(presenter)
        presenter.cancel()
        _ = try? await first.value
        presenter.didDismiss()
        let next = request(presenter)
        let current = try await pending(presenter)
        XCTAssertNotEqual(old.id, current.id)
        presenter.complete(id: old.id, result: .success(MobileChallengeProof(action: .signup, token: "synthetic-old")))
        XCTAssertEqual(presenter.attempt?.id, current.id)
        presenter.complete(id: current.id, result: .success(MobileChallengeProof(action: .signup, token: "synthetic-current")))
        let proof = try await next.value
        XCTAssertEqual(try proof.consume(for: .signup), "synthetic-current")
        presenter.didDismiss()
    }

    func testCancellingTheTaskCancelsItsPresentation() async throws {
        let presenter = MobileChallengePresenter()
        let task = request(presenter)
        _ = try await pending(presenter)
        task.cancel()
        do { _ = try await task.value; XCTFail("The cancelled form cannot receive a proof") } catch {}
        XCTAssertNil(presenter.attempt)
        presenter.didDismiss()
    }

    func testAChangedSessionRejectsTheProofBeforeSendingAForm() async throws {
        let service = MockAuthService()
        service.meResult = .failure(APIError.http(status: 401, code: nil, message: "synthetic-unauthenticated", requestId: nil, retryAfter: nil))
        let session = AuthSessionViewModel(service: service)
        await session.bootstrap()
        let context = try session.beginPublicForm()
        let proof = MobileChallengeProof(action: .signup, token: "synthetic-unused")
        session.enterDemoMode()
        await session.signup(email: "synthetic@example.invalid", password: "synthetic-password", name: "Test",
                             acceptedTerms: true, proof: proof, context: context)
        XCTAssertEqual(session.state, .authenticated(.mock))
        XCTAssertEqual(try proof.consume(for: .signup), "synthetic-unused")
        XCTAssertNil(session.errorMessage)
    }
}
