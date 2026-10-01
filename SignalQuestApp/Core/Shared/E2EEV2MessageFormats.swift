import Foundation
import CryptoKit

// Messages v2 du jalon A (spec E2EE §4, §11 et annexe D.7 à D.10) : enveloppe v2
// avec bourrage, compteur et franking, charge texte v2, référence de message,
// étiquette serveur et signalement en deux parties.

enum E2EEV2MessageV2Error: Error, Equatable {
    case invalidContext
    case invalidPayload
    case invalidPadding
    case invalidEnvelope
    case frankTagMismatch
    case counterMismatch
    case commitmentMismatch
    case invalidSignature
}

/// §4.2 : référence d'un message, que visent réponses, éditions et suppressions.
enum E2EEV2MessageRef {
    static func make(conversationId: String, senderDeviceId: String, clientRequestId: String) -> String {
        E2EEV2Canonical.sha256B64URL(E2EEV2Canonical.line([
            "SQ-E2EE-V2-MESSAGE-REF", "1", conversationId, senderDeviceId, clientRequestId,
        ]))
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil
    }
}

/// §11 : étiquettes de franking.
enum E2EEV2Franking {
    static func frankTag(
        fk: Data,
        conversationId: String,
        senderDeviceId: String,
        clientRequestId: String,
        payload: Data
    ) -> Data {
        var input = Data(["SQ-E2EE-V2-FRANK", "1", conversationId, senderDeviceId, clientRequestId, ""]
            .joined(separator: "\n").utf8)
        input.append(payload)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: fk)))
    }

    static func serverTag(
        ks: Data,
        frankTagB64: String,
        conversationId: String,
        envelopeId: String,
        senderUserId: String,
        senderDeviceId: String,
        serverTimeMs: Int64,
        keyId: String
    ) -> Data {
        let input = E2EEV2Canonical.line([
            "SQ-E2EE-V2-SERVER-TAG", "1", frankTagB64, conversationId, envelopeId, senderUserId,
            senderDeviceId, String(serverTimeMs), keyId,
        ])
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: ks)))
    }
}

/// D.8 : charge v2 du texte (`TEXT`, `EDIT`, `DELETE`).
struct E2EEV2ContentPayloadV2: Equatable, Sendable {
    static let schema = "signalquest.e2ee-content"
    /// Le clair bourré (`fk`, charge, 0x80) tient en 256 Kio : son enveloppe
    /// reste sous la limite de 512 Kio des requêtes et réponses JSON.
    static let maxBytes = 262_144 - 33
    static let maxTextBytes = 65_536

    enum Body: Equatable, Sendable {
        case text(String)
        case edit(targetRef: String, text: String)
        case delete(targetRef: String)

        var kind: String {
            switch self {
            case .text: return "TEXT"
            case .edit: return "EDIT"
            case .delete: return "DELETE"
            }
        }
    }

    let sentAtMs: Int64
    let counter: Int64
    let replyToRef: String?
    let mentions: [String]
    let body: Body

    var json: E2EEV2JSON {
        let bodyJSON: E2EEV2JSON
        switch body {
        case .text(let text):
            bodyJSON = .object(["text": .string(text)])
        case .edit(let targetRef, let text):
            bodyJSON = .object(["targetRef": .string(targetRef), "text": .string(text)])
        case .delete(let targetRef):
            bodyJSON = .object(["targetRef": .string(targetRef)])
        }
        return .object([
            "schema": .string(Self.schema),
            "version": .string("2"),
            "kind": .string(body.kind),
            "sentAtMs": .string(String(sentAtMs)),
            "counter": .string(String(counter)),
            "replyToRef": replyToRef.map(E2EEV2JSON.string) ?? .null,
            "mentions": .array(mentions.map(E2EEV2JSON.string)),
            "body": bodyJSON,
        ])
    }

    func encoded() throws -> Data {
        let data = E2EEV2CanonicalJSON.encode(json)
        guard data.count <= Self.maxBytes else { throw E2EEV2MessageV2Error.invalidPayload }
        return data
    }

    /// Charge bien formée d'une version ou d'un `kind` inconnus de cette app :
    /// « Contenu non pris en charge » (§5.2), sans rien interpréter.
    static func isUnsupported(_ data: Data) -> Bool {
        guard data.count <= maxBytes, let root = (try? E2EEV2CanonicalJSON.parseCanonical(data))?.objectValue,
              root["schema"]?.stringValue == schema, let version = root["version"]?.stringValue,
              let kind = root["kind"]?.stringValue else { return false }
        return version != "2" || !["TEXT", "EDIT", "DELETE"].contains(kind)
    }

