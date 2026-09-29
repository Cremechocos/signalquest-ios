import XCTest
@testable import SignalQuest

/// « Voir sur la carte » cadrait sur un point dont la couche était éteinte
/// (MES-15) ; la légende disait « 4G » à Montréal (UI-02).
@MainActor
final class MapFocusLayerTests: XCTestCase {

    private func outage(latitude: Double, longitude: Double) throws -> CommunityOutage {
        try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: Data("""
        {"id":"outage-A","targetId":"A","marketCode":"FR","operatorKey":"SFR","latitude":\(latitude),"longitude":\(longitude)}
        """.utf8))
    }

    func testOpeningAnOutageLightsTheOutageLayer() throws {
        let router = AppRouter()
        router.route(toCommunityOutage: try outage(latitude: 45.76, longitude: 4.83))
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertNotNil(router.pendingMapFocus)
        XCTAssertEqual(router.pendingMapLayer, .outage)
    }

    /// (0, 0) est le repli du décodeur : ni cadrage, ni couche à allumer.
    func testOutageWithoutPositionNeitherFocusesNorLightsALayer() throws {
        let router = AppRouter()
        router.route(toCommunityOutage: try outage(latitude: 0, longitude: 0))
        XCTAssertNil(router.pendingMapFocus)
        XCTAssertNil(router.pendingMapLayer)
    }

    /// « Aucun » restait en français dans la légende de l'app anglaise (UI-03) ;
    /// les libellés de la fiche antenne n'avaient pas de clé (TRX-06). Lu dans
    /// la table compilée : cette suite tourne en français.
    func testMapLabelsHaveEnglish() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
            subdirectory: "en.lproj"))
        let english = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        let expected = ["Aucun": "None", "Partage": "Sharing", "Numéro du support": "Structure number",
                        "Légende des antennes": "Antenna legend", "Identifiants de cellule": "Cell identifiers",
                        "Tu confirmes": "You confirm"]
        for (key, value) in expected {
            XCTAssertEqual(english[key], value, key)
        }
    }

    func testNorthAmericaReadsLTEInTheGenerationLegend() {
        XCTAssertEqual(CoverageGenerationBand.g4.title(forMarket: "CA"), "LTE")
        XCTAssertEqual(CoverageGenerationBand.g4.title(forMarket: "US"), "LTE")
        XCTAssertEqual(CoverageGenerationBand.g4.title(forMarket: "FR"), CoverageGenerationBand.g4.title)
        XCTAssertEqual(CoverageGenerationBand.g5.title(forMarket: "CA"), CoverageGenerationBand.g5.title)
        XCTAssertEqual(CoverageGenerationBand.g4.title(forMarket: nil), CoverageGenerationBand.g4.title)
    }
}
