import Foundation
import CryptoKit
import Security

// Shared by the app and notification service extension. This file has no network,
// account storage, Keychain or UI dependency. Protocol bytes and validation stay common.

enum E2EEV2DeviceAlgorithms {
    static let identityKeyAlgorithm = "P256_X963_ECDH_HKDF_SHA256"
    static let signingKeyAlgorithm = "P256_X963_ECDSA_SHA256_DER"
}

enum E2EEV2WireLimits {
    static let maxJSONResponseBytes = 512 * 1_024
}

enum E2EEV2ProtocolWire {
    static let version = 2
    static let protocolVersionHeader = "X-SQ-Protocol-Version"
    static let capabilitiesHeader = "X-SQ-Capabilities"
    static let contractPreviewCapability = "e2ee_v2_contract_preview"
    static let deviceIdentityCapability = "e2ee_device_identity_v2"
    static let messageEnvelopeCapability = "e2ee_message_envelope_v2"
    static let messageCapabilities: Set<String> = [
        contractPreviewCapability, deviceIdentityCapability, messageEnvelopeCapability,
    ]
}

extension Data {
    /// Base64 standard sans padding `=` — format d'encodage Android/web
    /// (`Base64.getEncoder().withoutPadding()`).
    func base64EncodedNoPadding() -> String {
        base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Base64URL sans padding — format des champs JWK (RFC 7517).
    func base64URLEncodedNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct E2EEV2DeviceDescriptor: Codable, Equatable, Sendable {
    let deviceId: String
    let platform: String
    let label: String?
    let publicIdentityKeyB64: String
    let publicSigningKeyB64: String
    let identityKeyAlgorithm: String
    let signingKeyAlgorithm: String
    let keyVersion: Int
}

enum E2EEV2SignedRequestError: Error, Equatable {
    case invalidMethod
    case invalidPath
    case invalidTimestamp
    case invalidNonce
    case invalidBodyHash
    case randomGenerationFailed
}

struct E2EEV2SignedHeaders: Equatable, Sendable {
    let deviceId: String
    let timestampMs: Int64
    let nonce: String
    let signatureB64: String

    var values: [String: String] {
        [
            E2EEV2SignedRequest.headerDeviceId: deviceId,
            E2EEV2SignedRequest.headerTimestampMs: String(timestampMs),
            E2EEV2SignedRequest.headerNonce: nonce,
            E2EEV2SignedRequest.headerSignature: signatureB64,
        ]
    }
}

/// Byte-for-byte request proof shared with Android and the API.
enum E2EEV2SignedRequest {
    static let prefix = "SQ-E2EE-V2"
    static let headerDeviceId = "x-sq-e2ee-device-id"
    static let headerTimestampMs = "x-sq-e2ee-timestamp-ms"
    static let headerNonce = "x-sq-e2ee-nonce"
    static let headerSignature = "x-sq-e2ee-signature"

    static func bodySHA256Base64URL(_ body: Data) -> String {
        Data(SHA256.hash(data: body)).base64URLEncodedNoPadding()
    }

    static func canonicalRequest(
        method: String,
        path: String,
        timestampMs: Int64,
        nonce: String,
        body: Data
    ) throws -> Data {
        try canonicalRequest(
            method: method,
            path: path,
            timestampMs: timestampMs,
            nonce: nonce,
            bodySHA256Base64URL: bodySHA256Base64URL(body)
        )
    }

    /// Variante streaming : le corps reste sur disque et seule son empreinte
    /// SHA-256 est intégrée à la preuve signée.
    static func canonicalRequest(
        method: String,
        path: String,
        timestampMs: Int64,
        nonce: String,
        bodySHA256Base64URL: String
    ) throws -> Data {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedMethod.range(of: #"^[A-Z]{3,16}$"#, options: .regularExpression) != nil else {
            throw E2EEV2SignedRequestError.invalidMethod
        }
        guard !path.isEmpty,
              path.utf8.count <= 512,
              path.hasPrefix("/"),
              path.filter({ $0 == "?" }).count <= 1,
              !path.contains("#"),
              !path.contains("\n"),
              !path.contains("\r") else {
            throw E2EEV2SignedRequestError.invalidPath
        }
        guard timestampMs >= 0 else { throw E2EEV2SignedRequestError.invalidTimestamp }
        guard nonce.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil else {
            throw E2EEV2SignedRequestError.invalidNonce
        }
        guard bodySHA256Base64URL.range(
            of: #"^[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil else {
            throw E2EEV2SignedRequestError.invalidBodyHash
        }
        let canonical = [
            prefix,
            normalizedMethod,
            path,
            String(timestampMs),
            nonce,
            bodySHA256Base64URL,
        ].joined(separator: "\n")
        return Data(canonical.utf8)
    }

    static func newNonce() throws -> String {
        var bytes = Data(count: 24)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw E2EEV2SignedRequestError.randomGenerationFailed
        }
        return bytes.base64URLEncodedNoPadding()
    }

}


struct E2EEV2EpochContext: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let senderDeviceId: String
    let recipientDeviceId: String
}

struct E2EEV2EpochEnvelope: Equatable, Sendable {
    let recipientDeviceId: String
    let wrapAlgorithm: String
    let ephemeralPublicKeyB64: String
    let wrappedEpochKeyB64: String
    let nonceB64: String
    let aadB64: String
}

enum E2EEV2EpochCryptoError: Error, Equatable {
    case invalidContext
    case invalidEpochKey
    case invalidNonce
    case invalidEnvelope
    case commitmentMismatch
}

/// Preview-only per-device epoch wrapping primitive. Envelopes are independently
/// authenticated by AES-GCM and then signed by the sender device for storage.
enum E2EEV2EpochCrypto {
    static let wrapAlgorithm = "P256_X963_ECDH_HKDF_SHA256_AES_256_GCM"
    static let kdfInfo = "signalquest-e2ee-v2-epoch-wrap-v1"

    static func keyCommitment(_ epochKey: Data) throws -> String {
        guard epochKey.count == 32 else { throw E2EEV2EpochCryptoError.invalidEpochKey }
        var input = Data("SQ-E2EE-V2-EPOCH-COMMITMENT".utf8)
        input.append(0)
        input.append(epochKey)
        return Data(SHA256.hash(data: input)).base64EncodedString()
    }

    static func saltCanonical(_ context: E2EEV2EpochContext) throws -> Data {
        try validate(context)
        return Data([
            "SQ-E2EE-V2-EPOCH-SALT",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientDeviceId,
        ].joined(separator: "\n").utf8)
    }

    static func salt(_ context: E2EEV2EpochContext) throws -> Data {
        Data(SHA256.hash(data: try saltCanonical(context)))
    }

