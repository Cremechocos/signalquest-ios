import XCTest
@testable import SignalQuest

final class TwoFactorEnrollmentServiceTests: XCTestCase {
    private let secret = "JBSWY3DPEHPK3PXP"

    func testSetupKeepsServerSecretURIAndExpiryAndCanRetryARecoverableFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.recorder.replies = [.init(status: 503, json: "{}"), .init(json:
            "{\"secret\":\"\(secret)\",\"uri\":\"otpauth://totp/SignalQuest:test?secret=\(secret)\",\"expiresAt\":\"2030-01-01T00:00:00.000Z\"}")]
        do { _ = try await fixture.service.setup(); XCTFail("503 must fail") } catch {}
        XCTAssertEqual(fixture.recorder.requests.count, 1, "A setup rotation is not replayed opaquely")
        let setup = try await fixture.service.setup()
        XCTAssertEqual(setup.secret, secret)
        XCTAssertEqual(setup.uri, "otpauth://totp/SignalQuest:test?secret=\(secret)")
        XCTAssertNotNil(setup.expiresAt)
        XCTAssertEqual(fixture.recorder.requests.count, 2)
    }

    func testInvalidOrMissingSecretCannotBecomeAReadyConfiguration() async throws {
        for json in ["{}", "{\"secret\":\"\"}", "{\"secret\":\"not a base32 secret\"}"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.recorder.replies = [.init(json: json)]
            do { _ = try await fixture.service.setup(); XCTFail("Invalid secret") }
            catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .invalidSetup) }
        }
    }

    func testConfirmationRequiresExplicitNonContradictoryAcknowledgement() async throws {
        for json in ["{}", "{\"ok\":false}", "{\"success\":false}", "{\"ok\":true,\"success\":false}", ""] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.recorder.replies = [.init(json: json)]
            do { try await fixture.service.confirm(secret: secret, code: "123456"); XCTFail("No confirmed activation") }
            catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .unconfirmedResponse) }
        }
        for json in ["{\"ok\":true}", "{\"success\":true}"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.recorder.replies = [.init(json: json)]
            try await fixture.service.confirm(secret: secret, code: "123456")
            let request = try XCTUnwrap(fixture.recorder.requests.first)
            let body = try JSONDecoder().decode(TwoFactorVerifySetupRequest.self, from: request.body)
            XCTAssertEqual(body.secret, secret)
            XCTAssertEqual(body.code, "123456")
            XCTAssertEqual(request.path, "/api/auth/2fa/verify-setup")
        }
    }

    func testFailedConfirmationDoesNotReplayAConsumedTOTPOrRefreshAndResend() async throws {
        for status in [401, 429, 503] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.recorder.replies = [.init(status: status, json: "{}", headers: ["Retry-After": "0"])]
            do { try await fixture.service.confirm(secret: secret, code: "123456"); XCTFail("Expected failure") } catch {}
            XCTAssertEqual(fixture.recorder.requests.map(\.path), ["/api/auth/2fa/verify-setup"])
        }
    }

    func testMalformedCodeNeverLeavesTheDeviceAndServerRejectionsRemainDistinct() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for code in ["", "12345", "1234567", "１２３４５６", "abcdef"] {
            do { try await fixture.service.confirm(secret: secret, code: code); XCTFail("Malformed code") }
            catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .invalidCode) }
        }
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        for (code, expected) in [
            ("INVALID_2FA_CODE", TwoFactorEnrollmentError.invalidCode),
            ("TWO_FACTOR_SETUP_EXPIRED", .expiredSetup),
            ("INVALID_2FA_SETUP", .replacedSetup),
            ("TWO_FACTOR_ALREADY_ENABLED", .alreadyEnabled),
        ] {
            fixture.recorder.replies = [.init(status: 400, json: "{\"code\":\"\(code)\"}")]
            do { try await fixture.service.confirm(secret: secret, code: "123456"); XCTFail("Expected server rejection") }
            catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, expected) }
        }
    }

    func testChangedAccountOrHTTPGenerationPreventsSetupConfirmAndProfileRequests() async throws {
        for changeCredentials in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            if changeCredentials { try fixture.credentials.setAccessToken(fixture.tokenB) }
            else { fixture.account.set(LocalAccountSession(ownerScopeId: "user:b", sessionId: UUID().uuidString)) }
            XCTAssertFalse(fixture.service.isCurrent())
            do { _ = try await fixture.service.setup(); XCTFail("Old setup") } catch {}
            do { try await fixture.service.confirm(secret: secret, code: "123456"); XCTFail("Old confirmation") } catch {}
            do { _ = try await fixture.service.profile(); XCTFail("Old profile") } catch {}
            XCTAssertTrue(fixture.recorder.requests.isEmpty)
        }
    }

    func testLateConfirmationResponseCannotConfirmTheNewConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let started = expectation(description: "confirmation entered")
        let release = DispatchSemaphore(value: 0)
        fixture.recorder.handler = { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return .init(json: "{\"ok\":true}")
        }
        let secret = secret
        let task = Task { try await fixture.service.confirm(secret: secret, code: "123456") }
        await fulfillment(of: [started], timeout: 2)
        try fixture.credentials.setAccessToken(fixture.tokenB)
        release.signal()
        do { try await task.value; XCTFail("A's ack cannot confirm B") } catch {}
        XCTAssertEqual(fixture.recorder.requests.count, 1)
    }

    func testProfileResponseMustBelongToTheCapturedUser() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.recorder.replies = [.init(json: "{\"user\":{\"id\":\"b\",\"email\":\"b@local.test\",\"role\":\"user\"}}")]
        do { _ = try await fixture.service.profile(); XCTFail("Foreign profile") }
        catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .sessionChanged) }
    }

    func testSingleAttemptRejectsAnAdmissionFailureBeforeAnyTransport() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        do {
            _ = try await fixture.api.performSingleAttempt(APIEndpoint(path: "/synthetic", method: .post,
                validateBeforeSend: { throw TwoFactorEnrollmentError.sessionChanged }),
                expectedCredentialSessionID: fixture.service.scope.credentialSessionID)
            XCTFail("Rejected admission")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
    }

    func testSingleAttemptRechecksOwnerAfterSuspendedAdmissionWithoutChangingSignedBody() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let gate = EnrollmentAdmissionGate()
        let task = Task {
            try await fixture.api.performSingleAttempt(APIEndpoint(path: "/synthetic", method: .post,
                body: Data("unchanged-signed-body".utf8), validateBeforeSend: { await gate.wait() }),
                expectedCredentialSessionID: fixture.service.scope.credentialSessionID)
        }
        await gate.waitUntilEntered()
        try fixture.credentials.setAccessToken(fixture.tokenB)
        await gate.open()
        do { _ = try await task.value; XCTFail("Old connection") } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertTrue(fixture.recorder.requests.isEmpty)

        let body = Data("exact-signed-body".utf8)
        _ = try await fixture.api.performSingleAttempt(APIEndpoint(path: "/synthetic", method: .post,
            headers: ["X-Synthetic-Signature": "unchanged"], body: body, validateBeforeSend: {}),
            expectedCredentialSessionID: fixture.credentials.snapshot().sessionID)
        XCTAssertEqual(fixture.recorder.requests.last?.body, body)
        XCTAssertEqual(fixture.recorder.requests.last?.signature, "unchanged")
    }

    func testOpeningCannotBindAccountAToCredentialsForAccountB() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.credentials.setAccessToken(fixture.tokenB)
        XCTAssertNil(TwoFactorEnrollmentService(api: fixture.api, userID: "a", accountSnapshot: fixture.account.snapshot))
    }

    func testDisableUsesCapturedOwnerRejectsMalformedCodeAndRequiresAcknowledgement() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        do { try await fixture.service.disable(code: "bad"); XCTFail("Malformed code") } catch {}
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        fixture.recorder.replies = [.init(json: "{}")]
        do { try await fixture.service.disable(code: "123456"); XCTFail("Missing receipt") } catch {}
        fixture.recorder.replies = [.init(json: "{\"ok\":true}")]
        try await fixture.service.disable(code: "123456")
        XCTAssertEqual(fixture.recorder.requests.map(\.path), Array(repeating: "/api/auth/2fa/disable", count: 2))
        try fixture.credentials.setAccessToken(fixture.tokenB)
        do { try await fixture.service.disable(code: "123456"); XCTFail("Wrong account") } catch {}
        XCTAssertEqual(fixture.recorder.requests.count, 2)
    }

    func testDisableNeverAutomaticallyReplaysAfterAmbiguousFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.recorder.replies = [.init(status: 503, json: "{}", headers: ["Retry-After": "0"])]
        do { try await fixture.service.disable(code: "123456"); XCTFail("Failure expected") } catch {}
        XCTAssertEqual(fixture.recorder.requests.count, 1)
    }

    private final class Fixture: @unchecked Sendable {
        let tokenA = Fixture.token(userID: "a")
        let tokenB = Fixture.token(userID: "b")
        private static func token(userID: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["userId": userID,
                "exp": Int(Date().timeIntervalSince1970) + 3600, "jti": UUID().uuidString])
            let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "synthetic.\(payload).signature"
        }
        let credentials = CredentialStore(tokenStore: EnrollmentTokenStore())
        let account = EnrollmentAccountBox(LocalAccountSession(ownerScopeId: "user:a", sessionId: UUID().uuidString))
        let recorder = EnrollmentHTTPRecorder()
        let session: URLSession
        let api: APIClient
        let service: TwoFactorEnrollmentService

        init() throws {
            try credentials.setAccessToken(tokenA)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EnrollmentURLProtocol.self]
            session = URLSession(configuration: configuration)
            api = APIClient(config: .test, credentials: credentials, session: session)
            service = try XCTUnwrap(TwoFactorEnrollmentService(api: api, userID: "a", accountSnapshot: account.snapshot))
            EnrollmentURLProtocol.register(tokenA, recorder: recorder)
            EnrollmentURLProtocol.register(tokenB, recorder: recorder)
        }

        func close() {
            credentials.clearAccessToken()
            session.invalidateAndCancel()
            EnrollmentURLProtocol.unregister(tokenA)
            EnrollmentURLProtocol.unregister(tokenB)
        }
    }
}

