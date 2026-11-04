import CryptoKit
import XCTest
@testable import SignalQuest

/// Révision 17 (E2EE-AUTO §7.7) : `MEDIA`, `AUDIO`, sondages et carte de
/// publication, lus et écrits à l'octet contre le vecteur `content-r17-v1`.
final class E2EEAutoContentR17Tests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/content-r17-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(vector()[key] as? [[String: Any]])
    }

    /// 12 charges valides : lues, réécrites à l'octet, livraison et règle (a) attendues.
    func testValidPayloadsAreReadAndRewrittenAtTheByte() throws {
        let valid = try cases("valid")
        XCTAssertEqual(valid.count, 12)
        for item in valid {
            let name = try XCTUnwrap(item["case"] as? String)
            let payload = Data(try XCTUnwrap(item["payloadUtf8"] as? String).utf8)
            guard case .ok(let content) = E2EEAutoContentR17.read(payload) else {
                XCTFail("\(name) : refusé")
                continue
            }
            XCTAssertEqual(content.body.kind, item["kind"] as? String, name)
            XCTAssertEqual(content.body.delivery.rawValue, item["delivery"] as? String, name)
            XCTAssertEqual(content.body.blobIds, item["blobIds"] as? [String], name)
            XCTAssertEqual(try E2EEAutoContentR17.encoded(content), payload, "\(name) : réécriture")
        }
    }

    /// 30 charges refusées : `MALFORMED` (illisible) ou `UNSUPPORTED` (« Contenu non pris en charge »).
    func testNegativePayloadsGetTheirVerdict() throws {
        let negative = try cases("negative")
        XCTAssertEqual(negative.count, 30)
        for item in negative {
            let name = try XCTUnwrap(item["case"] as? String)
            let payload = Data(try XCTUnwrap(item["payloadUtf8"] as? String).utf8)
            let expected: E2EEAutoContentR17.Read = item["expected"] as? String == "UNSUPPORTED" ? .unsupported : .malformed
            XCTAssertEqual(E2EEAutoContentR17.read(payload), expected, name)
        }
    }

    /// 8 décomptes : dernier vote par `sequence`, vote invalide ignoré en entier,
    /// retrait, clôture par l'auteur ou un administrateur, clôture indécidable, échéance.
    func testPollTalliesMatchTheVector() throws {
        let tallies = try cases("tallies")
        XCTAssertEqual(tallies.count, 8)
        func int(_ value: Any?) throws -> Int64 { try XCTUnwrap((value as? String).flatMap { Int64($0) }) }
        for item in tallies {
            let name = try XCTUnwrap(item["case"] as? String)
            let poll = try XCTUnwrap(item["poll"] as? [String: Any])
            let events = try XCTUnwrap(item["events"] as? [[String: Any]]).map { event -> E2EEAutoContentR17.PollEvent in
                let sender = event["senderId"] as? String ?? "", sequence = try int(event["sequence"])
                let serverTime = try int(event["serverTimeMs"])
                if event["kind"] as? String == "POLL_CLOSE" {
                    return .close(senderId: sender, sequence: sequence, serverTimeMs: serverTime, senderIsAdmin: event["senderIsAdmin"] as? Bool)
                }
                return .vote(senderId: sender, sequence: sequence, serverTimeMs: serverTime, optionIds: event["optionIds"] as? [String] ?? [])
            }
            let closesAt = poll["closesAtMs"] is NSNull ? nil : try int(poll["closesAtMs"])
            let tally = E2EEAutoContentR17.tally(
                authorId: try XCTUnwrap(poll["authorId"] as? String), optionIds: try XCTUnwrap(poll["optionIds"] as? [String]),
                multipleChoice: try XCTUnwrap(poll["multipleChoice"] as? Bool), closesAtMs: closesAt,
                events: events, nowServerMs: try int(item["nowServerMs"])
            )
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            XCTAssertEqual(tally.closed, expected["closed"] as? Bool, name)
            XCTAssertEqual(tally.closedBySequence, (expected["closedBySequence"] as? String).flatMap { Int64($0) }, name)
            XCTAssertEqual(tally.closePending, expected["closePending"] as? Bool, name)
            XCTAssertEqual(tally.votes, expected["votes"] as? [String: [String]], name)
            let counts = try XCTUnwrap(expected["counts"] as? [[String: Any]])
            XCTAssertEqual(tally.counts.map(\.id), counts.map { $0["id"] as? String ?? "" }, name)
            XCTAssertEqual(tally.counts.map { String($0.count) }, counts.map { $0["count"] as? String ?? "" }, name)
        }
    }

    /// Les natures du jalon A restent au lecteur existant ; une version future est « non pris en charge ».
    func testOtherKindsAndVersions() {
        func payload(kind: String, version: String = "2") -> Data {
            Data(#"{"body":{"text":"x"},"counter":"1","kind":"\#(kind)","mentions":[],"replyToRef":null,"schema":"signalquest.e2ee-content","sentAtMs":"1","version":"\#(version)"}"#.utf8)
        }
        XCTAssertEqual(E2EEAutoContentR17.read(payload(kind: "TEXT")), .unsupported)
        XCTAssertEqual(E2EEAutoContentR17.read(payload(kind: "MEDIA", version: "3")), .unsupported)
        XCTAssertEqual(E2EEAutoContentR17.read(payload(kind: "media")), .malformed)
        XCTAssertEqual(E2EEAutoContentR17.presentation(mimeType: "image/heic"), .image)
        XCTAssertEqual(E2EEAutoContentR17.presentation(mimeType: "video/quicktime"), .video)
        XCTAssertEqual(E2EEAutoContentR17.presentation(mimeType: "application/pdf"), .file)
    }

    /// La charge v2 lit et réécrit la révision 17 à l'octet ; ses refus restent
    /// illisibles, ou « non pris en charge » quand le vecteur le dit.
    func testContentPayloadV2ReadsRevision17() throws {
        for item in try cases("valid") {
            let name = try XCTUnwrap(item["case"] as? String)
            let payload = Data(try XCTUnwrap(item["payloadUtf8"] as? String).utf8)
            let parsed = try E2EEV2ContentPayloadV2.parse(payload)
            guard case .r17(let body) = parsed.body else { return XCTFail("\(name) : pas révision 17") }
            XCTAssertEqual(body.kind, item["kind"] as? String, name)
            XCTAssertEqual(try parsed.encoded(), payload, "\(name) : réécriture v2")
            XCTAssertFalse(E2EEV2ContentPayloadV2.isUnsupported(payload), name)
        }
        for item in try cases("negative") {
            let name = try XCTUnwrap(item["case"] as? String)
            let payload = Data(try XCTUnwrap(item["payloadUtf8"] as? String).utf8)
            XCTAssertThrowsError(try E2EEV2ContentPayloadV2.parse(payload), name)
            XCTAssertEqual(E2EEV2ContentPayloadV2.isUnsupported(payload), item["expected"] as? String == "UNSUPPORTED", name)
        }
    }

    /// L'empreinte des vecteurs copiés est celle du dépôt serveur.
    func testVectorChecksums() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto")
        let sums = try String(contentsOf: dir.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let line = try XCTUnwrap(sums.split(separator: "\n").first { $0.hasSuffix("  content-r17-v1.json") })
        let data = try Data(contentsOf: dir.appendingPathComponent("content-r17-v1.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(String(line.prefix(64)), digest)
    }
}
