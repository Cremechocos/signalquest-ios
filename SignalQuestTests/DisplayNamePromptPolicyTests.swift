import XCTest
@testable import SignalQuest

/// Identité membre v1 : le nom affiché se propose en entrant dans Communauté, au plus une fois
/// par semaine, jamais une fois rempli ni avant l'écran « Ton nom d'utilisateur ».
final class DisplayNamePromptPolicyTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "DisplayNamePromptPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func user(name: String?, handle: String? = "alex38", confirmed: Bool = true, id: String = "u1") throws -> AuthUser {
        var object: [String: Any] = ["id": id]
        if let name { object["name"] = name }
        if let handle { object["handle"] = handle }
        if confirmed { object["handleConfirmedAt"] = "2026-11-13T10:00:00.000Z" }
        return try JSONDecoder().decode(AuthUser.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOnlyWithoutADisplayNameAndAfterTheUsernameScreen() throws {
        let store = try defaults()
        XCTAssertTrue(DisplayNamePromptPolicy.shouldPresent(user: try user(name: nil), defaults: store))
        XCTAssertTrue(DisplayNamePromptPolicy.shouldPresent(user: try user(name: "  "), defaults: store))
        XCTAssertFalse(DisplayNamePromptPolicy.shouldPresent(user: try user(name: "Camille"), defaults: store),
                       "Jamais une fois le nom rempli")
        XCTAssertFalse(DisplayNamePromptPolicy.shouldPresent(user: try user(name: nil, confirmed: false), defaults: store),
                       "« Ton nom d'utilisateur » passe d'abord")
    }

    func testClosedWithoutANameComesBackAfterAWeekForThatAccountOnly() throws {
        let store = try defaults()
        let shown = Date(timeIntervalSince1970: 1_800_000_000)
        DisplayNamePromptPolicy.markPresented(userID: "u1", now: shown, defaults: store)
        XCTAssertFalse(DisplayNamePromptPolicy.shouldPresent(user: try user(name: nil),
            now: shown.addingTimeInterval(6 * 24 * 3600), defaults: store))
        XCTAssertTrue(DisplayNamePromptPolicy.shouldPresent(user: try user(name: nil),
            now: shown.addingTimeInterval(DisplayNamePromptPolicy.interval), defaults: store))
        XCTAssertTrue(DisplayNamePromptPolicy.shouldPresent(user: try user(name: nil, id: "u2"),
            now: shown.addingTimeInterval(60), defaults: store))
    }
}