private final class EnrollmentAccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalAccountSession?
    init(_ value: LocalAccountSession?) { self.value = value }
    func snapshot() -> LocalAccountSession? { lock.withLock { value } }
    func set(_ value: LocalAccountSession?) { lock.withLock { self.value = value } }
}

private final class EnrollmentTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for key: String) throws -> String? { lock.withLock { values[key] } }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { lock.withLock { values[key] = value } }
    func remove(_ key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
    func removeAll() throws { lock.withLock { values.removeAll() } }
}

private struct EnrollmentHTTPReply: Sendable {
    var status = 200
    var json = "{}"
    var headers: [String: String] = [:]
}

private final class EnrollmentHTTPRecorder: @unchecked Sendable {
    struct Request: Sendable { let path: String; let body: Data; let signature: String? }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var pendingReplies: [EnrollmentHTTPReply] = []
    private var callback: (@Sendable (URLRequest) throws -> EnrollmentHTTPReply)?
    var requests: [Request] { lock.withLock { recorded } }
    var replies: [EnrollmentHTTPReply] {
        get { lock.withLock { pendingReplies } }
        set { lock.withLock { pendingReplies = newValue } }
    }
    var handler: (@Sendable (URLRequest) throws -> EnrollmentHTTPReply)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    func respond(_ request: URLRequest) throws -> EnrollmentHTTPReply {
        let body = try requestBody(request)
        let (handler, reply) = lock.withLock {
            recorded.append(Request(path: request.url?.path ?? "", body: body, signature: request.value(forHTTPHeaderField: "X-Synthetic-Signature")))
            return (callback, pendingReplies.isEmpty ? EnrollmentHTTPReply() : pendingReplies.removeFirst())
        }
        return try handler?(request) ?? reply
    }
    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}

private final class EnrollmentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders: [String: EnrollmentHTTPRecorder] = [:]
    static func register(_ token: String, recorder: EnrollmentHTTPRecorder) { lock.withLock { recorders[token] = recorder } }
    static func unregister(_ token: String) { lock.withLock { _ = recorders.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Cookie")?.replacingOccurrences(of: "auth_token=", with: "") ?? ""
        let recorder = Self.lock.withLock { Self.recorders[token] }
        guard let recorder, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        do {
            let reply = try recorder.respond(request)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor EnrollmentAdmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; enteredWaiter?.resume(); enteredWaiter = nil }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}
