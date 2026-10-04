import CryptoKit
import XCTest
@testable import SignalQuest

/// Vecteur `recovery-bundle-v3` (§2.8, v0.4.21) : le bundle de
/// `recovery-proof-v2` avec l'UIK d'`identity-reset-v1` enveloppée sous la même
/// clé de récupération (rôle `ACCOUNT`, sel 0x33 × 32, nonce 0x44 × 12), sa
/// forme hachée figée à l'octet (condensat confronté au banc du serveur) et la
/// signature de l'UIK. Généré seulement avec
/// `SQ_E2EE_GENERATE_RECOVERY_V3=1` : ce test n'écrit que ce fichier.
final class E2EEV2RecoveryBundleV3VectorTests: XCTestCase {
    /// Le condensat du banc déterministe du serveur (#322).
    static let serverBundleHash = "7cb90cd3dc404f56d485fbc66687de2ab87b5dbaff157284ef8ab6d1a9bef438"
    private static let name = "recovery-bundle-v3"

    private func vectorURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/\(name).json")
    }

    private func load(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL(name))) as? [String: Any])
    }

    private func bundle(_ object: [String: Any]) throws -> E2EEV2RecoveryBundleV2 {
        try JSONDecoder().decode(E2EEV2RecoveryBundleV2.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func object(_ bundle: E2EEV2RecoveryBundleV2) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEV2RecoveryV2Contract.bundleData(bundle)) as? [String: Any])
    }

    // MARK: Génération

    func testGenerateRecoveryBundleV3Vector() throws {
        guard ProcessInfo.processInfo.environment["SQ_E2EE_GENERATE_RECOVERY_V3"] == "1" else {
            throw XCTSkip("Génération : SQ_E2EE_GENERATE_RECOVERY_V3=1")
        }
        let proof = try load("recovery-proof-v2"), reset = try load("identity-reset-v1")
        let ownerBinding = try XCTUnwrap(proof["ownerNamespace"] as? String)
        let userId = String(ownerBinding.dropFirst("user:".count))
        let recoveryKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(proof["recoveryKeyB64"] as? String)))
        let uik = try P256.Signing.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: try XCTUnwrap(reset["newUikPrivateRawB64"] as? String))))
        let v2 = try bundle(try XCTUnwrap(proof["bundle"] as? [String: Any]))
        let salt = Data(repeating: 0x33, count: 32), nonce = Data(repeating: 0x44, count: 12)
        let account = try E2EEV2RecoveryV2Crypto.wrapAccountKey(uik, recoveryKey: recoveryKey, ownerBinding: ownerBinding, salt: salt, nonce: nonce)
        let v3 = E2EEV2RecoveryBundleV2(
            recoveryPublicIdentityKeyB64: v2.recoveryPublicIdentityKeyB64, recoveryPublicSigningKeyB64: v2.recoveryPublicSigningKeyB64,
            identityPrivateKey: v2.identityPrivateKey, signingPrivateKey: v2.signingPrivateKey, accountPrivateKey: account
        )
        let canonical = E2EEV2RecoveryV2Contract.canonicalBundleJSON(v3)
        let hash = E2EEV2RecoveryV2Crypto.bundleHash(v3)
        XCTAssertEqual(hash, Self.serverBundleHash, "Même condensat que le banc du serveur")
        let signedText = E2EEV2RecoveryV2Crypto.bundleSignatureCanonical(userId: userId, bundle: v3)
        let signature = try E2EEV2LowS.sign(signedText, with: uik)

        // Cas négatifs.
        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        func withAccount(_ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            var bundleObject = try object(v3)
            var accountObject = try XCTUnwrap(bundleObject["accountPrivateKey"] as? [String: Any])
            change(&accountObject)
            bundleObject["accountPrivateKey"] = accountObject
            return bundleObject
        }
        func aad(_ owner: String, _ role: String) -> String { Data("SQ-E2EE-V2-RECOVERY\n2\n\(owner)\n\(role)".utf8).base64EncodedString() }
        var v2WithNinth = try object(v3)
        v2WithNinth["version"] = 2
        var kdf = try XCTUnwrap(v2WithNinth["kdfParameters"] as? [String: Any])
        kdf.removeValue(forKey: "accountInfo")
        v2WithNinth["kdfParameters"] = kdf
        var v3WithoutAccount = try object(v3)
        v3WithoutAccount.removeValue(forKey: "accountPrivateKey")
        // Scalaire hors de [1, n−1] : n lui-même, enveloppé avec la vraie UIK publique.
        let order = Data(E2EEV2LowS.curveOrder)
        let outOfRange = try E2EEV2RecoveryV2Crypto.wrap(
            privateRaw: order, publicX963: uik.publicKey.x963Representation, recoveryKey: recoveryKey,
            ownerBinding: ownerBinding, role: .account, salt: salt, nonce: Data(repeating: 0x45, count: 12)
        )
        // Chaque cas dit où il échoue (`expect`) ; un bundle modifié porte son
        // propre condensat, pour n'échouer que sur la règle visée.
        func negative(_ name: String, _ expect: String, bundle: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> [String: Any] {
            var item: [String: Any] = ["name": name, "expect": expect]
            if let bundle {
                item["bundle"] = bundle
                if let decoded = try? self.bundle(bundle) { item["bundleHash"] = E2EEV2RecoveryV2Crypto.bundleHash(decoded) }
            }
            return item.merging(extra) { _, new in new }
        }
        let negatives: [[String: Any]] = [
            try negative("aad-role-identity", "shape", bundle: try withAccount { $0["aadB64"] = aad(ownerBinding, "IDENTITY") }),
            try negative("aad-role-signing", "shape", bundle: try withAccount { $0["aadB64"] = aad(ownerBinding, "SIGNING") }),
            try negative("aad-other-account", "shape", bundle: try withAccount { $0["aadB64"] = aad("user:other-fixture", "ACCOUNT") }),
            try negative("served-uik-differs", "served", extra: ["servedUikPublicX963B64": other]),
            try negative("version-2-with-ninth-key", "shape", bundle: v2WithNinth),
            try negative("version-3-without-account-key", "shape", bundle: v3WithoutAccount),
            try negative("scalar-out-of-range", "unwrap", bundle: try withAccount {
                $0["wrappedPrivateJwkB64"] = outOfRange.wrappedPrivateJwkB64
                $0["nonceB64"] = outOfRange.nonceB64
            }),
            try negative("hash-without-account-key", "hash", extra: ["bundleHash": E2EEV2RecoveryV2Crypto.bundleHash(v2)]),
            try negative("equal-nonces", "shape", bundle: try withAccount { $0["nonceB64"] = v2.identityPrivateKey.nonceB64 }),
            try negative("public-key-not-the-wrapped-uik", "unwrap", bundle: try withAccount { $0["publicKeyB64"] = other }),
        ]
        let vector: [String: Any] = [
            "fixtureVersion": 1,
            "ownerNamespace": ownerBinding,
            "userId": userId,
            "recoveryKeyB64": recoveryKey.base64EncodedString(),
            "uikPrivateRawB64": uik.rawRepresentation.base64EncodedString(),
            "uikPublicX963B64": uik.publicKey.x963Representation.base64EncodedString(),
            "servedUikPublicX963B64": uik.publicKey.x963Representation.base64EncodedString(),
            "bundle": try object(v3),
            "canonicalUtf8": canonical,
            "bundleHash": hash,
            "bundleSignatureUtf8": String(decoding: signedText, as: UTF8.self),
            "bundleSignatureDerB64": signature.base64EncodedString(),
            "negative": negatives,
        ]
        let data = try JSONSerialization.data(withJSONObject: vector, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: vectorURL(Self.name))
    }

    // MARK: Lecture

    private enum Stage: String { case shape, hash, unwrap, served }
    private struct Refused: Error { let stage: Stage }

    /// Ce que fait un appareil en récupération, dans l'ordre : lecture stricte
    /// du bundle servi (celle de production), condensat attendu, déballage de
    /// l'UIK, puis UIK servie. Lève l'étape qui refuse.
    private func recover(
        _ bundleObject: [String: Any],
        expectedHash: String,
        servedUIK: String,
        recoveryKey: Data,
        ownerBinding: String
    ) throws -> P256.Signing.PrivateKey {
        var served = bundleObject
        served["createdAt"] = "2026-10-05T00:00:00.000Z"
        served["rotatedAt"] = NSNull()
        served["revokedAt"] = NSNull()
        guard let response = try? JSONSerialization.data(withJSONObject: ["state": "AVAILABLE", "bundle": served]),
              let candidate = E2EEV2RecoveryV2Contract.parseActiveBundle(response, expectedOwnerBinding: ownerBinding) else {
            throw Refused(stage: .shape)
        }
        guard E2EEV2RecoveryV2Crypto.bundleHash(candidate) == expectedHash else { throw Refused(stage: .hash) }
        let uik: P256.Signing.PrivateKey
        do {
            uik = try E2EEV2RecoveryV2Crypto.unwrapAccountPrivateKey(bundle: candidate, recoveryKey: recoveryKey, ownerBinding: ownerBinding)
        } catch {
            throw Refused(stage: .unwrap)
        }
        guard uik.publicKey.x963Representation.base64EncodedString() == servedUIK else { throw Refused(stage: .served) }
        return uik
    }

    func testRecoveryBundleV3Vector() throws {
        let v = try load(Self.name)
        let ownerBinding = try XCTUnwrap(v["ownerNamespace"] as? String)
        let recoveryKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(v["recoveryKeyB64"] as? String)))
        let bundleObject = try XCTUnwrap(v["bundle"] as? [String: Any])
        let expectedHash = try XCTUnwrap(v["bundleHash"] as? String)
        let served = try XCTUnwrap(v["servedUikPublicX963B64"] as? String)
        let parsed = try bundle(bundleObject)
        XCTAssertEqual(parsed.version, 3)
        XCTAssertEqual(E2EEV2RecoveryV2Contract.canonicalBundleJSON(parsed), v["canonicalUtf8"] as? String, "Forme hachée à l'octet")
        XCTAssertEqual(expectedHash, Self.serverBundleHash)
        let uik = try recover(bundleObject, expectedHash: expectedHash, servedUIK: served, recoveryKey: recoveryKey, ownerBinding: ownerBinding)
        XCTAssertEqual(uik.rawRepresentation.base64EncodedString(), v["uikPrivateRawB64"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(v["bundleSignatureDerB64"] as? String)))
        XCTAssertEqual(
            E2EEV2RecoveryV2Crypto.bundleSignatureCanonical(userId: try XCTUnwrap(v["userId"] as? String), bundle: parsed),
            Data(try XCTUnwrap(v["bundleSignatureUtf8"] as? String).utf8)
        )
        XCTAssertTrue(E2EEV2SignedString(
            canonical: try XCTUnwrap(v["bundleSignatureUtf8"] as? String), signatureB64: signature.base64EncodedString()
        ).verify(with: uik.publicKey))

        let negatives = try XCTUnwrap(v["negative"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(negatives.count, 10)
        for negative in negatives {
            let name = negative["name"] as? String ?? "?"
            XCTAssertThrowsError(try recover(
                negative["bundle"] as? [String: Any] ?? bundleObject,
                expectedHash: negative["bundleHash"] as? String ?? expectedHash,
                servedUIK: negative["servedUikPublicX963B64"] as? String ?? served,
                recoveryKey: recoveryKey, ownerBinding: ownerBinding
            ), name) { error in
                XCTAssertEqual((error as? Refused)?.stage.rawValue, negative["expect"] as? String, "Refusé pour la règle visée : \\(name)")
            }
        }
    }

    /// Un bundle v2 garde son usage : il se lit, mais ne donne aucune UIK.
    func testAV2BundleNeverYieldsTheAccountKey() throws {
        let proof = try load("recovery-proof-v2")
        let ownerBinding = try XCTUnwrap(proof["ownerNamespace"] as? String)
        let v2 = try bundle(try XCTUnwrap(proof["bundle"] as? [String: Any]))
        XCTAssertTrue(E2EEV2RecoveryV2Contract.validate(v2, ownerBinding: ownerBinding))
        XCTAssertEqual(E2EEV2RecoveryV2Crypto.bundleHash(v2), proof["bundleHash"] as? String, "Forme hachée v2 inchangée")
        let recoveryKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(proof["recoveryKeyB64"] as? String)))
        XCTAssertThrowsError(try E2EEV2RecoveryV2Crypto.unwrapAccountPrivateKey(bundle: v2, recoveryKey: recoveryKey, ownerBinding: ownerBinding))
    }
}
