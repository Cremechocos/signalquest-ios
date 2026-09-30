import XCTest
@testable import SignalQuest

/// Renvoi groupé des envois en attente (plan 3, vague 1).
@MainActor
final class PendingQueueFlusherTests: XCTestCase {
    func testStepsRunInOrderOncePerPass() async {
        var calls: [String] = []
        let flusher = PendingQueueFlusher(steps: [
            { calls.append("speedtests") },
            { calls.append("posts") },
            { calls.append("messages") },
        ])
        await flusher.flush().value
        XCTAssertEqual(calls, ["speedtests", "posts", "messages"])
        XCTAssertFalse(flusher.isRunning)
        await flusher.flush().value
        XCTAssertEqual(calls.count, 6)
    }

    /// Un second déclenchement pendant un passage (réseau revenu puis premier
    /// plan) ne relance pas les files : un envoi ne part pas deux fois en parallèle.
    func testSecondTriggerDuringAPassDoesNotStartAnother() async {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let flusher = PendingQueueFlusher(steps: [
            {
                calls += 1
                await withCheckedContinuation { release = $0 }
            },
        ])
        let first = flusher.flush()
        while release == nil { await Task.yield() }
        let second = flusher.flush()
        XCTAssertTrue(flusher.isRunning)
        release?.resume()
        await first.value
        await second.value
        XCTAssertEqual(calls, 1)
    }
}