    static func parse(_ data: Data) throws -> E2EEV2ContentPayloadV2 {
        guard data.count <= maxBytes,
              let root = (try? E2EEV2CanonicalJSON.parseCanonical(data))?.objectValue,
              Set(root.keys) == ["schema", "version", "kind", "sentAtMs", "counter", "replyToRef", "mentions", "body"],
              root["schema"]?.stringValue == schema, root["version"]?.stringValue == "2",
              let kind = root["kind"]?.stringValue,
              let sentAt = root["sentAtMs"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger),
              let counterText = root["counter"]?.stringValue, E2EEV2Canonical.isDecimal(counterText),
              let counter = Int64(counterText), (1...Int64(E2EEV2Canonical.maxSequenceNumber)).contains(counter),
              let mentionItems = root["mentions"]?.arrayValue, mentionItems.count <= 100,
              let bodyObject = root["body"]?.objectValue else {
            throw E2EEV2MessageV2Error.invalidPayload
        }
        let mentions = mentionItems.compactMap(\.stringValue)
        guard mentions.count == mentionItems.count, mentions.allSatisfy(E2EEV2Canonical.isOpaque),
              Set(mentions).count == mentions.count else {
            throw E2EEV2MessageV2Error.invalidPayload
        }
        let replyToRef: String?
        switch root["replyToRef"] {
        case .null?: replyToRef = nil
        case .string(let value)? where E2EEV2MessageRef.isValid(value): replyToRef = value
        default: throw E2EEV2MessageV2Error.invalidPayload
        }
        func validText(_ value: E2EEV2JSON?) -> String? {
            guard let text = value?.stringValue, (1...maxTextBytes).contains(text.utf8.count) else { return nil }
            return text
        }
        func validRef(_ value: E2EEV2JSON?) -> String? {
            guard let ref = value?.stringValue, E2EEV2MessageRef.isValid(ref) else { return nil }
            return ref
        }
        let body: Body
        switch kind {
        case "TEXT":
            guard Set(bodyObject.keys) == ["text"], let text = validText(bodyObject["text"]) else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            body = .text(text)
        case "EDIT":
            guard Set(bodyObject.keys) == ["targetRef", "text"],
                  let ref = validRef(bodyObject["targetRef"]), let text = validText(bodyObject["text"]) else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            body = .edit(targetRef: ref, text: text)
        case "DELETE":
            guard Set(bodyObject.keys) == ["targetRef"], let ref = validRef(bodyObject["targetRef"]) else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            body = .delete(targetRef: ref)
        default:
            throw E2EEV2MessageV2Error.invalidPayload
        }
        return E2EEV2ContentPayloadV2(sentAtMs: sentAt, counter: counter, replyToRef: replyToRef, mentions: mentions, body: body)
    }
}

struct E2EEV2MessageContextV2: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let senderDeviceId: String
    let clientRequestId: String
    let counter: Int64
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
}

struct E2EEV2MessageEnvelopeV2: Equatable, Sendable {
    let envelopeVersion: Int
    let epochNumber: Int
    let clientRequestId: String
    let counter: Int64
    let algorithm: String
    let contentType: String
    let keyCommitmentB64: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    let frankTagB64: String
    let nonceB64: String
    let aadB64: String
    let ciphertextB64: String
}

/// D.7 : enveloppe de message v2.
enum E2EEV2MessageCryptoV2 {
    static let envelopeVersion = 2
    static let algorithm = E2EEV2MessageCrypto.algorithm
    static let contentType = E2EEV2MessageCrypto.contentType
    static let kdfInfo = "signalquest-e2ee-v2-message-key-v2"

    /// Longueur bourrée : multiple de 256 jusqu'à 4 Kio, puis puissance de deux.
    static func paddedLength(forUnpadded length: Int) -> Int {
        if length <= 4_096 { return ((length + 255) / 256) * 256 }
        var size = 8_192
        while size < length { size *= 2 }
        return size
    }

    static func pad(fk: Data, payload: Data) -> Data {
        var clear = fk + payload
        clear.append(0x80)
        let target = paddedLength(forUnpadded: clear.count)
        clear.append(Data(repeating: 0, count: target - clear.count))
        return clear
    }

    /// Retire le bourrage : le dernier 0x80 n'est suivi que de 0x00.
    static func unpad(_ clear: Data) throws -> (fk: Data, payload: Data) {
        guard let marker = clear.lastIndex(where: { $0 != 0 }), clear[marker] == 0x80,
              clear.count == paddedLength(forUnpadded: marker - clear.startIndex + 1) else {
            throw E2EEV2MessageV2Error.invalidPadding
        }
        let body = clear[clear.startIndex..<marker]
        guard body.count > 32 else { throw E2EEV2MessageV2Error.invalidPadding }
        return (Data(body.prefix(32)), Data(body.dropFirst(32)))
    }

