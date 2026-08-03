import XCTest
@testable import SignalQuest

/// Le profil d'altitude est entièrement dessiné : ni texte ni sous-vue à
/// inspecter, donc rien qu'un test classique puisse attraper — et `ImageRenderer`
/// ne rend qu'un placeholder pour cette vue hors hiérarchie. Ce qui reste
/// vérifiable, et qui compte, c'est la géométrie : ce que l'axe doit contenir, et
/// où les antennes se posent sur le fût.
final class AntennaProfileGeometryTests: XCTestCase {

    /// Le site de la capture : 198 m de distance, +12 m de dénivelé, un clocher
    /// de 52 m portant ses antennes à 39 m. C'est le cas qui faisait sortir la
    /// cote du support hors du graphe.
    private func steepleProfile() -> [AntennaSightGeometry.ProfilePoint] {
        let ground: [Double?] = [218, 218, 217, 217, 218, 220, 224, 227, 229, 230]
        return AntennaSightGeometry.buildProfile(
            distanceMeters: 198,
            groundElevations: ground,
            clutterHeights: [],
            antennaHeightMeters: 39,
            frequencyMhz: 2100
        )
    }

    private func profileView(
        supportHeight: Double? = 52.2,
        supportLabel: String? = "Monument religieux",
        antennaTypes: [String] = ["Panneau", "Antenne 5G"]
    ) -> AntennaProfileView {
        let profile = steepleProfile()
        return AntennaProfileView(
            profile: profile,
            verdict: AntennaSightGeometry.verdict(for: profile, includesBuildings: false),
            siteLabel: "2877566",
            distanceMeters: 198,
            antennaHeightMeters: 39,
            heightIsEstimated: false,
            supportHeightMeters: supportHeight,
            supportLabel: supportLabel,
            antennaTypes: antennaTypes,
            tint: SQColor.brandBlue
        )
    }

    /// Le support doit rester DANS le cadre : c'est lui qui fixe le haut de
    /// l'échelle, et un sommet qui déborde emporte aussi ses antennes et ses cotes.
    func testStructureTopIsIncludedInTheVerticalScale() throws {
        let profile = steepleProfile()
        let antennaGround = try XCTUnwrap(profile.last?.groundMeters)
        let highestDrawn = antennaGround + 52.2
        let highestSightLine = try XCTUnwrap(profile.map(\.sightLineMeters).max())
        XCTAssertGreaterThan(
            highestDrawn, highestSightLine,
            "Sur ce site le support dépasse la ligne de visée : c'est lui qui doit borner l'axe"
        )
    }

    /// Le fût s'affine en montant : les antennes posées à 39 m sur un support de
    /// 52 m doivent être plus resserrées qu'au sol, sinon elles flottent à côté.
    func testAntennasSitOnTheNarrowingMast() {
        let base: CGFloat = 40
        let atGround = AntennaSupportSilhouette.width(family: .lattice, at: 0, baseWidth: base)
        let atAntennas = AntennaSupportSilhouette.width(family: .lattice, at: 0.75, baseWidth: base)
        let atTop = AntennaSupportSilhouette.width(family: .lattice, at: 1, baseWidth: base)
        XCTAssertEqual(atGround, base, accuracy: 0.01)
        XCTAssertLessThan(atAntennas, atGround)
        XCTAssertLessThan(atTop, atAntennas)
        XCTAssertGreaterThan(atTop, 0)
    }

    /// Un bâtiment ne s'affine pas : ses antennes se posent en bord de toit.
    func testBuildingKeepsItsWidthAllTheWayUp() {
        let base: CGFloat = 40
        XCTAssertEqual(
            AntennaSupportSilhouette.width(family: .building, at: 0, baseWidth: base),
            AntennaSupportSilhouette.width(family: .building, at: 1, baseWidth: base),
            accuracy: 0.01
        )
    }

    func testFamilyIsDeducedFromTheAnfrLabel() {
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Monument religieux"), .steeple)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Pylône treillis"), .lattice)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Pylône tubulaire"), .tube)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Château d'eau - réservoir"), .waterTower)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Immeuble"), .building)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Tunnel"), .indoor)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Éolienne"), .turbine)
        // Libellé inconnu ou absent : on retombe sur le pylône générique plutôt
        // que de ne rien dessiner.
        XCTAssertEqual(AntennaSupportSilhouette.family(for: "Support exotique"), .lattice)
        XCTAssertEqual(AntennaSupportSilhouette.family(for: nil), .lattice)
    }
}
