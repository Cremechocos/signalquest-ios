import XCTest
import CoreLocation
@testable import SignalQuest

/// La visée est du calcul pur affiché comme un fait : « tu es dans le lobe »,
/// « vue dégagée », « masqué à 300 m ». Une erreur de signe ou de repère y est
/// invisible à l'œil et fausse un verdict que l'utilisateur croira sur parole.
final class AntennaSightGeometryTests: XCTestCase {

    // MARK: Angles

    func testElevationAngleIsPositiveWhenLookingUp() throws {
        let angle = try XCTUnwrap(
            AntennaSightGeometry.elevationAngle(distanceMeters: 100, deltaHeightMeters: 100)
        )
        XCTAssertEqual(angle, 45, accuracy: 0.001)
    }

    func testElevationAngleIsNegativeWhenLookingDown() throws {
        let angle = try XCTUnwrap(
            AntennaSightGeometry.elevationAngle(distanceMeters: 200, deltaHeightMeters: -20)
        )
        XCTAssertLessThan(angle, 0)
    }

    func testElevationAngleRejectsZeroDistance() {
        XCTAssertNil(AntennaSightGeometry.elevationAngle(distanceMeters: 0, deltaHeightMeters: 30))
    }

    /// Le point cardinal doit suivre la convention compas (0 = nord, sens
    /// horaire) et boucler proprement au passage par 360°.
    func testCardinalFollowsCompassConvention() {
        let north = AntennaSightGeometry.cardinal(for: 0)
        let east = AntennaSightGeometry.cardinal(for: 90)
        let south = AntennaSightGeometry.cardinal(for: 180)
        let west = AntennaSightGeometry.cardinal(for: 270)
        XCTAssertEqual(Set([north, east, south, west]).count, 4, "Les quatre cardinaux doivent être distincts")
        XCTAssertEqual(AntennaSightGeometry.cardinal(for: 358), north, "358° reste au nord")
        XCTAssertEqual(AntennaSightGeometry.cardinal(for: -2), north, "Un cap négatif se normalise")
        XCTAssertEqual(AntennaSightGeometry.cardinal(for: 450), east, "Un cap > 360 se normalise")
    }

    // MARK: Échantillonnage

    func testSamplePathKeepsBothEndsExact() {
        let user = CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72)
        let antenna = CLLocationCoordinate2D(latitude: 45.19, longitude: 5.73)
        let distance = CLLocation(latitude: user.latitude, longitude: user.longitude)
            .distance(from: CLLocation(latitude: antenna.latitude, longitude: antenna.longitude))

        let path = AntennaSightGeometry.samplePath(from: user, to: antenna, distanceMeters: distance)

