import CryptoKit
import ImageIO
import Security
import XCTest
@testable import SignalQuest

final class E2EETests: XCTestCase {
    func testLegacyE2EEWritePolicyAllowsOnlyTextUntilV2RuntimeIsVerified() {
        for feature in LegacyE2EEWriteFeature.allCases {
            XCTAssertEqual(
                LegacyE2EEWritePolicy.isAllowed(e2eeEnabled: true, feature: feature),
                feature == .text,
                "Le runtime E2EE hérité ne doit accepter que le texte chiffré"
            )
            XCTAssertTrue(
                LegacyE2EEWritePolicy.isAllowed(e2eeEnabled: false, feature: feature),
                "Une conversation non E2EE conserve ses fonctions existantes"
            )
        }
    }

    func testLegacyE2EEWritePolicyFailsClosedWithExplicitReason() {
        XCTAssertThrowsError(
            try LegacyE2EEWritePolicy.requireAllowed(
                e2eeEnabled: true,
                feature: .location
            )
        ) { error in
            XCTAssertEqual(
                error as? E2EEError,
                .unsupported(LegacyE2EEWritePolicy.v2RequiredMessage)
            )
        }
    }

    private struct SignedRequestFixture: Decodable {
        let method: String
        let path: String
        let timestampMs: Int64
        let nonce: String
        let bodyUtf8: String
        let bodySha256B64Url: String
        let canonicalRequestUtf8: String
        let publicSigningKeyB64: String
        let signatureDerB64: String
    }

    private struct EpochFixture: Decodable {
        let conversationId: String
        let epochNumber: Int
        let senderDeviceId: String
        let recipientDeviceId: String
        let wrapAlgorithm: String
        let recipientPrivateRawB64: String
        let recipientPublicX963B64: String
        let ephemeralPrivateRawB64: String
        let ephemeralPublicX963B64: String
        let sharedSecretB64: String
        let epochKeyB64: String
        let keyCommitmentB64: String
        let saltCanonicalUtf8: String
        let saltB64: String
        let derivedKeyB64: String
        let nonceB64: String
        let aadUtf8: String
        let aadB64: String
        let wrappedEpochKeyB64: String
        let signatureCanonicalUtf8: String
        let senderPublicSigningKeyB64: String
        let signatureDerB64: String
    }

    private struct MessageFixture: Decodable {
        let conversationId: String
        let epochNumber: Int
        let senderDeviceId: String
        let clientRequestId: String
        let ttlSeconds: Int
        let encryptedBlobIds: [String]
        let algorithm: String
        let contentType: String
        let epochKeyB64: String
        let keyCommitmentB64: String
        let saltCanonicalUtf8: String
        let saltB64: String
        let derivedKeyB64: String
        let nonceB64: String
        let cleartextUtf8: String
        let aadUtf8: String
        let aadB64: String
        let ciphertextB64: String
        let signatureCanonicalUtf8: String
        let senderPublicSigningKeyB64: String
        let senderSignatureDerB64: String
    }

    private struct BlobFixture: Decodable {
        let blobId: String
        let algorithm: String
        let kdfInfo: String
        let mediaKeyB64: String
        let noncePrefixB64: String
        let plaintextChunksB64: [String]
        let saltCanonicalUtf8: String
        let saltB64: String
        let derivedKeyB64: String
        let chunkAadUtf8: [String]
        let ciphertextChunksB64: [String]
        let ciphertextB64: String
        let plaintextSha256: String
        let ciphertextSha256: String
        let plaintextSize: Int
        let ciphertextSize: Int
    }

    private struct CallFrameKeyFixture: Decodable {
        let conversationId: String
        let epochNumber: Int
        let callId: String
        let epochKeyB64: String
        let saltCanonicalUtf8: String
        let saltB64: String
        let kdfInfo: String
        let frameKeyB64: String
        let liveKitSharedPassphrase: String
    }

    private struct HistoryMigrationFixture: Decodable {
        let version: Int
        let source: E2EEV2LegacyMessageSource
        let canonicalSourceB64: String
        let sourceHash: String
        let clientRequestId: String
    }

    private struct DeviceApprovalFixture: Decodable {
        struct Challenge: Decodable {
            let challengeB64Url: String
            let payload: String?
        }

        struct Proximity: Decodable {
            let code: String
            let formattedCode: String
        }

        let approvalId: String
        let pendingDeviceId: String
        let expiresAtMs: Int64
        let qr: Challenge
        let push: Challenge
        let proximity: Proximity
    }

