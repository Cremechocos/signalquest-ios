import XCTest
import CoreLocation
@testable import SignalQuest

final class LiveTelemetryDeliveryStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var fix: CLLocation { CLLocation(latitude: 48.85, longitude: 2.35) }

    func testRadioAcceptedCannotSuppressRetryOfRejectedPosition() {
        var state = LiveTelemetryDeliveryState()
        state.acknowledge(fix, channel: .location, accepted: false, now: now)
        state.acknowledge(fix, channel: .radio, accepted: true, now: now)
        XCTAssertTrue(state.shouldSend(fix, channel: .location, now: now.addingTimeInterval(20), minDistance: 15, maxSilence: 120))
        XCTAssertFalse(state.shouldSend(fix, channel: .radio, now: now.addingTimeInterval(20), minDistance: 15, maxSilence: 120))
    }

    func testPositionAcceptedCannotSuppressRetryOfRejectedRadio() {
        var state = LiveTelemetryDeliveryState()
        state.acknowledge(fix, channel: .location, accepted: true, now: now)
        state.acknowledge(fix, channel: .radio, accepted: false, now: now)
        XCTAssertFalse(state.shouldSend(fix, channel: .location, now: now.addingTimeInterval(20), minDistance: 15, maxSilence: 120))
        XCTAssertTrue(state.shouldSend(fix, channel: .radio, now: now.addingTimeInterval(20), minDistance: 15, maxSilence: 120))
    }

    func testReenabledSharingRequiresANewAcceptedPosition() {
        var state = LiveTelemetryDeliveryState()
        state.acknowledge(fix, channel: .location, accepted: true, now: now)
        state.acknowledge(fix, channel: .radio, accepted: true, now: now)
        state.reset(.location)
        XCTAssertTrue(state.shouldSend(fix, channel: .location, now: now, minDistance: 15, maxSilence: 120))
        XCTAssertFalse(state.shouldSend(fix, channel: .radio, now: now, minDistance: 15, maxSilence: 120))
    }

    func testAcceptedFixRepublishesAfterSilenceOrMovement() {
        var state = LiveTelemetryDeliveryState()
        state.acknowledge(fix, channel: .location, accepted: true, now: now)
        XCTAssertTrue(state.shouldSend(fix, channel: .location, now: now.addingTimeInterval(120), minDistance: 15, maxSilence: 120))
        XCTAssertTrue(state.shouldSend(CLLocation(latitude: 48.86, longitude: 2.35), channel: .location, now: now, minDistance: 15, maxSilence: 120))
    }
}
