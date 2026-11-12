import XCTest
@testable import SignalQuest

/// Page « Porteuses » d'un site canadien (contrat ISED r1, étapes b, c, g1), mêmes règles
/// que la fiche Web (`apps/web/lib/ised-sheet.ts`).
final class ISEDCarrierSheetTests: XCTestCase {
    private let fr = Locale(identifier: "fr_FR")
    private let nbsp = "\u{00A0}"

    private func carriers(_ json: String) throws -> [AntennaRadioCarrier] {
        try JSONDecoder().decode([AntennaRadioCarrier].self, from: Data(json.utf8))
    }

    private func value(_ rows: [ISEDCarrierSheet.Row], _ label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    /// LM110-01 tel que servi le 11/11 : n78 de 50 MHz en TDD (et non 250), un secteur à 210°.
    func testTDDCarrierReadsItsRealChannelAndDownlinkShare() throws {
        let list = try carriers("""
        [{"id":"a","source":"ISED","technology":"NR","band":78,"bandLabel":"n78","bandId":"n78","technologyDetail":"5GNR",
          "bandInferred":true,"duplex":"TDD","txFrequencyMhz":3535,"rxFrequencyMhz":3535,"txRangeMhz":[3510,3560],
          "rxRangeMhz":[3510,3560],"bandwidthMhz":50,"downlinkAllocationPercent":70,"txPowerDbm":48.7,"txPowerW":73.54,
          "txPowerUnitInferred":"W","sectorAzimuthDeg":210,"sectorBeamwidthDeg":null,"omni":false,"antennaType":"AAS",
          "cellIds":["302500-25090-163891786"],"physicalIds":["117"],"dateLastChanged":"2022-11-01"}]
        """)
        let sheet = ISEDCarrierSheet.make(carriers: list, azimuths: [210], datasetPublishedAt: "2026-11-03", locale: fr)

        XCTAssertEqual(sheet.sectors.count, 1)
        let sector = sheet.sectors[0]
        XCTAssertEqual(sector.title, "Secteur 1 · 210° sud-ouest")
        XCTAssertEqual(value(sector.rows, "Type d’antenne"), "active (AAS)")
        // Aucun champ d'antenne g1 sur ce site : une phrase, pas des rangées vides.
        XCTAssertNotNil(sector.note)

        let carrier = try XCTUnwrap(sector.carriers.first)
        XCTAssertEqual(carrier.title, "5G NR")
        XCTAssertEqual(carrier.bandId, "n78")
        XCTAssertEqual(value(carrier.rows, "Largeur du canal"), "50\(nbsp)MHz")
        let low = 3510.0.formatted(.number.locale(fr)), high = 3560.0.formatted(.number.locale(fr))
        XCTAssertEqual(value(carrier.rows, "Fréquences"), "\(low)–\(high)\(nbsp)MHz")
        XCTAssertEqual(value(carrier.rows, "Duplex"), "TDD")
        XCTAssertEqual(value(carrier.rows, "Part du temps en DL"), 0.7.formatted(.percent.locale(fr)))
        XCTAssertNil(value(carrier.rows, "Fréquences DL"), "un canal TDD n'a pas de DL ni d'UL séparés")
        XCTAssertEqual(value(carrier.rows, "Puissance d’émission"), "48,7\(nbsp)dBm (≈\(nbsp)74\(nbsp)W)")
        XCTAssertEqual(value(carrier.rows, "PCI"), "117")

        XCTAssertEqual(sheet.source, [
            "Registre ISED (Canada), extrait du 3 nov. 2026.",
            "Configuration en service depuis le 1er nov. 2022.",
            "Bande déduite des fréquences.",
            "Puissance déclarée en watts par le titulaire, convertie en dBm."
        ])
    }

    /// FDD : DL et UL séparés ; une puissance sans watts n'invente rien ; une antenne omni
    /// a sa propre carte et une porteuse sans azimut va dans « Orientation inconnue ».
    func testFDDOmniAndUnknownCarriersGetTheirOwnCards() throws {
        let list = try carriers("""
        [{"id":"o","technology":"LTE","band":12,"bandId":"B12","technologyDetail":"LTE","bandInferred":false,"duplex":"FDD",
          "txRangeMhz":[729,739],"rxRangeMhz":[699,709],"bandwidthMhz":10,"txPowerDbm":43,"txPowerUnitInferred":"dBm",
          "sectorAzimuthDeg":null,"omni":true,"cellIds":[],"physicalIds":[],"dateLastChanged":null},
         {"id":"s","technology":"LTE","band":66,"bandId":"B66","technologyDetail":"LTE","duplex":"FDD","txFrequencyMhz":2140,
          "rxFrequencyMhz":1740,"bandwidthMhz":20,"sectorAzimuthDeg":80,"sectorBeamwidthDeg":65,"omni":false,
          "gainDbi":17.5,"tiltDeg":4,"antennaHeightM":31,"antennaCount":4,"antennaManufacturer":"Ericsson","antennaType":"NAC",
          "cellIds":[],"physicalIds":[]},
         {"id":"u","technology":"LTE","band":66,"bandId":"B66","technologyDetail":"LTE","bandwidthMhz":5,"omni":false,
          "cellIds":[],"physicalIds":[]}]
        """)
        let sheet = ISEDCarrierSheet.make(carriers: list, azimuths: [80, 200], datasetPublishedAt: nil, locale: fr)

        XCTAssertEqual(sheet.sectors.map(\.title), [
            "Secteur 1 · 80° est", "Secteur 2 · 200° sud", "Antennes omnidirectionnelles", "Orientation inconnue"
        ])
        let east = sheet.sectors[0]
        XCTAssertEqual(value(east.rows, "Ouverture horizontale"), "65°")
        XCTAssertEqual(value(east.rows, "Type d’antenne"), "Ericsson · non active, corrélée (NAC), 4 antennes")
        XCTAssertEqual(value(east.rows, "Hauteur de l’antenne"), "31\(nbsp)m")
        XCTAssertEqual(value(east.rows, "Inclinaison"), "4°")
        XCTAssertEqual(value(east.rows, "Gain"), "17,5\(nbsp)dBi")
        XCTAssertNil(east.note, "g1 servi : pas de phrase d'absence")
        let fdd = try XCTUnwrap(east.carriers.first)
        XCTAssertEqual(value(fdd.rows, "Fréquences DL"), "\(2140.0.formatted(.number.locale(fr)))\(nbsp)MHz")
        XCTAssertEqual(value(fdd.rows, "Fréquences UL"), "\(1740.0.formatted(.number.locale(fr)))\(nbsp)MHz")
        XCTAssertNil(value(fdd.rows, "Duplex"))

        // Un azimut du site sans porteuse lisible reste un secteur, sans porteuse ni phrase.
        XCTAssertTrue(sheet.sectors[1].carriers.isEmpty)
        XCTAssertNil(sheet.sectors[1].note)

        let omni = sheet.sectors[2]
        XCTAssertNil(value(omni.rows, "Ouverture horizontale"))
        XCTAssertEqual(value(omni.carriers[0].rows, "Fréquences DL"), "729–739\(nbsp)MHz")
        XCTAssertEqual(value(omni.carriers[0].rows, "Puissance d’émission"), "43\(nbsp)dBm")

        XCTAssertEqual(sheet.source, ["Registre ISED (Canada)."], "ni date, ni bande déduite, ni watts convertis")
    }

    /// Licence ISED (R1) : canal réel, largeur, bande lisible ; `bandId` nul servi = aucune bande.
    func testLicenceFrequencyTextReadsTheR1Channel() throws {
        let json = """
        [{"centerFrequencyMhz":3535,"bandwidthMhz":50,"technology":"NR","bandLabel":"5G NR n78","rangeMhz":[3510,3560],
          "duplex":"TDD","bandId":"n78"},
         {"centerFrequencyMhz":881.5,"bandwidthMhz":5,"technology":"HSPA","bandLabel":"HSPA 850","bandId":null},
         {"centerFrequencyMhz":2140,"bandwidthMhz":20,"technology":"LTE","bandLabel":"LTE B66"}]
        """
        let frequencies = try JSONDecoder().decode([ISEDSiteRecord.Frequency].self, from: Data(json.utf8))
        let low = 3510.0.formatted(.number.locale(fr)), high = 3560.0.formatted(.number.locale(fr))
        XCTAssertEqual(ISEDLicenceView.frequencyText(frequencies[0], locale: fr),
                       "\(low)–\(high)\(nbsp)MHz · 50\(nbsp)MHz de large · n78 · TDD")
        XCTAssertEqual(ISEDLicenceView.frequencyText(frequencies[1], locale: fr),
                       "881,5\(nbsp)MHz · 5\(nbsp)MHz de large")
        // Ancien serveur, sans `bandId` : le libellé de bande reste affiché.
        XCTAssertEqual(ISEDLicenceView.frequencyText(frequencies[2], locale: fr),
                       "\(2140.0.formatted(.number.locale(fr)))\(nbsp)MHz · 20\(nbsp)MHz de large · LTE B66")
    }

    /// Étapes d et e (servies le 12/11) : licences en carte quand l'import les sert, marque et province.
    func testLicencesBrandAndProvince() throws {
        let licensed = ISEDCarrierSheet.make(carriers: [], azimuths: [], datasetPublishedAt: nil,
                                             licences: [ISEDSiteLicence(number: "010587466-001", category: "Mobile")],
                                             holder: " Vidéotron ", locale: fr)
        XCTAssertEqual(licensed.licences.map(\.value), ["010587466-001", "Mobile", "Vidéotron"])
        let unlicensed = ISEDCarrierSheet.make(carriers: [], azimuths: [], datasetPublishedAt: nil, holder: "Bell", locale: fr)
        XCTAssertTrue(unlicensed.licences.isEmpty, "Sans licence servie, pas de carte : le titulaire reste dans Technique")
        XCTAssertNotNil(ISEDProvince.name(" qc "))
        XCTAssertNil(ISEDProvince.name("Montréal"))

        let json = #"{"id":"M1229","market":"CA","operatorBrand":"Freedom","operatorBrandKey":"FREEDOM","networkKind":"mobile","licences":[{"number":"5076954","category":"Mobile","areaName":null,"uploadDate":null},{"number":""},{"category":"x"}],"licenceCount":3}"#
        let core = try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data(json.utf8))
        XCTAssertEqual(core.operatorBrand, "Freedom")
        XCTAssertEqual(core.licences.map(\.number), ["5076954"], "Licences sans numéro écartées")
    }

