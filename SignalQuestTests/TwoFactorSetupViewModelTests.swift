import XCTest
@testable import SignalQuest

@MainActor
final class TwoFactorSetupViewModelTests: XCTestCase {
    private let secret = "JBSWY3DPEHPK3PXP"

    private func model(_ service: EnrollmentMock,
                       now: @escaping () -> Date = Date.init,
                       acknowledge: @escaping @MainActor () throws -> Void = {},
                       refresh: @escaping @MainActor () async throws -> Void = {}) -> TwoFactorSetupViewModel {
        TwoFactorSetupViewModel(service: service, now: now, acknowledge: acknowledge, refreshProfile: refresh)
    }

    func testInitialFailureStopsLoadingShowsErrorAndCanBeRetried() async {
        let service = EnrollmentMock()
        await service.failSetup(APIError.transport("synthetic"))
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.phase, .loadFailed)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.setup)
        XCTAssertNotNil(model.errorMessage)
        await service.succeedSetup(secret: secret)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.setup?.secret, secret)
        XCTAssertNil(model.errorMessage)
        let calls = await service.setupCalls
        XCTAssertEqual(calls, 2)
    }

    func testRepeatedLoadWhileRequestIsPendingDoesNotRotateTheChallengeTwice() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setSetupGate(gate)
        let model = model(service)
        let pending = Task { await model.load() }
        await gate.waitUntilEntered()
        await model.load()
        await gate.open()
        await pending.value
        let calls = await service.setupCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.phase, .ready)
    }

    func testDoubleConfirmationGestureSendsTheCodeOnlyOnce() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setConfirmationGate(gate)
        let model = model(service)
        await model.load()
        model.code = "123456"
        let pending = Task { await model.confirm() }
        await gate.waitUntilEntered()
        await model.confirm()
        await gate.open()
        await pending.value
        let confirmations = await service.confirmCalls
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(model.didEnable)
        XCTAssertNil(model.setup)
    }

    func testMalformedCodeMakesNoConfirmationRequestAndWrongTOTPRemainsRecoverable() async {
        let service = EnrollmentMock()
        let model = model(service)
        await model.load()
        model.code = "123"
        await model.confirm()
        var calls = await service.confirmCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(model.errorMessage)
        model.code = "123456"
        await service.failConfirmation(TwoFactorEnrollmentError.invalidCode)
        await model.confirm()
        calls = await service.confirmCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.setup?.secret, secret)
        XCTAssertEqual(model.code, "")
        XCTAssertFalse(model.didEnable)
    }

    func testConfirmedActivationClearsSecretBeforeProfileReadAndNeverResubmitsAfterReadFailure() async {
        let service = EnrollmentMock()
        var acknowledgements = 0, refreshes = 0
        let model = model(service, acknowledge: { acknowledgements += 1 }, refresh: {
            refreshes += 1
            if refreshes == 1 { throw APIError.transport("synthetic profile failure") }
        })
        await model.load()
        model.code = "123456"
        await model.confirm()
        XCTAssertTrue(model.didEnable)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertNil(model.setup)
        XCTAssertNil(model.qrCodeURI)
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(model.phase, .profileRefreshFailed)
        XCTAssertFalse(model.isBusy)
        await model.confirm()
        await model.load()
        await model.retryProfile()
        let confirmations = await service.confirmCalls
        let setups = await service.setupCalls
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(setups, 1)
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(model.phase, .complete)
        XCTAssertTrue(model.didEnable)
    }

    func testSecretIsAlreadyAbsentWhileTheConfirmedProfileRequestIsSuspended() async {
        let service = EnrollmentMock()
        let profileGate = EnrollmentModelGate()
        let model = model(service, refresh: { await profileGate.wait() })
        await model.load()
        model.code = "123456"
        let pending = Task { await model.confirm() }
        await profileGate.waitUntilEntered()
        XCTAssertTrue(model.didEnable)
        XCTAssertEqual(model.phase, .refreshingProfile)
        XCTAssertNil(model.setup)
        XCTAssertEqual(model.code, "")
        await profileGate.open()
        await pending.value
        XCTAssertEqual(model.phase, .complete)
    }

    func testFalseAcknowledgementDoesNotConfirmOrRefreshTheProfile() async {
        let service = EnrollmentMock()
        await service.failConfirmation(TwoFactorEnrollmentError.unconfirmedResponse)
        var acknowledged = false, refreshed = false
        let model = model(service, acknowledge: { acknowledged = true }, refresh: { refreshed = true })
        await model.load()
        model.code = "123456"
        await model.confirm()
        XCTAssertFalse(model.didEnable)
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.errorMessage)
    }

    func testExpiryRequiresANewSetupAndNeverSendsTheOldSecret() async {
        let service = EnrollmentMock()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var now = startedAt
        await service.succeedSetup(secret: secret, expiry: startedAt.addingTimeInterval(10))
        let model = model(service, now: { now })
        await model.load()
        now = startedAt.addingTimeInterval(10)
        model.code = "123456"
        await model.confirm()
        XCTAssertEqual(model.phase, .needsNewSetup)
        XCTAssertNil(model.setup)
        let calls = await service.confirmCalls
        XCTAssertEqual(calls, 0)
    }

    func testReplacedSetupClearsSecretAndLetsTheUserStartAgain() async {
        let service = EnrollmentMock()
        await service.failConfirmation(TwoFactorEnrollmentError.replacedSetup)
        let model = model(service)
        await model.load()
        model.code = "123456"
        await model.confirm()
        XCTAssertEqual(model.phase, .needsNewSetup)
        XCTAssertNil(model.setup)
        await service.succeedSetup(secret: "MFRGGZDFMZTWQ2LK")
        await model.load()
        XCTAssertEqual(model.setup?.secret, "MFRGGZDFMZTWQ2LK")
    }

    func testOldAccountSetupResponseCannotReappearAfterInvalidation() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setSetupGate(gate)
        let model = model(service)
        let pending = Task { await model.load() }
        await gate.waitUntilEntered()
        service.validity.set(false)
        model.sessionDidChange()
        await gate.open()
        await pending.value
        XCTAssertEqual(model.phase, .sessionChanged)
        XCTAssertNil(model.setup)
        XCTAssertEqual(model.code, "")
    }

    func testOldConfirmationDoesNotAcknowledgeOrRefreshAnotherAccount() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setConfirmationGate(gate)
        var acknowledged = false, refreshed = false
        let model = model(service, acknowledge: { acknowledged = true }, refresh: { refreshed = true })
        await model.load()
        model.code = "123456"
        let pending = Task { await model.confirm() }
        await gate.waitUntilEntered()
        service.validity.set(false)
        model.sessionDidChange()
        await gate.open()
        await pending.value
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(refreshed)
        XCTAssertFalse(model.didEnable)
        XCTAssertNil(model.setup)
        XCTAssertEqual(model.phase, .sessionChanged)
    }

    func testCloseDiscardsSecretCodeAndLateSetupResult() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setSetupGate(gate)
        let model = model(service)
        let pending = Task { await model.load() }
        await gate.waitUntilEntered()
        model.code = "123456"
        model.close()
        await gate.open()
        await pending.value
        XCTAssertNil(model.setup)
        XCTAssertEqual(model.code, "")
        XCTAssertFalse(model.canConfirm)
    }

    func testCancelledGenerationDoesNotLeaveAPermanentSpinner() async {
        let service = EnrollmentMock()
        let gate = EnrollmentModelGate()
        await service.setSetupGate(gate)
        let model = model(service)
        let pending = Task { await model.load() }
        await gate.waitUntilEntered()
        pending.cancel()
        await gate.open()
        await pending.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.phase, .loadFailed)
        XCTAssertNotNil(model.errorMessage)
    }

    func testURIWithoutMatchingSecretUsesManualEnrollmentInsteadOfAWrongQRCode() async {
        let service = EnrollmentMock()
        await service.succeedSetup(secret: secret, uri: "otpauth://totp/SignalQuest:test?secret=MFRGGZDFMZTWQ2LK")
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.setup?.secret, secret)
        XCTAssertNil(model.qrCodeURI)
    }

    func testAlreadyEnabledServerResponseOffersOnlyProfileRefresh() async {
        let service = EnrollmentMock()
        await service.failSetup(TwoFactorEnrollmentError.alreadyEnabled)
        var refreshes = 0
        let model = model(service, refresh: { refreshes += 1 })
        await model.load()
        XCTAssertFalse(model.didEnable, "Ne pas confondre le facteur existant et notre confirmation")
        XCTAssertTrue(model.serverAlreadyEnabled)
        XCTAssertNil(model.setup)
        XCTAssertEqual(refreshes, 1, "Un profil déjà activé est relu immédiatement, sans nouveau setup")
        await model.confirm()
        await model.load()
        await model.retryProfile()
        XCTAssertEqual(refreshes, 1)
        let confirmations = await service.confirmCalls
        let setups = await service.setupCalls
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(setups, 1)
        XCTAssertEqual(model.phase, .complete)
    }
}

