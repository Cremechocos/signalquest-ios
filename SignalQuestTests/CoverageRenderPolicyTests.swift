import XCTest
@testable import SignalQuest

/// Vérrouille la politique de rendu de la couche couverture (Lot M1) : tous les points
/// bruts dès le « zoom ville », clusters seulement au niveau région/pays, et caps relevés.
final class CoverageRenderPolicyTests: XCTestCase {

    func testRawPointsFromCityZoom() {
        // À partir du zoom ville (~11) : points bruts, pas de clusters.
        let mode = CoverageRenderPolicy.mode(zoom: 11, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(mode.useRawPoints)
        XCTAssertFalse(mode.useClusters)
    }

    func testRawPointsAtStreetZoom() {
        let mode = CoverageRenderPolicy.mode(zoom: 15, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(mode.useRawPoints)
        XCTAssertFalse(mode.useClusters)
    }

    func testClustersOnlyBelowCityZoom() {
        // Niveau région/pays (< 11) avec clusters disponibles : clusters seulement.
        let mode = CoverageRenderPolicy.mode(zoom: 8, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(mode.useClusters)
        XCTAssertFalse(mode.useRawPoints)
    }

    func testRawPointsAtLowZoomWhenNoClusters() {
        // Bas zoom mais pas de clusters dans la tuile : on rend les points bruts (repli).
        let mode = CoverageRenderPolicy.mode(zoom: 6, hasClusters: false, hasBandFilter: false)
        XCTAssertTrue(mode.useRawPoints)
        XCTAssertFalse(mode.useClusters)
    }

    func testBandFilterForcesRawPointsAtAnyZoom() {
        // Un filtre bande impose les points bruts (filtrage client), jamais de clusters.
        let mode = CoverageRenderPolicy.mode(zoom: 5, hasClusters: true, hasBandFilter: true)
        XCTAssertTrue(mode.useRawPoints)
        XCTAssertFalse(mode.useClusters)
    }

    func testModesAreMutuallyExclusive() {
        for zoom in stride(from: 3.0, through: 18.0, by: 1.0) {
            for hasClusters in [true, false] {
                for hasBand in [true, false] {
                    let mode = CoverageRenderPolicy.mode(zoom: zoom, hasClusters: hasClusters, hasBandFilter: hasBand)
                    XCTAssertFalse(mode.useClusters && mode.useRawPoints,
                                   "clusters et points bruts ne doivent jamais être actifs ensemble (z=\(zoom))")
                    XCTAssertTrue(mode.useClusters || mode.useRawPoints,
                                  "au moins un mode doit être actif (z=\(zoom))")
                }
            }
        }
    }

    func testCapsRaisedFromOldDefaults() {
        // Garde-fou anti-régression : les anciens plafonds (900/250/1200) sont relevés.
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.pointCapPerTile, 2000)
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.fallbackCap, 5000)
    }
}