    static func deriveWrappingKey(
        sharedSecret: SharedSecret,
        context: E2EEV2EpochContext
    ) throws -> Data {
        let inputKeyMaterial = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: try salt(context),
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func aad(
        context: E2EEV2EpochContext,
        keyCommitmentB64: String,
        ephemeralPublicKeyB64: String
    ) throws -> Data {
        try validate(context)
        guard Data(base64Encoded: keyCommitmentB64)?.count == 32,
              Data(base64Encoded: ephemeralPublicKeyB64)?.count == 65 else {
            throw E2EEV2EpochCryptoError.invalidEnvelope
        }
        return Data([
            "SQ-E2EE-V2-EPOCH-ENVELOPE",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientDeviceId,
            keyCommitmentB64,
            ephemeralPublicKeyB64,
        ].joined(separator: "\n").utf8)
    }

    static func signatureCanonical(
        context: E2EEV2EpochContext,
        keyCommitmentB64: String,
        envelope: E2EEV2EpochEnvelope
    ) throws -> Data {
        try validate(context)
        guard envelope.recipientDeviceId == context.recipientDeviceId else {
            throw E2EEV2EpochCryptoError.invalidEnvelope
        }
        return Data([
            "SQ-E2EE-V2-EPOCH-ENVELOPE-SIGNATURE",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientDeviceId,
            envelope.wrapAlgorithm,
            keyCommitmentB64,
            envelope.ephemeralPublicKeyB64,
            envelope.nonceB64,
            envelope.aadB64,
            envelope.wrappedEpochKeyB64,
        ].joined(separator: "\n").utf8)
    }

    static func wrap(
        epochKey: Data,
        recipientPublicKey: P256.KeyAgreement.PublicKey,
        ephemeralPrivateKey: P256.KeyAgreement.PrivateKey,
        nonce: Data,
        context: E2EEV2EpochContext
    ) throws -> E2EEV2EpochEnvelope {
        guard epochKey.count == 32 else { throw E2EEV2EpochCryptoError.invalidEpochKey }
        guard nonce.count == 12 else { throw E2EEV2EpochCryptoError.invalidNonce }
        let ephemeralB64 = ephemeralPrivateKey.publicKey.x963Representation.base64EncodedString()
        let commitment = try keyCommitment(epochKey)
        let envelopeAAD = try aad(
            context: context,
            keyCommitmentB64: commitment,
            ephemeralPublicKeyB64: ephemeralB64
        )
        let secret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let sealed = try AES.GCM.seal(
            epochKey,
            using: SymmetricKey(data: try deriveWrappingKey(sharedSecret: secret, context: context)),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: envelopeAAD
        )
        return E2EEV2EpochEnvelope(
            recipientDeviceId: context.recipientDeviceId,
            wrapAlgorithm: wrapAlgorithm,
            ephemeralPublicKeyB64: ephemeralB64,
            wrappedEpochKeyB64: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            nonceB64: nonce.base64EncodedString(),
            aadB64: envelopeAAD.base64EncodedString()
        )
    }

    static func unwrap(
        envelope: E2EEV2EpochEnvelope,
        keyCommitmentB64: String,
        recipientPrivateKey: P256.KeyAgreement.PrivateKey,
        context: E2EEV2EpochContext
    ) throws -> Data {
        guard envelope.wrapAlgorithm == wrapAlgorithm,
              envelope.recipientDeviceId == context.recipientDeviceId,
              let ephemeralData = Data(base64Encoded: envelope.ephemeralPublicKeyB64),
              let wrapped = Data(base64Encoded: envelope.wrappedEpochKeyB64),
              wrapped.count == 48,
              let nonce = Data(base64Encoded: envelope.nonceB64),
              nonce.count == 12,
              let suppliedAAD = Data(base64Encoded: envelope.aadB64) else {
            throw E2EEV2EpochCryptoError.invalidEnvelope
        }
        let expectedAAD = try aad(
            context: context,
            keyCommitmentB64: keyCommitmentB64,
            ephemeralPublicKeyB64: envelope.ephemeralPublicKeyB64
        )
        guard suppliedAAD == expectedAAD else { throw E2EEV2EpochCryptoError.invalidEnvelope }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        let secret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: wrapped.prefix(32),
            tag: wrapped.suffix(16)
        )
        let clear = try AES.GCM.open(
            box,
            using: SymmetricKey(data: try deriveWrappingKey(sharedSecret: secret, context: context)),
            authenticating: suppliedAAD
        )
        guard try keyCommitment(clear) == keyCommitmentB64 else {
            throw E2EEV2EpochCryptoError.commitmentMismatch
        }
        return clear
    }

    private static func validate(_ context: E2EEV2EpochContext) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
        guard context.conversationId.range(of: pattern, options: .regularExpression) != nil,
              context.senderDeviceId.range(of: pattern, options: .regularExpression) != nil,
              context.recipientDeviceId.range(of: pattern, options: .regularExpression) != nil,
              context.epochNumber > 0 else {
            throw E2EEV2EpochCryptoError.invalidContext
        }
    }
}

struct E2EEV2SignedEpochEnvelope: Codable, Equatable, Sendable {
    let recipientDeviceId: String
    let wrapAlgorithm: String
    let ephemeralPublicKeyB64: String
    let wrappedEpochKeyB64: String
    let nonceB64: String
    let aadB64: String
    let signatureB64: String

    var cryptoEnvelope: E2EEV2EpochEnvelope {
        E2EEV2EpochEnvelope(
            recipientDeviceId: recipientDeviceId,
            wrapAlgorithm: wrapAlgorithm,
            ephemeralPublicKeyB64: ephemeralPublicKeyB64,
            wrappedEpochKeyB64: wrappedEpochKeyB64,
            nonceB64: nonceB64,
            aadB64: aadB64
        )
    }
}

struct E2EEV2EpochDelivery: Equatable, Sendable {
    let conversationId: String
    let epochId: String
    let epochNumber: Int
    let keyCommitmentB64: String
    let reason: String
    let status: String
    let createdAt: String
    let senderDeviceId: String
    let senderPublicSigningKeyB64: String
    let envelope: E2EEV2SignedEpochEnvelope

    var epochContext: E2EEV2EpochContext {
        E2EEV2EpochContext(
            conversationId: conversationId,
            epochNumber: epochNumber,
            senderDeviceId: senderDeviceId,
            recipientDeviceId: envelope.recipientDeviceId
        )
    }
}

/// Strict response parser: unknown fields, substitutions and unsigned AAD are
/// rejected before the device private ECDH key is touched.
enum E2EEV2EpochDeliveryContract {
    private struct Response: Decodable {
        struct Epoch: Decodable {
            let epochId: String
            let epochNumber: Int
            let algorithm: String
            let keyCommitmentB64: String
            let reason: String
            let status: String
            let createdAt: String
        }

        struct SenderDevice: Decodable {
            let deviceId: String
            let publicSigningKeyB64: String
        }

        let protocolVersion: Int
        let conversationId: String
        let epoch: Epoch
        let senderDevice: SenderDevice
        let envelope: E2EEV2SignedEpochEnvelope
    }

    private static let opaqueIdPattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
    private static let epochAlgorithm = "AES_256_GCM_HKDF_SHA256"
    private static let reasons: Set<String> = [
        "INITIAL",
        "DEVICE_ADDED",
        "DEVICE_REVOKED",
        "MEMBER_ADDED",
        "MEMBER_REMOVED",
        "RECOVERY",
        "IDENTITY_RESET",
        "MANUAL",
    ]
    private static let statuses: Set<String> = ["active", "retired", "compromised"]

    static func parseAndVerify(
        _ data: Data,
        expectedConversationId: String,
        expectedRecipientDeviceId: String,
        allowedStatuses: Set<String> = ["active"]
    ) -> E2EEV2EpochDelivery? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              !allowedStatuses.isEmpty,
              allowedStatuses.isSubset(of: statuses),
              validOpaqueId(expectedConversationId),
              validOpaqueId(expectedRecipientDeviceId),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["protocolVersion", "conversationId", "epoch", "senderDevice", "envelope"]),
              let epochObject = root["epoch"] as? [String: Any],
              exactKeys(
                epochObject,
                ["epochId", "epochNumber", "algorithm", "keyCommitmentB64", "reason", "status", "createdAt"]
              ),
              let senderObject = root["senderDevice"] as? [String: Any],
              exactKeys(senderObject, ["deviceId", "publicSigningKeyB64"]),
              let envelopeObject = root["envelope"] as? [String: Any],
              exactKeys(
                envelopeObject,
                [
                    "recipientDeviceId",
                    "wrapAlgorithm",
                    "ephemeralPublicKeyB64",
                    "wrappedEpochKeyB64",
                    "nonceB64",
                    "aadB64",
                    "signatureB64",
                ]
              ),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.protocolVersion == 2,
              response.conversationId == expectedConversationId,
              validOpaqueId(response.epoch.epochId),
              response.epoch.epochNumber > 0,
              response.epoch.algorithm == epochAlgorithm,
              Data(base64Encoded: response.epoch.keyCommitmentB64)?.count == 32,
              reasons.contains(response.epoch.reason),
              allowedStatuses.contains(response.epoch.status),
              validISO8601(response.epoch.createdAt),
              validOpaqueId(response.senderDevice.deviceId),
              Data(base64Encoded: response.senderDevice.publicSigningKeyB64)?.count == 65,
              response.envelope.recipientDeviceId == expectedRecipientDeviceId,
              response.envelope.wrapAlgorithm == E2EEV2EpochCrypto.wrapAlgorithm,
              Data(base64Encoded: response.envelope.ephemeralPublicKeyB64)?.count == 65,
              Data(base64Encoded: response.envelope.wrappedEpochKeyB64)?.count == 48,
              Data(base64Encoded: response.envelope.nonceB64)?.count == 12,
              let suppliedAAD = Data(base64Encoded: response.envelope.aadB64),
              let signatureData = Data(base64Encoded: response.envelope.signatureB64),
              let signingPublicData = Data(base64Encoded: response.senderDevice.publicSigningKeyB64)
        else { return nil }

        let delivery = E2EEV2EpochDelivery(
            conversationId: expectedConversationId,
            epochId: response.epoch.epochId,
            epochNumber: response.epoch.epochNumber,
            keyCommitmentB64: response.epoch.keyCommitmentB64,
            reason: response.epoch.reason,
            status: response.epoch.status,
            createdAt: response.epoch.createdAt,
            senderDeviceId: response.senderDevice.deviceId,
            senderPublicSigningKeyB64: response.senderDevice.publicSigningKeyB64,
            envelope: response.envelope
        )
        do {
            let expectedAAD = try E2EEV2EpochCrypto.aad(
                context: delivery.epochContext,
                keyCommitmentB64: delivery.keyCommitmentB64,
                ephemeralPublicKeyB64: delivery.envelope.ephemeralPublicKeyB64
            )
            guard suppliedAAD == expectedAAD else { return nil }
            let signingPublic = try P256.Signing.PublicKey(x963Representation: signingPublicData)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            let canonical = try E2EEV2EpochCrypto.signatureCanonical(
                context: delivery.epochContext,
                keyCommitmentB64: delivery.keyCommitmentB64,
                envelope: delivery.envelope.cryptoEnvelope
            )
            return signingPublic.isValidSignature(signature, for: canonical) ? delivery : nil
        } catch {
            return nil
        }
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    private static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: opaqueIdPattern, options: .regularExpression) != nil
    }

    private static func validISO8601(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value) != nil
    }
}

