import XCTest
import SwiftUI
@testable import SignalQuest

/// Sur un support partagé, chaque opérateur a ses propres azimuts — et pointe
/// parfois exactement la même direction qu'un autre. Ces tests figent le
/// décodage du champ backend et le regroupement par direction, à partir de sites
/// ANFR réels relevés en production (août 2026).
final class AzimuthBeamGroupingTests: XCTestCase {

    private func marker(_ json: String) throws -> AndroidAntennaMarker {
        try JSONDecoder.signalQuest.decode(AndroidAntennaMarker.self, from: Data(json.utf8))
    }

    /// Site 1342522 : SFR et Orange sur le même support, directions différentes.
    func testSharedSiteDecodesAzimuthsPerOperator() throws {
        let marker = try marker("""
        {
          "id": "1342522", "supId": "1342522", "lat": 48.85, "lng": 2.35,
          "operators": ["SFR", "ORANGE"], "technologies": ["4G"],
          "azimuts": [0, 120, 240],
          "azimutsByOperator": { "SFR": [0, 120, 240], "ORANGE": [20, 100, 195, 285] },
          "bands": [20]
        }
        """)
        XCTAssertEqual(marker.azimutsByOperator["SFR"], [0, 120, 240])
        XCTAssertEqual(marker.azimutsByOperator["ORANGE"], [20, 100, 195, 285])
        // `azimuts` reste la liste historique : un site partagé n'en montrait
        // qu'une facette, et les clients qui l'utilisent encore ne changent pas.
        XCTAssertEqual(marker.azimuts, [0, 120, 240])
    }

    /// Une tuile servie avant le déploiement du champ n'a pas la clé : elle doit
    /// se décoder sans erreur et rendre exactement comme avant.
    func testLegacyTileHasNoPerOperatorAzimuths() throws {
        let marker = try marker("""
        {
          "id": "3079254", "supId": "3079254", "lat": 45.18, "lng": 5.72,
          "operators": ["SFR"], "technologies": ["4G"], "azimuts": [30, 150, 270], "bands": []
        }
        """)
        XCTAssertTrue(marker.azimutsByOperator.isEmpty)
        XCTAssertEqual(marker.azimuts, [30, 150, 270])
    }

    // MARK: Regroupement par direction

    /// Site 1853200 : Bouygues et Free déclarent tous deux 0/120/240. Les trois
    /// directions doivent devenir trois faisceaux BICOLORES, pas six traits.
    func testIdenticalAzimuthsCollapseIntoOneBicolourBeam() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["BOUYGUES", "FREE"],
            azimuthsByOperator: ["BOUYGUES": [0, 120, 240], "FREE": [0, 120, 240]],
            tint: { $0 == "BOUYGUES" ? .blue : .gray }
        )
        XCTAssertEqual(beams.count, 3)
        XCTAssertEqual(beams.map(\.azimuth), [0, 120, 240])
        for beam in beams {
            XCTAssertEqual(beam.tints, [.blue, .gray], "chaque direction porte les deux opérateurs")
        }
    }

    /// Directions distinctes : un faisceau par azimut, une seule couleur chacun.
    func testDistinctAzimuthsStaySeparate() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["SFR", "ORANGE"],
            azimuthsByOperator: ["SFR": [0, 120, 240], "ORANGE": [20, 100, 195, 285]],
            tint: { $0 == "SFR" ? .red : .orange }
        )
        XCTAssertEqual(beams.count, 7)
        XCTAssertTrue(beams.allSatisfy { $0.tints.count == 1 })
        XCTAssertEqual(beams.map(\.azimuth), [0, 20, 100, 120, 195, 240, 285])
    }

    /// Deux déclarations à 3° d'écart visent la même chose : les garder séparées
    /// donnerait deux traits superposés dont un seul serait visible.
    func testNearlyIdenticalAzimuthsMerge() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["SFR", "ORANGE"],
            azimuthsByOperator: ["SFR": [0], "ORANGE": [3]],
            tint: { $0 == "SFR" ? .red : .orange }
        )
        XCTAssertEqual(beams.count, 1)
        XCTAssertEqual(beams[0].tints, [.red, .orange])
    }

    /// Le seuil ne doit jamais fondre deux secteurs distincts : 0° et 120° sont
    /// deux directions, quoi qu'il arrive.
    func testRealSectorsAreNeverMerged() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["SFR", "ORANGE"],
            azimuthsByOperator: ["SFR": [0], "ORANGE": [120]],
            tint: { _ in .red }
        )
        XCTAssertEqual(beams.count, 2)
    }

    /// Le passage par 0° ne doit pas casser la comparaison : 358° et 2° sont à
    /// 4° l'un de l'autre, pas à 356°.
    func testWrapAroundNorthMerges() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["SFR", "ORANGE"],
            azimuthsByOperator: ["SFR": [358], "ORANGE": [2]],
            tint: { $0 == "SFR" ? .red : .orange }
        )
        XCTAssertEqual(beams.count, 1, "358° et 2° pointent la même direction")
        XCTAssertEqual(beams[0].tints, [.red, .orange])
    }

    /// L'ordre des couleurs suit celui des opérateurs du site, pas celui du
    /// dictionnaire : sinon la séquence des tirets sauterait d'un rendu à l'autre.
    func testTintOrderFollowsSiteOperators() {
        let beams = MapExplorerViewModel.groupAzimuthBeams(
            operators: ["ORANGE", "SFR"],
            azimuthsByOperator: ["SFR": [0], "ORANGE": [0]],
            tint: { $0 == "SFR" ? .red : .orange }
        )
        XCTAssertEqual(beams[0].tints, [.orange, .red])
    }
}
