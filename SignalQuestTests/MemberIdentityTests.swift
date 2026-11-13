import XCTest
@testable import SignalQuest

/// Identité membre v1 : normalisation du nom d'utilisateur sur les vecteurs du serveur, et
/// repli d'affichage commun (nom affiché, sinon @nom d'utilisateur, sinon « Quelqu'un »).
final class MemberIdentityTests: XCTestCase {
    private struct Vector: Decodable {
        let input: String
        let normalized: String
        let valid: Bool
    }

    private func vectors() throws -> [Vector] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "user-handle-vectors", withExtension: "json")
            ?? bundle.url(forResource: "user-handle-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    func testSharedHandleVectors() throws {
        let cases = try vectors()
        XCTAssertEqual(cases.count, 28)
        for vector in cases {
            let normalized = UserHandle.normalize(vector.input)
            XCTAssertEqual(normalized, vector.normalized, vector.input)
            XCTAssertEqual(UserHandle.isValid(normalized: normalized), vector.valid, vector.input)
            // La forme normalisée est un point fixe, comme côté serveur.
            XCTAssertEqual(UserHandle.normalize(vector.normalized), vector.normalized, vector.input)
        }
    }

    func testCutAtThirtyTwoThenTrailingSeparatorsRemoved() {
        let input = String(repeating: "a", count: 31) + "-b"
        XCTAssertEqual(UserHandle.normalize(input), String(repeating: "a", count: 31))
    }

    func testDisplayNameFallback() {
        XCTAssertEqual(MemberIdentity.displayName("Alexandre G.", handle: "alex38"), "Alexandre G.")
        XCTAssertEqual(MemberIdentity.displayName("  ", handle: "alex38"), "@alex38")
        XCTAssertEqual(MemberIdentity.displayName(nil, handle: "@alex38"), "@alex38")
        XCTAssertEqual(MemberIdentity.displayName(nil, handle: ""), MemberIdentity.someone)
        XCTAssertNil(MemberIdentity.name(nil, handle: nil))
    }

    func testMessageUserNeverShowsTheEmail() throws {
        let json = #"{"id":"u1","name":null,"email":"synthetic@example.invalid","avatarUrl":null}"#
        let user = try JSONDecoder().decode(MessageUser.self, from: Data(json.utf8))
        XCTAssertNil(user.knownName)
        XCTAssertEqual(user.displayName, MemberIdentity.someone)
        let withHandle = try JSONDecoder().decode(MessageUser.self, from: Data(
            #"{"id":"u1","name":"","handle":"alex38","email":"synthetic@example.invalid"}"#.utf8))
        XCTAssertEqual(withHandle.displayName, "@alex38")
    }

    func testOwnAccountNeverFallsBackToTheEmail() throws {
        let user = try JSONDecoder().decode(AuthUser.self, from: Data(
            #"{"id":"u1","email":"synthetic@example.invalid","name":null,"handle":null}"#.utf8))
        XCTAssertEqual(user.displayName, MemberIdentity.someone)
    }

    func testLeaderboardReadsTheHandleServedAsName() throws {
        // Option « nom d'utilisateur au classement » : `name` porte aussi le handle (anciens clients).
        let shown = try JSONDecoder().decode(PointsLeaderboardEntry.self, from: Data(
            #"{"rank":4,"userId":"u1","name":"alex38","handle":"alex38","points":12480}"#.utf8))
        XCTAssertEqual(shown.displayName, "@alex38")
        let named = try JSONDecoder().decode(PointsLeaderboardEntry.self, from: Data(
            #"{"rank":5,"userId":"u2","name":"Camille","handle":null,"points":100}"#.utf8))
        XCTAssertEqual(named.displayName, "Camille")
        let hidden = try JSONDecoder().decode(PointsLeaderboardEntry.self, from: Data(
            #"{"rank":6,"userId":"u3","name":null,"handle":null,"points":10}"#.utf8))
        XCTAssertEqual(hidden.displayName, MemberIdentity.someone)
    }
}
