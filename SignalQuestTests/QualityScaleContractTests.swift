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

    private func contractData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent("contracts/quality-scale-v1.json"))
    }

    private func contract() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: contractData()) as? [String: Any])
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
        let vectors = try XCTUnwrap(((try contract())["vectors"] as? [String: Any])?["downloadSpeed"] as? [[String: Any]])
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
        XCTAssertTrue(SQQualityScale.Signal.noService.isHatched)
    }

    func testDownloadThresholdsAndColors() throws {
        let download = try XCTUnwrap((try contract())["downloadSpeed"] as? [String: Any])
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