struct E2EEV2StoredEpochKey: Equatable, Sendable {
    let conversationId: String
    let epochId: String
    let epochNumber: Int
    let keyCommitmentB64: String
    var epochKey: Data
}

struct E2EEV2MessageContext: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let senderDeviceId: String
    let clientRequestId: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
}

struct E2EEV2MessageEnvelope: Equatable, Sendable {
    let envelopeVersion: Int
    let epochNumber: Int
    let clientRequestId: String
    let algorithm: String
    let contentType: String
    let keyCommitmentB64: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    let nonceB64: String
    let aadB64: String
    let ciphertextB64: String
}

enum E2EEV2MessageCryptoError: Error, Equatable {
    case invalidContext
    case invalidEpochKey
    case invalidNonce
    case invalidEnvelope
    case commitmentMismatch
}

/// Generic opaque payload used for every v2 message operation. Message type,
/// reply metadata and attachment names stay inside the encrypted JSON payload.
enum E2EEV2MessageCrypto {
    static let envelopeVersion = 1
    static let algorithm = "AES_256_GCM_HKDF_SHA256"
    static let contentType = "application/vnd.signalquest.e2ee-envelope+json"
    static let kdfInfo = "signalquest-e2ee-v2-message-key-v1"

    static func blobRoutingHash(_ encryptedBlobIds: [String]) throws -> String {
        let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
        guard encryptedBlobIds.count <= 20,
              Set(encryptedBlobIds).count == encryptedBlobIds.count,
              encryptedBlobIds.allSatisfy({
                  $0.range(of: opaquePattern, options: .regularExpression) != nil
              }) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        let canonical = Data(([
            "SQ-E2EE-V2-MESSAGE-BLOBS",
            "1",
        ] + encryptedBlobIds).joined(separator: "\n").utf8)
        return Data(SHA256.hash(data: canonical))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func saltCanonical(_ context: E2EEV2MessageContext) throws -> Data {
        try validate(context)
        return Data([
            "SQ-E2EE-V2-MESSAGE-SALT",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.clientRequestId,
        ].joined(separator: "\n").utf8)
    }

    static func salt(_ context: E2EEV2MessageContext) throws -> Data {
        Data(SHA256.hash(data: try saltCanonical(context)))
    }

    static func deriveMessageKey(
        epochKey: Data,
        context: E2EEV2MessageContext
    ) throws -> Data {
        guard epochKey.count == 32 else { throw E2EEV2MessageCryptoError.invalidEpochKey }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: epochKey),
            salt: try salt(context),
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func aad(
        context: E2EEV2MessageContext,
        keyCommitmentB64: String
    ) throws -> Data {
        try validate(context)
        guard Data(base64Encoded: keyCommitmentB64)?.count == 32 else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        return Data([
            "SQ-E2EE-V2-MESSAGE-ENVELOPE",
            String(envelopeVersion),
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.clientRequestId,
            algorithm,
            contentType,
            keyCommitmentB64,
            String(context.ttlSeconds),
            try blobRoutingHash(context.encryptedBlobIds),
        ].joined(separator: "\n").utf8)
    }

    static func signatureCanonical(
        context: E2EEV2MessageContext,
        envelope: E2EEV2MessageEnvelope
    ) throws -> Data {
        try validate(context: context, envelope: envelope)
        return Data([
            "SQ-E2EE-V2-MESSAGE-SIGNATURE",
            String(envelopeVersion),
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.clientRequestId,
            algorithm,
            contentType,
            envelope.keyCommitmentB64,
            String(context.ttlSeconds),
            try blobRoutingHash(context.encryptedBlobIds),
            envelope.nonceB64,
            envelope.aadB64,
            envelope.ciphertextB64,
        ].joined(separator: "\n").utf8)
    }

    static func encrypt(
        cleartext: Data,
        epochKey: Data,
        nonce: Data,
        context: E2EEV2MessageContext
    ) throws -> E2EEV2MessageEnvelope {
        guard epochKey.count == 32 else { throw E2EEV2MessageCryptoError.invalidEpochKey }
        guard nonce.count == 12 else { throw E2EEV2MessageCryptoError.invalidNonce }
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let envelopeAAD = try aad(context: context, keyCommitmentB64: commitment)
        var messageKey = try deriveMessageKey(epochKey: epochKey, context: context)
        defer { messageKey.resetBytes(in: 0..<messageKey.count) }
        let sealed = try AES.GCM.seal(
            cleartext,
            using: SymmetricKey(data: messageKey),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: envelopeAAD
        )
        return E2EEV2MessageEnvelope(
            envelopeVersion: envelopeVersion,
            epochNumber: context.epochNumber,
            clientRequestId: context.clientRequestId,
            algorithm: algorithm,
            contentType: contentType,
            keyCommitmentB64: commitment,
            ttlSeconds: context.ttlSeconds,
            encryptedBlobIds: context.encryptedBlobIds,
            nonceB64: nonce.base64EncodedString(),
            aadB64: envelopeAAD.base64EncodedString(),
            ciphertextB64: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
    }

    static func decrypt(
        envelope: E2EEV2MessageEnvelope,
        epochKey: Data,
        context: E2EEV2MessageContext
    ) throws -> Data {
        try validate(context: context, envelope: envelope)
        guard try E2EEV2EpochCrypto.keyCommitment(epochKey) == envelope.keyCommitmentB64 else {
            throw E2EEV2MessageCryptoError.commitmentMismatch
        }
        guard let nonce = Data(base64Encoded: envelope.nonceB64), nonce.count == 12,
              let suppliedAAD = Data(base64Encoded: envelope.aadB64),
              let ciphertext = Data(base64Encoded: envelope.ciphertextB64),
              ciphertext.count >= 16 else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        let expectedAAD = try aad(context: context, keyCommitmentB64: envelope.keyCommitmentB64)
        guard suppliedAAD == expectedAAD else { throw E2EEV2MessageCryptoError.invalidEnvelope }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        var messageKey = try deriveMessageKey(epochKey: epochKey, context: context)
        defer { messageKey.resetBytes(in: 0..<messageKey.count) }
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: messageKey),
            authenticating: suppliedAAD
        )
    }

    private static func validate(
        context: E2EEV2MessageContext,
        envelope: E2EEV2MessageEnvelope
    ) throws {
        try validate(context)
        guard envelope.envelopeVersion == envelopeVersion,
              envelope.epochNumber == context.epochNumber,
              envelope.clientRequestId == context.clientRequestId,
              envelope.algorithm == algorithm,
              envelope.contentType == contentType,
              envelope.ttlSeconds == context.ttlSeconds,
              envelope.encryptedBlobIds == context.encryptedBlobIds else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
    }

    private static func validate(_ context: E2EEV2MessageContext) throws {
        let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
        let requestPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$"#
        guard context.conversationId.range(of: opaquePattern, options: .regularExpression) != nil,
              context.senderDeviceId.range(of: opaquePattern, options: .regularExpression) != nil,
              context.clientRequestId.range(of: requestPattern, options: .regularExpression) != nil,
              context.epochNumber > 0,
              (0...(30 * 24 * 60 * 60)).contains(context.ttlSeconds) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        _ = try blobRoutingHash(context.encryptedBlobIds)
    }
}

enum E2EEV2BlobCryptoError: Error, Equatable {
    case invalidBlobID
    case invalidMediaKey
    case invalidNoncePrefix
    case invalidChunk
}

/// Streaming-compatible encrypted-media record format shared with Android and the API.
/// Clear media metadata is intentionally not represented by this type.
enum E2EEV2BlobCrypto {
    static let algorithm = "AES_256_GCM_CHUNKED_HKDF_SHA256"
    static let kdfInfo = "signalquest-e2ee-v2-blob-key-v1"
    static let cryptoChunkBytes = 256 * 1_024
    static let mediaKeyBytes = 32
    static let noncePrefixBytes = 8
    static let tagBytes = 16
    static let maxPlaintextBytes: Int64 = 512 * 1_024 * 1_024

