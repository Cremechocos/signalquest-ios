import XCTest
@testable import SignalQuest

/// BANDES-OP, forme B : les bandes de chaque opérateur, par génération, sans
/// jamais emprunter celles du support ou d'un voisin.
final class GenerationBandsTests: XCTestCase {
    /// Support 1829761 (Grenoble), tuile servie en prod le 09/11.
    private let bouygues = ["GSM 900", "UMTS 900", "LTE 700", "LTE 800", "LTE 1800", "LTE 2600", "5G NR 2100", "5G NR 3500"]
    private let orange = ["UMTS 900", "LTE 700", "LTE 800", "LTE 1800", "LTE 2100", "LTE 2600", "5G NR 3500"]

    func testRowsByGenerationKeep2100WithItsGeneration() {
        let b = GenerationBands.rows(systems: bouygues)
        XCTAssertEqual(b.map(\.generation), ["5G", "4G", "3G", "2G"])
        XCTAssertEqual(b[0].bands, [2100, 3500])
        XCTAssertEqual(b[1].bands, [700, 800, 1800, 2600])
        XCTAssertEqual(b[3].bands, [900])
        let o = GenerationBands.rows(systems: orange)
        XCTAssertEqual(o.map(\.generation), ["5G", "4G", "3G"])
        XCTAssertEqual(o[0].bands, [3500])
        XCTAssertEqual(o[1].bands, [700, 800, 1800, 2100, 2600])
        XCTAssertFalse(GenerationBands.sameDeclaredBands([b, o]))
    }

    func testPlannedBandsStayInTheirRowAndSkipActiveOnes() {
        let rows = GenerationBands.rows(systems: ["LTE 800"], planned: ["4G 800", "4G 2600", "5G 3500"])
        XCTAssertEqual(rows.map(\.generation), ["5G", "4G"])
        XCTAssertEqual(rows[0].bands, [])
        XCTAssertEqual(rows[0].plannedBands, [3500])
        XCTAssertEqual(rows[1].bands, [800])
        XCTAssertEqual(rows[1].plannedBands, [2600])
    }

    func testSameDeclaredBandsIgnoresPlanned() {
        let a = GenerationBands.rows(systems: orange, planned: ["5G 2100"])
        let b = GenerationBands.rows(systems: orange.reversed())
        XCTAssertTrue(GenerationBands.sameDeclaredBands([a, b]))
        XCTAssertFalse(GenerationBands.sameDeclaredBands([a]))
        XCTAssertFalse(GenerationBands.sameDeclaredBands([[], []]))
    }

    func testSystemsAreNeverBorrowedFromTheSupportOrANeighbour() {
        var site = AntennaSite(id: "1829761", siteId: "1829761", anfrCode: nil, latitude: 45.19, longitude: 5.72,
                               operators: ["BOUYGUES", "ORANGE"], technologies: [], bands: [], azimuths: [],
                               sharingType: nil, crozonLeader: nil, address: nil, height: nil, owner: nil)
        site.radioSystems = bouygues + orange
        site.technologiesByOperator = ["BOUYGUES": bouygues]
        XCTAssertEqual(site.systems(attributedTo: "bouygues"), bouygues)
        XCTAssertNil(site.systems(attributedTo: "ORANGE"), "clé absente = inconnu, pas la liste du support")

        var single = AntennaSite(id: "1", siteId: "1", anfrCode: nil, latitude: 45.19, longitude: 5.72,
                                 operators: ["SFR"], technologies: [], bands: [], azimuths: [],
                                 sharingType: nil, crozonLeader: nil, address: nil, height: nil, owner: nil)
        single.radioSystems = ["LTE 800"]
        XCTAssertEqual(single.systems(attributedTo: "SFR"), ["LTE 800"])
        XCTAssertNil(single.systems(attributedTo: "ORANGE"))
    }
}