    private func signedRequestFixture() throws -> SignedRequestFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/signed-request-v1.json")
        return try JSONDecoder().decode(SignedRequestFixture.self, from: Data(contentsOf: url))
    }

    private func epochFixture() throws -> EpochFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/epoch-envelope-v1.json")
        return try JSONDecoder().decode(EpochFixture.self, from: Data(contentsOf: url))
    }

    private func epochDeliveryData(_ fixture: EpochFixture) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 2,
            "conversationId": fixture.conversationId,
            "epoch": [
                "epochId": "epoch_0000000000000001",
                "epochNumber": fixture.epochNumber,
                "algorithm": "AES_256_GCM_HKDF_SHA256",
                "keyCommitmentB64": fixture.keyCommitmentB64,
                "reason": "INITIAL",
                "status": "active",
                "createdAt": "2026-08-23T00:00:00.000Z",
            ],
            "senderDevice": [
                "deviceId": fixture.senderDeviceId,
                "publicSigningKeyB64": fixture.senderPublicSigningKeyB64,
            ],
            "envelope": [
                "recipientDeviceId": fixture.recipientDeviceId,
                "wrapAlgorithm": fixture.wrapAlgorithm,
                "ephemeralPublicKeyB64": fixture.ephemeralPublicX963B64,
                "wrappedEpochKeyB64": fixture.wrappedEpochKeyB64,
                "nonceB64": fixture.nonceB64,
                "aadB64": fixture.aadB64,
                "signatureB64": fixture.signatureDerB64,
            ],
        ])
    }

    private func messageFixture() throws -> MessageFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/message-envelope-v1.json")
        return try JSONDecoder().decode(MessageFixture.self, from: Data(contentsOf: url))
    }

    private func blobFixture() throws -> BlobFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/blob-chunks-v1.json")
        return try JSONDecoder().decode(BlobFixture.self, from: Data(contentsOf: url))
    }

    private func callFrameKeyFixture() throws -> CallFrameKeyFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/call-frame-key-v1.json")
        return try JSONDecoder().decode(CallFrameKeyFixture.self, from: Data(contentsOf: url))
    }

    private func historyMigrationFixture() throws -> HistoryMigrationFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/history-migration-v1.json")
        return try JSONDecoder().decode(HistoryMigrationFixture.self, from: Data(contentsOf: url))
    }

    private func deviceApprovalFixture() throws -> DeviceApprovalFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("contracts/e2ee-v2/device-approval-v1.json")
        return try JSONDecoder().decode(DeviceApprovalFixture.self, from: Data(contentsOf: url))
    }

    func testV2HistoryMigrationCanonicalizationMatchesCrossPlatformFixture() throws {
        let fixture = try historyMigrationFixture()
        XCTAssertEqual(fixture.version, E2EEV2HistoryMigrationContract.version)
        XCTAssertEqual(
            try E2EEV2HistoryMigrationContract.canonicalSource(fixture.source).base64EncodedString(),
            fixture.canonicalSourceB64
        )
        XCTAssertEqual(
            try E2EEV2HistoryMigrationContract.sourceHash(fixture.source),
            fixture.sourceHash
        )
        XCTAssertEqual(
            try E2EEV2HistoryMigrationContract.clientRequestId(
                messageId: fixture.source.messageId,
                sourceHash: fixture.sourceHash
            ),
            fixture.clientRequestId
        )

        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
    }

    func testV2DeviceIdentityIsStableScopedAndUsesP256X963() throws {
        let keychain = InMemoryTokenStore()
        let store = E2EEV2DeviceIdentityStore(tokenStore: keychain, allowsOwner: { _ in true })

        let first = try store.loadOrCreate(ownerNamespace: "account-a", label: "iPhone")
        let again = try store.loadOrCreate(ownerNamespace: "account-a", label: "Renamed")
        let other = try store.loadOrCreate(ownerNamespace: "account-b", label: "iPad")

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first.deviceId, other.deviceId)
        XCTAssertEqual(Data(base64Encoded: first.publicIdentityKeyB64)?.count, 65)
        XCTAssertEqual(Data(base64Encoded: first.publicSigningKeyB64)?.count, 65)
        XCTAssertEqual(first.identityKeyAlgorithm, "P256_X963_ECDH_HKDF_SHA256")
        XCTAssertEqual(first.signingKeyAlgorithm, "P256_X963_ECDSA_SHA256_DER")
    }

    func testV2DeviceRequestSignatureUsesDerAndVerifies() throws {
        let keychain = InMemoryTokenStore()
        let store = E2EEV2DeviceIdentityStore(tokenStore: keychain, allowsOwner: { _ in true })
        let descriptor = try store.loadOrCreate(ownerNamespace: "account-a")
        let payload = Data("SQ-E2EE-V2\nPOST\n/api/e2ee/v2/devices".utf8)
        let signature = try store.sign(canonicalRequest: payload, ownerNamespace: "account-a")
        let publicData = try XCTUnwrap(Data(base64Encoded: descriptor.publicSigningKeyB64))
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicData)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)

        XCTAssertTrue(publicKey.isValidSignature(parsed, for: payload))
    }

    func testV2DeviceInventoryRequiresIdentityBoundToListedDevice() throws {
        let store = E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let descriptor = try store.loadOrCreate(ownerNamespace: "account-inventory")
        let device: [String: Any] = [
            "deviceId": descriptor.deviceId,
            "platform": descriptor.platform,
            "label": descriptor.label ?? NSNull(),
            "publicIdentityKeyB64": descriptor.publicIdentityKeyB64,
            "publicSigningKeyB64": descriptor.publicSigningKeyB64,
            "identityKeyAlgorithm": descriptor.identityKeyAlgorithm,
            "signingKeyAlgorithm": descriptor.signingKeyAlgorithm,
            "keyVersion": descriptor.keyVersion,
            "status": "approved",
            "approvedAt": "2026-08-24T12:00:00.000Z",
            "revokedAt": NSNull(),
            "lastSeenAt": "2026-08-24T12:01:00.000Z",
            "createdAt": "2026-08-24T11:59:00.000Z",
        ]
        let identity: [String: Any] = [
            "generation": 2,
            "establishedByDeviceId": descriptor.deviceId,
            "establishmentMethod": "identity_reset",
            "establishedAt": "2026-08-24T12:00:00.000Z",
            "lastResetAt": "2026-08-24T12:00:00.000Z",
        ]
        let response = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 2,
            "activationEnabled": false,
            "activationBlockReason": "external_security_review_required",
            "identity": identity,
            "devices": [device],
        ])
        XCTAssertEqual(
            E2EEV2DeviceApprovalContract.parseDeviceInventory(response)?.identity?.generation,
            2
        )

        var unboundIdentity = identity
        unboundIdentity["establishedByDeviceId"] = "device_0000000000000009"
        let unbound = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 2,
            "activationEnabled": false,
            "activationBlockReason": "external_security_review_required",
            "identity": unboundIdentity,
            "devices": [device],
        ])
        XCTAssertNil(E2EEV2DeviceApprovalContract.parseDeviceInventory(unbound))
    }

    func testV2DeviceApprovalUniversalLinkCarriesTheV3PayloadInItsFragmentOnly() throws {
        let raw = "SQE2EE2|3|appr_01J7ABCD|ios|AbC-_09"
        let fragment = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let hosts: Set<String> = ["signalquest.fr"]
        func read(_ text: String) -> String? {
            E2EEV2DeviceApprovalContract.rawQRPayload(fromScanned: text, appHosts: hosts)
        }

        XCTAssertEqual(read("https://signalquest.fr/e2ee/approve#\(fragment)"), raw)
        XCTAssertEqual(read("  https://SignalQuest.fr/e2ee/approve#\(fragment)\n"), raw)
        XCTAssertEqual(read(raw), raw, "La chaîne v3 nue reste lue telle quelle")
        XCTAssertNil(read("http://signalquest.fr/e2ee/approve#\(fragment)"), "https seulement")
        XCTAssertNil(read("https://evil.example/e2ee/approve#\(fragment)"), "Hôte de l'app seulement")
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve/x#\(fragment)"))
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve?p=\(fragment)"), "Jamais dans la requête")
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve?x=1#\(fragment)"))
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve#\(fragment)="), "base64url sans bourrage")
        let other = Data("SQE2EE1|x".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve#\(other)"), "Autre charge refusée")
        XCTAssertNil(read("https://signalquest.fr/e2ee/approve#"))
    }

    func testV2DeviceApprovalPushAcceptsOnlyScopedUnexpiredOpaqueID() throws {
        let fixture = try deviceApprovalFixture()
        let expiresAt = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: TimeInterval(fixture.expiresAtMs) / 1_000)
        )
        let payload = [
            "type": "e2ee_v2_device_approval",
            "approvalId": fixture.approvalId,
            "expiresAt": expiresAt,
        ]
        XCTAssertEqual(
            E2EEV2DeviceApprovalContract.pushApprovalID(payload, nowMs: fixture.expiresAtMs - 1),
            fixture.approvalId
        )
        XCTAssertNil(E2EEV2DeviceApprovalContract.pushApprovalID(payload, nowMs: fixture.expiresAtMs))
        XCTAssertNil(E2EEV2DeviceApprovalContract.pushApprovalID(
            payload.merging(["approvalId": "../bad"]) { _, new in new },
            nowMs: 0
        ))
    }

    private func approvalDescriptor(deviceId: String) -> E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: deviceId,
            platform: "ios",
            label: "iPhone",
            publicIdentityKeyB64: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
            keyVersion: 1
        )
    }

    func testV2SignedRequestCanonicalizationMatchesCrossPlatformFixture() throws {
        let fixture = try signedRequestFixture()
        let body = Data(fixture.bodyUtf8.utf8)

        XCTAssertEqual(E2EEV2SignedRequest.bodySHA256Base64URL(body), fixture.bodySha256B64Url)
        XCTAssertEqual(
            try E2EEV2SignedRequest.canonicalRequest(
                method: fixture.method,
                path: fixture.path,
                timestampMs: fixture.timestampMs,
                nonce: fixture.nonce,
                body: body
            ),
            Data(fixture.canonicalRequestUtf8.utf8)
        )
        XCTAssertEqual(
            try E2EEV2SignedRequest.canonicalRequest(
                method: fixture.method,
                path: fixture.path,
                timestampMs: fixture.timestampMs,
                nonce: fixture.nonce,
                bodySHA256Base64URL: fixture.bodySha256B64Url
            ),
            Data(fixture.canonicalRequestUtf8.utf8),
            "La signature streaming doit produire exactement le même canonique"
        )
    }

    func testV2SignedRequestBindsOnePaginationQuery() throws {
        let target = "/api/e2ee/v2/recovery-epochs?cursor=epoch_cursor_01J7ABCD"
        let canonical = try E2EEV2SignedRequest.canonicalRequest(
            method: "GET",
            path: target,
            timestampMs: 1_782_000_123_456,
            nonce: "pagination_nonce_0123456789",
            body: Data()
        )
        XCTAssertEqual(String(decoding: canonical, as: UTF8.self).split(separator: "\n")[2], Substring(target))
        XCTAssertThrowsError(try E2EEV2SignedRequest.canonicalRequest(
            method: "GET",
            path: target + "?second=1",
            timestampMs: 1_782_000_123_456,
            nonce: "pagination_nonce_0123456789",
            body: Data()
        ))
    }

    func testV2SignedRequestRejectsMalformedStreamingHash() {
        XCTAssertThrowsError(
            try E2EEV2SignedRequest.canonicalRequest(
                method: "PUT",
                path: "/api/e2ee/v2/blobs/blob_1234567890123456/parts/1",
                timestampMs: 1,
                nonce: "nonce_1234567890123456",
                bodySHA256Base64URL: "not-a-sha256"
            )
        ) { error in
            XCTAssertEqual(error as? E2EEV2SignedRequestError, .invalidBodyHash)
        }
    }

    func testV2TransportFailurePolicyIsStructuredAndFailClosed() {
        XCTAssertEqual(
            E2EEV2TransportFailurePolicy.classify(
                statusCode: 403,
                code: "E2EE_V2_SECURITY_REVIEW_REQUIRED"
            ),
            .activationBlocked
        )
        XCTAssertEqual(
            E2EEV2TransportFailurePolicy.classify(statusCode: 503, code: nil),
            .retryable
        )
        XCTAssertEqual(
            E2EEV2TransportFailurePolicy.classify(statusCode: 400, code: "INVALID_ENVELOPE"),
            .permanent
        )
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
    }

    func testV2MediaOutboxPersistsOnlyOpaqueCiphertextAndPurgesByAccount() throws {
        let message = try messageFixture()
        let blob = try blobFixture()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-e2ee-outbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = temporaryRoot.appendingPathComponent("encrypted-source.bin")
        let ciphertext = try XCTUnwrap(Data(base64Encoded: blob.ciphertextB64))
        try ciphertext.write(to: source, options: .atomic)

        let envelope = E2EEV2MessageEnvelope(
            envelopeVersion: 1,
            epochNumber: message.epochNumber,
            clientRequestId: message.clientRequestId,
            algorithm: message.algorithm,
            contentType: message.contentType,
            keyCommitmentB64: message.keyCommitmentB64,
            ttlSeconds: message.ttlSeconds,
            encryptedBlobIds: [blob.blobId],
            nonceB64: message.nonceB64,
            aadB64: message.aadB64,
            ciphertextB64: message.ciphertextB64
        )
        let signedEnvelope = E2EEV2SignedMessageEnvelope(
            envelope: envelope,
            senderSignatureB64: message.senderSignatureDerB64
        )
        let manifest = E2EEV2OutboxBlobManifest(
            blobId: blob.blobId,
            algorithm: blob.algorithm,
            ciphertextSha256: blob.ciphertextSha256,
            ciphertextSize: Int64(blob.ciphertextSize),
            uploadChunkSize: E2EEV2MediaOutboxStore.uploadChunkBytes
        )
        let record = E2EEV2MediaOutboxRecord(
            conversationId: message.conversationId,
            envelope: signedEnvelope,
            blobs: [manifest],
            createdAtMs: 1_700_000_000_000
        )
        let ownerScope = "user:account-a"
        let store = try E2EEV2MediaOutboxStore(baseDirectory: temporaryRoot.appendingPathComponent("outbox"))
        try store.stage(
            record: record,
            ownerScopeId: ownerScope,
            ciphertextSources: [blob.blobId: source]
        )

        XCTAssertEqual(try store.load(ownerScopeId: ownerScope, clientRequestId: record.clientRequestId), record)
        let serialized = String(decoding: try E2EEV2MediaOutboxStore.encode(record), as: UTF8.self)
        for forbidden in ["mediaKey", "sourceURI", "mimeType", "fileName", source.path] {
            XCTAssertFalse(serialized.contains(forbidden), "Le manifeste ne doit pas persister \(forbidden)")
        }
        let stagedCiphertext = try store.ciphertextURL(ownerScopeId: ownerScope, blobId: blob.blobId)
        XCTAssertEqual(try Data(contentsOf: stagedCiphertext), ciphertext)

        try store.purge(ownerScopeId: ownerScope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedCiphertext.path))
    }

    func testV2MediaOutboxDecoderRejectsUnexpectedCleartextFields() throws {
        let message = try messageFixture()
        let blob = try blobFixture()
        let envelope = E2EEV2MessageEnvelope(
            envelopeVersion: 1,
            epochNumber: message.epochNumber,
            clientRequestId: message.clientRequestId,
            algorithm: message.algorithm,
            contentType: message.contentType,
            keyCommitmentB64: message.keyCommitmentB64,
            ttlSeconds: message.ttlSeconds,
            encryptedBlobIds: [blob.blobId],
            nonceB64: message.nonceB64,
            aadB64: message.aadB64,
            ciphertextB64: message.ciphertextB64
        )
        let record = E2EEV2MediaOutboxRecord(
            conversationId: message.conversationId,
            envelope: .init(envelope: envelope, senderSignatureB64: message.senderSignatureDerB64),
            blobs: [.init(
                blobId: blob.blobId,
                algorithm: blob.algorithm,
                ciphertextSha256: blob.ciphertextSha256,
                ciphertextSize: Int64(blob.ciphertextSize),
                uploadChunkSize: E2EEV2MediaOutboxStore.uploadChunkBytes
            )]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: E2EEV2MediaOutboxStore.encode(record)) as? [String: Any]
        )
        object["mediaKey"] = Data(repeating: 7, count: 32).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try E2EEV2MediaOutboxStore.decode(tampered)) { error in
            XCTAssertEqual(error as? E2EEV2MediaOutboxError, .invalidRecord)
        }
    }

    func testV2IOSVerifiesBackendFixtureDerSignature() throws {
        let fixture = try signedRequestFixture()
        let publicData = try XCTUnwrap(Data(base64Encoded: fixture.publicSigningKeyB64))
        let signatureData = try XCTUnwrap(Data(base64Encoded: fixture.signatureDerB64))
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicData)
        let canonical = Data(fixture.canonicalRequestUtf8.utf8)

        // Vecteur réémis en forme low-S (spec §15) : accepté ; sa variante high-S,
        // que CryptoKit accepterait, est refusée.
        XCTAssertTrue(E2EEV2LowS.verify(derSignature: signatureData, message: canonical, publicKey: publicKey))
        let highS = try E2EEV2LowS.highSVariant(der: signatureData)
        XCTAssertFalse(E2EEV2LowS.verify(derSignature: highS, message: canonical, publicKey: publicKey))
    }

    func testV2EpochEnvelopeMatchesCrossPlatformFixtureAndUnwraps() throws {
        let fixture = try epochFixture()
        let context = E2EEV2EpochContext(
            conversationId: fixture.conversationId,
            epochNumber: fixture.epochNumber,
            senderDeviceId: fixture.senderDeviceId,
            recipientDeviceId: fixture.recipientDeviceId
        )
        let recipientPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: fixture.recipientPrivateRawB64))
        )
        let ephemeralPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: fixture.ephemeralPrivateRawB64))
        )
        XCTAssertEqual(
            recipientPrivate.publicKey.x963Representation.base64EncodedString(),
            fixture.recipientPublicX963B64
        )
        XCTAssertEqual(
            ephemeralPrivate.publicKey.x963Representation.base64EncodedString(),
            fixture.ephemeralPublicX963B64
        )
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPrivate.publicKey)
        XCTAssertEqual(
            shared.withUnsafeBytes { Data($0) }.base64EncodedString(),
            fixture.sharedSecretB64
        )
        XCTAssertEqual(
            try E2EEV2EpochCrypto.saltCanonical(context),
            Data(fixture.saltCanonicalUtf8.utf8)
        )
        XCTAssertEqual(try E2EEV2EpochCrypto.salt(context).base64EncodedString(), fixture.saltB64)
        XCTAssertEqual(
            try E2EEV2EpochCrypto.deriveWrappingKey(sharedSecret: shared, context: context)
                .base64EncodedString(),
            fixture.derivedKeyB64
        )
        let epochKey = try XCTUnwrap(Data(base64Encoded: fixture.epochKeyB64))
        XCTAssertEqual(try E2EEV2EpochCrypto.keyCommitment(epochKey), fixture.keyCommitmentB64)
        let envelope = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: recipientPrivate.publicKey,
            ephemeralPrivateKey: ephemeralPrivate,
            nonce: XCTUnwrap(Data(base64Encoded: fixture.nonceB64)),
            context: context
        )
        XCTAssertEqual(envelope.wrapAlgorithm, fixture.wrapAlgorithm)
        XCTAssertEqual(envelope.ephemeralPublicKeyB64, fixture.ephemeralPublicX963B64)
        XCTAssertEqual(envelope.wrappedEpochKeyB64, fixture.wrappedEpochKeyB64)
        XCTAssertEqual(envelope.aadB64, fixture.aadB64)
        XCTAssertEqual(
            try E2EEV2EpochCrypto.signatureCanonical(
                context: context,
                keyCommitmentB64: fixture.keyCommitmentB64,
                envelope: envelope
            ),
            Data(fixture.signatureCanonicalUtf8.utf8)
        )
        XCTAssertEqual(
            try E2EEV2EpochCrypto.unwrap(
                envelope: envelope,
                keyCommitmentB64: fixture.keyCommitmentB64,
                recipientPrivateKey: recipientPrivate,
                context: context
            ),
            epochKey
        )
        let signingPublic = try P256.Signing.PublicKey(
            x963Representation: XCTUnwrap(Data(base64Encoded: fixture.senderPublicSigningKeyB64))
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: XCTUnwrap(Data(base64Encoded: fixture.signatureDerB64))
        )
        XCTAssertTrue(signingPublic.isValidSignature(signature, for: Data(fixture.signatureCanonicalUtf8.utf8)))
    }

    func testV2DeliveredEpochRequiresExactRecipientAADAndSignature() throws {
        let fixture = try epochFixture()
        let data = try epochDeliveryData(fixture)
        let parsed = try XCTUnwrap(
            E2EEV2EpochDeliveryContract.parseAndVerify(
                data,
                expectedConversationId: fixture.conversationId,
                expectedRecipientDeviceId: fixture.recipientDeviceId
            )
        )
        XCTAssertEqual(parsed.epochNumber, fixture.epochNumber)
        XCTAssertNil(
            E2EEV2EpochDeliveryContract.parseAndVerify(
                data,
                expectedConversationId: fixture.conversationId,
                expectedRecipientDeviceId: "wrong_recipient_01J7ABCD234567"
            )
        )

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["epochKeyB64"] = fixture.epochKeyB64
        let leakedField = try JSONSerialization.data(withJSONObject: root)
        XCTAssertNil(
            E2EEV2EpochDeliveryContract.parseAndVerify(
                leakedField,
                expectedConversationId: fixture.conversationId,
                expectedRecipientDeviceId: fixture.recipientDeviceId
            )
        )
    }

    func testV2EpochRotationEnvelopeIsSignedAndUnwrapsForExactRecipient() throws {
        let fixture = try epochFixture()
        let tokenStore = InMemoryTokenStore()
        let identityStore = E2EEV2DeviceIdentityStore(tokenStore: tokenStore, allowsOwner: { _ in true })
        let owner = "rotation-owner"
        let sender = try identityStore.loadOrCreate(ownerNamespace: owner, label: "Rotation")
        let epochKey = Data((0..<32).map(UInt8.init))
        let context = E2EEV2EpochContext(
            conversationId: fixture.conversationId,
            epochNumber: fixture.epochNumber + 1,
            senderDeviceId: sender.deviceId,
            recipientDeviceId: fixture.recipientDeviceId
        )
        let envelope = try identityStore.createSignedEpochEnvelope(
            context: context,
            epochKey: epochKey,
            recipientPublicIdentityKeyB64: fixture.recipientPublicX963B64,
            ownerNamespace: owner,
            nonce: Data(repeating: 0, count: 12)
        )
        XCTAssertNotEqual(envelope.wrappedEpochKeyB64, epochKey.base64EncodedString())
        let recipientPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: fixture.recipientPrivateRawB64))
        )
        XCTAssertEqual(
            try E2EEV2EpochCrypto.unwrap(
                envelope: envelope.cryptoEnvelope,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(epochKey),
                recipientPrivateKey: recipientPrivate,
                context: context
            ),
            epochKey
        )
        let signingPublic = try P256.Signing.PublicKey(
            x963Representation: XCTUnwrap(Data(base64Encoded: sender.publicSigningKeyB64))
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: XCTUnwrap(Data(base64Encoded: envelope.signatureB64))
        )
        XCTAssertTrue(signingPublic.isValidSignature(
            signature,
            for: try E2EEV2EpochCrypto.signatureCanonical(
                context: context,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
                envelope: envelope.cryptoEnvelope
            )
        ))
    }

    func testV2IdentityResetReasonPreservesDeliveryAndRotationContracts() throws {
        let fixture = try epochFixture()
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: epochDeliveryData(fixture)) as? [String: Any]
        )
        var epoch = try XCTUnwrap(root["epoch"] as? [String: Any])
        epoch["reason"] = "IDENTITY_RESET"
        root["epoch"] = epoch
        let parsed = try XCTUnwrap(E2EEV2EpochDeliveryContract.parseAndVerify(
            JSONSerialization.data(withJSONObject: root),
            expectedConversationId: fixture.conversationId,
            expectedRecipientDeviceId: fixture.recipientDeviceId
        ))
        XCTAssertEqual(parsed.reason, "IDENTITY_RESET")
        XCTAssertEqual(parsed.envelope.aadB64, fixture.aadB64)
        XCTAssertEqual(parsed.envelope.signatureB64, fixture.signatureDerB64)
        let recipientPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: fixture.recipientPrivateRawB64))
        )
        XCTAssertEqual(try E2EEV2EpochCrypto.unwrap(
            envelope: parsed.envelope.cryptoEnvelope,
            keyCommitmentB64: parsed.keyCommitmentB64,
            recipientPrivateKey: recipientPrivate,
            context: parsed.epochContext
        ), Data(base64Encoded: fixture.epochKeyB64))

        var requirement: [String: Any] = [
            "conversationId": fixture.conversationId, "reason": "IDENTITY_RESET",
            "revision": 4, "triggeredAt": "2026-08-29T10:00:00.000Z",
            "currentEpochNumber": 7, "currentEpochStatus": "compromised",
        ]
        let requirements = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 2, "requirements": [requirement],
        ])
        XCTAssertEqual(E2EEV2EpochRotationContract.parseRequirements(requirements)?.first?.reason, "IDENTITY_RESET")
        requirement["reason"] = "identity reset"
        XCTAssertNil(E2EEV2EpochRotationContract.parseRequirements(
            try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 2, "requirements": [requirement],
            ])
        ))
    }

    /// Les exigences telles que le serveur A3 les sert : motifs d'appartenance,
    /// conversation encore v1 (époque 0, statut nul), motif encore inconnu.
    func testV2EpochRotationContractParsesTheServedRequirements() throws {
        let fixture = try epochFixture()
        var requirement: [String: Any] = [
            "conversationId": fixture.conversationId,
            "reason": "MEMBER_REMOVED",
            "revision": 3,
            "triggeredAt": "2026-10-04T10:00:00.000Z",
            "currentEpochNumber": 7,
            "currentEpochStatus": "active",
        ]
        func parse(_ values: [[String: Any]]) throws -> [E2EEV2EpochRotationRequirement]? {
            E2EEV2EpochRotationContract.parseRequirements(try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 2, "requirements": values,
            ]))
        }
        XCTAssertEqual(try parse([requirement])?.first?.reason, "MEMBER_REMOVED")
        XCTAssertNil(try parse([requirement, requirement]), "Une conversation nommée deux fois")
        // `isGroup`, champ additif servi depuis le 09/11 (8fe65a067) : lu, jamais exigé.
        var withKind = requirement
        withKind["isGroup"] = false
        XCTAssertEqual(try parse([withKind])?.first?.reason, "MEMBER_REMOVED")
        withKind["isGroup"] = "false"
        XCTAssertNil(try parse([withKind]), "isGroup n'est qu'un booléen")
        withKind["isGroup"] = 0
        XCTAssertNil(try parse([withKind]), "isGroup n'est qu'un booléen")
        withKind["isGroup"] = false
        withKind["extra"] = true
        XCTAssertNil(try parse([withKind]), "Tout autre champ reste refusé")
        var legacy = requirement
        legacy["conversationId"] = "conversation_v1_000000001"
        legacy["reason"] = "DEVICE_REVOKED"
        legacy["currentEpochNumber"] = 0
        legacy["currentEpochStatus"] = NSNull()
        let both = try XCTUnwrap(try parse([requirement, legacy]))
        XCTAssertEqual(both.map(\.currentEpochNumber), [7, 0])
        XCTAssertNil(both[1].currentEpochStatus)
        requirement["reason"] = "SOME_FUTURE_REASON"
        XCTAssertEqual(try parse([requirement])?.first?.reason, "SOME_FUTURE_REASON", "Un motif inconnu ne fige pas la file")
        requirement["reason"] = "member-removed"
        XCTAssertNil(try parse([requirement]))
        requirement["reason"] = "MANUAL"
        requirement["currentEpochNumber"] = -1
        XCTAssertNil(try parse([requirement]))
        // Entiers en chaînes (D.0), lus comme les entiers ; jamais une forme non canonique.
        requirement["currentEpochNumber"] = "12"
        requirement["revision"] = "4"
        XCTAssertEqual(try parse([requirement])?.first.map { [$0.currentEpochNumber, $0.revision] }, [12, 4])
        XCTAssertEqual(E2EEV2EpochRotationContract.parseRequirements(try JSONSerialization.data(withJSONObject: [
            "protocolVersion": "2", "requirements": [requirement],
        ]))?.count, 1, "protocolVersion en chaîne (A3c)")
        requirement["revision"] = "04"
        XCTAssertNil(try parse([requirement]))
        requirement["revision"] = true
        XCTAssertNil(try parse([requirement]))
    }

    func testV2EpochKeyStoreKeepsHistoricalEpochsWithoutMovingCurrentPointer() throws {
        let fixture = try epochFixture()
        let delivery = try XCTUnwrap(
            E2EEV2EpochDeliveryContract.parseAndVerify(
                epochDeliveryData(fixture),
                expectedConversationId: fixture.conversationId,
                expectedRecipientDeviceId: fixture.recipientDeviceId
            )
        )
        let keychain = InMemoryTokenStore()
        let store = E2EEV2EpochKeyStore(tokenStore: keychain, allowsOwner: { _ in true })
        let epochKey = try XCTUnwrap(Data(base64Encoded: fixture.epochKeyB64))
        XCTAssertTrue(try store.put(delivery: delivery, epochKey: epochKey, ownerNamespace: "account-a"))
        XCTAssertEqual(
            try store.load(conversationId: fixture.conversationId, ownerNamespace: "account-a")?.epochKey,
            epochKey
        )
        XCTAssertNil(try store.load(conversationId: fixture.conversationId, ownerNamespace: "account-b"))

        let nextKey = Data(repeating: 9, count: 32)
        XCTAssertTrue(try store.put(
            recordInput: .init(
                conversationId: fixture.conversationId,
                epochId: "epoch_0000000000000002",
                epochNumber: delivery.epochNumber + 1,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(nextKey)
            ),
            epochKey: nextKey,
            ownerNamespace: "account-a"
        ))
        XCTAssertEqual(
            try store.load(conversationId: fixture.conversationId, ownerNamespace: "account-a")?.epochKey,
            nextKey
        )
        XCTAssertEqual(
            try store.loadEpoch(
                conversationId: fixture.conversationId,
                epochNumber: delivery.epochNumber,
                ownerNamespace: "account-a"
            )?.epochKey,
            epochKey
        )
        XCTAssertTrue(try store.put(delivery: delivery, epochKey: epochKey, ownerNamespace: "account-a"))
        XCTAssertEqual(
            try store.load(conversationId: fixture.conversationId, ownerNamespace: "account-a")?.epochKey,
            nextKey
        )

        let replacementKey = Data(repeating: 7, count: 32)
        let substitution = E2EEV2EpochDelivery(
            conversationId: delivery.conversationId,
            epochId: delivery.epochId,
            epochNumber: delivery.epochNumber,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(replacementKey),
            reason: delivery.reason,
            status: delivery.status,
            createdAt: delivery.createdAt,
            senderDeviceId: delivery.senderDeviceId,
            senderPublicSigningKeyB64: delivery.senderPublicSigningKeyB64,
            envelope: delivery.envelope
        )
        XCTAssertFalse(
            try store.put(delivery: substitution, epochKey: replacementKey, ownerNamespace: "account-a")
        )
    }

    func testV2RestoredEpochKeyNeverDisplacesAVerifiedKeyAndAVerifiedKeyReplacesIt() throws {
        let store = E2EEV2EpochKeyStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let conversationId = "conv_restored_0000000001"
        func record(_ key: Data, epochId: String, number: Int = 3) throws -> E2EEV2EpochKeyRecordInput {
            .init(conversationId: conversationId, epochId: epochId, epochNumber: number,
                  keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(key))
        }
        let restoredKey = Data(repeating: 1, count: 32)
        let verifiedKey = Data(repeating: 2, count: 32)

        // Restaurée d'abord, puis la synchro vérifiée apporte une autre clé au même
        // numéro (autre epochId, non authentifié par la sauvegarde) : elle gagne.
        XCTAssertTrue(try store.put(recordInput: record(restoredKey, epochId: "epoch_restored_000001"),
                                    epochKey: restoredKey, ownerNamespace: "a", origin: .restored))
        XCTAssertNil(try store.load(conversationId: conversationId, ownerNamespace: "a"),
                     "Une clé restaurée ne devient jamais l'époque courante")
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a", includeRestored: true)?.epochKey,
                       restoredKey)
        XCTAssertNil(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a"),
                     "Par défaut, aucun lecteur ne lit une clé restaurée non confirmée")
        XCTAssertTrue(try store.put(recordInput: record(verifiedKey, epochId: "epoch_verified_000001"),
                                    epochKey: verifiedKey, ownerNamespace: "a"))
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a", includeRestored: false)?.epochKey,
                       verifiedKey, "La clé vérifiée, elle, sert")
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a")?.epochKey, verifiedKey)
        XCTAssertEqual(try store.load(conversationId: conversationId, ownerNamespace: "a")?.epochKey, verifiedKey,
                       "Le pointeur courant suit la clé vérifiée")

        // Une clé restaurée ne remplace jamais la clé vérifiée, ni ne la rétrograde.
        XCTAssertFalse(try store.put(recordInput: record(restoredKey, epochId: "epoch_restored_000001"),
                                     epochKey: restoredKey, ownerNamespace: "a", origin: .restored))
        XCTAssertTrue(try store.put(recordInput: record(verifiedKey, epochId: "epoch_verified_000001"),
                                    epochKey: verifiedKey, ownerNamespace: "a", origin: .restored))
        let other = Data(repeating: 4, count: 32)
        XCTAssertFalse(try store.put(recordInput: record(other, epochId: "epoch_other_00000001"),
                                     epochKey: other, ownerNamespace: "a"),
                       "Une clé vérifiée ne se remplace pas, même après une restauration identique")
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a")?.epochKey, verifiedKey)

        // Restaurée puis confirmée par la clé vérifiée identique : elle sert alors aux lecteurs v2.
        let confirmed = Data(repeating: 5, count: 32)
        XCTAssertTrue(try store.put(recordInput: record(confirmed, epochId: "epoch_confirmed_00001", number: 1),
                                    epochKey: confirmed, ownerNamespace: "a", origin: .restored))
        XCTAssertNil(try store.loadEpoch(conversationId: conversationId, epochNumber: 1, ownerNamespace: "a", includeRestored: false))
        XCTAssertTrue(try store.put(recordInput: record(confirmed, epochId: "epoch_confirmed_00001", number: 1),
                                    epochKey: confirmed, ownerNamespace: "a"))
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 1, ownerNamespace: "a", includeRestored: false)?.epochKey, confirmed)

        // Une clé restaurée reste lisible pour l'historique tant que rien ne la remplace.
        XCTAssertTrue(try store.put(recordInput: record(restoredKey, epochId: "epoch_restored_000002", number: 2),
                                    epochKey: restoredKey, ownerNamespace: "a", origin: .restored))
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 2, ownerNamespace: "a", includeRestored: true)?.epochKey,
                       restoredKey)
        XCTAssertEqual(try store.load(conversationId: conversationId, ownerNamespace: "a")?.epochNumber, 3)
    }

    /// §2.8 (v0.4.38) : l'engagement du manifeste signé confirme une clé
    /// restaurée, un autre l'efface ; une clé vérifiée n'est jamais touchée.
    func testV2RestoredEpochKeyIsConfirmedOrErasedByItsManifestCommitment() throws {
        let store = E2EEV2EpochKeyStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let conversationId = "conv_settled_0000000001"
        func put(_ key: Data, number: Int, origin: E2EEV2EpochKeyOrigin) throws -> Bool {
            try store.put(
                recordInput: .init(conversationId: conversationId, epochId: "epoch_settled_00000\(number)", epochNumber: number,
                                   keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(key)),
                epochKey: key, ownerNamespace: "a", origin: origin
            )
        }
        let one = Data(repeating: 1, count: 32), two = Data(repeating: 2, count: 32), three = Data(repeating: 3, count: 32)
        XCTAssertTrue(try put(three, number: 3, origin: .verified))
        XCTAssertTrue(try put(one, number: 1, origin: .restored))
        XCTAssertTrue(try put(two, number: 2, origin: .restored))
        XCTAssertEqual(try store.restoredEpochNumbers(conversationId: conversationId, ownerNamespace: "a"), [1, 2])

        XCTAssertTrue(try store.settleRestored(conversationId: conversationId, epochNumber: 1,
                                               keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(one), ownerNamespace: "a"))
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 1, ownerNamespace: "a", includeRestored: false)?.epochKey,
                       one, "Confirmée : elle sert aux lecteurs v2")
        XCTAssertFalse(try store.settleRestored(conversationId: conversationId, epochNumber: 2,
                                                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(three), ownerNamespace: "a"))
        XCTAssertNil(try store.loadEpoch(conversationId: conversationId, epochNumber: 2, ownerNamespace: "a"),
                     "Un autre engagement l'efface")
        XCTAssertEqual(try store.restoredEpochNumbers(conversationId: conversationId, ownerNamespace: "a"), [])
        XCTAssertFalse(try store.settleRestored(conversationId: conversationId, epochNumber: 3,
                                                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(one), ownerNamespace: "a"))
        XCTAssertEqual(try store.loadEpoch(conversationId: conversationId, epochNumber: 3, ownerNamespace: "a")?.epochKey, three,
                       "Une clé vérifiée n'est jamais effacée par ce chemin")
        XCTAssertEqual(try store.load(conversationId: conversationId, ownerNamespace: "a")?.epochNumber, 3,
                       "La confirmation ne déplace pas l'époque courante")

        // Coffre verrouillé : l'erreur remonte, jamais une liste vide qui
        // ferait tenir les clés provisoires pour réglées.
        final class LockableStore: TokenStore, @unchecked Sendable {
            let memory = InMemoryTokenStore()
            var locked = false
            func string(for key: String) throws -> String? {
                if locked, key.hasPrefix("epoch-v2-history:") { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
                return try memory.string(for: key)
            }
            func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
                try memory.set(value, for: key, accessibility: accessibility)
            }
            func remove(_ key: String) throws { try memory.remove(key) }
            func keys(withPrefix prefix: String) throws -> [String] { try memory.keys(withPrefix: prefix) }
            func removeAll() throws { try memory.removeAll() }
        }
        let vault = LockableStore()
        let lockable = E2EEV2EpochKeyStore(tokenStore: vault, allowsOwner: { _ in true })
        XCTAssertTrue(try lockable.put(
            recordInput: .init(conversationId: conversationId, epochId: "epoch_settled_000002", epochNumber: 2,
                               keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(two)),
            epochKey: two, ownerNamespace: "a", origin: .restored
        ))
        vault.locked = true
        XCTAssertThrowsError(try lockable.restoredEpochNumbers(conversationId: conversationId, ownerNamespace: "a"))
        vault.locked = false
        XCTAssertEqual(try lockable.restoredEpochNumbers(conversationId: conversationId, ownerNamespace: "a"), [2])
    }

    /// §2.8 (v0.4.38) : une époque confirmée après coup est acceptée à la
    /// confirmation ; une confirmation reprise en reprend la date ; une époque
    /// que la liste pleine ne retiendrait pas est refusée.
    func testV2PastEpochAcceptedAfterTheFactKeepsTheConfirmationDateAndFitsTheList() throws {
        let states = E2EEV2ConversationStateStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let conversationId = "conv_accepted_000000001"
        let limit = E2EEV2ConversationStateStore.acceptedEpochLimit
        for number in 2...(limit + 1) {
            try states.recordCurrentEpoch(.init(
                conversationId: conversationId, epochNumber: number, membershipChangeNumber: 2, memberIds: ["a", "b"],
                recipientsDigest: "digest", excludesWeb: false, createdAtMs: Int64(number), acceptedAtMs: Int64(number)
            ), ownerNamespace: "a")
        }
        func past(_ number: Int, at ms: Int64) -> E2EEV2ConversationStateStore.AcceptedEpoch {
            .init(epochNumber: number, membershipChangeNumber: 2, memberIds: ["a", "b"], acceptedAtMs: ms)
        }
        XCTAssertThrowsError(try states.acceptPastEpoch(past(1, at: 9_000), conversationId: conversationId, ownerNamespace: "a"),
                             "Plus ancienne que toute la liste pleine")
        XCTAssertThrowsError(try states.acceptPastEpoch(past(limit + 1, at: 9_000), conversationId: conversationId, ownerNamespace: "a"),
                             "Jamais l'époque courante")
        try states.acceptPastEpoch(past(100, at: 9_000), conversationId: conversationId, ownerNamespace: "a")
        try states.acceptPastEpoch(past(100, at: 9_500), conversationId: conversationId, ownerNamespace: "a")
        let accepted = try states.acceptedEpochs(conversationId: conversationId, ownerNamespace: "a")
        XCTAssertEqual(accepted.count, limit)
        XCTAssertEqual(accepted.filter { $0.epochNumber == 100 }.map(\.acceptedAtMs), [9_500], "Une seule entrée, à la dernière date")
    }

    func testV2EpochKeyStoreResetPurgeIsStrictlyAccountScoped() throws {
        let tokenStore = InMemoryTokenStore()
        let store = E2EEV2EpochKeyStore(tokenStore: tokenStore, allowsOwner: { _ in true })
        let conversationA = "conversation_0000000000000011"
        let conversationB = "conversation_0000000000000012"
        let keyA = Data(repeating: 0xA1, count: 32)
        let keyB = Data(repeating: 0xB2, count: 32)
        XCTAssertTrue(try store.put(
            recordInput: .init(
                conversationId: conversationA,
                epochId: "epoch_0000000000000011",
                epochNumber: 1,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(keyA)
            ),
            epochKey: keyA,
            ownerNamespace: "account-a"
        ))
        XCTAssertTrue(try store.put(
            recordInput: .init(
                conversationId: conversationB,
                epochId: "epoch_0000000000000012",
                epochNumber: 1,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(keyB)
            ),
            epochKey: keyB,
            ownerNamespace: "account-b"
        ))

        try store.removeAll(ownerNamespace: "account-a")

        XCTAssertNil(try store.load(conversationId: conversationA, ownerNamespace: "account-a"))
        XCTAssertEqual(
            try store.load(conversationId: conversationB, ownerNamespace: "account-b")?.epochKey,
            keyB
        )
        XCTAssertTrue(try tokenStore.keys(withPrefix: "epoch-v2:account-a:").isEmpty)
        XCTAssertFalse(try tokenStore.keys(withPrefix: "epoch-v2:account-b:").isEmpty)
    }

    func testV2MessageEnvelopeMatchesCrossPlatformFixtureAndDecrypts() throws {
        let fixture = try messageFixture()
        let context = E2EEV2MessageContext(
            conversationId: fixture.conversationId,
            epochNumber: fixture.epochNumber,
            senderDeviceId: fixture.senderDeviceId,
            clientRequestId: fixture.clientRequestId,
            ttlSeconds: fixture.ttlSeconds,
            encryptedBlobIds: fixture.encryptedBlobIds
        )
        let epochKey = try XCTUnwrap(Data(base64Encoded: fixture.epochKeyB64))
        XCTAssertEqual(try E2EEV2MessageCrypto.saltCanonical(context), Data(fixture.saltCanonicalUtf8.utf8))
        XCTAssertEqual(try E2EEV2MessageCrypto.salt(context).base64EncodedString(), fixture.saltB64)
        XCTAssertEqual(
            try E2EEV2MessageCrypto.deriveMessageKey(epochKey: epochKey, context: context)
                .base64EncodedString(),
            fixture.derivedKeyB64
        )
        let envelope = try E2EEV2MessageCrypto.encrypt(
            cleartext: Data(fixture.cleartextUtf8.utf8),
            epochKey: epochKey,
            nonce: XCTUnwrap(Data(base64Encoded: fixture.nonceB64)),
            context: context
        )
        XCTAssertEqual(envelope.algorithm, fixture.algorithm)
        XCTAssertEqual(envelope.contentType, fixture.contentType)
        XCTAssertEqual(envelope.keyCommitmentB64, fixture.keyCommitmentB64)
        XCTAssertEqual(envelope.aadB64, fixture.aadB64)
        XCTAssertEqual(envelope.ciphertextB64, fixture.ciphertextB64)
        XCTAssertEqual(Data(base64Encoded: envelope.aadB64), Data(fixture.aadUtf8.utf8))
        let canonical = try E2EEV2MessageCrypto.signatureCanonical(context: context, envelope: envelope)
        XCTAssertEqual(canonical, Data(fixture.signatureCanonicalUtf8.utf8))
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: XCTUnwrap(Data(base64Encoded: fixture.senderPublicSigningKeyB64))
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: XCTUnwrap(Data(base64Encoded: fixture.senderSignatureDerB64))
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: canonical))
        XCTAssertEqual(
            try E2EEV2MessageCrypto.decrypt(envelope: envelope, epochKey: epochKey, context: context),
            Data(fixture.cleartextUtf8.utf8)
        )
    }

    func testV2CallFrameKeyMatchesCrossPlatformFixture() throws {
        let fixture = try callFrameKeyFixture()
        let context = E2EEV2CallFrameKeyContext(
            conversationId: fixture.conversationId,
            epochNumber: fixture.epochNumber,
            callId: fixture.callId
        )
        let epochKey = try XCTUnwrap(Data(base64Encoded: fixture.epochKeyB64))
        XCTAssertEqual(try E2EEV2CallFrameKey.saltCanonical(context), Data(fixture.saltCanonicalUtf8.utf8))
        XCTAssertEqual(try E2EEV2CallFrameKey.salt(context).base64EncodedString(), fixture.saltB64)
        XCTAssertEqual(E2EEV2CallFrameKey.kdfInfo, fixture.kdfInfo)
        let frameKey = try E2EEV2CallFrameKey.derive(epochKey: epochKey, context: context)
        XCTAssertEqual(frameKey.base64EncodedString(), fixture.frameKeyB64)
        XCTAssertEqual(
            try E2EEV2CallFrameKey.liveKitSharedPassphrase(frameKey: frameKey),
            fixture.liveKitSharedPassphrase
        )
        XCTAssertNotEqual(
            try E2EEV2CallFrameKey.derive(
                epochKey: epochKey,
                context: E2EEV2CallFrameKeyContext(
                    conversationId: fixture.conversationId,
                    epochNumber: fixture.epochNumber,
                    callId: "call_01J7ABCD234567890124"
                )
            ),
            try E2EEV2CallFrameKey.derive(epochKey: epochKey, context: context)
        )
    }

    func testV2LiveKitVerificationFailsClosed() {
        #if canImport(LiveKit)
        let verification = E2EEV2LiveKitVerification()
        verification.expectParticipant("local-participant")
        verification.expect(participantID: "local-participant", trackID: "local-track")
        XCTAssertFalse(verification.isVerified)
        verification.update("local-track", state: .ok)
        XCTAssertFalse(verification.isVerified)
        verification.expectParticipant("remote-participant")
        verification.expect(participantID: "remote-participant", trackID: "remote-track")
        XCTAssertFalse(verification.isVerified)
        verification.update("remote-track", state: .key_ratcheted)
        XCTAssertFalse(verification.isVerified, "Personne ne fait de ratchet : une clé qui bouge ne prouve rien")
        verification.update("remote-track", state: .ok)
        XCTAssertTrue(verification.isVerified)
        verification.expect(participantID: "remote-participant", trackID: "remote-video")
        XCTAssertFalse(verification.isVerified)
        verification.update("remote-video", state: .ok)
        XCTAssertTrue(verification.isVerified)
        verification.update("remote-track", state: .decryption_failed)
        XCTAssertFalse(verification.isVerified)
        verification.failGlobally()
        verification.remove(participantID: "remote-participant", trackID: "remote-track")
        XCTAssertFalse(verification.isVerified)
        #endif
    }

    func testV2LiveKitVerificationRejectsUnknownOrReassignedTracks() {
        #if canImport(LiveKit)
        let unknown = E2EEV2LiveKitVerification()
        unknown.update("unknown-track", state: .ok)
        XCTAssertFalse(unknown.isVerified)

        let reassigned = E2EEV2LiveKitVerification()
        reassigned.expect(participantID: "participant-one", trackID: "shared-track")
        reassigned.expect(participantID: "participant-two", trackID: "shared-track")
        reassigned.update("shared-track", state: .ok)
        XCTAssertFalse(reassigned.isVerified)
        #endif
    }

    func testV2BlobChunksMatchCrossPlatformFixtureAndDecrypt() throws {
        let fixture = try blobFixture()
        let mediaKey = try XCTUnwrap(Data(base64Encoded: fixture.mediaKeyB64))
        let noncePrefix = try XCTUnwrap(Data(base64Encoded: fixture.noncePrefixB64))
        XCTAssertEqual(E2EEV2BlobCrypto.algorithm, fixture.algorithm)
        XCTAssertEqual(E2EEV2BlobCrypto.kdfInfo, fixture.kdfInfo)
        XCTAssertEqual(
            try E2EEV2BlobCrypto.saltCanonical(blobID: fixture.blobId),
            Data(fixture.saltCanonicalUtf8.utf8)
        )
        XCTAssertEqual(
            try E2EEV2BlobCrypto.salt(blobID: fixture.blobId).base64EncodedString(),
            fixture.saltB64
        )
        XCTAssertEqual(
            try E2EEV2BlobCrypto.deriveBlobKey(mediaKey: mediaKey, blobID: fixture.blobId)
                .base64EncodedString(),
            fixture.derivedKeyB64
        )

        var ciphertext = Data()
        var plaintext = Data()
        for (index, cleartextB64) in fixture.plaintextChunksB64.enumerated() {
            let cleartext = try XCTUnwrap(Data(base64Encoded: cleartextB64))
            let finalChunk = index == fixture.plaintextChunksB64.count - 1
            XCTAssertEqual(
                try E2EEV2BlobCrypto.chunkAAD(
                    blobID: fixture.blobId,
                    chunkIndex: UInt32(index),
                    cleartextBytes: cleartext.count,
                    finalChunk: finalChunk
                ),
                Data(fixture.chunkAadUtf8[index].utf8)
            )
            let encrypted = try E2EEV2BlobCrypto.encryptChunk(
                cleartext,
                blobID: fixture.blobId,
                mediaKey: mediaKey,
                noncePrefix: noncePrefix,
                chunkIndex: UInt32(index),
                finalChunk: finalChunk
            )
            XCTAssertEqual(encrypted.base64EncodedString(), fixture.ciphertextChunksB64[index])
            XCTAssertEqual(
                try E2EEV2BlobCrypto.decryptChunk(
                    encrypted,
                    blobID: fixture.blobId,
                    mediaKey: mediaKey,
                    noncePrefix: noncePrefix,
                    chunkIndex: UInt32(index),
                    finalChunk: finalChunk,
                    cleartextBytes: cleartext.count
                ),
                cleartext
            )
            plaintext.append(cleartext)
            ciphertext.append(encrypted)
        }
        XCTAssertEqual(plaintext.count, fixture.plaintextSize)
        XCTAssertEqual(ciphertext.count, fixture.ciphertextSize)
        XCTAssertEqual(ciphertext.base64EncodedString(), fixture.ciphertextB64)
        XCTAssertEqual(
            Data(SHA256.hash(data: plaintext)).map { String(format: "%02x", $0) }.joined(),
            fixture.plaintextSha256
        )
        XCTAssertEqual(
            Data(SHA256.hash(data: ciphertext)).map { String(format: "%02x", $0) }.joined(),
            fixture.ciphertextSha256
        )
    }

    func testV2CorruptIdentityIsNotSilentlyReplaced() throws {
        let keychain = InMemoryTokenStore()
        let store = E2EEV2DeviceIdentityStore(tokenStore: keychain, allowsOwner: { _ in true })
        let key = store.storageKey(ownerNamespace: "account-a")
        try keychain.set("corrupt", for: key, accessibility: .whenUnlocked)

        XCTAssertThrowsError(try store.loadOrCreate(ownerNamespace: "account-a")) {
            XCTAssertEqual($0 as? E2EEV2DeviceIdentityError, .invalidRecord)
        }
        XCTAssertEqual(try keychain.string(for: key), "corrupt")
    }

    func testV2AADBindsConversationContentTypeAndDevice() throws {
        let context = EncryptedMessageEnvelopeV2AAD(
            conversationId: "conversation-42",
            contentType: .poll,
            senderDeviceId: "device-ios-1",
            operationId: "poll-create-1"
        )
        let decoded = try JSONDecoder().decode(
            EncryptedMessageEnvelopeV2AAD.self,
            from: context.encoded()
        )

        XCTAssertEqual(decoded.cryptoVersion, 2)
        XCTAssertEqual(decoded.schema, "signalquest.encrypted-message")
        XCTAssertEqual(decoded.conversationId, "conversation-42")
        XCTAssertEqual(decoded.contentType, .poll)
        XCTAssertEqual(decoded.senderDeviceId, "device-ios-1")
        XCTAssertEqual(decoded.operationId, "poll-create-1")
    }

    func testAESGCMV1RoundtripPayloadShape() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data("secret".utf8), using: key, nonce: nonce)
        var combined = Data(sealed.ciphertext)
        combined.append(sealed.tag)
        let payload = E2EEPayload(
            v: 1,
            ivB64: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertextB64: combined.base64EncodedString(),
            aadB64: nil
        )

        let data = try XCTUnwrap(Data(base64Encoded: payload.ciphertextB64))
        let iv = try XCTUnwrap(Data(base64Encoded: payload.ivB64))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        XCTAssertEqual(String(data: plain, encoding: .utf8), "secret")
    }

    func testInvalidRSAJWKFailsGracefully() {
        XCTAssertThrowsError(try E2EEService.unwrapConversationKey(wrappedKeyB64: "bad", privateJwk: "{}"))
    }

    func testWipeLocalKeysClearsPrivateAndConversationKeys() async throws {
        let store = InMemoryTokenStore()
        try store.set("{\"kty\":\"RSA\"}", for: "privateJwk:current")
        try store.set("{\"kty\":\"RSA\"}", for: "privateJwk:u1")
        try store.set(Data(repeating: 7, count: 32).base64EncodedString(), for: "conversation:c1")
        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: store)

        await service.wipeLocalKeys()

        XCTAssertNil(try store.string(for: "privateJwk:current"))
        XCTAssertNil(try store.string(for: "privateJwk:u1"))
        XCTAssertNil(try store.string(for: "conversation:c1"))
        let unlocked = await service.isUnlocked()
        XCTAssertFalse(unlocked)
    }

    /// La clé publique JWK d'une clé v1 sait wrapper une clé de conversation que
    /// sa clé privée JWK sait dé-wrapper — l'aller-retour exact utilisé entre
    /// participants iOS/Android/web. L'app ne crée plus de clé v1 (lot 10.5) :
    /// `LegacyKeyFixture` en fabrique une au format commun.
    func testLegacyKeyWrapUnwrapRoundTrip() throws {
        let key = try LegacyKeyFixture(password: "correct horse battery")
        let privateObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(key.privateJwk.utf8)) as? [String: String])

        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let wrapped = try E2EEService.wrapConversationKey(rawKey: rawKey, publicJwk: key.publicJwk)
        XCTAssertFalse(wrapped.contains("="), "wrappedKeyB64 doit être sans padding")
        let unwrapped = try E2EEService.unwrapConversationKey(wrappedKeyB64: wrapped, privateJwk: key.privateJwk)
        XCTAssertEqual(unwrapped, rawKey)

        // Clé créée sur le site : WebCrypto exporte aussi `alg`, `ext` (booléen) et
        // `key_ops` (tableau) ; elle doit s'ouvrir pareil (pile QA, 12/11).
        var webObject: [String: Any] = privateObj
        webObject["alg"] = "RSA-OAEP-256"
        webObject["ext"] = true
        webObject["key_ops"] = ["decrypt"]
        let webJwk = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: webObject), encoding: .utf8))
        XCTAssertEqual(try E2EEService.unwrapConversationKey(wrappedKeyB64: wrapped, privateJwk: webJwk), rawKey)
    }

    /// Signalement d'un message chiffré (SOC-12) : la clé de la conversation
    /// part chiffrée pour la clé publique de modération, en base64 standard
    /// comme le web, et seule la clé privée de modération la rouvre.
    func testModerationWrapOpensOnlyWithModerationKey() throws {
        // Une paire RSA quelconque tient lieu de clé de modération.
        let moderation = try LegacyKeyFixture(password: "correct horse battery")
        let moderationPrivate = moderation.privateJwk
        let moderationPublic = moderation.publicJwk

        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let wrapped = try E2EEService.wrapForModeration(rawKey: rawKey, publicJwk: moderationPublic)
        XCTAssertNotNil(Data(base64Encoded: wrapped), "base64 standard attendu, comme le web")
        XCTAssertEqual(try E2EEService.unwrapConversationKey(wrappedKeyB64: wrapped, privateJwk: moderationPrivate), rawKey)
        XCTAssertThrowsError(try E2EEService.wrapForModeration(rawKey: rawKey, publicJwk: "{}"))
    }

    /// Une clé v1 se déverrouille à partir des champs servis par
    /// GET /api/e2ee/bootstrap (PBKDF2 210k + AES-GCM), comme sur un autre
    /// appareil : la clé privée est gardée, et elle correspond à la clé publique.
    func testLegacyBootstrapFieldsUnlockWithPassword() async throws {
        let key = try LegacyKeyFixture(password: "s3cret-pass")
        let store = InMemoryTokenStore()
        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: store)

        try await service.unlock(userId: "u1", password: "s3cret-pass", bootstrapKey: key.bootstrapKey)

        XCTAssertEqual(try store.string(for: "privateJwk:current"), key.privateJwk)
        XCTAssertEqual(try store.string(for: "privateJwk:u1"), key.privateJwk)
        let unlocked = await service.isUnlocked()
        XCTAssertTrue(unlocked)
        XCTAssertTrue(E2EEService.privateJwk(key.privateJwk, matchesPublicJwk: key.publicJwk))
    }

    /// E2EE-UX-03 — Un mot de passe erroné doit remonter `.wrongPassword`
    /// (message FR clair), PAS une CryptoKitError technique, et ne rien garder.
    func testWrongPasswordMapsToWrongPasswordError() async throws {
        let key = try LegacyKeyFixture(password: "s3cret-pass")
        let store = InMemoryTokenStore()
        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: store)

        do {
            try await service.unlock(userId: "u1", password: "mauvais-mot-de-passe", bootstrapKey: key.bootstrapKey)
            XCTFail("Un mauvais mot de passe doit échouer")
        } catch {
            XCTAssertEqual(error as? E2EEError, .wrongPassword)
        }
        XCTAssertNil(try store.string(for: "privateJwk:current"))
    }

    func testE2EECleartextSendBlockedWithoutKey() async {
        let conversation = MessageConversation(
            id: "c1",
            title: "Secure",
            isGroup: false,
            e2eeEnabled: true,
            groupPhotoUrl: nil,
            createdAt: nil,
            updatedAt: nil,
            lastMessageAt: nil,
            lastReadAt: nil,
            pinnedAt: nil,
            participants: [],
            lastMessage: nil
        )
        let service = MessagesService(api: APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore())))
        do {
            _ = try await service.sendText("hello", in: conversation, e2ee: nil)
            XCTFail("Expected locked E2EE error")
        } catch let error as E2EEError {
            XCTAssertEqual(error, .locked)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// Invariant E2EE (réception) : un message marqué chiffré mais SANS iv/ciphertext
    /// est malformé — `decryptText` doit lever `.decryptFailed` et ne JAMAIS retomber
    /// sur le `content` en clair. On fournit volontairement un `content` clair pour
    /// vérifier qu'il n'est jamais renvoyé.
    func testDecryptTextNeverFallsBackToCleartextOnMissingFields() async throws {
        let json = Data(#"{"id":"m1","conversationId":"c1","content":"hello-en-clair"}"#.utf8)
        let message = try JSONDecoder().decode(MessageItem.self, from: json)
        XCTAssertNil(message.e2eeIvB64)
        XCTAssertNil(message.e2eeCiphertextB64)

        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: InMemoryTokenStore())
        do {
            _ = try await service.decryptText(conversationId: "c1", message: message)
            XCTFail("decryptText doit lever .decryptFailed, jamais renvoyer le clair")
        } catch let error as E2EEError {
            XCTAssertEqual(error, .decryptFailed)
        } catch {
            XCTFail("Erreur inattendue \(error)")
        }
    }

    func testV2DeviceApprovalPushRoutesOnlyThroughValidatedOpaqueIdentifier() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pushSource = try String(
            contentsOf: repository.appendingPathComponent(
                "SignalQuestApp/Core/Push/PushNotificationService.swift"
            ),
            encoding: .utf8
        )
        let routerSource = try String(
            contentsOf: repository.appendingPathComponent(
                "SignalQuestApp/Core/Routing/AppRouter.swift"
            ),
            encoding: .utf8
        )
        let profileSource = try String(
            contentsOf: repository.appendingPathComponent(
                "SignalQuestApp/Features/Profile/ProfileView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(pushSource.contains("E2EEV2DeviceApprovalContract.pushApprovalID"))
        XCTAssertTrue(pushSource.contains("e2eeDeviceApprovalId: e2eeDeviceApprovalId"))
        XCTAssertTrue(routerSource.contains("openE2EEDeviceApprovalId"))
        XCTAssertTrue(routerSource.contains("case \"e2ee_v2_device_approval\""))
        // E2EE-REVOKE-SYNC r1 (09/11) : le lien ouvre les appareils du journal,
        // plus l'écran v2 qui révoquait sans écrire le journal.
        XCTAssertTrue(profileSource.contains("deepLinkE2EEApproval = E2EEDeviceApprovalDeepLink(id: id)"))
        XCTAssertFalse(profileSource.contains("initialApprovalId: link.id"))
        XCTAssertTrue(profileSource.contains("consumeE2EEApprovalDeepLink"))
    }
}

final class E2EEV2ContentContractTests: XCTestCase {
    private func opaque(_ prefix: String) -> String {
        "\(prefix)_0123456789abcdef"
    }

    func testSharedLocationFixtureParsesAndRoundTrips() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try Data(contentsOf: repository.appendingPathComponent(
            "contracts/e2ee-v2/content-payload-v1.json"
        ))

        let parsed = try XCTUnwrap(E2EEV2ContentContract.parse(fixture))
        XCTAssertEqual(parsed["kind"] as? String, "LOCATION")
        let body = try XCTUnwrap(parsed["body"] as? [String: Any])
        XCTAssertEqual((body["latitude"] as? NSNumber)?.doubleValue, 48.8566)
        XCTAssertNotNil(E2EEV2ContentContract.parse(try E2EEV2ContentContract.encode(parsed)))
    }

    func testSharedWorldLiveLocationFixturePreservesServingAndSIMIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try Data(contentsOf: repository.appendingPathComponent(
            "contracts/e2ee-v2/live-location-payload-v1.json"
        ))

        let parsed = try XCTUnwrap(E2EEV2ContentContract.parse(fixture))
        XCTAssertEqual(parsed["kind"] as? String, "LIVE_LOCATION")
        let body = try XCTUnwrap(parsed["body"] as? [String: Any])
        let radio = try XCTUnwrap(body["radio"] as? [String: Any])
        XCTAssertEqual(radio["observedPlmn"] as? String, "310001")
        XCTAssertEqual(radio["simPlmn"] as? String, "20820")
        XCTAssertEqual(radio["isRoaming"] as? Bool, true)
        XCTAssertEqual(radio["ci"] as? String, "3112966")
        XCTAssertTrue(radio["gnb"] is NSNull)
        XCTAssertNotNil(E2EEV2ContentContract.parse(try E2EEV2ContentContract.encode(parsed)))
    }

    func testEveryPrivateOperationIsAccepted() throws {
        let blob = manifest()
        let samples: [[String: Any]] = [
            root("TEXT", ["text": "Bonjour 🌍"]),
            root("EDIT", ["targetMessageId": opaque("message"), "text": "Corrigé"]),
            root("REACTION", [
                "targetMessageId": opaque("message"), "emoji": "👍", "action": "ADD",
            ]),
            root("DELETE", ["targetMessageId": opaque("message")]),
            root("MEDIA", ["caption": "Photo", "attachments": [blob]]),
            root("AUDIO", [
                "caption": NSNull(),
                "attachment": blob.merging(["durationMs": 2_400]) { _, new in new },
                "durationMs": 2_400,
                "transcription": [
                    "status": "COMPLETE", "language": "fr", "text": "Bonjour", "confidence": 0.98,
                ],
            ]),
            root("LOCATION", [
                "latitude": 48.8566,
                "longitude": 2.3522,
                "accuracyMeters": 12.5,
                "altitudeMeters": NSNull(),
                "label": "Paris",
            ]),
            root("LIVE_LOCATION", [
                "sessionId": opaque("live"),
                "sequence": 4,
                "latitude": -34.6037,
                "longitude": -58.3816,
                "accuracyMeters": 8,
                "observedAt": "2026-08-24T12:00:00.000Z",
                "expiresAt": "2026-08-24T12:15:00.000Z",
            ]),
            root("CARD", [
                "cardType": "SPEEDTEST", "cardVersion": 1, "payload": ["downloadMbps": 73.1],
            ]),
            root("POLL", [
                "question": "Quel réseau ?",
                "options": [
                    ["id": opaque("optionA"), "label": "5G SA"],
                    ["id": opaque("optionB"), "label": "5G NSA"],
                ],
                "multipleChoice": false,
                "closesAt": NSNull(),
            ]),
            root("POLL_VOTE", [
                "targetMessageId": opaque("message"), "optionIds": [opaque("optionA")],
            ]),
            root("TASK", [
                "taskId": opaque("task"),
                "title": "Vérifier le site",
                "status": "OPEN",
                "dueAt": NSNull(),
                "assigneeIds": [opaque("user")],
            ]),
        ]

        for sample in samples {
            XCTAssertNotNil(E2EEV2ContentContract.parse(try E2EEV2ContentContract.encode(sample)))
        }
    }

    func testParserRejectsLeaksUnknownFieldsAndInvalidValues() throws {
        var leaked = root("TEXT", ["text": "secret"])
        leaked["preview"] = "secret"
        XCTAssertNil(E2EEV2ContentContract.parse(try JSONSerialization.data(withJSONObject: leaked)))

        let badLocation = root("LOCATION", [
            "latitude": 91,
            "longitude": 2,
            "accuracyMeters": NSNull(),
            "altitudeMeters": NSNull(),
            "label": NSNull(),
        ])
        XCTAssertNil(E2EEV2ContentContract.parse(try JSONSerialization.data(withJSONObject: badLocation)))

        var badManifest = manifest()
        badManifest["mediaKeyB64"] = "visible-secret"
        let media = root("MEDIA", ["caption": NSNull(), "attachments": [badManifest]])
        XCTAssertNil(E2EEV2ContentContract.parse(try JSONSerialization.data(withJSONObject: media)))

        let dangerousCard = root("CARD", [
            "cardType": "RADIO",
            "cardVersion": 1,
            "payload": ["__proto__": ["polluted": true]],
        ])
        XCTAssertNil(E2EEV2ContentContract.parse(try JSONSerialization.data(withJSONObject: dangerousCard)))

        let invalidWorldLiveShare = root("LIVE_LOCATION", [
            "sessionId": opaque("live"),
            "sequence": 4,
            "latitude": 40.7128,
            "longitude": -74.006,
            "accuracyMeters": 8.5,
            "altitudeMeters": NSNull(),
            "speedMetersPerSecond": NSNull(),
            "headingDegrees": NSNull(),
            "observedAt": "2026-08-26T12:00:00.000Z",
            "expiresAt": "2026-08-26T12:15:00.000Z",
            "radio": liveShareRadio(observedPLMN: "31001A"),
        ])
        XCTAssertNil(E2EEV2ContentContract.parse(
            try JSONSerialization.data(withJSONObject: invalidWorldLiveShare)
        ))
    }

    private func root(_ kind: String, _ body: [String: Any]) -> [String: Any] {
        [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": kind,
            "replyToId": NSNull(),
            "mentions": [],
            "body": body,
        ]
    }

    private func manifest() -> [String: Any] {
        [
            "blobId": opaque("blob"),
            "algorithm": "AES_256_GCM_CHUNKED_HKDF_SHA256",
            "mediaKeyB64": Data(repeating: 7, count: 32).base64EncodedString(),
            "noncePrefixB64": Data(repeating: 3, count: 8).base64EncodedString(),
            "cryptoChunkSize": 256 * 1_024,
            "plaintextSize": "12",
            "ciphertextSize": "28",
            "plaintextSha256": String(repeating: "a", count: 64),
            "ciphertextSha256": String(repeating: "b", count: 64),
            "fileName": "terrain.webp",
            "mimeType": "image/webp",
            "width": 1200,
            "height": 900,
            "durationMs": NSNull(),
        ]
    }

    private func liveShareRadio(observedPLMN: String) -> [String: Any] {
        [
            "connectionType": "5G NSA",
            "technology": "LTE",
            "operator": "T-Mobile US",
            "observedPlmn": observedPLMN,
            "simPlmn": "20820",
            "simOperator": "Bouygues Telecom",
            "isRoaming": true,
            "enb": "12197",
            "gnb": NSNull(),
            "cellId": "3112966",
            "ci": "3112966",
            "pci": 321,
            "band": 2,
            "bandwidth": 20_000,
            "earfcn": 975,
            "arfcn": NSNull(),
            "rsrp": -93,
            "rsrq": -16,
            "snr": 2,
            "rssi": -71,
            "tac": "42",
            "is5GNSA": true,
            "is5GSA": false,
            "batterySaver": false,
        ]
    }
}

