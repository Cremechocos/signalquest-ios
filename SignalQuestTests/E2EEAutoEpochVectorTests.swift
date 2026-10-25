import XCTest
@testable import SignalQuest

/// Vecteurs `epoch-recipients-v1` et `safety-code-v1` (contrat E2EE-AUTO v2,
/// §7 et §7.1, phase 1c) rejoués contre `E2EEAutoEpoch` et `E2EEAutoSafetyCode`,
/// sur le journal vérifié du vecteur, y compris un lecteur en retard (`logSeq`).
/// Les cas `submissions` décrivent le contrôle du serveur, que l'app ne porte pas.
final class E2EEAutoEpochVectorTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    /// Journaux vérifiés de chaque compte, tels qu'un lecteur les tient à la tête `atSeq`
    /// (`nil` : tout le journal).
    private func accounts(_ vectors: [String: Any], atSeq: Int64? = nil) throws -> [String: E2EEAutoLog.AccountState] {
        let log = try XCTUnwrap(vectors["log"] as? [String: Any])
        let allLinks = try XCTUnwrap(log["links"] as? [String])
        let limit = atSeq ?? Int64(allLinks.count)
        let links = Array(allLinks.prefix(Int(limit)))
        let logKeyEntries = try XCTUnwrap(log["logKeyEntries"] as? [String: String])
            .reduce(into: [Int64: String]()) { result, item in
                if let seq = Int64(item.key), seq <= limit { result[seq] = item.value }
            }
        let chain = try E2EEAutoLog.extendChain(
            .initial(
                pinnedLogKeyB64: try string(log, "pinnedLogKeyB64"),
                nextLogKeysB64: try XCTUnwrap(log["pinnedNextLogKeysB64"] as? [String])
            ),
            links: links, logKeyEntries: logKeyEntries
        ).get()
        let bySeq = try Dictionary(uniqueKeysWithValues: links.map { (try XCTUnwrap(E2EEAutoLog.parseLink($0)).seq, $0) })
        var result: [String: E2EEAutoLog.AccountState] = [:]
        for account in try XCTUnwrap(log["accounts"] as? [[String: Any]]) {
            let userId = try string(account, "userId")
            let entries = try XCTUnwrap(account["entries"] as? [String])
                .filter { (E2EEAutoLog.parseEntry($0)?.entry.seq ?? .max) <= limit }
            result[userId] = try E2EEAutoLog.verifyAccount(
                userId: userId, accountSaltB64: try string(account, "accountSaltB64"),
                entries: entries, links: bySeq, chain: chain
            ).get()
        }
        return result
    }

    private func recipients(_ object: [String: Any]) throws -> [E2EEAutoEpoch.Recipient] {
        try XCTUnwrap(object["recipients"] as? [String]).map { try XCTUnwrap(E2EEAutoEpoch.Recipient.parse($0), $0) }
    }

    func testToleranceMatchesContract() throws {
        XCTAssertEqual((try load("epoch-recipients-v1")["toleranceMs"] as? NSNumber)?.int64Value, E2EEAutoEpoch.manifestToleranceMs)
    }

    func testCompose() throws {
        let vectors = try load("epoch-recipients-v1")
        let accounts = try accounts(vectors)
        for testCase in try XCTUnwrap(vectors["compose"] as? [[String: Any]]) {
            let name = try string(testCase, "name")
            let excluded = try XCTUnwrap(testCase["excluded"] as? [[String: String]]).map {
                E2EEAutoEpoch.DeviceRef(userId: try XCTUnwrap($0["userId"]), deviceId: try XCTUnwrap($0["deviceId"]))
            }
            let composed = try XCTUnwrap(E2EEAutoEpoch.compose(
                memberUserIds: try XCTUnwrap(testCase["memberUserIds"] as? [String]), accounts: accounts, excluded: Set(excluded)
            ), name)
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], name)
            XCTAssertEqual(composed.memberLogSeqs, try XCTUnwrap(expect["memberLogSeqs"] as? [String: String]), name)
            XCTAssertEqual(composed.recipients.map(\.line), try XCTUnwrap(expect["recipients"] as? [String]), name)
        }
        XCTAssertNil(E2EEAutoEpoch.compose(memberUserIds: ["user_eve_0000000000005"], accounts: accounts), "membre sans journal")
    }

    func testManifests() throws {
        let vectors = try load("epoch-recipients-v1")
        var accountsBySeq: [Int64: [String: E2EEAutoLog.AccountState]] = [:]
        let manifests = try XCTUnwrap(vectors["manifests"] as? [[String: Any]])
        XCTAssertEqual(manifests.count, 45)
        for testCase in manifests {
            let name = try string(testCase, "name")
            let logSeq = try XCTUnwrap((testCase["logSeq"] as? NSNumber)?.int64Value, name)
            if accountsBySeq[logSeq] == nil { accountsBySeq[logSeq] = try accounts(vectors, atSeq: logSeq) }
            let result = E2EEAutoEpoch.checkManifest(
                createdAtMs: try XCTUnwrap((testCase["manifestCreatedAtMs"] as? NSNumber)?.int64Value, name),
                excludesWeb: try XCTUnwrap(testCase["excludesWeb"] as? Bool, name),
                memberUserIds: try XCTUnwrap(testCase["memberUserIds"] as? [String], name),
                recipients: try recipients(testCase),
                accounts: try XCTUnwrap(accountsBySeq[logSeq]),
                correctedNowMs: try XCTUnwrap((testCase["correctedNowMs"] as? NSNumber)?.int64Value, name),
                ownManifest: try XCTUnwrap(testCase["ownManifest"] as? Bool, name),
                refreshed: try XCTUnwrap(testCase["refreshed"] as? Bool, name)
            )
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], name)
            let expected: E2EEAutoEpoch.ManifestCheck
            if expect["adoptable"] as? Bool == true {
                expected = .adoptable
            } else if expect["alert"] as? Bool == true {
                // Le vecteur fixe la raison et l'appareil ; un deviceId peut exister sous deux comptes.
                let reason = try XCTUnwrap(E2EEAutoEpoch.RecipientError(rawValue: try string(expect, "reason")), name)
                guard case let .alert(gotReason, gotUserId, gotDeviceId) = result else {
                    XCTFail("\(name) : alerte attendue, \(result)")
                    continue
                }
                XCTAssertEqual(gotReason, reason, name)
                XCTAssertEqual(gotDeviceId, try string(expect, "deviceId"), name)
                if let userId = expect["userId"] as? String { XCTAssertEqual(gotUserId, userId, name) }
                continue
            } else {
                switch try string(expect, "reason") {
                case "LOG_BEHIND": expected = .logBehind(userIds: try XCTUnwrap(expect["userIds"] as? [String], name))
                case "FUTURE": expected = .future
                case "EXCLUDES_WEB": expected = .excludesWeb
                default: return XCTFail("\(name) : raison inconnue")
                }
            }
            XCTAssertEqual(result, expected, name)
        }
    }

    func testSendable() throws {
        let vectors = try load("epoch-recipients-v1")
        let accounts = try accounts(vectors)
        for testCase in try XCTUnwrap(vectors["sendable"] as? [[String: Any]]) {
            let name = try string(testCase, "name")
            XCTAssertEqual(E2EEAutoEpoch.isSendable(try recipients(testCase), accounts: accounts), testCase["expect"] as? Bool, name)
        }
    }

    // MARK: Code de sécurité

    func testSafetyCode() throws {
        let vectors = try load("safety-code-v1")
        let accounts = try accounts(try load("epoch-recipients-v1"))
        for expected in try XCTUnwrap(vectors["accounts"] as? [[String: Any]]) {
            let userId = try string(expected, "userId")
            let account = try XCTUnwrap(accounts[userId], userId)
            for device in try XCTUnwrap(expected["activeDevices"] as? [[String: Any]]) {
                let deviceId = try string(device, "deviceId"), signingKey = try string(device, "signingKeyB64")
                XCTAssertEqual(account.devices[deviceId]?.signingKeyB64, signingKey, deviceId)
                XCTAssertEqual(account.devices[deviceId]?.status, .active, deviceId)
                XCTAssertEqual(
                    E2EEAutoSafetyCode.deviceFingerprintText(userId: userId, deviceId: deviceId, signingKeyB64: signingKey),
                    try string(device, "fingerprintUtf8"), deviceId
                )
                let fingerprint = E2EEAutoSafetyCode.deviceFingerprint(userId: userId, deviceId: deviceId, signingKeyB64: signingKey)
                XCTAssertEqual(fingerprint, try string(device, "fingerprint"), deviceId)
                XCTAssertEqual(E2EEAutoSafetyCode.shortFingerprint(fingerprint), device["shortFingerprint"] as? [String], deviceId)
            }
            for ignored in try XCTUnwrap(expected["ignoredDevices"] as? [[String: Any]]) {
                let deviceId = try string(ignored, "deviceId")
                XCTAssertEqual(account.devices[deviceId]?.status.rawValue, try string(ignored, "status"), deviceId)
            }
            XCTAssertEqual(E2EEAutoSafetyCode.accountText(account), try string(expected, "accountUtf8"), userId)
            XCTAssertEqual(E2EEAutoSafetyCode.accountDigits(account), try string(expected, "accountDigits"), userId)
        }

        for key in ["pair", "pairWithEmptyAccount", "pairByteOrder"] {
            let pair = try XCTUnwrap(vectors[key] as? [String: Any])
            let userIds = try XCTUnwrap(pair["userIds"] as? [String])
            let left = try XCTUnwrap(accounts[userIds[0]]), right = try XCTUnwrap(accounts[userIds[1]])
            let expected = E2EEAutoSafetyCode.Code(
                digits: try string(pair, "digits"), groups: try XCTUnwrap(pair["groups"] as? [String]), qr: try string(pair, "qr")
            )
            // Le même code des deux côtés.
            XCTAssertEqual(E2EEAutoSafetyCode.code(left, right), expected, key)
            XCTAssertEqual(E2EEAutoSafetyCode.code(right, left), expected, key)
            XCTAssertEqual(E2EEAutoSafetyCode.parseQR(expected.qr), expected.digits, key)
            XCTAssertNil(E2EEAutoSafetyCode.code(left, left), key)
        }
        for invalid in try XCTUnwrap(vectors["invalidQr"] as? [[String: Any]]) {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoSafetyCode.parseQR(try string(invalid, "value")), name)
        }
        for invalid in try XCTUnwrap(vectors["invalidShortFingerprintInputs"] as? [[String: Any]]) {
            let name = try string(invalid, "name")
            XCTAssertNil(E2EEAutoSafetyCode.shortFingerprint(try string(invalid, "value")), name)
        }
    }
}
