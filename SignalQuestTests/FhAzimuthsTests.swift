import XCTest
@testable import SignalQuest

/// Un faisceau hertzien n'est pas un secteur : il raccorde le site au réseau au
/// lieu de desservir quelqu'un. Le backend l'écarte donc de `azimuts` — et ne
/// disait jusqu'ici que « oui, il y en a », sans jamais dire où. Ces tests
/// figent le champ additif qui porte enfin les directions, et le fait qu'il ne
/// contamine ni les secteurs ni les fiches servies par un backend antérieur.
final class FhAzimuthsTests: XCTestCase {

    private func details(_ json: String) throws -> AntennaDetails {
        try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data(json.utf8))
    }

    /// Site ANFR 0092700031 (SFR, Ariège) : quatre azimuts au registre, dont
    /// deux paraboles. Les secteurs et les faisceaux arrivent séparés.
    func testFhAzimuthsDecodeApartFromSectors() throws {
        let details = try details("""
        {
          "antenna": {
            "id": "24763", "supId": "24763", "anfrCode": "0092700031",
            "lat": 42.9158, "lng": 1.0139,
            "operators": ["SFR"], "technologies": ["5G", "4G"],
            "azimuts": [40, 300],
            "azimutsFh": [49, 282],
            "technical": { "hasFh": true }
          }
        }
        """)
        let core = try XCTUnwrap(details.core)
        XCTAssertEqual(core.azimuts, [40, 300], "les secteurs ne portent aucun faisceau")
        XCTAssertEqual(core.azimutsFh, [49, 282])
        XCTAssertTrue(core.hasFhLink)
    }

    /// Backend antérieur au champ : la fiche ne doit rien inventer, mais garde
    /// le seul fait connu — le site relaie, on ignore vers où.
    func testLegacyPayloadKeepsTheFlagWithoutDirections() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "24763", "supId": "24763", "anfrCode": "0092700031",
            "lat": 42.9, "lng": 1.0, "operators": ["SFR"], "technologies": ["4G"],
            "azimuts": [40, 300],
            "technical": { "hasFh": true }
          }
        }
        """).core)
        XCTAssertTrue(core.azimutsFh.isEmpty)
        XCTAssertTrue(core.hasFhLink, "le drapeau du registre suffit à l'affirmer")
    }

    /// Les directions seules suffisent aussi : un dataset peut les publier sans
    /// le booléen. L'inverse d'une fiche muette.
    func testDirectionsAloneAssertTheLink() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "1", "supId": "1", "lat": 48.8, "lng": 2.3,
            "operators": ["ORANGE"], "technologies": ["5G"],
            "azimuts": [0, 120, 240], "azimutsFh": [95]
          }
        }
        """).core)
        XCTAssertEqual(core.azimutsFh, [95])
        XCTAssertTrue(core.hasFhLink)
    }

    /// Le détail : diamètre de parabole et site visé, déduit par le backend.
    func testFhLinksCarryDishAndTarget() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "24763", "supId": "24763", "lat": 42.9, "lng": 1.0,
            "operators": ["SFR"], "technologies": ["5G"],
            "azimuts": [40, 300], "azimutsFh": [49, 282],
            "fhLinks": [
              { "azimuth": 282, "dishMeters": 1.2,
                "target": { "supId": "565115", "anfrCode": "0312700293", "operator": "SFR", "distanceKm": 13 } },
              { "azimuth": 49, "dishMeters": 0.9,
                "target": { "supId": "1852108", "anfrCode": "0092700046", "operator": "SFR", "distanceKm": 14.7 } }
            ]
          }
        }
        """).core)
        // Triés par azimut : la fiche les liste dans l'ordre de la rose, pas
        // dans celui où le backend les a écrits.
        XCTAssertEqual(core.fhLinks.map(\.azimuth), [49, 282])
        XCTAssertEqual(core.fhLinks.first?.dishMeters, 0.9)
        XCTAssertEqual(core.fhLinks.first?.target?.supId, "1852108")
        XCTAssertEqual(core.fhLinks.first?.target?.operatorName, "SFR", "la clé JSON est `operator`, mot réservé en Swift")
        XCTAssertEqual(core.fhLinks.last?.target?.distanceKm, 13)
    }

    /// Une parabole sans partenaire réciproque garde sa direction et sa taille :
    /// « on ne sait pas vers quoi » n'est pas « pas de faisceau ».
    func testBeamWithoutTargetStaysListed() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "35519", "supId": "35519", "lat": 50.4, "lng": 2.8,
            "operators": ["SFR"], "technologies": ["4G"],
            "azimuts": [0, 170, 270], "azimutsFh": [28, 138, 340],
            "fhLinks": [
              { "azimuth": 28, "dishMeters": 0.3 },
              { "azimuth": 138, "dishMeters": 0.6,
                "target": { "supId": "3012724", "anfrCode": "0622700733", "operator": "SFR", "distanceKm": 4.7 } },
              { "azimuth": 340, "dishMeters": 0.6 }
            ]
          }
        }
        """).core)
        XCTAssertEqual(core.fhLinks.count, 3)
        XCTAssertNil(core.fhLinks[0].target)
        XCTAssertEqual(core.fhLinks[0].dishMeters, 0.3)
        XCTAssertEqual(core.fhLinks[1].target?.supId, "3012724")
    }

    /// Backend qui ne sert que les directions : la fiche doit quand même avoir
    /// des faisceaux à dessiner, sans détail.
    func testBeamsFallBackToBareDirections() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "1", "supId": "1", "lat": 48.8, "lng": 2.3,
            "operators": ["SFR"], "technologies": ["4G"],
            "azimuts": [0, 120], "azimutsFh": [95, 275]
          }
        }
        """).core)
        XCTAssertTrue(core.fhLinks.isEmpty)
        XCTAssertEqual(core.fhBeams.map(\.azimuth), [95, 275])
        XCTAssertNil(core.fhBeams.first?.dishMeters)
    }

    /// Un site sans parabole ne doit surtout pas porter la pastille.
    func testSiteWithoutFhClaimsNothing() throws {
        let core = try XCTUnwrap(try details("""
        {
          "antenna": {
            "id": "2", "supId": "2", "lat": 45.1, "lng": 5.7,
            "operators": ["FREE"], "technologies": ["4G"],
            "azimuts": [30, 150, 270], "azimutsFh": [],
            "technical": { "hasFh": false }
          }
        }
        """).core)
        XCTAssertTrue(core.azimutsFh.isEmpty)
        XCTAssertFalse(core.hasFhLink)
    }
}