    static func saltCanonical(_ context: E2EEV2MessageContextV2) -> Data {
        E2EEV2Canonical.line([
            "SQ-E2EE-V2-MESSAGE-SALT", "2", context.conversationId, String(context.epochNumber),
            context.senderDeviceId, context.clientRequestId,
        ])
    }

    static func deriveMessageKey(epochKey: Data, context: E2EEV2MessageContextV2) throws -> Data {
        guard epochKey.count == 32 else { throw E2EEV2MessageV2Error.invalidContext }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: epochKey),
            salt: Data(SHA256.hash(data: saltCanonical(context))),
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    static func aad(context: E2EEV2MessageContextV2, keyCommitmentB64: String, frankTagB64: String) throws -> Data {
        try validate(context)
        return E2EEV2Canonical.line([
            "SQ-E2EE-V2-MESSAGE-ENVELOPE", "2", context.conversationId, String(context.epochNumber),
            context.senderDeviceId, context.clientRequestId, String(context.counter), algorithm, contentType,
            keyCommitmentB64, String(context.ttlSeconds), try E2EEV2MessageCrypto.blobRoutingHash(context.encryptedBlobIds),
            frankTagB64,
        ])
    }

    static func signatureCanonical(context: E2EEV2MessageContextV2, envelope: E2EEV2MessageEnvelopeV2) throws -> Data {
        try validate(context)
        return E2EEV2Canonical.line([
            "SQ-E2EE-V2-MESSAGE-SIGNATURE", "2", context.conversationId, String(context.epochNumber),
            context.senderDeviceId, context.clientRequestId, String(context.counter), algorithm, contentType,
            envelope.keyCommitmentB64, String(context.ttlSeconds),
            try E2EEV2MessageCrypto.blobRoutingHash(context.encryptedBlobIds), envelope.frankTagB64,
            envelope.nonceB64, envelope.aadB64, envelope.ciphertextB64,
        ])
    }