final class E2EEV2MessageComposerTests: XCTestCase {
    private let conversationId = "conversation_01J7ABCD23456789"
    private let clientRequestId = "request_01J7ABCD23456789"

    func testContractPreviewBuildsVerifiableEnvelopeWithoutPublicPrivateContent() throws {
        let signingKey = P256.Signing.PrivateKey()
        let epochKey = Data((1...32).map(UInt8.init))
        let epoch = try storedEpoch(epochKey)
        let device = device(signingKey)
        let nonce = Data((10...21).map(UInt8.init))
        let content = textContent()

        let signed = try E2EEV2MessageComposer.prepareContractPreview(
            input: input(content),
            device: device,
            epoch: epoch,
            nonce: nonce,
            signer: { try E2EEV2LowS.sign($0, with: signingKey) }
        )
        let envelope = unsigned(signed)
        let context = E2EEV2MessageContext(
            conversationId: conversationId,
            epochNumber: epoch.epochNumber,
            senderDeviceId: device.deviceId,
            clientRequestId: clientRequestId,
            ttlSeconds: 3_600,
            encryptedBlobIds: []
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: XCTUnwrap(Data(base64Encoded: signed.senderSignatureB64))
        )
        XCTAssertTrue(signingKey.publicKey.isValidSignature(
            signature,
            for: try E2EEV2MessageCrypto.signatureCanonical(context: context, envelope: envelope)
        ))
        var cleartext = try E2EEV2MessageCrypto.decrypt(
            envelope: envelope,
            epochKey: epochKey,
            context: context
        )
        defer { cleartext.resetBytes(in: 0..<cleartext.count) }
        XCTAssertEqual(
            try JSONSerialization.data(
                withJSONObject: XCTUnwrap(E2EEV2ContentContract.parse(cleartext)),
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            try E2EEV2ContentContract.encode(content)
        )
        let encodedEnvelope = try JSONEncoder().encode(signed)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedEnvelope) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), [
            "envelopeVersion", "epochNumber", "clientRequestId", "algorithm",
            "contentType", "keyCommitmentB64", "ttlSeconds", "encryptedBlobIds",
            "nonceB64", "aadB64", "ciphertextB64", "senderSignatureB64",
        ])
        XCTAssertFalse(String(decoding: encodedEnvelope, as: UTF8.self)
            .contains("secret-message-never-public"))
        XCTAssertEqual(epochKey, Data((1...32).map(UInt8.init)))
        XCTAssertEqual(nonce, Data((10...21).map(UInt8.init)))
    }

    func testRuntimeGateBlocksBeforeLocalStateOrNonceAccess() {
        var localStateReads = 0
        var nonceReads = 0
        let result = E2EEV2MessageComposer.prepareRuntimeWithStateLoader(
            input: input(textContent()),
            nonceProvider: {
                nonceReads += 1
                return Data(repeating: 0, count: 12)
            },
            localStateLoader: {
                localStateReads += 1
                return nil
            }
        )

        XCTAssertEqual(result, .blocked(reason: "e2ee-v2-security-review-required"))
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertEqual(localStateReads, 0)
        XCTAssertEqual(nonceReads, 0)
    }

    func testPrivateMediaManifestAndRoutingMustMatchBeforeSignature() throws {
        let signingKey = P256.Signing.PrivateKey()
        let blobId = "blob_01J7ABCD234567890123"
        var signatures = 0
        let media = root("MEDIA", [
            "caption": NSNull(),
            "attachments": [manifest(blobId: blobId)],
        ])
        XCTAssertThrowsError(try E2EEV2MessageComposer.prepareContractPreview(
            input: input(media, encryptedBlobIds: []),
            device: device(signingKey),
            epoch: storedEpoch(Data(repeating: 7, count: 32)),
            nonce: Data(repeating: 0, count: 12),
            signer: {
                signatures += 1
                return try E2EEV2LowS.sign($0, with: signingKey)
            }
        ))
        XCTAssertEqual(signatures, 0)
    }

    func testSignatureFromAnotherDeviceFailsClosed() throws {
        let expectedKey = P256.Signing.PrivateKey()
        let wrongKey = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try E2EEV2MessageComposer.prepareContractPreview(
            input: input(textContent()),
            device: device(expectedKey),
            epoch: storedEpoch(Data(repeating: 5, count: 32)),
            nonce: Data(repeating: 0, count: 12),
            signer: { try E2EEV2LowS.sign($0, with: wrongKey) }
        )) { error in
            XCTAssertEqual(error as? E2EEV2MessageCryptoError, .invalidEnvelope)
        }
    }

    private func input(
        _ content: [String: Any],
        encryptedBlobIds: [String] = []
    ) -> E2EEV2MessagePreparationInput {
        .init(
            conversationId: conversationId,
            clientRequestId: clientRequestId,
            ttlSeconds: 3_600,
            encryptedBlobIds: encryptedBlobIds,
            content: content
        )
    }

    private func textContent() -> [String: Any] {
        root("TEXT", ["text": "secret-message-never-public"])
    }

    private func root(_ kind: String, _ body: [String: Any]) -> [String: Any] {
        [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": kind,
            "replyToId": NSNull(),
            "mentions": [],
            "body": body,
        ]
    }

    private func manifest(blobId: String) -> [String: Any] {
        [
            "blobId": blobId,
            "algorithm": "AES_256_GCM_CHUNKED_HKDF_SHA256",
            "mediaKeyB64": Data(repeating: 1, count: 32).base64EncodedString(),
            "noncePrefixB64": Data(repeating: 2, count: 8).base64EncodedString(),
            "cryptoChunkSize": 256 * 1_024,
            "plaintextSize": "4",
            "ciphertextSize": "20",
            "plaintextSha256": String(repeating: "a", count: 64),
            "ciphertextSha256": String(repeating: "b", count: 64),
            "fileName": "photo-privee.jpg",
            "mimeType": "image/jpeg",
            "width": 1_080,
            "height": 1_920,
            "durationMs": NSNull(),
        ]
    }

    private func storedEpoch(_ epochKey: Data) throws -> E2EEV2StoredEpochKey {
        .init(
            conversationId: conversationId,
            epochId: "epoch_01J7ABCD234567890123",
            epochNumber: 7,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
            epochKey: epochKey
        )
    }

    private func device(_ signingKey: P256.Signing.PrivateKey) -> E2EEV2DeviceDescriptor {
        let identityKey = P256.KeyAgreement.PrivateKey()
        return .init(
            deviceId: "ios_01J7ABCD234567890123",
            platform: "ios",
            label: "iPhone QA",
            publicIdentityKeyB64: identityKey.publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signingKey.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
            keyVersion: 1
        )
    }

    private func unsigned(_ signed: E2EEV2SignedMessageEnvelope) -> E2EEV2MessageEnvelope {
        .init(
            envelopeVersion: signed.envelopeVersion,
            epochNumber: signed.epochNumber,
            clientRequestId: signed.clientRequestId,
            algorithm: signed.algorithm,
            contentType: signed.contentType,
            keyCommitmentB64: signed.keyCommitmentB64,
            ttlSeconds: signed.ttlSeconds,
            encryptedBlobIds: signed.encryptedBlobIds,
            nonceB64: signed.nonceB64,
            aadB64: signed.aadB64,
            ciphertextB64: signed.ciphertextB64
        )
    }
}

