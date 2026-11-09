import CryptoKit
import XCTest
@testable import SignalQuest

/// Vecteurs `epoch-member-missing-v1` (E2EE-MEMBRE r2, 09/11) : le serveur
/// refuse en 422 MEMBER_MISSING une époque qui oublie un membre ayant un
/// appareil éligible. On rejoue d'abord la règle sur les destinataires du
/// vecteur (pour fixer notre lecture de l'éligibilité), puis on vérifie que les
/// destinataires que compose iOS ne déclenchent jamais ce refus.
final class E2EEMemberMissingVectorTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto")
    }

    private func load() throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("epoch-member-missing-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func int64(_ object: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap((object[key] as? NSNumber)?.int64Value, key)
    }

    func testChecksum() throws {
        let sums = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let line = try XCTUnwrap(sums.split(separator: "\n").first { $0.hasSuffix("  epoch-member-missing-v1.json") })
        let data = try Data(contentsOf: directory.appendingPathComponent("epoch-member-missing-v1.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(String(line.prefix(64)), digest)
    }

    /// Membres qu'aucun appareil cité ne couvre alors qu'ils en ont un éligible
    /// au sens du serveur : ACTIVE (journal), ou APPROVED avec des capacités de
    /// moins de 89 jours et pas dans le futur ; jamais un navigateur exclu.
    private func missing(_ testCase: [String: Any], cited: Set<String>, nowMs: Int64, windowMs: Int64) throws -> [String] {
        let excludesWeb = try XCTUnwrap(testCase["excludesWeb"] as? Bool)
        let devices = try XCTUnwrap(testCase["devices"] as? [String: [[String: Any]]])
        return try XCTUnwrap(testCase["memberUserIds"] as? [String]).filter { userId in
            let eligible = (devices[userId] ?? []).contains { device in
                if excludesWeb && device["platform"] as? String == "web" { return false }
                switch device["state"] as? String {
                case "ACTIVE": return true
                case "APPROVED":
                    guard let issued = (device["capabilitiesIssuedAtMs"] as? NSNumber)?.int64Value else { return false }
                    return issued <= nowMs && nowMs - issued < windowMs
                default: return false
                }
            }
            return eligible && !cited.contains { $0.hasPrefix(userId + "\n") }
        }
        .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    func testVectors() throws {
        let vectors = try load()
        XCTAssertEqual((vectors["fixtureVersion"] as? NSNumber)?.intValue, 1)
        let nowMs = try int64(vectors, "nowMs")
        let windowMs = try int64(vectors, "freshnessMs") - int64(vectors, "marginMs")
        XCTAssertEqual(try int64(vectors, "freshnessMs"), E2EEV2IdentityVerification.capabilityFreshnessMs)
        let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 17)

        for testCase in cases {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], name)
            let stale = testCase["staleUserIds"] as? [String] ?? []

            // 1. La règle du serveur, rejouée sur les destinataires du vecteur.
            let served = Set(try XCTUnwrap(testCase["recipients"] as? [String], name))
            let gaps = try missing(testCase, cited: served, nowMs: nowMs, windowMs: windowMs)
            if !stale.isEmpty {
                XCTAssertEqual(expect["code"] as? String, "E2EE_DEVICE_LIST_STALE", name)
                XCTAssertEqual(expect["userIds"] as? [String], stale, name)
            } else if gaps.isEmpty {
                XCTAssertEqual(expect["ok"] as? Bool, true, name)
            } else {
                XCTAssertEqual(expect["status"] as? Int, 422, name)
                XCTAssertEqual(expect["reason"] as? String, "MEMBER_MISSING", name)
                XCTAssertEqual(expect["userIds"] as? [String], gaps, name)
            }

            // 2. Ce que compose iOS sur les mêmes appareils (révoqués absents de
            // l'ensemble certifié, appareils du journal jamais mis à l'écart).
            let mode = try XCTUnwrap(testCase["mode"] as? String, name)
            let devices = try XCTUnwrap(testCase["devices"] as? [String: [[String: Any]]], name)
            var byUser: [String: [E2EEV2CertifiedDevice]] = [:]
            for (userId, list) in devices {
                byUser[userId] = try list.filter { $0["state"] as? String != "REVOKED" }.map { device in
                    let deviceId = try XCTUnwrap(device["deviceId"] as? String, name)
                    let capabilities = ((device["capabilitiesIssuedAtMs"] as? NSNumber)?.int64Value).map {
                        E2EEV2CapabilitiesDocument(
                            userId: userId, deviceId: deviceId, sequence: 1, issuedAtMs: $0,
                            envelopeVersions: [], payloadVersions: [], kinds: [], features: []
                        )
                    }
                    var certified = E2EEV2CertifiedDevice(
                        userId: userId, deviceId: deviceId, keyVersion: 1,
                        platform: try XCTUnwrap(device["platform"] as? String, name),
                        identityKeyB64: "", signingKeyB64: "", fingerprint: "", capabilities: capabilities
                    )
                    certified.verifiedByLog = mode == "auto"
                    return certified
                }
            }
            let composed = E2EEV2EpochProposals.recipients(
                E2EEV2CertifiedDeviceSet(devicesByUser: byUser, refusals: [:]),
                members: Set(try XCTUnwrap(testCase["memberUserIds"] as? [String], name)),
                excludesWeb: try XCTUnwrap(testCase["excludesWeb"] as? Bool, name),
                nowMs: nowMs
            )
            let lines = Set(composed.map { "\($0.userId)\n\($0.deviceId)" })
            XCTAssertEqual(try missing(testCase, cited: lines, nowMs: nowMs, windowMs: windowMs), [], "\(name) : iOS oublie un membre")
        }
    }
}
