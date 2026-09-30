import Foundation
import CryptoKit

// Appels chiffrés du jalon A (spec E2EE §10 et annexe D.11) : descripteur signé
// par l'appareil appelant, clé de trame v2 et preuve de jonction.

enum E2EEV2CallFormatError: Error, Equatable {
    case invalidField
    case invalidSignature
    case expired
}

/// §10.1 : descripteur d'appel.
struct E2EEV2CallDescriptor: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-CALL-DESCRIPTOR"
    static let ringingValidityMs: Int64 = 60_000

    let conversationId: String
    let callId: String
    let callerDeviceId: String
    let epochId: String
    let epochNumber: Int
    let keyCommitmentB64: String
    let callNonceB64: String
    let createdAtMs: Int64

    var canonical: String {
        [
            Self.tag, "1", conversationId, callId, callerDeviceId, epochId, String(epochNumber),
            keyCommitmentB64, callNonceB64, String(createdAtMs),
        ].joined(separator: "\n")
    }

    static func parse(_ canonical: String) throws -> E2EEV2CallDescriptor {
        guard let f = E2EEV2Canonical.split(canonical, tag: tag, version: "1", fieldCount: 10),
              E2EEV2Canonical.isOpaque(f[2]), E2EEV2Canonical.isOpaque(f[3]),
              E2EEV2Canonical.isOpaque(f[4]), E2EEV2Canonical.isOpaque(f[5]),
              E2EEV2Canonical.isDecimal(f[6]), let epochNumber = Int(f[6]), epochNumber >= 1,
              Data(base64Encoded: f[7])?.count == 32,
              Data(base64Encoded: f[8])?.count == 32,
              E2EEV2Canonical.isDecimal(f[9]), let createdAt = Int64(f[9]) else {
            throw E2EEV2CallFormatError.invalidField
        }
        return E2EEV2CallDescriptor(
            conversationId: f[2], callId: f[3], callerDeviceId: f[4], epochId: f[5],
            epochNumber: epochNumber, keyCommitmentB64: f[7], callNonceB64: f[8], createdAtMs: createdAt
        )
    }

    /// Vérifie la signature de l'appareil appelant. La règle des 60 secondes ne
    /// vaut que pour une sonnerie ; une jonction tardive dépend de l'appel actif.
    static func verify(
        _ signed: E2EEV2SignedString,
        callerSigningKey: P256.Signing.PublicKey,
        nowMs: Int64,
        ringing: Bool
    ) throws -> E2EEV2CallDescriptor {
        guard signed.verify(with: callerSigningKey) else { throw E2EEV2CallFormatError.invalidSignature }
        let descriptor = try parse(signed.canonical)
        if ringing, nowMs - descriptor.createdAtMs > ringingValidityMs || descriptor.createdAtMs - nowMs > ringingValidityMs {
            throw E2EEV2CallFormatError.expired
        }
        return descriptor
    }

    /// D.11 : clé JSON `e2eeV2` des réponses d'appel.
    static func e2eeV2JSON(_ signed: E2EEV2SignedString, callerDeviceId: String) -> E2EEV2JSON {
        .object([
            "descriptor": .string(signed.canonical),
            "signatureB64": .string(signed.signatureB64),
            "callerDeviceId": .string(callerDeviceId),
        ])
    }
}

/// §10.2 : clé de trame v2, dérivée de la clé d'époque ; aucune clé ne transite.
enum E2EEV2CallFrameKeyV2 {
    static let info = "signalquest-e2ee-v2-call-frame-key-v2"

    static func saltCanonical(conversationId: String, epochNumber: Int, callId: String, callNonceB64: String) -> Data {
        E2EEV2Canonical.line([
            "SQ-E2EE-V2-CALL-FRAME-SALT", "2", conversationId, String(epochNumber), callId, callNonceB64,
        ])
    }

    static func derive(
        epochKey: Data,
        conversationId: String,
        epochNumber: Int,
        callId: String,
        callNonceB64: String
    ) throws -> Data {
        guard epochKey.count == 32, epochNumber >= 1,
              E2EEV2Canonical.isOpaque(conversationId), E2EEV2Canonical.isOpaque(callId),
              Data(base64Encoded: callNonceB64)?.count == 32 else {
            throw E2EEV2CallFormatError.invalidField
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: epochKey),
            salt: Data(SHA256.hash(data: saltCanonical(
                conversationId: conversationId, epochNumber: epochNumber, callId: callId, callNonceB64: callNonceB64
            ))),
            info: Data(info.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    /// Passphrase LiveKit : la chaîne base64 standard de 44 caractères.
    static func livekitPassphrase(_ frameKey: Data) -> String {
        frameKey.base64EncodedString()
    }
}

/// §10.4 : preuve de jonction, envoyée sur le canal de données chiffré.
struct E2EEV2CallJoinProof: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-CALL-JOIN"
    static let topic = "sq.e2ee.join"

    let conversationId: String
    let callId: String
    let callNonceB64: String
    let livekitIdentity: String
    let userId: String
    let deviceId: String
    let joinedAtMs: Int64

    var canonical: String {
        [
            Self.tag, "1", conversationId, callId, callNonceB64, livekitIdentity, userId, deviceId,
            String(joinedAtMs),
        ].joined(separator: "\n")
    }

    /// Identité LiveKit d'un appareil dans un appel chiffré (§10.4) : le « . »
    /// est hors de l'alphabet opaque, la découpe est donc sans ambiguïté.
    static func livekitIdentity(userId: String, deviceId: String) -> String {
        "\(userId).\(deviceId)"
    }

    static func parse(_ canonical: String) throws -> E2EEV2CallJoinProof {
        guard let f = E2EEV2Canonical.split(canonical, tag: tag, version: "1", fieldCount: 9),
              E2EEV2Canonical.isOpaque(f[2]), E2EEV2Canonical.isOpaque(f[3]),
              Data(base64Encoded: f[4])?.count == 32,
              E2EEV2Canonical.isOpaque(f[6]), E2EEV2Canonical.isOpaque(f[7]),
              f[5] == livekitIdentity(userId: f[6], deviceId: f[7]),
              E2EEV2Canonical.isDecimal(f[8]), let joinedAt = Int64(f[8]) else {
            throw E2EEV2CallFormatError.invalidField
        }
        return E2EEV2CallJoinProof(
            conversationId: f[2], callId: f[3], callNonceB64: f[4], livekitIdentity: f[5],
            userId: f[6], deviceId: f[7], joinedAtMs: joinedAt
        )
    }

    /// Contenu du message du canal de données (JSON canonique).
    static func message(_ signed: E2EEV2SignedString) -> Data {
        E2EEV2CanonicalJSON.encode(.object([
            "proof": .string(signed.canonical),
            "signatureB64": .string(signed.signatureB64),
        ]))
    }

    static func readMessage(_ data: Data) throws -> E2EEV2SignedString {
        guard let root = (try? E2EEV2CanonicalJSON.parseCanonical(data))?.objectValue,
              Set(root.keys) == ["proof", "signatureB64"],
              let proof = root["proof"]?.stringValue,
              let signature = root["signatureB64"]?.stringValue else {
            throw E2EEV2CallFormatError.invalidField
        }
        return E2EEV2SignedString(canonical: proof, signatureB64: signature)
    }
}
