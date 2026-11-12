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

    /// `detail=grid` (N2-3a) sert `clusters: []` et ses cellules dans `grid` : une tuile de grille
    /// non vide était refusée (0 élément brut contre N clusters décodés), d'où « Données
    /// incomplètes » au dézoom. Deux cellules réelles (ORANGE, 9/260/186, 12/11).
    func testNonEmptyGridTileIsAdmitted() throws {
        let grid = AndroidMapTile(z: 9, x: 260, y: 186)
        let body = Data(#"""
        {"tile":{"z":9,"x":260,"y":186},"points":[],"clusters":[],"grid":{"version":1,"projection":"web-mercator","divisions":128,"cells":[
        {"id":"9/260/186:90:92","row":90,"col":92,"groups":[{"tech":"4G","source":"android","count":3,"observedPlmn":null,"mcc":208,"mnc":1,"lat":43.72785,"lng":3.32310,"measuredCount":3,"noServiceCount":0,"avgRsrp":-98,"earliestTimestamp":"2026-06-09T06:00:00.000Z","latestTimestamp":"2026-06-09T06:00:00.000Z"}]},
        {"id":"9/260/186:90:93","row":90,"col":93,"groups":[{"tech":"4G","source":"android","count":8,"observedPlmn":null,"mcc":208,"mnc":1,"lat":43.72840,"lng":3.32389,"measuredCount":8,"noServiceCount":0,"avgRsrp":-99.5,"earliestTimestamp":"2026-06-09T06:00:00.000Z","latestTimestamp":"2026-06-09T06:00:00.000Z"},{"tech":"5G","source":"android","count":4,"observedPlmn":null,"mcc":208,"mnc":1,"lat":43.72786,"lng":3.32415,"measuredCount":4,"noServiceCount":0,"avgRsrp":-95,"earliestTimestamp":"2026-06-09T06:00:00.000Z","latestTimestamp":"2026-06-09T06:00:00.000Z"}]}
        ]},"revision":"d172e305","stats":{"avgRsrp":null,"sampleCount":15,"returnedCount":2,"hasMore":false,"truncated":false,"representation":"grid"},"timestampPrecision":"hour"}
        """#.utf8)
        let response = try MapTileAdmission.decode(AndroidCoverageTileResponse.self, from: body, expectedTile: grid)
        XCTAssertEqual(response.clusters.map(\.tech), ["4G", "4G", "5G"])
        XCTAssertEqual(response.clusters.map(\.count), [3, 8, 4])
        XCTAssertThrowsError(try MapTileAdmission.decode(AndroidCoverageTileResponse.self, from: body,
                                                         expectedTile: AndroidMapTile(z: 9, x: 261, y: 186)))
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
