import XCTest
@testable import SignalQuest

final class MapTileAdmissionTests: XCTestCase {
    private let tile = AndroidMapTile(z: 14, x: 8299, y: 5636)

    func testRealEmptyTileIsAcceptedOnlyForItsRequestedIdentity() throws {
        let body = Data(#"{"tile":{"z":14,"x":8299,"y":5636},"points":[],"clusters":[]}"#.utf8)
        let response = try MapTileAdmission.decode(AndroidCoverageTileResponse.self, from: body, expectedTile: tile)
        XCTAssertTrue(response.points.isEmpty)
        XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCoverageTileResponse.self, from: body,
                                                         expectedTile: AndroidMapTile(z: 14, x: 8300, y: 5636)))
    }

    func testMissingTileCannotBeFabricatedAsTheWorldTile() {
        let body = Data(#"{"markers":[]}"#.utf8)
        XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCustomSiteTileResponse.self, from: body,
                                                         expectedTile: AndroidMapTile(z: 0, x: 0, y: 0)))
    }

    func testMalformedArraysDoNotBecomeEmptySuccessesThroughLossyDecoders() {
        for json in [
            #"{"tile":{"z":14,"x":8299,"y":5636},"markers":"unavailable"}"#,
            #"{"tile":{"z":14,"x":8299,"y":5636}}"#,
            #"{"tile":{"z":14,"x":8299,"y":5636},"markers":["not a marker"]}"#,
            #"{"tile":{"z":14,"x":8299,"y":5636},"markers":[{}]}"#,
        ] {
            XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCustomSiteTileResponse.self, from: Data(json.utf8), expectedTile: tile))
        }
    }

    func testUnavailableLegacyFlagCannotBeAdmittedAsARealEmptyTile() {
        let body = Data(#"{"tile":{"z":14,"x":8299,"y":5636},"points":[],"clusters":[],"degraded":true}"#.utf8)
        XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCoverageTileResponse.self, from: body, expectedTile: tile)) { error in
            guard case let APIError.http(status, code, _, _, _) = error else { return XCTFail("Expected unavailable state") }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, "DATABASE_UNAVAILABLE")
        }
    }

    func testMissingOrInvalidCoordinatesCannotBecomeAZeroCoordinateMarker() {
        for point in [#"{"id":"p"}"#, #"{"id":"p","lat":91,"lng":2}"#, #"{"id":"p","lat":48,"lng":181}"#] {
            let body = Data("{\"tile\":{\"z\":14,\"x\":8299,\"y\":5636},\"markers\":[\(point)]}".utf8)
            XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCustomSiteTileResponse.self, from: body, expectedTile: tile))
        }
    }

    func testValidPointCoordinatesAndMetricsArePreserved() throws {
        let body = Data(#"{"tile":{"z":14,"x":8299,"y":5636},"clusters":[],"markers":[{"id":"m","lat":48.8566,"lng":2.3522,"downloadMbps":123.4}]}"#.utf8)
        let response = try MapTileAdmission.decode(AndroidSpeedtestTileResponse.self, from: body, expectedTile: tile)
        XCTAssertEqual(response.markers.map(\.id), ["m"])
        XCTAssertEqual(response.markers[0].lat, 48.8566)
        XCTAssertEqual(response.markers[0].lng, 2.3522)
        XCTAssertEqual(response.markers[0].downloadMbps, 123.4)
    }
}