final class E2EEV2MessageReceiverTests: XCTestCase {
    private let ownerScopeId = "user:owner_01J7ABCD23456789"
    private let conversationId = "conversation_01J7ABCD23456789"
    private let clientRequestId = "request_01J7ABCD23456789"

    func testContractReceiverVerifiesDecryptsAndValidatesPrivateContent() throws {
        let signingKey = P256.Signing.PrivateKey()
        let epochKey = Data((1...32).map(UInt8.init))
        let epoch = try storedEpoch(epochKey)
        let device = device(signingKey)
        let content = locationContent()
        let signed = try E2EEV2MessageComposer.prepareContractPreview(
            input: preparationInput(content),
            device: device,
            epoch: epoch,
            nonce: Data((10...21).map(UInt8.init)),
            signer: { try E2EEV2LowS.sign($0, with: signingKey) }
        )
        let envelopeData = try JSONEncoder().encode(signed)
        let originalEnvelopeData = envelopeData

        let message = try E2EEV2MessageReceiver.decryptContractPreview(
            input: incoming(
                senderDeviceId: device.deviceId,
                senderPublicSigningKeyB64: device.publicSigningKeyB64,
                envelopeData: envelopeData
            ),
            epoch: epoch
        )

        XCTAssertEqual(message.epochNumber, 7)
        XCTAssertEqual(message.clientRequestId, clientRequestId)
        XCTAssertEqual(message.encryptedBlobIds, [])
        XCTAssertEqual(
            try E2EEV2ContentContract.encode(message.content),
            try E2EEV2ContentContract.encode(content)
        )
        XCTAssertEqual(epochKey, Data((1...32).map(UInt8.init)))
        XCTAssertEqual(envelopeData, originalEnvelopeData)
    }

    func testRuntimeReadGateRefusesBeforeParsingOrEpochAccess() throws {
        var epochReads = 0
        let result = E2EEV2MessageReceiver.decryptRuntimeWithEpochLoader(
            input: incoming(
                senderDeviceId: "invalid",
                senderPublicSigningKeyB64: "invalid",
                envelopeData: try JSONSerialization.data(withJSONObject: [
                    "privateLeak": "must-not-be-parsed",
                ])
            ),
            epochLoader: { _ in
                epochReads += 1
                return nil
            }
        )

        XCTAssertFalse(E2EEV2RuntimeReadGate.enabled)
        guard case .blocked(let reason) = result else {
            return XCTFail("Le verrou de lecture doit bloquer le runtime")
        }
        XCTAssertEqual(reason, "e2ee-v2-security-review-required")
        XCTAssertEqual(epochReads, 0)
    }

    func testValidEnvelopeWithAnotherSenderKeyFailsClosed() throws {
        let signingKey = P256.Signing.PrivateKey()
        let unrelatedKey = P256.Signing.PrivateKey()
        let epoch = try storedEpoch(Data(repeating: 4, count: 32))
        let device = device(signingKey)
        let signed = try E2EEV2MessageComposer.prepareContractPreview(
            input: preparationInput(locationContent()),
            device: device,
            epoch: epoch,
            nonce: Data(repeating: 0, count: 12),
            signer: { try E2EEV2LowS.sign($0, with: signingKey) }
        )

        XCTAssertThrowsError(try E2EEV2MessageReceiver.decryptContractPreview(
            input: incoming(
                senderDeviceId: device.deviceId,
                senderPublicSigningKeyB64: unrelatedKey.publicKey.x963Representation.base64EncodedString(),
                envelopeData: JSONEncoder().encode(signed)
            ),
            epoch: epoch
        )) { error in
            XCTAssertEqual(error as? E2EEV2MessageCryptoError, .invalidEnvelope)
        }
    }

    func testPrivateContentAndSignedBlobRoutingMustMatchAfterDecryption() throws {
        let signingKey = P256.Signing.PrivateKey()
        let epochKey = Data(repeating: 5, count: 32)
        let epoch = try storedEpoch(epochKey)
        let device = device(signingKey)
        let blobId = "blob_01J7ABCD234567890123"
        let context = E2EEV2MessageContext(
            conversationId: conversationId,
            epochNumber: epoch.epochNumber,
            senderDeviceId: device.deviceId,
            clientRequestId: clientRequestId,
            ttlSeconds: 3_600,
            encryptedBlobIds: [blobId]
        )
        var cleartext = try E2EEV2ContentContract.encode(locationContent())
        defer { cleartext.resetBytes(in: 0..<cleartext.count) }
        let unsigned = try E2EEV2MessageCrypto.encrypt(
            cleartext: cleartext,
            epochKey: epochKey,
            nonce: Data((20...31).map(UInt8.init)),
            context: context
        )
        var canonical = try E2EEV2MessageCrypto.signatureCanonical(
            context: context,
            envelope: unsigned
        )
        defer { canonical.resetBytes(in: 0..<canonical.count) }
        var signature = try E2EEV2LowS.sign(canonical, with: signingKey)
        defer { signature.resetBytes(in: 0..<signature.count) }
        let signed = E2EEV2SignedMessageEnvelope(
            envelope: unsigned,
            senderSignatureB64: signature.base64EncodedString()
        )

        XCTAssertThrowsError(try E2EEV2MessageReceiver.decryptContractPreview(
            input: incoming(
                senderDeviceId: device.deviceId,
                senderPublicSigningKeyB64: device.publicSigningKeyB64,
                envelopeData: JSONEncoder().encode(signed)
            ),
            epoch: epoch
        )) { error in
            XCTAssertEqual(error as? E2EEV2MessageCryptoError, .invalidEnvelope)
        }
    }

    func testEnvelopeWithUnknownPublicFieldFailsClosed() throws {
        let signingKey = P256.Signing.PrivateKey()
        let epoch = try storedEpoch(Data(repeating: 8, count: 32))
        let device = device(signingKey)
        let signed = try E2EEV2MessageComposer.prepareContractPreview(
            input: preparationInput(locationContent()),
            device: device,
            epoch: epoch,
            nonce: Data(repeating: 0, count: 12),
            signer: { try E2EEV2LowS.sign($0, with: signingKey) }
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as? [String: Any]
        )
        root["privateMetadata"] = "forbidden"

        XCTAssertThrowsError(try E2EEV2MessageReceiver.decryptContractPreview(
            input: incoming(
                senderDeviceId: device.deviceId,
                senderPublicSigningKeyB64: device.publicSigningKeyB64,
                envelopeData: JSONSerialization.data(withJSONObject: root)
            ),
            epoch: epoch
        )) { error in
            XCTAssertEqual(error as? E2EEV2MessageCryptoError, .invalidEnvelope)
        }
    }

    private func incoming(
        senderDeviceId: String,
        senderPublicSigningKeyB64: String,
        envelopeData: Data
    ) -> E2EEV2IncomingMessageInput {
        .init(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            senderDeviceId: senderDeviceId,
            senderPublicSigningKeyB64: senderPublicSigningKeyB64,
            envelopeData: envelopeData
        )
    }

    private func preparationInput(_ content: [String: Any]) -> E2EEV2MessagePreparationInput {
        .init(
            conversationId: conversationId,
            clientRequestId: clientRequestId,
            ttlSeconds: 3_600,
            encryptedBlobIds: [],
            content: content
        )
    }

    private func locationContent() -> [String: Any] {
        [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": "LOCATION",
            "replyToId": NSNull(),
            "mentions": [],
            "body": [
                "latitude": 48.8566,
                "longitude": 2.3522,
                "accuracyMeters": 5.0,
                "altitudeMeters": NSNull(),
                "label": "Position privée",
            ],
        ]
    }

    private func storedEpoch(_ epochKey: Data) throws -> E2EEV2StoredEpochKey {
        .init(
            conversationId: conversationId,
            epochId: "epoch_01J7ABCD234567890123",
            epochNumber: 7,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
            epochKey: epochKey
        )
    }

    private func device(_ signingKey: P256.Signing.PrivateKey) -> E2EEV2DeviceDescriptor {
        let identityKey = P256.KeyAgreement.PrivateKey()
        return .init(
            deviceId: "ios_01J7ABCD234567890123",
            platform: "ios",
            label: "iPhone QA",
            publicIdentityKeyB64: identityKey.publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signingKey.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
            keyVersion: 1
        )
    }
}

final class E2EEV2LiveShareTransportTests: XCTestCase {
    private let sessionId = "live_0123456789abcdef"
    private let clientRequestId = "live-request-0123456789abcdef"

    func testRuntimeGatesRefuseBeforeLocalStateCryptoOrNetwork() async {
        var preparations = 0
        var identityReads = 0
        var epochReads = 0
        var unwraps = 0
        var requests = 0
        let publish = await E2EEV2LiveShareTransportClient.publishRuntimeWithDependencies(
            .init(
                ownerScopeId: "invalid",
                sessionId: "invalid",
                preparation: preparationInput()
            ),
            dependencies: .init(
                prepareEnvelope: {
                    preparations += 1
                    return .blocked(reason: "must-not-run")
                },
                postJSON: { _, _ in
                    requests += 1
                    return .failure(.init(kind: .localState, message: "must-not-run"))
                }
            )
        )
        if case .failure(let failure) = publish {
            XCTAssertEqual(failure.kind, .activationBlocked)
        } else {
            XCTFail("Live Share write gate must remain closed")
        }

        let fetch = await E2EEV2LiveShareTransportClient.fetchLatestRuntimeWithDependencies(
            .init(ownerScopeId: "invalid", conversationId: "invalid", sessionId: "invalid"),
            dependencies: .init(
                loadIdentity: {
                    identityReads += 1
                    return nil
                },
                postJSON: { _, _ in
                    requests += 1
                    return .failure(.init(kind: .localState, message: "must-not-run"))
                },
                loadEpoch: { _, _ in
                    epochReads += 1
                    return nil
                },
                unwrapEpoch: { _ in
                    unwraps += 1
                    return Data()
                },
                now: Date.init
            )
        )
        if case .failure(let failure) = fetch {
            XCTAssertEqual(failure.kind, .activationBlocked)
        } else {
            XCTFail("Live Share read gate must remain closed")
        }
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertFalse(E2EEV2RuntimeReadGate.enabled)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(identityReads, 0)
        XCTAssertEqual(epochReads, 0)
        XCTAssertEqual(unwraps, 0)
        XCTAssertEqual(requests, 0)

        let client = E2EEV2LiveShareTransportClient(api: APIClient())
        if case .failure(let failure) = await client.createSessionRuntime(
            ownerScopeId: "invalid",
            conversationId: "invalid",
            body: Data("not-json".utf8)
        ) {
            XCTAssertEqual(failure.kind, .activationBlocked)
        } else {
            XCTFail("Live Share lifecycle gate must remain closed")
        }
        if case .failure(let failure) = await client.acceptSessionRuntime(
            ownerScopeId: "invalid",
            sessionId: "invalid"
        ) {
            XCTAssertEqual(failure.kind, .activationBlocked)
        } else {
            XCTFail("Live Share acceptance gate must remain closed")
        }
    }

    func testLifecycleResponsesRequireV2MarkerExpiryAndNoLegacyPayload() throws {
        let session: [String: Any] = [
            "id": sessionId,
            "conversationId": "conversation_0123456789abcdef",
            "requesterId": "user_requester_0123456789abcdef",
            "sharerId": "user_sharer_0123456789abcdef",
            "status": "active",
            "expiresAt": "2026-08-26T12:15:00.000Z",
            "e2eeV2Required": true,
            "lastPayload": NSNull(),
            "lastLocation": NSNull(),
        ]
        let create = try JSONSerialization.data(withJSONObject: [
            "mode": "targeted",
            "createdCount": 1,
            "skippedCount": 0,
            "sessions": [session],
            "session": session,
        ])
        let sessions = try XCTUnwrap(
            E2EEV2LiveShareTransportClient.parseCreateResponseContractPreview(
                create,
                expectedConversationId: "conversation_0123456789abcdef"
            )
        )
        XCTAssertEqual(sessions.first?.id, sessionId)
        let decoded = try JSONDecoder.signalQuest.decode(
            LiveShareSession.self,
            from: try XCTUnwrap(sessions.first?.valueData)
        )
        XCTAssertEqual(decoded.e2eeV2Required, true)
        XCTAssertNotNil(decoded.expiresAt)
        XCTAssertNil(decoded.decodedPayload)

        XCTAssertNotNil(E2EEV2LiveShareTransportClient.parseAcceptResponseContractPreview(
            try JSONSerialization.data(withJSONObject: ["session": session]),
            expectedSessionId: sessionId
        ))
        var leaked = session
        leaked["lastPayload"] = "{\"latitude\":48}"
        XCTAssertNil(E2EEV2LiveShareTransportClient.parseAcceptResponseContractPreview(
            try JSONSerialization.data(withJSONObject: ["session": leaked]),
            expectedSessionId: sessionId
        ))
    }

    func testLiveShareSequenceAndOpaquePendingEnvelopeSurviveStoreRecreation() throws {
        let tokenStore = InMemoryTokenStore()
        let ownerScopeId = "user:owner_01J7ABCD23456789"
        let conversationId = "conversation_0123456789abcdef"
        let first = E2EEV2LiveShareStateStore(tokenStore: tokenStore)
        XCTAssertEqual(try first.claimSequence(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId,
            nowMs: 1_000
        ), 0)
        let unsigned = E2EEV2MessageEnvelope(
            envelopeVersion: 1,
            epochNumber: 7,
            clientRequestId: clientRequestId,
            algorithm: E2EEV2MessageCrypto.algorithm,
            contentType: E2EEV2MessageCrypto.contentType,
            keyCommitmentB64: Data(repeating: 1, count: 32).base64EncodedString(),
            ttlSeconds: 900,
            encryptedBlobIds: [],
            nonceB64: Data(repeating: 2, count: 12).base64EncodedString(),
            aadB64: Data("opaque-aad".utf8).base64EncodedString(),
            ciphertextB64: Data(repeating: 3, count: 64).base64EncodedString()
        )
        let pending = E2EEV2LiveSharePendingEnvelope(
            clientRequestId: clientRequestId,
            sendDeadlineAtMs: 61_000,
            envelope: .init(
                envelope: unsigned,
                senderSignatureB64: Data(repeating: 4, count: 70).base64EncodedString()
            )
        )
        try first.storePending(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId,
            pending: pending,
            nowMs: 1_000
        )

        let restored = E2EEV2LiveShareStateStore(tokenStore: tokenStore)
        XCTAssertEqual(try restored.pending(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId
        ), pending)
        try restored.complete(
            ownerScopeId: ownerScopeId,
            sessionId: sessionId,
            clientRequestId: clientRequestId,
            nowMs: 2_000
        )
        XCTAssertNil(try restored.pending(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId
        ))
        XCTAssertEqual(try restored.claimSequence(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId,
            nowMs: 2_001
        ), 1)
    }

    func testOpaqueEventContractAndClosedRuntimeStream() async throws {
        XCTAssertEqual(E2EEV2LiveShareEventContract.parse(
            event: "status",
            data: "{\"status\":\"active\"}",
            eventId: "status-1"
        ), .status(value: "active", eventId: "status-1"))
        XCTAssertNotNil(E2EEV2LiveShareEventContract.parse(
            event: "encrypted_update",
            data: """
            {"updateId":"update_0123456789abcdef","createdAt":"2026-08-26T12:00:00.000Z","expiresAt":"2026-08-26T12:15:00.000Z"}
            """,
            eventId: "update_0123456789abcdef"
        ))
        XCTAssertNil(E2EEV2LiveShareEventContract.parse(
            event: "encrypted_update",
            data: """
            {"updateId":"update_0123456789abcdef","createdAt":"2026-08-26T12:00:00.000Z","expiresAt":"2026-08-26T12:15:00.000Z","latitude":48}
            """,
            eventId: nil
        ))

        var received: [E2EEV2LiveShareEvent] = []
        for try await event in E2EEV2LiveShareEventClient(api: APIClient()).eventsRuntime(
            ownerScopeId: "invalid",
            sessionId: "invalid"
        ) {
            received.append(event)
        }
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(E2EEV2RuntimeReadGate.enabled)
    }

    /// Le flux réel passe par le lecteur d'octets : les lignes vides ferment les
    /// événements, `id:` est gardé, un battement `:` et un événement inconnu sont ignorés.
    func testRuntimeStreamFramesDispatchLiveShareEvents() throws {
        let stream = """
        : keepalive

        event: encrypted_update
        id: update_0123456789abcdef
        data: {"updateId":"update_0123456789abcdef","createdAt":"2026-08-26T12:00:00.000Z","expiresAt":"2026-08-26T12:15:00.000Z"}
        
        event: ping
        data: {}

        event:  Status
        id: status-1
        data: {"status":"stopped"}


        """
        var parser = SSEFrameParser(limit: E2EEV2LiveShareEventContract.maxFrameBytes)
        let events = try stream.utf8.compactMap { try parser.append($0) }
            .compactMap(E2EEV2LiveShareEventContract.parse(frame:))
        XCTAssertEqual(events, [
            .encryptedUpdate(
                updateId: "update_0123456789abcdef",
                createdAt: "2026-08-26T12:00:00.000Z",
                expiresAt: "2026-08-26T12:15:00.000Z",
                eventId: "update_0123456789abcdef"
            ),
            .status(value: "stopped", eventId: "status-1")
        ])

        var bounded = SSEFrameParser(limit: E2EEV2LiveShareEventContract.maxFrameBytes)
        let oversized = "data: " + String(repeating: "x", count: 35 * 1_024)
        XCTAssertThrowsError(try oversized.utf8.forEach { _ = try bounded.append($0) })
    }

