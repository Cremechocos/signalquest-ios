import XCTest
@testable import SignalQuest

/// TRX-20 : la feuille du @pseudo ne revient plus à chaque lancement.
final class HandleGatePolicyTests: XCTestCase {
    private func store() throws -> (UserDefaults, String) {
        let name = "sq-handle-gate-test-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testMembersWithAHandleAreNeverAsked() throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(HandleGatePolicy.shouldPresent(handle: "alex", userID: "u1", defaults: defaults))
        XCTAssertTrue(HandleGatePolicy.shouldPresent(handle: "", userID: "u1", defaults: defaults))
        XCTAssertTrue(HandleGatePolicy.shouldPresent(handle: nil, userID: "u1", defaults: defaults))
    }

    func testDismissedSheetWaitsAWeekPerAccount() throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let shown = Date(timeIntervalSince1970: 1_800_000_000)
        HandleGatePolicy.markPresented(userID: "u1", now: shown, defaults: defaults)
        XCTAssertFalse(HandleGatePolicy.shouldPresent(handle: nil, userID: "u1",
            now: shown.addingTimeInterval(24 * 3600), defaults: defaults), "A relaunch the next day must not ask again")
        XCTAssertTrue(HandleGatePolicy.shouldPresent(handle: nil, userID: "u1",
            now: shown.addingTimeInterval(HandleGatePolicy.interval), defaults: defaults))
        XCTAssertTrue(HandleGatePolicy.shouldPresent(handle: nil, userID: "u2",
            now: shown.addingTimeInterval(60), defaults: defaults), "Another account keeps its own reminder")
    }
}
