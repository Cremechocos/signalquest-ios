import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

/// Couleurs de carte communes aux trois plateformes : `contracts/quality-scale-v1.json`,
/// figé le 01/10/2026 avec Alexandre. La copie du dépôt est celle du web, octet
/// pour octet, et l'échelle de l'app la suit : seuils, ordre d'évaluation,
/// arrondi et teintes. Une nouvelle version passe par un changement visible de
/// cette copie et de son empreinte.
final class QualityScaleContractTests: XCTestCase {
    private static let expectedSHA256 = "4ac6086facc0f8879dc8420a9189e0005b2b03dd7fd17cf025c2695ea48631a3"
    /// v2 (#1220, servie le 12/11) : seul le débit descendant change.
    private static let expectedV2SHA256 = "f9b6ea96b9e4d7fb1f0a84067069fb896884fefe41bf7972e374bf1e11c460b0"

    private func contractData(_ name: String = "quality-scale-v1.json") throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent("contracts/\(name)"))
    }

    private func contract() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: contractData()) as? [String: Any])
    }

    private func contractV2() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: contractData("quality-scale-v2.json")) as? [String: Any])
    }

    func testTheV2CopyIsTheFrozenContract() throws {
        let digest = SHA256.hash(data: try contractData("quality-scale-v2.json")).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.expectedV2SHA256, "La copie doit être celle du web, octet pour octet")
        let root = try contractV2()
        XCTAssertEqual(root["contract"] as? String, "quality-scale")
        XCTAssertEqual(root["version"] as? String, "2")
        XCTAssertEqual(root["status"] as? String, "frozen")
        // Le reste de la v2 est la v1 : signal, génération et opérateurs inchangés.
        let v1 = try contract()
        for key in ["signal", "generation", "operators"] {
            XCTAssertEqual(root[key] as? NSDictionary, v1[key] as? NSDictionary, key)
        }
    }

    private func hex(_ value: Any?) throws -> UInt32 {
        let text = try XCTUnwrap(value as? String)
        XCTAssertTrue(text.hasPrefix("#"), text)
        return try XCTUnwrap(UInt32(text.dropFirst(), radix: 16))
    }

    /// Teinte claire, et la sombre qui doit lui être égale tant que l'app n'a pas
    /// de variante sombre (contrat v1 : `darkVariants`).
    private func lightHex(_ entry: Any?, _ label: String) throws -> UInt32 {
        let object = try XCTUnwrap(entry as? [String: Any], label)
        let light = try hex(object["light"])
        XCTAssertEqual(try hex(object["dark"]), light, "\(label) : l'app n'a pas encore de variante sombre")
        return light
    }

    private func components(of color: Color) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    func testTheCopyIsTheFrozenContract() throws {
        let digest = SHA256.hash(data: try contractData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.expectedSHA256, "La copie doit être celle du web, octet pour octet")
        let root = try contract()
        XCTAssertEqual(root["contract"] as? String, "quality-scale")
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["status"] as? String, "frozen")
    }

    func testSignalVectorsPass() throws {
        let vectors = try XCTUnwrap(((try contract())["vectors"] as? [String: Any])?["signal"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 25)
        for vector in vectors {
            let technology = vector["technology"] as? String
            let dbm = (vector["dbm"] as? NSNumber)?.doubleValue
            let expected = try XCTUnwrap(vector["expected"] as? String)
            XCTAssertEqual(
                SQQualityScale.Signal(dbm: dbm, technology: technology).contractKey, expected,
                "\(technology ?? "nil") \(dbm.map { String($0) } ?? "nil")"
            )
        }
    }

    func testDownloadVectorsPass() throws {
        let vectors = try XCTUnwrap(((try contractV2())["vectors"] as? [String: Any])?["downloadSpeed"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 11)
        for vector in vectors {
            let expected = try XCTUnwrap(vector["expected"] as? String)
            guard let mbps = (vector["mbps"] as? NSNumber)?.doubleValue else {
                // Pas de débit : l'app n'en dessine pas, comme le contrat (« pas de mesure »).
                XCTAssertEqual(expected, "unknown")
                continue
            }
            XCTAssertEqual(SQQualityScale.Throughput(mbps: mbps).contractKey, expected, "\(mbps)")
        }
    }

    func testSignalThresholdsRangesAndColors() throws {
        let signal = try XCTUnwrap((try contract())["signal"] as? [String: Any])
        let thresholds = try XCTUnwrap(signal["thresholdsDbm"] as? [String: [Int]])
        let ranges = try XCTUnwrap(signal["validRangeDbm"] as? [String: [Int]])
        let metrics: [(String, SQQualityScale.Signal.Metric)] = [("RSRP", .rsrp), ("SS-RSRP", .ssRsrp), ("RSCP", .rscp), ("RSSI", .rssi)]
        for (key, metric) in metrics {
            XCTAssertEqual(thresholds[key], metric.thresholds, key)
            XCTAssertEqual(ranges[key], [metric.validRange.lowerBound, metric.validRange.upperBound], key)
        }
        let levels = try XCTUnwrap(signal["levels"] as? [[String: Any]])
        let app = Dictionary(uniqueKeysWithValues: SQQualityScale.Signal.allCases.map { ($0.contractKey, $0) })
        XCTAssertEqual(levels.count, 5)
        for level in levels {
            let key = try XCTUnwrap(level["key"] as? String)
            XCTAssertEqual(try XCTUnwrap(app[key]).hex, try lightHex(level, key), key)
        }
        let states = try XCTUnwrap(signal["states"] as? [String: Any])
        XCTAssertEqual(SQQualityScale.Signal.noService.hex, try lightHex(states["noService"], "noService"))
        XCTAssertEqual(SQQualityScale.Signal.unknown.hex, try lightHex(states["unknown"], "unknown"))
        XCTAssertEqual((states["noService"] as? [String: Any])?["pattern"] as? String, "hatched")
        // La v3 (21/11) retire la hachure : la v1 reste figée, l'app suit la v3.
        XCTAssertFalse(SQQualityScale.Signal.noService.isHatched)
    }

    func testDownloadThresholdsAndColors() throws {
        let download = try XCTUnwrap((try contractV2())["downloadSpeed"] as? [String: Any])
        let levels = try XCTUnwrap(download["levels"] as? [[String: Any]])
        let app = Dictionary(uniqueKeysWithValues: SQQualityScale.Throughput.allCases.map { ($0.contractKey, $0) })
        XCTAssertEqual(levels.count, app.count)
        for level in levels {
            let key = try XCTUnwrap(level["key"] as? String)
            let tier = try XCTUnwrap(app[key], key)
            XCTAssertEqual(tier.lowerBoundMbps, (level["min"] as? NSNumber)?.doubleValue, key)
            XCTAssertEqual(tier.hex, try lightHex(level, key), key)
        }
        XCTAssertEqual(SQQualityScale.unknownHex, try lightHex(download["unknown"], "downloadSpeed.unknown"))
    }

    func testGenerationColors() throws {
        let generation = try XCTUnwrap((try contract())["generation"] as? [String: Any])
        let levels = try XCTUnwrap(generation["levels"] as? [[String: Any]])
        let app: [String: SQQualityScale.Generation] = ["2G": .twoG, "3G": .threeG, "4G": .fourG, "5G": .fiveG]
        XCTAssertEqual(levels.count, app.count)
        for level in levels {
            let key = try XCTUnwrap(level["key"] as? String)
            XCTAssertEqual(try XCTUnwrap(app[key], key).hex, try lightHex(level, key), key)
        }
        XCTAssertEqual(SQQualityScale.Generation.none.hex, try lightHex(generation["none"], "generation.none"))
    }

    func testOperatorColorsInEveryMarket() throws {
        let operators = try XCTUnwrap((try contract())["operators"] as? [String: Any])
        let brandKeys: [String: String] = [
            "SFR": "sfr", "BOUYGUES": "bouygues", "ORANGE": "orange", "FREE": "free",
            "DIGICEL": "digicel", "OUTREMER": "outremer", "SRR": "srr", "TELCO_OI": "telcooi", "ZEOP": "zeop", "MAORE": "maore",
            "BELL": "bell", "ROGERS": "rogers", "TELUS": "telus", "VIDEOTRON_FREEDOM": "videotron", "REGIONAL": "regional",
        ]
        var checked = 0
        for market in ["FR", "DROM", "CA"] {
            let entries = try XCTUnwrap(operators[market] as? [String: Any], market)
            for (name, entry) in entries {
                let brand = try XCTUnwrap(brandKeys[name], "Opérateur du contrat sans couleur iOS : \(market) \(name)")
                let colors = try XCTUnwrap(SQBrand.operators[brand], brand)
                XCTAssertEqual(components(of: colors.solid), try lightHex(entry, name), "\(market) \(name)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, brandKeys.count)
        // Les opérateurs des DOM d'une marque métropolitaine en reprennent la teinte.
        XCTAssertEqual(components(of: SQBrand.operators["freecaraibes"]!.solid), components(of: SQBrand.operators["free"]!.solid))
    }
}

/// Copie de `contracts/quality-scale-v3.json` (web, figé le 21/11) : octet pour
/// octet, et ses vecteurs de qualité rejoués sur l'échelle de l'app. Le reste
/// de la v3 est la v2, déjà couverte plus haut.
final class QualityScaleContractV3Tests: XCTestCase {
    private static let expectedSHA256 = "878cf104cf5af540263f1e8ef4872b8585162631b45a8b46fa19e2d93945fc29"

    private func contract(_ name: String) throws -> [String: Any] {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("contracts/\(name)"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheCopyIsTheFrozenContract() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("contracts/quality-scale-v3.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.expectedSHA256, "La copie doit être celle du web, octet pour octet")
        let root = try contract("quality-scale-v3.json")
        XCTAssertEqual(root["contract"] as? String, "quality-scale")
        XCTAssertEqual(root["version"] as? String, "3")
        XCTAssertEqual(root["status"] as? String, "frozen")
    }

    /// La v3 ne touche que le signal (qualité, règle de carte, gris plein) : le
    /// débit, la génération, les bandes, les opérateurs et leurs vecteurs sont la v2.
    func testOnlyTheSignalChangesSinceV2() throws {
        let v3 = try contract("quality-scale-v3.json")
        let v2 = try contract("quality-scale-v2.json")
        for key in ["downloadSpeed", "generation", "bands", "operators", "outages"] {
            XCTAssertEqual(v3[key] as? NSDictionary, v2[key] as? NSDictionary, key)
        }
        let vectors3 = try XCTUnwrap(v3["vectors"] as? [String: Any])
        let vectors2 = try XCTUnwrap(v2["vectors"] as? [String: Any])
        for key in ["signal", "downloadSpeed", "bands"] {
            XCTAssertEqual(vectors3[key] as? NSArray, vectors2[key] as? NSArray, "vectors.\(key)")
        }
        let signal = try XCTUnwrap(v3["signal"] as? [String: Any])
        let noService = try XCTUnwrap((signal["states"] as? [String: Any])?["noService"] as? [String: Any])
        XCTAssertEqual(noService["pattern"] as? String, "solid")
        XCTAssertEqual(noService["light"] as? String, String(format: "#%06X", SQQualityScale.noServiceHex))
        XCTAssertFalse(CoverageQualityBand.noService.isHatched, "v3 : gris plein")
    }

    func testQualityVectorsPass() throws {
        let vectors = try XCTUnwrap(((try contract("quality-scale-v3.json"))["vectors"] as? [String: Any])?["quality"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 64)
        for vector in vectors {
            let axis = try XCTUnwrap(SQQualityScale.Signal.Measure(rawValue: try XCTUnwrap(vector["axis"] as? String)))
            let technology = vector["technology"] as? String
            let value = (vector["value"] as? NSNumber)?.doubleValue
            let expected = try XCTUnwrap(vector["expected"] as? String)
            let signal = SQQualityScale.Signal(
                measure: axis,
                rsrp: axis == .rsrp ? value : nil,
                rsrq: axis == .rsrq ? value : nil,
                sinr: axis == .sinr ? value : nil,
                technology: technology
            )
            XCTAssertEqual(signal.contractKey, expected, "\(axis.rawValue) \(technology ?? "nil") \(value.map { String($0) } ?? "nil")")
        }
    }
}

/// Contrat v3 (21/11, choix d'Alexandre) : RSRQ et SINR sur les cinq niveaux,
/// seulement en 4G et en 5G. Les plages viennent du code d'Android (AOSP) ; 0
/// est une sentinelle pour les deux, comme pour le RSRP.
final class SignalQualityMeasureTests: XCTestCase {
    private func level(_ measure: SQQualityScale.Signal.Measure, _ value: Double?, _ technology: String? = "4G") -> String {
        SQQualityScale.Signal(measure: measure, rsrp: -90, rsrq: measure == .rsrq ? value : nil,
                              sinr: measure == .sinr ? value : nil, technology: technology).contractKey
    }

    func testRSRQThresholdsRoundingAndRange() {
        let cases: [(Double, String)] = [
            (3, "excellent"), (-9, "excellent"), (-9.5, "excellent"), (-9.6, "good"), (-12, "good"),
            (-13, "fair"), (-15, "fair"), (-16, "poor"), (-19, "poor"), (-20, "critical"), (-34, "critical"),
            (-35, "unknown"), (4, "unknown"), (0, "unknown"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(level(.rsrq, value), expected, "RSRQ 4G \(value)")
        }
        XCTAssertEqual(level(.rsrq, -40, "5G"), "critical", "SS-RSRQ jusqu'à −43")
        XCTAssertEqual(level(.rsrq, -43, "5G NSA"), "critical")
        XCTAssertEqual(level(.rsrq, -44, "5G"), "unknown")
        XCTAssertEqual(level(.rsrq, 20, "NR"), "excellent")
        XCTAssertEqual(level(.rsrq, -40, "4G"), "unknown", "RSRQ 4G borné à −34")
    }

    func testSINRThresholdsAndZeroSentinel() {
        let cases: [(Double, String)] = [
            (40, "excellent"), (20, "excellent"), (19, "good"), (13, "good"), (12, "fair"), (5, "fair"),
            (4, "poor"), (1, "poor"), (0, "unknown"), (-1, "critical"), (-23, "critical"),
            (-24, "unknown"), (41, "unknown"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(level(.sinr, value), expected, "SINR 4G \(value)")
            XCTAssertEqual(level(.sinr, value, "5G"), expected, "SS-SINR \(value)")
        }
    }

    func testOnly4GAnd5GHaveAQualityMeasure() {
        for technology in ["2G", "3G", "GSM", "UMTS", "Inconnu", nil] as [String?] {
            XCTAssertEqual(level(.rsrq, -10, technology), "unknown", technology ?? "nil")
            XCTAssertEqual(level(.sinr, 15, technology), "unknown", technology ?? "nil")
        }
        XCTAssertEqual(level(.rsrq, nil), "unknown", "valeur absente")
        XCTAssertEqual(level(.sinr, -10, "Aucun"), "noService", "sans réseau quelle que soit la mesure")
    }

    func testRSRPMeasureIsTheTechnologyMetric() {
        for (dbm, technology) in [(-85.0, "4G"), (-85, "3G"), (-85, "2G"), (-120, "5G"), (0, "4G")] {
            XCTAssertEqual(
                SQQualityScale.Signal(measure: .rsrp, rsrp: dbm, rsrq: -5, sinr: 30, technology: technology),
                SQQualityScale.Signal(dbm: dbm, technology: technology), "\(technology) \(dbm)"
            )
        }
    }
}

/// Carte de couverture, contrat v3 : légende aux bornes exactes, points et
/// clusters sans valeur jamais dessinés, médianes des clusters.
final class CoverageMeasureMapTests: XCTestCase {
    private var french: Bool { Bundle.main.preferredLocalizations.first == "fr" }
    private func range(_ low: String, _ high: String, _ unit: String) -> String {
        french ? "\(low) à \(high) \(unit)" : "\(low) to \(high) \(unit)"
    }

    func testLegendShowsTheExactBounds() {
        XCTAssertEqual(CoverageQualityBand.excellent.bounds(for: .rsrp), "≥ −80 dBm")
        XCTAssertEqual(CoverageQualityBand.good.bounds(for: .rsrp), range("−90", "−81", "dBm"))
        XCTAssertEqual(CoverageQualityBand.poor.bounds(for: .rsrp), "< −110 dBm")
        XCTAssertEqual(CoverageQualityBand.excellent.bounds(for: .rsrq), "≥ −9 dB")
        XCTAssertEqual(CoverageQualityBand.fair.bounds(for: .rsrq), range("−15", "−13", "dB"))
        XCTAssertEqual(CoverageQualityBand.weak.bounds(for: .rsrq), range("−19", "−16", "dB"))
        XCTAssertEqual(CoverageQualityBand.weak.bounds(for: .sinr), range("1", "4", "dB"), "0 est une sentinelle")
        XCTAssertEqual(CoverageQualityBand.poor.bounds(for: .sinr), "< 0 dB")
        XCTAssertNil(CoverageQualityBand.noService.bounds(for: .rsrp))
    }

    func testAPointWithoutTheMeasureIsNotDrawn() {
        XCTAssertNil(CoverageQualityBand.band(measure: .rsrq, rsrp: -85, rsrq: -10, sinr: 15, technology: "3G"))
        XCTAssertNil(CoverageQualityBand.band(measure: .sinr, rsrp: -85, rsrq: -10, sinr: nil, technology: "4G"))
        XCTAssertNil(CoverageQualityBand.band(measure: .sinr, rsrp: -85, rsrq: -10, sinr: 0, technology: "5G"))
        XCTAssertNil(CoverageQualityBand.band(measure: .rsrp, rsrp: 0, rsrq: nil, sinr: nil, technology: "4G"), "plus de gris « pas de mesure »")
        XCTAssertEqual(CoverageQualityBand.band(measure: .rsrq, rsrp: nil, rsrq: nil, sinr: nil, technology: "Aucun"), .noService)
        XCTAssertEqual(CoverageQualityBand.band(measure: .rsrq, rsrp: -85, rsrq: -10, sinr: 15, technology: "4G"), .good)
        XCTAssertEqual(CoverageQualityBand.band(measure: .sinr, rsrp: -85, rsrq: -10, sinr: 15, technology: "5G"), .good)
        XCTAssertFalse(CoverageQualityBand.noService.isHatched, "v3 : gris plein")
    }

    func testClustersDecodeTheirMedians() throws {
        let json = #"{"id":"0:1","lat":45.2,"lng":5.7,"count":12,"avgRsrp":-95.4,"tech":"4G","medianRsrp":-97,"medianRsrq":-11,"medianSnr":8}"#
        let cluster = try JSONDecoder().decode(AndroidMapCluster.self, from: Data(json.utf8))
        XCTAssertEqual(cluster.colorRsrp, -97, "la médiane d'abord")
        XCTAssertEqual(cluster.medianRsrq, -11)
        XCTAssertEqual(cluster.medianSnr, 8)
        let scoped = cluster.scoped(to: AndroidMapTile(z: 8, x: 1, y: 2))
        XCTAssertEqual(scoped.medianRsrq, -11)
        XCTAssertEqual(scoped.medianSnr, 8)
        let older = try JSONDecoder().decode(AndroidMapCluster.self, from: Data(#"{"id":"0:1","lat":1,"lng":2,"count":3,"avgRsrp":-95}"#.utf8))
        XCTAssertEqual(older.colorRsrp, -95, "serveur d'avant : la moyenne")
        XCTAssertNil(older.medianRsrq)
    }

    /// Un seul réglage pour la feuille Carte, sa légende et la pastille de la
    /// carte : Génération garde la mesure d'avant (retour d'Alexandre du 21/11).
    func testColoringIsOneSettingSharedBySheetLegendAndPill() {
        var byGeneration = false
        var measure = SQQualityScale.Signal.Measure.rsrq
        let coloring = CoverageColoring.binding(
            byGeneration: Binding(get: { byGeneration }, set: { byGeneration = $0 }),
            measure: Binding(get: { measure }, set: { measure = $0 })
        )
        XCTAssertEqual(coloring.wrappedValue, .rsrq)
        coloring.wrappedValue = .generation
        XCTAssertTrue(byGeneration)
        XCTAssertEqual(measure, .rsrq, "Génération garde la mesure d'avant")
        coloring.wrappedValue = .sinr
        XCTAssertFalse(byGeneration)
        XCTAssertEqual(measure, .sinr)
        XCTAssertEqual(CoverageColoring.allCases.map { "map.coverage.mode.\(String(describing: $0))" },
                       ["map.coverage.mode.rsrp", "map.coverage.mode.rsrq", "map.coverage.mode.sinr", "map.coverage.mode.generation"],
                       "identifiants des tests UI inchangés")
    }

    func testScaleStripShowsTheTwoEnds() {
        XCTAssertEqual(CoverageColoring.rsrp.swatches.count, 5)
        XCTAssertEqual(CoverageColoring.generation.swatches.count, 4)
        let rsrp = CoverageScaleStrip(coloring: .rsrp, marketCode: "FR").ends
        XCTAssertEqual(rsrp.best, "Excellent ≥ \u{2212}80 dBm", "même mot dans les deux langues")
        XCTAssertEqual(rsrp.worst, french ? "Critique < \u{2212}110 dBm" : "Critical < \u{2212}110 dBm")
        let sinr = CoverageScaleStrip(coloring: .sinr, marketCode: "FR").ends
        XCTAssertTrue(sinr.best.hasSuffix("≥ 20 dB"), sinr.best)
        XCTAssertTrue(sinr.worst.hasSuffix("< 0 dB"), sinr.worst)
        let generation = CoverageScaleStrip(coloring: .generation, marketCode: "FR").ends
        XCTAssertEqual(generation.best, "5G")
        XCTAssertEqual(generation.worst, "2G")
    }

    func testFallbackPointsDecodeRawRsrqAndSnr() throws {
        let json = #"{"points":[{"id":"a","latitude":45.2,"longitude":5.7,"signalStrength":-97,"rsrq":-11,"snr":8,"technology":"4G"},{"id":"b","latitude":45.3,"longitude":5.8,"signalStrength":-90,"technology":"4G"}]}"#
        let points = try JSONDecoder().decode(CoveragePointsResponse.self, from: Data(json.utf8)).points
        XCTAssertEqual(points[0].rsrq, -11)
        XCTAssertEqual(points[0].snr, 8)
        XCTAssertNil(points[1].rsrq, "serveur d'avant : pas de RSRQ, le point n'est pas dessiné en RSRQ")
        XCTAssertNil(CoverageQualityBand.band(measure: .rsrq, rsrp: points[1].signalStrength, rsrq: points[1].rsrq,
                                              sinr: points[1].snr, technology: points[1].technology))
    }
}