    /// Un refus v2 arrive en échec de transport : il arrête la publication comme
    /// un refus v1, et une panne passagère ne l'arrête pas.
    @MainActor
    func testV2PublishRefusalsAreTerminal() {
        func v2(_ status: Int?, _ kind: E2EEV2TransportFailureKind) -> Error {
            E2EEV2LiveShareRuntimeError.transport(E2EEV2TransportFailure(kind: kind, statusCode: status, message: ""))
        }
        for status in [400, 403, 404, 409, 410, 426] {
            XCTAssertTrue(ConversationLiveShareCoordinator.isTerminalPublishFailure(v2(status, .permanent)), "\(status)")
            XCTAssertTrue(ConversationLiveShareCoordinator.isTerminalPublishFailure(
                APIError.http(status: status, code: nil, message: "", requestId: nil, retryAfter: nil)
            ))
        }
        // Une époque à relire ou à tourner n'arrête rien : le code prime sur le statut.
        for code in ["E2EE_EPOCH_STALE", "E2EE_AUTO_REQUIRED"] {
            XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(
                E2EEV2LiveShareRuntimeError.transport(.init(kind: .permanent, statusCode: 409, code: code, message: ""))
            ), code)
        }
        XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(v2(503, .retryable)))
        XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(v2(nil, .retryable)))
        XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(v2(401, .authentication)))
        XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(E2EEV2LiveShareRuntimeError.invalidPayload))
        XCTAssertFalse(ConversationLiveShareCoordinator.isTerminalPublishFailure(URLError(.timedOut)))
    }

    /// Le flux d'un partage v2 ne s'arrête que sur une fin annoncée ; un 429 ou une
    /// panne se rattrapent en se reconnectant (E2EE-AUTO §7.6).
    func testV2LiveShareStreamEndsOnlyOnTerminalCodes() {
        func http(_ status: Int, _ code: String?) -> Error {
            APIError.http(status: status, code: code, message: "", requestId: nil, retryAfter: nil)
        }
        for code in ["LIVE_SHARE_INACTIVE", "LIVE_SHARE_ENDED", "LIVE_SHARE_NOT_FOUND", "FORBIDDEN"] {
            XCTAssertTrue(MessagesService.endsLiveShareStream(http(409, code)), code)
        }
        for status in [403, 404, 410] {
            XCTAssertTrue(MessagesService.endsLiveShareStream(http(status, nil)), "\(status)")
        }
        XCTAssertFalse(MessagesService.endsLiveShareStream(http(429, "RATE_LIMITED")))
        XCTAssertFalse(MessagesService.endsLiveShareStream(http(404, "E2EE_EPOCH_ENVELOPE_NOT_FOUND")))
        XCTAssertFalse(MessagesService.endsLiveShareStream(http(503, nil)))
        XCTAssertFalse(MessagesService.endsLiveShareStream(URLError(.networkConnectionLost)))
    }

    func testOpaquePushPreviewIsDerivedOnlyAfterDecryptionAndHonorsPrivacy() throws {
        let message = E2EEV2DecryptedMessage(
            epochNumber: 7,
            clientRequestId: clientRequestId,
            ttlSeconds: 0,
            encryptedBlobIds: [],
            content: [
                "schema": E2EEV2ContentContract.schema,
                "version": E2EEV2ContentContract.version,
                "kind": "TEXT",
                "replyToId": NSNull(),
                "mentions": [],
                "body": ["text": "  Message   privé  "],
            ]
        )
        XCTAssertEqual(
            E2EEV2NotificationPresentationPolicy.present(message, privacy: .full).body,
            "Message privé"
        )
        XCTAssertFalse(
            E2EEV2NotificationPresentationPolicy.present(message, privacy: .senderOnly)
                .body.contains("Message privé")
        )
        XCTAssertEqual(
            E2EEV2NotificationPresentationPolicy.present(message, privacy: .hidden).body,
            String(localized: "Nouveau contenu privé")
        )

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(contentsOf: repository.appendingPathComponent(
            "SignalQuestApp/Core/Push/AppDelegate.swift"
        ))
        let push = try String(contentsOf: repository.appendingPathComponent(
            "SignalQuestApp/Core/Push/PushNotificationService.swift"
        ))
        // Le choix d'aperçu vit dans l'écran Notifications depuis le Lot 4g.
        let settings = try String(contentsOf: repository.appendingPathComponent(
            "SignalQuestApp/Features/Profile/NotificationSettingsView.swift"
        ))
        XCTAssertTrue(appDelegate.contains("handleE2eeV2Envelope"))
        // Le même processeur que l'extension, sur la route GET servie (E.3).
        XCTAssertTrue(push.contains("E2EEV2NotificationProcessor.processRuntime"))
        XCTAssertFalse(push.contains("E2EEV2MessageDeliveryClient"))
        XCTAssertTrue(push.contains("recipientOwnerScope"))
        XCTAssertFalse(push.contains("MessageReplyReceiver"))
        XCTAssertFalse(push.contains("content.categoryIdentifier = \"MESSAGE\""))
        XCTAssertTrue(settings.contains("E2EEV2NotificationPrivacyStore.set"))
        XCTAssertTrue(settings.contains("E2EEV2NotificationPrivacy.full"))
        XCTAssertTrue(settings.contains("E2EEV2NotificationPrivacy.senderOnly"))
        XCTAssertTrue(settings.contains("E2EEV2NotificationPrivacy.hidden"))
    }

    func testNotificationPublicationRejectsOldSessionAndCancelsAccountRaces() async {
        let scope = E2EEV2NotificationScope(ownerScopeId: "account-a", sessionId: "session-a")
        XCTAssertTrue(scope.matches(ownerScopeId: "account-a", sessionId: "session-a"))
        XCTAssertFalse(scope.matches(ownerScopeId: "account-b", sessionId: "session-a"))
        XCTAssertFalse(scope.matches(ownerScopeId: "account-a", sessionId: "session-after-login"))
        XCTAssertFalse(scope.matches(ownerScopeId: nil, sessionId: nil))

        var activeSession = "session-a"
        var cancelled = false
        let result = await E2EEV2NotificationScope.publishIfCurrent(
            isCurrent: { scope.matches(ownerScopeId: "account-a", sessionId: activeSession) },
            publish: {
                activeSession = "session-after-login"
                return true
            },
            cancel: { cancelled = true }
        )
        XCTAssertFalse(result)
        XCTAssertTrue(cancelled)
    }

    func testNotificationPrivacyIsSeparatedBetweenAccounts() {
        let ownerA = "fixture-a-\(UUID().uuidString)"
        let ownerB = "fixture-b-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "e2ee-v2-notification-privacy.\(ownerA)")
            UserDefaults.standard.removeObject(forKey: "e2ee-v2-notification-privacy.\(ownerB)")
        }
        XCTAssertEqual(E2EEV2NotificationPrivacyStore.get(ownerScopeId: ownerA), .full)
        E2EEV2NotificationPrivacyStore.set(.hidden, ownerScopeId: ownerA)
        XCTAssertEqual(E2EEV2NotificationPrivacyStore.get(ownerScopeId: ownerB), .full)
        E2EEV2NotificationPrivacyStore.set(.senderOnly, ownerScopeId: ownerB)
        XCTAssertEqual(E2EEV2NotificationPrivacyStore.get(ownerScopeId: ownerA), .hidden)
        XCTAssertEqual(E2EEV2NotificationPrivacyStore.get(ownerScopeId: ownerB), .senderOnly)
        XCTAssertEqual(E2EEV2NotificationPrivacyStore.get(ownerScopeId: nil), .hidden)
    }

    func testNotificationPreviewAndSettingsHaveCompiledEnglishTranslations() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(
            english.localizedString(forKey: "Nouveau contenu privé", value: nil, table: nil),
            "New private content"
        )
        XCTAssertEqual(
            english.localizedString(forKey: "Ouvre SignalQuest pour afficher le message.", value: nil, table: nil),
            "Open SignalQuest to view the message."
        )
        XCTAssertEqual(
            english.localizedString(forKey: "Aperçu des messages chiffrés", value: nil, table: nil),
            "Encrypted message previews"
        )
    }

    func testPublishAcknowledgementIsExactScopedAndIdempotent() throws {
        let valid = try publishResponse(idempotentReplay: true)
        XCTAssertEqual(
            E2EEV2LiveShareTransportClient.parsePublishResponseContractPreview(
                valid,
                expectedSessionId: sessionId,
                expectedClientRequestId: clientRequestId,
                transportIdempotentReplay: true
            )?.updateId,
            "update_0123456789abcdef"
        )
        XCTAssertNil(E2EEV2LiveShareTransportClient.parsePublishResponseContractPreview(
            valid,
            expectedSessionId: sessionId,
            expectedClientRequestId: clientRequestId,
            transportIdempotentReplay: false
        ))

        var leaked = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        leaked["latitude"] = 48.0
        XCTAssertNil(E2EEV2LiveShareTransportClient.parsePublishResponseContractPreview(
            try JSONSerialization.data(withJSONObject: leaked),
            expectedSessionId: sessionId,
            expectedClientRequestId: clientRequestId,
            transportIdempotentReplay: true
        ))
    }

    func testDecryptedUpdateMustMatchSessionAndRemainUnexpired() throws {
        let message = E2EEV2DecryptedMessage(
            epochNumber: 7,
            clientRequestId: clientRequestId,
            ttlSeconds: 900,
            encryptedBlobIds: [],
            content: liveLocationContent()
        )
        let publicExpiry = try XCTUnwrap(E2EEV2PortableInventoryContract.parseInstant(
            "2026-08-26T12:15:00.000Z"
        ))
        let now = try XCTUnwrap(E2EEV2PortableInventoryContract.parseInstant(
            "2026-08-26T12:01:00.000Z"
        ))
        XCTAssertEqual(E2EEV2LiveShareTransportClient.validateDecryptedUpdateContractPreview(
            updateId: "update_0123456789abcdef",
            expectedSessionId: sessionId,
            message: message,
            publicExpiresAt: publicExpiry,
            now: now
        )?.sequence, 4)
        XCTAssertNil(E2EEV2LiveShareTransportClient.validateDecryptedUpdateContractPreview(
            updateId: "update_0123456789abcdef",
            expectedSessionId: "live_other_0123456789abcdef",
            message: message,
            publicExpiresAt: publicExpiry,
            now: now
        ))
        XCTAssertNil(E2EEV2LiveShareTransportClient.validateDecryptedUpdateContractPreview(
            updateId: "update_0123456789abcdef",
            expectedSessionId: sessionId,
            message: message,
            publicExpiresAt: publicExpiry,
            now: publicExpiry.addingTimeInterval(1)
        ))
    }

    func testDormantTransportHasNoCleartextPersistencePath() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SignalQuestApp/Services/E2EEService.swift"))
        let start = try XCTUnwrap(source.range(
            of: "// MARK: - E2EE v2 Live Share transport (dormant)"
        ))
        let end = try XCTUnwrap(source.range(
            of: "struct E2EEV2PortableExportSummary",
            range: start.upperBound..<source.endIndex
        ))
        let section = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(section.contains("allowServerBoundedExpiry: true"))
        XCTAssertTrue(section.contains("E2EEV2MessageReceiver.decryptContractPreview"))
        XCTAssertFalse(section.contains("epochStore.put("))
        XCTAssertFalse(section.contains("UserDefaults"))
        XCTAssertFalse(section.contains("FileManager"))
        XCTAssertTrue(section.contains("session[\"lastLocation\"] is NSNull"))
        XCTAssertTrue(section.contains("session[\"lastPayload\"] is NSNull"))
        XCTAssertTrue(section.contains("E2EEV2LiveShareStateStore"))
        XCTAssertTrue(section.contains("publishPreparedRuntime"))

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let services = try String(contentsOf: repository.appendingPathComponent(
            "SignalQuestApp/Services/MessagesService.swift"
        ))
        let coordinator = try String(contentsOf: repository.appendingPathComponent(
            "SignalQuestApp/Services/AppServices.swift"
        ))
        XCTAssertTrue(services.contains("e2eeV2LiveShareRuntime.publish"))
        XCTAssertTrue(services.contains("e2eeV2LiveShareRuntime.fetchLatest"))
        XCTAssertTrue(coordinator.contains("service.updateE2eeLiveShare"))
        XCTAssertTrue(coordinator.contains("service.e2eeLiveShareEvents"))
        XCTAssertTrue(services.contains("e2eeV2LiveShareEventsClient.eventsRuntime"))
    }

    private func preparationInput() -> E2EEV2MessagePreparationInput {
        .init(
            conversationId: "conversation_0123456789abcdef",
            clientRequestId: clientRequestId,
            ttlSeconds: 900,
            encryptedBlobIds: [],
            content: liveLocationContent()
        )
    }

    private func liveLocationContent() -> [String: Any] {
        [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": "LIVE_LOCATION",
            "replyToId": NSNull(),
            "mentions": [],
            "body": [
                "sessionId": sessionId,
                "sequence": 4,
                "latitude": 40.7128,
                "longitude": -74.006,
                "accuracyMeters": 8.5,
                "observedAt": "2026-08-26T12:00:00.000Z",
                "expiresAt": "2026-08-26T12:15:00.000Z",
            ],
        ]
    }

    private func publishResponse(idempotentReplay: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "update": [
                "updateId": "update_0123456789abcdef",
                "sessionId": sessionId,
                "clientRequestId": clientRequestId,
                "createdAt": "2026-08-26T12:00:00.000Z",
                "expiresAt": "2026-08-26T12:15:00.000Z",
            ],
            "idempotentReplay": idempotentReplay,
        ], options: [.sortedKeys])
    }
}

final class E2EEV2PortableExportTests: XCTestCase {
    private let ownerScopeId = "user:user_01J7PORTABLE00000001"
    private let otherOwnerScopeId = "user:user_01J7PORTABLE00000002"
    private let recipientDeviceId = "ios_01J7PORTABLE000000001"
    private let conversationId = "conv_01J7PORTABLE00000001"
    private let senderId = "user_01J7PORTABLE00000003"
    private let senderDeviceId = "ios_01J7PORTABLE000000004"

    func testStrictInventoryRejectsUnknownFieldsAndNonCanonicalOrder() throws {
        let first = item(0)
        let second = item(1)
        let valid = try inventoryData(items: [first, second], hasMore: false)
        XCTAssertNotNil(E2EEV2PortableInventoryContract.parse(
            valid,
            expectedRecipientDeviceId: recipientDeviceId
        ))

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        root["debug"] = true
        XCTAssertNil(E2EEV2PortableInventoryContract.parse(
            try JSONSerialization.data(withJSONObject: root),
            expectedRecipientDeviceId: recipientDeviceId
        ))

        root.removeValue(forKey: "debug")
        root["envelopes"] = [jsonItem(second), jsonItem(first)]
        XCTAssertNil(E2EEV2PortableInventoryContract.parse(
            try JSONSerialization.data(withJSONObject: root),
            expectedRecipientDeviceId: recipientDeviceId
        ))
    }

