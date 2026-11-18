import SwiftUI
import XCTest
@testable import SignalQuest

/// FREQ-BLOCKS r0 à r0.6 : décodage tolérant de `antenna.frequencyBlocks`, regroupement des
/// bornes identiques, règle du spectre et pied de cadre par source.
@MainActor
final class FrequencyBlocksTests: XCTestCase {
    private func core(_ blocksJSON: String) throws -> AntennaCoreDetails {
        try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self,
                                           from: Data("{\"id\":\"s1\",\"frequencyBlocks\":\(blocksJSON)}".utf8))
    }

    private func blocks(_ json: String) throws -> FrequencyBlocks {
        try XCTUnwrap(core(json).frequencyBlocks)
    }

    private static func block(_ gen: String, _ band: String?, _ mhz: Int, dl: String = "null", ul: String = "null",
                              range: String = "null", width: Double = 10, duplex: String? = "FDD",
                              planned: Bool = false, system: String? = nil, share: String = "null") -> String {
        """
        {"system":"\(system ?? "\(gen) \(mhz)")","generation":"\(gen)","band":\(band.map { "\"\($0)\"" } ?? "null"),\
        "bandMhz":\(mhz),"dlMhz":\(dl),"ulMhz":\(ul),"rangeMhz":\(range),"widthMhz":\(width),\
        "duplex":\(duplex.map { "\"\($0)\"" } ?? "null"),"paired":\(dl != "null" && ul != "null"),\
        "planned":\(planned),"emitters":3,"dlSharePercent":\(share)}
        """
    }

    /// Planche « France » : Orange seul, ordre servi par génération puis fréquence.
    static let france = """
    {"revision":"r0","source":"anfr_sup_bande","datasetDate":"2026-11-06","operators":[{"operatorKey":"ORANGE","blocks":[
    \(block("3G", nil, 2100, dl: "[2154.8,2169.6]", ul: "[1964.8,1979.6]", width: 14.8, system: "UMTS 2100")),
    \(block("4G", "B28", 700, dl: "[763,773]", ul: "[708,718]")),
    \(block("4G", "B20", 800, dl: "[811,821]", ul: "[852,862]")),
    \(block("4G", "B20", 800, dl: "[811,821]", ul: "[852,862]", planned: true)),
    \(block("4G", "B3", 1800, dl: "[1805,1825]", ul: "[1710,1730]", width: 20)),
    \(block("4G", "B1", 2100, dl: "[2154.8,2169.6]", ul: "[1964.8,1979.6]", width: 14.8)),
    \(block("4G", "B7", 2600, dl: "[2635,2655]", ul: "[2515,2535]", width: 20)),
    \(block("5G", "n1", 2100, dl: "[2154.8,2169.6]", ul: "[1964.8,1979.6]", width: 14.8, planned: true)),
    \(block("5G", "n78", 3500, dl: "[3710,3800]", width: 90, duplex: "TDD"))
    ]}]}
    """

    /// Planche « Canada » : Bell, deux porteuses B66, n78 avec sa part de descente.
    static let canada = """
    {"revision":"r0","source":"ised","datasetDate":"2026-11-02","operators":[{"operatorKey":"BELL","blocks":[
    \(block("4G", "B13", 700, dl: "[746,756]", ul: "[777,787]")),
    \(block("4G", "B66", 2100, dl: "[2125,2145]", ul: "[1725,1745]", width: 20)),
    \(block("4G", "B66", 2100, dl: "[2145,2155]", ul: "[1745,1755]")),
    \(block("4G", "B7", 2600, dl: "[2630,2650]", ul: "[2510,2530]", width: 20)),
    \(block("5G", "n78", 3500, dl: "[3500,3600]", width: 100, duplex: "TDD", share: "75"))
    ]}]}
    """

    /// Planche « support partagé » : Orange et Free sur le même 700 (B28 et n28).
    static let shared = """
    {"revision":"r0","source":"anfr_sup_bande","datasetDate":"2026-11-06","operators":[
    {"operatorKey":"ORANGE","blocks":[
    \(block("4G", "B28", 700, dl: "[763,773]", ul: "[708,718]")),
    \(block("5G", "n78", 3500, dl: "[3710,3800]", width: 90, duplex: "TDD"))]},
    {"operatorKey":"FREE","blocks":[
    \(block("4G", "B7", 2600, dl: "[2670,2690]", ul: "[2550,2570]", width: 20)),
    \(block("5G", "n28", 700, dl: "[778,788]", ul: "[723,733]")),
    \(block("5G", "n78", 3500, dl: "[3640,3710]", width: 70, duplex: "TDD"))]}
    ]}
    """

    /// Autres pays : plages entières des bandes relevées, sans date ; un sens inconnu.
    static let bandPlan = """
    {"revision":"r0","source":"3gpp_band_plan","datasetDate":null,"operators":[{"operatorKey":"POST_LU","blocks":[
    \(block("4G", "B20", 800, dl: "[791,821]", ul: "[832,862]", width: 30)),
    \(block("5G", "n78", 3500, range: "[3300,3800]", width: 500, duplex: nil))
    ]}]}
    """

    func testFranceRowsFollowTheRulerAndMergeIdenticalBounds() throws {
        let value = try blocks(Self.france)
        XCTAssertEqual(value.source, .anfr)
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.bandMhz), [700, 800, 1800, 2100, 2600, 3500])
        XCTAssertEqual(rows.map(\.label), ["B28", "B20", "B3", "B1", "B7", "n78"])
        // 2100 : UMTS, LTE et NR en projet partagent les mêmes bornes, une seule rangée.
        let b1 = rows[3]
        XCTAssertEqual(b1.operators.count, 1)
        XCTAssertTrue(b1.operators[0].isSinglePair)
        XCTAssertEqual(b1.widthMhz, 14.8)
        XCTAssertEqual(b1.generations.map(\.generation), ["3G", "4G", "5G"])
        XCTAssertEqual(b1.generations.map(\.planned), [false, false, true])
        // Le B20 en projet identique au B20 en service n'est pas répété.
        XCTAssertEqual(rows[1].operators[0].dl.count, 1)
        XCTAssertEqual(rows[1].generations.map(\.planned), [false])
        XCTAssertTrue(value.showsPlanned)
    }

    func testStripHasOneLinePerGenerationOnASingleOperator() throws {
        let value = try blocks(Self.france)
        XCTAssertEqual(value.stripRows.map(\.id), ["g-3G", "g-4G", "g-5G"])
        XCTAssertEqual(value.stripRows[1].marks.count, 5)
        XCTAssertEqual(value.stripRows[2].marks.map(\.planned), [true, false])
        XCTAssertEqual(value.stripDomain, FrequencyBlocks.Range(low: 600, high: 4000))
    }

    func testCanadaKeepsBothCarriersOfABandInOneRow() throws {
        let value = try blocks(Self.canada)
        XCTAssertEqual(value.source, .ised)
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.label), ["B13", "B66", "B7", "n78"])
        XCTAssertEqual(rows[1].operators[0].dl.count, 2)
        XCTAssertEqual(rows[1].carriers, 2)
        XCTAssertNil(rows[1].widthMhz)
        XCTAssertEqual(rows[3].operators.first?.dlSharePercent, 75)
        XCTAssertEqual(value.carrierCount, 5)
        XCTAssertFalse(value.showsPlanned)
    }

    func testSharedSiteHasOneStripLinePerOperatorAndOneRowPerBand() throws {
        let value = try blocks(Self.shared)
        XCTAssertEqual(value.stripRows.map(\.id), ["o-ORANGE", "o-FREE"])
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.bandMhz), [700, 2600, 3500])
        XCTAssertEqual(rows[0].label, "B28")
        XCTAssertEqual(rows[0].operators.map(\.operatorKey), ["ORANGE", "FREE"])
        XCTAssertEqual(rows[0].generations.map(\.generation), ["4G", "5G"])
        XCTAssertNil(rows[0].widthMhz)
        XCTAssertEqual(rows[2].operators.map(\.operatorKey), ["ORANGE", "FREE"])
        XCTAssertNil(value.carrierCount)
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{FE0E}", with: "")
    }

    private func fixture(_ name: String) throws -> FrequencyBlocks {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let json = try String(contentsOf: url, encoding: .utf8)
        return try blocks(json)
    }

    private func lines(_ row: FrequencyBlocks.BandRow, _ operatorKey: String? = nil) -> [String] {
        let entry = operatorKey.flatMap { key in row.operators.first { $0.operatorKey == key } } ?? row.operators[0]
        return FrequencyBandRowView.rangeLines(entry).map(plain)
    }

    /// Vraie réponse servie le 18/11 (support partagé SFR et Bouygues, ANFR du 06/11, blocs seuls),
    /// le même vecteur qu'Android (fcd675020). Servie par génération, affichée par fréquence comme le site.
    func testRealAnfrSharedSiteFollowsTheSite() throws {
        let value = try fixture("frequency-blocks-fr-shared-v1")
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.bandMhz), [700, 800, 900, 1800, 2100, 2600, 3500])
        XCTAssertEqual(rows.map(\.label), ["B28", "B20", "UMTS 900", "B3", "B1", "B7", "n78"])
        let b1 = rows[4]
        XCTAssertEqual(b1.generations.map(\.generation), ["4G", "5G"])
        XCTAssertEqual(b1.generations.map(\.planned), [false, false])
        XCTAssertNil(b1.widthMhz)
        XCTAssertEqual(lines(b1, "SFR"), ["↓ 2110,5–2125,3 · ↑ 1920,5–1935,3 MHz"].map(localized))
        XCTAssertEqual(lines(rows[6], "BOUYGUES"), ["↓↑ 3570–3640 MHz"])
        XCTAssertEqual(value.stripRows.map(\.marks.count), [7, 7])
        XCTAssertNil(value.carrierCount)
        XCTAssertFalse(value.showsPlanned)
    }

    /// Vraie réponse servie le 18/11 (SFR seul) : en 2100, UMTS, LTE et NR (en projet) aux mêmes bornes
    /// prennent le nom 3GPP (B1), et la plage UMTS sans sens (1915,1–1920,1) vient en dernière ligne.
    func testRealAnfrUmtsRangeWithoutDirectionComesLast() throws {
        let value = try fixture("frequency-blocks-fr-umts-range-v1")
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.label), ["B20", "GSM 900", "B3", "B1", "B7", "n78"])
        XCTAssertEqual(rows[1].generations.map(\.generation), ["2G", "3G"])
        XCTAssertEqual(rows[1].widthMhz, 8.7)
        let b1 = rows[3]
        XCTAssertEqual(lines(b1), ["↓ 2110,5–2125,3 · 2149,9–2154,9 MHz", "↑ 1920,5–1935,3 · 1959,9–1964,9 MHz",
                                   "1915,1–1920,1 MHz"].map(localized))
        XCTAssertEqual(b1.generations.map(\.generation), ["3G", "4G", "5G"])
        XCTAssertEqual(b1.generations.map(\.planned), [false, false, true])
        XCTAssertNil(b1.widthMhz)
        XCTAssertNil(b1.carriers)
        XCTAssertEqual(b1.duplex, "FDD")
        XCTAssertTrue(value.showsPlanned)
    }

    /// Les vecteurs sont écrits en français : en anglais, la virgule décimale devient un point.
    private func localized(_ text: String) -> String {
        Bundle.main.preferredLocalizations.first == "fr" ? text : text.replacingOccurrences(of: ",", with: ".")
    }

    func testRangeTextsSayTheDirection() throws {
        let france = try blocks(Self.france).bandRows
        XCTAssertEqual(lines(france[0]), ["↓ 763–773 · ↑ 708–718 MHz"])
        XCTAssertEqual(lines(france[5]), ["↓↑ 3710–3800 MHz"])
        let plan = try blocks(Self.bandPlan).bandRows
        XCTAssertEqual(lines(plan[1]), ["3300–3800 MHz"])
        XCTAssertNil(plan[0].widthMhz)
        let dlOnly = try blocks("""
        {"source":"anfr_sup_bande","datasetDate":"2026-11-06","operators":[{"operatorKey":"SFR","blocks":[
        \(Self.block("4G", "B32", 1500, dl: "[1452,1472]", duplex: "SDL")),
        \(Self.block("4G", "B3", 1800, ul: "[1710,1730]"))]}]}
        """).bandRows
        XCTAssertEqual(lines(dlOnly[0]), ["↓ 1452–1472 MHz"])
        XCTAssertEqual(lines(dlOnly[1]), ["↑ 1710–1730 MHz"])
    }

    /// Textes au mot près ceux du contrat (r0.5 §2), en français.
    func testFooterBySource() throws {
        guard Bundle.main.preferredLocalizations.first == "fr" else { throw XCTSkip("textes français seulement") }
        XCTAssertEqual(FrequencyBlocksCard.footer(try blocks(Self.france)),
                       "Bornes déclarées à l’ANFR · jeu du 6 novembre 2026. Pointillé : en projet.")
        XCTAssertEqual(FrequencyBlocksCard.footer(try blocks(Self.canada)),
                       "Porteuses inscrites à ISED · 2 novembre 2026.")
        XCTAssertEqual(FrequencyBlocksCard.footer(try blocks(Self.bandPlan)),
                       "Plages des bandes (norme 3GPP), d’après les bandes relevées par la communauté.")
        XCTAssertEqual(FrequencyBlocksCard.mhz(2154.8), "2154,8")
        XCTAssertEqual(FrequencyBlocksCard.mhz(3500), "3500")
    }

    func testTolerantDecoding() throws {
        // Absent ou null : pas de cadre.
        XCTAssertNil(try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data("{\"id\":\"s1\"}".utf8)).frequencyBlocks)
        XCTAssertNil(try core("null").frequencyBlocks)
        // Que des blocs mal formés : pas de cadre non plus.
        XCTAssertNil(try core("""
        {"source":"ised","operators":[{"operatorKey":"BELL","blocks":[
        {"generation":"6G","dlMhz":[1,2]},{"generation":"4G","dlMhz":[5]},{"generation":"4G"},"x"]}]}
        """).frequencyBlocks)
        // Source inconnue, un bon bloc parmi des mauvais, une génération en minuscules.
        let value = try blocks("""
        {"source":"futur","operators":[{"operatorKey":"BELL","blocks":[
        {"generation":"4g","band":"B13","bandMhz":700,"dlMhz":[746,756],"ulMhz":[777,787],"duplex":"fdd"},
        {"generation":"4G","dlMhz":[900,800]}]},{"operatorKey":"","blocks":[]}]}
        """)
        XCTAssertEqual(value.source, .unrecognized)
        XCTAssertEqual(value.operators.count, 1)
        XCTAssertEqual(value.operators[0].blocks.count, 1)
        XCTAssertEqual(value.operators[0].blocks[0].duplex, "FDD")
        XCTAssertEqual(FrequencyBlocksCard.footer(value), "")
    }

    func testCaptureFrequencyBlocksForReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["SQ_FREQ_SHOTS"] else {
            throw XCTSkip("SQ_FREQ_SHOTS absent")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        var fixtures = [("france", Self.france), ("canada", Self.canada), ("partage", Self.shared), ("autres", Self.bandPlan)]
        for name in ["frequency-blocks-fr-shared-v1", "frequency-blocks-fr-umts-range-v1"] {
            let bundle = Bundle(for: Self.self)
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            fixtures.append((name, try String(contentsOf: url, encoding: .utf8)))
        }
        let colors: [String: Color] = ["ORANGE": Color(hex: 0xFF7900), "FREE": Color(hex: 0xCD1E25),
                                       "SFR": Color(hex: 0xE2001A), "BOUYGUES": Color(hex: 0x00A3E0),
                                       "BELL": Color(hex: 0x0066CC), "POST_LU": Color(hex: 0xFFCC00)]
        let names = ["ORANGE": "Orange", "FREE": "Free Mobile", "BELL": "Bell", "POST_LU": "POST",
                     "SFR": "SFR", "BOUYGUES": "Bouygues Telecom"]
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("clair", .light, .large), ("sombre", .dark, .large), ("ax", .light, .accessibility2),
        ]
        for (fixture, json) in fixtures {
            let value = try blocks(json)
            for (name, scheme, size) in variants where fixture == "france" || fixture.hasSuffix("umts-range-v1") || name == "clair" {
                let view = ScrollView {
                    FrequencyBlocksCard(blocks: value, operatorLabel: { names[$0] ?? $0 },
                                        operatorColor: { colors[$0] ?? .gray })
                        .padding(16)
                }
                .background(SQColor.bg)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
                let host = UIHostingController(rootView: view)
                host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = host
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: output).appendingPathComponent("\(fixture)-\(name).png"))
            }
        }
    }
}
