import XCTest
import LocalAuthentication
@testable import SignalQuest

@MainActor
final class AppLockControllerTests: XCTestCase {
    func testEnabledLockDoesNotRequireAvailableAuthenticationAtActivation() async {
        var requests = 0
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 30, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in requests += 1; return false })
        lock.lockOnActivationIfNeeded()
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(requests, 0, "L'absence de preuve doit fermer le verrou avant toute invite")
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
    }

    func testDisabledLockDoesNotPromptOrLockAtActivationAndReturn() async {
        let lock = AppLockController(settings: { .init(enabled: false, lockGrace: 0, autoLogout: 1) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in XCTFail("Pas d'invite quand le verrou est désactivé"); return true })
        lock.lockOnActivationIfNeeded()
        lock.didEnterBackground()
        XCTAssertFalse(lock.willEnterForeground())
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
    }

    func testSuccessfulAuthenticationAllowsDevicePasscodeFallback() async {
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { reason, allowPasscode in
                XCTAssertFalse(reason.isEmpty)
                XCTAssertTrue(allowPasscode)
                return true
            })
        lock.lockOnActivationIfNeeded()
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
        XCTAssertFalse(lock.willEnterForeground(), "L'invite système seule ne constitue pas un arrière-plan")
        XCTAssertFalse(lock.isLocked, "Le retour de l'invite ne doit pas créer une boucle")
    }

    func testFailedOrCancelledAuthenticationCanBeRetriedWithoutUnlocking() async {
        var attempts = 0
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in attempts += 1; return attempts > 1 })
        lock.lockOnActivationIfNeeded()
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
    }

    func testImmediateLockIsAppliedInBackgroundWithoutAuthenticationAvailability() async {
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.isInBackground)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked, "Le contenu ne peut être exposé par une invite en arrière-plan")
        XCTAssertFalse(lock.willEnterForeground())
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isInBackground)
    }

    func testGracePeriodAllowsShortAbsenceAndLocksAtItsBoundary() {
        var time: TimeInterval = 100
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 30, autoLogout: 0) },
            now: { time }, canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        time = 129
        XCTAssertFalse(lock.willEnterForeground())
        XCTAssertFalse(lock.isLocked)
        lock.didEnterBackground()
        time = 159
        XCTAssertFalse(lock.willEnterForeground())
        XCTAssertTrue(lock.isLocked)
    }

    func testRepeatedBackgroundEventsDoNotExtendGracePeriod() {
        var time: TimeInterval = 100
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 30, autoLogout: 0) },
            now: { time }, canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        time = 129
        lock.didEnterBackground()
        time = 131
        XCTAssertFalse(lock.willEnterForeground())
        XCTAssertTrue(lock.isLocked)
    }

    func testAutoLogoutUsesElapsedTimeRegardlessOfAuthenticationAvailability() {
        var time: TimeInterval = 100
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 30, autoLogout: 60) },
            now: { time }, canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        time = 160
        XCTAssertTrue(lock.willEnterForeground())
        XCTAssertTrue(lock.isLocked, "La déconnexion asynchrone doit rester masquée")
        XCTAssertFalse(lock.willEnterForeground(), "Le signal de déconnexion est consommé une seule fois")
    }

    func testResetRemovesLockAndBackgroundDeadline() {
        var time: TimeInterval = 100
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 60) },
            now: { time }, canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        lock.reset()
        time = 200
        XCTAssertFalse(lock.willEnterForeground())
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isInBackground)
    }

    func testInvalidClockAndGraceValuesFailClosed() {
        var time: TimeInterval = 100
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 30, autoLogout: 0) },
            now: { time }, canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        lock.didEnterBackground()
        time = 99
        _ = lock.willEnterForeground()
        XCTAssertTrue(lock.isLocked)

        let invalidGrace = AppLockController(settings: { .init(enabled: true, lockGrace: .nan, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in false })
        invalidGrace.didEnterBackground()
        XCTAssertTrue(invalidGrace.isLocked)
    }

    func testConcurrentUnlockTapsShareOnlyOneAuthenticationAttempt() async {
        let started = expectation(description: "Une invite")
        let authenticator = ControlledAuthentication(onStart: { started.fulfill() })
        let lock = makeLock(authenticator)
        lock.lockOnActivationIfNeeded()
        let first = Task { await lock.unlock() }
        await fulfillment(of: [started], timeout: 1)
        await lock.unlock()
        XCTAssertEqual(authenticator.requestCount, 1)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.isAuthenticating)
        authenticator.complete(true)
        await first.value
        XCTAssertFalse(lock.isLocked)
    }

    func testSuccessfulOldPromptCannotUnlockAfterBackgroundAndReturn() async {
        let started = expectation(description: "Invite avant arrière-plan")
        let authenticator = ControlledAuthentication(onStart: { started.fulfill() })
        let lock = makeLock(authenticator)
        lock.lockOnActivationIfNeeded()
        let first = Task { await lock.unlock() }
        await fulfillment(of: [started], timeout: 1)
        lock.didEnterBackground()
        _ = lock.willEnterForeground()
        authenticator.complete(true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
    }

    func testSuccessfulOldPromptCannotUnlockNewSessionAfterReset() async {
        let started = expectation(description: "Invite de l'ancienne session")
        let authenticator = ControlledAuthentication(onStart: { started.fulfill() })
        let lock = makeLock(authenticator)
        lock.lockOnActivationIfNeeded()
        let first = Task { await lock.unlock() }
        await fulfillment(of: [started], timeout: 1)
        lock.reset()
        lock.lockOnActivationIfNeeded()
        authenticator.complete(true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
    }

    func testCancelledUnlockTaskCannotUseLaterSuccess() async {
        let started = expectation(description: "Invite annulée")
        let authenticator = ControlledAuthentication(onStart: { started.fulfill() })
        let lock = makeLock(authenticator)
        lock.lockOnActivationIfNeeded()
        let first = Task { await lock.unlock() }
        await fulfillment(of: [started], timeout: 1)
        first.cancel()
        authenticator.complete(true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
    }

    func testUnavailableAuthenticationGuidesRecoveryAndAvailabilityRefreshNeverUnlocks() async {
        var available = false
        var requests = 0
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { available }, authenticate: { _, _ in requests += 1; return true })
        lock.lockOnActivationIfNeeded()
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.canAuthenticateDeviceOwner)
        XCTAssertEqual(requests, 0)
        available = true
        lock.refreshAuthenticationAvailability()
        XCTAssertTrue(lock.canAuthenticateDeviceOwner)
        XCTAssertTrue(lock.isLocked, "Returning from Settings is not authentication")
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(requests, 1)
    }

    func testFailedAuthenticationGivesFeedbackAndSuccessfulRetryClearsIt() async {
        var succeeds = false
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in succeeds })
        lock.lockOnActivationIfNeeded()
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertNotNil(lock.unlockError)
        XCTAssertFalse(lock.isAuthenticating)
        succeeds = true
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.unlockError)
    }

    private func makeLock(_ authenticator: ControlledAuthentication) -> AppLockController {
        AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { true }, authenticate: { _, _ in await authenticator.authenticate() })
    }
}