    func testIdentityResetSharedMessageDeliveryKeepsSignedContentAndRejectsUnknownAlias() throws {
        let fixture = try signedDeliveryFixture()
        var response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.response) as? [String: Any]
        )
        var envelope = try XCTUnwrap(response["envelope"] as? [String: Any])
        var epoch = try XCTUnwrap(envelope["epoch"] as? [String: Any])
        epoch["reason"] = "IDENTITY_RESET"
        envelope["epoch"] = epoch
        response["envelope"] = envelope
        let delivery = try XCTUnwrap(E2EEV2MessageDeliveryContract.parseAndVerify(
            JSONSerialization.data(withJSONObject: response),
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
        XCTAssertEqual(delivery.epochDelivery?.reason, "IDENTITY_RESET")
        let message = try E2EEV2MessageReceiver.decryptContractPreview(
            input: delivery.incoming, epoch: fixture.epoch
        )
        XCTAssertEqual(
            (message.content["body"] as? [String: Any])?["text"] as? String,
            "Export portable vérifié"
        )
        epoch["reason"] = "RESET"
        envelope["epoch"] = epoch
        response["envelope"] = envelope
        XCTAssertNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            try JSONSerialization.data(withJSONObject: response),
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
    }

    /// Une époque déjà accusée arrive sans enveloppe (`recipientEnvelope: null`) : la
    /// livraison reste lisible avec la clé gardée, et seule la clé manque au parseur.
    func testAcknowledgedEpochDeliveryKeepsEpochWithoutEnvelope() throws {
        let fixture = try signedDeliveryFixture()
        var response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.response) as? [String: Any]
        )
        var envelope = try XCTUnwrap(response["envelope"] as? [String: Any])
        var epoch = try XCTUnwrap(envelope["epoch"] as? [String: Any])
        epoch["recipientEnvelope"] = NSNull()
        envelope["epoch"] = epoch
        response["envelope"] = envelope
        let delivery = try XCTUnwrap(E2EEV2MessageDeliveryContract.parseAndVerify(
            JSONSerialization.data(withJSONObject: response),
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
        XCTAssertNil(delivery.epochDelivery)
        XCTAssertEqual(delivery.epoch.epochNumber, fixture.epoch.epochNumber)
        XCTAssertEqual(delivery.epoch.keyCommitmentB64, fixture.epoch.keyCommitmentB64)
        let message = try E2EEV2MessageReceiver.decryptContractPreview(
            input: delivery.incoming, epoch: fixture.epoch
        )
        XCTAssertEqual(message.content["kind"] as? String, "TEXT")

        epoch.removeValue(forKey: "recipientEnvelope")
        envelope["epoch"] = epoch
        response["envelope"] = envelope
        XCTAssertNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            try JSONSerialization.data(withJSONObject: response),
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
    }

    func testSignedMessageDeliveryParserVerifiesEpochAndMessage() throws {
        let fixture = try signedDeliveryFixture()
        let delivery = try XCTUnwrap(E2EEV2MessageDeliveryContract.parseAndVerify(
            fixture.response,
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
        let message = try E2EEV2MessageReceiver.decryptContractPreview(
            input: delivery.incoming,
            epoch: fixture.epoch
        )
        XCTAssertEqual(message.content["kind"] as? String, "TEXT")
        XCTAssertEqual(
            (message.content["body"] as? [String: Any])?["text"] as? String,
            "Export portable vérifié"
        )
    }

    func testLiveShareMayShortenSignedRetentionWithoutExtendingSignedTTL() throws {
        let fixture = try signedDeliveryFixture(
            ttlSeconds: 900,
            expiresAt: "2026-08-24T12:01:00.000Z"
        )
        XCTAssertNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            fixture.response,
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId
        ))
        XCTAssertNotNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            fixture.response,
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId,
            allowServerBoundedExpiry: true
        ))

        var response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.response) as? [String: Any]
        )
        var envelope = try XCTUnwrap(response["envelope"] as? [String: Any])
        envelope["expiresAt"] = "2026-08-24T12:15:01.000Z"
        response["envelope"] = envelope
        XCTAssertNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            try JSONSerialization.data(withJSONObject: response),
            ownerScopeId: ownerScopeId,
            expectedEnvelopeId: fixture.envelopeId,
            expectedConversationId: conversationId,
            expectedRecipientDeviceId: recipientDeviceId,
            allowServerBoundedExpiry: true
        ))
    }

    func testThreePageExportDecryptsMediaAndCommitsAtomicZIP64Archive() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("SignalQuest-E2EE.zip")
        try Data("ANCIEN EXPORT".utf8).write(to: target)

        let media = try mediaFixture(index: 0)
        var messages: [String: E2EEV2DeliveredMessage] = [:]
        let items = (0..<205).map(item)
        for (index, inventoryItem) in items.enumerated() {
            messages[inventoryItem.envelopeId] = index == 0
                ? media.message
                : deliveredMessage(item: inventoryItem, content: textContent("Message \(index)"))
        }
        let pages = try paginatedInventory(items)
        let result = await E2EEV2PortableExportCoordinator.exportContractPreview(
            ownerScopeId: ownerScopeId,
            generatedAt: try XCTUnwrap(E2EEV2PortableInventoryContract.parseInstant("2026-08-24T12:00:00.000Z")),
            dependencies: .init(
                currentOwnerScope: { self.ownerScopeId },
                isApprovedDevice: { true },
                recipientDeviceId: recipientDeviceId,
                makeDestination: {
                    try E2EEV2PortableAtomicFileDestination(targetURL: target).destination()
                },
                fetchInventory: { cursor in
                    guard let page = pages[cursor ?? "FIRST"] else {
                        throw TestFailure.invalidFixture
                    }
                    return page
                },
                fetchMessage: { inventoryItem in
                    guard let message = messages[inventoryItem.envelopeId] else {
                        throw TestFailure.invalidFixture
                    }
                    return message
                },
                downloadRange: { _, offset, length in
                    let start = Int(offset)
                    guard start >= 0, start + length <= media.ciphertext.count else {
                        throw TestFailure.invalidFixture
                    }
                    return media.ciphertext.subdata(in: start..<(start + length))
                }
            )
        )
        XCTAssertEqual(result, .success(.init(
            messageCount: 205,
            mediaCount: 1,
            plaintextMediaBytes: Int64(media.plaintext.count)
        )))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(partials(in: root, target: target).isEmpty)

        let archive = try storedZIPEntries(Data(contentsOf: target))
        XCTAssertEqual(archive["media/\(media.blobId)/capture.bin"], media.plaintext)
        XCTAssertNotNil(archive["messages/\(conversationId)/\(items[204].envelopeId).json"])
        XCTAssertEqual(
            archive.keys.filter { $0.hasPrefix("messages/") }.count,
            205
        )
        let manifest = try XCTUnwrap(archive["manifest.json"])
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        )
        XCTAssertEqual((manifestObject["messageCount"] as? NSNumber)?.intValue, 205)
        XCTAssertEqual(manifestObject["containsPrivateKeys"] as? Bool, false)
        let firstMessage = try XCTUnwrap(
            archive["messages/\(conversationId)/\(items[0].envelopeId).json"]
        )
        let firstObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstMessage) as? [String: Any]
        )
        let firstContent = try XCTUnwrap(firstObject["content"] as? [String: Any])
        let firstBody = try XCTUnwrap(firstContent["body"] as? [String: Any])
        let firstAttachments = try XCTUnwrap(firstBody["attachments"] as? [[String: Any]])
        XCTAssertNil(firstAttachments[0]["mediaKeyB64"])
        XCTAssertNil(firstAttachments[0]["noncePrefixB64"])
        XCTAssertNil(firstAttachments[0]["ciphertextSha256"])
        XCTAssertEqual(firstAttachments[0]["archivePath"] as? String, "media/\(media.blobId)/capture.bin")
    }

    func testLaterPageFailurePreservesExistingDestinationAndDeletesPartial() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("existing.zip")
        let original = Data("EXPORT PRÉCÉDENT".utf8)
        try original.write(to: target)
        let items = (0..<101).map(item)
        let firstPage = try inventoryData(items: Array(items.prefix(100)), hasMore: true)
        let messages = Dictionary(uniqueKeysWithValues: items.map {
            ($0.envelopeId, deliveredMessage(item: $0, content: textContent("Texte")))
        })

        let result = await E2EEV2PortableExportCoordinator.exportContractPreview(
            ownerScopeId: ownerScopeId,
            generatedAt: Date(timeIntervalSince1970: 1_724_500_000),
            dependencies: .init(
                currentOwnerScope: { self.ownerScopeId },
                isApprovedDevice: { true },
                recipientDeviceId: recipientDeviceId,
                makeDestination: {
                    try E2EEV2PortableAtomicFileDestination(targetURL: target).destination()
                },
                fetchInventory: { cursor in
                    if cursor == nil { return firstPage }
                    throw TestFailure.interrupted
                },
                fetchMessage: { try XCTUnwrap(messages[$0.envelopeId]) },
                downloadRange: { _, _, _ in throw TestFailure.invalidFixture }
            )
        )
        guard case .failure = result else { return XCTFail("L'export interrompu doit échouer") }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(partials(in: root, target: target).isEmpty)
    }

    func testAccountSwitchBeforeMediaRangeAbortsWithoutNetworkOrOverwrite() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("account-switch.zip")
        let original = Data("COMPTE A".utf8)
        try original.write(to: target)
        let media = try mediaFixture(index: 0)
        let inventory = try inventoryData(items: [item(0)], hasMore: false)
        let activeOwner = LockedBox(ownerScopeId)
        let rangeCalls = LockedBox(0)

        let result = await E2EEV2PortableExportCoordinator.exportContractPreview(
            ownerScopeId: ownerScopeId,
            generatedAt: Date(timeIntervalSince1970: 1_724_500_000),
            dependencies: .init(
                currentOwnerScope: { activeOwner.value },
                isApprovedDevice: { true },
                recipientDeviceId: recipientDeviceId,
                makeDestination: {
                    try E2EEV2PortableAtomicFileDestination(targetURL: target).destination()
                },
                fetchInventory: { _ in inventory },
                fetchMessage: { _ in
                    activeOwner.value = self.otherOwnerScopeId
                    return media.message
                },
                downloadRange: { _, _, _ in
                    rangeCalls.value += 1
                    return media.ciphertext
                }
            )
        )
        XCTAssertEqual(result, .blocked(reason: "e2ee-v2-account-scope-mismatch"))
        XCTAssertEqual(rangeCalls.value, 0)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(partials(in: root, target: target).isEmpty)
    }

    private func signedDeliveryFixture(
        ttlSeconds: Int = 0,
        expiresAt: String? = nil
    ) throws -> (
        response: Data,
        envelopeId: String,
        epoch: E2EEV2StoredEpochKey
    ) {
        let epochSenderId = "ios_01J7EPOCHSENDER000001"
        let envelopeId = "env_01J7PORTABLESIGNED001"
        let epochId = "epoch_01J7PORTABLESIGNED01"
        let createdAt = "2026-08-24T12:00:00.000Z"
        let epochNumber = 4
        let epochKey = Data((0..<32).map { UInt8($0 + 1) })
        let recipientKey = P256.KeyAgreement.PrivateKey()
        let epochSigningKey = P256.Signing.PrivateKey()
        let epochContext = E2EEV2EpochContext(
            conversationId: conversationId,
            epochNumber: epochNumber,
            senderDeviceId: epochSenderId,
            recipientDeviceId: recipientDeviceId
        )
        let wrapped = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: recipientKey.publicKey,
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(),
            nonce: Data(repeating: 7, count: 12),
            context: epochContext
        )
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let epochSignature = try E2EEV2LowS.sign(E2EEV2EpochCrypto.signatureCanonical(
            context: epochContext,
            keyCommitmentB64: commitment,
            envelope: wrapped
        ), with: epochSigningKey).base64EncodedString()

        let messageSigningKey = P256.Signing.PrivateKey()
        let content = textContent("Export portable vérifié")
        let cleartext = try E2EEV2ContentContract.encode(content)
        let messageContext = E2EEV2MessageContext(
            conversationId: conversationId,
            epochNumber: epochNumber,
            senderDeviceId: senderDeviceId,
            clientRequestId: "req_01J7PORTABLESIGNED001",
            ttlSeconds: ttlSeconds,
            encryptedBlobIds: []
        )
        let unsigned = try E2EEV2MessageCrypto.encrypt(
            cleartext: cleartext,
            epochKey: epochKey,
            nonce: Data(repeating: 9, count: 12),
            context: messageContext
        )
        let messageSignature = try E2EEV2LowS.sign(
            E2EEV2MessageCrypto.signatureCanonical(context: messageContext, envelope: unsigned),
            with: messageSigningKey
        ).base64EncodedString()
        let response: [String: Any] = [
            "envelope": [
                "id": envelopeId,
                "conversationId": conversationId,
                "senderId": senderId,
                "senderDevice": [
                    "deviceId": senderDeviceId,
                    "publicSigningKeyB64": messageSigningKey.publicKey.x963Representation.base64EncodedString(),
                    "signingKeyAlgorithm": E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
                    "keyVersion": 1,
                ],
                "epoch": [
                    "id": epochId,
                    "epochNumber": epochNumber,
                    "algorithm": "AES_256_GCM_HKDF_SHA256",
                    "keyCommitmentB64": commitment,
                    "reason": "INITIAL",
                    "status": "active",
                    "createdAt": createdAt,
                    "recipientEnvelope": [
                        "recipientDeviceId": recipientDeviceId,
                        "senderDeviceId": epochSenderId,
                        "wrapAlgorithm": wrapped.wrapAlgorithm,
                        "ephemeralPublicKeyB64": wrapped.ephemeralPublicKeyB64,
                        "wrappedEpochKeyB64": wrapped.wrappedEpochKeyB64,
                        "nonceB64": wrapped.nonceB64,
                        "aadB64": wrapped.aadB64,
                        "signatureB64": epochSignature,
                        "senderPublicSigningKeyB64": epochSigningKey.publicKey.x963Representation.base64EncodedString(),
                        "senderSigningKeyAlgorithm": E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
                        "senderKeyVersion": 1,
                    ],
                ],
                "envelopeVersion": unsigned.envelopeVersion,
                "clientRequestId": unsigned.clientRequestId,
                "algorithm": unsigned.algorithm,
                "contentType": unsigned.contentType,
                "ttlSeconds": unsigned.ttlSeconds,
                "encryptedBlobIds": unsigned.encryptedBlobIds,
                "nonceB64": unsigned.nonceB64,
                "aadB64": unsigned.aadB64,
                "ciphertextB64": unsigned.ciphertextB64,
                "senderSignatureB64": messageSignature,
                "encryptedBlobs": [],
                "createdAt": createdAt,
                "expiresAt": expiresAt.map { $0 as Any } ?? NSNull(),
            ],
        ]
        return (
            try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
            envelopeId,
            .init(
                conversationId: conversationId,
                epochId: epochId,
                epochNumber: epochNumber,
                keyCommitmentB64: commitment,
                epochKey: epochKey
            )
        )
    }

    private func mediaFixture(index: Int) throws -> (
        message: E2EEV2DeliveredMessage,
        blobId: String,
        plaintext: Data,
        ciphertext: Data
    ) {
        let inventoryItem = item(index)
        let blobId = "blob_01J7PORTABLE00000001"
        let mediaKey = Data((0..<32).map { UInt8($0) })
        let noncePrefix = Data((40..<48).map(UInt8.init))
        let plaintext = Data((0..<(E2EEV2BlobCrypto.cryptoChunkBytes + 12_345)).map {
            UInt8($0 % 251)
        })
        var ciphertext = Data()
        let chunkCount = 2
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * E2EEV2BlobCrypto.cryptoChunkBytes
            let end = min(plaintext.count, start + E2EEV2BlobCrypto.cryptoChunkBytes)
            ciphertext.append(try E2EEV2BlobCrypto.encryptChunk(
                plaintext.subdata(in: start..<end),
                blobID: blobId,
                mediaKey: mediaKey,
                noncePrefix: noncePrefix,
                chunkIndex: UInt32(chunkIndex),
                finalChunk: chunkIndex == chunkCount - 1
            ))
        }
        let plaintextHash = Data(SHA256.hash(data: plaintext)).testHex
        let ciphertextHash = Data(SHA256.hash(data: ciphertext)).testHex
        let manifest: [String: Any] = [
            "blobId": blobId,
            "algorithm": E2EEV2BlobCrypto.algorithm,
            "mediaKeyB64": mediaKey.base64EncodedString(),
            "noncePrefixB64": noncePrefix.base64EncodedString(),
            "cryptoChunkSize": E2EEV2BlobCrypto.cryptoChunkBytes,
            "plaintextSize": String(plaintext.count),
            "ciphertextSize": String(ciphertext.count),
            "plaintextSha256": plaintextHash,
            "ciphertextSha256": ciphertextHash,
            "fileName": "capture.bin",
            "mimeType": "application/octet-stream",
            "width": NSNull(),
            "height": NSNull(),
            "durationMs": NSNull(),
        ]
        let content: [String: Any] = [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": "MEDIA",
            "replyToId": NSNull(),
            "mentions": [],
            "body": ["caption": NSNull(), "attachments": [manifest]],
        ]
        let descriptor = E2EEV2DeliveredBlob(
            blobId: blobId,
            algorithm: E2EEV2BlobCrypto.algorithm,
            ciphertextSha256: ciphertextHash,
            ciphertextSize: Int64(ciphertext.count),
            chunkSize: 5 * 1_024 * 1_024
        )
        return (
            deliveredMessage(
                item: inventoryItem,
                content: content,
                encryptedBlobIds: [blobId],
                blobs: [descriptor]
            ),
            blobId,
            plaintext,
            ciphertext
        )
    }

    private func deliveredMessage(
        item: E2EEV2PortableInventoryItem,
        content: [String: Any],
        encryptedBlobIds: [String] = [],
        blobs: [E2EEV2DeliveredBlob] = []
    ) -> E2EEV2DeliveredMessage {
        let epochNumber = 1
        let delivery = E2EEV2VerifiedMessageDelivery(
            id: item.envelopeId,
            senderId: senderId,
            incoming: .init(
                ownerScopeId: ownerScopeId,
                conversationId: conversationId,
                senderDeviceId: senderDeviceId,
                senderPublicSigningKeyB64: Data(repeating: 3, count: 65).base64EncodedString(),
                envelopeData: Data()
            ),
            epochDelivery: .init(
                conversationId: conversationId,
                epochId: "epoch_01J7PORTABLE0000001",
                epochNumber: epochNumber,
                keyCommitmentB64: Data(repeating: 4, count: 32).base64EncodedString(),
                reason: "INITIAL",
                status: "active",
                createdAt: "2026-08-24T11:00:00.000Z",
                senderDeviceId: senderDeviceId,
                senderPublicSigningKeyB64: Data(repeating: 3, count: 65).base64EncodedString(),
                envelope: .init(
                    recipientDeviceId: recipientDeviceId,
                    wrapAlgorithm: E2EEV2EpochCrypto.wrapAlgorithm,
                    ephemeralPublicKeyB64: Data(repeating: 5, count: 65).base64EncodedString(),
                    wrappedEpochKeyB64: Data(repeating: 6, count: 48).base64EncodedString(),
                    nonceB64: Data(repeating: 7, count: 12).base64EncodedString(),
                    aadB64: Data("aad".utf8).base64EncodedString(),
                    signatureB64: Data("sig".utf8).base64EncodedString()
                )
            ),
            encryptedBlobs: blobs,
            createdAt: item.createdAt,
            expiresAt: item.expiresAt
        )
        return .init(
            delivery: delivery,
            message: .init(
                epochNumber: epochNumber,
                clientRequestId: "req_\(item.envelopeId)",
                ttlSeconds: 0,
                encryptedBlobIds: encryptedBlobIds,
                content: content
            )
        )
    }

    private func textContent(_ text: String) -> [String: Any] {
        [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": "TEXT",
            "replyToId": NSNull(),
            "mentions": [],
            "body": ["text": text],
        ]
    }

    private func item(_ index: Int) -> E2EEV2PortableInventoryItem {
        .init(
            envelopeId: String(format: "env_%020d", index),
            conversationId: conversationId,
            createdAt: instant(Date(timeIntervalSince1970: 1_724_500_000 + Double(index))),
            expiresAt: nil
        )
    }

    private func paginatedInventory(
        _ items: [E2EEV2PortableInventoryItem]
    ) throws -> [String: Data] {
        let first = Array(items[0..<100])
        let second = Array(items[100..<200])
        let third = Array(items[200..<items.count])
        return [
            "FIRST": try inventoryData(items: first, hasMore: true),
            first.last!.envelopeId: try inventoryData(items: second, hasMore: true),
            second.last!.envelopeId: try inventoryData(items: third, hasMore: false),
        ]
    }

    private func inventoryData(
        items: [E2EEV2PortableInventoryItem],
        hasMore: Bool
    ) throws -> Data {
        let root: [String: Any] = [
            "version": 1,
            "recipientDeviceId": recipientDeviceId,
            "envelopes": items.map(jsonItem),
            "hasMore": hasMore,
            "nextCursor": hasMore ? items.last!.envelopeId : NSNull(),
            "serverTime": "2026-08-24T12:30:00.000Z",
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func jsonItem(_ item: E2EEV2PortableInventoryItem) -> [String: Any] {
        [
            "envelopeId": item.envelopeId,
            "conversationId": item.conversationId,
            "createdAt": item.createdAt,
            "expiresAt": item.expiresAt ?? NSNull(),
        ]
    }

    private func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-ios-portable-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func partials(in root: URL, target: URL) -> [URL] {
        let prefix = ".\(target.lastPathComponent)."
        return (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "partial" } ?? []
    }

    private func storedZIPEntries(_ data: Data) throws -> [String: Data] {
        guard data.count >= 98 else { throw TestFailure.invalidArchive }
        let locatorOffset = data.count - 42
        guard data.testUInt32(at: locatorOffset) == 0x07064b50 else {
            throw TestFailure.invalidArchive
        }
        let zip64Offset = try data.testInt(data.testUInt64(at: locatorOffset + 8))
        guard data.testUInt32(at: zip64Offset) == 0x06064b50 else {
            throw TestFailure.invalidArchive
        }
        let entryCount = try data.testInt(data.testUInt64(at: zip64Offset + 32))
        var cursor = try data.testInt(data.testUInt64(at: zip64Offset + 48))
        var entries: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard data.testUInt32(at: cursor) == 0x02014b50 else {
                throw TestFailure.invalidArchive
            }
            let nameLength = Int(data.testUInt16(at: cursor + 28))
            let extraLength = Int(data.testUInt16(at: cursor + 30))
            let commentLength = Int(data.testUInt16(at: cursor + 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd + extraLength + commentLength <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8),
                  data.testUInt16(at: nameEnd) == 0x0001,
                  data.testUInt16(at: nameEnd + 2) == 24 else {
                throw TestFailure.invalidArchive
            }
            let size = try data.testInt(data.testUInt64(at: nameEnd + 4))
            let localOffset = try data.testInt(data.testUInt64(at: nameEnd + 20))
            guard data.testUInt32(at: localOffset) == 0x04034b50 else {
                throw TestFailure.invalidArchive
            }
            let localNameLength = Int(data.testUInt16(at: localOffset + 26))
            let localExtraLength = Int(data.testUInt16(at: localOffset + 28))
            let valueStart = localOffset + 30 + localNameLength + localExtraLength
            let valueEnd = valueStart + size
            guard valueEnd <= data.count, entries[name] == nil else {
                throw TestFailure.invalidArchive
            }
            entries[name] = data.subdata(in: valueStart..<valueEnd)
            cursor = nameEnd + extraLength + commentLength
        }
        return entries
    }

    private enum TestFailure: Error {
        case invalidFixture
        case interrupted
        case invalidArchive
    }

}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension E2EETests {
    private func rotationBacklog(
        store: TokenStore, session: LockedBox<LocalAccountSession>, clock: LockedBox<Int64>
    ) -> E2EEV2RotationBacklog {
        .init(store: store, now: { clock.value }, current: { $0 == session.value }, publish: { expected, write in
            guard expected == session.value else { throw CancellationError() }
            try write()
        })
    }

    func testV2RotationRuntimeGateKeepsDurableHintsWithoutNetwork() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-gate-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000)), calls = LockedBox(0)
        let store = InMemoryTokenStore()
        let backlog = rotationBacklog(store: store, session: current, clock: clock)
        let id = "conversation_rotation_0001"
        try backlog.request(session, conversations: [id])
        let before = try backlog.snapshot(session)
        let drain = E2EEV2RotationDrain()
        let retry = try await drain.run(session: session, backlog: backlog, dependencies: .init(
            isCurrent: { session == current.value }, activationEnabled: { false },
            pending: { calls.value += 1; return .success([]) },
            rotate: { _, _ in calls.value += 1; return .noAction }, now: { clock.value }
        ))
        XCTAssertFalse(retry)
        XCTAssertEqual(calls.value, 0)
        let reopened = rotationBacklog(store: store, session: current, clock: clock)
        XCTAssertEqual(try reopened.snapshot(session).pending, before.pending)
        XCTAssertEqual(try reopened.snapshot(session).phase, .waitingAuthorization)
        XCTAssertEqual(try reopened.snapshot(session).attempts, 0)
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertFalse(E2EEV2RuntimeReadGate.enabled)
    }

    func testV2RotationRetryBudgetAndDeadlineSurviveReopening() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-retry-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000)), calls = LockedBox(0)
        let store = InMemoryTokenStore()
        var backlog = rotationBacklog(store: store, session: current, clock: clock)
        try backlog.request(session, conversations: ["conversation_rotation_0001"])
        let drain = E2EEV2RotationDrain()
        let deps = E2EEV2RotationDrainDependencies(
            isCurrent: { current.value == session }, activationEnabled: { true },
            pending: { calls.value += 1; return .failure(.init(kind: .retryable, message: "synthetic-offline")) },
            rotate: { _, _ in XCTFail("A failed discovery must not rotate"); return .noAction }, now: { clock.value }
        )
        for attempt in 1...5 {
            let startedAt = clock.value
            let retry = try await drain.run(session: session, backlog: backlog, dependencies: deps)
            XCTAssertEqual(retry, attempt < 5)
            let state = try backlog.snapshot(session)
            let delay: Int64 = attempt < 5 ? 30_000 * (1 << (attempt - 1)) : 3_600_000
            XCTAssertEqual(state.attempts, attempt)
            XCTAssertEqual(state.notBeforeMs, startedAt + delay)
            XCTAssertTrue(state.hasWork)
            backlog = rotationBacklog(store: store, session: current, clock: clock)
            clock.value = state.notBeforeMs - 1
            _ = try await drain.run(session: session, backlog: backlog, dependencies: deps)
            XCTAssertEqual(calls.value, attempt)
            XCTAssertEqual(try backlog.snapshot(session), state)
            clock.value = state.notBeforeMs
        }
        XCTAssertEqual(try backlog.snapshot(session).phase, .needsAttention)
        clock.value = try backlog.snapshot(session).notBeforeMs - 1
        try backlog.request(session, conversations: [], resetRetry: true)
        XCTAssertEqual(try backlog.snapshot(session).attempts, 0)
        XCTAssertEqual(try backlog.snapshot(session).notBeforeMs, 0)
    }

    func testV2RotationLateAckDoesNotClearNewerDeviceChange() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-ticket-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000))
        let backlog = rotationBacklog(store: InMemoryTokenStore(), session: current, clock: clock)
        let id = "conversation_rotation_0001"
        try backlog.request(session, conversations: [id])
        let original = try XCTUnwrap(backlog.snapshot(session).pending[id])
        let drain = E2EEV2RotationDrain()
        let retry = try await drain.run(session: session, backlog: backlog, dependencies: .init(
            isCurrent: { current.value == session }, activationEnabled: { true },
            pending: {
                try? backlog.request(session, conversations: [id])
                return .success([])
            }, rotate: { _, _ in
                try? backlog.request(session, conversations: [id])
                return .noAction
            }, now: { clock.value }
        ))
        let state = try backlog.snapshot(session)
        XCTAssertTrue(retry)
        XCTAssertGreaterThan(try XCTUnwrap(state.pending[id]), original)
        XCTAssertTrue(state.scanRequired)
        XCTAssertEqual(state.phase, .retryPending)
        try backlog.acknowledge(session, conversation: id, ticket: original)
        XCTAssertEqual(try backlog.snapshot(session), state)
    }

    /// E2EE-COMPROMISED-1 §6 : le serveur ne clôt une exigence que par une nouvelle
    /// époque. Celle qu'il liste est passée « requise » ; une demande locale ne l'est pas.
    func testV2RotationServedRequirementIsRequiredLocalRequestIsNot() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-required-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000)), seen = LockedBox([String: Bool]())
        let backlog = rotationBacklog(store: InMemoryTokenStore(), session: current, clock: clock)
        let served = "conversation_rotation_0001", local = "conversation_rotation_0002"
        try backlog.request(session, conversations: [local])
        let drain = E2EEV2RotationDrain()
        let retry = try await drain.run(session: session, backlog: backlog, dependencies: .init(
            isCurrent: { current.value == session }, activationEnabled: { true },
            pending: { .success([.init(
                conversationId: served, reason: "DEVICE_REVOKED", revision: 1, triggeredAt: "2026-11-09T15:58:00.000Z",
                currentEpochNumber: 3, currentEpochStatus: "compromised"
            )]) },
            rotate: { id, required in
                seen.value[id] = required
                return required ? .rotated(followUpRequired: false) : .noAction
            }, now: { clock.value }
        ))
        XCTAssertFalse(retry)
        XCTAssertEqual(seen.value, [served: true, local: false])
        XCTAssertFalse(try backlog.snapshot(session).hasWork)
    }

    /// Après un refus définitif, la même révision n'est plus forcée ; une révision
    /// plus grande l'est de nouveau. Un échec passager ne retire pas le forçage.
    func testV2RotationRefusedRequirementRevisionIsNotForcedAgain() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-refused-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000))
        let forced = LockedBox([Bool]()), revision = LockedBox(1), outcome = LockedBox(E2EEV2TransportFailureKind.permanent)
        let backlog = rotationBacklog(store: InMemoryTokenStore(), session: current, clock: clock)
        let id = "conversation_rotation_0001"
        let drain = E2EEV2RotationDrain()
        let deps = E2EEV2RotationDrainDependencies(
            isCurrent: { current.value == session }, activationEnabled: { true },
            pending: { .success([.init(
                conversationId: id, reason: "MEMBER_REMOVED", revision: revision.value,
                triggeredAt: "2026-11-09T19:26:06.804Z", currentEpochNumber: 4, currentEpochStatus: "active"
            )]) },
            rotate: { _, required in
                forced.value.append(required)
                return required ? .failure(.init(kind: outcome.value, message: "refused")) : .noAction
            }, now: { clock.value }
        )
        func pass() async throws {
            try backlog.request(session, conversations: [], resetRetry: true)
            clock.value = max(clock.value, try backlog.snapshot(session).notBeforeMs)
            _ = try await drain.run(session: session, backlog: backlog, dependencies: deps)
        }
        outcome.value = .retryable
        try await pass()
        try await pass()
        outcome.value = .permanent
        try await pass()
        try await pass()
        revision.value = 2
        try await pass()
        XCTAssertEqual(forced.value, [true, true, true, false, true])
    }

    func testV2RotationBoundedPassAndFollowUpDoNotAnnouncePrematureCompletion() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-budget-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000)), calls = LockedBox(0)
        let backlog = rotationBacklog(store: InMemoryTokenStore(), session: current, clock: clock)
        let first = "conversation_rotation_0001", second = "conversation_rotation_0002"
        try backlog.request(session, conversations: [first, second])
        let drain = E2EEV2RotationDrain()
        let deps = E2EEV2RotationDrainDependencies(
            isCurrent: { current.value == session }, activationEnabled: { true }, pending: { .success([]) },
            rotate: { id, _ in
                calls.value += 1
                if calls.value == 1 { return .rotated(followUpRequired: true) }
                return .noAction
            }, now: { clock.value }
        )
        _ = try await drain.run(session: session, backlog: backlog, dependencies: deps, limit: 1)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try backlog.snapshot(session).pending.count, 2)
        clock.value = try backlog.snapshot(session).notBeforeMs
        _ = try await drain.run(session: session, backlog: backlog, dependencies: deps, limit: 1)
        XCTAssertEqual(try backlog.snapshot(session).pending.count, 1)
        XCTAssertNotEqual(try backlog.snapshot(session).phase, .complete)
        clock.value = try backlog.snapshot(session).notBeforeMs
        let finalRetry = try await drain.run(session: session, backlog: backlog, dependencies: deps, limit: 1)
        XCTAssertFalse(finalRetry)
        XCTAssertFalse(try backlog.snapshot(session).hasWork)
        XCTAssertEqual(try backlog.snapshot(session).phase, .complete)
        XCTAssertEqual(calls.value, 3)
    }

    func testV2RotationOldSessionCannotAcknowledgeAfterSwitchOrRelogin() async throws {
        let session = LocalAccountSession(ownerScopeId: "user:rotation-owner-fixture", sessionId: UUID().uuidString)
        let current = LockedBox(session), clock = LockedBox(Int64(1_000)), calls = LockedBox(0)
        let store = InMemoryTokenStore()
        let backlog = rotationBacklog(store: store, session: current, clock: clock)
        let id = "conversation_rotation_0001"
        try backlog.request(session, conversations: [id])
        let ticket = try backlog.snapshot(session).pending[id]
        let drain = E2EEV2RotationDrain()
        let deps = E2EEV2RotationDrainDependencies(
            isCurrent: { current.value == session }, activationEnabled: { true }, pending: { .success([]) },
            rotate: { _, _ in
                calls.value += 1
                current.value = .init(ownerScopeId: "user:other-owner-fixture", sessionId: UUID().uuidString)
                return .noAction
            }, now: { clock.value }
        )
        do { _ = try await drain.run(session: session, backlog: backlog, dependencies: deps); XCTFail("Old session accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try backlog.snapshot(session))
        current.value = .init(ownerScopeId: session.ownerScopeId, sessionId: UUID().uuidString)
        do { _ = try await drain.run(session: session, backlog: backlog, dependencies: deps); XCTFail("Relogin adopted old work") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.value, 1)
        let raw = try XCTUnwrap(store.string(for: "rotation-work-v1:\(session.ownerNamespace)"))
        let audit = try JSONDecoder().decode(E2EEV2RotationState.self, from: Data(raw.utf8))
        XCTAssertEqual(audit.pending[id], ticket)
        XCTAssertNotEqual(audit.phase, .complete)
    }
}

extension E2EETests {
    /// Only synthetic defaults and in-memory vaults; mirror/biometric callbacks are never invoked.
    private final class RotationFixture: @unchecked Sendable {
        static let userKey = "SignalQuest.LocalAccountScope.userId.v1"
        static let sessionKey = "SignalQuest.LocalAccountScope.sessionId.v1"
        static let legacyKey = "SignalQuest.E2EE.LegacyCacheLocked.v1"
        let user = "rotation_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let vault = InMemoryTokenStore()
        let identity: E2EEV2DeviceIdentityStore
        let keys: E2EEV2EpochKeyStore
        let descriptor: E2EEV2DeviceDescriptor
        let credentials: CredentialStore
        let authToken: String
        let api: APIClient
        let network: URLSession
        let context: LocalAccountSession
        let outboxURL: URL
        let outbox: E2EEV2MediaOutboxStore
        private let previous: [String: Any]

        init() throws {
            let defaults = UserDefaults.standard
            var previous: [String: Any] = [:]
            for key in [Self.userKey, Self.sessionKey, Self.legacyKey] {
                if let value = defaults.object(forKey: key) { previous[key] = value }
            }
            self.previous = previous
            LocalAccountScope.deactivate()
            LocalAccountScope.activate(userId: user)
            identity = E2EEV2DeviceIdentityStore(tokenStore: vault, identityChanged: { namespace in
                if LocalAccountScope.storageNamespace == namespace {
                    guard let userId = LocalAccountScope.currentUserId else { return }
                    LocalAccountScope.invalidateNotificationSession()
                    LocalAccountScope.activate(userId: userId)
                }
            })
            keys = E2EEV2EpochKeyStore(tokenStore: vault)
            descriptor = try identity.loadOrCreate(ownerNamespace: LocalAccountScope.storageNamespace, label: "Synthetic iOS device")
            context = LocalAccountScope.sessionSnapshot()!
            credentials = CredentialStore(tokenStore: InMemoryTokenStore())
            authToken = Self.token(user)
            try credentials.setAccessToken(authToken)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            network = URLSession(configuration: configuration)
            api = APIClient(config: .test, credentials: credentials, session: network)
            outboxURL = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-outbox-\(UUID().uuidString)", isDirectory: true)
            outbox = try E2EEV2MediaOutboxStore(baseDirectory: outboxURL)
        }

        func select(_ user: String) -> LocalAccountSession {
            LocalAccountScope.invalidateNotificationSession()
            LocalAccountScope.activate(userId: user)
            return LocalAccountScope.sessionSnapshot()!
        }

        func close() {
            MockURLProtocol.requestHandler = nil
            network.invalidateAndCancel()
            LocalAccountScope.deactivate()
            if let previousUser = previous[Self.userKey] as? String {
                LocalAccountScope.activate(userId: previousUser)
                if previous[Self.sessionKey] == nil { LocalAccountScope.invalidateNotificationSession() }
            }
            if let legacy = previous[Self.legacyKey] { UserDefaults.standard.set(legacy, forKey: Self.legacyKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.legacyKey) }
            if FileManager.default.fileExists(atPath: outboxURL.path) {
                try? FileManager.default.removeItem(at: outboxURL)
            }
        }

        static func token(_ user: String) -> String {
            func b64(_ value: Data) -> String {
                value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let payload = try! JSONSerialization.data(withJSONObject: ["userId": user, "kind": "session", "exp": Int(Date().timeIntervalSince1970) + 3_600])
            let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
            return b64(header) + "." + b64(payload) + ".synthetic"
        }

        static func body(_ request: URLRequest) throws -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                    if data.count > 512 * 1_024 { throw E2EEError.invalidKey }
                }
            }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        func directory(number: Int, required: Bool, status: String = "active", reason: String = "DEVICE_ADDED") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 2, "activationEnabled": true, "migrationReady": true, "directoryTooLarge": false,
                "missingParticipantUserIds": [], "incompatibleSessionUserIds": [],
                "conversation": ["id": "conversation_rotation_0001", "currentProtocolVersion": 2,
                    "currentEpochNumber": number, "currentEpochStatus": status, "rotationRequired": required,
                    "rotationReason": required ? reason as Any : NSNull(), "rotationRevision": required ? 1 as Any : NSNull(),
                    "rotationTriggeredAt": required ? "2026-08-24T10:00:00Z" as Any : NSNull()],
                "participants": [["userId": user, "devices": [["deviceId": descriptor.deviceId, "platform": "ios",
                    "label": "Synthetic iOS device", "publicIdentityKeyB64": descriptor.publicIdentityKeyB64,
                    "publicSigningKeyB64": descriptor.publicSigningKeyB64,
                    "identityKeyAlgorithm": E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
                    "signingKeyAlgorithm": E2EEV2DeviceIdentityStore.signingKeyAlgorithm, "keyVersion": 1,
                    "approvedAt": "2026-08-24T10:00:00Z"]]]],
            ])
        }

        static func response(_ request: URLRequest, _ data: Data, status: Int = 200, extra: [String: String] = [:]) -> (HTTPURLResponse, Data) {
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"].merging(extra) { _, value in value })!, data)
        }
    }

    func testV2VaultLogoutLocksBWithoutDestroyingApprovedIdentityOrHistoryOfA() async throws {
        let fixture = try RotationFixture(); defer { fixture.close() }
        let a = fixture.context, id = "conversation_rotation_0001"
        let aKey = Data(repeating: 3, count: 32), bKey = Data(repeating: 5, count: 32)
        XCTAssertTrue(try fixture.keys.put(recordInput: .init(conversationId: id, epochId: "epoch_rotation_000001",
            epochNumber: 1, keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(aKey)), epochKey: aKey, ownerNamespace: a.ownerNamespace))
        let beforeIdentity = try fixture.vault.string(for: fixture.identity.storageKey(ownerNamespace: a.ownerNamespace))
        let b = fixture.select(fixture.user + "_B")
        let bDevice = try fixture.identity.loadOrCreate(ownerNamespace: b.ownerNamespace)
        XCTAssertTrue(try fixture.keys.put(recordInput: .init(conversationId: id, epochId: "epoch_rotation_000002",
            epochNumber: 1, keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(bKey)), epochKey: bKey, ownerNamespace: b.ownerNamespace))
        _ = fixture.select(fixture.user)
        try fixture.vault.set("legacy", for: "privateJwk:current")
        try fixture.vault.set("legacy", for: "conversation:unowned")
        let mirrorLocks = LockedBox(0)
        let service = E2EEService(api: fixture.api, tokenStore: fixture.vault, privacyLock: { mirrorLocks.value += 1 })
        await service.lockLocalKeys()
        XCTAssertNil(LocalAccountScope.currentSessionId)
        XCTAssertEqual(mirrorLocks.value, 1)
        XCTAssertThrowsError(try fixture.identity.load(ownerNamespace: a.ownerNamespace))
        XCTAssertNil(try fixture.vault.string(for: "privateJwk:current"))
        XCTAssertNil(try fixture.vault.string(for: "conversation:unowned"))
        _ = fixture.select(fixture.user + "_B")
        XCTAssertThrowsError(try fixture.identity.load(ownerNamespace: a.ownerNamespace))
        XCTAssertThrowsError(try fixture.keys.load(conversationId: id, ownerNamespace: a.ownerNamespace))
        XCTAssertEqual(try fixture.identity.load(ownerNamespace: b.ownerNamespace)?.deviceId, bDevice.deviceId)
        XCTAssertEqual(try fixture.keys.loadEpoch(conversationId: id, epochNumber: 1, ownerNamespace: b.ownerNamespace)?.epochKey, bKey)
        _ = fixture.select(fixture.user)
        XCTAssertEqual(try fixture.identity.load(ownerNamespace: a.ownerNamespace), fixture.descriptor)
        XCTAssertEqual(try fixture.vault.string(for: fixture.identity.storageKey(ownerNamespace: a.ownerNamespace)), beforeIdentity)
        XCTAssertEqual(try fixture.keys.loadEpoch(conversationId: id, epochNumber: 1, ownerNamespace: a.ownerNamespace)?.epochKey, aKey)
        // Effacement EXPLICITE synthétique de A : B reste intact, aucun removeAll(service).
        try E2EEV2VaultBoundary.purge(store: fixture.vault, ownerScopeId: a.ownerScopeId)
        XCTAssertNil(try fixture.identity.load(ownerNamespace: a.ownerNamespace))
        _ = fixture.select(fixture.user + "_B")
        XCTAssertEqual(try fixture.identity.load(ownerNamespace: b.ownerNamespace)?.deviceId, bDevice.deviceId)
        XCTAssertEqual(try fixture.keys.load(conversationId: id, ownerNamespace: b.ownerNamespace)?.epochKey, bKey)
    }

    func testV2BoundAccountDeletionDiscardsLateCookieAndCannotAdoptARelogin() async throws {
        let fixture = try RotationFixture(); defer { fixture.close() }
        let original = fixture.context, calls = LockedBox(0)
        let bToken = RotationFixture.token(fixture.user + "_B")
        MockURLProtocol.requestHandler = { request in
            calls.value += 1
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=\(fixture.authToken)")
            XCTAssertFalse(request.httpShouldHandleCookies)
            _ = fixture.select(fixture.user + "_B")
            try fixture.credentials.setAccessToken(bToken)
            return RotationFixture.response(request, Data("{\"success\":true,\"reauthMethod\":\"password\",\"message\":\"synthetic\"}".utf8),
                extra: ["Set-Cookie": "auth_token=late-A; Path=/"])
        }
        do {
            _ = try await UserService(api: fixture.api).deleteAccount(using: .password("synthetic"), expectedSession: original)
            XCTFail("Stale deletion response accepted")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        XCTAssertEqual(fixture.credentials.accessToken(), bToken)
        _ = fixture.select(fixture.user)
        do {
            _ = try await UserService(api: fixture.api).deleteAccount(using: .password("synthetic"), expectedSession: original)
            XCTFail("Old session adopted relogin")
        } catch { /* rejected before HTTP */ }
        XCTAssertEqual(calls.value, 1)
    }
}

