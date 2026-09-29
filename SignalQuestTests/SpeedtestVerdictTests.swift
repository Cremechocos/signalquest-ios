import XCTest
@testable import SignalQuest

/// MES-05 : le verdict dit à quoi suffit une mesure, sans promettre plus que
/// ce qui a été mesuré.
final class SpeedtestVerdictTests: XCTestCase {
    func testFastConnectionFitsEveryUsage() {
        let verdict = SpeedtestVerdict(downloadMbps: 312, uploadMbps: 54, latencyMs: 17, jitterMs: 3)
        XCTAssertEqual(verdict.tier, .veryGood)
        for usage in SpeedtestVerdict.Usage.allCases {
            XCTAssertEqual(verdict.fits[usage], .good, "\(usage)")
        }
        XCTAssertEqual(verdict.oneGigabyteSeconds ?? 0, 8_000 / 312, accuracy: 0.01)
    }

    func testSlowConnectionStaysHonest() {
        let verdict = SpeedtestVerdict(downloadMbps: 4, uploadMbps: 1, latencyMs: 80, jitterMs: 40)
        XCTAssertEqual(verdict.fits[.web], .good)
        XCTAssertEqual(verdict.fits[.hdVideo], .limited)
        XCTAssertEqual(verdict.fits[.uhdVideo], .poor)
        XCTAssertEqual(verdict.fits[.videoCall], .poor, "1 Mbit/s up cannot carry a video call")
        XCTAssertEqual(verdict.fits[.gaming], .limited)
    }

    func testUnmeasuredDirectionsPromiseNothing() {
        let verdict = SpeedtestVerdict(downloadMbps: 150, uploadMbps: nil, latencyMs: nil, jitterMs: nil)
        XCTAssertNil(verdict.fits[.videoCall], "No upload measured, no video-call verdict")
        XCTAssertNil(verdict.fits[.gaming], "No latency measured, no gaming verdict")
        XCTAssertEqual(verdict.fits[.uhdVideo], .good)
    }

    func testBrokenValuesNeverCrashOrFlatter() {
        let verdict = SpeedtestVerdict(downloadMbps: .nan, uploadMbps: -3, latencyMs: nil, jitterMs: nil)
        XCTAssertEqual(verdict.tier, .verySlow)
        XCTAssertNil(verdict.oneGigabyteSeconds)
        XCTAssertEqual(verdict.fits[.web], .poor)
    }
}