    /// Onglet Essentiel (retour d'Alexandre, 12/11) : les bandes d'un site canadien, en familles
    /// du serveur, et non « LTE » / « 5GDSS » sans fréquence.
    func testEssentialBandsComeFromCarrierFrequencies() throws {
        let list = try carriers("""
        [{"id":"a","technology":"LTE","technologyDetail":"LTE","txFrequencyMhz":2145,"sectorAzimuthDeg":70,"omni":false,"cellIds":[],"physicalIds":[]},
         {"id":"b","technology":"NR","technologyDetail":"5GDSS","txFrequencyMhz":2145,"sectorAzimuthDeg":200,"omni":false,"cellIds":[],"physicalIds":[]},
         {"id":"c","technology":"NR","technologyDetail":"5GNR","txFrequencyMhz":3535,"sectorAzimuthDeg":70,"omni":false,"cellIds":[],"physicalIds":[]},
         {"id":"d","technology":"LTE","technologyDetail":"LTE","txFrequencyMhz":739,"sectorAzimuthDeg":200,"omni":false,"cellIds":[],"physicalIds":[]},
         {"id":"e","technology":"LTE","technologyDetail":"LTE","txFrequencyMhz":5000,"cellIds":[],"physicalIds":[]}]
        """)
        XCTAssertEqual(ISEDBandFamily.siteSystems(list), ["LTE AWS", "5G NR AWS", "5G NR 3500", "LTE 700"],
                       "Une fréquence hors famille ne fabrique pas de bande")
        let rows = ISEDBandFamily.generationRows(list)
        XCTAssertEqual(rows.map(\.generation), ["5G", "4G"])
        XCTAssertEqual(rows[0].bands.map(rows[0].name), ["AWS", "3500"])
        XCTAssertEqual(rows[1].bands.map(rows[1].name), ["700", "AWS"])
        let sectors = ISEDBandFamily.sectorSystems(list, azimuths: [70, 200])
        XCTAssertEqual(sectors.map(\.systems), [["LTE AWS", "5G NR 3500"], ["5G NR AWS", "LTE 700"]])
        let same = ISEDBandFamily.sectorSystems(Array(list.prefix(1)), azimuths: [70])
        XCTAssertTrue(same.isEmpty, "Un seul secteur : pas de détail")
    }
}