private extension Data {
    var testHex: String { map { String(format: "%02x", $0) }.joined() }

    func testUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func testUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func testUInt64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(self[offset + index]) << UInt64(index * 8) }
        return value
    }

    func testInt(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw NSError(domain: "SignalQuestTests.PortableZIP", code: 1)
        }
        return Int(value)
    }
}

final class MessageTextOutboxTests: XCTestCase {
    func testServiceStagesBeforeFailureThenReplaysTheSameBody() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-service-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        let userId = "message-outbox-service-user"
        LocalAccountScope.activate(userId: userId)
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let tokenStore = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: tokenStore)
        try credentials.setAccessToken("synthetic-message-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        let outbox = MessageTextOutboxStore(baseDirectory: root)
        let service = MessagesService(api: api, textOutbox: outbox)
        let conversation = MessageConversation(
            id: "conversation-service-outbox",
            title: "Fixture",
            isGroup: false,
            e2eeEnabled: false,
            groupPhotoUrl: nil,
            createdAt: nil,
            updatedAt: nil,
            lastMessageAt: nil,
            lastReadAt: nil,
            pinnedAt: nil,
            participants: [],
            lastMessage: nil
        )
        let requestId = "local-message-service-0123456789abcdef"
        var requestBodies: [[String: Any]] = []
        var shouldFail = true
        MockURLProtocol.requestHandler = { request in
            let body = Self.requestBody(request)
            requestBodies.append(
                (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestId)
            if shouldFail { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let json = #"{"message":{"id":"server-message","conversationId":"conversation-service-outbox","senderId":"message-outbox-service-user","kind":"TEXT","content":"durable","attachments":[],"reactions":[]}}"#
            return (response, Data(json.utf8))
        }

        do {
            _ = try await service.sendText(
                "durable",
                in: conversation,
                replyToId: "parent-service",
                e2ee: nil,
                idempotencyKey: requestId,
                ttlSeconds: 120
            )
            XCTFail("Le premier transport synthetique doit echouer")
        } catch {
            // L'outbox doit rester la source de reprise.
        }
        let staged = try await outbox.pending(session: session)
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.request.clientRequestId, requestId)
        XCTAssertEqual(staged.first?.request.replyToId, "parent-service")
        XCTAssertEqual(staged.first?.request.ttlSeconds, 120)

        shouldFail = false
        await service.retryPendingTextMessages()
        let afterReplay = try await outbox.pending(session: session)
        XCTAssertTrue(afterReplay.isEmpty)
        XCTAssertGreaterThanOrEqual(requestBodies.count, 2)
        XCTAssertEqual(requestBodies.first?["clientRequestId"] as? String, requestId)
        XCTAssertEqual(requestBodies.last?["clientRequestId"] as? String, requestId)
        XCTAssertEqual(requestBodies.last?["replyToId"] as? String, "parent-service")
        XCTAssertEqual(requestBodies.last?["ttlSeconds"] as? Int, 120)
    }

    func testPermanentRefusalStaysUnsentWithoutBlockingOtherConversations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-blocking-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "message-outbox-blocking-user")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-message-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials,
                            session: URLSession(configuration: configuration))
        let outbox = MessageTextOutboxStore(baseDirectory: root)
        let service = MessagesService(api: api, textOutbox: outbox)
        func conversation(_ id: String) -> MessageConversation {
            MessageConversation(id: id, title: "Fixture", isGroup: false, e2eeEnabled: false,
                                groupPhotoUrl: nil, createdAt: nil, updatedAt: nil, lastMessageAt: nil,
                                lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil)
        }
        var online = false
        var posted: [String] = []
        MockURLProtocol.requestHandler = { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            let path = try XCTUnwrap(request.url?.path)
            posted.append(path)
            let removed = path.contains("conversation-removed")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: removed ? 404 : 200,
                                           httpVersion: nil, headerFields: nil)!
            let json = removed
                ? #"{"error":"NOT_FOUND","message":"Conversation introuvable"}"#
                : #"{"message":{"id":"server-kept","conversationId":"conversation-kept","senderId":"message-outbox-blocking-user","kind":"TEXT","content":"kept","attachments":[],"reactions":[]}}"#
            return (response, Data(json.utf8))
        }
        for id in ["conversation-removed", "conversation-kept"] {
            do {
                _ = try await service.sendText(id, in: conversation(id), e2ee: nil,
                                               idempotencyKey: "local-\(id)-0123456789abcdef")
                XCTFail("Hors ligne, l'envoi doit rester en file")
            } catch {}
        }

        online = true
        await service.retryPendingTextMessages()
        XCTAssertTrue(posted.contains { $0.contains("conversation-kept") },
                      "Un refus dans une conversation ne retient plus les autres (SOC-04)")
        let remaining = try await outbox.pending(session: session)
        XCTAssertEqual(remaining.map(\.conversationId), ["conversation-removed"])
        XCTAssertNotNil(remaining.first?.failureReason, "Le message refusé reste visible comme non envoyé")
        let shown = await service.pendingTextMessages(conversationId: "conversation-removed")
        XCTAssertEqual(shown.count, 1)

        let attempts = posted.count
        await service.retryPendingTextMessages()
        XCTAssertEqual(posted.count, attempts, "Un message refusé n'est plus rejoué sans geste")
        await service.discardPendingText(clientRequestId: "local-conversation-removed-0123456789abcdef")
        let afterDiscard = try await outbox.pending(session: session)
        XCTAssertTrue(afterDiscard.isEmpty)
    }

    // MARK: Demandes de message (DM-REQ-1)

    private func requestFixture(userId: String) throws -> (service: MessagesService, outbox: MessageTextOutboxStore, session: LocalAccountSession, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-request-\(UUID().uuidString)", isDirectory: true)
        LocalAccountScope.activate(userId: userId)
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-message-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let outbox = MessageTextOutboxStore(baseDirectory: root)
        return (MessagesService(api: api, textOutbox: outbox), outbox, session, root)
    }

    private func plainConversation(_ id: String) -> MessageConversation {
        MessageConversation(id: id, title: "Fixture", isGroup: false, e2eeEnabled: false,
                            groupPhotoUrl: nil, createdAt: nil, updatedAt: nil, lastMessageAt: nil,
                            lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil)
    }

    /// 403 `MESSAGE_REQUEST_PENDING` en v1 : terminal. Le texte reste « non envoyé » avec sa raison, la file
    /// ne le rejoue jamais seule, et la conversation apprend qu'elle attend l'acceptation.
    /// Texte écrit en clair hors ligne, rejoué après la bascule : le serveur répond 409
    /// E2EE_AUTO_REQUIRED. La file le garde « non envoyé » et le rend à l'appelant, qui le
    /// renvoie en v2 ; il n'est plus rejoué en clair.
    func testAutoRequiredRefusalIsReturnedForAV2Resend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-auto-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "message-outbox-auto-user")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-message-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials,
                            session: URLSession(configuration: configuration))
        let outbox = MessageTextOutboxStore(baseDirectory: root)
        let service = MessagesService(api: api, textOutbox: outbox)
        let conversation = MessageConversation(
            id: "conversation-auto", title: "Fixture", isGroup: false, e2eeEnabled: false,
            groupPhotoUrl: nil, createdAt: nil, updatedAt: nil, lastMessageAt: nil,
            lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil
        )
        var online = false
        var posted = 0
        MockURLProtocol.requestHandler = { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            posted += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"Conversation chiffrée","code":"E2EE_AUTO_REQUIRED"}"#.utf8))
        }
        do {
            _ = try await service.sendText("bonjour", in: conversation, e2ee: nil,
                                           idempotencyKey: "local-auto-0123456789abcdef")
            XCTFail("Hors ligne, l'envoi doit rester en file")
        } catch {}

        online = true
        let refused = await service.retryPendingTextMessages()
        XCTAssertEqual(refused.map(\.clientRequestId), ["local-auto-0123456789abcdef"])
        XCTAssertEqual(refused.first?.request.content, "bonjour")
        let kept = try await outbox.pending(session: session)
        XCTAssertNotNil(kept.first?.failureReason, "Gardé « non envoyé » tant que la v2 ne l'a pas repris")

        let attempts = posted
        let again = await service.retryPendingTextMessages()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(posted, attempts, "Jamais rejoué en clair sans geste")
    }

    func testMessageRequestPendingIsTerminalAndNeverReplayed() async throws {
        let fixture = try requestFixture(userId: "message-request-pending-user")
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var posts = 0
        MockURLProtocol.requestHandler = { request in
            posts += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"Ta demande de message n'a pas encore été acceptée.","code":"MESSAGE_REQUEST_PENDING"}"#.utf8))
        }
        do {
            _ = try await fixture.service.sendText("Salut", in: plainConversation("conversation-pending"), e2ee: nil,
                                                   idempotencyKey: "local-conversation-pending-0123456789abcdef")
            XCTFail("Un 403 n'est pas un envoi")
        } catch {
            XCTAssertTrue(error.isMessageRequestPending)
            XCTAssertTrue(error.isPermanentRequestFailure)
        }
        let kept = try await fixture.outbox.pending(session: fixture.session)
        XCTAssertEqual(kept.count, 1, "Le texte reste visible, non envoyé")
        XCTAssertEqual(kept.first?.failureReason, String(localized: "Ta demande de message n’a pas encore été acceptée."))
        XCTAssertEqual(MessageRequestEvents.recentRequest(conversationId: "conversation-pending"), MessageRequest.senderSent)

        await fixture.service.retryPendingTextMessages()
        XCTAssertEqual(posts, 1, "Un refus de demande n'est jamais rejoué par la file")
    }

    /// Le reçu d'un premier message porte `request` : la conversation ferme son compositeur.
    func testTheFirstMessageReceiptAnnouncesTheSentRequest() async throws {
        let fixture = try requestFixture(userId: "message-request-receipt-user")
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"message":{"id":"server-first","conversationId":"conversation-first","senderId":"message-request-receipt-user","kind":"TEXT","content":"Salut","attachments":[],"reactions":[]},"request":{"role":"sender","status":"pending","remaining":0}}"#
            return (response, Data(json.utf8))
        }
        let sent = try await fixture.service.sendText("Salut", in: plainConversation("conversation-first"), e2ee: nil,
                                                      idempotencyKey: "local-conversation-first-0123456789abcdef")
        XCTAssertEqual(sent.id, "server-first")
        XCTAssertEqual(MessageRequestEvents.recentRequest(conversationId: "conversation-first"), MessageRequest.senderSent)
        let left = try await fixture.outbox.pending(session: fixture.session)
        XCTAssertTrue(left.isEmpty)
    }

    /// 429 `MESSAGE_REQUEST_LIMIT` en v1 : une seule requête, aucun rejeu, et la date (`Retry-After`) en main.
    func testMessageRequestLimitIsNotReplayedAndCarriesItsDate() async throws {
        let fixture = try requestFixture(userId: "message-request-limit-user")
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var posts = 0
        MockURLProtocol.requestHandler = { request in
            posts += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 429, httpVersion: nil,
                                           headerFields: ["Retry-After": "3600"])!
            return (response, Data(#"{"error":"Tu as atteint le nombre de demandes de message pour aujourd'hui.","code":"MESSAGE_REQUEST_LIMIT","details":{"until":"2026-10-20T00:00:00.000Z"}}"#.utf8))
        }
        do {
            _ = try await fixture.service.createConversation(participantIds: ["stranger"], title: nil, e2ee: false)
            XCTFail("Un 429 n'est pas une création")
        } catch {
            let limit = try XCTUnwrap(error.messageRequestLimit)
            let until = try XCTUnwrap(limit.until)
            XCTAssertGreaterThan(until.timeIntervalSinceNow, 3_000)
            XCTAssertTrue(error.isPermanentRequestFailure, "Les files ne rejouent pas un plafond atteint")
            XCTAssertEqual(error.userFacingMessage, String(localized: "Un compte récent peut envoyer 5 demandes de message par jour. Tu pourras écrire demain, ou dès maintenant si la personne t’ajoute en ami."))
        }
        XCTAssertEqual(posts, 1, "Aucun rejeu automatique")
    }

    /// Sans `requestsSummary` ni `request`, la messagerie est celle d'aujourd'hui : pas de ligne
    /// « Demandes », liste inchangée.
    func testAServerWithoutRequestsServesTheSameConversationList() async throws {
        let fixture = try requestFixture(userId: "message-request-legacy-user")
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"conversations":[{"id":"c1","participants":[]}],"hasMore":false}"#.utf8))
        }
        let page = try await fixture.service.conversationPage(cursor: nil, take: 50)
        XCTAssertNil(page.requestsSummary, "Pas de ligne « Demandes de message » sans le résumé du serveur")
        XCTAssertEqual(page.conversations.map(\.id), ["c1"])
        XCTAssertNil(page.conversations.first?.request)
    }

    /// Une demande reçue en attente ne se glisse jamais dans la liste ordinaire (badge, cibles de transfert).
    func testAnIncomingPendingRequestNeverJoinsTheOrdinaryList() async throws {
        let fixture = try requestFixture(userId: "message-request-incoming-user")
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"conversations":[{"id":"ordinary","participants":[]},{"id":"asked","participants":[],"request":{"role":"recipient","status":"pending","id":"r1"}},{"id":"mine","participants":[],"request":{"role":"sender","status":"pending","remaining":0}}],"hasMore":false,"requestsSummary":{"count":1,"unreadCount":1}}"#
            return (response, Data(json.utf8))
        }
        let page = try await fixture.service.conversationPage(cursor: nil, take: 50)
        XCTAssertEqual(page.conversations.map(\.id), ["ordinary", "mine"])
        XCTAssertEqual(page.requestsSummary, MessageRequestsSummary(count: 1, unreadCount: 1))
    }

    func testExactCiphertextReplyTtlAndRequestIdSurviveStoreRecreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalAccountSession(
            ownerScopeId: "user:message-outbox-fixture",
            sessionId: UUID().uuidString.lowercased()
        )
        let requestId = "local-message-outbox-0123456789abcdef"
        let request = SendMessageRequest(
            kind: "TEXT",
            content: nil,
            e2ee: E2EEPayload(
                v: 1,
                ivB64: "synthetic-iv",
                ciphertextB64: "synthetic-ciphertext",
                aadB64: nil
            ),
            replyToId: "parent-message",
            attachments: nil,
            ttlSeconds: 90,
            clientRequestId: requestId
        )
        let record = MessageTextOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            conversationId: "conversation-message-outbox",
            clientRequestId: requestId,
            request: request,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let current: MessageTextOutboxStore.CurrentSession = { _ in true }
        let publish: MessageTextOutboxStore.Publisher = { _, write in try write() }
        let first = MessageTextOutboxStore(
            baseDirectory: root,
            currentSession: current,
            publisher: publish
        )
        try await first.stage(record, session: session)
        try await first.stage(record, session: session)

        let reopened = MessageTextOutboxStore(
            baseDirectory: root,
            currentSession: current,
            publisher: publish
        )
        let pending = try await reopened.pending(session: session)
        XCTAssertEqual(pending, [record])
        XCTAssertEqual(pending.first?.request.replyToId, "parent-message")
        XCTAssertEqual(pending.first?.request.ttlSeconds, 90)
        XCTAssertEqual(pending.first?.request.clientRequestId, requestId)
        XCTAssertEqual(pending.first?.request.e2ee?.ciphertextB64, "synthetic-ciphertext")
        let encodedRequest = try JSONEncoder.signalQuest.encode(try XCTUnwrap(pending.first?.request))
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedRequest) as? [String: Any]
        )
        XCTAssertEqual(encodedObject["clientRequestId"] as? String, requestId)

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("SignalQuestMessageOutbox", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let raw = try Data(contentsOf: try XCTUnwrap(storedFiles.first))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("plaintext-must-not-persist"))

        var changed = record
        changed = MessageTextOutboxRecord(
            ownerScopeId: changed.ownerScopeId,
            sessionId: changed.sessionId,
            conversationId: changed.conversationId,
            clientRequestId: changed.clientRequestId,
            request: SendMessageRequest(
                kind: "TEXT",
                content: nil,
                e2ee: E2EEPayload(v: 1, ivB64: "other", ciphertextB64: "changed", aadB64: nil),
                replyToId: changed.request.replyToId,
                attachments: nil,
                ttlSeconds: changed.request.ttlSeconds,
                clientRequestId: changed.clientRequestId
            ),
            createdAt: changed.createdAt
        )
        do {
            try await reopened.stage(changed, session: session)
            XCTFail("Une meme request id ne doit jamais accepter un ciphertext different")
        } catch {
            XCTAssertEqual(error as? MessageTextOutboxError, .requestConflict)
        }

        try await reopened.acknowledge(session: session, clientRequestId: requestId)
        let afterAck = try await reopened.pending(session: session)
        XCTAssertTrue(afterAck.isEmpty)
    }

    func testNewSessionOfTheSameAccountAdoptsPendingRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-outbox-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = "user:message-outbox-session-fixture"
        let old = LocalAccountSession(ownerScopeId: owner, sessionId: "old-session")
        let next = LocalAccountSession(ownerScopeId: owner, sessionId: "next-session")
        let current: MessageTextOutboxStore.CurrentSession = { _ in true }
        let publish: MessageTextOutboxStore.Publisher = { _, write in try write() }
        let store = MessageTextOutboxStore(baseDirectory: root, currentSession: current, publisher: publish)
        let request = SendMessageRequest(
            kind: "TEXT", content: "old", e2ee: nil, replyToId: nil, attachments: nil,
            ttlSeconds: nil, clientRequestId: "local-old-session-request"
        )
        try await store.stage(
            MessageTextOutboxRecord(
                ownerScopeId: owner,
                sessionId: old.sessionId,
                conversationId: "conversation-old",
                clientRequestId: "local-old-session-request",
                request: request,
                createdAt: Date()
            ),
            session: old
        )

        // Cookie expiré puis reconnexion au même compte : l'envoi en attente est repris.
        let nextPending = try await store.pending(session: next)
        XCTAssertEqual(nextPending.map(\.clientRequestId), ["local-old-session-request"])
        XCTAssertEqual(nextPending.first?.sessionId, next.sessionId)
        XCTAssertEqual(nextPending.first?.request.content, "old")
        let adopted = try await store.record(session: next, clientRequestId: "local-old-session-request")
        XCTAssertNotNil(adopted)

        // Le propriétaire d'un autre compte ne voit rien de cette file.
        let stranger = LocalAccountSession(ownerScopeId: "user:message-outbox-stranger", sessionId: "stranger-session")
        let strangerPending = try await store.pending(session: stranger)
        XCTAssertTrue(strangerPending.isEmpty)
    }

    func testEraseRemovesTheLeavingAccountQueueOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-text-outbox-erase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current: MessageTextOutboxStore.CurrentSession = { _ in true }
        let publish: MessageTextOutboxStore.Publisher = { _, write in try write() }
        let store = MessageTextOutboxStore(baseDirectory: root, currentSession: current, publisher: publish)
        var sessions: [LocalAccountSession] = []
        for name in ["leaving", "staying"] {
            let session = LocalAccountSession(ownerScopeId: "user:message-outbox-\(name)", sessionId: "\(name)-session")
            sessions.append(session)
            let request = SendMessageRequest(kind: "TEXT", content: name, e2ee: nil, replyToId: nil, attachments: nil,
                                             ttlSeconds: nil, clientRequestId: "request-\(name)")
            try await store.stage(
                MessageTextOutboxRecord(ownerScopeId: session.ownerScopeId, sessionId: session.sessionId,
                                        conversationId: "conversation", clientRequestId: "request-\(name)",
                                        request: request, createdAt: Date()),
                session: session)
        }

        MessageTextOutboxStore.erase(ownerScopeId: sessions[0].ownerScopeId, baseDirectory: root)

        let leaving = try await store.pending(session: sessions[0])
        let staying = try await store.pending(session: sessions[1])
        XCTAssertTrue(leaving.isEmpty)
        XCTAssertEqual(staying.count, 1)
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

