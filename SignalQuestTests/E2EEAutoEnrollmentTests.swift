import CryptoKit
import XCTest
@testable import SignalQuest

/// Inscription automatique (E2EE-AUTO §4.1, §4.3) : vecteur `register-request-v1`,
/// puis le coordinateur contre un faux serveur et un faux journal.
final class E2EEAutoEnrollmentTests: XCTestCase {
    private static let userId = "user_alice_00000000001"

    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func link(for entry: String, seq: Int64) -> String {
        ["SQ-E2EE-AUTO-LOG-LINK", "1", String(seq), E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
         E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
    }

    private static func written(_ entry: String, seq: Int64, status: String? = nil) -> Data {
        var object: [String: Any] = [
            "entry": entry, "link": link(for: entry, seq: seq), "head": ["text": "t", "signatureB64": "s"],
        ]
        object["status"] = status
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Vecteur

    func testRegisterRequestVector() throws {
        let vectors = try load("register-request-v1")
        let bodyText = try XCTUnwrap(vectors["bodyUtf8"] as? String), body = Data(bodyText.utf8)
        let headers = try XCTUnwrap(vectors["headers"] as? [String: String])
        let method = try XCTUnwrap(vectors["method"] as? String), path = try XCTUnwrap(vectors["path"] as? String)
        XCTAssertEqual(path, E2EEAutoEnrollmentContract.registerPath)
        XCTAssertEqual(E2EEV2SignedRequest.bodySHA256Base64URL(body), vectors["bodySha256B64Url"] as? String)

        func canonical(_ body: Data, _ headers: [String: String]) throws -> String {
            String(decoding: try E2EEV2SignedRequest.canonicalRequest(
                method: method, path: path,
                timestampMs: try XCTUnwrap(Int64(try XCTUnwrap(headers[E2EEV2SignedRequest.headerTimestampMs]))),
                nonce: try XCTUnwrap(headers[E2EEV2SignedRequest.headerNonce]), body: body
            ), as: UTF8.self)
        }
        /// Ce que le serveur exige : la nouvelle clé de signature du corps, sur ces octets, pour ce `deviceId`.
        func accepted(_ body: Data, _ headers: [String: String]) throws -> Bool {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let signingKeyB64 = try XCTUnwrap(object["signingKeyB64"] as? String), payload = try canonical(body, headers)
            let signatureB64 = try XCTUnwrap(headers[E2EEV2SignedRequest.headerSignature])
            return headers[E2EEV2SignedRequest.headerDeviceId] == object["deviceId"] as? String
                && E2EEAutoLog.verify(publicKeyB64: signingKeyB64, payload: payload, signatureB64: signatureB64)
        }
        XCTAssertEqual(try canonical(body, headers), vectors["canonicalRequestUtf8"] as? String)
        XCTAssertTrue(try accepted(body, headers))
        for refused in try XCTUnwrap(vectors["refusedRequests"] as? [[String: Any]]) {
            let name = try XCTUnwrap(refused["name"] as? String)
            let refusedBody = Data(try XCTUnwrap(refused["bodyUtf8"] as? String).utf8)
            XCTAssertFalse(try accepted(refusedBody, try XCTUnwrap(refused["headers"] as? [String: String])), name)
        }

        // Le corps produit ici : les sept champs du §4.1, ni plus ni moins, et une signature de la nouvelle clé.
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let device = E2EEV2DeviceDescriptor(
            deviceId: try XCTUnwrap(expected["deviceId"] as? String), platform: try XCTUnwrap(expected["platform"] as? String),
            label: nil, publicIdentityKeyB64: try XCTUnwrap(expected["identityKeyB64"] as? String),
            publicSigningKeyB64: try XCTUnwrap(expected["signingKeyB64"] as? String),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
        let ours = try E2EEAutoEnrollmentContract.registrationBody(
            device: device, label: try XCTUnwrap(expected["label"] as? String), historyKeyPresent: false
        )
        XCTAssertEqual(try JSONSerialization.jsonObject(with: ours) as? NSDictionary, expected as NSDictionary)
        let key = try P256.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vectors["signingPrivateScalarB64"] as? String))))
        XCTAssertEqual(key.publicKey.x963Representation.base64EncodedString(), device.publicSigningKeyB64)
        var ourHeaders = headers
        ourHeaders[E2EEV2SignedRequest.headerSignature] = try E2EEV2LowS.sign(Data(try canonical(ours, headers).utf8), with: key).base64EncodedString()
        XCTAssertTrue(try accepted(ours, ourHeaders))