    static func saltCanonical(blobID: String) throws -> Data {
        try validateBlobID(blobID)
        return Data(["SQ-E2EE-V2-BLOB-SALT", "1", blobID].joined(separator: "\n").utf8)
    }

    static func salt(blobID: String) throws -> Data {
        Data(SHA256.hash(data: try saltCanonical(blobID: blobID)))
    }

    static func deriveBlobKey(mediaKey: Data, blobID: String) throws -> Data {
        guard mediaKey.count == mediaKeyBytes else { throw E2EEV2BlobCryptoError.invalidMediaKey }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: mediaKey),
            salt: try salt(blobID: blobID),
            info: Data(kdfInfo.utf8),
            outputByteCount: mediaKeyBytes
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func chunkNonce(noncePrefix: Data, chunkIndex: UInt32) throws -> Data {
        guard noncePrefix.count == noncePrefixBytes else {
            throw E2EEV2BlobCryptoError.invalidNoncePrefix
        }
        var bigEndianIndex = chunkIndex.bigEndian
        var nonce = noncePrefix
        withUnsafeBytes(of: &bigEndianIndex) { nonce.append(contentsOf: $0) }
        return nonce
    }

    static func chunkAAD(
        blobID: String,
        chunkIndex: UInt32,
        cleartextBytes: Int,
        finalChunk: Bool
    ) throws -> Data {
        try validateBlobID(blobID)
        guard (0...cryptoChunkBytes).contains(cleartextBytes) else {
            throw E2EEV2BlobCryptoError.invalidChunk
        }
        return Data([
            "SQ-E2EE-V2-BLOB-CHUNK",
            "1",
            blobID,
            algorithm,
            String(chunkIndex),
            String(cleartextBytes),
            finalChunk ? "FINAL" : "MORE",
        ].joined(separator: "\n").utf8)
    }

    static func encryptChunk(
        _ cleartext: Data,
        blobID: String,
        mediaKey: Data,
        noncePrefix: Data,
        chunkIndex: UInt32,
        finalChunk: Bool
    ) throws -> Data {
        let aad = try chunkAAD(
            blobID: blobID,
            chunkIndex: chunkIndex,
            cleartextBytes: cleartext.count,
            finalChunk: finalChunk
        )
        let sealed = try AES.GCM.seal(
            cleartext,
            using: SymmetricKey(data: try deriveBlobKey(mediaKey: mediaKey, blobID: blobID)),
            nonce: AES.GCM.Nonce(data: try chunkNonce(noncePrefix: noncePrefix, chunkIndex: chunkIndex)),
            authenticating: aad
        )
        return sealed.ciphertext + sealed.tag
    }

    static func decryptChunk(
        _ ciphertext: Data,
        blobID: String,
        mediaKey: Data,
        noncePrefix: Data,
        chunkIndex: UInt32,
        finalChunk: Bool,
        cleartextBytes: Int
    ) throws -> Data {
        guard ciphertext.count == cleartextBytes + tagBytes else {
            throw E2EEV2BlobCryptoError.invalidChunk
        }
        let aad = try chunkAAD(
            blobID: blobID,
            chunkIndex: chunkIndex,
            cleartextBytes: cleartextBytes,
            finalChunk: finalChunk
        )
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: try chunkNonce(noncePrefix: noncePrefix, chunkIndex: chunkIndex)),
            ciphertext: ciphertext.dropLast(tagBytes),
            tag: ciphertext.suffix(tagBytes)
        )
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: try deriveBlobKey(mediaKey: mediaKey, blobID: blobID)),
            authenticating: aad
        )
    }

    private static func validateBlobID(_ blobID: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
        guard blobID.range(of: pattern, options: .regularExpression) != nil else {
            throw E2EEV2BlobCryptoError.invalidBlobID
        }
    }
}

struct E2EEV2SignedMessageEnvelope: Codable, Equatable, Sendable {
    let envelopeVersion: Int
    let epochNumber: Int
    let clientRequestId: String
    let algorithm: String
    let contentType: String
    let keyCommitmentB64: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    let nonceB64: String
    let aadB64: String
    let ciphertextB64: String
    let senderSignatureB64: String

    init(envelope: E2EEV2MessageEnvelope, senderSignatureB64: String) {
        envelopeVersion = envelope.envelopeVersion
        epochNumber = envelope.epochNumber
        clientRequestId = envelope.clientRequestId
        algorithm = envelope.algorithm
        contentType = envelope.contentType
        keyCommitmentB64 = envelope.keyCommitmentB64
        ttlSeconds = envelope.ttlSeconds
        encryptedBlobIds = envelope.encryptedBlobIds
        nonceB64 = envelope.nonceB64
        aadB64 = envelope.aadB64
        ciphertextB64 = envelope.ciphertextB64
        self.senderSignatureB64 = senderSignatureB64
    }
}

enum E2EEV2ContentContract {
    static let schema = "signalquest.e2ee-content"
    static let version = 1
    static let maxBytes = 256 * 1_024

