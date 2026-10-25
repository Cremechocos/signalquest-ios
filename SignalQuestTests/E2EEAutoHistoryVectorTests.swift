import CryptoKit
import XCTest
@testable import SignalQuest

/// Vecteurs `history-wrap-v1` et `passkey-wrap-v1` (contrat E2EE-AUTO §5.4 à
/// §5.6, phase 1b) rejoués avec CryptoKit dans les deux sens : chaînes de sel,
/// d'AAD et de signature, secret ECDH, clé HKDF, scellement à l'octet avec
/// l'éphémère et le nonce du vecteur, ouverture, et chaque verdict du lecteur
/// face au journal vérifié.
final class E2EEAutoHistoryVectorTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func bytes(_ object: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try string(object, key)), key)
    }

    /// Journal vérifié du compte d'Alice sur lequel les enveloppes sont jugées ;
    /// `variant` : un journal de `logVariants`, sur la même clé, sans tête propre.
    private func verifiedAccount(_ vectors: [String: Any], variant: String? = nil) throws -> E2EEAutoLog.AccountState {
        let main = try XCTUnwrap(vectors["log"] as? [String: Any])
        let log = try variant.map { try XCTUnwrap((vectors["logVariants"] as? [String: Any])?[$0] as? [String: Any], $0) } ?? main
        let links = try XCTUnwrap(log["links"] as? [String])
        XCTAssertEqual((main["logKeyEntries"] as? [String: String])?.isEmpty, true)
        let chain = try E2EEAutoLog.extendChain(
            .initial(pinnedLogKeyB64: try string(main, "pinnedLogKeyB64")), links: links, logKeyEntries: [:]
        ).get()
        if variant == nil { try checkHead(main, chain: chain) }
        let account = try XCTUnwrap(log["account"] as? [String: Any])
        let bySeq = try Dictionary(uniqueKeysWithValues: links.map { (try XCTUnwrap(E2EEAutoLog.parseLink($0)).seq, $0) })
        return try E2EEAutoLog.verifyAccount(
            userId: try string(account, "userId"), accountSaltB64: try string(account, "accountSaltB64"),
            entries: try XCTUnwrap(account["entries"] as? [String]), links: bySeq, chain: chain
        ).get()
    }

    private func checkHead(_ log: [String: Any], chain: E2EEAutoLog.ChainState) throws {
        let head = try XCTUnwrap(log["head"] as? [String: Any])
        let check = E2EEAutoLog.checkHead(
            text: try string(head, "text"), signatureB64: try string(head, "signatureB64"), logKeyB64: chain.logKeyB64,
            nowMs: try XCTUnwrap((log["headNowMs"] as? NSNumber)?.int64Value)
        )
        guard case let .ok(verifiedHead) = check else { return XCTFail("tête : \(check)") }
        XCTAssertEqual(E2EEAutoLog.compare(head: verifiedHead, to: chain), .match)
    }

    private func reader(_ object: [String: Any]) throws -> E2EEAutoHistory.Reader {
        switch try string(object, "kind") {
        case "device":
            return .device(
                deviceId: try string(object, "deviceId"),
                keyVersions: try XCTUnwrap(object["keyVersions"] as? [Int]),
                openRequestIds: try XCTUnwrap(object["openRequestIds"] as? [String]),
                heldHkPubB64: object["heldHkPubB64"] as? String
            )
        case "history":
            return .history(hkPubB64: try string(object, "hkPubB64"))
        default:
            XCTFail("lecteur inconnu")
            throw CocoaError(.coderInvalidValue)
        }
    }

    // MARK: Enveloppe d'historique

    func testHistoryWrapCases() throws {
        let vectors = try load("history-wrap-v1")
        XCTAssertEqual(try string(vectors, "kdfInfo"), E2EEAutoHistory.historyWrapInfo)
        let userId = try string(vectors, "userId")
        let account = try verifiedAccount(vectors)
        let secrets = try XCTUnwrap(vectors["secrets"] as? [String: Any])
        // Clés privées d'accord du lecteur : A2 par version de clé, et chaque HK par sa clé publique.
        var historyScalars: [String: Data] = [:]
        for name in ["hk1ScalarB64", "hk2ScalarB64", "hk3ScalarB64", "hk4ScalarB64", "hkUnknownScalarB64"] {
            let scalar = try bytes(secrets, name)
            historyScalars[try XCTUnwrap(E2EEAutoHistoryKey.publicKeyB64(scalar: scalar))] = scalar
        }

        let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 34)
        var variants: [String: E2EEAutoLog.AccountState] = [:]
        for testCase in cases {
            let name = try string(testCase, "name")
            let object = try XCTUnwrap(testCase["wrap"] as? [String: Any], name)
            let wrap = try XCTUnwrap(E2EEAutoHistory.parseWrap(object), name)
            let steps = try XCTUnwrap(testCase["intermediates"] as? [String: Any], name)
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], name)

            // Chaînes du contrat.
            let saltText = E2EEAutoHistory.saltText(
                userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient,
                keyVersion: wrap.keyVersion, requestId: wrap.requestId, addHash: wrap.addHash
            )
            XCTAssertEqual(saltText, try string(steps, "saltUtf8"), name)
            XCTAssertEqual(Data(SHA256.hash(data: Data(saltText.utf8))), try bytes(steps, "saltB64"), name)
            XCTAssertEqual(
                E2EEAutoHistory.aadText(
                    userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient, keyVersion: wrap.keyVersion,
                    requestId: wrap.requestId, addHash: wrap.addHash, hkPubB64: wrap.hkPubB64, ephemeralB64: wrap.ephemeralB64
                ),
                try string(steps, "aadUtf8"), name
            )
            XCTAssertEqual(E2EEAutoHistory.signaturePayload(userId: userId, wrap: wrap), try string(steps, "signatureUtf8"), name)

            // Côté émetteur : ECDH de l'éphémère, HKDF, puis scellement à l'octet.
            let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try bytes(steps, "ephemeralPrivateB64"))
            XCTAssertEqual(ephemeral.publicKey.x963Representation.base64EncodedString(), wrap.ephemeralB64, name)
            let recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: try bytes(steps, "recipientAgreementPublicB64"))
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey).withUnsafeBytes { Data($0) }
            XCTAssertEqual(secret, try bytes(steps, "sharedSecretB64"), name)
            let key = E2EEAutoHistory.derivedKey(inputKeyMaterial: secret, saltText: saltText, info: E2EEAutoHistory.historyWrapInfo)
            XCTAssertEqual(key.withUnsafeBytes { Data($0) }, try bytes(steps, "derivedKeyB64"), name)

            let plaintext = try bytes(steps, "plaintextScalarB64")
            if expect["plaintextMatches"] as? Bool != false {
                var signedPayload = ""
                let sealed = try E2EEAutoHistory.seal(
                    scalar: plaintext, userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient,
                    keyVersion: wrap.keyVersion, requestId: wrap.requestId, addHash: wrap.addHash,
                    recipientAgreementKey: recipientKey,
                    sign: { payload in
                        signedPayload = String(decoding: payload, as: UTF8.self)
                        return try XCTUnwrap(Data(base64Encoded: wrap.signatureB64))
                    },
                    ephemeral: ephemeral, nonce: try XCTUnwrap(Data(base64Encoded: wrap.nonceB64))
                )
                XCTAssertEqual(signedPayload, try string(steps, "signatureUtf8"), name)
                XCTAssertEqual(sealed, wrap, name)
            }

            // Côté lecteur : verdict avant tout déchiffrement, sur le journal du cas
            // et, s'il le fixe, pour un autre compte que celui de l'enveloppe.
            var judged = account
            if let variant = testCase["log"] as? String {
                if variants[variant] == nil { variants[variant] = try verifiedAccount(vectors, variant: variant) }
                judged = try XCTUnwrap(variants[variant], name)
            }
            let verdict = E2EEAutoHistory.check(
                userId: testCase["checkUserId"] as? String ?? userId, wrap: wrap, account: judged,
                reader: try reader(try XCTUnwrap(testCase["reader"] as? [String: Any]))
            )
            XCTAssertEqual(verdict?.rawValue ?? "ok", try string(expect, "check"), name)
            guard verdict == nil else { continue }

            // Puis ouverture avec la clé privée d'accord du lecteur.
            let agreementScalar: Data
            if E2EEAutoHistory.isHistoryRecipient(wrap.recipient) {
                agreementScalar = try XCTUnwrap(historyScalars[String(wrap.recipient.dropFirst(E2EEAutoHistory.historyRecipientPrefix.count))], name)
            } else {
                agreementScalar = try bytes(secrets, "a2IdentityKv\(wrap.keyVersion)PrivateB64")
            }
            let agreementKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementScalar)
            XCTAssertEqual(agreementKey.publicKey.x963Representation, recipientKey.x963Representation, name)
            if expect["plaintextMatches"] as? Bool == true {
                XCTAssertEqual(try E2EEAutoHistory.open(wrap, userId: userId, agreementKey: agreementKey), plaintext, name)
            } else {
                XCTAssertFalse(E2EEAutoHistory.plaintextMatches(wrap, scalar: plaintext), name)
                XCTAssertThrowsError(try E2EEAutoHistory.open(wrap, userId: userId, agreementKey: agreementKey), name) {
                    XCTAssertEqual($0 as? E2EEAutoHistory.Failure, .keyMismatch, name)
                }
            }
        }
    }

    func testHistoryWrapRefusedObjects() throws {
        let vectors = try load("history-wrap-v1")
        for invalid in try XCTUnwrap(vectors["invalidObjects"] as? [[String: Any]]) {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoHistory.parseWrap(try XCTUnwrap(invalid["value"] as? [String: Any], name)), name)
        }
    }

    // MARK: Passkey

    func testPasskeyWrap() throws {
        let vectors = try load("passkey-wrap-v1")
        XCTAssertEqual(try string(vectors, "kdfInfo"), E2EEAutoHistory.passkeyWrapInfo)
        let userId = try string(vectors, "userId"), credentialId = try string(vectors, "credentialId")
        let prfOutput = try bytes(vectors, "prfOutputB64"), scalar = try bytes(vectors, "hkScalarB64")

        let saltText = E2EEAutoHistory.passkeySaltText(userId: userId, credentialId: credentialId)
        XCTAssertEqual(saltText, try string(vectors, "saltUtf8"))
        XCTAssertEqual(Data(SHA256.hash(data: Data(saltText.utf8))), try bytes(vectors, "saltB64"))
        let key = E2EEAutoHistory.passkeyKey(prfOutput: prfOutput, userId: userId, credentialId: credentialId)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, try bytes(vectors, "derivedKeyB64"))

        let body = try XCTUnwrap(E2EEAutoHistory.parsePasskeyWrap(try XCTUnwrap(vectors["body"] as? [String: Any])))
        XCTAssertEqual(
            E2EEAutoHistory.passkeyAadText(userId: userId, credentialId: credentialId, hkPubB64: body.hkPubB64),
            try string(vectors, "aadUtf8")
        )
        XCTAssertEqual(try E2EEAutoHistory.openPasskey(body, prfOutput: prfOutput, userId: userId, credentialId: credentialId), scalar)
        XCTAssertEqual(
            try E2EEAutoHistory.sealPasskey(
                scalar: scalar, prfOutput: prfOutput, prfSalt: try XCTUnwrap(Data(base64Encoded: body.prfSaltB64)),
                userId: userId, credentialId: credentialId, nonce: try XCTUnwrap(Data(base64Encoded: body.nonceB64))
            ),
            body
        )
        // Une autre sortie PRF n'ouvre pas l'enveloppe.
        XCTAssertThrowsError(try E2EEAutoHistory.openPasskey(
            body, prfOutput: Data(repeating: 7, count: 32), userId: userId, credentialId: credentialId
        ))

        for invalid in try XCTUnwrap(vectors["invalidBodies"] as? [[String: Any]]) {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoHistory.parsePasskeyWrap(try XCTUnwrap(invalid["value"] as? [String: Any], name)), name)
        }
        for valid in try XCTUnwrap(vectors["validCredentialIds"] as? [String]) {
            XCTAssertTrue(E2EEAutoHistory.isPasskeyCredentialId(valid), valid)
        }
        for invalid in try XCTUnwrap(vectors["invalidCredentialIds"] as? [[String: Any]]) {
            let name = try string(invalid, "name")
            XCTAssertFalse(E2EEAutoHistory.isPasskeyCredentialId(try string(invalid, "value")), name)
        }
    }
}
