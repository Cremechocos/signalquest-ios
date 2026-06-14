import XCTest
@testable import SignalQuest

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDecodesSuccessAndStoresAuthCookie() async throws {
        let session = Self.mockSession()
        let cookieStore = AuthCookieStore(tokenStore: InMemoryTokenStore())
        let client = APIClient(config: .test, cookieStore: cookieStore, session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), nil)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=abc123; Path=/; HttpOnly"]
            )!
            return (response, Data(#"{"success":true,"requestId":"req-ok"}"#.utf8))
        }

        let response = try await client.request(APIEndpoint(path: "/api/auth/refresh", method: .post), as: SuccessResponse.self)
        XCTAssertEqual(response.success, true)
        XCTAssertEqual(cookieStore.cookieHeader(), "auth_token=abc123")
    }

    func testDecodesBackendErrorRequestIdAndRetryAfter() async {
        let client = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "42", "X-Request-Id": "header-id"]
            )!
            return (response, Data(#"{"error":"Too many requests","code":"RATE_LIMIT","requestId":"body-id"}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/test"), as: SuccessResponse.self)
            XCTFail("Expected APIError")
        } catch let error as APIError {
            if case .http(let status, let code, let message, let requestId, let retryAfter) = error {
                XCTAssertEqual(status, 429)
                XCTAssertEqual(code, "RATE_LIMIT")
                XCTAssertEqual(message, "Too many requests")
                XCTAssertEqual(requestId, "body-id")
                XCTAssertEqual(retryAfter, 42)
            } else {
                XCTFail("Unexpected error \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Sprint 1 : idempotence & throttling (429/503)

    /// Un POST porte une clé d'idempotence et REJOUE la même clé après un
    /// refresh 401, pour qu'un retry transparent ne crée pas de doublon.
    func testPostReusesIdempotencyKeyAcrossRefreshRetry() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("stale")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())

        var createKeys: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/auth/refresh") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Set-Cookie": "auth_token=fresh; Path=/; HttpOnly"]
                )!
                return (response, Data(#"{"success":true}"#.utf8))
            }
            createKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "<none>")
            if createKeys.count == 1 {
                let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (r, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }

        let _: SuccessResponse = try await client.requestJSON("/api/social/v2/posts", body: ["text": "hi"])
        XCTAssertEqual(createKeys.count, 2, "Le POST doit être rejoué une fois après refresh")
        XCTAssertNotEqual(createKeys.first, "<none>", "Un POST doit porter une clé d'idempotence")
        XCTAssertEqual(createKeys[0], createKeys[1], "La même clé doit être renvoyée sur le rejeu post-refresh")
    }

    /// Un GET ne doit pas porter de clé d'idempotence.
    func testGetCarriesNoIdempotencyKey() async throws {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hadKey = true
        MockURLProtocol.requestHandler = { request in
            hadKey = request.value(forHTTPHeaderField: "Idempotency-Key") != nil
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }
        let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
        XCTAssertFalse(hadKey)
    }

    /// Un 429 sans Retry-After déclenche un seul rejeu après un court backoff,
    /// puis réussit.
    func testThrottleRetriesOnceThenSucceeds() async throws {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hits = 0
        MockURLProtocol.requestHandler = { request in
            hits += 1
            let status = hits == 1 ? 429 : 200
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }
        let resp: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
        XCTAssertEqual(resp.success, true)
        XCTAssertEqual(hits, 2)
    }

    /// Un Retry-After long ne doit PAS bloquer l'appel : on remonte l'erreur sans rejeu.
    func testThrottleDoesNotRetryOnLongRetryAfter() async {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hits = 0
        MockURLProtocol.requestHandler = { request in
            hits += 1
            let r = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "42"])!
            return (r, Data(#"{"error":"slow down"}"#.utf8))
        }
        do {
            let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
            XCTFail("Expected throttling error")
        } catch {
            XCTAssertEqual(hits, 1, "Un Retry-After long doit remonter immédiatement, sans rejeu automatique")
        }
    }

    func testThrottleDelayHonorsShortRetryAfterAndCapsLong() {
        XCTAssertEqual(APIClient.throttleDelaySeconds(retryAfter: 2, attempt: 0), 2.0)
        XCTAssertNil(APIClient.throttleDelaySeconds(retryAfter: 42, attempt: 0))
        let backoff = try? XCTUnwrap(APIClient.throttleDelaySeconds(retryAfter: nil, attempt: 0))
        XCTAssertNotNil(backoff)
        XCTAssertLessThanOrEqual(backoff ?? 99, APIClient.maxAutoRetryDelaySeconds)
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