final class MessageAttachmentOutboxTests: XCTestCase {
    func testSourceAndUploadedReceiptSurviveRecreationThenAckPurgesBothFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-attachment-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalAccountSession(
            ownerScopeId: "user:message-attachment-fixture",
            sessionId: "attachment-session"
        )
        let source = Data("synthetic-image-bytes".utf8)
        let sha = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let requestId = "attachment-request-0123456789abcdef"
        let record = MessageAttachmentOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            conversationId: "conversation-attachment",
            clientRequestId: requestId,
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            kind: "IMAGE",
            caption: "caption",
            replyToId: "parent-message",
            width: 10,
            height: 20,
            contentSha256: sha,
            uploadedAttachment: nil,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let current: MessageTextOutboxStore.CurrentSession = { _ in true }
        let publish: MessageTextOutboxStore.Publisher = { _, write in try write() }
        let first = MessageAttachmentOutboxStore(
            baseDirectory: root,
            currentSession: current,
            publisher: publish
        )
        try await first.stage(record, source: source, session: session)

        let reopened = MessageAttachmentOutboxStore(
            baseDirectory: root,
            currentSession: current,
            publisher: publish
        )
        let restoredRecords = try await reopened.pending(session: session)
        let restoredSource = try await reopened.sourceData(record, session: session)
        XCTAssertEqual(restoredRecords, [record])
        XCTAssertEqual(restoredSource, source)
        let uploaded = UploadedAttachment(
            kind: "IMAGE",
            url: "https://example.invalid/message.webp",
            fileName: "photo.webp",
            contentType: "image/webp",
            size: source.count,
            width: 10,
            height: 20
        )
        try await reopened.markUploaded(
            session: session,
            clientRequestId: requestId,
            attachment: uploaded
        )
        let uploadedRecord = try await reopened.record(session: session, clientRequestId: requestId)
        XCTAssertEqual(uploadedRecord?.uploadedAttachment, uploaded)
        try await reopened.acknowledge(session: session, clientRequestId: requestId)
        let afterAck = try await reopened.pending(session: session)
        XCTAssertTrue(afterAck.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("SignalQuestMessageAttachmentOutbox", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertTrue(files.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.isEmpty)
    }

    func testNewSessionOfTheSameAccountAdoptsPendingAttachmentAndItsSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-attachment-adopt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = "user:message-attachment-adopt"
        let old = LocalAccountSession(ownerScopeId: owner, sessionId: "old-session")
        let next = LocalAccountSession(ownerScopeId: owner, sessionId: "next-session")
        let source = Data("synthetic-image-bytes".utf8)
        let sha = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let record = MessageAttachmentOutboxRecord(
            ownerScopeId: owner, sessionId: old.sessionId, conversationId: "conversation-attachment",
            clientRequestId: "attachment-adopt-request-0123456789", filename: "photo.jpg", mimeType: "image/jpeg",
            kind: "IMAGE", caption: "caption", replyToId: nil, width: 10, height: 20, contentSha256: sha,
            uploadedAttachment: nil, createdAt: Date(timeIntervalSince1970: 1_000))
        let store = MessageAttachmentOutboxStore(
            baseDirectory: root, currentSession: { _ in true }, publisher: { _, write in try write() })
        try await store.stage(record, source: source, session: old)

        let pending = try await store.pending(session: next)

        XCTAssertEqual(pending.map(\.clientRequestId), [record.clientRequestId])
        XCTAssertEqual(pending.first?.sessionId, next.sessionId)
        let restored = try await store.sourceData(try XCTUnwrap(pending.first), session: next)
        XCTAssertEqual(restored, source)

        MessageAttachmentOutboxStore.erase(ownerScopeId: owner, baseDirectory: root)
        let afterErase = try await store.pending(session: next)
        XCTAssertTrue(afterErase.isEmpty)
    }

    func testServiceStagesBeforeUploadFailureThenReplaysUploadAndMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-attachment-service-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "message-attachment-service-user")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let tokenStore = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: tokenStore)
        try credentials.setAccessToken("synthetic-attachment-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        let outbox = MessageAttachmentOutboxStore(baseDirectory: root)
        let service = MessagesService(api: api, attachmentOutbox: outbox)
        let conversation = MessageConversation(
            id: "conversation-attachment-service",
            title: "Fixture",
            isGroup: false,
            e2eeEnabled: false,
            groupPhotoUrl: nil,
            createdAt: nil,
            updatedAt: nil,
            lastMessageAt: nil,
            lastReadAt: nil,
            pinnedAt: nil,
            participants: [],
            lastMessage: nil
        )
        let source = Data("binary-attachment-fixture".utf8)
        var uploadBodies: [String] = []
        var messageBodies: [[String: Any]] = []
        var failFirstUpload = true
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let body = Self.requestBody(request)
            if path == "/api/messages/attachments" {
                uploadBodies.append(String(decoding: body, as: UTF8.self))
                if failFirstUpload { throw URLError(.notConnectedToInternet) }
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = #"{"attachment":{"kind":"IMAGE","url":"https://example.invalid/message.webp","fileName":"photo.webp","contentType":"image/webp","size":25,"width":12,"height":8}}"#
                return (response, Data(json.utf8))
            }
            messageBodies.append(
                (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            )
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"message":{"id":"server-attachment-message","conversationId":"conversation-attachment-service","senderId":"message-attachment-service-user","kind":"ATTACHMENT","content":"caption","attachments":[],"reactions":[]}}"#
            return (response, Data(json.utf8))
        }

        do {
            _ = try await service.sendAttachmentData(
                source,
                filename: "photo.jpg",
                mimeType: "image/jpeg",
                kind: "IMAGE",
                caption: "caption",
                width: 12,
                height: 8,
                in: conversation,
                replyToId: "parent-attachment",
                e2ee: nil,
                ttlSeconds: 86_400
            )
            XCTFail("Le premier upload synthetique doit echouer")
        } catch {
            // Attendu : source et intention restent dans l'outbox.
        }
        let staged = try await outbox.pending(session: session)
        let stagedRecord = try XCTUnwrap(staged.first)
        let requestId = stagedRecord.clientRequestId
        let contentSha256 = stagedRecord.contentSha256
        XCTAssertEqual(staged.count, 1)
        let restoredSource = try await outbox.sourceData(stagedRecord, session: session)
        XCTAssertEqual(restoredSource, source)

        failFirstUpload = false
        await service.retryPendingAttachments()
        let afterReplay = try await outbox.pending(session: session)
        XCTAssertTrue(afterReplay.isEmpty)
        XCTAssertEqual(uploadBodies.count, 2)
        XCTAssertTrue(uploadBodies.allSatisfy { $0.contains(requestId) })
        XCTAssertTrue(uploadBodies.allSatisfy { $0.contains(contentSha256) })
        XCTAssertEqual(messageBodies.count, 1)
        XCTAssertEqual(messageBodies.first?["clientRequestId"] as? String, requestId)
        XCTAssertEqual(messageBodies.first?["replyToId"] as? String, "parent-attachment")
        // Le mode éphémère survit au passage par la file d'envoi.
        XCTAssertEqual(messageBodies.first?["ttlSeconds"] as? Int, 86_400)
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

final class SocialPostOutboxTests: XCTestCase {
    func testEraseRemovesThePostQueueAndTheVoiceNoteCacheOfTheLeavingAccount() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-outbox-erase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let leaving = LocalAccountScope.storageNamespace(for: "user:leaving")
        let staying = LocalAccountScope.storageNamespace(for: "user:staying")
        let fileManager = FileManager.default
        for ns in [leaving, staying] {
            let posts = base.appendingPathComponent("SignalQuestSocialPostOutbox/\(ns)", isDirectory: true)
            let notes = base.appendingPathComponent("VoiceNotes/\(ns)", isDirectory: true)
            for directory in [posts, notes] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: directory.appendingPathComponent("a.json"))
            }
        }

        SocialPostOutboxStore.erase(ownerScopeId: "user:leaving", baseDirectory: base)
        VoiceNoteCache.erase(ownerScopeId: "user:leaving", cachesDirectory: base)

        XCTAssertFalse(fileManager.fileExists(atPath: base.appendingPathComponent("SignalQuestSocialPostOutbox/\(leaving)").path))
        XCTAssertFalse(fileManager.fileExists(atPath: base.appendingPathComponent("VoiceNotes/\(leaving)").path))
        XCTAssertTrue(fileManager.fileExists(atPath: base.appendingPathComponent("SignalQuestSocialPostOutbox/\(staying)").path))
        XCTAssertTrue(fileManager.fileExists(atPath: base.appendingPathComponent("VoiceNotes/\(staying)").path))
    }

    @MainActor
    func testEmailVerification403KeepsComposerDraftWithoutAutomaticReplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-email-gate-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "email-gate-\(UUID().uuidString)")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-email-gate-token")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config))
        let outbox = SocialPostOutboxStore(
            baseDirectory: root,
            currentSession: { _ in true },
            publisher: { _, write in try write() }
        )
        let service = SocialFeedService(api: api, postOutbox: outbox)
        var submissions = 0
        MockURLProtocol.requestHandler = { request in
            submissions += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"EMAIL_NOT_VERIFIED","error":"Confirme ton adresse."}"#.utf8))
        }

        let composer = ComposerViewModel(service: service)
        composer.text = "Brouillon à reprendre après confirmation"
        await composer.publish()
        XCTAssertEqual(submissions, 1, "Le refus doit venir du vrai transport HTTP simulé")
        XCTAssertFalse(composer.didPublish)
        XCTAssertEqual(composer.text, "Brouillon à reprendre après confirmation")
        XCTAssertNotNil(composer.errorMessage)
        let pending = try await outbox.pending(session: session)
        XCTAssertTrue(pending.isEmpty)
        await service.retryPendingPosts()
        XCTAssertEqual(submissions, 1, "Un 403 métier ne doit pas être rejoué automatiquement")
        let reopened = ComposerViewModel(service: service)
        XCTAssertEqual(reopened.text, composer.text)
        reopened.clearDraft()
    }

    func testPublishingTheSameDraftTwiceReusesTheQueuedRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "social-dedupe-\(UUID().uuidString)")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-social-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials,
                            session: URLSession(configuration: configuration))
        let outbox = SocialPostOutboxStore(baseDirectory: root)
        let service = SocialFeedService(api: api, postOutbox: outbox)
        var online = false
        var postedRequestIds: [String] = []
        MockURLProtocol.requestHandler = { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any]) ?? [:]
            postedRequestIds.append(body["clientRequestId"] as? String ?? "")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"post":null,"requestId":"post-request"}"#.utf8))
        }
        for _ in 0..<2 {
            do {
                _ = try await service.publishPost(text: "Même brouillon", visibility: "friends",
                                                  imageData: nil, imageMimeType: "image/jpeg",
                                                  targetType: nil, targetId: nil,
                                                  extraMetadata: nil, poll: nil)
                XCTFail("Hors ligne, la publication doit rester en file")
            } catch {}
        }
        let staged = try await outbox.pending(session: session)
        XCTAssertEqual(staged.count, 1, "Un second appui sur Publier ne crée plus de doublon (SOC-02)")

        online = true
        await service.retryPendingPosts()
        XCTAssertEqual(postedRequestIds, [staged.first?.clientRequestId ?? "?"])
        let afterReplay = try await outbox.pending(session: session)
        XCTAssertTrue(afterReplay.isEmpty)
    }

    func testImageMetadataAndReceiptSurviveRecreationThenAckPurgesFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-post-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalAccountSession(ownerScopeId: "user:social-post-fixture", sessionId: "social-session")
        let image = Data("synthetic-social-image".utf8)
        let sha = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let requestId = "post:00000000-0000-0000-0000-000000000001"
        let request = CreatePostRequest(
            text: "publication durable",
            visibility: "friends",
            targetType: "speedtest",
            targetId: "speedtest-1",
            placeLabel: nil,
            latitude: nil,
            longitude: nil,
            metadata: ["platform": .string("ios")],
            attachments: nil,
            attachRadio: false,
            poll: nil,
            clientRequestId: requestId
        )
        let record = SocialPostOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            clientRequestId: requestId,
            request: request,
            imageMimeType: "image/jpeg",
            imageSha256: sha,
            uploadedAttachment: nil,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let current: MessageTextOutboxStore.CurrentSession = { _ in true }
        let publish: MessageTextOutboxStore.Publisher = { _, write in try write() }
        let first = SocialPostOutboxStore(baseDirectory: root, currentSession: current, publisher: publish)
        try await first.stage(record, imageData: image, session: session)
        let reopened = SocialPostOutboxStore(baseDirectory: root, currentSession: current, publisher: publish)
        let pending = try await reopened.pending(session: session)
        let restoredImage = try await reopened.imageData(record, session: session)
        XCTAssertEqual(pending, [record])
        XCTAssertEqual(restoredImage, image)

        let upload = CreatePostAttachment(
            kind: "image",
            url: URL(string: "https://example.invalid/social.webp"),
            thumbnailUrl: URL(string: "https://example.invalid/social-thumb.webp"),
            altText: nil,
            metadata: nil
        )
        try await reopened.markUploaded(session: session, clientRequestId: requestId, attachment: upload)
        let uploaded = try await reopened.record(session: session, clientRequestId: requestId)
        XCTAssertEqual(uploaded?.uploadedAttachment, upload)
        try await reopened.acknowledge(session: session, clientRequestId: requestId)
        let afterAck = try await reopened.pending(session: session)
        XCTAssertTrue(afterAck.isEmpty)
    }

    func testServiceStagesBeforeUploadFailureThenReplaysUploadAndPost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-post-service-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockURLProtocol.requestHandler = nil
            LocalAccountScope.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        LocalAccountScope.activate(userId: "social-post-service-user")
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let tokenStore = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: tokenStore)
        try credentials.setAccessToken("synthetic-social-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        let outbox = SocialPostOutboxStore(baseDirectory: root)
        let service = SocialFeedService(api: api, postOutbox: outbox)
        let image = try StoryTypedTests.makeJpegWithSensitiveMetadata()
        var uploadBodies: [String] = []
        var postBodies: [[String: Any]] = []
        var failFirstUpload = true
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let body = Self.requestBody(request)
            if path == "/api/social/uploads" {
                uploadBodies.append(String(decoding: body, as: UTF8.self))
                if failFirstUpload { throw URLError(.notConnectedToInternet) }
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
                let json = #"{"upload":{"kind":"image","url":"https://example.invalid/social.webp","thumbnailUrl":"https://example.invalid/social-thumb.webp","altText":null,"metadata":null},"requestId":"upload-request"}"#
                return (response, Data(json.utf8))
            }
            postBodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"post":null,"requestId":"post-request"}"#.utf8))
        }

        do {
            _ = try await service.publishPost(
                text: "publication durable",
                visibility: "friends",
                imageData: image,
                imageMimeType: "image/jpeg",
                targetType: "speedtest",
                targetId: "speedtest-1",
                extraMetadata: ["speedtestId": .string("speedtest-1")],
                poll: nil
            )
            XCTFail("Le premier upload social synthetique doit echouer")
        } catch {
            // Attendu : l'image et le payload restent dans l'outbox.
        }
        let staged = try await outbox.pending(session: session)
        let stagedRecord = try XCTUnwrap(staged.first)
        let restoredImage = try await outbox.imageData(stagedRecord, session: session)
        // L'image gardée dans la file est déjà la version nettoyée : sans GPS.
        XCTAssertNotEqual(restoredImage, image)
        XCTAssertNil(try StoryTypedTests.properties(of: restoredImage)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(stagedRecord.imageMimeType, "image/jpeg")

        failFirstUpload = false
        await service.retryPendingPosts()
        let afterReplay = try await outbox.pending(session: session)
        XCTAssertTrue(afterReplay.isEmpty)
        XCTAssertEqual(uploadBodies.count, 2)
        XCTAssertTrue(uploadBodies.allSatisfy { $0.contains(stagedRecord.clientRequestId) })
        XCTAssertTrue(uploadBodies.allSatisfy { $0.contains("image-0") })
        XCTAssertEqual(postBodies.count, 1)
        XCTAssertEqual(postBodies.first?["clientRequestId"] as? String, stagedRecord.clientRequestId)
        XCTAssertEqual(postBodies.first?["targetId"] as? String, "speedtest-1")
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

/// Clé v1 au format commun iOS/Android/web : paire RSA-2048 en JWK base64url
/// sans padding, clé privée sous PBKDF2-HMAC-SHA256 (210 000 itérations) puis
/// AES-256-GCM (iv + texte chiffré + tag, base64 sans padding). L'app n'en crée
/// plus (lot 10.5) : seuls les tests en fabriquent, pour le déverrouillage.
private struct LegacyKeyFixture {
    let privateJwk: String
    let publicJwk: String
    let bootstrapKey: E2EEBootstrapKey

    init(password: String) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(privateKey, &error) as Data?)
        // PKCS#1 : SEQUENCE { version, n, e, d, p, q, dp, dq, qi }.
        let integers = try Self.integers(der)
        XCTAssertGreaterThanOrEqual(integers.count, 9)
        var privateObject = ["kty": "RSA"]
        for (index, field) in ["n", "e", "d", "p", "q", "dp", "dq", "qi"].enumerated() {
            privateObject[field] = integers[index + 1].base64URLEncodedNoPadding()
        }
        let publicObject = ["kty": "RSA", "n": privateObject["n"]!, "e": privateObject["e"]!]
        privateJwk = String(decoding: try JSONSerialization.data(withJSONObject: privateObject), as: UTF8.self)
        publicJwk = String(decoding: try JSONSerialization.data(withJSONObject: publicObject), as: UTF8.self)

        let iterations = 210_000
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let nonce = AES.GCM.Nonce()
        let wrapKey = SymmetricKey(data: E2EEService.pbkdf2SHA256(
            password: password, salt: salt, iterations: iterations, keyLength: 32
        ))
        let sealed = try AES.GCM.seal(Data(privateJwk.utf8), using: wrapKey, nonce: nonce)
        bootstrapKey = E2EEBootstrapKey(
            publicKeyJwk: publicJwk,
            encryptedPrivateJwk: (Data(nonce) + sealed.ciphertext + sealed.tag).base64EncodedNoPadding(),
            kdfSaltB64: salt.base64EncodedNoPadding(),
            kdfIterations: iterations
        )
    }

    /// INTEGERs d'un SEQUENCE DER, sans leur octet de signe initial.
    private static func integers(_ der: Data) throws -> [Data] {
        let bytes = [UInt8](der)
        var index = 0
        func element() throws -> (tag: UInt8, body: ArraySlice<UInt8>) {
            let tag = bytes[index]
            index += 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            defer { index += length }
            return (tag, bytes[index..<index + length])
        }
        let sequence = try element()
        XCTAssertEqual(sequence.tag, 0x30)
        index = sequence.body.startIndex
        var values: [Data] = []
        while index < sequence.body.endIndex {
            let integer = try element()
            XCTAssertEqual(integer.tag, 0x02)
            values.append(Data(integer.body.drop { $0 == 0 }))
        }
        return values
    }
}
