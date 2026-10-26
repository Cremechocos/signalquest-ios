import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 6a (E2EE-AUTO §4.4) : révocation signée par cet appareil, contrôlée sur
/// le journal, et l'écran Appareils tiré du journal vérifié.
final class E2EEAutoDeviceRevocationTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private let signing = P256.Signing.PrivateKey()
    private let ownId = "ios_device_own_000000000"
    private let otherId = "android_device_other_0000"

    private var ownDevice: E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: ownId, platform: "ios", label: nil,
            publicIdentityKeyB64: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
    }

    private func state(
        _ deviceId: String, platform: E2EEAutoLog.Platform = .ios, signingKeyB64: String? = nil,
        status: E2EEAutoLog.DeviceStatus = .active, addedAtMs: Int64 = 1, revokedAtMs: Int64? = nil,
        reason: E2EEAutoLog.RevokeReason? = nil
    ) -> E2EEAutoLog.DeviceState {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        return E2EEAutoLog.DeviceState(
            deviceId: deviceId, platform: platform, identityKeyB64: key,
            signingKeyB64: signingKeyB64 ?? P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            keyVersion: 1, status: status, addedAtMs: addedAtMs, activatedAtMs: status == .pending ? nil : addedAtMs,
            addEntryHash: E2EEAutoLog.digest("add-\(deviceId)"),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: addedAtMs)],
            revokeReason: reason, revokeSeq: reason == nil ? nil : 9, revokedAtMs: revokedAtMs
        )
    }

    private func account(_ devices: [E2EEAutoLog.DeviceState], last: String = E2EEAutoLog.digest("last")) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        for device in devices { account.devices[device.deviceId] = device }
        account.lastEntryHash = last
        return account
    }

    private func ownState(status: E2EEAutoLog.DeviceStatus = .active, addedAtMs: Int64 = 1) -> E2EEAutoLog.DeviceState {
        state(ownId, signingKeyB64: ownDevice.publicSigningKeyB64, status: status, addedAtMs: addedAtMs)
    }

    /// Le `REVOKE` que le serveur écrirait, signé par `key`.
    private func written(
        target: String, prev: String, reason: E2EEAutoLog.RevokeReason, revoker: String? = nil, key: P256.Signing.PrivateKey? = nil
    ) throws -> Data {
        let revoker = revoker ?? ownId
        let payload = E2EEAutoRevocationContract.payload(
            userId: Self.userId, prevUserEntryHash: prev, revokerDeviceId: revoker, deviceId: target, reason: reason
        )
        let signature = try E2EEV2LowS.sign(Data(payload.utf8), with: key ?? signing).base64EncodedString()
        let entry = E2EEAutoLog.Entry(
            seq: 30, userId: Self.userId, prevUserEntryHash: prev, op: .revoke, deviceId: target, platform: E2EEAutoLog.none,
            identityKeyB64: E2EEAutoLog.none, signingKeyB64: E2EEAutoLog.none, keyVersion: E2EEAutoLog.none,
            detail: "\(reason.rawValue):\(revoker):\(signature)", createdAtMs: 9
        ).canonical
        let link = ["SQ-E2EE-AUTO-LOG-LINK", "1", "30", E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
                    E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
        return try JSONSerialization.data(withJSONObject: ["entry": entry, "link": link, "head": ["text": "t", "signatureB64": "s"]])
    }

    private static func failure(_ status: Int, _ code: String, details: [String: JSONValue]? = nil) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x",
            details: details
        ))
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        var responses: [E2EEV2TransportResult<Data>] = []
        private(set) var posts: [(path: String, body: [String: Any])] = []
        private(set) var forgotten = 0

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        func dependencies(device: E2EEV2DeviceDescriptor, signing: P256.Signing.PrivateKey) -> E2EEAutoDeviceRevocation.Dependencies {
            .init(
                userId: E2EEAutoDeviceRevocationTests.userId,
                device: { device },
                sign: { try E2EEV2LowS.sign($0, with: signing) },
                post: { [self] path, body, _ in
                    posts.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
                    return responses.isEmpty ? .failure(.init(kind: .retryable, statusCode: 503, message: "x")) : responses.removeFirst()
                },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                forgetThisDevice: { [self] in forgotten += 1 },
                nowMs: { 1_000_000 }
            )
        }
    }

    private func run(_ fake: Fake, target: String, reason: E2EEAutoLog.RevokeReason) async -> E2EEAutoDeviceRevocation.Outcome {
        await E2EEAutoDeviceRevocation(fake.dependencies(device: ownDevice, signing: signing)).revoke(deviceId: target, reason: reason)
    }

    // MARK: Contrat

    func testBodyIsExactAndTheTokenStaysOutOfTheSignature() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEAutoRevocationContract.body(
            prevUserEntryHash: "h", reason: .notMe, signatureB64: "s"
        )) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["prevUserEntryHash", "reason", "signatureB64"], "jeton absent, jamais null")
        XCTAssertEqual(body["reason"] as? String, "NOT_ME")
        let withToken = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEAutoRevocationContract.body(
            prevUserEntryHash: "h", reason: .user, signatureB64: "s", confirmationToken: "token_0123456789ab"
        )) as? [String: Any])
        XCTAssertEqual(withToken["confirmationToken"] as? String, "token_0123456789ab")
        XCTAssertEqual(
            E2EEAutoRevocationContract.payload(userId: "u", prevUserEntryHash: "p", revokerDeviceId: "r", deviceId: "d", reason: .user),
            "SQ-E2EE-AUTO-REVOKE\n1\nu\np\nr\nd\nUSER"
        )
        XCTAssertEqual(E2EEAutoRevocationContract.revokePath(deviceId: otherId), "/api/e2ee/auto/devices/\(otherId)/revoke")
    }

    func testResponseMustBeThisRevokeSignedHere() throws {
        let prev = E2EEAutoLog.digest("last")
        func parse(_ data: Data, target: String? = nil, reason: E2EEAutoLog.RevokeReason = .user) -> Bool {
            E2EEAutoRevocationContract.parse(
                data, userId: Self.userId, prevUserEntryHash: prev, revokerDeviceId: ownId, deviceId: target ?? otherId,
                reason: reason, signingKeyB64: ownDevice.publicSigningKeyB64
            )
        }
        XCTAssertTrue(parse(try written(target: otherId, prev: prev, reason: .user)))
        XCTAssertFalse(parse(try written(target: otherId, prev: prev, reason: .user), reason: .notMe), "autre raison")
        XCTAssertFalse(parse(try written(target: otherId, prev: prev, reason: .user), target: "web_device_000000000000"), "autre cible")
        XCTAssertFalse(parse(try written(target: otherId, prev: E2EEAutoLog.digest("old"), reason: .user)), "autre état")
        XCTAssertFalse(parse(try written(target: otherId, prev: prev, reason: .user, key: P256.Signing.PrivateKey())), "autre clé")
        XCTAssertFalse(parse(try written(target: otherId, prev: prev, reason: .user, revoker: "web_device_000000000000")), "autre révocateur")
    }

    // MARK: Révocation

    func testRevokesAnotherDeviceWithASignedRequest() async throws {
        let prev = E2EEAutoLog.digest("last")
        let fake = Fake(reads: [.verified(account([ownState(), state(otherId, platform: .android)], last: prev))])
        fake.responses = [.success(value: try written(target: otherId, prev: prev, reason: .notMe), statusCode: 200, idempotentReplay: false)]
        let outcome = await run(fake, target: otherId, reason: .notMe)
        XCTAssertEqual(outcome, .revoked(ownDevice: false))
        XCTAssertEqual(fake.forgotten, 0)
        let post = try XCTUnwrap(fake.posts.first)
        XCTAssertEqual(post.path, E2EEAutoRevocationContract.revokePath(deviceId: otherId))
        XCTAssertEqual(post.body["prevUserEntryHash"] as? String, prev)
        let signature = try XCTUnwrap(post.body["signatureB64"] as? String)
        XCTAssertTrue(E2EEAutoLog.verify(
            publicKeyB64: ownDevice.publicSigningKeyB64,
            payload: E2EEAutoRevocationContract.payload(
                userId: Self.userId, prevUserEntryHash: prev, revokerDeviceId: ownId, deviceId: otherId, reason: .notMe
            ),
            signatureB64: signature
        ))
    }

    func testSelfRevocationForgetsThisDevice() async throws {
        let prev = E2EEAutoLog.digest("last")
        let fake = Fake(reads: [.verified(account([ownState(addedAtMs: 999_999)], last: prev))])
        fake.responses = [.success(value: try written(target: ownId, prev: prev, reason: .user), statusCode: 200, idempotentReplay: false)]
        let outcome = await run(fake, target: ownId, reason: .user)
        XCTAssertEqual(outcome, .revoked(ownDevice: true), "permise même à moins de 24 h")
        XCTAssertEqual(fake.forgotten, 1)

        let notMe = Fake(reads: [.verified(account([ownState()]))])
        let refused = await run(notMe, target: ownId, reason: .notMe)
        XCTAssertEqual(refused, .notFound, "« Ce n’est pas moi » sur soi-même n’est jamais envoyé")
        XCTAssertTrue(notMe.posts.isEmpty)
    }

    func testStaleLogIsRereadAndResignedOnce() async throws {
        let first = E2EEAutoLog.digest("first"), second = E2EEAutoLog.digest("second")
        let fake = Fake(reads: [
            .verified(account([ownState(), state(otherId)], last: first)),
            .verified(account([ownState(), state(otherId)], last: second)),
        ])
        fake.responses = [
            Self.failure(409, "E2EE_LOG_STALE"),
            .success(value: try written(target: otherId, prev: second, reason: .user), statusCode: 200, idempotentReplay: false),
        ]
        let outcome = await run(fake, target: otherId, reason: .user)
        XCTAssertEqual(outcome, .revoked(ownDevice: false))
        XCTAssertEqual(fake.posts.map { $0.body["prevUserEntryHash"] as? String }, [first, second])

        let twice = Fake(reads: [.verified(account([ownState(), state(otherId)], last: first))])
        twice.responses = [Self.failure(409, "E2EE_LOG_STALE"), Self.failure(409, "E2EE_LOG_STALE")]
        let gaveUp = await run(twice, target: otherId, reason: .user)
        XCTAssertEqual(gaveUp, .retryLater)
        XCTAssertEqual(twice.posts.count, 2, "une seule nouvelle signature")
    }

    /// Déjà retirée, ou requête rejouée déjà écrite : le journal relu le dit, sans nouvel envoi.
    func testAlreadyRevokedOrReplayedIsReadBackFromTheLog() async {
        for code in ["E2EE_DEVICE_ALREADY_REVOKED", "E2EE_REQUEST_REPLAYED"] {
            let fake = Fake(reads: [
                .verified(account([ownState(), state(otherId)])),
                .verified(account([ownState(), state(otherId, status: .revoked, revokedAtMs: 5, reason: .user)])),
            ])
            fake.responses = [Self.failure(409, code)]
            let outcome = await run(fake, target: otherId, reason: .user)
            XCTAssertEqual(outcome, .revoked(ownDevice: false), code)
            XCTAssertEqual(fake.posts.count, 1, code)
        }

        let known = Fake(reads: [.verified(account([ownState(), state(otherId, status: .revoked, revokedAtMs: 5, reason: .user)]))])
        let nothing = await run(known, target: otherId, reason: .user)
        XCTAssertEqual(nothing, .revoked(ownDevice: false))
        XCTAssertTrue(known.posts.isEmpty)
    }

    func testRefusals() async {
        func outcome(_ response: E2EEV2TransportResult<Data>) async -> E2EEAutoDeviceRevocation.Outcome {
            let fake = Fake(reads: [.verified(account([ownState(), state(otherId)]))])
            fake.responses = [response]
            return await run(fake, target: otherId, reason: .user)
        }
        let tooRecent = await outcome(Self.failure(403, "E2EE_DEVICE_TOO_RECENT"))
        XCTAssertEqual(tooRecent, .tooRecent)
        let notActive = await outcome(Self.failure(403, "E2EE_DEVICE_NOT_ACTIVE"))
        XCTAssertEqual(notActive, .notActive)
        let notFound = await outcome(Self.failure(404, "E2EE_DEVICE_NOT_FOUND"))
        XCTAssertEqual(notFound, .notFound)
        let revoked = await outcome(.failure(.init(
            kind: .permanent, statusCode: 403, code: "E2EE_DEVICE_REVOKED", message: "x", reason: "NOT_ME"
        )))
        XCTAssertEqual(revoked, .thisDeviceRevoked)
        let invalid = await outcome(Self.failure(400, "E2EE_DEVICE_REVOCATION_INVALID"))
        XCTAssertEqual(invalid, .failed("e2ee-auto-revocation-refused"))
        let unavailable = await outcome(Self.failure(503, "E2EE_AUTO_LOG_UNAVAILABLE"))
        XCTAssertEqual(unavailable, .retryLater)
        let forged = await outcome(.success(value: Data("{}".utf8), statusCode: 200, idempotentReplay: false))
        XCTAssertEqual(forged, .failed("invalid-e2ee-auto-revocation-response"))

        // Un appareil en attente ne révoque rien, et un journal refusé n'envoie rien.
        let pending = Fake(reads: [.verified(account([ownState(status: .pending), state(otherId)]))])
        let pendingOutcome = await run(pending, target: otherId, reason: .user)
        XCTAssertEqual(pendingOutcome, .notActive)
        let refused = Fake(reads: [.refused])
        let refusedOutcome = await run(refused, target: otherId, reason: .user)
        XCTAssertEqual(refusedOutcome, .logRefused)
        XCTAssertTrue(pending.posts.isEmpty && refused.posts.isEmpty)
    }

    // MARK: Écran

    @MainActor
    private func model(
        _ account: E2EEAutoLog.AccountState?, nowMs: Int64 = 100 * 24 * 3_600_000,
        revoke: @escaping (String, E2EEAutoLog.RevokeReason) async -> E2EEAutoDeviceRevocation.Outcome = { _, _ in .retryLater }
    ) -> E2EEAutoDevicesViewModel {
        let ownId = ownId
        return E2EEAutoDevicesViewModel(dependencies: .init(
            ownDeviceId: { ownId },
            readOwnAccount: { account.map { .verified($0) } ?? .refused },
            revoke: revoke,
            nowMs: { nowMs }
        ))
    }

    @MainActor
    func testScreenListsTheVerifiedDevicesThisOneFirst() async throws {
        let day: Int64 = 24 * 3_600_000
        let now = 100 * day
        let model = model(account([
            ownState(addedAtMs: 10 * day),
            state(otherId, platform: .android, addedAtMs: 50 * day),
            state("web_device_pending_00000", platform: .web, status: .pending, addedAtMs: 60 * day),
            state("web_device_gone_000000000", platform: .web, status: .revoked, addedAtMs: 2 * day, revokedAtMs: now - day, reason: .notMe),
            state("web_device_old_0000000000", platform: .web, status: .revoked, addedAtMs: day, revokedAtMs: now - 40 * day, reason: .user),
        ]), nowMs: now)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.map(\.id), [ownId, "web_device_pending_00000", otherId])
        XCTAssertEqual(model.revokedRows.map(\.id), ["web_device_gone_000000000"], "retirés depuis moins de 30 jours")
        XCTAssertTrue(model.canRevokeOthers)
        XCTAssertNil(model.hoursBeforeRevokingOthers)
        let expected = E2EEAutoSafetyCode.shortFingerprint(E2EEAutoSafetyCode.deviceFingerprint(
            userId: Self.userId, deviceId: ownId, signingKeyB64: ownDevice.publicSigningKeyB64
        ))
        XCTAssertEqual(model.rows.first?.shortFingerprint, expected)
        XCTAssertEqual(model.rows.first?.shortFingerprint.count, 4)
    }

    /// Garde des 24 h (§4.4) : aucun bouton vers les autres, l'heure restante à la place.
    @MainActor
    func testRecentDeviceExplainsInsteadOfRevoking() async {
        let now: Int64 = 100 * 24 * 3_600_000
        var revoked: [String] = []
        let model = model(account([ownState(addedAtMs: now - 5 * 3_600_000), state(otherId)]), nowMs: now) { id, _ in
            revoked.append(id)
            return .revoked(ownDevice: false)
        }
        await model.load()
        XCTAssertFalse(model.canRevokeOthers)
        XCTAssertEqual(model.hoursBeforeRevokingOthers, 19)
        await model.revoke(try! XCTUnwrap(model.rows.last), reason: .user)
        XCTAssertTrue(revoked.isEmpty, "rien n’est envoyé sous la garde")

        let pending = self.model(account([ownState(status: .pending), state(otherId)]), nowMs: now)
        await pending.load()
        XCTAssertFalse(pending.canRevokeOthers)
        XCTAssertNil(pending.hoursBeforeRevokingOthers)
    }

    @MainActor
    func testScreenPhasesAndOutcomes() async throws {
        let refused = model(nil)
        await refused.load()
        XCTAssertEqual(refused.phase, .refused)
        XCTAssertTrue(refused.rows.isEmpty)

        let absent = model(account([state(otherId)]))
        await absent.load()
        XCTAssertEqual(absent.phase, .notEnrolled)

        let selfRevoked = model(account([ownState(), state(otherId)])) { _, _ in .revoked(ownDevice: true) }
        await selfRevoked.load()
        await selfRevoked.revoke(try XCTUnwrap(selfRevoked.current), reason: .user)
        XCTAssertTrue(selfRevoked.signedOut)

        let notMe = model(account([ownState(), state(otherId)])) { _, _ in .revoked(ownDevice: false) }
        await notMe.load()
        await notMe.revoke(try XCTUnwrap(notMe.rows.last), reason: .notMe)
        XCTAssertEqual(notMe.confirmationMessage, String(localized: "Appareil retiré. Tes autres sessions ont été fermées : change ton mot de passe si quelqu’un d’autre le connaît."))
        XCTAssertFalse(notMe.signedOut)
    }
}