        // Les entrées écrites par le serveur, lues par le contrôle local de la réponse.
        let add = try XCTUnwrap(vectors["addEntryUtf8"] as? String), addPending = try XCTUnwrap(vectors["addPendingEntryUtf8"] as? String)
        let seq = try XCTUnwrap((vectors["entryContext"] as? [String: Any])?["seq"] as? NSNumber).int64Value
        let userId = try XCTUnwrap(vectors["userId"] as? String)
        XCTAssertEqual(E2EEAutoEnrollmentContract.parseRegistration(Self.written(add, seq: seq, status: "ACTIVE"), userId: userId, device: device)?.status, .active)
        XCTAssertEqual(E2EEAutoEnrollmentContract.parseRegistration(Self.written(addPending, seq: seq, status: "PENDING"), userId: userId, device: device)?.status, .pending)
        XCTAssertNil(E2EEAutoEnrollmentContract.parseRegistration(Self.written(addPending, seq: seq, status: "ACTIVE"), userId: userId, device: device))
        XCTAssertNil(E2EEAutoEnrollmentContract.parseRegistration(Self.written(add, seq: seq + 1, status: "ACTIVE"), userId: userId, device: device),
                     "maillon d'un autre seq")
        XCTAssertNil(E2EEAutoEnrollmentContract.parseRegistration(Self.written(add, seq: seq, status: "ACTIVE"), userId: "user_bob_0000000000002", device: device))
        let rotated = E2EEV2DeviceDescriptor(
            deviceId: device.deviceId, platform: device.platform, label: nil, publicIdentityKeyB64: device.publicIdentityKeyB64,
            publicSigningKeyB64: device.publicSigningKeyB64, identityKeyAlgorithm: device.identityKeyAlgorithm,
            signingKeyAlgorithm: device.signingKeyAlgorithm, keyVersion: 2
        )
        XCTAssertNil(E2EEAutoEnrollmentContract.parseRegistration(Self.written(add, seq: seq, status: "ACTIVE"), userId: userId, device: rotated),
                     "autre keyVersion")
    }

    func testLabelAndPolicy() {
        XCTAssertEqual(E2EEAutoEnrollmentContract.label(isPad: false), "iPhone")
        XCTAssertEqual(E2EEAutoEnrollmentContract.label(isPad: true), "iPad")
        func action(_ status: Int, _ code: String?, reason: String? = nil, keyVersion: Int = 1) -> E2EEAutoEnrollmentPolicy.Action {
            E2EEAutoEnrollmentPolicy.action(for: E2EEV2TransportFailure(
                kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x",
                reason: reason
            ), keyVersion: keyVersion)
        }
        XCTAssertEqual(action(409, "E2EE_DEVICE_KEY_MISMATCH"), .newIdentity)
        XCTAssertEqual(action(403, "E2EE_DEVICE_REVOKED", reason: "INACTIVE"), .newIdentity)
        XCTAssertEqual(action(403, "E2EE_DEVICE_REVOKED", reason: "ACCOUNT_DELETED"), .accountDeleted)
        for reason in [E2EEAutoLog.RevokeReason.user, .notMe, .emailNotMe, .admin] {
            XCTAssertEqual(action(403, "E2EE_DEVICE_REVOKED", reason: reason.rawValue), .revoked(reason))
        }
        XCTAssertEqual(action(403, "E2EE_DEVICE_REVOKED"), .revoked(nil), "raison absente : aucune réinscription")
        XCTAssertEqual(action(403, "E2EE_DEVICE_REVOKED", reason: "LATER"), .revoked(nil))
        XCTAssertEqual(action(400, "E2EE_DEVICE_REGISTRATION_INVALID", keyVersion: 2), .newIdentity)
        XCTAssertEqual(action(409, "E2EE_LOG_STALE"), .rereadAndResign)
        XCTAssertEqual(action(426, "E2EE_UPDATE_REQUIRED"), .updateRequired)
        XCTAssertEqual(action(401, "E2EE_DEVICE_SIGNATURE_INVALID"), .reauthenticate)
        XCTAssertEqual(action(429, "E2EE_DEVICE_REGISTRATION_RATE_LIMITED"), .retryLater)
        XCTAssertEqual(action(503, nil), .retryLater)
        XCTAssertEqual(action(400, "E2EE_DEVICE_REGISTRATION_INVALID"), .failed)

        // Révision 8 : réponses communes des routes `auto` signées.
        XCTAssertEqual(action(403, "E2EE_DEVICE_SIGNATURE_INVALID"), .failed, "403 : refus définitif, pas une session expirée")
        XCTAssertEqual(action(403, "E2EE_REQUEST_TIMESTAMP_INVALID"), .retryLater)
        XCTAssertEqual(action(404, "E2EE_SIGNER_DEVICE_NOT_FOUND"), .signerNotFound)
        XCTAssertEqual(action(409, "E2EE_REQUEST_REPLAYED"), .rereadAndResign)
        XCTAssertEqual(action(428, "E2EE_MANAGED_SESSION_REQUIRED"), .refreshSession)
        XCTAssertEqual(action(400, "E2EE_DEVICE_REQUEST_INVALID"), .failed)
        XCTAssertEqual(action(400, "E2EE_DEVICE_ROTATION_INVALID"), .failed)
        XCTAssertEqual(action(503, "E2EE_AUTO_LOG_UNAVAILABLE"), .logClosed(retryAfterSeconds: 900))
        XCTAssertEqual(E2EEAutoEnrollmentPolicy.action(for: E2EEV2TransportFailure(
            kind: .retryable, statusCode: 503, code: "E2EE_AUTO_LOG_UNAVAILABLE", message: "x", retryAfterSeconds: 1_800
        )), .logClosed(retryAfterSeconds: 1_800))
    }

    // MARK: Coordinateur

    private struct Keys {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        let next = P256.KeyAgreement.PrivateKey()
        let deviceId: String

        func device(keyVersion: Int = 1, identity: P256.KeyAgreement.PrivateKey? = nil) -> E2EEV2DeviceDescriptor {
            E2EEV2DeviceDescriptor(
                deviceId: deviceId, platform: "ios", label: nil,
                publicIdentityKeyB64: (identity ?? agreement).publicKey.x963Representation.base64EncodedString(),
                publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
                signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: keyVersion
            )
        }

        var rotation: E2EEV2DeviceIdentityStore.AgreementKeyRotation {
            .init(deviceId: deviceId, keyVersion: 2, identityKeyB64: next.publicKey.x963Representation.base64EncodedString(), createdAtMs: 1)
        }
    }

    /// Faux appareil, serveur et journal : un appel à la fois, dans l'ordre des tests.
    private final class Fake: @unchecked Sendable {
        var identities: [Keys]
        var current = 0
        var rotationDue = false
        var activated: [E2EEV2DeviceIdentityStore.AgreementKeyRotation] = []
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        var responses: [E2EEV2TransportResult<Data>] = []
        private(set) var posts: [(path: String, body: [String: Any])] = []
        var revocation: E2EEAutoEnrollment.Revocation?
        private(set) var deviceReads = 0
        private(set) var clockOffsets: [Int64] = []
        let nowMs: Int64 = 1_000_000

        init(identities: Int = 2, reads: [E2EEAutoEnrollment.OwnAccount]) {
            self.identities = (0..<identities).map { Keys(deviceId: "ios_device_\($0)_00000000000000") }
            self.reads = reads
        }

        var keys: Keys { identities[current] }

        func dependencies() -> E2EEAutoEnrollment.Dependencies {
            .init(
                userId: E2EEAutoEnrollmentTests.userId, label: "iPhone",
                device: { [self] in
                    deviceReads += 1
                    let keys = self.keys
                    return activated.isEmpty ? keys.device() : keys.device(keyVersion: 2, identity: keys.next)
                },
                resetDevice: { [self] in current += 1 },
                dueRotation: { [self] in rotationDue && activated.isEmpty ? keys.rotation : nil },
                activateRotation: { [self] in activated.append($0) },
                sign: { [self] in try E2EEV2LowS.sign($0, with: keys.signing) },
                post: { [self] path, body, clockOffsetMs in
                    posts.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
                    clockOffsets.append(clockOffsetMs)
                    return responses.isEmpty ? .failure(.init(kind: .retryable, statusCode: 503, message: "x")) : responses.removeFirst()
                },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                revocation: { [self] in revocation },
                recordRevocation: { [self] in revocation = $0 },
                nowMs: { [self] in nowMs }
            )
        }
    }

    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()

    private static func account(_ devices: [E2EEAutoLog.DeviceState], lastEntryHash: String = E2EEAutoLog.digest("last")) -> E2EEAutoLog.AccountState {
        var state = E2EEAutoLog.AccountState(userId: userId, accountSaltB64: salt)
        for device in devices { state.devices[device.deviceId] = device }
        state.lastEntryHash = lastEntryHash
        return state
    }

    private static func state(
        _ device: E2EEV2DeviceDescriptor, status: E2EEAutoLog.DeviceStatus = .active,
        signingKeyB64: String? = nil, revokeReason: E2EEAutoLog.RevokeReason? = nil
    ) -> E2EEAutoLog.DeviceState {
        E2EEAutoLog.DeviceState(
            deviceId: device.deviceId, platform: .ios, identityKeyB64: device.publicIdentityKeyB64,
            signingKeyB64: signingKeyB64 ?? device.publicSigningKeyB64, keyVersion: device.keyVersion, status: status,
            addedAtMs: 1, activatedAtMs: status == .pending ? nil : 1, addEntryHash: E2EEAutoLog.digest("add"),
            identityKeys: [.init(keyVersion: device.keyVersion, identityKeyB64: device.publicIdentityKeyB64, sinceMs: 1)],
            revokeReason: revokeReason, revokeSeq: revokeReason == nil ? nil : 9, revokedAtMs: revokeReason == nil ? nil : 1
        )
    }

    private static func addEntry(_ device: E2EEV2DeviceDescriptor, pending: Bool = false) -> String {
        E2EEAutoLog.Entry(
            seq: 20, userId: userId, prevUserEntryHash: E2EEAutoLog.none, op: pending ? .addPending : .add, deviceId: device.deviceId,
            platform: "ios", identityKeyB64: device.publicIdentityKeyB64, signingKeyB64: device.publicSigningKeyB64,
            keyVersion: String(device.keyVersion), detail: E2EEAutoLog.none, createdAtMs: 5
        ).canonical
    }

    private static func failure(
        _ status: Int, _ code: String, reason: String? = nil, details: [String: JSONValue]? = nil
    ) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x",
            details: details, reason: reason
        ))
    }

    func testRegistersWhenAbsentFromLogOrLogInconclusive() async throws {
        for read in [E2EEAutoEnrollment.OwnAccount.verified(Self.account([])), .inconclusive] {
            let fake = Fake(reads: [read])
            let device = fake.keys.device()
            fake.responses = [.success(value: Self.written(Self.addEntry(device), seq: 20, status: "ACTIVE"), statusCode: 201, idempotentReplay: false)]
            let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(outcome, .registered(deviceId: device.deviceId, status: .active))
            XCTAssertEqual(fake.posts.map(\.path), [E2EEAutoEnrollmentContract.registerPath])
            XCTAssertEqual(fake.posts.first?.body["historyKey"] as? String, "absent")
            XCTAssertEqual(fake.posts.first?.body["keyVersion"] as? Int, 1)
        }
    }

    func testRefusedLogWritesNothing() async {
        let fake = Fake(reads: [.refused])
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .logRefused)
        XCTAssertTrue(fake.posts.isEmpty)
    }

    func testKeyMismatchOrInactivityReplacesTheIdentity() async throws {
        // 409 du serveur : identité effacée, puis un nouveau passage inscrit la suivante.
        let mismatch = Fake(reads: [.verified(Self.account([]))])
        let second = mismatch.identities[1].device()
        mismatch.responses = [
            Self.failure(409, "E2EE_DEVICE_KEY_MISMATCH"),
            .success(value: Self.written(Self.addEntry(second), seq: 20, status: "ACTIVE"), statusCode: 201, idempotentReplay: false),
        ]
        let replaced = await E2EEAutoEnrollment(mismatch.dependencies()).run()
        XCTAssertEqual(replaced, .identityReplaced)
        XCTAssertEqual(mismatch.current, 1)
        let registered = await E2EEAutoEnrollment(mismatch.dependencies()).run()
        XCTAssertEqual(registered, .registered(deviceId: second.deviceId, status: .active))

        // Journal : retiré pour inactivité, ou même deviceId sous d'autres clés ;
        // serveur : 403 INACTIVE, ou 400 pour une keyVersion reprise inconnue du journal.
        for judged in [
            { (device: E2EEV2DeviceDescriptor) in Self.state(device, status: .revoked, revokeReason: .inactive) },
            { (device: E2EEV2DeviceDescriptor) in Self.state(device, signingKeyB64: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()) },
        ] {
            let fake = Fake(reads: [])
            fake.reads = [.verified(Self.account([judged(fake.keys.device())]))]
            let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(outcome, .identityReplaced)
            XCTAssertEqual(fake.current, 1)
            XCTAssertTrue(fake.posts.isEmpty)
            XCTAssertNil(fake.revocation)
        }
        let inactive = Fake(reads: [.inconclusive])
        inactive.responses = [Self.failure(403, "E2EE_DEVICE_REVOKED", reason: "INACTIVE")]
        let afterInactive = await E2EEAutoEnrollment(inactive.dependencies()).run()
        XCTAssertEqual(afterInactive, .identityReplaced)
        XCTAssertNil(inactive.revocation)

        let resumed = Fake(reads: [.inconclusive])
        resumed.activated = [resumed.keys.rotation]
        resumed.responses = [Self.failure(400, "E2EE_DEVICE_REGISTRATION_INVALID")]
        let afterInvalid = await E2EEAutoEnrollment(resumed.dependencies()).run()
        XCTAssertEqual(afterInvalid, .identityReplaced)
        XCTAssertEqual(resumed.posts.first?.body["keyVersion"] as? Int, 2)
        let fresh = Fake(reads: [.inconclusive])
        fresh.responses = [Self.failure(400, "E2EE_DEVICE_REGISTRATION_INVALID")]
        let refused = await E2EEAutoEnrollment(fresh.dependencies()).run()
        XCTAssertEqual(refused, .failed("e2ee-auto-request-refused"), "keyVersion 1 refusée : pas de nouvelle identité")
        XCTAssertEqual(fresh.current, 0)

        // Compte supprimé : rien.
        let deleted = Fake(reads: [])
        deleted.reads = [.verified(Self.account([Self.state(deleted.keys.device(), status: .revoked, revokeReason: .accountDeleted)]))]
        let outcome = await E2EEAutoEnrollment(deleted.dependencies()).run()
        XCTAssertEqual(outcome, .accountDeleted)
        XCTAssertTrue(deleted.posts.isEmpty)
        XCTAssertEqual(deleted.current, 0)
    }

    /// §4.3 : USER, NOT_ME, EMAIL_NOT_ME, ADMIN (ou sans raison) purgent les clés,
    /// et rien ne se réinscrit avant une nouvelle connexion.
    func testRevocationPurgesAndWaitsForANewConnection() async throws {
        for reason in [E2EEAutoLog.RevokeReason.user, .notMe, .emailNotMe, .admin, nil] {
            let fake = Fake(reads: [])
            fake.reads = [.verified(Self.account([Self.state(fake.keys.device(), status: .revoked, revokeReason: reason)]))]
            let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(outcome, .revoked(reason))
            XCTAssertEqual(fake.current, 1, "clés purgées")
            XCTAssertEqual(fake.revocation, .init(reason: reason))
            XCTAssertTrue(fake.posts.isEmpty)

            // Même connexion : ni identité recréée, ni lecture, ni envoi.
            let (reads, devices) = (fake.readCount, fake.deviceReads)
            let again = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(again, .revoked(reason))
            XCTAssertEqual(fake.readCount, reads)
            XCTAssertEqual(fake.deviceReads, devices)
            XCTAssertTrue(fake.posts.isEmpty)
        }

        // Le serveur le sait avant le journal relu : 403 à l'inscription.
        let registering = Fake(reads: [.inconclusive])
        registering.responses = [Self.failure(403, "E2EE_DEVICE_REVOKED", reason: "NOT_ME")]
        let refused = await E2EEAutoEnrollment(registering.dependencies()).run()
        XCTAssertEqual(refused, .revoked(.notMe))
        XCTAssertEqual(registering.revocation, .init(reason: .notMe))
        XCTAssertEqual(registering.current, 1)

        // Et à la rotation.
        let rotating = Fake(reads: [])
        rotating.reads = [.verified(Self.account([Self.state(rotating.keys.device())]))]
        rotating.rotationDue = true
        rotating.responses = [Self.failure(403, "E2EE_DEVICE_REVOKED", reason: "ADMIN")]
        let duringRotation = await E2EEAutoEnrollment(rotating.dependencies()).run()
        XCTAssertEqual(duringRotation, .revoked(.admin))
        XCTAssertEqual(rotating.revocation, .init(reason: .admin))
        XCTAssertTrue(rotating.activated.isEmpty)
    }

    func testRevocationMarkerHoldsUntilANewConnection() throws {
        let store = InMemoryTokenStore(), namespace = "ns"
        XCTAssertNil(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: namespace, authToken: "cookie-a"))
        try E2EEAutoRevocationMarker.record(.init(reason: .notMe), store: store, ownerNamespace: namespace, authToken: "cookie-a")
        let stored = try XCTUnwrap(store.string(for: E2EEAutoRevocationMarker.key(ownerNamespace: namespace)))
        XCTAssertFalse(stored.contains("cookie-a"), "empreinte seulement")
        XCTAssertEqual(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: namespace, authToken: "cookie-a"), .init(reason: .notMe))
        XCTAssertEqual(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: namespace, authToken: nil), .init(reason: .notMe),
                       "sans connexion : gardée")
        XCTAssertNil(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: "other", authToken: "cookie-a"))
        XCTAssertNil(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: namespace, authToken: "cookie-b"), "nouvelle connexion")
        XCTAssertNil(try store.string(for: E2EEAutoRevocationMarker.key(ownerNamespace: namespace)))
        try E2EEAutoRevocationMarker.record(.init(reason: nil), store: store, ownerNamespace: namespace, authToken: "cookie-b")
        XCTAssertEqual(E2EEAutoRevocationMarker.read(store: store, ownerNamespace: namespace, authToken: "cookie-b"), .init(reason: nil))
        XCTAssertThrowsError(try E2EEAutoRevocationMarker.record(.init(reason: .user), store: store, ownerNamespace: namespace, authToken: nil))
    }

    func testServerRefusals() async {
        for (response, expected) in [
            (Self.failure(426, "E2EE_UPDATE_REQUIRED"), E2EEAutoEnrollment.Outcome.updateRequired),
            (Self.failure(401, "E2EE_DEVICE_SIGNATURE_INVALID"), .reauthenticate),
            (Self.failure(429, "E2EE_DEVICE_REGISTRATION_RATE_LIMITED"), .retryLater),
            (Self.failure(403, "E2EE_DEVICE_REVOKED", reason: "ACCOUNT_DELETED"), .accountDeleted),
            (Self.failure(428, "E2EE_MANAGED_SESSION_REQUIRED"), .sessionRefreshRequired),
            (Self.failure(503, "E2EE_AUTO_LOG_UNAVAILABLE"), .logClosed(retryAfterSeconds: 900)),
            (Self.failure(403, "E2EE_DEVICE_SIGNATURE_INVALID"), .failed("e2ee-auto-request-refused")),
        ] {
            let fake = Fake(reads: [.inconclusive])
            fake.responses = [response]
            let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(outcome, expected)
        }
    }

    private static func rotateEntry(_ keys: Keys, prev: String) throws -> String {
        let rotation = keys.rotation
        let payload = E2EEAutoEnrollmentContract.rotationPayload(userId: userId, prevUserEntryHash: prev, rotation: rotation)
        let signature = try E2EEV2LowS.sign(Data(payload.utf8), with: keys.signing).base64EncodedString()
        return E2EEAutoLog.Entry(
            seq: 21, userId: userId, prevUserEntryHash: prev, op: .rotate, deviceId: keys.deviceId, platform: E2EEAutoLog.none,
            identityKeyB64: rotation.identityKeyB64, signingKeyB64: E2EEAutoLog.none, keyVersion: "2", detail: signature, createdAtMs: 6
        ).canonical
    }

    func testActiveDeviceRotatesWhenDue() async throws {
        let quiet = Fake(reads: [])
        quiet.reads = [.verified(Self.account([Self.state(quiet.keys.device())]))]
        let idle = await E2EEAutoEnrollment(quiet.dependencies()).run()
        XCTAssertEqual(idle, .active(deviceId: quiet.keys.deviceId, rotated: false))
        XCTAssertTrue(quiet.posts.isEmpty)

        let fake = Fake(reads: [])
        let prev = E2EEAutoLog.digest("last")
        fake.reads = [.verified(Self.account([Self.state(fake.keys.device())], lastEntryHash: prev))]
        fake.rotationDue = true
        fake.responses = [.success(value: Self.written(try Self.rotateEntry(fake.keys, prev: prev), seq: 21), statusCode: 200, idempotentReplay: false)]
        let rotated = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(rotated, .active(deviceId: fake.keys.deviceId, rotated: true))
        XCTAssertEqual(fake.activated, [fake.keys.rotation])
        let body = try XCTUnwrap(fake.posts.first)
        XCTAssertEqual(body.path, E2EEAutoEnrollmentContract.rotatePath(deviceId: fake.keys.deviceId))
        XCTAssertEqual(Set(body.body.keys), ["prevUserEntryHash", "identityKeyB64", "keyVersion", "signatureB64"])
        XCTAssertEqual(body.body["prevUserEntryHash"] as? String, prev)
    }

    func testPendingDeviceRotatesToo() async throws {
        let fake = Fake(reads: [])
        let prev = E2EEAutoLog.digest("last")
        fake.reads = [.verified(Self.account([Self.state(fake.keys.device(), status: .pending)], lastEntryHash: prev))]
        fake.rotationDue = true
        fake.responses = [.success(value: Self.written(try Self.rotateEntry(fake.keys, prev: prev), seq: 21), statusCode: 200, idempotentReplay: false)]
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .pending(deviceId: fake.keys.deviceId))
        XCTAssertEqual(fake.activated.count, 1)
    }

    func testStaleLogIsRereadAndResigned() async throws {
        let fake = Fake(reads: [])
        let first = E2EEAutoLog.digest("first"), second = E2EEAutoLog.digest("second")
        let device = fake.keys.device()
        fake.reads = [.verified(Self.account([Self.state(device)], lastEntryHash: first)), .verified(Self.account([Self.state(device)], lastEntryHash: second))]
        fake.rotationDue = true
        fake.responses = [
            Self.failure(409, "E2EE_LOG_STALE"),
            .success(value: Self.written(try Self.rotateEntry(fake.keys, prev: second), seq: 21), statusCode: 200, idempotentReplay: false),
        ]
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .active(deviceId: device.deviceId, rotated: true))
        XCTAssertEqual(fake.posts.map { $0.body["prevUserEntryHash"] as? String }, [first, second])
    }

    /// Réponse perdue : le journal porte déjà la nouvelle clé, elle passe en service sans nouvel envoi.
    func testLostRotationResponseIsRecoveredFromTheLog() async throws {
        let fake = Fake(reads: [])
        let device = fake.keys.device(), rotation = fake.keys.rotation
        var state = Self.state(device)
        state.identityKeyB64 = rotation.identityKeyB64
        state.keyVersion = 2
        state.identityKeys.append(.init(keyVersion: 2, identityKeyB64: rotation.identityKeyB64, sinceMs: 2))
        fake.reads = [.verified(Self.account([state]))]
        fake.rotationDue = true
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .active(deviceId: device.deviceId, rotated: true))
        XCTAssertEqual(fake.activated, [rotation])
        XCTAssertTrue(fake.posts.isEmpty)
    }

    // MARK: Révision 8

    /// Horodatage refusé : l'heure du serveur corrige l'écart, une seule nouvelle signature.
    func testTimestampRefusalResignsOnceAtServerTime() async throws {
        let fake = Fake(reads: [.inconclusive])
        let device = fake.keys.device(), serverTimeMs = fake.nowMs + 600_000
        let refusal = Self.failure(403, "E2EE_REQUEST_TIMESTAMP_INVALID", details: ["serverTimeMs": .number(Double(serverTimeMs))])
        fake.responses = [refusal, .success(value: Self.written(Self.addEntry(device), seq: 20, status: "ACTIVE"), statusCode: 201, idempotentReplay: false)]
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .registered(deviceId: device.deviceId, status: .active))
        XCTAssertEqual(fake.clockOffsets, [0, 600_000])

        let twice = Fake(reads: [.inconclusive])
        twice.responses = [refusal, refusal]
        let refusedTwice = await E2EEAutoEnrollment(twice.dependencies()).run()
        XCTAssertEqual(refusedTwice, .retryLater)
        XCTAssertEqual(twice.posts.count, 2, "une seule nouvelle signature")

        let unreadable = Fake(reads: [.inconclusive])
        unreadable.responses = [Self.failure(403, "E2EE_REQUEST_TIMESTAMP_INVALID")]
        let withoutTime = await E2EEAutoEnrollment(unreadable.dependencies()).run()
        XCTAssertEqual(withoutTime, .retryLater)
        XCTAssertEqual(unreadable.posts.count, 1, "sans serverTimeMs, aucun nouvel essai")
    }

    /// Nonce déjà servi : l'inscription est peut-être écrite, le journal relu le dit.
    func testReplayedRegistrationIsReadBackFromTheLog() async throws {
        let written = Fake(reads: [])
        let device = written.keys.device()
        written.reads = [.inconclusive, .verified(Self.account([Self.state(device)]))]
        written.responses = [Self.failure(409, "E2EE_REQUEST_REPLAYED")]
        let found = await E2EEAutoEnrollment(written.dependencies()).run()
        XCTAssertEqual(found, .active(deviceId: device.deviceId, rotated: false))
        XCTAssertEqual(written.posts.count, 1, "rien de renvoyé : l'appareil est au journal")

        let lost = Fake(reads: [])
        let lostDevice = lost.keys.device()
        lost.reads = [.inconclusive, .verified(Self.account([]))]
        lost.responses = [
            Self.failure(409, "E2EE_REQUEST_REPLAYED"),
            .success(value: Self.written(Self.addEntry(lostDevice), seq: 20, status: "ACTIVE"), statusCode: 201, idempotentReplay: false),
        ]
        let resent = await E2EEAutoEnrollment(lost.dependencies()).run()
        XCTAssertEqual(resent, .registered(deviceId: lostDevice.deviceId, status: .active))
        XCTAssertEqual(lost.posts.count, 2)

        let unknown = Fake(reads: [.inconclusive])
        unknown.responses = [Self.failure(409, "E2EE_REQUEST_REPLAYED")]
        let unread = await E2EEAutoEnrollment(unknown.dependencies()).run()
        XCTAssertEqual(unread, .retryLater, "journal illisible : pas de nouvel envoi à l'aveugle")
        XCTAssertEqual(unknown.posts.count, 1)
    }

    /// `404 E2EE_SIGNER_DEVICE_NOT_FOUND` seul n'efface jamais les clés.
    func testSignerNotFoundForgetsKeysOnlyWhenTheVerifiedLogAgrees() async throws {
        for (secondRead, expected, resets) in [
            (E2EEAutoEnrollment.OwnAccount.verified(Self.account([])), E2EEAutoEnrollment.Outcome.identityReplaced, 1),
            (.inconclusive, .retryLater, 0),
        ] {
            let fake = Fake(reads: [])
            fake.reads = [.verified(Self.account([Self.state(fake.keys.device())])), secondRead]
            fake.rotationDue = true
            fake.responses = [Self.failure(404, "E2EE_SIGNER_DEVICE_NOT_FOUND")]
            let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(fake.current, resets)
        }
        let stillThere = Fake(reads: [])
        let state = Self.state(stillThere.keys.device())
        stillThere.reads = [.verified(Self.account([state])), .verified(Self.account([state]))]
        stillThere.rotationDue = true
        stillThere.responses = [Self.failure(404, "E2EE_SIGNER_DEVICE_NOT_FOUND")]
        let kept = await E2EEAutoEnrollment(stillThere.dependencies()).run()
        XCTAssertEqual(kept, .retryLater)
        XCTAssertEqual(stillThere.current, 0, "au journal : clés gardées")
    }

    /// Rotation rejouée dont la réponse s'est perdue : la relecture y trouve le `ROTATE`.
    func testReplayedRotationIsRecoveredFromTheLog() async throws {
        let fake = Fake(reads: [])
        let device = fake.keys.device(), rotation = fake.keys.rotation
        var rotated = Self.state(device)
        rotated.identityKeyB64 = rotation.identityKeyB64
        rotated.keyVersion = 2
        rotated.identityKeys.append(.init(keyVersion: 2, identityKeyB64: rotation.identityKeyB64, sinceMs: 2))
        fake.reads = [.verified(Self.account([Self.state(device)])), .verified(Self.account([rotated]))]
        fake.rotationDue = true
        fake.responses = [Self.failure(409, "E2EE_REQUEST_REPLAYED")]
        let outcome = await E2EEAutoEnrollment(fake.dependencies()).run()
        XCTAssertEqual(outcome, .active(deviceId: device.deviceId, rotated: true))
        XCTAssertEqual(fake.activated, [rotation])
        XCTAssertEqual(fake.posts.count, 1)
    }

    func testRotationResponseIsChecked() throws {
        let keys = Keys(deviceId: "ios_device_x_00000000000000"), prev = E2EEAutoLog.digest("last")
        let entry = try Self.rotateEntry(keys, prev: prev)
        let signingKeyB64 = keys.signing.publicKey.x963Representation.base64EncodedString()
        func parse(_ data: Data, prev: String = prev, signingKeyB64: String = signingKeyB64) -> Bool {
            E2EEAutoEnrollmentContract.parseRotation(data, userId: Self.userId, prevUserEntryHash: prev, rotation: keys.rotation, signingKeyB64: signingKeyB64)
        }
        XCTAssertTrue(parse(Self.written(entry, seq: 21)))
        XCTAssertFalse(parse(Self.written(entry, seq: 21), prev: E2EEAutoLog.digest("other")), "autre état signé")
        XCTAssertFalse(parse(Self.written(entry, seq: 21), signingKeyB64: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()),
                       "signée par une autre clé")
        XCTAssertFalse(parse(Self.written(entry, seq: 22)), "maillon d'un autre seq")
    }
}