    static func encrypt(
        payload: Data,
        fk: Data,
        epochKey: Data,
        nonce: Data,
        context: E2EEV2MessageContextV2
    ) throws -> E2EEV2MessageEnvelopeV2 {
        guard fk.count == 32, nonce.count == 12, payload.count <= E2EEV2ContentPayloadV2.maxBytes else {
            throw E2EEV2MessageV2Error.invalidContext
        }
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let frankTagB64 = E2EEV2Franking.frankTag(
            fk: fk, conversationId: context.conversationId, senderDeviceId: context.senderDeviceId,
            clientRequestId: context.clientRequestId, payload: payload
        ).base64EncodedString()
        let envelopeAAD = try aad(context: context, keyCommitmentB64: commitment, frankTagB64: frankTagB64)
        var messageKey = try deriveMessageKey(epochKey: epochKey, context: context)
        defer { messageKey.resetBytes(in: 0..<messageKey.count) }
        let sealed = try AES.GCM.seal(
            pad(fk: fk, payload: payload),
            using: SymmetricKey(data: messageKey),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: envelopeAAD
        )
        return E2EEV2MessageEnvelopeV2(
            envelopeVersion: envelopeVersion, epochNumber: context.epochNumber,
            clientRequestId: context.clientRequestId, counter: context.counter, algorithm: algorithm,
            contentType: contentType, keyCommitmentB64: commitment, ttlSeconds: context.ttlSeconds,
            encryptedBlobIds: context.encryptedBlobIds, frankTagB64: frankTagB64,
            nonceB64: nonce.base64EncodedString(), aadB64: envelopeAAD.base64EncodedString(),
            ciphertextB64: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
    }

    /// Réception, dans l'ordre de l'annexe D.7 (la signature est vérifiée avant,
    /// avec le certificat de l'émetteur, par `verifySignature`).
    static func decrypt(
        envelope: E2EEV2MessageEnvelopeV2,
        epochKey: Data,
        context: E2EEV2MessageContextV2
    ) throws -> (fk: Data, payload: E2EEV2ContentPayloadV2, payloadBytes: Data) {
        let (fk, payloadBytes) = try openFranked(envelope: envelope, epochKey: epochKey, context: context)
        let payload = try E2EEV2ContentPayloadV2.parse(payloadBytes)
        guard payload.counter == context.counter else { throw E2EEV2MessageV2Error.counterMismatch }
        return (fk, payload, payloadBytes)
    }

    /// D.7, étapes 2 à 5 : déchiffrement, bourrage, `fk` et `frankTag`. La
    /// charge exacte en sort authentique, avant toute analyse : un `kind`
    /// inconnu se distingue ainsi d'un message altéré.
    static func openFranked(
        envelope: E2EEV2MessageEnvelopeV2,
        epochKey: Data,
        context: E2EEV2MessageContextV2
    ) throws -> (fk: Data, payloadBytes: Data) {
        guard envelope.envelopeVersion == envelopeVersion, envelope.epochNumber == context.epochNumber,
              envelope.clientRequestId == context.clientRequestId, envelope.counter == context.counter,
              envelope.algorithm == algorithm, envelope.contentType == contentType,
              envelope.ttlSeconds == context.ttlSeconds, envelope.encryptedBlobIds == context.encryptedBlobIds else {
            throw E2EEV2MessageV2Error.invalidEnvelope
        }
        guard try E2EEV2EpochCrypto.keyCommitment(epochKey) == envelope.keyCommitmentB64 else {
            throw E2EEV2MessageV2Error.commitmentMismatch
        }
        guard let nonce = Data(base64Encoded: envelope.nonceB64), nonce.count == 12,
              let suppliedAAD = Data(base64Encoded: envelope.aadB64),
              let ciphertext = Data(base64Encoded: envelope.ciphertextB64), ciphertext.count >= 16 else {
            throw E2EEV2MessageV2Error.invalidEnvelope
        }
        let expectedAAD = try aad(context: context, keyCommitmentB64: envelope.keyCommitmentB64, frankTagB64: envelope.frankTagB64)
        guard suppliedAAD == expectedAAD else { throw E2EEV2MessageV2Error.invalidEnvelope }
        var messageKey = try deriveMessageKey(epochKey: epochKey, context: context)
        defer { messageKey.resetBytes(in: 0..<messageKey.count) }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        let clear = try AES.GCM.open(box, using: SymmetricKey(data: messageKey), authenticating: suppliedAAD)
        let (fk, payloadBytes) = try unpad(clear)
        let expectedTag = E2EEV2Franking.frankTag(
            fk: fk, conversationId: context.conversationId, senderDeviceId: context.senderDeviceId,
            clientRequestId: context.clientRequestId, payload: payloadBytes
        ).base64EncodedString()
        guard expectedTag == envelope.frankTagB64 else { throw E2EEV2MessageV2Error.frankTagMismatch }
        return (fk, payloadBytes)
    }

    static func verifySignature(
        context: E2EEV2MessageContextV2,
        envelope: E2EEV2MessageEnvelopeV2,
        signatureDerB64: String,
        senderSigningKey: P256.Signing.PublicKey
    ) throws {
        guard let der = Data(base64Encoded: signatureDerB64),
              E2EEV2LowS.verify(
                derSignature: der,
                message: try signatureCanonical(context: context, envelope: envelope),
                publicKey: senderSigningKey
              ) else {
            throw E2EEV2MessageV2Error.invalidSignature
        }
    }

    static func isClientRequestId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z"#, options: .regularExpression) != nil
    }

    private static func validate(_ context: E2EEV2MessageContextV2) throws {
        guard E2EEV2Canonical.isOpaque(context.conversationId),
              E2EEV2Canonical.isOpaque(context.senderDeviceId),
              isClientRequestId(context.clientRequestId),
              (1...E2EEV2Canonical.maxSequenceNumber).contains(context.epochNumber),
              (1...Int64(E2EEV2Canonical.maxSequenceNumber)).contains(context.counter),
              (0...E2EEV2SignedMessageEnvelopeV2.maxTTLSeconds).contains(context.ttlSeconds) else {
            throw E2EEV2MessageV2Error.invalidContext
        }
    }
}

/// D.7 et E.3 : l'enveloppe v2 telle qu'elle voyage, corps de l'envoi et
/// `envelope` des lectures. Format nouveau (D.0) : clés exactes, analyseur
/// strict, entiers en chaînes décimales. Mêmes noms de champs que la v1, plus
/// `counter` et `frankTagB64`.
struct E2EEV2SignedMessageEnvelopeV2: Equatable, Sendable {
    static let keys: Set<String> = [
        "envelopeVersion", "epochNumber", "clientRequestId", "counter", "algorithm", "contentType",
        "keyCommitmentB64", "ttlSeconds", "encryptedBlobIds", "frankTagB64", "nonceB64", "aadB64",
        "ciphertextB64", "senderSignatureB64",
    ]
    static let maxTTLSeconds = 30 * 24 * 60 * 60
    /// Clair bourré de 256 Kio au plus, plus l'étiquette GCM.
    static let maxCiphertextBytes = 262_144 + 16
    static let maxWireBytes = E2EEV2WireLimits.maxJSONResponseBytes

