import XCTest
@testable import SignalQuest

/// Vérrouille la politique de rendu de la couche couverture (Lot M1) : rendu piloté
/// par la donnée (points si présents, sinon clusters), caps relevés, seuil de fetch.
final class CoverageRenderPolicyTests: XCTestCase {

    func testRendersPointsWhenPresent() {
        let m = CoverageRenderPolicy.mode(hasPoints: true, hasClusters: false, hasBandFilter: false)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testRendersClustersWhenOnlyClusters() {
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(m.useClusters)
        XCTAssertFalse(m.useRawPoints)
    }

    func testPointsPreferredOverClusters() {
        // Une tuile contenant les deux : on privilégie les points (vérité détaillée).
        let m = CoverageRenderPolicy.mode(hasPoints: true, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testBandFilterForcesPoints() {
        // Le filtre bande s'applique côté client sur les points bruts → jamais de clusters.
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: true, hasBandFilter: true)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testEmptyTileRendersNothing() {
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: false, hasBandFilter: false)
        XCTAssertFalse(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testModesAreMutuallyExclusive() {
        for hasPoints in [true, false] {
            for hasClusters in [true, false] {
                for hasBand in [true, false] {
                    let m = CoverageRenderPolicy.mode(hasPoints: hasPoints, hasClusters: hasClusters, hasBandFilter: hasBand)
                    XCTAssertFalse(m.useClusters && m.useRawPoints,
                                   "clusters et points ne doivent jamais être actifs ensemble")
                }
            }
        }
    }

    func testFetchThresholdIsCityZoom() {
        // Le client demande les points bruts dès le zoom ville (z11).
        XCTAssertEqual(CoverageRenderPolicy.rawPointsFromZoom, 11)
    }

    func testCapsRaisedFromOldDefaults() {
        // Garde-fou anti-régression : les anciens plafonds (900/250/1200) sont relevés.
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.pointCapPerTile, 2000)
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.fallbackCap, 5000)
    }
}
