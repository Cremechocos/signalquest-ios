import XCTest
@testable import SignalQuest

/// E.1 (v0.4.20) : une session révoquée avec son appareil v2 répond 401 avec
/// `details.reason` à `E2EE_DEVICE_REVOKED`, y compris sur le refresh. L'app
/// le signale pour effacer le coffre v2 de ce compte ; un autre 401 non.
final class E2EEDeviceRevocationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func api() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("revocation-test-token")
        return APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
    }

    private func respond(_ body: String) {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
             Data(body.utf8))
        }
    }

    func testARevokedDeviceSessionIsSignaledWithTheLocalSession() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let client = try api()
        respond(#"{"error":"Session révoquée","code":"UNAUTHORIZED","details":{"reason":"E2EE_DEVICE_REVOKED"}}"#)
        let signaled = expectation(forNotification: .sqE2EEDeviceRevoked, object: nil) { notification in
            (notification.object as? LocalAccountSession) == fixture.session
        }
        signaled.assertForOverFulfill = false
        _ = try? await client.request(APIEndpoint(path: "/api/user/profile"), as: JSONValue.self)
        await fulfillment(of: [signaled], timeout: 2)
    }

    func testAnOrdinary401IsNotADeviceRevocation() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let client = try api()
        respond(#"{"error":"Non authentifié","code":"UNAUTHORIZED"}"#)
        let signaled = expectation(forNotification: .sqE2EEDeviceRevoked, object: nil)
        signaled.isInverted = true
        _ = try? await client.request(APIEndpoint(path: "/api/user/profile"), as: JSONValue.self)
        await fulfillment(of: [signaled], timeout: 0.5)
    }
}