private actor EnrollmentMock: TwoFactorEnrollmentServicing {
    nonisolated let scope = TwoFactorEnrollmentScope(userID: "a",
        account: LocalAccountSession(ownerScopeId: "user:a", sessionId: UUID().uuidString), credentialSessionID: UUID())
    nonisolated let validity = EnrollmentValidity()
    nonisolated func isCurrent() -> Bool { validity.get() }
    private(set) var setupCalls = 0
    private(set) var confirmCalls = 0
    private var setupResult: Result<TwoFactorSetupResponse, Error> = .success(TwoFactorSetupResponse(secret: "JBSWY3DPEHPK3PXP"))
    private var confirmationError: Error?
    private var setupGate: EnrollmentModelGate?
    private var confirmationGate: EnrollmentModelGate?
    func failSetup(_ error: Error) { setupResult = .failure(error) }
    func succeedSetup(secret: String, uri: String? = nil, expiry: Date? = nil) {
        setupResult = .success(TwoFactorSetupResponse(secret: secret, uri: uri, expiresAt: expiry))
    }
    func failConfirmation(_ error: Error) { confirmationError = error }
    func setSetupGate(_ gate: EnrollmentModelGate) { setupGate = gate }
    func setConfirmationGate(_ gate: EnrollmentModelGate) { confirmationGate = gate }
    func setup() async throws -> TwoFactorSetupResponse {
        setupCalls += 1
        if let gate = setupGate { await gate.wait() }
        return try setupResult.get()
    }
    func confirm(secret: String, code: String) async throws {
        confirmCalls += 1
        if let gate = confirmationGate { await gate.wait() }
        if let confirmationError { throw confirmationError }
    }
    func profile() async throws -> AuthUser { .mock }
}

private final class EnrollmentValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func get() -> Bool { lock.withLock { value } }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
}

actor EnrollmentModelGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; enteredWaiter?.resume(); enteredWaiter = nil }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}
