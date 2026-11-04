import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C5 (E2EE-AUTO §6, route r3) : le mode renforcé se règle par une requête signée,
/// la réponse doit être le `MODE` signé ici, et seul le journal relu fait foi.
final class E2EEAutoModeSettingTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let day = E2EEAutoLog.signerMinAgeMs
    private let signing = P256.Signing.PrivateKey()
    private let ownId = "ios_device_own_000000001"
    private let otherId = "and_device_other_0000001"

    private var device: E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: ownId, platform: "ios", label: nil, publicIdentityKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
    }

    private func state(_ id: String, key: String, status: E2EEAutoLog.DeviceStatus = .active) -> E2EEAutoLog.DeviceState {
        E2EEAutoLog.DeviceState(
            deviceId: id, platform: .ios, identityKeyB64: key, signingKeyB64: key, keyVersion: 1, status: status,
            addedAtMs: 1_000, activatedAtMs: 1_000, addEntryHash: E2EEAutoLog.digest(id),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1_000)], revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
        )
    }

    private func account(mode: E2EEAutoLog.Mode = .normal, others: Int = 1, last: String = "last") -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Data(repeating: 7, count: 16).base64EncodedString())
        account.devices[ownId] = state(ownId, key: device.publicSigningKeyB64)
        if others > 0 {
            account.devices[otherId] = state(otherId, key: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString())
        }
        account.mode = mode
        account.lastEntryHash = E2EEAutoLog.digest(last)
        return account
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        var responses: [(Data) -> E2EEV2TransportResult<Data>] = []
        private(set) var bodies: [[String: Any]] = []
        var nowMs: Int64 = 1_000 + E2EEAutoLog.signerMinAgeMs

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        func dependencies(device: E2EEV2DeviceDescriptor, signing: P256.Signing.PrivateKey) -> E2EEAutoModeSetting.Dependencies {
            .init(
                userId: E2EEAutoModeSettingTests.userId,
                device: { device },
                sign: { try E2EEV2LowS.sign($0, with: signing) },
                put: { [self] path, body, _ in
                    XCTAssertEqual(path, E2EEAutoStrictMode.path)
                    bodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
                    guard !responses.isEmpty else { return .failure(.init(kind: .retryable, statusCode: 503, message: "x")) }
                    return responses.removeFirst()(body)
                },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                nowMs: { [self] in nowMs }
            )
        }
    }

    /// Le `MODE` que le serveur écrirait à partir du corps reçu, signé par `key`.
    private func written(signer: String? = nil, key: P256.Signing.PrivateKey? = nil) -> (Data) -> E2EEV2TransportResult<Data> {
        { [self] body in
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let prev = object["prevUserEntryHash"] as? String ?? ""
            let mode = E2EEAutoLog.Mode(rawValue: object["mode"] as? String ?? "") ?? .normal
            var signature = object["signatureB64"] as? String ?? ""
            if let key {
                let payload = E2EEAutoStrictMode.payload(userId: Self.userId, prevUserEntryHash: prev, signerDeviceId: signer ?? ownId, mode: mode)
                signature = (try? E2EEV2LowS.sign(Data(payload.utf8), with: key).base64EncodedString()) ?? ""
            }
            let none = E2EEAutoLog.none
            let entry = E2EEAutoLog.Entry(
                seq: 30, userId: Self.userId, prevUserEntryHash: prev, op: .mode, deviceId: none, platform: none,
                identityKeyB64: none, signingKeyB64: none, keyVersion: none,
                detail: "\(signer ?? ownId):\(mode.rawValue):\(signature)", createdAtMs: 9
            ).canonical
            let link = ["SQ-E2EE-AUTO-LOG-LINK", "1", "30", E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
                        E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
            let data = try! JSONSerialization.data(withJSONObject: ["entry": entry, "link": link, "head": ["text": "t", "signatureB64": "s"]])
            return .success(value: data, statusCode: 201, idempotentReplay: false)
        }
    }

    private func setting(_ fake: Fake) -> E2EEAutoModeSetting {
        E2EEAutoModeSetting(fake.dependencies(device: device, signing: signing))
    }

    /// Corps à trois champs exacts, charge signée par cet appareil, mode adopté à la relecture.
    func testStrictIsSignedWrittenAndAdoptedFromTheLog() async throws {
        let fake = Fake(reads: [.verified(account()), .verified(account(mode: .strict))])
        fake.responses = [written()]
        let outcome = await setting(fake).set(.strict)
        XCTAssertEqual(outcome, .set(.strict))
        let body = try XCTUnwrap(fake.bodies.first)
        XCTAssertEqual(Set(body.keys), ["prevUserEntryHash", "mode", "signatureB64"])
        XCTAssertEqual(body["mode"] as? String, "STRICT")
        XCTAssertEqual(body["prevUserEntryHash"] as? String, E2EEAutoLog.digest("last"))
        let payload = E2EEAutoStrictMode.payload(
            userId: Self.userId, prevUserEntryHash: E2EEAutoLog.digest("last"), signerDeviceId: ownId, mode: .strict
        )
        XCTAssertTrue(E2EEAutoLog.verify(
            publicKeyB64: device.publicSigningKeyB64, payload: payload, signatureB64: try XCTUnwrap(body["signatureB64"] as? String)
        ))
    }

    /// La réponse ne vaut pas adoption : le journal relu sans le `MODE` ne le montre pas.
    func testResponseAloneIsNotAdoption() async {
        let fake = Fake(reads: [.verified(account())])
        fake.responses = [written()]
        let outcome = await setting(fake).set(.strict)
        XCTAssertEqual(outcome, .retryLater(afterSeconds: nil))
    }

    /// Un `MODE` signé par une autre clé ou un autre appareil est refusé.
    func testForgedResponseIsRefused() async {
        let fake = Fake(reads: [.verified(account()), .verified(account(mode: .strict))])
        fake.responses = [written(key: P256.Signing.PrivateKey())]
        let forgedKey = await setting(fake).set(.strict)
        XCTAssertEqual(forgedKey, .failed("invalid-e2ee-auto-mode-response"))

        let other = Fake(reads: [.verified(account()), .verified(account(mode: .strict))])
        other.responses = [written(signer: otherId, key: signing)]
        let forgedSigner = await setting(other).set(.strict)
        XCTAssertEqual(forgedSigner, .failed("invalid-e2ee-auto-mode-response"))
    }

    /// Gardes locales avant toute requête : 24 h, deux appareils actifs, mode déjà en vigueur.
    func testLocalGuardsSendNothing() async {
        let recent = Fake(reads: [.verified(account())])
        recent.nowMs = 1_000 + Self.day - 1
        let tooRecent = await setting(recent).set(.strict)
        XCTAssertEqual(tooRecent, .tooRecent)

        let alone = Fake(reads: [.verified(account(others: 0))])
        let needsTwo = await setting(alone).set(.strict)
        XCTAssertEqual(needsTwo, .needsTwoDevices)

        let already = Fake(reads: [.verified(account(mode: .strict))])
        let unchanged = await setting(already).set(.strict)
        XCTAssertEqual(unchanged, .set(.strict))

        // NORMAL ne demande pas deux appareils.
        let back = Fake(reads: [.verified(account(mode: .strict, others: 0)), .verified(account(mode: .normal, others: 0))])
        back.responses = [written()]
        let normal = await setting(back).set(.normal)
        XCTAssertEqual(normal, .set(.normal))

        for fake in [recent, alone, already] { XCTAssertTrue(fake.bodies.isEmpty) }
    }

    /// `409 E2EE_LOG_STALE` : relire le compte et re-signer sur la nouvelle tête, une fois.
    func testStaleLogRereadsAndResigns() async throws {
        let fake = Fake(reads: [.verified(account()), .verified(account(last: "newer")), .verified(account(mode: .strict))])
        fake.responses = [
            { _ in .failure(.init(kind: E2EEV2TransportFailurePolicy.classify(statusCode: 409, code: "E2EE_LOG_STALE"),
                                  statusCode: 409, code: "E2EE_LOG_STALE", message: "x")) },
            written(),
        ]
        let outcome = await setting(fake).set(.strict)
        XCTAssertEqual(outcome, .set(.strict))
        XCTAssertEqual(fake.bodies.map { $0["prevUserEntryHash"] as? String }, [E2EEAutoLog.digest("last"), E2EEAutoLog.digest("newer")])
    }

    /// `200 { entry: null, link: null, head }` : mode déjà en vigueur côté serveur.
    func testUnchangedResponseShape() throws {
        let head: [String: Any] = ["text": "t", "signatureB64": "s"]
        XCTAssertTrue(E2EEAutoModeSetting.isUnchangedResponse(try JSONSerialization.data(
            withJSONObject: ["entry": NSNull(), "link": NSNull(), "head": head]
        )))
        XCTAssertFalse(E2EEAutoModeSetting.isUnchangedResponse(try JSONSerialization.data(
            withJSONObject: ["entry": NSNull(), "link": NSNull()]
        )))
        XCTAssertFalse(E2EEAutoModeSetting.isUnchangedResponse(try JSONSerialization.data(
            withJSONObject: ["entry": "x", "link": NSNull(), "head": head]
        )))
    }
}