    let envelope: E2EEV2MessageEnvelopeV2
    let senderSignatureB64: String

    var json: E2EEV2JSON {
        .object([
            "envelopeVersion": .string(String(envelope.envelopeVersion)),
            "epochNumber": .string(String(envelope.epochNumber)),
            "clientRequestId": .string(envelope.clientRequestId),
            "counter": .string(String(envelope.counter)),
            "algorithm": .string(envelope.algorithm),
            "contentType": .string(envelope.contentType),
            "keyCommitmentB64": .string(envelope.keyCommitmentB64),
            "ttlSeconds": .string(String(envelope.ttlSeconds)),
            "encryptedBlobIds": .array(envelope.encryptedBlobIds.map(E2EEV2JSON.string)),
            "frankTagB64": .string(envelope.frankTagB64),
            "nonceB64": .string(envelope.nonceB64),
            "aadB64": .string(envelope.aadB64),
            "ciphertextB64": .string(envelope.ciphertextB64),
            "senderSignatureB64": .string(senderSignatureB64),
        ])
    }

    var encoded: Data { E2EEV2CanonicalJSON.encode(json) }

    /// Contexte dont l'appareil émetteur, connu par ailleurs (signature, liste
    /// d'appareils), n'est jamais lu dans l'enveloppe.
    func context(conversationId: String, senderDeviceId: String) -> E2EEV2MessageContextV2 {
        .init(
            conversationId: conversationId, epochNumber: envelope.epochNumber, senderDeviceId: senderDeviceId,
            clientRequestId: envelope.clientRequestId, counter: envelope.counter, ttlSeconds: envelope.ttlSeconds,
            encryptedBlobIds: envelope.encryptedBlobIds
        )
    }

    /// Corps d'envoi : en JCS, à l'octet (D.7). Imbriquée dans une réponse,
    /// l'enveloppe se relit avec `parse(_: E2EEV2JSON)`, sans exigence de forme.
    static func parse(_ data: Data) -> E2EEV2SignedMessageEnvelopeV2? {
        guard data.count <= maxWireBytes, let value = try? E2EEV2CanonicalJSON.parseCanonical(data) else { return nil }
        return parse(value)
    }

    static func parse(_ value: E2EEV2JSON) -> E2EEV2SignedMessageEnvelopeV2? {
        guard let root = value.objectValue, Set(root.keys) == keys,
              root["envelopeVersion"]?.stringValue == String(E2EEV2MessageCryptoV2.envelopeVersion),
              let epochNumber = root["epochNumber"]?.stringValue.flatMap(E2EEV2Canonical.sequenceNumber),
              let clientRequestId = root["clientRequestId"]?.stringValue,
              E2EEV2MessageCryptoV2.isClientRequestId(clientRequestId),
              let counter = root["counter"]?.stringValue.flatMap(E2EEV2Canonical.sequenceNumber),
              root["algorithm"]?.stringValue == E2EEV2MessageCryptoV2.algorithm,
              root["contentType"]?.stringValue == E2EEV2MessageCryptoV2.contentType,
              let commitment = base64(root["keyCommitmentB64"], 32...32),
              let ttlText = root["ttlSeconds"]?.stringValue, E2EEV2Canonical.isDecimal(ttlText),
              let ttlSeconds = Int(ttlText), (0...maxTTLSeconds).contains(ttlSeconds),
              let blobValues = root["encryptedBlobIds"]?.arrayValue,
              let frankTag = base64(root["frankTagB64"], 32...32),
              let nonce = base64(root["nonceB64"], 12...12),
              let aad = base64(root["aadB64"], 1...2_048),
              let ciphertext = base64(root["ciphertextB64"], 272...maxCiphertextBytes),
              let signature = base64(root["senderSignatureB64"], 8...72) else { return nil }
        let blobIds = blobValues.compactMap(\.stringValue)
        // Le chiffré suit un palier de bourrage (§4.5), plus l'étiquette GCM.
        let clearLength = (Data(base64Encoded: ciphertext)?.count ?? 0) - 16
        guard blobIds.count == blobValues.count, (try? E2EEV2MessageCrypto.blobRoutingHash(blobIds)) != nil,
              clearLength >= 256, E2EEV2MessageCryptoV2.paddedLength(forUnpadded: clearLength) == clearLength else {
            return nil
        }
        return .init(
            envelope: .init(
                envelopeVersion: E2EEV2MessageCryptoV2.envelopeVersion, epochNumber: epochNumber,
                clientRequestId: clientRequestId, counter: Int64(counter), algorithm: E2EEV2MessageCryptoV2.algorithm,
                contentType: E2EEV2MessageCryptoV2.contentType, keyCommitmentB64: commitment, ttlSeconds: ttlSeconds,
                encryptedBlobIds: blobIds, frankTagB64: frankTag, nonceB64: nonce, aadB64: aad, ciphertextB64: ciphertext
            ),
            senderSignatureB64: signature
        )
    }

