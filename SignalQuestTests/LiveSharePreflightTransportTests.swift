import XCTest
@testable import SignalQuest

final class LiveSharePreflightTransportTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    private func client(_ fixture: LivePreflightFixture) throws -> (APIClient, CredentialStore) {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-live-a")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = fixture.response
        return (APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config)), credentials)
    }

    func test503DoesNotRetryCoordinatesThatExpiredDuringBackoff() async throws {
        let fixture = LivePreflightFixture(mode: .unavailable)
        let (api, credentials) = try client(fixture)
        do {
            _ = try await api.request(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { try fixture.validate() }), as: LivePreflightResponse.self,
                expectedSessionID: credentials.snapshot().sessionID)
            XCTFail("Expired coordinates replayed")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 1)
        XCTAssertEqual(fixture.validations, 2)
    }

    func testRefreshCanFinishButCannotReplayCoordinatesExpiredWhileItWasSuspended() async throws {
        let fixture = LivePreflightFixture(mode: .refresh)
        let (api, credentials) = try client(fixture)
        let refreshEntered = expectation(description: "Refresh entered")
        fixture.onRefresh = { refreshEntered.fulfill() }
        let original = credentials.snapshot().sessionID
        let sending = Task {
            try await api.request(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { try fixture.validate() }), as: LivePreflightResponse.self,
                expectedSessionID: original)
        }
        await fulfillment(of: [refreshEntered], timeout: 2)
        fixture.expire()
        fixture.allowRefresh.signal()
        do { _ = try await sending.value; XCTFail("Refresh replayed an expired fix") }
        catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 1)
        XCTAssertEqual(fixture.refreshRequests, 1)
        XCTAssertEqual(credentials.snapshot().sessionID, original, "A successful refresh keeps the session")
    }

    func testPreflightHTTPErrorIsNotClassifiedAsRetryableTransport() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, _) = try client(fixture)
        do {
            _ = try await api.request(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { throw APIError.http(status: 503, code: nil, message: "Local rejection", requestId: nil, retryAfter: 0) }),
                as: LivePreflightResponse.self)
            XCTFail("Rejected admission reached HTTP")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
    }

    func testAccountSwitchInsideAdmissionCannotSendWithNewCredentials() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, credentials) = try client(fixture)
        do {
            _ = try await api.requestData(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { try credentials.setAccessToken("synthetic-live-b") }),
                expectedSessionID: credentials.snapshot().sessionID)
            XCTFail("Admission crossed accounts")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
    }
    func testSingleAttemptRejectsPublicationBeforeAnyTransport() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, _) = try client(fixture)
        fixture.expire()
        do {
            _ = try await api.performSingleAttempt(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { try fixture.validate() }))
            XCTFail("Rejected single attempt reached HTTP")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
        XCTAssertEqual(fixture.validations, 1)
    }

    func testFileUploadRejectsPublicationBeforeReadingOrSendingTheFile() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, _) = try client(fixture)
        fixture.expire()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("admission-\(UUID()).bin")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await api.uploadFileSingleAttempt(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { try fixture.validate() }), fromFile: file)
            XCTFail("Rejected file reached HTTP")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
        XCTAssertEqual(fixture.validations, 1)
    }

    func testAdmittedRequestStillReachesTransport() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, _) = try client(fixture)
        let result = try await api.request(APIEndpoint(path: "/api/live-publication", method: .post,
            validateBeforeSend: { try fixture.validate() }), as: LivePreflightResponse.self)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(fixture.resourceRequests, 1)
        XCTAssertEqual(fixture.validations, 1)
    }

    func testAccountSwitchWhileAdmissionIsSuspendedCannotReachTransport() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, credentials) = try client(fixture)
        let entered = expectation(description: "Admission suspended")
        let pause = LiveAdmissionPause()
        let sending = Task {
            try await api.performSingleAttempt(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { await pause.wait { entered.fulfill() } }))
        }
        await fulfillment(of: [entered], timeout: 2)
        try credentials.setAccessToken("synthetic-live-b")
        await pause.release()
        do { _ = try await sending.value; XCTFail("Suspended admission crossed accounts") }
        catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
    }

    func testCancellationWhileAdmissionIsSuspendedKeepsThePublicCancellationError() async throws {
        let fixture = LivePreflightFixture(mode: .success)
        let (api, _) = try client(fixture)
        let entered = expectation(description: "Admission suspended")
        let pause = LiveAdmissionPause()
        let sending = Task {
            try await api.performSingleAttempt(APIEndpoint(path: "/api/live-publication", method: .post,
                validateBeforeSend: { await pause.wait { entered.fulfill() } }))
        }
        await fulfillment(of: [entered], timeout: 2)
        sending.cancel()
        await pause.release()
        do { _ = try await sending.value; XCTFail("Cancelled admission reached HTTP") }
        catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.resourceRequests, 0)
    }

}

private enum LivePreflightFailure: Error { case expired }

private struct LivePreflightResponse: Decodable { let ok: Bool }

private final class LivePreflightFixture: @unchecked Sendable {
    enum Mode { case success, unavailable, refresh }
    let mode: Mode
    let allowRefresh = DispatchSemaphore(value: 0)
    var onRefresh: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var resourceCount = 0
    private var refreshCount = 0
    private var validationCount = 0
    private var expired = false
    init(mode: Mode) { self.mode = mode }
    var resourceRequests: Int { lock.withLock { resourceCount } }
    var refreshRequests: Int { lock.withLock { refreshCount } }
    var validations: Int { lock.withLock { validationCount } }
    func expire() { lock.withLock { expired = true } }
    func validate() throws {
        let rejected = lock.withLock { validationCount += 1; return expired }
        if rejected { throw LivePreflightFailure.expired }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        if url.path == "/api/auth/refresh" {
            lock.withLock { refreshCount += 1 }
            onRefresh?()
            guard allowRefresh.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie":"auth_token=synthetic-live-refreshed; Path=/; HttpOnly"])!, Data("{\"ok\":true}".utf8))
        }
        guard url.path == "/api/live-publication" else { throw URLError(.unsupportedURL) }
        lock.withLock { resourceCount += 1 }
        switch mode {
        case .success:
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"ok\":true}".utf8))
        case .unavailable:
            expire()
            return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After":"0"])!, Data("{\"error\":\"unavailable\"}".utf8))
        case .refresh:
            return (HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{\"error\":\"expired\"}".utf8))
        }
    }
}

private actor LiveAdmissionPause {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(entered: @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
