import XCTest
@testable import SignalQuest

/// Vecteurs communs du chiffrement automatique (`contracts/e2ee-auto/`, contrat
/// E2EE-AUTO §11, phase 1a) rejoués contre `E2EEAutoLog` et
/// `E2EEAutoHistoryKey` : lecture stricte dans les deux sens, condensats,
/// chaîne de référence complète et chaque refus attendu avec son `seq`.
final class E2EEAutoLogVectorTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func int64(_ object: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap((object[key] as? NSNumber)?.int64Value, key)
    }

    private func objects(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], key)
    }

    /// `{"13": "<entrée>"}` → `[13: "<entrée>"]`.
    private func logKeyEntries(_ object: [String: Any]) throws -> [Int64: String] {
        let raw = try XCTUnwrap(object["logKeyEntries"] as? [String: String])
        return try Dictionary(uniqueKeysWithValues: raw.map { (try XCTUnwrap(Int64($0.key)), $0.value) })
    }

    private func linksBySeq(_ texts: [String]) throws -> [Int64: String] {
        try Dictionary(uniqueKeysWithValues: texts.map { (try XCTUnwrap(E2EEAutoLog.parseLink($0)).seq, $0) })
    }

    // MARK: Entrées

    func testEntriesParseCanonicallyAndHash() throws {
        let vectors = try load("log-entry-v2")
        for valid in try objects(vectors, "valid") {
            let text = try string(valid, "text")
            let parsed = try XCTUnwrap(E2EEAutoLog.parseEntry(text), text)
            XCTAssertEqual(parsed.entry.canonical, text)
            XCTAssertEqual(parsed.entry.seq, try int64(valid, "seq"))
            XCTAssertEqual(parsed.entry.op.rawValue, try string(valid, "op"))
            XCTAssertEqual(E2EEAutoLog.digest(text), try string(valid, "entryHash"))
        }
        for invalid in try objects(vectors, "invalid") {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoLog.parseEntry(try string(invalid, "text")), name)
        }
    }

    /// Le format admet une signature à S haut ; la vérification la refuse (§2.3).
    func testHighSRotateSignatureIsRefused() throws {
        let vectors = try load("log-entry-v2"), chain = try load("log-chain-v2")
        let publicKeys = try XCTUnwrap(chain["publicKeys"] as? [String: String])
        let text = try string(try XCTUnwrap(vectors["highSSignatureDetail"] as? [String: Any]), "text")
        let (entry, detail) = try XCTUnwrap(E2EEAutoLog.parseEntry(text))
        guard case let .rotate(signatureB64) = detail else { return XCTFail("ROTATE attendu") }
        let payload = E2EEAutoLog.Payload.rotate(
            userId: entry.userId, prevUserEntryHash: entry.prevUserEntryHash, deviceId: entry.deviceId,
            newIdentityKeyB64: entry.identityKeyB64, keyVersion: try XCTUnwrap(Int(entry.keyVersion))
        )
        XCTAssertFalse(E2EEAutoLog.verify(publicKeyB64: try XCTUnwrap(publicKeys["a1Signing"]), payload: payload, signatureB64: signatureB64))
    }

    // MARK: Maillons et comptes

    func testLinksAccountsAndGenesis() throws {
        let vectors = try load("log-link-v1")
        XCTAssertEqual(E2EEAutoLog.genesisHash, try string(vectors, "genesisHash"))
        XCTAssertEqual(E2EEAutoLog.digest(try string(vectors, "genesisCanonicalUtf8")), E2EEAutoLog.genesisHash)
        for account in try objects(vectors, "accounts") {
            let userId = try string(account, "userId"), salt = try string(account, "accountSaltB64")
            XCTAssertTrue(E2EEAutoLog.isAccountSalt(salt))
            XCTAssertEqual(E2EEAutoLog.accountId(userId: userId), try string(account, "accountId"))
            XCTAssertEqual(E2EEAutoLog.digest(try string(account, "accountIdCanonicalUtf8")), try string(account, "accountId"))
            XCTAssertEqual(E2EEAutoLog.saltCommitment(accountSaltB64: salt), try string(account, "saltCommitment"))
            XCTAssertEqual(E2EEAutoLog.digest(try string(account, "saltCommitmentCanonicalUtf8")), try string(account, "saltCommitment"))
            XCTAssertEqual(E2EEAutoLog.accountTag(userId: userId, accountSaltB64: salt), try string(account, "accountTag"))
            XCTAssertEqual(E2EEAutoLog.digest(try string(account, "accountTagCanonicalUtf8")), try string(account, "accountTag"))
        }
        for link in try objects(vectors, "links") {
            let text = try string(link, "text")
            let parsed = try XCTUnwrap(E2EEAutoLog.parseLink(text), text)
            XCTAssertEqual(parsed.canonical, text)
            XCTAssertEqual(parsed.seq, try int64(link, "seq"))
            XCTAssertEqual(E2EEAutoLog.digest(text), try string(link, "linkHash"))
        }
        for invalid in try objects(vectors, "invalid") {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoLog.parseLink(try string(invalid, "text")), name)
        }
    }

    // MARK: Tête

    func testHeadSignatureKeyIdsAndAge() throws {
        let vectors = try load("log-head-v2")
        let pinned = try string(vectors, "pinnedLogKeyB64"), next = try string(vectors, "nextLogKeyB64")
        let ids = try XCTUnwrap(vectors["logKeyIds"] as? [String: String])
        XCTAssertEqual(E2EEAutoLog.logKeyId(pinned), ids["logKey1"])
        XCTAssertEqual(E2EEAutoLog.logKeyId(next), ids["logKey2"])

        let head = try XCTUnwrap(vectors["head"] as? [String: Any])
        let text = try string(head, "text"), signature = try string(head, "signatureB64")
        for check in try objects(vectors, "checks") {
            let result = E2EEAutoLog.checkHead(text: text, signatureB64: signature, logKeyB64: next, nowMs: try int64(check, "nowMs"))
            switch (result, try string(check, "expect")) {
            case (.ok, "ok"), (.stale, "stale"): break
            default: XCTFail("\(try string(check, "name")) : \(result)")
            }
        }
        for invalid in try objects(vectors, "invalid") {
            let result = E2EEAutoLog.checkHead(
                text: text, signatureB64: try string(invalid, "signatureB64"), logKeyB64: try string(invalid, "logKeyB64"),
                nowMs: try int64(try load("log-chain-v2")["reference"] as? [String: Any] ?? [:], "headNowMs")
            )
            let name = try string(invalid, "name")
            XCTAssertEqual(result, .invalid(try XCTUnwrap(E2EEAutoLog.HeadError(rawValue: try string(invalid, "expect")))), name)
        }

        // La pulsation re-signe le même seq et le même condensat une heure plus tard.
        let heartbeat = try XCTUnwrap(vectors["heartbeat"] as? [String: Any])
        let original = try XCTUnwrap(E2EEAutoLog.parseHead(text))
        let beat = try XCTUnwrap(E2EEAutoLog.parseHead(try string(heartbeat, "text")))
        XCTAssertEqual(beat.seq, original.seq)
        XCTAssertEqual(beat.linkHash, original.linkHash)
        XCTAssertEqual(
            E2EEAutoLog.checkHead(text: try string(heartbeat, "text"), signatureB64: try string(heartbeat, "signatureB64"), logKeyB64: next, nowMs: beat.createdAtMs),
            .ok(beat)
        )
    }

    // MARK: Chaîne de référence

    func testReferenceChainAndAccounts() throws {
        let vectors = try load("log-chain-v2")
        let reference = try XCTUnwrap(vectors["reference"] as? [String: Any])
        let links = try XCTUnwrap(reference["links"] as? [String])
        let chain = try E2EEAutoLog.extendChain(
            .initial(pinnedLogKeyB64: try string(vectors, "pinnedLogKeyB64")), links: links, logKeyEntries: logKeyEntries(reference)
        ).get()
        XCTAssertEqual(chain.seq, Int64(links.count))
        XCTAssertNotEqual(chain.logKeyB64, try string(vectors, "pinnedLogKeyB64"), "LOG_KEY appliquée")

        let head = try XCTUnwrap(reference["head"] as? [String: Any])
        let check = E2EEAutoLog.checkHead(
            text: try string(head, "text"), signatureB64: try string(head, "signatureB64"), logKeyB64: chain.logKeyB64,
            nowMs: try int64(reference, "headNowMs")
        )
        guard case let .ok(verifiedHead) = check else { return XCTFail("tête : \(check)") }
        XCTAssertEqual(E2EEAutoLog.compare(head: verifiedHead, to: chain), .match)

        let bySeq = try linksBySeq(links)
        for account in try objects(reference, "accounts") {
            let userId = try string(account, "userId")
            let state = try E2EEAutoLog.verifyAccount(
                userId: userId, accountSaltB64: try string(account, "accountSaltB64"),
                entries: try XCTUnwrap(account["entries"] as? [String]), links: bySeq, chain: chain
            ).get()
            let expect = try XCTUnwrap(account["expect"] as? [String: Any])
            XCTAssertEqual(state.lastSeq, try int64(expect, "lastSeq"), userId)
            XCTAssertEqual(state.historyKeyPubB64, expect["historyKeyPubB64"] as? String, userId)
            XCTAssertEqual(state.mode.rawValue, try string(expect, "mode"), userId)
            let devices = try XCTUnwrap(expect["devices"] as? [String: [String: Any]])
            XCTAssertEqual(Set(state.devices.keys), Set(devices.keys), userId)
            for (deviceId, expected) in devices {
                let device = try XCTUnwrap(state.devices[deviceId])
                XCTAssertEqual(device.status.rawValue, try string(expected, "status"), deviceId)
                if let keyVersion = expected["keyVersion"] as? Int { XCTAssertEqual(device.keyVersion, keyVersion, deviceId) }
                if let identityKey = expected["identityKeyB64"] as? String { XCTAssertEqual(device.identityKeyB64, identityKey, deviceId) }
                if let reason = expected["revokeReason"] as? String { XCTAssertEqual(device.revokeReason?.rawValue, reason, deviceId) }
                if expected["revokeSeq"] != nil { XCTAssertEqual(device.revokeSeq, try int64(expected, "revokeSeq"), deviceId) }
            }
            XCTAssertTrue(state.activeDevices.allSatisfy { $0.status == .active })
        }
    }

    /// Un état gardé que la tête contredit : même `seq` et autre condensat, ou `seq` plus petit.
    func testKeptStateAgainstHead() throws {
        let vectors = try load("log-chain-v2")
        // L'état gardé peut franchir la LOG_KEY de la référence : son entrée vient avec.
        let entries = try logKeyEntries(try XCTUnwrap(vectors["reference"] as? [String: Any]))
        for kept in try objects(vectors, "keptStateCases") {
            let state = try E2EEAutoLog.extendChain(
                .initial(pinnedLogKeyB64: try string(vectors, "pinnedLogKeyB64")),
                links: try XCTUnwrap(kept["keptLinks"] as? [String]), logKeyEntries: entries
            ).get()
            let head = E2EEAutoLog.Head(seq: try int64(kept, "headSeq"), linkHash: try string(kept, "headLinkHash"), logKeyId: "", createdAtMs: 0)
            let expected = try XCTUnwrap(E2EEAutoLog.ChainError(rawValue: try string(kept, "expect")))
            let name = try string(kept, "name")
            XCTAssertEqual(E2EEAutoLog.compare(head: head, to: state), .failure(expected), name)
        }
    }

    func testChainAndAccountRefusals() throws {
        let vectors = try load("log-chain-v2")
        let pinned = try string(vectors, "pinnedLogKeyB64")
        for testCase in try objects(vectors, "cases") {
            let name = try string(testCase, "name")
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any])
            let links = try XCTUnwrap(testCase["links"] as? [String])
            let extended = E2EEAutoLog.extendChain(.initial(pinnedLogKeyB64: pinned), links: links, logKeyEntries: try logKeyEntries(testCase))

            if let chainError = expect["chainError"] as? String {
                XCTAssertEqual(
                    extended,
                    .failure(E2EEAutoLog.ChainFailure(error: try XCTUnwrap(E2EEAutoLog.ChainError(rawValue: chainError)), seq: try int64(expect, "seq"))),
                    name
                )
                continue
            }
            let chain = try extended.get()
            let account = try XCTUnwrap(testCase["account"] as? [String: Any], name)
            let result = E2EEAutoLog.verifyAccount(
                userId: try string(account, "userId"), accountSaltB64: try string(account, "accountSaltB64"),
                entries: try XCTUnwrap(account["entries"] as? [String]), links: try linksBySeq(links), chain: chain
            )
            let accountError = try XCTUnwrap(E2EEAutoLog.AccountError(rawValue: try string(expect, "accountError")), name)
            XCTAssertEqual(result.failure, E2EEAutoLog.AccountFailure(error: accountError, seq: try int64(expect, "seq")), name)
        }
    }

    // MARK: Clé d'historique

    func testHistoryKeyScalars() throws {
        let vectors = try load("history-key-v1")
        for pair in try objects(vectors, "pairs") {
            let scalar = try XCTUnwrap(Data(base64Encoded: try string(pair, "scalarB64")))
            let name = try string(pair, "name")
            XCTAssertTrue(E2EEAutoHistoryKey.isValidScalar(scalar), name)
            XCTAssertEqual(E2EEAutoHistoryKey.publicKeyB64(scalar: scalar), try string(pair, "hkPubB64"), name)
        }
        for invalid in try objects(vectors, "invalidScalars") {
            let scalar = try XCTUnwrap(Data(base64Encoded: try string(invalid, "scalarB64")))
            let name = try string(invalid, "name")
            XCTAssertFalse(E2EEAutoHistoryKey.isValidScalar(scalar), name)
            XCTAssertNil(E2EEAutoHistoryKey.publicKeyB64(scalar: scalar), name)
        }
    }

    func testHistoryKeyProofs() throws {
        let vectors = try load("hk-proof-v1")
        func verify(_ proof: [String: Any]) throws -> Bool {
            E2EEAutoHistoryKey.verifyProof(
                userId: try string(proof, "userId"), deviceId: try string(proof, "deviceId"), hkPubB64: try string(proof, "hkPubB64"),
                revokeSeq: try int64(proof, "revokeSeq"), signatureB64: try string(proof, "signatureB64")
            )
        }
        let proof = try XCTUnwrap(vectors["proof"] as? [String: Any])
        XCTAssertEqual(
            E2EEAutoHistoryKey.proofPayload(
                userId: try string(proof, "userId"), deviceId: try string(proof, "deviceId"),
                hkPubB64: try string(proof, "hkPubB64"), revokeSeq: try int64(proof, "revokeSeq")
            ),
            try string(proof, "payloadUtf8")
        )
        XCTAssertTrue(try verify(proof))
        for invalid in try objects(vectors, "invalid") {
            let name = try string(invalid, "name")
            XCTAssertFalse(try verify(invalid), name)
        }
        // Signature valide : c'est le journal (appareil révoqué) qui la refuse, pas la preuve.
        XCTAssertTrue(try verify(try XCTUnwrap(vectors["revokedDeviceProof"] as? [String: Any])))

        // Aller-retour, et refus d'un scalaire qui ne correspond pas à la clé annoncée.
        let pairs = try objects(try load("history-key-v1"), "pairs")
        XCTAssertGreaterThanOrEqual(pairs.count, 2)
        let scalar = try XCTUnwrap(Data(base64Encoded: try string(pairs[0], "scalarB64")))
        let other = try XCTUnwrap(Data(base64Encoded: try string(pairs[1], "scalarB64")))
        let hkPub = try string(pairs[0], "hkPubB64")
        let userId = try string(proof, "userId"), deviceId = try string(proof, "deviceId")
        let signature = try XCTUnwrap(E2EEAutoHistoryKey.signProof(userId: userId, deviceId: deviceId, hkPubB64: hkPub, revokeSeq: 7, scalar: scalar))
        XCTAssertTrue(E2EEAutoHistoryKey.verifyProof(userId: userId, deviceId: deviceId, hkPubB64: hkPub, revokeSeq: 7, signatureB64: signature))
        XCTAssertFalse(E2EEAutoHistoryKey.verifyProof(userId: userId, deviceId: deviceId, hkPubB64: hkPub, revokeSeq: 8, signatureB64: signature))
        XCTAssertNil(E2EEAutoHistoryKey.signProof(userId: userId, deviceId: deviceId, hkPubB64: hkPub, revokeSeq: 7, scalar: other))
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
