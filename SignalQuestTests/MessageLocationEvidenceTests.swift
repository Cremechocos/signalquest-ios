import XCTest
@testable import SignalQuest

final class MessageLocationEvidenceTests: XCTestCase {
    func testMeasuredLocationRetainsObservedTimeAndSensorAccuracy() throws {
        let value = try XCTUnwrap(MessageLocationData.parse(fromMetadataJSON: """
        {"location":{"lat":48.8566,"lng":2.3522,"place":"Paris",
          "accuracyMeters":12.5,"observedAt":"2026-09-27T04:12:34.123Z"}}
        """))
        XCTAssertEqual(value.latitude, 48.8566)
        XCTAssertEqual(value.longitude, 2.3522)
        XCTAssertEqual(value.accuracyMeters, 12.5)
        XCTAssertEqual(value.observedAt?.timeIntervalSince1970,
                       try XCTUnwrap(SQDateParsing.parse("2026-09-27T04:12:34.123Z")).timeIntervalSince1970)
    }

    func testLegacyLocationDoesNotInventMeasurementEvidence() throws {
        let value = try XCTUnwrap(MessageLocationData.parse(fromMetadataJSON: """
        {"location":{"lat":48.8566,"lng":2.3522,"place":"Paris"}}
        """))
        XCTAssertNil(value.accuracyMeters)
        XCTAssertNil(value.observedAt)
    }
}
