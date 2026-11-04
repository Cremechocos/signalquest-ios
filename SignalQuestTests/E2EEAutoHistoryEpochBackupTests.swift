import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C2 (E2EE-AUTO §5.2) : rattrapage des époques reçues ici vers la dernière
/// HK, et restauration des enveloppes contrôlées face au journal vérifié.
final class E2EEAutoHistoryEpochBackupTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private static let conversationId = "conversation_000000000001"
    private let signing = P256.Signing.PrivateKey()
    private let ownId = "ios_device_own_000000000"
    private let hkScalar = P256.KeyAgreement.PrivateKey().rawRepresentation
    private var hk: String { E2EEAutoHistoryKey.publicKeyB64(scalar: hkScalar)! }

    private var ownDevice: E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: ownId, platform: "ios", label: nil,
            publicIdentityKeyB64: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
    }

    private func device(_ id: String, signingKeyB64: String, activated: Bool = true) -> E2EEAutoLog.DeviceState {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        return E2EEAutoLog.DeviceState(
            deviceId: id, platform: .ios, identityKeyB64: key, signingKeyB64: signingKeyB64, keyVersion: 1,
            status: activated ? .active : .pending, addedAtMs: 1, activatedAtMs: activated ? 1 : nil,
            addEntryHash: E2EEAutoLog.digest("add-\(id)"), identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1)],
            revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
        )
    }

    private func account(hks: [String]? = nil, extra: [E2EEAutoLog.DeviceState] = []) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        account.devices[ownId] = device(ownId, signingKeyB64: ownDevice.publicSigningKeyB64)
        for other in extra { account.devices[other.deviceId] = other }
        var previous: String?
        for (index, key) in (hks ?? [hk]).enumerated() {
            account.historyKeys.append(.init(
                seq: Int64(10 + index), entryHash: E2EEAutoLog.digest("hk-\(index)"), hkPubB64: key, previousHkPubB64: previous,
                signerDeviceId: ownId, signerAddedAtMs: 1, createdAtMs: 2, afterRevokeSeq: nil
            ))
            previous = key
        }
        account.historyKeyPubB64 = previous
        account.lastEntryHash = E2EEAutoLog.digest("last")
        return account
    }

    private struct Epoch {
        let id: String
        let number: Int
        let key: Data
        var commitment: String { try! E2EEV2EpochCrypto.keyCommitment(key) }
        var view: [String: Any] {
            ["epochId": id, "epochNumber": String(number), "algorithm": "AES_256_GCM_HKDF_SHA256", "keyCommitmentB64": commitment,
             "reason": "ROTATION", "status": "active", "createdAt": "2026-11-04T12:00:00.000Z"]
        }
        var local: E2EEAutoHistoryEpochBackup.LocalEpoch { .init(epochId: id, keyCommitmentB64: commitment, epochKey: key) }
    }

    private func epoch(_ number: Int) -> Epoch {
        Epoch(id: "epoch_\(String(repeating: "0", count: 14))\(number)", number: number, key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private static func failure(_ status: Int, _ code: String, retryAfter: Int? = nil) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x",
            retryAfterSeconds: retryAfter
        ))
    }

    private func backfillPage(_ items: [(Epoch, Bool)], hk: String? = nil, next: String? = nil) -> E2EEV2TransportResult<Data> {
        let envelope: [String: Any] = [
            "recipientDeviceId": ownId, "senderDeviceId": "web_device_0000000000001", "wrapAlgorithm": "x",
            "ephemeralPublicKeyB64": "x", "wrappedEpochKeyB64": "x", "nonceB64": "x", "aadB64": "x", "signatureB64": "x",
        ]
        return .success(value: Self.json([
            "hkPubB64": hk ?? self.hk, "nextCursor": next.map { $0 as Any } ?? NSNull(),
            "items": items.map { ["conversationId": Self.conversationId, "epoch": $0.0.view, "deviceEnvelope": $0.1 ? envelope as Any : NSNull() as Any] },
        ]), statusCode: 200, idempotentReplay: false)
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var gets: [E2EEV2TransportResult<Data>] = []
        var postResults: [(Fake, [String: Any]) -> E2EEV2TransportResult<Data>] = []
        var scalars: [String: Data] = [:]
        var local: [Int: E2EEAutoHistoryEpochBackup.LocalEpoch] = [:]
        var finished: Set<String> = []
        private(set) var readCount = 0
        private(set) var posts: [(path: String, body: [String: Any])] = []
        private(set) var stored: [(epochId: String, key: Data)] = []

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        func dependencies(device: E2EEV2DeviceDescriptor, signing: P256.Signing.PrivateKey) -> E2EEAutoHistoryEpochBackup.Dependencies {
            .init(
                userId: E2EEAutoHistoryEpochBackupTests.userId,
                device: { device },
                sign: { try E2EEV2LowS.sign($0, with: signing) },
                get: { [self] _, _ in gets.isEmpty ? .failure(.init(kind: .retryable, statusCode: 503, message: "x")) : gets.removeFirst() },
                post: { [self] path, body, _ in
                    let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                    posts.append((path, object))
                    return postResults.isEmpty ? .failure(.init(kind: .retryable, statusCode: 503, message: "x")) : postResults.removeFirst()(self, object)
                },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                scalar: { [self] in scalars[$0] },
                localEpoch: { [self] _, number in local[number] },
                storeRestored: { [self] _, epoch, key in
                    stored.append((epoch.epochId, key))
                    return true
                },
                finishedEpochIds: { [self] in finished },
                recordFinished: { [self] in finished.insert($0) },
                nowMs: { 1_000_000 }
            )
        }
    }

    private func backup(_ fake: Fake) -> E2EEAutoHistoryEpochBackup {
        E2EEAutoHistoryEpochBackup(fake.dependencies(device: ownDevice, signing: signing))
    }

    private func created(_ epoch: Epoch) -> (Fake, [String: Any]) -> E2EEV2TransportResult<Data> {
        { _, _ in
            .success(value: Self.json([
                "historyEnvelopeId": "history_envelope_000001", "conversationId": Self.conversationId, "epochId": epoch.id,
            ]), statusCode: 201, idempotentReplay: false)
        }
    }

    // MARK: Contrat

    func testEpochViewIsStrictAndTheMarkerOnlyTrue() {
        let first = epoch(1)
        XCTAssertEqual(E2EEAutoHistoryEpochContract.epoch(first.view)?.epochNumber, 1)
        var marked = first.view
        marked["e2eeAuto"] = true
        XCTAssertNotNil(E2EEAutoHistoryEpochContract.epoch(marked))
        marked["e2eeAuto"] = false
        XCTAssertNil(E2EEAutoHistoryEpochContract.epoch(marked), "jamais servi à false")
        marked["e2eeAuto"] = 1
        XCTAssertNil(E2EEAutoHistoryEpochContract.epoch(marked), "booléen, pas nombre")
        var integer = first.view
        integer["epochNumber"] = 1
        XCTAssertNil(E2EEAutoHistoryEpochContract.epoch(integer), "entiers en chaînes décimales")
        var padded = first.view
        padded["epochNumber"] = "01"
        XCTAssertNil(E2EEAutoHistoryEpochContract.epoch(padded))
        XCTAssertEqual(
            E2EEAutoHistoryEpochContract.depositPath(conversationId: Self.conversationId, epochNumber: 3),
            "/api/e2ee/auto/conversations/\(Self.conversationId)/epochs/3/history-envelopes"
        )
    }

    func testAccountWithoutHistoryKeyServesNoBackfill() {
        let page = E2EEAutoHistoryEpochContract.parseBackfill(Self.json(["hkPubB64": NSNull(), "nextCursor": NSNull(), "items": []]))
        XCTAssertEqual(page, .init(hkPubB64: nil, items: [], nextCursor: nil))
        XCTAssertNil(E2EEAutoHistoryEpochContract.parseBackfill(Self.json(["hkPubB64": NSNull(), "nextCursor": NSNull(), "items": [1]])))
    }

    // MARK: Rattrapage

    func testBackfillWrapsLocallyHeldEpochsTowardTheLatestKey() async throws {
        let first = epoch(1), second = epoch(2)
        let fake = Fake(reads: [.verified(account())])
        fake.scalars = [hk: hkScalar]
        fake.local = [1: first.local, 2: second.local]
        fake.gets = [backfillPage([(first, true), (second, false)])]
        fake.postResults = [created(first), { _, _ in Self.failure(409, "E2EE_HISTORY_ENVELOPE_EXISTS") }]
        let outcome = await backup(fake).backfill()
        XCTAssertEqual(outcome, .backedUp(1), "un 409 EXISTS vaut succès sans compter deux fois")
        XCTAssertEqual(fake.posts.map(\.path), [1, 2].map {
            E2EEAutoHistoryEpochContract.depositPath(conversationId: Self.conversationId, epochNumber: $0)
        })
        // L'enveloppe déposée s'ouvre avec HK et rend la clé de l'époque.
        let raw = try XCTUnwrap(fake.posts.first?.body)
        let envelope = try XCTUnwrap(E2EEAutoHistory.parseEpochUploadBody(raw))
        XCTAssertEqual(envelope.hkPubB64, hk)
        XCTAssertEqual(envelope.recipientUserId, Self.userId)
        let opened = try E2EEAutoHistory.openEpoch(
            envelope, scalar: hkScalar, userId: Self.userId, conversationId: Self.conversationId, epochNumber: 1,
            senderDeviceId: ownId, keyCommitmentB64: first.commitment
        )
        XCTAssertEqual(opened, first.key)
    }

    func testBackfillOnlyWrapsWhatItReceivedAndRemembersLostEpochs() async {
        let pending = epoch(1), lost = epoch(2), substituted = epoch(3)
        let fake = Fake(reads: [.verified(account())])
        fake.scalars = [hk: hkScalar]
        fake.local = [3: epoch(3).local]
        fake.gets = [backfillPage([(pending, true), (lost, false), (substituted, true)])]
        let outcome = await backup(fake).backfill()
        XCTAssertEqual(outcome, .backedUp(0))
        XCTAssertTrue(fake.posts.isEmpty, "ni clé absente, ni clé dont l'engagement diffère")
        XCTAssertEqual(fake.finished, [lost.id], "enveloppe accusée sans clé : terminée ; l'autre attend la synchro")
    }

    func testBackfillRereadsTheAccountWhenTheHintDiffers() async {
        let newer = P256.KeyAgreement.PrivateKey().rawRepresentation
        let newerPub = E2EEAutoHistoryKey.publicKeyB64(scalar: newer)!
        let first = epoch(1)
        let fake = Fake(reads: [.verified(account()), .verified(account(hks: [hk, newerPub]))])
        fake.scalars = [hk: hkScalar, newerPub: newer]
        fake.local = [1: first.local]
        fake.gets = [backfillPage([(first, true)], hk: newerPub), backfillPage([(first, true)], hk: newerPub)]
        fake.postResults = [created(first)]
        let outcome = await backup(fake).backfill()
        XCTAssertEqual(outcome, .backedUp(1))
        XCTAssertEqual(fake.readCount, 2)
        XCTAssertEqual(E2EEAutoHistory.parseEpochUploadBody(fake.posts.first?.body ?? [:])?.hkPubB64, newerPub)
    }

    func testBackfillStopsOnRateLimitAndWithoutTheLatestKey() async {
        let first = epoch(1)
        let limited = Fake(reads: [.verified(account())])
        limited.scalars = [hk: hkScalar]
        limited.local = [1: first.local]
        limited.gets = [backfillPage([(first, true)])]
        limited.postResults = [{ _, _ in Self.failure(429, "E2EE_HISTORY_ENVELOPE_RATE_LIMITED", retryAfter: 120) }]
        let rateLimited = await backup(limited).backfill()
        XCTAssertEqual(rateLimited, .retryLater(afterSeconds: 120))

        let withoutKey = Fake(reads: [.verified(account())])
        let noKey = await backup(withoutKey).backfill()
        XCTAssertEqual(noKey, .noHistoryKey)
        XCTAssertTrue(withoutKey.posts.isEmpty)

        let stale = Fake(reads: [.verified(account())])
        stale.scalars = [hk: hkScalar]
        stale.local = [1: first.local]
        stale.gets = [backfillPage([(first, true)])]
        stale.postResults = [{ _, _ in Self.failure(409, "E2EE_HISTORY_KEY_STALE") }]
        let staleOutcome = await backup(stale).backfill()
        XCTAssertEqual(staleOutcome, .retryLater(afterSeconds: nil))
    }

    // MARK: Restauration

    private func restoreItem(_ epoch: Epoch, sender: String, signer: P256.Signing.PrivateKey, id: String) throws -> [String: Any] {
        let envelope = try E2EEAutoHistory.sealEpoch(
            epochKey: epoch.key, keyCommitmentB64: epoch.commitment, userId: Self.userId, conversationId: Self.conversationId,
            epochNumber: epoch.number, senderDeviceId: sender, hkPubB64: hk, sign: { try E2EEV2LowS.sign($0, with: signer) }
        )
        return ["historyEnvelopeId": id, "conversationId": Self.conversationId, "epoch": epoch.view, "senderDeviceId": sender,
                "envelope": envelope.jsonObject]
    }

    func testRestoreKeepsOnlyEnvelopesThatPassTheLogChecks() async throws {
        let good = epoch(1), forged = epoch(2), fromPending = epoch(3), known = epoch(4)
        let otherSigning = P256.Signing.PrivateKey()
        let pendingSigning = P256.Signing.PrivateKey()
        let otherId = "android_device_other_0000", pendingId = "web_device_pending_000000"
        let extra = [
            device(otherId, signingKeyB64: otherSigning.publicKey.x963Representation.base64EncodedString()),
            device(pendingId, signingKeyB64: pendingSigning.publicKey.x963Representation.base64EncodedString(), activated: false),
        ]
        let fake = Fake(reads: [.verified(account(extra: extra))])
        fake.scalars = [hk: hkScalar]
        fake.local = [4: Epoch(id: known.id, number: 4, key: epoch(4).key).local]
        fake.gets = [.success(value: Self.json([
            "missingEpochCount": "2", "nextCursor": NSNull(),
            "items": [
                try restoreItem(good, sender: otherId, signer: otherSigning, id: "history_envelope_000001"),
                try restoreItem(forged, sender: otherId, signer: P256.Signing.PrivateKey(), id: "history_envelope_000002"),
                try restoreItem(fromPending, sender: pendingId, signer: pendingSigning, id: "history_envelope_000003"),
                try restoreItem(known, sender: otherId, signer: otherSigning, id: "history_envelope_000004"),
                try restoreItem(good, sender: ownId, signer: signing, id: "history_envelope_000005"),
            ],
        ]), statusCode: 200, idempotentReplay: false)]
        let outcome = await backup(fake).restore()
        XCTAssertEqual(outcome, .restored(1, missingEpochCount: 2))
        XCTAssertEqual(fake.stored.map(\.epochId), [good.id], "signature fausse, appareil jamais activé, engagement différent du connu : ignorés")
        XCTAssertEqual(fake.stored.first?.key, good.key)
    }

    func testRestoreNeedsAHeldHistoryKeyOfTheLog() async {
        let fake = Fake(reads: [.verified(account())])
        let outcome = await backup(fake).restore()
        XCTAssertEqual(outcome, .noHistoryKey)
        XCTAssertEqual(E2EEAutoHistoryEpochContract.parseRestore(Self.json([
            "missingEpochCount": 2, "nextCursor": NSNull(), "items": [],
        ])), nil, "entiers en chaînes décimales")
    }
}
