import XCTest
@testable import SignalQuest

@MainActor
final class OnboardingEntryStateTests: XCTestCase {
    private func store() throws -> (UserDefaults, String) {
        let name = "sq-onboarding-test-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testOpeningOrRecreatingStateDoesNotCompleteOnboarding() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        XCTAssertFalse(state.hasCompleted)
        XCTAssertNil(state.pending)
        XCTAssertFalse(OnboardingEntryState(defaults: defaults).hasCompleted)
    }

    func testChoiceSurvivesRestartUntilPresentationAcknowledgesItsID() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let original = OnboardingEntryState(defaults: defaults)
        original.finish(destination: .measure)
        let request = try XCTUnwrap(original.pending)
        let restored = OnboardingEntryState(defaults: defaults)
        XCTAssertTrue(restored.hasCompleted)
        XCTAssertEqual(restored.pending, request)
        XCTAssertEqual(restored.resolve(access: .loggedOut, updateRequired: false, locked: false, hasExternalRoute: false), .guest(request))
        restored.consume(.init(destination: .measure))
        XCTAssertEqual(restored.pending, request, "A late callback for another presentation cannot consume the choice")
        restored.consume(request)
        XCTAssertNil(OnboardingEntryState(defaults: defaults).pending)
        XCTAssertTrue(OnboardingEntryState(defaults: defaults).hasCompleted)
    }

    func testSkipCompletesWithoutSelectingOrStartingAnything() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: nil)
        XCTAssertTrue(state.hasCompleted)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.resolve(access: .authenticated, updateRequired: false, locked: false, hasExternalRoute: false), .wait)
    }

    func testExistingCompletionDoesNotIntroduceANewDestination() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: OnboardingEntryState.completionKey)
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .measure)
        XCTAssertNil(state.pending)
    }

    func testCheckingOfflineAndTwoFactorKeepTheChoicePending() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .map)
        for access in [OnboardingEntryState.Access.checking, .offline, .twoFactor] {
            XCTAssertEqual(state.resolve(access: access, updateRequired: false, locked: false, hasExternalRoute: false), .wait)
            XCTAssertNotNil(state.pending)
        }
    }

    func testUpdateAndPrivacyLockPreventAllAutomaticDestinations() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .measure)
        for access in [OnboardingEntryState.Access.loggedOut, .authenticated] {
            XCTAssertEqual(state.resolve(access: access, updateRequired: true, locked: false, hasExternalRoute: false), .wait)
            XCTAssertEqual(state.resolve(access: access, updateRequired: false, locked: true, hasExternalRoute: false), .wait)
        }
    }

    func testDeepLinkSupersedesOnboardingForBothGuestAndAuthenticatedEntry() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .map)
        let request = try XCTUnwrap(state.pending)
        for access in [OnboardingEntryState.Access.loggedOut, .authenticated] {
            XCTAssertEqual(state.resolve(access: access, updateRequired: false, locked: false, hasExternalRoute: true), .superseded(request))
        }
    }

    func testAuthenticatedChoiceSelectsItsScreenAndDoesNotChangeExistingPreferences() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "existing-test-collection-preference")
        defaults.set("retained", forKey: "existing-test-consent-record")
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .measure)
        let request = try XCTUnwrap(state.pending)
        XCTAssertEqual(state.resolve(access: .authenticated, updateRequired: false, locked: false, hasExternalRoute: false), .authenticated(request))
        XCTAssertFalse(defaults.bool(forKey: "existing-test-collection-preference"))
        XCTAssertEqual(defaults.string(forKey: "existing-test-consent-record"), "retained")
        state.finish(destination: .map)
        XCTAssertEqual(state.pending, request, "Repeated completion cannot replace the first explicit choice")
    }

    func testResetOrInterruptedCompletionDoesNotReplayAnOrphanChoice() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let request = OnboardingEntryRequest(destination: .measure)
        defaults.set(try JSONEncoder().encode(request), forKey: OnboardingEntryState.pendingKey)
        let state = OnboardingEntryState(defaults: defaults)
        XCTAssertFalse(state.hasCompleted)
        XCTAssertNil(state.pending)
        state.finish(destination: nil)
        XCTAssertNil(defaults.data(forKey: OnboardingEntryState.pendingKey))
    }

    func testOnlyTheSceneOfTheChoiceCanReserveBeforeItsPresentation() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let origin = UUID(), other = UUID()
        state.finish(destination: .map, sceneID: origin)
        let request = try XCTUnwrap(state.pending)
        XCTAssertNil(state.reserveGuestPresentation(request, sceneID: other))
        let first = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: origin))
        XCTAssertNil(state.reserveGuestPresentation(request, sceneID: origin))
        XCTAssertNil(state.reserveGuestPresentation(request, sceneID: other))
        XCTAssertEqual(OnboardingEntryState(defaults: defaults).pending, request)
        XCTAssertTrue(first.acknowledge())
        XCTAssertTrue(first.didPresent)
        XCTAssertNil(state.pending)
        XCTAssertNil(OnboardingEntryState(defaults: defaults).pending)
        XCTAssertFalse(first.acknowledge())
        XCTAssertNil(state.reserveGuestPresentation(request, sceneID: other))
    }

    func testInactiveOrClosedOriginHandsTheUnpresentedChoiceToAnotherScene() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let origin = UUID(), other = UUID()
        state.finish(destination: .measure, sceneID: origin)
        let request = try XCTUnwrap(state.pending)
        let first = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: origin))
        state.releaseGuestScene(other)
        XCTAssertTrue(first.isValid, "An unrelated scene cannot release the owner")
        state.releaseGuestScene(origin)
        XCTAssertFalse(first.isValid)
        XCTAssertEqual(state.pending, request)
        let second = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: other))
        XCTAssertFalse(first.acknowledge(), "A late cover callback cannot consume the reassigned choice")
        first.release()
        XCTAssertTrue(second.isValid, "A stale release cannot release a newer reservation")
        XCTAssertTrue(second.acknowledge())
    }

    func testClosingTheOriginBeforeLoginAppearsDoesNotStrandItsChoice() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let origin = UUID()
        state.finish(destination: .map, sceneID: origin)
        let request = try XCTUnwrap(state.pending)
        state.releaseGuestScene(origin)
        let replacement = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: UUID()))
        XCTAssertTrue(replacement.acknowledge())
    }

    func testARecreatedProcessDoesNotWaitForAnOldSceneIdentifier() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .measure, sceneID: UUID())
        let request = try XCTUnwrap(state.pending)
        let restored = OnboardingEntryState(defaults: defaults)
        let lease = try XCTUnwrap(restored.reserveGuestPresentation(request, sceneID: UUID()))
        XCTAssertTrue(lease.acknowledge())
    }

    func testSupersedingRouteInvalidatesAnUnpresentedGuestCover() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        state.finish(destination: .map)
        let request = try XCTUnwrap(state.pending)
        let lease = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: UUID()))
        state.consume(request)
        XCTAssertFalse(lease.isValid)
        XCTAssertFalse(lease.acknowledge())
        XCTAssertFalse(lease.didPresent)
        XCTAssertNil(state.pending)
    }

    func testReleasedReservationCanRetryButOldCallbackCannotAcknowledgeRetry() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let scene = UUID()
        state.finish(destination: .measure, sceneID: scene)
        let request = try XCTUnwrap(state.pending)
        let old = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: scene))
        old.release()
        let retry = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: scene))
        XCTAssertNotEqual(old.id, retry.id)
        XCTAssertFalse(old.acknowledge())
        XCTAssertTrue(retry.acknowledge())
    }

    func testInactiveSceneDoesNotCloseAnAlreadyAcknowledgedPreview() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let scene = UUID()
        state.finish(destination: .map, sceneID: scene)
        let request = try XCTUnwrap(state.pending)
        let lease = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: scene))
        XCTAssertTrue(lease.acknowledge())
        state.releaseGuestScene(scene)
        XCTAssertTrue(lease.didPresent)
        XCTAssertNil(state.pending)
    }

    func testLeaseDeallocationReleasesOnlyItsOwnReservation() async throws {
        let (defaults, name) = try store(); defer { defaults.removePersistentDomain(forName: name) }
        let state = OnboardingEntryState(defaults: defaults)
        let scene = UUID()
        state.finish(destination: .map, sceneID: scene)
        let request = try XCTUnwrap(state.pending)
        var lease = state.reserveGuestPresentation(request, sceneID: scene)
        weak var weakLease = lease
        XCTAssertNotNil(weakLease)
        lease = nil
        XCTAssertNil(weakLease)
        // Deinit dispatches its release on MainActor; the awaited task drains
        // that queued actor work without a wall-clock timeout.
        await Task { @MainActor in }.value
        let retry = try XCTUnwrap(state.reserveGuestPresentation(request, sceneID: scene))
        XCTAssertTrue(retry.acknowledge())
    }
}
