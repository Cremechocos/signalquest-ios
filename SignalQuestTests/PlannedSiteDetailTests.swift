import XCTest
@testable import SignalQuest

/// Fiche d'un site prévisionnel : le flux ne porte pas d'adresse, mais le support
/// ANFR apparié (`activation.supId`) la donne. Réponses réelles de
/// `/api/map/planned-sites` lues le 10/11.
final class PlannedSiteDetailTests: XCTestCase {
    func testPlannedSiteKeepsItsAnfrMastAndMarket() throws {
        let json = #"""
        {"sourceId":"fr-bouygues-planned","market":"FR","operator":"BOUYGUES","territory":null,"lat":49.03382,"lon":2.45247,
         "codeSite":null,"idStation":null,"plannedKey":"feed:BOUYGUES:49.03382,2.45247","referenceId":"49.03382,2.45247",
         "departement":"95","insee":"95280","commune":"GOUSSAINVILLE","date5g":null,"sourceUpdatedAt":"2026-02-19T10:35:33.000Z",
         "technologies":{},"activation":{"status":"declared","matchType":"proximity","anfrStationId":"0952750706","supId":"2903682",
         "distanceM":120,"lastInServiceDate":null,"activeTechnologies":[],"plannedTechnologies":[],"confirmedTechnologies":[],"pendingTechnologies":[]}}
        """#
        let site = try JSONDecoder.signalQuest.decode(PlannedSiteLive.self, from: Data(json.utf8))
        XCTAssertEqual(site.market, "FR")
        XCTAssertEqual(site.insee, "95280")
        XCTAssertEqual(site.activation?.supId, "2903682")
        XCTAssertEqual(site.activation?.anfrStationId, "0952750706")
        XCTAssertEqual(site.activation?.matchType, "proximity")
        XCTAssertNotNil(site.sourceUpdatedAt)

        let orange = #"""
        {"sourceId":"fr-orange-planned","market":"FR","operator":"ORANGE","lat":47.32304,"lon":4.911944,"codeSite":"00000079E1",
         "idStation":"0212290034","plannedKey":"feed:ORANGE:0212290034","referenceId":"0212290034","departement":null,"insee":null,
         "commune":null,"date5g":"2026-09-30","technologies":{"4G":true,"5G 700":true},
         "activation":{"status":"active","matchType":"anfr","anfrStationId":"0212290034","supId":2111318,"distanceM":2,
         "lastInServiceDate":"2026-07-02","activeTechnologies":["4G"],"plannedTechnologies":["4G"],"confirmedTechnologies":["4G"],"pendingTechnologies":[]}}
        """#
        let matched = try JSONDecoder.signalQuest.decode(PlannedSiteLive.self, from: Data(orange.utf8))
        XCTAssertEqual(matched.activation?.supId, "2111318", "Un supId numérique est lu aussi")
        XCTAssertNil(matched.insee)
    }
}
