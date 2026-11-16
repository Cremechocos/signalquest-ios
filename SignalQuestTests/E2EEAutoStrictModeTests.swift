import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 8a (E2EE-AUTO §5.5, §6) : règles du mode renforcé, activation signée
/// pour le `fulfil`, et ce que l'app propose pour la passkey.
final class E2EEAutoStrictModeTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private static let day = E2EEAutoLog.signerMinAgeMs
    private let signing = P256.Signing.PrivateKey()
    private let ownId = "ios_device_own_000000000"
    private let otherId = "android_device_other_0000"
    private let pendingId = "ios_device_pending_00000"

    private func state(
        _ deviceId: String, platform: E2EEAutoLog.Platform = .ios, signingKeyB64: String? = nil,
        status: E2EEAutoLog.DeviceStatus = .active, addedAtMs: Int64 = 1
    ) -> E2EEAutoLog.DeviceState {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        return E2EEAutoLog.DeviceState(
            deviceId: deviceId, platform: platform, identityKeyB64: key,
            signingKeyB64: signingKeyB64 ?? P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            keyVersion: 1, status: status, addedAtMs: addedAtMs, activatedAtMs: status == .pending ? nil : addedAtMs,
            addEntryHash: E2EEAutoLog.digest("add-\(deviceId)"),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: addedAtMs)],
            revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
        )
    }

    private func account(_ devices: [E2EEAutoLog.DeviceState], mode: E2EEAutoLog.Mode = .normal, hk: String? = nil) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        for device in devices { account.devices[device.deviceId] = device }
        account.lastEntryHash = E2EEAutoLog.digest("last")
        account.mode = mode
        account.historyKeyPubB64 = hk
        return account
    }

    private var own: E2EEAutoLog.DeviceState {
        state(ownId, signingKeyB64: signing.publicKey.x963Representation.base64EncodedString())
    }

    /// Ce que le serveur écrirait : l'entrée, son maillon et une tête.
    private func written(op: E2EEAutoLog.Op, device: E2EEAutoLog.DeviceState?, detail: String, prev: String) -> [String: Any] {
        let none = E2EEAutoLog.none
        let entry = E2EEAutoLog.Entry(
            seq: 30, userId: Self.userId, prevUserEntryHash: prev, op: op, deviceId: device?.deviceId ?? none,
            platform: device?.platform.rawValue ?? none, identityKeyB64: device?.identityKeyB64 ?? none,
            signingKeyB64: device?.signingKeyB64 ?? none, keyVersion: device.map { String($0.keyVersion) } ?? none,
            detail: detail, createdAtMs: 9
        ).canonical
        let link = ["SQ-E2EE-AUTO-LOG-LINK", "1", "30", E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
                    E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
        return ["entry": entry, "link": link, "head": ["text": "t", "signatureB64": "s"]]
    }

    // MARK: Mode renforcé

    /// Temps 1 du §6 : seule la sortie reste, aux règles du lecteur, sans condition de deux appareils.
    func testLeavingStrictFollowsTheReaderRules() {
        let now = 10 * Self.day
        XCTAssertNil(E2EEAutoStrictMode.refusal(account: account([own], mode: .strict), deviceId: ownId, nowMs: now))
        XCTAssertEqual(E2EEAutoStrictMode.refusal(account: account([own, state(otherId)]), deviceId: ownId, nowMs: now), .unchanged)
        XCTAssertEqual(
            E2EEAutoStrictMode.refusal(
                account: account([own, state(otherId), state(pendingId, status: .pending)], mode: .strict), deviceId: pendingId, nowMs: now
            ),
            .notActive
        )
        // Ancienneté depuis l'`ADD` : 24 h pile suffisent.
        let young = account([state(ownId, addedAtMs: 5), state(otherId)], mode: .strict)
        XCTAssertEqual(E2EEAutoStrictMode.refusal(account: young, deviceId: ownId, nowMs: 4 + Self.day), .tooRecent(eligibleAtMs: 5 + Self.day))
        XCTAssertNil(E2EEAutoStrictMode.refusal(account: young, deviceId: ownId, nowMs: 5 + Self.day))
    }

    func testModeResponseMustBeThisModeSignedHere() throws {
        let prev = E2EEAutoLog.digest("last")
        func response(mode: E2EEAutoLog.Mode, signer: String? = nil, key: P256.Signing.PrivateKey? = nil, prev entryPrev: String? = nil) throws -> Data {
            let signer = signer ?? ownId
            let text = E2EEAutoStrictMode.payload(userId: Self.userId, prevUserEntryHash: entryPrev ?? prev, signerDeviceId: signer, mode: mode)
            let signature = try E2EEV2LowS.sign(Data(text.utf8), with: key ?? signing).base64EncodedString()
            return try JSONSerialization.data(withJSONObject: written(
                op: .mode, device: nil, detail: "\(signer):\(mode.rawValue):\(signature)", prev: entryPrev ?? prev
            ))
        }
        func parse(_ data: Data, mode: E2EEAutoLog.Mode = .strict) -> Bool {
            E2EEAutoStrictMode.parse(
                data, userId: Self.userId, prevUserEntryHash: prev, signerDeviceId: ownId, mode: mode,
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString()
            )
        }
        XCTAssertEqual(
            E2EEAutoStrictMode.payload(userId: "u", prevUserEntryHash: "p", signerDeviceId: "d", mode: .strict),
            "SQ-E2EE-AUTO-MODE\n1\nu\np\nd\nSTRICT"
        )
        XCTAssertTrue(parse(try response(mode: .strict)))
        XCTAssertFalse(parse(try response(mode: .normal)), "autre mode")
        XCTAssertFalse(parse(try response(mode: .strict, signer: otherId)), "autre signataire")
        XCTAssertFalse(parse(try response(mode: .strict, key: P256.Signing.PrivateKey())), "autre clé")
        XCTAssertFalse(parse(try response(mode: .strict, prev: E2EEAutoLog.digest("old"))), "autre état")
    }

    // MARK: Activation (« C'est moi » en mode renforcé)

    func testOnlyAnOldEnoughActiveDeviceActivatesAPendingOne() {
        let now = 10 * Self.day
        let accountState = account([own, state(pendingId, status: .pending, addedAtMs: now - 5), state(otherId, addedAtMs: now - 5)])
        XCTAssertNil(E2EEAutoActivationContract.refusal(account: accountState, approverDeviceId: ownId, deviceId: pendingId, nowMs: now))
        XCTAssertEqual(
            E2EEAutoActivationContract.refusal(account: accountState, approverDeviceId: otherId, deviceId: pendingId, nowMs: now),
            .approverTooRecent(eligibleAtMs: now - 5 + Self.day)
        )
        XCTAssertEqual(
            E2EEAutoActivationContract.refusal(account: accountState, approverDeviceId: pendingId, deviceId: pendingId, nowMs: now),
            .approverNotActive
        )
        XCTAssertEqual(
            E2EEAutoActivationContract.refusal(account: accountState, approverDeviceId: ownId, deviceId: otherId, nowMs: now),
            .notPending
        )
    }

    /// L'objet signé ici, écrit par le serveur, se relit comme l'`ACTIVATE` de
    /// cet appareil en attente ; une clé recopiée autrement est refusée.
    func testActivationIsSignedOnTheLastEntryAndReadBack() throws {
        let pending = state(pendingId, status: .pending)
        let accountState = account([own, pending])
        let activation = try XCTUnwrap(E2EEAutoActivationContract.activation(
            account: accountState, approverDeviceId: ownId, deviceId: pendingId, sign: { try E2EEV2LowS.sign($0, with: self.signing) }
        ))
        XCTAssertEqual(Set(activation.keys), ["prevUserEntryHash", "signatureB64"])
        let prev = try XCTUnwrap(accountState.lastEntryHash)
        XCTAssertEqual(activation["prevUserEntryHash"], prev)
        let signature = try XCTUnwrap(activation["signatureB64"])

        let response = written(op: .activate, device: pending, detail: "\(ownId):\(signature)", prev: prev)
        XCTAssertTrue(E2EEAutoActivationContract.parseWritten(
            response, account: accountState, prevUserEntryHash: prev, approverDeviceId: ownId, deviceId: pendingId
        ))
        XCTAssertFalse(E2EEAutoActivationContract.parseWritten(
            response, account: accountState, prevUserEntryHash: E2EEAutoLog.digest("old"), approverDeviceId: ownId, deviceId: pendingId
        ), "autre état")
        // Une clé changée par le serveur ne passe pas, même avec la signature d'origine.
        var swapped = pending
        swapped.identityKeyB64 = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        XCTAssertFalse(E2EEAutoActivationContract.parseWritten(
            written(op: .activate, device: swapped, detail: "\(ownId):\(signature)", prev: prev),
            account: accountState, prevUserEntryHash: prev, approverDeviceId: ownId, deviceId: pendingId
        ), "clé recopiée autrement")
        XCTAssertNil(try E2EEAutoActivationContract.activation(
            account: accountState, approverDeviceId: ownId, deviceId: ownId, sign: { try E2EEV2LowS.sign($0, with: self.signing) }
        ), "cible déjà active")
    }

    // MARK: Passkey

    private func wrapObject(credentialId: String, hk: String, current: Any = true, extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "credentialId": credentialId, "prfSaltB64": Data(repeating: 1, count: 32).base64EncodedString(),
            "nonceB64": Data(repeating: 2, count: 12).base64EncodedString(),
            "wrappedB64": Data(repeating: 3, count: 48).base64EncodedString(), "hkPubB64": hk,
            "current": current, "updatedAtMs": "1793000000000"
        ]
        object.merge(extra) { $1 }
        return object
    }

    func testPasskeyListIsReadStrictly() throws {
        let hk = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        func parse(_ wraps: [[String: Any]]) throws -> [E2EEAutoPasskeyContract.Listed]? {
            E2EEAutoPasskeyContract.parseList(try JSONSerialization.data(withJSONObject: ["wraps": wraps]))
        }
        let listed = try XCTUnwrap(try parse([wrapObject(credentialId: "AQID", hk: hk)]))
        XCTAssertEqual(listed.first?.credentialId, "AQID")
        XCTAssertEqual(listed.first?.updatedAtMs, 1_793_000_000_000)
        XCTAssertEqual(try parse([]), [])
        XCTAssertNil(try parse([wrapObject(credentialId: "AQID", hk: hk, current: 1)]), "current non booléen")
        XCTAssertNil(try parse([wrapObject(credentialId: "AQID", hk: hk, extra: ["label": "x"])]), "champ de trop")
        XCTAssertNil(try parse([wrapObject(credentialId: "AQ==", hk: hk)]), "credentialId avec bourrage")
        XCTAssertNil(try parse([wrapObject(credentialId: "AQID", hk: hk, extra: ["updatedAtMs": 1])]), "updatedAtMs non décimal")
        XCTAssertEqual(E2EEAutoPasskeyContract.path(credentialId: "AQID"), "/api/e2ee/auto/history-key/passkey-wraps/AQID")
        XCTAssertNil(E2EEAutoPasskeyContract.path(credentialId: "a/b"))
    }

    /// §5.5 révision 22 : passkey par défaut, sans condition d'appareil non Apple, selon « Quand créer » ;
    /// mise à jour d'une passkey périmée par un appareil inscrit depuis 24 h (H1).
    func testPasskeyIsOfferedByDefaultAndUpdatedWhenStale() throws {
        let hk = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let old = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let now = 10 * Self.day
        func offer(
            _ devices: [E2EEAutoLog.DeviceState], listed: [[String: Any]] = [], holds: Bool = true, prf: Bool = true,
            wanted: Bool = false, nowMs: Int64? = nil
        ) throws -> E2EEAutoPasskeyContract.Offer {
            let parsed = try XCTUnwrap(E2EEAutoPasskeyContract.parseList(JSONSerialization.data(withJSONObject: ["wraps": listed])))
            return E2EEAutoPasskeyContract.offer(
                account: account(devices, hk: hk), deviceId: ownId, holdsLatestHistoryKey: holds, prfAvailable: prf,
                listed: parsed, localPasskeyWanted: wanted, nowMs: nowMs ?? now
            )
        }
        let apple = state("ios_device_other_000000")
        XCTAssertEqual(try offer([own]), .create, "seul appareil, sans passkey : proposée")
        XCTAssertEqual(try offer([own, apple]), .create, "plus de condition d'appareil non Apple")
        XCTAssertEqual(try offer([own], holds: false), .none)
        XCTAssertEqual(try offer([own], prf: false), .none, "iOS 16 et 17 : « C'est moi » seul")
        XCTAssertEqual(try offer([state(ownId, status: .pending)]), .none)
        let current = wrapObject(credentialId: "AQID", hk: hk)
        XCTAssertEqual(try offer([own, apple], listed: [current]), .none, "passkey à jour : synchro ou passkey de ce gestionnaire")
        XCTAssertEqual(try offer([own, apple], listed: [current], wanted: true), .create, "« C'est moi » ou passkey par QR : la locale")
        XCTAssertEqual(
            try offer([own], listed: [wrapObject(credentialId: "AQID", hk: old, current: true)]),
            .update(credentialIds: ["AQID"]),
            "current du serveur démenti par le journal"
        )
        XCTAssertEqual(
            try offer([own, apple], listed: [
                wrapObject(credentialId: "BQYH", hk: old, current: false), wrapObject(credentialId: "AQID", hk: hk)
            ], wanted: true),
            .update(credentialIds: ["BQYH"]),
            "une passkey périmée se met à jour d'abord"
        )
        // H1 : inscrit depuis moins de 24 h, le remplacement serait refusé.
        let stale = [wrapObject(credentialId: "BQYH", hk: old, current: false)]
        XCTAssertEqual(try offer([own], listed: stale, nowMs: 1 + Self.day - 1), .updateTomorrow)
        XCTAssertEqual(try offer([own], listed: stale, nowMs: 1 + Self.day), .update(credentialIds: ["BQYH"]))
    }

    /// Limite des dix enveloppes : la plus ancienne qui n'est pas à jour part, jamais une à jour.
    func testOldestStaleWrapIsTheOneRemoved() throws {
        let hk = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let old = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        func listed(_ wraps: [[String: Any]]) throws -> [E2EEAutoPasskeyContract.Listed] {
            try XCTUnwrap(E2EEAutoPasskeyContract.parseList(JSONSerialization.data(withJSONObject: ["wraps": wraps])))
        }
        let wraps = try listed([
            wrapObject(credentialId: "AQID", hk: hk, extra: ["updatedAtMs": "100"]),
            wrapObject(credentialId: "BQYH", hk: old, current: false, extra: ["updatedAtMs": "300"]),
            wrapObject(credentialId: "CQoL", hk: old, current: false, extra: ["updatedAtMs": "200"]),
            wrapObject(credentialId: "DQ4P", hk: old, current: true, extra: ["updatedAtMs": "250"]),
        ])
        XCTAssertEqual(E2EEAutoPasskeyContract.oldestStale(wraps, latest: hk)?.credentialId, "CQoL")
        XCTAssertNil(E2EEAutoPasskeyContract.oldestStale(try listed([wrapObject(credentialId: "AQID", hk: hk)]), latest: hk))
        XCTAssertTrue(E2EEAutoPasskeyContract.isDeleted(Data(#"{"deleted":true}"#.utf8)))
        XCTAssertFalse(E2EEAutoPasskeyContract.isDeleted(Data(#"{"deleted":1}"#.utf8)))
        XCTAssertFalse(E2EEAutoPasskeyContract.isDeleted(Data(#"{"deleted":true,"x":1}"#.utf8)))
    }
}
