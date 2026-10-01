import CryptoKit
import XCTest
@testable import SignalQuest

/// Contrat de couleurs v1.1 (`contracts/quality-scale-v1.1.json`, gelé le
/// 01/10/2026 avec Alexandre, PR web #252) : une teinte par bande ANFR, claire
/// et sombre, et le trait sombre de chaque génération sur un graphique. La
/// copie est celle du web, octet pour octet ; la partie v1 n'a pas changé.
final class QualityScaleContractV11Tests: XCTestCase {
    private static let expectedSHA256 = "39606af0e1a37b58bc00c513a87a932399b146151e9fcac92f533291f5745dff"

    private func data(_ name: String) throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent("contracts/\(name)"))
    }

    private func contract() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data("quality-scale-v1.1.json")) as? [String: Any])
    }

    private func hex(_ value: Any?) throws -> UInt32 {
        let text = try XCTUnwrap(value as? String)
        XCTAssertTrue(text.hasPrefix("#"), text)
        return try XCTUnwrap(UInt32(text.dropFirst(), radix: 16))
    }

    private func text(_ value: UInt32) -> String { String(format: "#%06X", value) }

    func testTheCopyIsTheFrozenContract() throws {
        let digest = SHA256.hash(data: try data("quality-scale-v1.1.json")).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.expectedSHA256, "La copie doit être celle du web, octet pour octet")
        let root = try contract()
        XCTAssertEqual(root["contract"] as? String, "quality-scale")
        XCTAssertEqual(root["version"] as? String, "1.1", "La v1.1 porte sa version en chaîne")
        XCTAssertEqual(root["status"] as? String, "frozen")
    }

    /// Signal, débit, génération et opérateurs : ceux de la v1, que
    /// `QualityScaleContractTests` vérifie déjà contre l'app.
    func testTheV1PartIsUnchanged() throws {
        let v11 = try contract()
        let v1 = try XCTUnwrap(try JSONSerialization.jsonObject(with: data("quality-scale-v1.json")) as? [String: Any])
        for key in ["signal", "downloadSpeed", "generation", "operators"] {
            XCTAssertEqual(v11[key] as? NSDictionary, v1[key] as? NSDictionary, key)
        }
        let vectors11 = try XCTUnwrap(v11["vectors"] as? [String: Any])
        let vectors1 = try XCTUnwrap(v1["vectors"] as? [String: Any])
        for key in ["signal", "downloadSpeed"] {
            XCTAssertEqual(vectors11[key] as? NSArray, vectors1[key] as? NSArray, "vectors.\(key)")
        }
    }

    func testEveryBandAndGenerationStrokeMatchesTheApp() throws {
        let bands = try XCTUnwrap((try contract())["bands"] as? [String: Any])
        let levels = try XCTUnwrap(bands["levels"] as? [[String: Any]])
        XCTAssertEqual(levels.count, SQQualityScale.Band.levels.count)
        let generations: [String: SQQualityScale.Generation] = ["2G": .twoG, "3G": .threeG, "4G": .fourG, "5G": .fiveG]
        for level in levels {
            let key = try XCTUnwrap(level["key"] as? String)
            let band = try XCTUnwrap(SQQualityScale.Band.levels[key], "Bande du contrat absente de l'app : \(key)")
            XCTAssertEqual(text(band.light), text(try hex(level["light"])), "\(key) clair")
            XCTAssertEqual(text(band.dark), text(try hex(level["dark"])), "\(key) sombre")
            XCTAssertEqual(SQQualityScale.Band.generation(ofKey: key), generations[try XCTUnwrap(level["generation"] as? String)], key)
        }
        let strokes = try XCTUnwrap((bands["generationStroke"] as? [String: Any])?["levels"] as? [[String: Any]])
        XCTAssertEqual(strokes.count, generations.count)
        for stroke in strokes {
            let key = try XCTUnwrap(stroke["key"] as? String)
            let generation = try XCTUnwrap(generations[key], key)
            XCTAssertEqual(text(generation.hex), text(try hex(stroke["light"])), "\(key) clair : la teinte de la v1")
            XCTAssertEqual(text(generation.chartDarkHex), text(try hex(stroke["dark"])), "\(key) sombre")
        }
    }

    /// Clés en minuscules, repli sur la génération lue au préfixe, aucune
    /// teinte sans génération reconnaissable.
    func testBandVectorsPass() throws {
        let vectors = try XCTUnwrap(((try contract())["vectors"] as? [String: Any])?["bands"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 11)
        for vector in vectors {
            let key = try XCTUnwrap(vector["key"] as? String)
            let mode = try XCTUnwrap(vector["mode"] as? String)
            let stroke = SQQualityScale.Band.stroke(key)
            let actual = stroke.map { text(mode == "dark" ? $0.dark : $0.light) }
            let expected: String? = try (vector["expected"] is NSNull ? nil : text(hex(vector["expected"])))
            XCTAssertEqual(actual, expected, "« \(key) » \(mode)")
        }
    }
}