    private static let maxMediaBytes: Int64 = 512 * 1_024 * 1_024
    private static let blobAlgorithm = "AES_256_GCM_CHUNKED_HKDF_SHA256"
    private static let opaquePattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
    )
    private static let sha256Pattern = try! NSRegularExpression(pattern: #"^[a-f0-9]{64}$"#)
    private static let decimalPattern = try! NSRegularExpression(pattern: #"^(0|[1-9][0-9]{0,11})$"#)
    private static let plmnPattern = try! NSRegularExpression(pattern: #"^[0-9]{5,6}$"#)
    private static let rootKeys: Set<String> = [
        "schema", "version", "kind", "replyToId", "mentions", "body",
    ]
    private static let kinds: Set<String> = [
        "TEXT", "EDIT", "REACTION", "DELETE", "MEDIA", "AUDIO",
        "LOCATION", "LIVE_LOCATION", "CARD", "POLL", "POLL_VOTE", "TASK",
    ]

    static func parse(_ cleartext: Data) -> [String: Any]? {
        guard (2...maxBytes).contains(cleartext.count),
              let root = try? JSONSerialization.jsonObject(with: cleartext) as? [String: Any],
              Set(root.keys) == rootKeys,
              root["schema"] as? String == schema,
              integer(root["version"], min: version, max: version),
              let kind = root["kind"] as? String,
              kinds.contains(kind),
              nullableOpaque(root["replyToId"]),
              let mentions = root["mentions"] as? [Any],
              validOpaqueArray(mentions, max: 100, allowEmpty: true),
              let body = root["body"] as? [String: Any],
              validBody(kind: kind, body: body) else {
            return nil
        }
        return root
    }

    static func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard parse(data) != nil else { throw E2EEV2MessageCryptoError.invalidContext }
        return data
    }

    private static func validBody(kind: String, body: [String: Any]) -> Bool {
        switch kind {
        case "TEXT":
            return exact(body, ["text"]) && boundedString(body["text"], min: 1, max: maxBytes)
        case "EDIT":
            return exact(body, ["targetMessageId", "text"])
                && isOpaque(body["targetMessageId"] as? String)
                && boundedString(body["text"], min: 1, max: maxBytes)
        case "REACTION":
            return exact(body, ["targetMessageId", "emoji", "action"])
                && isOpaque(body["targetMessageId"] as? String)
                && boundedString(body["emoji"], min: 1, max: 32)
                && ["ADD", "REMOVE"].contains(body["action"] as? String ?? "")
        case "DELETE":
            return exact(body, ["targetMessageId"])
                && isOpaque(body["targetMessageId"] as? String)
        case "MEDIA":
            guard exact(body, ["caption", "attachments"]),
                  nullableBoundedString(body["caption"], max: 16 * 1_024),
                  let attachments = body["attachments"] as? [Any],
                  (1...20).contains(attachments.count) else { return false }
            let manifests = attachments.compactMap { $0 as? [String: Any] }
            guard manifests.count == attachments.count,
                  manifests.allSatisfy(validManifest) else { return false }
            return Set(manifests.compactMap { $0["blobId"] as? String }).count == manifests.count
        case "AUDIO":
            guard exact(body, ["caption", "attachment", "durationMs", "transcription"]),
                  nullableBoundedString(body["caption"], max: 16 * 1_024),
                  integer(body["durationMs"], min: 0, max: 24 * 60 * 60 * 1_000),
                  let attachment = body["attachment"] as? [String: Any],
                  validManifest(attachment) else { return false }
            if body["transcription"] is NSNull { return true }
            guard let transcription = body["transcription"] as? [String: Any],
                  exact(transcription, ["status", "language", "text", "confidence"]),
                  let status = transcription["status"] as? String,
                  ["NONE", "PENDING", "COMPLETE", "FAILED"].contains(status),
                  nullableBoundedString(transcription["language"], max: 32),
                  nullableBoundedString(transcription["text"], max: maxBytes),
                  nullableNumber(transcription["confidence"], min: 0, max: 1) else { return false }
            return status != "COMPLETE" || boundedString(transcription["text"], min: 1, max: maxBytes)
        case "LOCATION":
            return exact(body, ["latitude", "longitude", "accuracyMeters", "altitudeMeters", "label"])
                && number(body["latitude"], min: -90, max: 90)
                && number(body["longitude"], min: -180, max: 180)
                && nullableNumber(body["accuracyMeters"], min: 0, max: 100_000)
                && nullableNumber(body["altitudeMeters"], min: -20_000, max: 100_000)
                && nullableBoundedString(body["label"], max: 512)
        case "LIVE_LOCATION":
            let legacyKeys: Set<String> = [
                "sessionId", "sequence", "latitude", "longitude", "accuracyMeters",
                "observedAt", "expiresAt",
            ]
            let worldRadioKeys = legacyKeys.union([
                "altitudeMeters", "speedMetersPerSecond", "headingDegrees", "radio",
            ])
            let worldRadioShape = exact(body, worldRadioKeys)
            guard (exact(body, legacyKeys) || worldRadioShape),
            isOpaque(body["sessionId"] as? String),
            integer(body["sequence"], min: 0, max: Int.max),
            number(body["latitude"], min: -90, max: 90),
            number(body["longitude"], min: -180, max: 180),
            nullableNumber(body["accuracyMeters"], min: 0, max: 100_000),
            (!worldRadioShape || (
                nullableNumber(body["altitudeMeters"], min: -20_000, max: 100_000)
                    && nullableNumber(body["speedMetersPerSecond"], min: 0, max: 10_000)
                    && nullableNumber(body["headingDegrees"], min: 0, max: 360)
                    && (body["radio"] is NSNull || ((body["radio"] as? [String: Any]).map {
                        validLiveShareRadio($0)
                    } ?? false))
            )),
            let observedAt = parseDate(body["observedAt"]),
            let expiresAt = parseDate(body["expiresAt"]) else { return false }
            return expiresAt > observedAt
        case "CARD":
            return exact(body, ["cardType", "cardVersion", "payload"])
                && ["SPEEDTEST", "RADIO", "DRIVE_TEST"].contains(body["cardType"] as? String ?? "")
                && integer(body["cardVersion"], min: 1, max: Int(Int32.max))
                && ((body["payload"] as? [String: Any]).map { validPrivateJSON($0, depth: 0) } ?? false)
        case "POLL":
            guard exact(body, ["question", "options", "multipleChoice", "closesAt"]),
                  boundedString(body["question"], min: 1, max: 2_000),
                  body["multipleChoice"] is Bool,
                  nullableDate(body["closesAt"]),
                  let options = body["options"] as? [Any],
                  (2...20).contains(options.count) else { return false }
            let parsed = options.compactMap { $0 as? [String: Any] }
            guard parsed.count == options.count,
                  parsed.allSatisfy({ option in
                      exact(option, ["id", "label"])
                          && isOpaque(option["id"] as? String)
                          && boundedString(option["label"], min: 1, max: 1_000)
                  }) else { return false }
            return Set(parsed.compactMap { $0["id"] as? String }).count == parsed.count
        case "POLL_VOTE":
            return exact(body, ["targetMessageId", "optionIds"])
                && isOpaque(body["targetMessageId"] as? String)
                && ((body["optionIds"] as? [Any]).map {
                    validOpaqueArray($0, max: 20, allowEmpty: true)
                } ?? false)
        case "TASK":
            return exact(body, ["taskId", "title", "status", "dueAt", "assigneeIds"])
                && isOpaque(body["taskId"] as? String)
                && boundedString(body["title"], min: 1, max: 2_000)
                && boundedString(body["status"], min: 1, max: 40)
                && nullableDate(body["dueAt"])
                && ((body["assigneeIds"] as? [Any]).map {
                    validOpaqueArray($0, max: 100, allowEmpty: true)
                } ?? false)
        default:
            return false
        }
    }

    private static func validManifest(_ value: [String: Any]) -> Bool {
        let keys: Set<String> = [
            "blobId", "algorithm", "mediaKeyB64", "noncePrefixB64", "cryptoChunkSize",
            "plaintextSize", "ciphertextSize", "plaintextSha256", "ciphertextSha256",
            "fileName", "mimeType", "width", "height", "durationMs",
        ]
        guard Set(value.keys) == keys,
              isOpaque(value["blobId"] as? String),
              value["algorithm"] as? String == blobAlgorithm,
              base64(value["mediaKeyB64"], bytes: 32),
              base64(value["noncePrefixB64"], bytes: 8),
              integer(value["cryptoChunkSize"], min: 256 * 1_024, max: 256 * 1_024),
              parseSize(value["plaintextSize"], max: maxMediaBytes) != nil,
              let ciphertextSize = parseSize(value["ciphertextSize"], max: maxMediaBytes + 64 * 1_024),
              ciphertextSize >= 16,
              matches(value["plaintextSha256"] as? String, regex: sha256Pattern),
              matches(value["ciphertextSha256"] as? String, regex: sha256Pattern),
              nullableBoundedString(value["fileName"], max: 512),
              nullableBoundedString(value["mimeType"], max: 255),
              nullableInteger(value["width"], min: 1, max: 100_000),
              nullableInteger(value["height"], min: 1, max: 100_000),
              nullableInteger(value["durationMs"], min: 0, max: 24 * 60 * 60 * 1_000) else {
            return false
        }
        return true
    }

    private static func validLiveShareRadio(_ value: [String: Any]) -> Bool {
        let keys: Set<String> = [
            "connectionType", "technology", "operator", "observedPlmn", "simPlmn",
            "simOperator", "isRoaming", "enb", "gnb", "cellId", "ci", "pci", "band",
            "bandwidth", "earfcn", "arfcn", "rsrp", "rsrq", "snr", "rssi", "tac",
            "is5GNSA", "is5GSA", "batterySaver",
        ]
        return exact(value, keys)
            && nullableBoundedString(value["connectionType"], max: 64)
            && nullableBoundedString(value["technology"], max: 64)
            && nullableBoundedString(value["operator"], max: 256)
            && nullablePLMN(value["observedPlmn"])
            && nullablePLMN(value["simPlmn"])
            && nullableBoundedString(value["simOperator"], max: 256)
            && nullableBoolean(value["isRoaming"])
            && nullableBoundedString(value["enb"], max: 64)
            && nullableBoundedString(value["gnb"], max: 64)
            && nullableBoundedString(value["cellId"], max: 64)
            && nullableBoundedString(value["ci"], max: 64)
            && nullableInteger(value["pci"], min: 0, max: 1_007)
            && nullableInteger(value["band"], min: 1, max: 1_024)
            && nullableInteger(value["bandwidth"], min: 0, max: 1_000_000)
            && nullableInteger(value["earfcn"], min: 0, max: 262_143)
            && nullableInteger(value["arfcn"], min: 0, max: 3_279_165)
            && nullableInteger(value["rsrp"], min: -200, max: 0)
            && nullableInteger(value["rsrq"], min: -100, max: 100)
            && nullableInteger(value["snr"], min: -100, max: 100)
            && nullableInteger(value["rssi"], min: -200, max: 0)
            && nullableBoundedString(value["tac"], max: 64)
            && nullableBoolean(value["is5GNSA"])
            && nullableBoolean(value["is5GSA"])
            && nullableBoolean(value["batterySaver"])
    }

    private static func validPrivateJSON(_ value: Any, depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        if value is NSNull || value is Bool { return true }
        if let string = value as? String { return string.count <= 32 * 1_024 }
        if let number = value as? NSNumber { return !isBoolean(number) && number.doubleValue.isFinite }
        if let array = value as? [Any] {
            return array.count <= 500 && array.allSatisfy { validPrivateJSON($0, depth: depth + 1) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.count <= 200 && dictionary.allSatisfy { key, nested in
                (1...80).contains(key.count)
                    && !["__proto__", "constructor", "prototype"].contains(key)
                    && validPrivateJSON(nested, depth: depth + 1)
            }
        }
        return false
    }

    private static func exact(_ value: [String: Any], _ keys: Set<String>) -> Bool {
        Set(value.keys) == keys
    }

    private static func isOpaque(_ value: String?) -> Bool {
        matches(value, regex: opaquePattern)
    }

    private static func nullableOpaque(_ value: Any?) -> Bool {
        value is NSNull || isOpaque(value as? String)
    }

    private static func matches(_ value: String?, regex: NSRegularExpression) -> Bool {
        guard let value else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func boundedString(_ value: Any?, min: Int, max: Int) -> Bool {
        guard let value = value as? String else { return false }
        return (min...max).contains(value.count)
    }

    private static func nullableBoundedString(_ value: Any?, max: Int) -> Bool {
        value is NSNull || boundedString(value, min: 0, max: max)
    }

    private static func nullablePLMN(_ value: Any?) -> Bool {
        value is NSNull || matches(value as? String, regex: plmnPattern)
    }

    private static func nullableBoolean(_ value: Any?) -> Bool {
        value is NSNull || value is Bool
    }

    private static func isBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?, min: Double, max: Double) -> Bool {
        guard let value = value as? NSNumber, !isBoolean(value), value.doubleValue.isFinite else { return false }
        return value.doubleValue >= min && value.doubleValue <= max
    }

    private static func nullableNumber(_ value: Any?, min: Double, max: Double) -> Bool {
        value is NSNull || number(value, min: min, max: max)
    }

    private static func integer(_ value: Any?, min: Int, max: Int) -> Bool {
        guard let value = value as? NSNumber, !isBoolean(value), value.doubleValue.isFinite else { return false }
        let integer = value.int64Value
        return value.doubleValue == Double(integer) && integer >= Int64(min) && integer <= Int64(max)
    }

    private static func nullableInteger(_ value: Any?, min: Int, max: Int) -> Bool {
        value is NSNull || integer(value, min: min, max: max)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value = value as? String, (20...40).contains(value.count) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func nullableDate(_ value: Any?) -> Bool {
        value is NSNull || parseDate(value) != nil
    }

    private static func validOpaqueArray(_ values: [Any], max: Int, allowEmpty: Bool) -> Bool {
        guard values.count <= max, allowEmpty || !values.isEmpty else { return false }
        let strings = values.compactMap { $0 as? String }
        return strings.count == values.count
            && strings.allSatisfy(isOpaque)
            && Set(strings).count == strings.count
    }

    private static func base64(_ value: Any?, bytes: Int) -> Bool {
        guard var raw = value as? String else { return false }
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw.append(String(repeating: "=", count: (4 - raw.count % 4) % 4))
        return Data(base64Encoded: raw)?.count == bytes
    }

    private static func parseSize(_ value: Any?, max: Int64) -> Int64? {
        guard let raw = value as? String,
              matches(raw, regex: decimalPattern),
              let parsed = Int64(raw),
              parsed >= 0,
              parsed <= max else { return nil }
        return parsed
    }
}

enum E2EEV2RuntimeReadGate {
    static let enabled = false
}

struct E2EEV2IncomingMessageInput: Sendable {
    let ownerScopeId: String
    let conversationId: String
    let senderDeviceId: String
    let senderPublicSigningKeyB64: String
    let envelopeData: Data
}

struct E2EEV2DecryptedMessage {
    let epochNumber: Int
    let clientRequestId: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    let content: [String: Any]
}

enum E2EEV2MessageDecryptionResult {
    case decrypted(E2EEV2DecryptedMessage)
    case blocked(reason: String)
}

/// Récepteur local strict. Aucun réseau ni cache n'est muté ici et le runtime
/// reste fermé jusqu'à la revue externe et la matrice d'interopérabilité.
enum E2EEV2MessageReceiver {
    private static let maxEnvelopeBytes = 512 * 1_024
    private static let maxCiphertextBytes = E2EEV2ContentContract.maxBytes + 16
    private static let envelopeKeys: Set<String> = [
        "envelopeVersion", "epochNumber", "clientRequestId", "algorithm",
        "contentType", "keyCommitmentB64", "ttlSeconds", "encryptedBlobIds",
        "nonceB64", "aadB64", "ciphertextB64", "senderSignatureB64",
    ]
    private static let ownerPattern = #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$"#
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
    private static let requestPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$"#

    static func decryptRuntimeWithEpochLoader(
        input: E2EEV2IncomingMessageInput,
        epochLoader: (Int) throws -> E2EEV2StoredEpochKey?
    ) -> E2EEV2MessageDecryptionResult {
        guard E2EEV2RuntimeReadGate.enabled else {
            return .blocked(reason: "e2ee-v2-security-review-required")
        }
        guard let envelope = parseEnvelope(input.envelopeData) else {
            return .blocked(reason: "invalid-e2ee-v2-envelope")
        }
        do {
            guard let epoch = try epochLoader(envelope.epochNumber) else {
                return .blocked(reason: "e2ee-v2-local-epoch-unavailable")
            }
            return .decrypted(try decryptContractPreview(input: input, epoch: epoch))
        } catch {
            return .blocked(reason: "invalid-e2ee-v2-envelope")
        }
    }

    /// Réservé aux tests de contrat tant que le verrou runtime est fermé.
    static func decryptContractPreview(
        input: E2EEV2IncomingMessageInput,
        epoch: E2EEV2StoredEpochKey
    ) throws -> E2EEV2DecryptedMessage {
        guard matches(input.ownerScopeId, ownerPattern),
              matches(input.conversationId, opaquePattern),
              matches(input.senderDeviceId, opaquePattern),
              let signed = parseEnvelope(input.envelopeData),
              epoch.conversationId == input.conversationId,
              epoch.epochNumber == signed.epochNumber,
              epoch.keyCommitmentB64 == signed.keyCommitmentB64 else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        let envelope = unsigned(signed)
        let context = E2EEV2MessageContext(
            conversationId: input.conversationId,
            epochNumber: signed.epochNumber,
            senderDeviceId: input.senderDeviceId,
            clientRequestId: signed.clientRequestId,
            ttlSeconds: signed.ttlSeconds,
            encryptedBlobIds: signed.encryptedBlobIds
        )
        var canonicalSignature = try E2EEV2MessageCrypto.signatureCanonical(
            context: context,
            envelope: envelope
        )
        var localEpochKey = epoch.epochKey
        var publicSigningKeyData = Data()
        var signatureData = Data()
        var cleartext = Data()
        defer {
            canonicalSignature.resetBytes(in: 0..<canonicalSignature.count)
            localEpochKey.resetBytes(in: 0..<localEpochKey.count)
            publicSigningKeyData.resetBytes(in: 0..<publicSigningKeyData.count)
            signatureData.resetBytes(in: 0..<signatureData.count)
            cleartext.resetBytes(in: 0..<cleartext.count)
        }
        guard let decodedPublicKey = Data(base64Encoded: input.senderPublicSigningKeyB64),
              decodedPublicKey.count == 65,
              let decodedSignature = Data(base64Encoded: signed.senderSignatureB64),
              decodedSignature.count <= 256 else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        publicSigningKeyData = decodedPublicKey
        signatureData = decodedSignature
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicSigningKeyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: canonicalSignature) else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        cleartext = try E2EEV2MessageCrypto.decrypt(
            envelope: envelope,
            epochKey: localEpochKey,
            context: context
        )
        guard let content = E2EEV2ContentContract.parse(cleartext),
              referencedPrivateBlobIds(content) == signed.encryptedBlobIds else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        return .init(
            epochNumber: signed.epochNumber,
            clientRequestId: signed.clientRequestId,
            ttlSeconds: signed.ttlSeconds,
            encryptedBlobIds: signed.encryptedBlobIds,
            content: content
        )
    }

    private static func parseEnvelope(_ data: Data) -> E2EEV2SignedMessageEnvelope? {
        guard data.count >= 2, data.count <= maxEnvelopeBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == envelopeKeys,
              integer(root["envelopeVersion"]) == E2EEV2MessageCrypto.envelopeVersion,
              let epochNumber = integer(root["epochNumber"]), epochNumber > 0,
              let clientRequestId = root["clientRequestId"] as? String,
              matches(clientRequestId, requestPattern),
              root["algorithm"] as? String == E2EEV2MessageCrypto.algorithm,
              root["contentType"] as? String == E2EEV2MessageCrypto.contentType,
              let keyCommitment = root["keyCommitmentB64"] as? String,
              Data(base64Encoded: keyCommitment)?.count == 32,
              let ttlSeconds = integer(root["ttlSeconds"]),
              (0...(30 * 24 * 60 * 60)).contains(ttlSeconds),
              let blobIds = root["encryptedBlobIds"] as? [String],
              blobIds.count <= 20,
              Set(blobIds).count == blobIds.count,
              blobIds.allSatisfy({ matches($0, opaquePattern) }),
              let nonceB64 = root["nonceB64"] as? String,
              nonceB64.count <= 64,
              Data(base64Encoded: nonceB64)?.count == 12,
              let aadB64 = root["aadB64"] as? String,
              aadB64.count <= 8_192,
              let aad = Data(base64Encoded: aadB64), !aad.isEmpty,
              let ciphertextB64 = root["ciphertextB64"] as? String,
              ciphertextB64.count <= ((maxCiphertextBytes + 2) / 3) * 4 + 4,
              let ciphertext = Data(base64Encoded: ciphertextB64),
              (16...maxCiphertextBytes).contains(ciphertext.count),
              let signatureB64 = root["senderSignatureB64"] as? String,
              signatureB64.count <= 256,
              let signature = Data(base64Encoded: signatureB64), !signature.isEmpty,
              let decoded = try? JSONDecoder().decode(E2EEV2SignedMessageEnvelope.self, from: data),
              decoded.epochNumber == epochNumber,
              decoded.clientRequestId == clientRequestId,
              decoded.ttlSeconds == ttlSeconds,
              decoded.encryptedBlobIds == blobIds else { return nil }
        return decoded
    }

    private static func unsigned(_ signed: E2EEV2SignedMessageEnvelope) -> E2EEV2MessageEnvelope {
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

    private static func referencedPrivateBlobIds(_ content: [String: Any]) -> [String] {
        guard let kind = content["kind"] as? String,
              let body = content["body"] as? [String: Any] else { return [] }
        switch kind {
        case "MEDIA":
            return (body["attachments"] as? [[String: Any]])?
                .compactMap { $0["blobId"] as? String } ?? []
        case "AUDIO":
            guard let attachment = body["attachment"] as? [String: Any],
                  let blobId = attachment["blobId"] as? String else { return [] }
            return [blobId]
        default:
            return []
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct E2EEV2PortableInventoryItem: Equatable, Sendable {
    let envelopeId: String
    let conversationId: String
    let createdAt: String
    let expiresAt: String?
}

struct E2EEV2PortableInventoryPage: Equatable, Sendable {
    let recipientDeviceId: String
    let envelopes: [E2EEV2PortableInventoryItem]
    let hasMore: Bool
    let nextCursor: String?
    let serverTime: String
}

enum E2EEV2PortableInventoryContract {
    static let pageSize = 100
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#

    static func parse(
        _ data: Data,
        expectedRecipientDeviceId: String
    ) -> E2EEV2PortableInventoryPage? {
        guard data.count <= 768 * 1_024,
              validOpaqueId(expectedRecipientDeviceId),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(
                root,
                ["version", "recipientDeviceId", "envelopes", "hasMore", "nextCursor", "serverTime"]
              ),
              integer(root["version"]) == 1,
              root["recipientDeviceId"] as? String == expectedRecipientDeviceId,
              let rawEnvelopes = root["envelopes"] as? [Any],
              rawEnvelopes.count <= pageSize,
              let hasMore = root["hasMore"] as? Bool,
              let serverTime = root["serverTime"] as? String,
              parseInstant(serverTime) != nil else { return nil }

        let nextCursor: String?
        if root["nextCursor"] is NSNull {
            nextCursor = nil
        } else if let value = root["nextCursor"] as? String, validOpaqueId(value) {
            nextCursor = value
        } else {
            return nil
        }
        guard hasMore == (nextCursor != nil) else { return nil }

        var previousOrderKey: String?
        var seen = Set<String>()
        var envelopes: [E2EEV2PortableInventoryItem] = []
        envelopes.reserveCapacity(rawEnvelopes.count)
        for raw in rawEnvelopes {
            guard let value = raw as? [String: Any],
                  exactKeys(value, ["envelopeId", "conversationId", "createdAt", "expiresAt"]),
                  let envelopeId = value["envelopeId"] as? String,
                  validOpaqueId(envelopeId), seen.insert(envelopeId).inserted,
                  let conversationId = value["conversationId"] as? String,
                  validOpaqueId(conversationId),
                  let createdAt = value["createdAt"] as? String,
                  let createdDate = parseInstant(createdAt) else { return nil }
            let expiresAt: String?
            if value["expiresAt"] is NSNull {
                expiresAt = nil
            } else if let rawExpiry = value["expiresAt"] as? String,
                      let expiry = parseInstant(rawExpiry), expiry > createdDate {
                expiresAt = rawExpiry
            } else {
                return nil
            }
            let orderKey = "\(createdAt)\n\(envelopeId)"
            guard previousOrderKey == nil || orderKey > previousOrderKey! else { return nil }
            previousOrderKey = orderKey
            envelopes.append(.init(
                envelopeId: envelopeId,
                conversationId: conversationId,
                createdAt: createdAt,
                expiresAt: expiresAt
            ))
        }
        if hasMore {
            guard let last = envelopes.last, nextCursor == last.envelopeId else { return nil }
        }
        return .init(
            recipientDeviceId: expectedRecipientDeviceId,
            envelopes: envelopes,
            hasMore: hasMore,
            nextCursor: nextCursor,
            serverTime: serverTime
        )
    }

    static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: opaquePattern, options: .regularExpression) != nil
    }

    static func parseInstant(_ value: String) -> Date? {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else {
            return nil
        }
        return parsed
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }
}

struct E2EEV2DeliveredBlob: Equatable, Sendable {
    let blobId: String
    let algorithm: String
    let ciphertextSha256: String
    let ciphertextSize: Int64
    let chunkSize: Int
}

struct E2EEV2VerifiedMessageDelivery: Equatable, Sendable {
    let id: String
    let senderId: String
    let incoming: E2EEV2IncomingMessageInput
    let epochDelivery: E2EEV2EpochDelivery
    let encryptedBlobs: [E2EEV2DeliveredBlob]
    let createdAt: String
    let expiresAt: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.senderId == rhs.senderId
            && lhs.incoming.ownerScopeId == rhs.incoming.ownerScopeId
            && lhs.incoming.conversationId == rhs.incoming.conversationId
            && lhs.incoming.senderDeviceId == rhs.incoming.senderDeviceId
            && lhs.incoming.senderPublicSigningKeyB64 == rhs.incoming.senderPublicSigningKeyB64
            && lhs.incoming.envelopeData == rhs.incoming.envelopeData
            && lhs.epochDelivery == rhs.epochDelivery
            && lhs.encryptedBlobs == rhs.encryptedBlobs
            && lhs.createdAt == rhs.createdAt
            && lhs.expiresAt == rhs.expiresAt
    }
}

struct E2EEV2DeliveredMessage: @unchecked Sendable {
    let delivery: E2EEV2VerifiedMessageDelivery
    let message: E2EEV2DecryptedMessage
}

enum E2EEV2MessageDeliveryContract {
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#
    private static let sha256Pattern = #"^[a-f0-9]{64}$"#
    private static let statuses: Set<String> = ["active", "retired", "compromised"]

    static func parseAndVerify(
        _ data: Data,
        ownerScopeId: String,
        expectedEnvelopeId: String,
        expectedConversationId: String,
        expectedRecipientDeviceId: String,
        allowServerBoundedExpiry: Bool = false
    ) -> E2EEV2VerifiedMessageDelivery? {
        guard data.count <= 768 * 1_024,
              ownerScopeId.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$"#,
                options: .regularExpression
              ) != nil,
              validOpaqueId(expectedEnvelopeId),
              validOpaqueId(expectedConversationId),
              validOpaqueId(expectedRecipientDeviceId),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["envelope"]),
              let value = root["envelope"] as? [String: Any],
              exactKeys(value, [
                "id", "conversationId", "senderId", "senderDevice", "epoch", "envelopeVersion",
                "clientRequestId", "algorithm", "contentType", "ttlSeconds", "encryptedBlobIds",
                "nonceB64", "aadB64", "ciphertextB64", "senderSignatureB64", "encryptedBlobs",
                "createdAt", "expiresAt",
              ]),
              value["id"] as? String == expectedEnvelopeId,
              value["conversationId"] as? String == expectedConversationId,
              let senderId = value["senderId"] as? String, validOpaqueId(senderId),
              let sender = value["senderDevice"] as? [String: Any],
              exactKeys(sender, ["deviceId", "publicSigningKeyB64", "signingKeyAlgorithm", "keyVersion"]),
              let senderDeviceId = sender["deviceId"] as? String, validOpaqueId(senderDeviceId),
              let senderPublicKey = sender["publicSigningKeyB64"] as? String,
              decodedBase64(senderPublicKey)?.count == 65,
              sender["signingKeyAlgorithm"] as? String == E2EEV2DeviceAlgorithms.signingKeyAlgorithm,
              integer(sender["keyVersion"]) == 1,
              let epoch = value["epoch"] as? [String: Any],
              exactKeys(epoch, [
                "id", "epochNumber", "algorithm", "keyCommitmentB64", "reason", "status", "createdAt",
                "recipientEnvelope",
              ]),
              let epochId = epoch["id"] as? String, validOpaqueId(epochId),
              let epochNumber = integer(epoch["epochNumber"]), (1...Int(Int32.max)).contains(epochNumber),
              epoch["algorithm"] as? String == "AES_256_GCM_HKDF_SHA256",
              let keyCommitment = epoch["keyCommitmentB64"] as? String,
              decodedBase64(keyCommitment)?.count == 32,
              let reason = epoch["reason"] as? String,
              ["INITIAL", "DEVICE_ADDED", "DEVICE_REVOKED", "MEMBER_ADDED", "MEMBER_REMOVED", "RECOVERY", "IDENTITY_RESET", "MANUAL"].contains(reason),
              let epochStatus = epoch["status"] as? String, statuses.contains(epochStatus),
              let epochCreatedAt = epoch["createdAt"] as? String,
              E2EEV2PortableInventoryContract.parseInstant(epochCreatedAt) != nil,
              let recipient = epoch["recipientEnvelope"] as? [String: Any],
              exactKeys(recipient, [
                "recipientDeviceId", "senderDeviceId", "wrapAlgorithm", "ephemeralPublicKeyB64",
                "wrappedEpochKeyB64", "nonceB64", "aadB64", "signatureB64",
                "senderPublicSigningKeyB64", "senderSigningKeyAlgorithm", "senderKeyVersion",
              ]),
              recipient["recipientDeviceId"] as? String == expectedRecipientDeviceId,
              let epochSenderDeviceId = recipient["senderDeviceId"] as? String,
              validOpaqueId(epochSenderDeviceId),
              let epochSenderPublicKey = recipient["senderPublicSigningKeyB64"] as? String,
              decodedBase64(epochSenderPublicKey)?.count == 65,
              recipient["senderSigningKeyAlgorithm"] as? String == E2EEV2DeviceAlgorithms.signingKeyAlgorithm,
              integer(recipient["senderKeyVersion"]) == 1,
              let wrapAlgorithm = recipient["wrapAlgorithm"] as? String,
              let ephemeralPublicKeyB64 = recipient["ephemeralPublicKeyB64"] as? String,
              let wrappedEpochKeyB64 = recipient["wrappedEpochKeyB64"] as? String,
              let epochNonceB64 = recipient["nonceB64"] as? String,
              let epochAADB64 = recipient["aadB64"] as? String,
              let epochSignatureB64 = recipient["signatureB64"] as? String else { return nil }

        let epochResponse: [String: Any] = [
            "protocolVersion": 2,
            "conversationId": expectedConversationId,
            "epoch": [
                "epochId": epochId,
                "epochNumber": epochNumber,
                "algorithm": "AES_256_GCM_HKDF_SHA256",
                "keyCommitmentB64": keyCommitment,
                "reason": reason,
                "status": epochStatus,
                "createdAt": epochCreatedAt,
            ],
            "senderDevice": [
                "deviceId": epochSenderDeviceId,
                "publicSigningKeyB64": epochSenderPublicKey,
            ],
            "envelope": [
                "recipientDeviceId": expectedRecipientDeviceId,
                "wrapAlgorithm": wrapAlgorithm,
                "ephemeralPublicKeyB64": ephemeralPublicKeyB64,
                "wrappedEpochKeyB64": wrappedEpochKeyB64,
                "nonceB64": epochNonceB64,
                "aadB64": epochAADB64,
                "signatureB64": epochSignatureB64,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(epochResponse),
              let epochData = try? JSONSerialization.data(withJSONObject: epochResponse),
              let epochDelivery = E2EEV2EpochDeliveryContract.parseAndVerify(
                epochData,
                expectedConversationId: expectedConversationId,
                expectedRecipientDeviceId: expectedRecipientDeviceId,
                allowedStatuses: statuses
              ),
              let rawBlobIds = value["encryptedBlobIds"] as? [Any], rawBlobIds.count <= 20 else {
            return nil
        }
        let blobIds = rawBlobIds.compactMap { $0 as? String }
        guard blobIds.count == rawBlobIds.count,
              blobIds.allSatisfy(validOpaqueId),
              Set(blobIds).count == blobIds.count,
              let rawBlobs = value["encryptedBlobs"] as? [Any], rawBlobs.count == blobIds.count else {
            return nil
        }
        var blobs: [E2EEV2DeliveredBlob] = []
        blobs.reserveCapacity(rawBlobs.count)
        for (index, raw) in rawBlobs.enumerated() {
            guard let blob = raw as? [String: Any],
                  exactKeys(blob, ["blobId", "algorithm", "ciphertextSha256", "ciphertextSize", "chunkSize"]),
                  blob["blobId"] as? String == blobIds[index],
                  blob["algorithm"] as? String == E2EEV2BlobCrypto.algorithm,
                  let hash = blob["ciphertextSha256"] as? String,
                  hash.range(of: sha256Pattern, options: .regularExpression) != nil,
                  let rawSize = blob["ciphertextSize"] as? String,
                  rawSize.range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil,
                  let size = Int64(rawSize), (1...E2EEV2BlobCrypto.maxPlaintextBytes + 64 * 1_024).contains(size),
                  let chunkSize = integer(blob["chunkSize"]),
                  (5 * 1_024 * 1_024...8 * 1_024 * 1_024).contains(chunkSize) else { return nil }
            blobs.append(.init(
                blobId: blobIds[index],
                algorithm: E2EEV2BlobCrypto.algorithm,
                ciphertextSha256: hash,
                ciphertextSize: size,
                chunkSize: chunkSize
            ))
        }

        guard let createdAt = value["createdAt"] as? String,
              let createdDate = E2EEV2PortableInventoryContract.parseInstant(createdAt),
              let ttlSeconds = integer(value["ttlSeconds"]),
              (0...(30 * 24 * 60 * 60)).contains(ttlSeconds) else { return nil }
        let expiresAt: String?
        if value["expiresAt"] is NSNull {
            guard ttlSeconds == 0 else { return nil }
            expiresAt = nil
        } else if let rawExpiry = value["expiresAt"] as? String,
                  let expiry = E2EEV2PortableInventoryContract.parseInstant(rawExpiry),
                  ttlSeconds > 0 {
            let lifetime = expiry.timeIntervalSince(createdDate)
            guard lifetime > 0,
                  (allowServerBoundedExpiry
                    ? lifetime <= Double(ttlSeconds) + 0.001
                    : abs(lifetime - Double(ttlSeconds)) < 0.001) else { return nil }
            expiresAt = rawExpiry
        } else {
            return nil
        }

        guard let envelopeVersion = integer(value["envelopeVersion"]),
              let clientRequestId = value["clientRequestId"] as? String,
              let algorithm = value["algorithm"] as? String,
              let contentType = value["contentType"] as? String,
              let nonceB64 = value["nonceB64"] as? String,
              let aadB64 = value["aadB64"] as? String,
              let ciphertextB64 = value["ciphertextB64"] as? String,
              let senderSignatureB64 = value["senderSignatureB64"] as? String else { return nil }
        let unsigned = E2EEV2MessageEnvelope(
            envelopeVersion: envelopeVersion,
            epochNumber: epochNumber,
            clientRequestId: clientRequestId,
            algorithm: algorithm,
            contentType: contentType,
            keyCommitmentB64: keyCommitment,
            ttlSeconds: ttlSeconds,
            encryptedBlobIds: blobIds,
            nonceB64: nonceB64,
            aadB64: aadB64,
            ciphertextB64: ciphertextB64
        )
        let signed = E2EEV2SignedMessageEnvelope(
            envelope: unsigned,
            senderSignatureB64: senderSignatureB64
        )
        guard let envelopeData = try? JSONEncoder().encode(signed) else { return nil }
        return .init(
            id: expectedEnvelopeId,
            senderId: senderId,
            incoming: .init(
                ownerScopeId: ownerScopeId,
                conversationId: expectedConversationId,
                senderDeviceId: senderDeviceId,
                senderPublicSigningKeyB64: senderPublicKey,
                envelopeData: envelopeData
            ),
            epochDelivery: epochDelivery,
            encryptedBlobs: blobs,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    private static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: opaquePattern, options: .regularExpression) != nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func decodedBase64(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        return Data(base64Encoded: normalized)
    }
}
