import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C6 (E2EE-AUTO §5.5) : la HK scellée par la sortie PRF d'une passkey ; le
/// serveur ne fait foi de rien, la HK ouverte doit être au journal vérifié.
final class E2EEAutoPasskeyBackupTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private let ownId = "ios_device_own_000000001"
    private let credentialId = "AQIDBAUGBwg"
    private let prfOutput = Data(repeating: 9, count: 32)
    private let prfSalt = Data(repeating: 4, count: 32)
    private let latest = Data(repeating: 1, count: 32)
    private let older = Data(repeating: 2, count: 32)

    private var device: E2EEV2DeviceDescriptor {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        return E2EEV2DeviceDescriptor(
            deviceId: ownId, platform: "ios", label: nil, publicIdentityKeyB64: key, publicSigningKeyB64: key,
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
    }

    private func pub(_ scalar: Data) -> String { E2EEAutoHistoryKey.publicKeyB64(scalar: scalar)! }

    private func account(status: E2EEAutoLog.DeviceStatus = .active, keys: [Data]? = nil) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Data(repeating: 7, count: 16).base64EncodedString())
        let key = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        account.devices[ownId] = E2EEAutoLog.DeviceState(
            deviceId: ownId, platform: .ios, identityKeyB64: key, signingKeyB64: key, keyVersion: 1, status: status,
            addedAtMs: 1_000, activatedAtMs: 1_000, addEntryHash: E2EEAutoLog.digest(ownId),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1_000)], revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
        )
        let chain = keys ?? [older, latest]
        for (index, scalar) in chain.enumerated() {
            account.historyKeys.append(.init(
                seq: Int64(10 + index), entryHash: E2EEAutoLog.digest("hk\(index)"), hkPubB64: pub(scalar),
                previousHkPubB64: index == 0 ? nil : pub(chain[index - 1]), signerDeviceId: ownId,
                signerAddedAtMs: 1_000, createdAtMs: 2_000, afterRevokeSeq: nil
            ))
        }
        account.historyKeyPubB64 = chain.last.map(pub)
        return account
    }

    private final class Fake: @unchecked Sendable {
        var own: E2EEAutoEnrollment.OwnAccount
        var held: [String: Data] = [:]
        var listed: [[String: Any]] = []
        var putResponse: ((Data) -> E2EEV2TransportResult<Data>)?
        private(set) var puts: [(path: String, body: [String: Any])] = []
        private(set) var kept: [Data] = []

        init(own: E2EEAutoEnrollment.OwnAccount) { self.own = own }

        func dependencies(device: E2EEV2DeviceDescriptor) -> E2EEAutoPasskeyBackup.Dependencies {
            .init(
                userId: E2EEAutoPasskeyBackupTests.userId,
                device: { device },
                get: { [self] path in
                    XCTAssertEqual(path, E2EEAutoPasskeyContract.listPath)
                    return .success(value: try! JSONSerialization.data(withJSONObject: ["wraps": listed]), statusCode: 200, idempotentReplay: false)
                },
                put: { [self] path, body, _ in
                    puts.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
                    guard let putResponse else { return .failure(.init(kind: .retryable, statusCode: 503, message: "x")) }
                    return putResponse(body)
                },
                readOwnAccount: { [self] in own },
                scalar: { [self] in held[$0] },
                keep: { [self] scalar in
                    kept.append(scalar)
                    return E2EEAutoHistoryKey.publicKeyB64(scalar: scalar) ?? ""
                }
            )
        }
    }

    /// L'élément du `GET` que le serveur renverrait pour ce corps.
    private func echo(credentialId: String? = nil, tamper: Bool = false) -> (Data) -> E2EEV2TransportResult<Data> {
        { [self] body in
            var object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            object["credentialId"] = credentialId ?? self.credentialId
            object["current"] = true
            object["updatedAtMs"] = "1793000000000"
            if tamper { object["nonceB64"] = Data(repeating: 0, count: 12).base64EncodedString() }
            return .success(value: try! JSONSerialization.data(withJSONObject: object), statusCode: 200, idempotentReplay: false)
        }
    }

    private func listedObject(_ scalar: Data, credentialId: String, current: Bool) throws -> [String: Any] {
        let wrap = try E2EEAutoHistory.sealPasskey(
            scalar: scalar, prfOutput: prfOutput, prfSalt: prfSalt, userId: Self.userId, credentialId: credentialId
        )
        var object = wrap.jsonObject
        object["credentialId"] = credentialId
        object["current"] = current
        object["updatedAtMs"] = "1793000000000"
        return object
    }

    /// Corps aux quatre champs exacts, scellé sur la dernière HK, rouvert par la même sortie PRF.
    func testProtectSealsTheLatestKeyAndChecksTheReply() async throws {
        let fake = Fake(own: .verified(account()))
        fake.held = [pub(latest): latest, pub(older): older]
        fake.putResponse = echo()
        let outcome = await E2EEAutoPasskeyBackup(fake.dependencies(device: device))
            .protect(credentialId: credentialId, prfSalt: prfSalt, prfOutput: prfOutput)
        XCTAssertEqual(outcome, .protected)
        let put = try XCTUnwrap(fake.puts.first)
        XCTAssertEqual(put.path, "\(E2EEAutoPasskeyContract.listPath)/\(credentialId)")
        XCTAssertEqual(Set(put.body.keys), ["prfSaltB64", "nonceB64", "wrappedB64", "hkPubB64"])
        XCTAssertEqual(put.body["hkPubB64"] as? String, pub(latest))
        XCTAssertEqual(put.body["prfSaltB64"] as? String, prfSalt.base64EncodedString())
        let wrap = try XCTUnwrap(E2EEAutoHistory.parsePasskeyWrap(put.body))
        XCTAssertEqual(try E2EEAutoHistory.openPasskey(wrap, prfOutput: prfOutput, userId: Self.userId, credentialId: credentialId), latest)
    }

    /// Une réponse qui n'est pas l'enveloppe déposée (autre identifiant, autre contenu) est refusée.
    func testProtectRefusesAnotherReply() async {
        for response in [echo(tamper: true), echo(credentialId: "CQoLDA")] {
            let fake = Fake(own: .verified(account()))
            fake.held = [pub(latest): latest]
            fake.putResponse = response
            let outcome = await E2EEAutoPasskeyBackup(fake.dependencies(device: device))
                .protect(credentialId: credentialId, prfSalt: prfSalt, prfOutput: prfOutput)
            XCTAssertEqual(outcome, .failed("invalid-e2ee-auto-passkey-response"))
        }
    }

    /// Sans la dernière HK ou appareil non actif : rien ne part. Erreurs du serveur traduites.
    func testProtectGuardsAndErrors() async {
        let missing = Fake(own: .verified(account()))
        missing.held = [pub(older): older]
        let noKey = await E2EEAutoPasskeyBackup(missing.dependencies(device: device))
            .protect(credentialId: credentialId, prfSalt: prfSalt, prfOutput: prfOutput)
        XCTAssertEqual(noKey, .noHistoryKey)
        XCTAssertTrue(missing.puts.isEmpty)

        let pending = Fake(own: .verified(account(status: .pending)))
        pending.held = [pub(latest): latest]
        let notActive = await E2EEAutoPasskeyBackup(pending.dependencies(device: device))
            .protect(credentialId: credentialId, prfSalt: prfSalt, prfOutput: prfOutput)
        XCTAssertEqual(notActive, .notActive)
        XCTAssertTrue(pending.puts.isEmpty)

        for (code, expected) in [
            ("E2EE_HISTORY_KEY_STALE", E2EEAutoPasskeyBackup.ProtectOutcome.stale),
            ("E2EE_PASSKEY_WRAP_LIMIT", .limit),
            ("E2EE_DEVICE_NOT_ACTIVE", .notActive),
        ] {
            let fake = Fake(own: .verified(account()))
            fake.held = [pub(latest): latest]
            fake.putResponse = { _ in .failure(.init(kind: .permanent, statusCode: code == "E2EE_DEVICE_NOT_ACTIVE" ? 403 : 409, code: code, message: "x")) }
            let outcome = await E2EEAutoPasskeyBackup(fake.dependencies(device: device))
                .protect(credentialId: credentialId, prfSalt: prfSalt, prfOutput: prfOutput)
            XCTAssertEqual(outcome, expected, code)
        }
    }

    /// Ouverture : la dernière HK donne `present`, une précédente `older` ; une HK
    /// inconnue du journal n'est jamais gardée, même bien scellée.
    func testRecoverKeepsOnlyKeysOfTheLog() async throws {
        let fake = Fake(own: .verified(account()))
        fake.listed = [
            try listedObject(latest, credentialId: credentialId, current: true),
            try listedObject(older, credentialId: "CQoLDA", current: false),
        ]
        let backup = E2EEAutoPasskeyBackup(fake.dependencies(device: device))
        let listed = await backup.recoverable()
        XCTAssertEqual(listed.map(\.credentialId), [credentialId, "CQoLDA"])
        let present = await backup.recover(listed[0], prfOutput: prfOutput)
        XCTAssertEqual(present, .present(hkPubB64: pub(latest)))
        let old = await backup.recover(listed[1], prfOutput: prfOutput)
        XCTAssertEqual(old, .older(hkPubB64: pub(older)))
        XCTAssertEqual(fake.kept, [latest, older])

        let wrongPrf = await backup.recover(listed[0], prfOutput: Data(repeating: 8, count: 32))
        XCTAssertEqual(wrongPrf, .failed("e2ee-auto-passkey-open"))

        let stranger = Data(repeating: 3, count: 32)
        fake.listed = [try listedObject(stranger, credentialId: credentialId, current: true)]
        let offered = await backup.recoverable()
        XCTAssertTrue(offered.isEmpty, "HK hors journal : pas proposée")
        let forged = try XCTUnwrap(E2EEAutoPasskeyContract.parseList(JSONSerialization.data(withJSONObject: ["wraps": fake.listed])))
        let unknown = await backup.recover(forged[0], prfOutput: prfOutput)
        XCTAssertEqual(unknown, .failed("e2ee-auto-passkey-unknown-key"))
        XCTAssertEqual(fake.kept.count, 2, "rien de gardé")
    }
}