    /// Base64 standard canonique (D.0) : `Data(base64Encoded:)` accepte des variantes.
    static func base64(_ value: E2EEV2JSON?, _ byteCount: ClosedRange<Int>) -> String? {
        guard let text = value?.stringValue, let data = Data(base64Encoded: text),
              byteCount.contains(data.count), data.base64EncodedString() == text else { return nil }
        return text
    }
}

/// E.3 : accusé d'un envoi, `{envelopeId, clientRequestId, serverTagB64,
/// serverTimeMs, keyId}`. Le même envoi rejoué rend le même accusé.
struct E2EEV2MessageReceiptV2: Codable, Equatable, Sendable {
    let envelopeId: String
    let clientRequestId: String
    let serverTagB64: String
    let serverTimeMs: Int64
    let keyId: String

    static func parse(_ data: Data, clientRequestId: String) -> E2EEV2MessageReceiptV2? {
        guard data.count <= 4_096, let root = (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue,
              Set(root.keys) == ["envelopeId", "clientRequestId", "serverTagB64", "serverTimeMs", "keyId"],
              let envelopeId = root["envelopeId"]?.stringValue, E2EEV2Canonical.isOpaque(envelopeId),
              root["clientRequestId"]?.stringValue == clientRequestId,
              let serverTag = E2EEV2SignedMessageEnvelopeV2.base64(root["serverTagB64"], 32...32),
              let serverTimeMs = root["serverTimeMs"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger),
              let keyId = root["keyId"]?.stringValue, E2EEV2Canonical.isOpaque(keyId) else { return nil }
        return .init(
            envelopeId: envelopeId, clientRequestId: clientRequestId, serverTagB64: serverTag,
            serverTimeMs: serverTimeMs, keyId: keyId
        )
    }
}

/// E.3 : un message v2 tel que le serveur le remet, dans la liste d'une
/// conversation comme à la lecture d'une enveloppe (`{"message": …}`).
struct E2EEV2DeliveredMessageV2: Equatable, Sendable {
    static let keys: Set<String> = [
        "envelopeId", "sequence", "senderUserId", "senderDeviceId", "envelope", "serverTagB64", "serverTimeMs", "keyId",
    ]
    static let pageLimit = 100

    let envelopeId: String
    /// Séquence du serveur dans la conversation : ordre de lecture et curseur.
    let sequence: Int64
    let senderUserId: String
    let senderDeviceId: String
    let signed: E2EEV2SignedMessageEnvelopeV2
    let serverTagB64: String
    let serverTimeMs: Int64
    let keyId: String

    static func parse(_ value: E2EEV2JSON) -> E2EEV2DeliveredMessageV2? {
        guard let root = value.objectValue, Set(root.keys) == keys,
              let envelopeId = root["envelopeId"]?.stringValue, E2EEV2Canonical.isOpaque(envelopeId),
              let sequence = root["sequence"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger), sequence >= 1,
              let senderUserId = root["senderUserId"]?.stringValue, E2EEV2Canonical.isOpaque(senderUserId),
              let senderDeviceId = root["senderDeviceId"]?.stringValue, E2EEV2Canonical.isOpaque(senderDeviceId),
              let signed = root["envelope"].flatMap(E2EEV2SignedMessageEnvelopeV2.parse),
              let serverTag = E2EEV2SignedMessageEnvelopeV2.base64(root["serverTagB64"], 32...32),
              let serverTimeMs = root["serverTimeMs"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger),
              let keyId = root["keyId"]?.stringValue, E2EEV2Canonical.isOpaque(keyId) else { return nil }
        return .init(
            envelopeId: envelopeId, sequence: sequence, senderUserId: senderUserId, senderDeviceId: senderDeviceId,
            signed: signed, serverTagB64: serverTag, serverTimeMs: serverTimeMs, keyId: keyId
        )
    }

