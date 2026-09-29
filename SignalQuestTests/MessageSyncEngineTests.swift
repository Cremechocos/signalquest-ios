import XCTest
@testable import SignalQuest

/// SOC-43 : une conversation calme n'est plus sondée toutes les 12 s tant que
/// son flux SSE est ouvert ; le repli court ne sert que flux coupé.
final class MessageSyncEngineTests: XCTestCase {
    func testQuietConversationWithLiveStreamOnlyGetsTheSafetyDelta() {
        XCTAssertFalse(MessageSyncEngine.shouldPoll(sinceLastRefresh: .seconds(12), sseConnected: true, interval: .seconds(12)))
        XCTAssertFalse(MessageSyncEngine.shouldPoll(sinceLastRefresh: .seconds(59), sseConnected: true, interval: .seconds(12)))
        XCTAssertTrue(MessageSyncEngine.shouldPoll(sinceLastRefresh: .seconds(60), sseConnected: true, interval: .seconds(12)))
    }

    func testDroppedStreamFallsBackToTheShortInterval() {
        XCTAssertFalse(MessageSyncEngine.shouldPoll(sinceLastRefresh: .seconds(5), sseConnected: false, interval: .seconds(12)))
        XCTAssertTrue(MessageSyncEngine.shouldPoll(sinceLastRefresh: .seconds(12), sseConnected: false, interval: .seconds(12)))
    }
}
