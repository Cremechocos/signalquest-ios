import XCTest
@testable import SignalQuest

/// Signalement d'un opérateur porteur erroné sur un site partagé (demande
/// d'Alexandre, 29/09) : `POST /api/antennas/reports` avec `incorrect_leader`.
final class AntennaLeaderReportTests: XCTestCase {
    func testCrozonSiteOffersTheOtherOperatorOfThePair() throws {
        let report = try XCTUnwrap(AntennaLeaderReport(sharingKind: "crozon", crozonLeader: "SFR",
                                                        zbLeader: nil, operators: ["SFR", "BOUYGUES"]))
        XCTAssertEqual(report.currentLeader, "SFR")
        XCTAssertEqual(report.choices, ["BOUYGUES"])
    }

    func testWhiteZoneSiteOffersThePresentOperatorsExceptTheCurrentLeader() throws {
        let report = try XCTUnwrap(AntennaLeaderReport(sharingKind: "ZB", crozonLeader: nil, zbLeader: "Orange",
                                                        operators: ["SFR", "Bouygues Telecom", "ORANGE", "Free"]))
        XCTAssertEqual(report.sharingKind, "zb")
        XCTAssertEqual(report.currentLeader, "ORANGE")
        XCTAssertEqual(report.choices, ["SFR", "BOUYGUES", "FREE"])
    }

    func testOptionIsHiddenOnUnsharedSites() {
        XCTAssertNil(AntennaLeaderReport(sharingKind: nil, crozonLeader: nil, zbLeader: nil, operators: ["SFR"]))
        XCTAssertNil(AntennaLeaderReport(sharingKind: "mutualisé", crozonLeader: nil, zbLeader: nil,
                                         operators: ["SFR", "ORANGE"]))
        XCTAssertNil(AntennaLeaderReport(sharingKind: "zb", crozonLeader: nil, zbLeader: "SFR", operators: ["SFR"]),
                     "Aucun autre opérateur à proposer")
    }

    func testLeaderTypeUsesThePickerRatherThanFreeText() {
        XCTAssertFalse(AntennaReportType.incorrectLeader.suggestsValues)
        XCTAssertEqual(AntennaReportType.incorrectLeader.rawValue, "incorrect_leader")
    }
}
