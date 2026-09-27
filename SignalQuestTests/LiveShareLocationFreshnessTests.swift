import XCTest
@testable import SignalQuest

final class LiveShareLocationFreshnessTests: XCTestCase {
    func testOnlyRecentDatedLocationsCanBeShownAsLive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let location = LiveShareLocation(
            latitude: 48.8566, longitude: 2.3522,
            accuracy: 8, altitude: nil, speed: nil, heading: nil
        )
        func payload(secondsAgo: TimeInterval?) -> LiveSharePayload {
            LiveSharePayload(
                radio: nil,
                location: location,
                at: secondsAgo.map { ObservationTimestamp.string(now.addingTimeInterval(-$0)) }
            )
        }

        XCTAssertTrue(LiveShareLocationFreshness.isCurrent(payload(secondsAgo: 0), at: now))
        XCTAssertTrue(LiveShareLocationFreshness.isCurrent(payload(secondsAgo: 30), at: now))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(payload(secondsAgo: 30.001), at: now))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(payload(secondsAgo: -1), at: now))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(payload(secondsAgo: nil), at: now))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(
            LiveSharePayload(radio: nil, location: nil, at: ObservationTimestamp.string(now)), at: now
        ))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(nil, at: now))
        XCTAssertFalse(LiveShareLocationFreshness.isCurrent(
            LiveSharePayload(radio: nil, location: location, at: "invalid"), at: now
        ))
    }
}
