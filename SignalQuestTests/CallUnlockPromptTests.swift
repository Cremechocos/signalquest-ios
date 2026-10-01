import XCTest
@testable import SignalQuest

/// Spec §2.6 (v0.4.13) : un appel décroché téléphone verrouillé attend le
/// déverrouillage, dans la limite de la sonnerie, tant qu'il sonne encore.
@MainActor
final class CallUnlockPromptTests: XCTestCase {
    func testTheCallResumesAsSoonAsTheDeviceIsUnlocked() async {
        var checks = 0
        let unlocked = await CallUnlockPrompt.waitForUnlock(
            timeout: .seconds(5), pollInterval: .milliseconds(10),
            isUnlocked: {
                checks += 1
                return checks >= 3
            },
            stillWanted: { true }
        )
        XCTAssertTrue(unlocked)
        XCTAssertEqual(checks, 3)
    }

    func testTheWaitStopsAtTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let unlocked = await CallUnlockPrompt.waitForUnlock(
            timeout: .milliseconds(100), pollInterval: .milliseconds(10),
            isUnlocked: { false }, stillWanted: { true }
        )
        XCTAssertFalse(unlocked)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(100))
        XCTAssertLessThanOrEqual(CallUnlockPrompt.maxWait, .seconds(45), "Jamais au-delà de la sonnerie")
    }

    func testTheWaitStopsWhenTheCallEnds() async {
        var asked = 0
        let unlocked = await CallUnlockPrompt.waitForUnlock(
            timeout: .seconds(5), pollInterval: .milliseconds(10),
            isUnlocked: { false },
            stillWanted: {
                asked += 1
                return asked < 3
            }
        )
        XCTAssertFalse(unlocked)
        XCTAssertEqual(asked, 3)
    }

    func testAnUnlockedDeviceNeverWaits() async {
        let unlocked = await CallUnlockPrompt.waitForUnlock(timeout: .zero, isUnlocked: { true }, stillWanted: { true })
        XCTAssertTrue(unlocked)
    }

    /// Raccroché pendant que Face ID déverrouille : l'appel ne reprend jamais.
    func testACallThatEndedIsNeverResumedEvenUnlocked() async {
        let unlocked = await CallUnlockPrompt.waitForUnlock(timeout: .seconds(5), isUnlocked: { true }, stillWanted: { false })
        XCTAssertFalse(unlocked)
    }

    /// Seul « verrouillé » attend : la clé d'époque ou la copie de la clé de signature.
    func testOnlyALockedKeyWaitsForTheUnlock() {
        XCTAssertTrue(CallManager.waitsForUnlock(CallManager.CallError.deviceLocked))
        XCTAssertTrue(CallManager.waitsForUnlock(CallsServiceError.e2eeUnavailable("e2ee-device-locked")))
        XCTAssertFalse(CallManager.waitsForUnlock(CallsServiceError.e2eeUnavailable("e2ee-transport-unavailable")))
        XCTAssertFalse(CallManager.waitsForUnlock(CallManager.CallError.e2eeUnavailable))
        XCTAssertFalse(CallManager.waitsForUnlock(CancellationError()))
    }
}
