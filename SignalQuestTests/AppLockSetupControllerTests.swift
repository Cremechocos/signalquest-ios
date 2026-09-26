import XCTest
@testable import SignalQuest

@MainActor
final class AppLockSetupControllerTests: XCTestCase {
    func testSuccessCommitsPreferenceAndFailureCanBeRetried() async throws {
        let fixture = try Fixture()
        fixture.authentication.result = false
        await fixture.setup.setEnabled(true, credentials: fixture.credentials)?.value
        XCTAssertFalse(fixture.preference.enabled)
        XCTAssertNotNil(fixture.setup.errorMessage)
        fixture.authentication.result = true
        await fixture.setup.setEnabled(true, credentials: fixture.credentials)?.value
        XCTAssertTrue(fixture.preference.enabled)
        XCTAssertEqual(fixture.preference.writes, [true])
        XCTAssertNil(fixture.setup.errorMessage)
        XCTAssertFalse(fixture.setup.isConfirming)
    }

    func testMissingSessionCannotStartAuthenticationOrChangePreference() async throws {
        let fixture = try Fixture(authenticated: false)
        await fixture.setup.setEnabled(true, credentials: fixture.credentials)?.value
        XCTAssertEqual(fixture.authentication.requests, 0)
        XCTAssertTrue(fixture.preference.writes.isEmpty)
        XCTAssertNotNil(fixture.setup.errorMessage)
    }

    func testAccountReplacementAndSameAccountReloginRejectOldSuccess() async throws {
        for replacement in ["synthetic-B", "synthetic-A"] {
            let fixture = try Fixture()
            let task = try await fixture.startHeldConfirmation(self)
            try fixture.credentials.setAccessToken(replacement)
            fixture.setup.cancelIfSessionChanged()
            XCTAssertFalse(fixture.setup.isConfirming)
            fixture.authentication.complete(0, true)
            await task.value
            XCTAssertTrue(fixture.preference.writes.isEmpty)
            XCTAssertNil(fixture.setup.errorMessage)
        }
    }

    func testCredentialRefreshDoesNotInvalidateTheSameSession() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startHeldConfirmation(self)
        let expected = fixture.credentials.snapshot()
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!,
            statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "auth_token=synthetic-refreshed; Path=/"]))
        _ = try fixture.credentials.captureFromResponse(response, for: expected)
        fixture.setup.cancelIfSessionChanged()
        XCTAssertTrue(fixture.setup.isConfirming)
        fixture.authentication.complete(0, true)
        await task.value
        XCTAssertEqual(fixture.preference.writes, [true])
    }

    func testChangedSessionIsRejectedBeforeSettingsReceivesItsNotification() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startHeldConfirmation(self)
        try fixture.credentials.setAccessToken("synthetic-B")
        fixture.authentication.complete(0, true)
        await task.value
        XCTAssertTrue(fixture.preference.writes.isEmpty)
        XCTAssertFalse(fixture.setup.isConfirming)
        XCTAssertNil(fixture.setup.errorMessage)
    }

    func testDisappearanceOrBackgroundCancellationRejectsLateSuccess() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startHeldConfirmation(self)
        fixture.setup.cancel()
        XCTAssertTrue(task.isCancelled)
        fixture.authentication.complete(0, true)
        await task.value
        XCTAssertTrue(fixture.preference.writes.isEmpty)
        XCTAssertFalse(fixture.setup.isConfirming)
        XCTAssertNil(fixture.setup.errorMessage)
    }

    func testOtherWindowDisablingTheSettingInvalidatesPendingEnableEvenIfAlreadyFalse() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startHeldConfirmation(self)
        let otherWindow = fixture.makeController()
        otherWindow.setEnabled(false, credentials: fixture.credentials)
        fixture.authentication.complete(0, true)
        await task.value
        XCTAssertEqual(fixture.preference.writes, [false])
        XCTAssertFalse(fixture.preference.enabled)
        XCTAssertNil(fixture.setup.errorMessage)
    }

    func testOldFailureCannotPolluteANewSuccessfulIntention() async throws {
        let fixture = try Fixture()
        let first = try await fixture.startHeldConfirmation(self)
        fixture.setup.cancel()
        let second = try await fixture.startHeldConfirmation(self)
        fixture.authentication.complete(0, false)
        await first.value
        XCTAssertTrue(fixture.setup.isConfirming)
        XCTAssertNil(fixture.setup.errorMessage)
        fixture.authentication.complete(1, true)
        await second.value
        XCTAssertEqual(fixture.preference.writes, [true])
        XCTAssertNil(fixture.setup.errorMessage)
        XCTAssertFalse(fixture.setup.isConfirming)
    }

    @MainActor
    private final class Fixture {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let preference = Preference()
        let authentication = Authentication()
        lazy var setup = makeController()

        init(authenticated: Bool = true) throws {
            if authenticated { try credentials.setAccessToken("synthetic-A") }
        }

        func makeController() -> AppLockSetupController {
            AppLockSetupController(revision: { [preference] in preference.revision },
                setEnabled: { [preference] in preference.set($0) },
                authenticate: { [authentication] in await authentication.run() })
        }

        func startHeldConfirmation(_ test: XCTestCase) async throws -> Task<Void, Never> {
            let started = test.expectation(description: "Confirmation starts")
            authentication.hold = true
            authentication.onStart = { started.fulfill() }
            let task = try XCTUnwrap(setup.setEnabled(true, credentials: credentials))
            await test.fulfillment(of: [started], timeout: 1)
            return task
        }
    }

    @MainActor
    private final class Preference {
        var enabled = false
        var revision = UUID()
        var writes: [Bool] = []
        func set(_ value: Bool) {
            enabled = value
            revision = UUID()
            writes.append(value)
        }
    }

    @MainActor
    private final class Authentication {
        var result = true
        var hold = false
        var onStart: (() -> Void)?
        var requests = 0
        private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]

        func run() async -> Bool {
            let id = requests
            requests += 1
            guard hold else { return result }
            return await withCheckedContinuation { continuation in
                continuations[id] = continuation
                onStart?()
            }
        }

        func complete(_ id: Int, _ success: Bool) {
            continuations.removeValue(forKey: id)?.resume(returning: success)
        }
    }
}
