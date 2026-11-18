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
        XCTAssertEqual(b1.groups.count, 1)
        XCTAssertEqual(b1.generations.map(\.generation), ["3G", "4G", "5G"])
        XCTAssertEqual(b1.generations.map(\.planned), [false, false, true])
        // Le B20 en projet identique au B20 en service n'est pas répété.
        XCTAssertEqual(rows[1].groups.first?.blocks.count, 1)
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
        XCTAssertEqual(rows[1].groups.count, 2)
        XCTAssertEqual(rows[3].groups.first?.dlSharePercent, 75)
        XCTAssertFalse(value.showsPlanned)
    }

    func testSharedSiteHasOneStripLinePerOperatorAndOneRowPerBand() throws {
        let value = try blocks(Self.shared)
        XCTAssertEqual(value.stripRows.map(\.id), ["o-ORANGE", "o-FREE"])
        let rows = value.bandRows
        XCTAssertEqual(rows.map(\.bandMhz), [700, 2600, 3500])
        XCTAssertEqual(rows[0].label, "B28")
        XCTAssertEqual(rows[0].groups.map(\.operatorKey), ["ORANGE", "FREE"])
        XCTAssertEqual(rows[0].generations.map(\.generation), ["4G", "5G"])
        XCTAssertEqual(rows[2].groups.map(\.operatorKey), ["ORANGE", "FREE"])
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
    }

    /// Passage à blanc du 18/11 : en France, 11 172 émetteurs UMTS 2100 sont déclarés dans l'ancienne
    /// bande 3G TDD (1900-1920 MHz), sans sens. Leur plage brute s'affiche sans flèche de sens,
    /// dans une rangée à part du 2100 FDD, et n'élargit pas la règle.
    func testAnfrUmtsOutsideItsBandKeepsItsRawRange() throws {
        let value = try blocks("""
        {"source":"anfr_sup_bande","datasetDate":"2026-11-06","operators":[{"operatorKey":"SFR","blocks":[
        \(Self.block("3G", nil, 2100, dl: "[2110.5,2125.3]", ul: "[1920.5,1935.3]", width: 14.8, system: "UMTS 2100")),
        \(Self.block("3G", nil, 2100, range: "[1900.1,1905.1]", width: 5, duplex: nil, system: "UMTS 2100")),
        \(Self.block("3G", nil, 2100, range: "[1910.1,1915.1]", width: 5, duplex: nil, system: "UMTS 2100")),
        \(Self.block("3G", nil, 2100, range: "[1915.1,1920.1]", width: 5, duplex: nil, system: "UMTS 2100"))]}]}
        """)
        let rows = value.bandRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.label), ["UMTS 2100", "UMTS 2100"])
        let unknown = try XCTUnwrap(rows.first { $0.duplex == nil })
        XCTAssertEqual(unknown.groups.count, 3)
        let texts = unknown.groups.map { plain(FrequencyBandRowView.rangeText($0.first)) }
        XCTAssertTrue(texts.allSatisfy { $0.hasPrefix("↕ ") && $0.hasSuffix(" MHz") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("1900") && $0.contains("1905") }, "\(texts)")
        XCTAssertEqual(value.stripDomain.low, 600)
        XCTAssertEqual(value.stripDomain.high, 4000)
    }

    func testRangeTextsSayTheDirection() throws {
        let france = try blocks(Self.france).bandRows
        XCTAssertEqual(plain(FrequencyBandRowView.rangeText(france[0].groups[0].first)), "↓ 763–773 · ↑ 708–718 MHz")
        XCTAssertEqual(plain(FrequencyBandRowView.rangeText(france[5].groups[0].first)), "↓↑ 3710–3800 MHz")
        let plan = try blocks(Self.bandPlan).bandRows
        XCTAssertEqual(plain(FrequencyBandRowView.rangeText(plan[1].groups[0].first)), "↕ 3300–3800 MHz")
        let dlOnly = try blocks("""
        {"source":"anfr_sup_bande","datasetDate":"2026-11-06","operators":[{"operatorKey":"SFR","blocks":[
        \(Self.block("4G", "B32", 1500, dl: "[1452,1472]", duplex: "SDL")),
        \(Self.block("4G", "B3", 1800, ul: "[1710,1730]"))]}]}
        """).bandRows
        XCTAssertEqual(plain(FrequencyBandRowView.rangeText(dlOnly[0].groups[0].first)), "↓ 1452–1472 MHz")
        XCTAssertEqual(plain(FrequencyBandRowView.rangeText(dlOnly[1].groups[0].first)), "↑ 1710–1730 MHz")
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
        let fixtures = [("france", Self.france), ("canada", Self.canada), ("partage", Self.shared), ("autres", Self.bandPlan)]
        let colors: [String: Color] = ["ORANGE": Color(hex: 0xFF7900), "FREE": Color(hex: 0xCD1E25),
                                       "BELL": Color(hex: 0x0066CC), "POST_LU": Color(hex: 0xFFCC00)]
        let names = ["ORANGE": "Orange", "FREE": "Free Mobile", "BELL": "Bell", "POST_LU": "POST"]
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("clair", .light, .large), ("sombre", .dark, .large), ("ax", .light, .accessibility2),
        ]
        for (fixture, json) in fixtures {
            let value = try blocks(json)
            for (name, scheme, size) in variants where fixture == "france" || name == "clair" {
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
