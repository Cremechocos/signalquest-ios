import XCTest
@testable import SignalQuest

/// Réglages d'affichage de la carte : croisement des bandes et style d'azimut.
/// Tous deux persistent entre deux lancements, et leur valeur par défaut doit
/// reproduire le comportement d'avant — sinon la carte changerait toute seule
/// pour les utilisateurs existants.
final class MapDisplayPreferencesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MapBandMatchStore.reset()
        MapAzimuthStyleStore.reset()
    }

    override func tearDown() {
        MapBandMatchStore.reset()
        MapAzimuthStyleStore.reset()
        super.tearDown()
    }

    // MARK: Croisement des bandes

    func testBandMatchDefaultsToTheHistoricalBehaviour() {
        XCTAssertEqual(MapBandMatchStore.last(), .any)
    }

    func testBandMatchRoundTrips() {
        for mode in BandMatchMode.allCases {
            MapBandMatchStore.save(mode)
            XCTAssertEqual(MapBandMatchStore.last(), mode)
        }
    }

    /// La valeur brute part telle quelle en `?bandMatch=` : la changer casserait
    /// le contrat avec le backend, qui attend ces trois jetons exacts.
    func testBandMatchRawValuesMatchTheApiContract() {
        XCTAssertEqual(BandMatchMode.any.rawValue, "any")
        XCTAssertEqual(BandMatchMode.all.rawValue, "all")
        XCTAssertEqual(BandMatchMode.only.rawValue, "only")
    }

    /// Une valeur écrite par une version future (ou corrompue) ne doit pas
    /// planter ni bloquer la carte : on retombe sur le défaut.
    func testUnknownStoredBandMatchFallsBackToAny() {
        UserDefaults.standard.set("quelque-chose", forKey: MapBandMatchStore.key)
        XCTAssertEqual(MapBandMatchStore.last(), .any)
    }

    // MARK: Style d'azimut

    /// Les traits sont le défaut : ils restent lisibles en zone dense, et ce sont
    /// eux qui portent la couleur par opérateur sur un support partagé.
    func testAzimuthStyleDefaultsToLines() {
        XCTAssertEqual(MapAzimuthStyleStore.last(), .lines)
    }

    func testAzimuthStyleRoundTrips() {
        for style in AzimuthStyle.allCases {
            MapAzimuthStyleStore.save(style)
            XCTAssertEqual(MapAzimuthStyleStore.last(), style)
        }
    }

    func testUnknownStoredAzimuthStyleFallsBackToTheDefault() {
        UserDefaults.standard.set("fleches", forKey: MapAzimuthStyleStore.key)
        XCTAssertEqual(MapAzimuthStyleStore.last(), .lines)
    }

    /// Trois styles proposés, dont « aucun » : le quatrième (flèches) a été
    /// écarté, ce test évite qu'il revienne par inadvertance.
    func testThreeAzimuthStylesAreOffered() {
        XCTAssertEqual(AzimuthStyle.allCases, [.lobes, .lines, .hidden])
    }
}