        XCTAssertGreaterThanOrEqual(path.count, 10)
        XCTAssertLessThanOrEqual(path.count, 50, "La route backend est bornée : le profil ne doit pas la saturer")
        XCTAssertEqual(path.first?.latitude ?? 0, user.latitude, accuracy: 1e-9)
        XCTAssertEqual(path.last?.longitude ?? 0, antenna.longitude, accuracy: 1e-9)
    }

    /// Les points intermédiaires doivent se trouver SUR le segment, pas à côté :
    /// un profil échantillonné en biais mesurerait le relief d'un autre trajet.
    func testSamplePathStaysOnTheLine() {
        let user = CLLocationCoordinate2D(latitude: 45.0, longitude: 5.0)
        let antenna = CLLocationCoordinate2D(latitude: 45.02, longitude: 5.0)
        let distance = 2224.0
        let path = AntennaSightGeometry.samplePath(from: user, to: antenna, distanceMeters: distance)
        for point in path {
            XCTAssertEqual(point.longitude, 5.0, accuracy: 1e-4, "Un trajet plein nord garde la même longitude")
        }
    }

    // MARK: Fresnel

    func testFresnelRadiusPeaksInTheMiddle() {
        let middle = AntennaSightGeometry.fresnelRadius(d1: 500, d2: 500, frequencyMhz: 2100)
        let quarter = AntennaSightGeometry.fresnelRadius(d1: 250, d2: 750, frequencyMhz: 2100)
        XCTAssertGreaterThan(middle, quarter)
        XCTAssertEqual(middle, 5.97, accuracy: 0.05)
    }

    func testFresnelRadiusShrinksWithFrequency() {
        let low = AntennaSightGeometry.fresnelRadius(d1: 500, d2: 500, frequencyMhz: 700)
        let high = AntennaSightGeometry.fresnelRadius(d1: 500, d2: 500, frequencyMhz: 3500)
        XCTAssertGreaterThan(low, high, "Une bande basse a une zone de Fresnel plus large")
    }

    // MARK: Trous de relief

    func testInterpolatedGapsFillsHolesLinearly() {
        XCTAssertEqual(AntennaSightGeometry.interpolatedGaps([1, nil, 3]), [1, 2, 3])
        XCTAssertEqual(AntennaSightGeometry.interpolatedGaps([0, nil, nil, 30]), [0, 10, 20, 30])
    }

    /// Un trou en bordure reprend la valeur connue la plus proche : le traiter
    /// comme une altitude nulle inventerait une falaise au départ du profil.
    func testInterpolatedGapsExtendsEdges() {
        XCTAssertEqual(AntennaSightGeometry.interpolatedGaps([nil, 5, nil]), [5, 5, 5])
    }

    func testInterpolatedGapsReturnsEmptyWhenNothingIsKnown() {
        XCTAssertTrue(AntennaSightGeometry.interpolatedGaps([nil, nil, nil]).isEmpty)
    }

    // MARK: Profil et verdict

    private func flatProfile(
        distance: Double = 1000,
        ground: [Double?],
        clutter: [Double?] = [],
        antennaHeight: Double = 30
    ) -> [AntennaSightGeometry.ProfilePoint] {
        AntennaSightGeometry.buildProfile(
            distanceMeters: distance,
            groundElevations: ground,
            clutterHeights: clutter,
            antennaHeightMeters: antennaHeight,
            frequencyMhz: 2100
        )
    }

    func testSightLineRunsFromEyesToAntennaTop() throws {
        let profile = flatProfile(ground: Array(repeating: 0, count: 11))
        let first = try XCTUnwrap(profile.first)
        let last = try XCTUnwrap(profile.last)
        XCTAssertEqual(first.sightLineMeters, AntennaSightGeometry.observerHeightMeters, accuracy: 0.001)
        XCTAssertEqual(last.sightLineMeters, 30, accuracy: 0.001)
    }

    func testFlatTerrainIsClear() throws {
        let profile = flatProfile(ground: Array(repeating: 0, count: 11))
        let verdict = try XCTUnwrap(AntennaSightGeometry.verdict(for: profile, includesBuildings: false))
        XCTAssertEqual(verdict.level, .clear)
        XCTAssertNil(verdict.obstacleDistanceMeters)
    }

    func testHillBlocksTheSightLine() throws {
        var ground: [Double?] = Array(repeating: 0, count: 11)
        ground[5] = 100 // une crête à mi-parcours, bien au-dessus de la ligne
        let profile = flatProfile(ground: ground)
        let verdict = try XCTUnwrap(AntennaSightGeometry.verdict(for: profile, includesBuildings: false))
        XCTAssertEqual(verdict.level, .blocked)
        XCTAssertEqual(verdict.obstacleDistanceMeters ?? 0, 500, accuracy: 1)
        XCTAssertGreaterThan(verdict.obstacleOvershootMeters ?? 0, 0)
    }

    /// Un obstacle qui passe SOUS la ligne de visée mais mord la zone de Fresnel
    /// n'est ni « dégagé » ni « masqué » — c'est le cas que le verdict binaire
    /// raterait, et celui qui explique un débit qui s'effondre sans raison visible.
    func testObstacleInsideFresnelZoneIsGrazing() throws {
        var ground: [Double?] = Array(repeating: 0, count: 11)
        // Ligne de visée à mi-parcours ≈ 15,75 m ; Fresnel 60 % ≈ 3,6 m.
        // Un relief à 14 m passe dessous mais entame la zone.
        ground[5] = 14
        let profile = flatProfile(ground: ground)
        let verdict = try XCTUnwrap(AntennaSightGeometry.verdict(for: profile, includesBuildings: false))
        XCTAssertEqual(verdict.level, .grazing)
    }

    /// Le bâti s'ajoute au relief : un immeuble sur terrain plat doit bloquer.
    func testBuildingsAreAddedOnTopOfTerrain() throws {
        let ground: [Double?] = Array(repeating: 0, count: 11)
        var clutter: [Double?] = Array(repeating: 0, count: 11)
        clutter[5] = 60
        let profile = flatProfile(ground: ground, clutter: clutter)
        let verdict = try XCTUnwrap(AntennaSightGeometry.verdict(for: profile, includesBuildings: true))
        XCTAssertEqual(verdict.level, .blocked)
        XCTAssertTrue(verdict.includesBuildings)
    }

    /// Les extrémités touchent la ligne de visée par construction (le sol sous
    /// les pieds, le pied du pylône) : les compter rendrait tout trajet « masqué ».
    func testEndsAreNotTreatedAsObstacles() throws {
        var ground: [Double?] = Array(repeating: 0, count: 11)
        ground[0] = 0
        ground[10] = 200 // le site est perché : ce n'est pas un obstacle, c'est la cible
        let profile = flatProfile(ground: ground)
        let verdict = try XCTUnwrap(AntennaSightGeometry.verdict(for: profile, includesBuildings: false))
        XCTAssertNotEqual(verdict.level, .blocked)
    }

    func testProfileIsEmptyWhenTerrainIsUnknown() {
        let profile = flatProfile(ground: [nil, nil, nil])
        XCTAssertTrue(profile.isEmpty, "Sans relief connu, mieux vaut pas de profil qu'un profil à plat inventé")
    }
}