    /// `GET …/messages?after=&limit=` : `{messages, hasMore}`, séquences croissantes
    /// et toutes après le curseur ; une page tient en 512 Kio.
    static func parsePage(_ data: Data, after: Int64) -> (messages: [E2EEV2DeliveredMessageV2], hasMore: Bool)? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue,
              Set(root.keys) == ["messages", "hasMore"],
              let items = root["messages"]?.arrayValue, items.count <= pageLimit,
              let hasMore = root["hasMore"]?.boolValue else { return nil }
        let messages = items.compactMap(parse)
        guard messages.count == items.count, !(hasMore && messages.isEmpty),
              zip([after] + messages.map(\.sequence), messages.map(\.sequence)).allSatisfy({ $0 < $1 }) else {
            return nil
        }
        return (messages, hasMore)
    }

    /// `GET /api/e2ee/v2/envelopes/{id}/fetch` d'un message v2 :
    /// `{"conversationId": …, "message": …}`. La conversation annoncée n'est
    /// qu'un aiguillage : l'AAD et la signature la lient, et rien ne s'ouvre
    /// sous une autre.
    static func parseFetch(_ data: Data, envelopeId: String) -> (conversationId: String, message: E2EEV2DeliveredMessageV2)? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue,
              Set(root.keys) == ["conversationId", "message"],
              let conversationId = root["conversationId"]?.stringValue, E2EEV2Canonical.isOpaque(conversationId),
              let message = root["message"].flatMap(parse), message.envelopeId == envelopeId else { return nil }
        return (conversationId, message)
    }
}

/// D.10 : signalement en deux parties.
enum E2EEV2Report {
    static let reasons: Set<String> = ["SPAM", "HARASSMENT", "HATE", "VIOLENCE", "SEXUAL", "ILLEGAL", "OTHER"]

    struct ClearItem: Equatable, Sendable {
        let envelopeId: String
        let frankTagB64: String
        let serverTagB64: String
        let blobIds: [String]
    }

    struct SealedItem: Equatable, Sendable {
        let envelopeId: String
        let payload: Data
        let fk: Data
        let mediaKeys: [(blobId: String, mediaKey: Data)]

        static func == (lhs: SealedItem, rhs: SealedItem) -> Bool {
            lhs.envelopeId == rhs.envelopeId && lhs.payload == rhs.payload && lhs.fk == rhs.fk
                && lhs.mediaKeys.map(\.blobId) == rhs.mediaKeys.map(\.blobId)
                && lhs.mediaKeys.map(\.mediaKey) == rhs.mediaKeys.map(\.mediaKey)
        }
    }

    static func clearJSON(reportId: String, conversationId: String, reason: String, items: [ClearItem]) -> String {
        E2EEV2CanonicalJSON.encodeString(.object([
            "schema": .string("signalquest.e2ee-report"),
            "version": .string("1"),
            "reportId": .string(reportId),
            "conversationId": .string(conversationId),
            "reason": .string(reason),
            "items": .array(items.map { item in
                .object([
                    "envelopeId": .string(item.envelopeId),
                    "frankTagB64": .string(item.frankTagB64),
                    "serverTagB64": .string(item.serverTagB64),
                    "blobIds": .array(item.blobIds.map(E2EEV2JSON.string)),
                ])
            }),
        ]))
    }

    static func sealedJSON(items: [SealedItem]) -> Data {
        E2EEV2CanonicalJSON.encode(.object([
            "schema": .string("signalquest.e2ee-report-sealed"),
            "version": .string("1"),
            "items": .array(items.map { item in
                .object([
                    "envelopeId": .string(item.envelopeId),
                    "payloadB64": .string(item.payload.base64EncodedString()),
                    "fkB64": .string(item.fk.base64EncodedString()),
                    "mediaKeys": .array(item.mediaKeys.map { key in
                        .object(["blobId": .string(key.blobId), "mediaKeyB64": .string(key.mediaKey.base64EncodedString())])
                    }),
                ])
            }),
        ]))
    }

    static func info(clearJSON: String) -> Data {
        Data("SQ-E2EE-V2-REPORT\n1\n".utf8) + Data(E2EEV2Canonical.sha256B64URL(Data(clearJSON.utf8)).utf8)
    }

