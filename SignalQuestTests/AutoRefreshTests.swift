import XCTest
@testable import SignalQuest

final class AutoRefreshTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// On a 401, the client should call `/api/auth/refresh` once and retry the
    /// original request transparently.
    func testRetriesOnceAfterRefresh() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("stale")
        let client = APIClient(config: .test, credentials: credentials, session: mockSession())

        var hits: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            hits.append(path)
            if path.contains("/api/auth/refresh") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Set-Cookie": "auth_token=fresh; Path=/; HttpOnly"]
                )!
                return (response, Data(#"{"success":true}"#.utf8))
            }
            if hits.filter({ $0 == "/api/auth/me" }).count == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"unauthorized","code":"UNAUTHORIZED"}"#.utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"user":{"id":"u","email":"u@x","name":"U","role":"user"}}"#.utf8))
        }

        let response: AuthMeResponse = try await client.request(
            APIEndpoint(path: "/api/auth/me"),
            as: AuthMeResponse.self
        )
        XCTAssertEqual(response.user?.id, "u")
        XCTAssertEqual(credentials.accessToken(), "fresh")
        XCTAssertEqual(hits.filter { $0 == "/api/auth/me" }.count, 2)
        XCTAssertEqual(hits.filter { $0.contains("/api/auth/refresh") }.count, 1)
    }

    /// The refresh endpoint itself MUST NOT loop into auto-refresh.
    func testRefreshDoesNotRetryItself() async {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let client = APIClient(config: .test, credentials: credentials, session: mockSession())

        var refreshHits = 0
        MockURLProtocol.requestHandler = { request in
            refreshHits += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"nope"}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(
                APIEndpoint(path: "/api/auth/refresh", method: .post, skipsAutoRefresh: true),
                as: SuccessResponse.self
            )
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(refreshHits, 1)
        }
    }
}
