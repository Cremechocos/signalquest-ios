import Foundation
import XCTest
@testable import SignalQuest

/// Optional real transport check against the persistent, synthetic PRE-02 stack.
/// No request is sent unless an explicit local recipe fixture is supplied.
@MainActor
final class RecipeBackendPersistenceTests: XCTestCase {
    private struct Fixture: Decodable {
        let baseURL: URL
        let token: String
        let expectedUserID: String
        let bio: String
    }
    private struct ProfileResponse: Decodable {
        struct User: Decodable { let id: String; let bio: String? }
        let user: User
    }

    func testSignedStagingHostPersistsProfileThroughRealAPI() async throws {
        let fixturePath = ProcessInfo.processInfo.environment["SQ_RECIPE_FIXTURE"]
        try XCTSkipIf(fixturePath == nil, "Requires the isolated PRE-02 stack and SQ_RECIPE_FIXTURE")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: try XCTUnwrap(fixturePath))))
        let expectedURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49141"))
        XCTAssertEqual(fixture.baseURL, expectedURL)
        guard fixture.baseURL == expectedURL, fixture.expectedUserID == "ios_recipe_user_a" else {
            XCTFail("Refusing non-recipe fixture")
            return
        }
        // This also proves the signed app contains the dedicated URLs.
        XCTAssertEqual(AppConfig.current.environment, .staging)
        XCTAssertEqual(AppConfig.current.apiBaseURL, expectedURL)
        XCTAssertEqual(AppConfig.current.appBaseURL, expectedURL)
        guard AppConfig.current.environment == .staging,
              AppConfig.current.apiBaseURL == expectedURL,
              AppConfig.current.appBaseURL == expectedURL else { return }
        let keychain = KeychainStore(service: "fr.signalquest.ios.qa.recipe")
        try keychain.removeAll()
        defer { try? keychain.removeAll() }
        let credentials = CredentialStore(tokenStore: keychain)
        try credentials.setAccessToken(fixture.token)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let api = APIClient(config: AppConfig.current, credentials: credentials, session: session)
        let before = try await api.request(APIEndpoint(path: "/api/user/profile"), as: ProfileResponse.self)
        XCTAssertEqual(before.user.id, fixture.expectedUserID)
        guard before.user.id == fixture.expectedUserID else { return }
        try await api.request(APIEndpoint(path: "/api/user/profile", method: .put,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(["bio": fixture.bio])))
        let after = try await api.request(APIEndpoint(path: "/api/user/profile"), as: ProfileResponse.self)
        XCTAssertEqual(after.user.id, fixture.expectedUserID)
        XCTAssertEqual(after.user.bio, fixture.bio)
    }
}
