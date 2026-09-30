import XCTest
@testable import SignalQuest

/// Plan 3, vague 1, sur les conseils de l'audit serveur du 30/09 : départ
/// d'appel par la route commune aux trois plateformes, et User-Agent versionné
/// que les gardes du serveur reconnaissent.
final class CallLeaveAndUserAgentTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testUserAgentCarriesVersionBuildAndSystem() {
        let agent = APIClient.userAgent
        let format = #"^SignalQuest-iOS/[0-9][^ ]* \([0-9]+; iOS [0-9]+\.[0-9]+(\.[0-9]+)?\)$"#
        XCTAssertNotNil(agent.range(of: format, options: .regularExpression), agent)
        // Garde d'écriture du serveur : `/\bSignalQuest-iOS\b/i`.
        XCTAssertNotNil(agent.range(of: #"\bSignalQuest-iOS\b"#, options: [.regularExpression, .caseInsensitive]))
    }

    func testLeavingACallUsesTheSharedLeaveRoute() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("call-leave-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let service = CallsService(api: api)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/calls/leave")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), APIClient.userAgent)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            // Second départ : le serveur répond 200 avec `alreadyClosed`.
            return (response, Data(#"""
            {"success":true,"alreadyClosed":true,"status":"ENDED","joinedCount":0,"ringingCount":0,"duration":null}
            """#.utf8))
        }
        try await service.end(callId: "call_1234567890123456")
    }
}