    /// Valide la partie en clair : JSON canonique, clés exactes, 1 à 50 messages.
    static func parseClear(_ clearJSON: String) throws -> (reportId: String, conversationId: String, reason: String, items: [ClearItem]) {
        guard let root = (try? E2EEV2CanonicalJSON.parseCanonical(clearJSON))?.objectValue,
              Set(root.keys) == ["schema", "version", "reportId", "conversationId", "reason", "items"],
              root["schema"]?.stringValue == "signalquest.e2ee-report", root["version"]?.stringValue == "1",
              let reportId = root["reportId"]?.stringValue, E2EEV2Canonical.isOpaque(reportId),
              let conversationId = root["conversationId"]?.stringValue, E2EEV2Canonical.isOpaque(conversationId),
              let reason = root["reason"]?.stringValue, reasons.contains(reason),
              let itemValues = root["items"]?.arrayValue, (1...50).contains(itemValues.count) else {
            throw E2EEV2MessageV2Error.invalidPayload
        }
        let items: [ClearItem] = try itemValues.map { value in
            guard let object = value.objectValue,
                  Set(object.keys) == ["envelopeId", "frankTagB64", "serverTagB64", "blobIds"],
                  let envelopeId = object["envelopeId"]?.stringValue, E2EEV2Canonical.isOpaque(envelopeId),
                  let frank = object["frankTagB64"]?.stringValue, Data(base64Encoded: frank)?.count == 32,
                  let server = object["serverTagB64"]?.stringValue, Data(base64Encoded: server)?.count == 32,
                  let blobValues = object["blobIds"]?.arrayValue else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            let blobIds = blobValues.compactMap(\.stringValue)
            guard blobIds.count == blobValues.count, blobIds.allSatisfy(E2EEV2Canonical.isOpaque) else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            return ClearItem(envelopeId: envelopeId, frankTagB64: frank, serverTagB64: server, blobIds: blobIds)
        }
        return (reportId, conversationId, reason, items)
    }

    static func seal(
        clearJSON: String,
        items: [SealedItem],
        moderationKey: P256.KeyAgreement.PublicKey,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> (enc: Data, sealed: Data) {
        let result = try E2EEV2HPKE.seal(
            recipient: moderationKey,
            info: info(clearJSON: clearJSON),
            aad: Data(),
            plaintext: sealedJSON(items: items),
            aead: .aes256GCM,
            ephemeral: ephemeral
        )
        return (result.enc, result.ciphertext)
    }

    /// Côté outil de modération : ouvre la partie scellée et vérifie qu'elle
    /// suit la partie en clair, message par message. Le `frankTag` se vérifie
    /// ensuite avec `verifyFrankTag`, à partir des métadonnées de l'enveloppe
    /// que l'API joint au signalement (appareil émetteur, `clientRequestId`).
    static func open(
        clearJSON: String,
        enc: Data,
        sealed: Data,
        moderationKey: P256.KeyAgreement.PrivateKey
    ) throws -> [SealedItem] {
        let clear = try parseClear(clearJSON)
        let plaintext = try E2EEV2HPKE.open(
            enc: enc, recipient: moderationKey, info: info(clearJSON: clearJSON), aad: Data(),
            ciphertext: sealed, aead: .aes256GCM
        )
        guard let root = (try? E2EEV2CanonicalJSON.parseCanonical(plaintext))?.objectValue,
              Set(root.keys) == ["schema", "version", "items"],
              root["schema"]?.stringValue == "signalquest.e2ee-report-sealed", root["version"]?.stringValue == "1",
              let itemValues = root["items"]?.arrayValue, itemValues.count == clear.items.count else {
            throw E2EEV2MessageV2Error.invalidPayload
        }
        return try zip(itemValues, clear.items).map { value, clearItem in
            guard let object = value.objectValue,
                  Set(object.keys) == ["envelopeId", "payloadB64", "fkB64", "mediaKeys"],
                  object["envelopeId"]?.stringValue == clearItem.envelopeId,
                  let payload = object["payloadB64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  let fk = object["fkB64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), fk.count == 32,
                  let keyValues = object["mediaKeys"]?.arrayValue else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            let mediaKeys: [(blobId: String, mediaKey: Data)] = try keyValues.map { keyValue in
                guard let keyObject = keyValue.objectValue, Set(keyObject.keys) == ["blobId", "mediaKeyB64"],
                      let blobId = keyObject["blobId"]?.stringValue,
                      let key = keyObject["mediaKeyB64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                      key.count == 32 else {
                    throw E2EEV2MessageV2Error.invalidPayload
                }
                return (blobId, key)
            }
            return SealedItem(envelopeId: clearItem.envelopeId, payload: payload, fk: fk, mediaKeys: mediaKeys)
        }
    }

    static func verifyFrankTag(
        item: SealedItem,
        clearItem: ClearItem,
        conversationId: String,
        senderDeviceId: String,
        clientRequestId: String
    ) -> Bool {
        E2EEV2Franking.frankTag(
            fk: item.fk, conversationId: conversationId, senderDeviceId: senderDeviceId,
            clientRequestId: clientRequestId, payload: item.payload
        ).base64EncodedString() == clearItem.frankTagB64
    }
}