@MainActor
private final class ControlledAuthentication {
    private let onStart: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requestCount = 0

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func authenticate() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart()
        }
    }

    func complete(_ result: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

@MainActor
final class BiometricAuthTests: XCTestCase {
    func testUnavailableBiometricsAndLockoutCanUseDevicePasscodePolicy() async {
        let context = FakeDeviceAuthenticationContext()
        context.biometricsAvailable = false
        context.deviceAuthenticationAvailable = true
        context.result = true
        let authenticated = await BiometricAuth.authenticate(reason: "synthetic", context: context)
        XCTAssertTrue(authenticated)
        XCTAssertEqual(context.checkedPolicies, [.deviceOwnerAuthentication])
        XCTAssertEqual(context.evaluatedPolicies, [.deviceOwnerAuthentication])
    }

    func testBiometricsOnlyCallerDoesNotSilentlyAllowDevicePasscode() async {
        let context = FakeDeviceAuthenticationContext()
        context.biometricsAvailable = false
        context.deviceAuthenticationAvailable = true
        let authenticated = await BiometricAuth.authenticate(reason: "synthetic", allowPasscode: false, context: context)
        XCTAssertFalse(authenticated)
        XCTAssertEqual(context.checkedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertTrue(context.evaluatedPolicies.isEmpty)
    }

    func testNoAvailableOwnerAuthenticationCannotUnlock() async {
        let context = FakeDeviceAuthenticationContext()
        context.deviceAuthenticationAvailable = false
        context.result = true
        let authenticated = await BiometricAuth.authenticate(reason: "synthetic", context: context)
        XCTAssertFalse(authenticated)
        XCTAssertTrue(context.evaluatedPolicies.isEmpty)
    }

    func testControllerRemainsLockedWhenBothBiometricsAndPasscodeAreUnavailable() async {
        let context = FakeDeviceAuthenticationContext()
        context.biometricsAvailable = false
        context.deviceAuthenticationAvailable = false
        let lock = AppLockController(settings: { .init(enabled: true, lockGrace: 0, autoLogout: 0) },
            canAuthenticateDeviceOwner: { false }, authenticate: { reason, allowPasscode in
                await BiometricAuth.authenticate(reason: reason, allowPasscode: allowPasscode, context: context)
            })
        lock.lockOnActivationIfNeeded()
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.canAuthenticateDeviceOwner)
        XCTAssertTrue(context.evaluatedPolicies.isEmpty)
    }

    func testRejectedAuthenticationCannotUnlock() async {
        let context = FakeDeviceAuthenticationContext()
        context.result = false
        let authenticated = await BiometricAuth.authenticate(reason: "synthetic", context: context)
        XCTAssertFalse(authenticated)
    }

    func testCancellationInvalidatesSystemContextAndRejectsLateSuccess() async {
        let started = expectation(description: "Invite système ouverte")
        let invalidated = expectation(description: "Invite système invalidée")
        let context = FakeDeviceAuthenticationContext()
        context.holdResponse = true
        context.onStart = { started.fulfill() }
        context.onInvalidate = { invalidated.fulfill() }
        let task = Task { await BiometricAuth.authenticate(reason: "synthetic", context: context) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [invalidated], timeout: 1)
        context.complete(true)
        let authenticated = await task.value
        XCTAssertFalse(authenticated)
    }
}

@MainActor
private final class FakeDeviceAuthenticationContext: DeviceAuthenticationContext {
    var biometricsAvailable = true
    var deviceAuthenticationAvailable = true
    var result = false
    var holdResponse = false
    var onStart: (() -> Void)?
    var onInvalidate: (() -> Void)?
    private(set) var checkedPolicies: [LAPolicy] = []
    private(set) var evaluatedPolicies: [LAPolicy] = []
    private var continuation: CheckedContinuation<Bool, Never>?

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        checkedPolicies.append(policy)
        return policy == .deviceOwnerAuthentication ? deviceAuthenticationAvailable : biometricsAvailable
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool {
        evaluatedPolicies.append(policy)
        guard holdResponse else { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart?()
        }
    }

    func invalidate() { onInvalidate?() }

    func complete(_ result: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
