import XCTest
@testable import SignalQuest

/// Contrat ANFR par bande v1 (`view=bands`, figé le 01/10) : décodage, ligne
/// illisible ignorée, écarts signés, pic et part du pic calculés par le serveur.
final class ANFRBandStatsTests: XCTestCase {
    private let payload = """
    {"meta":{"firstDate":"2021-12-29","latestDate":"2026-09-24","requestId":"req-1","partial":false},
     "bands":[
      {"key":"3g","generation":"3G","kind":"generation","mhz":null,"nrBand":null,
       "label":{"fr":"3G","en":"3G","short":"3G"},"firstDate":"2021-12-29"},
      {"key":"3g2100","generation":"3G","kind":"band","mhz":2100,"nrBand":null,
       "label":{"fr":"3G 2100 MHz","en":"3G 2100 MHz","short":"2100"},"firstDate":"2021-12-29"},
      {"key":"3g900","generation":"3G","kind":"band","mhz":900,"nrBand":null,
       "label":{"fr":"3G 900 MHz","en":"3G 900 MHz","short":"900"},"firstDate":"2021-12-29"},
      {"key":"n78","generation":"5G","kind":"band","mhz":3500,"nrBand":"n78",
       "label":{"fr":"5G n78 3,5 GHz","en":"5G n78 3.5 GHz","short":"n78"},"firstDate":"2021-12-29"},
      {"key":"5g","generation":"5G","kind":"generation","mhz":null,"nrBand":null,
       "label":{"fr":"5G","en":"5G","short":"5G"},"firstDate":"2021-12-29"},
      {"key":"broken","generation":"4G","kind":"weird"}
     ],
     "series":[
      {"date":"2026-09-24","operator":"all","band":"3g2100","operational":5472,"projected":0,"total":5472},
      {"date":"2021-12-29","operator":"all","band":"3g2100","operational":56627,"projected":12,"total":56639},
      {"date":"2026-09-24","operator":"sfr","band":"3g2100","operational":1200,"projected":0,"total":1200},
      {"date":"2026-09-24","operator":"all","band":"n78"}
     ],
     "summary":[
      {"operator":"all","band":"3g2100","latest":{"date":"2026-09-24","operational":5472,"projected":0},
       "delta1w":{"referenceDate":"2026-09-17","operational":-310},
       "delta4w":{"referenceDate":"2026-08-27","operational":-1490},"delta52w":null,
       "peak":{"date":"2021-12-29","operational":56627},"shareOfPeakPermille":97},
      {"operator":"all","band":"n78","latest":{"date":"2026-09-24","operational":0,"projected":40},
       "delta1w":null,"delta4w":null,"delta52w":null,
       "peak":{"date":"2026-09-24","operational":0},"shareOfPeakPermille":null}
     ]}
    """

    private func decode(_ json: String) throws -> ANFRBandStats {
        try JSONDecoder.signalQuest.decode(ANFRBandStats.self, from: Data(json.utf8))
    }

    func testTheFrozenContractDecodesAndAnUnreadableRowIsDropped() throws {
        let stats = try decode(payload)
        XCTAssertEqual(stats.meta.latestDate, "2026-09-24")
        XCTAssertFalse(stats.meta.partial)
        XCTAssertEqual(stats.bands.map(\.key), ["3g", "3g2100", "3g900", "n78", "5g"], "La bande illisible est ignorée")
        XCTAssertEqual(stats.series.count, 3, "Le point sans valeurs est ignoré")
        XCTAssertEqual(stats.generations.map(\.key), ["3g", "5g"])
        XCTAssertEqual(stats.bands(of: "3G").map(\.key), ["3g900", "3g2100"], "De la plus basse fréquence à la plus haute")
        XCTAssertEqual(stats.bands(of: "5G").first?.nrBand, "n78")
        XCTAssertEqual(stats.series(operatorKey: "all", band: "3g2100").map(\.date), ["2021-12-29", "2026-09-24"])
        XCTAssertEqual(stats.series(operatorKey: "sfr", band: "3g2100").map(\.operational), [1200])

        let n78 = try XCTUnwrap(stats.bands.first { $0.key == "n78" })
        XCTAssertEqual(n78.localizedLabel(language: "fr"), "5G n78 3,5 GHz")
        XCTAssertEqual(n78.localizedLabel(language: "en"), "5G n78 3.5 GHz")
        XCTAssertEqual(n78.label.short, "n78")
    }

    /// Les écarts sont signés (négatifs en pleine extinction) ; une bande sans
    /// relevé opérationnel garde son pic à 0 et n'a pas de part du pic.
    func testTheServerSummaryCarriesSignedChangesAndTheShareOfPeak() throws {
        let stats = try decode(payload)
        let umts = try XCTUnwrap(stats.summary(operatorKey: "all", band: "3g2100"))
        XCTAssertEqual(umts.latest.operational, 5_472)
        XCTAssertEqual(umts.delta1w, .init(referenceDate: "2026-09-17", operational: -310))
        XCTAssertEqual(umts.delta4w?.operational, -1_490)
        XCTAssertNil(umts.delta52w)
        XCTAssertEqual(umts.peak, .init(date: "2021-12-29", operational: 56_627))
        XCTAssertEqual(umts.shareOfPeakPermille, 97)

        let n78 = try XCTUnwrap(stats.summary(operatorKey: "all", band: "n78"))
        XCTAssertEqual(n78.peak.operational, 0)
        XCTAssertNil(n78.shareOfPeakPermille)
        XCTAssertEqual(n78.latest.projected, 40)
        XCTAssertNil(stats.summary(operatorKey: "free", band: "n78"))
    }

    func testAResponseWithoutMetaIsRefused() {
        XCTAssertThrowsError(try decode(#"{"bands":[],"series":[],"summary":[]}"#))
    }
}
