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

/// D.8 : charge v2 du texte (`TEXT`, `EDIT`, `DELETE`) ; D.16 : réactions (`REACTION`).
struct E2EEV2ContentPayloadV2: Equatable, Sendable {
    static let schema = "signalquest.e2ee-content"
    /// Le clair bourré (`fk`, charge, 0x80) tient en 256 Kio : son enveloppe
    /// reste sous la limite de 512 Kio des requêtes et réponses JSON.
    static let maxBytes = 262_144 - 33
    static let maxTextBytes = 65_536

    enum ReactionAction: String, Equatable, Sendable {
        case add = "ADD"
        case remove = "REMOVE"
    }

    enum Body: Equatable, Sendable {
        case text(String)
        case edit(targetRef: String, text: String)
        case delete(targetRef: String)
        /// D.16 : toujours dans une enveloppe v3 en `annotation`.
        case reaction(targetRef: String, emoji: String, action: ReactionAction)

        var kind: String {
            switch self {
            case .text: return "TEXT"
            case .edit: return "EDIT"
            case .delete: return "DELETE"
            case .reaction: return "REACTION"
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
        case .reaction(let targetRef, let emoji, let action):
            bodyJSON = .object(["targetRef": .string(targetRef), "emoji": .string(emoji), "action": .string(action.rawValue)])
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
        return version != "2" || !["TEXT", "EDIT", "DELETE", "REACTION"].contains(kind)
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
        case "REACTION":
            // Ni réponse ni mention : une réaction n'est pas un message (D.16).
            guard Set(bodyObject.keys) == ["targetRef", "emoji", "action"], replyToRef == nil, mentions.isEmpty,
                  let ref = validRef(bodyObject["targetRef"]),
                  let emoji = bodyObject["emoji"]?.stringValue, E2EEV2EmojiRGI.isValid(emoji),
                  let action = bodyObject["action"]?.stringValue.flatMap(ReactionAction.init(rawValue:)) else {
                throw E2EEV2MessageV2Error.invalidPayload
            }
            body = .reaction(targetRef: ref, emoji: emoji, action: action)
        default:
            throw E2EEV2MessageV2Error.invalidPayload
        }
        return E2EEV2ContentPayloadV2(sentAtMs: sentAt, counter: counter, replyToRef: replyToRef, mentions: mentions, body: body)
    }
}

/// D.16 : ce que l'enveloppe v3 dit au serveur. `message` est affiché ;
/// `annotation` modifie un message existant sans en être un.
enum E2EEV2Delivery: String, Equatable, Sendable {
    case message
    case annotation
}

struct E2EEV2MessageContextV2: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let senderDeviceId: String
    let clientRequestId: String
    let counter: Int64
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    /// 2, ou 3 (D.16) avec `delivery` et `notifyUserId` sous l'AAD et la signature.
    var envelopeVersion = E2EEV2MessageCryptoV2.envelopeVersion
    var delivery = E2EEV2Delivery.message
    /// Seul membre à notifier (un `ADD` de réaction), ou vide.
    var notifyUserId = ""
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
    var delivery = E2EEV2Delivery.message
    var notifyUserId = ""
}

/// D.7 : enveloppe de message v2 ; D.16 : enveloppe v3, la même avec
/// `delivery` et `notifyUserId`.
enum E2EEV2MessageCryptoV2 {
    static let envelopeVersion = 2
    static let annotationEnvelopeVersion = 3
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
            "SQ-E2EE-V2-MESSAGE-ENVELOPE", String(context.envelopeVersion), context.conversationId, String(context.epochNumber),
            context.senderDeviceId, context.clientRequestId, String(context.counter), algorithm, contentType,
            keyCommitmentB64, String(context.ttlSeconds), try E2EEV2MessageCrypto.blobRoutingHash(context.encryptedBlobIds),
            frankTagB64,
        ] + deliveryFields(context))
    }

    static func signatureCanonical(context: E2EEV2MessageContextV2, envelope: E2EEV2MessageEnvelopeV2) throws -> Data {
        try validate(context)
        return E2EEV2Canonical.line([
            "SQ-E2EE-V2-MESSAGE-SIGNATURE", String(context.envelopeVersion), context.conversationId, String(context.epochNumber),
            context.senderDeviceId, context.clientRequestId, String(context.counter), algorithm, contentType,
            envelope.keyCommitmentB64, String(context.ttlSeconds),
            try E2EEV2MessageCrypto.blobRoutingHash(context.encryptedBlobIds), envelope.frankTagB64,
        ] + deliveryFields(context) + [envelope.nonceB64, envelope.aadB64, envelope.ciphertextB64])
    }

    /// D.16 : en v3, après `frankTagB64`.
    private static func deliveryFields(_ context: E2EEV2MessageContextV2) -> [String] {
        context.envelopeVersion == annotationEnvelopeVersion ? [context.delivery.rawValue, context.notifyUserId] : []
    }

    /// D.16, après l'étape 6 : `delivery` doit convenir au `kind` (un texte
    /// caché en annotation est rejeté), et seul un `ADD` de réaction nomme
    /// qui notifier. Une enveloppe v2 est un `message` sans notification.
    static func checkDelivery(context: E2EEV2MessageContextV2, payload: E2EEV2ContentPayloadV2) throws {
        switch payload.body {
        case .text:
            guard context.delivery == .message else { throw E2EEV2MessageV2Error.invalidEnvelope }
        case .reaction:
            guard context.delivery == .annotation else { throw E2EEV2MessageV2Error.invalidEnvelope }
        case .edit, .delete:
            break
        }
        if !context.notifyUserId.isEmpty {
            guard case .reaction(_, _, .add) = payload.body else { throw E2EEV2MessageV2Error.invalidEnvelope }
        }
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
            envelopeVersion: context.envelopeVersion, epochNumber: context.epochNumber,
            clientRequestId: context.clientRequestId, counter: context.counter, algorithm: algorithm,
            contentType: contentType, keyCommitmentB64: commitment, ttlSeconds: context.ttlSeconds,
            encryptedBlobIds: context.encryptedBlobIds, frankTagB64: frankTagB64,
            nonceB64: nonce.base64EncodedString(), aadB64: envelopeAAD.base64EncodedString(),
            ciphertextB64: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            delivery: context.delivery, notifyUserId: context.notifyUserId
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
        try checkDelivery(context: context, payload: payload)
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
        guard envelope.envelopeVersion == context.envelopeVersion, envelope.delivery == context.delivery,
              envelope.notifyUserId == context.notifyUserId, envelope.epochNumber == context.epochNumber,
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
        switch context.envelopeVersion {
        case envelopeVersion:
            guard context.delivery == .message, context.notifyUserId.isEmpty else { throw E2EEV2MessageV2Error.invalidContext }
        case annotationEnvelopeVersion:
            // Notifier n'a de sens que pour une annotation (D.16).
            guard context.notifyUserId.isEmpty
                    || (context.delivery == .annotation && E2EEV2Canonical.isOpaque(context.notifyUserId)) else {
                throw E2EEV2MessageV2Error.invalidContext
            }
        default:
            throw E2EEV2MessageV2Error.invalidContext
        }
    }
}

/// D.7 et E.3 : l'enveloppe v2 telle qu'elle voyage, corps de l'envoi et
/// `envelope` des lectures. Format nouveau (D.0) : clés exactes, analyseur
/// strict, entiers en chaînes décimales. Mêmes noms de champs que la v1, plus
/// `counter` et `frankTagB64` ; en v3 (D.16), plus `delivery` et `notifyUserId`.
struct E2EEV2SignedMessageEnvelopeV2: Equatable, Sendable {
    static let keys: Set<String> = [
        "envelopeVersion", "epochNumber", "clientRequestId", "counter", "algorithm", "contentType",
        "keyCommitmentB64", "ttlSeconds", "encryptedBlobIds", "frankTagB64", "nonceB64", "aadB64",
        "ciphertextB64", "senderSignatureB64",
    ]
    static let keysV3 = keys.union(["delivery", "notifyUserId"])
    static let maxTTLSeconds = 30 * 24 * 60 * 60
    /// Clair bourré de 256 Kio au plus, plus l'étiquette GCM.
    static let maxCiphertextBytes = 262_144 + 16
    static let maxWireBytes = E2EEV2WireLimits.maxJSONResponseBytes

    let envelope: E2EEV2MessageEnvelopeV2
    let senderSignatureB64: String

    var json: E2EEV2JSON {
        var fields: [String: E2EEV2JSON] = [
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
        ]
        if envelope.envelopeVersion == E2EEV2MessageCryptoV2.annotationEnvelopeVersion {
            fields["delivery"] = .string(envelope.delivery.rawValue)
            fields["notifyUserId"] = .string(envelope.notifyUserId)
        }
        return .object(fields)
    }

    var encoded: Data { E2EEV2CanonicalJSON.encode(json) }

    /// Contexte dont l'appareil émetteur, connu par ailleurs (signature, liste
    /// d'appareils), n'est jamais lu dans l'enveloppe.
    func context(conversationId: String, senderDeviceId: String) -> E2EEV2MessageContextV2 {
        .init(
            conversationId: conversationId, epochNumber: envelope.epochNumber, senderDeviceId: senderDeviceId,
            clientRequestId: envelope.clientRequestId, counter: envelope.counter, ttlSeconds: envelope.ttlSeconds,
            encryptedBlobIds: envelope.encryptedBlobIds, envelopeVersion: envelope.envelopeVersion,
            delivery: envelope.delivery, notifyUserId: envelope.notifyUserId
        )
    }

    /// Corps d'envoi : en JCS, à l'octet (D.7). Imbriquée dans une réponse,
    /// l'enveloppe se relit avec `parse(_: E2EEV2JSON)`, sans exigence de forme.
    static func parse(_ data: Data) -> E2EEV2SignedMessageEnvelopeV2? {
        guard data.count <= maxWireBytes, let value = try? E2EEV2CanonicalJSON.parseCanonical(data) else { return nil }
        return parse(value)
    }

    static func parse(_ value: E2EEV2JSON) -> E2EEV2SignedMessageEnvelopeV2? {
        guard let root = value.objectValue else { return nil }
        let envelopeVersion: Int, delivery: E2EEV2Delivery, notifyUserId: String
        switch root["envelopeVersion"]?.stringValue {
        case String(E2EEV2MessageCryptoV2.envelopeVersion)?:
            guard Set(root.keys) == keys else { return nil }
            (envelopeVersion, delivery, notifyUserId) = (E2EEV2MessageCryptoV2.envelopeVersion, .message, "")
        case String(E2EEV2MessageCryptoV2.annotationEnvelopeVersion)?:
            guard Set(root.keys) == keysV3,
                  let parsed = root["delivery"]?.stringValue.flatMap(E2EEV2Delivery.init(rawValue:)),
                  let notify = root["notifyUserId"]?.stringValue,
                  notify.isEmpty || (parsed == .annotation && E2EEV2Canonical.isOpaque(notify)) else { return nil }
            (envelopeVersion, delivery, notifyUserId) = (E2EEV2MessageCryptoV2.annotationEnvelopeVersion, parsed, notify)
        default:
            return nil
        }
        guard let epochNumber = root["epochNumber"]?.stringValue.flatMap(E2EEV2Canonical.sequenceNumber),
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
                envelopeVersion: envelopeVersion, epochNumber: epochNumber,
                clientRequestId: clientRequestId, counter: Int64(counter), algorithm: E2EEV2MessageCryptoV2.algorithm,
                contentType: E2EEV2MessageCryptoV2.contentType, keyCommitmentB64: commitment, ttlSeconds: ttlSeconds,
                encryptedBlobIds: blobIds, frankTagB64: frankTag, nonceB64: nonce, aadB64: aad, ciphertextB64: ciphertext,
                delivery: delivery, notifyUserId: notifyUserId
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
    /// Demande de message (DM-REQ-1) : présente seulement si le serveur répond à un client qui déclare
    /// `message_requests_v1`, pour le premier message d'une demande (`remaining` vaut alors 0).
    var request: E2EEV2MessageRequestBlock? = nil

    static func parse(_ data: Data, clientRequestId: String) -> E2EEV2MessageReceiptV2? {
        let keys: Set<String> = ["envelopeId", "clientRequestId", "serverTagB64", "serverTimeMs", "keyId"]
        // Seule clé de plus admise : `request`, dont `remaining` est un nombre pour le serveur.
        guard data.count <= 4_096,
              let root = (try? E2EEV2CanonicalJSON.parseStrict(data, smallIntegerKeys: E2EEV2MessageRequestBlock.numberKeys))?.objectValue,
              Set(root.keys).subtracting(["request"]) == keys,
              let envelopeId = root["envelopeId"]?.stringValue, E2EEV2Canonical.isOpaque(envelopeId),
              root["clientRequestId"]?.stringValue == clientRequestId,
              let serverTag = E2EEV2SignedMessageEnvelopeV2.base64(root["serverTagB64"], 32...32),
              let serverTimeMs = root["serverTimeMs"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger),
              let keyId = root["keyId"]?.stringValue, E2EEV2Canonical.isOpaque(keyId) else { return nil }
        var request: E2EEV2MessageRequestBlock?
        if let served = root["request"] {
            guard let object = served.objectValue else { return nil }
            request = E2EEV2MessageRequestBlock.parse(object)
        }
        return .init(
            envelopeId: envelopeId, clientRequestId: clientRequestId, serverTagB64: serverTag,
            serverTimeMs: serverTimeMs, keyId: keyId, request: request
        )
    }
}

/// Le bloc `request` d'un reçu v2 (DM-REQ-1, §7) : `{role: "sender", status: "pending", remaining: 0 | 1}`.
/// C'est une information d'affichage, jamais une condition de validité du reçu : une clé `request` dont
/// le contenu n'a pas cette forme se lit comme « rien à dire », alors que le message est bien accepté.
/// Une valeur qui n'est pas un objet reste refusée, comme toute autre clé hors contrat.
struct E2EEV2MessageRequestBlock: Codable, Equatable, Sendable {
    /// 1 : le premier message n'est pas parti ; 0 : « Demande envoyée ».
    let remaining: Int

    /// Clés dont le serveur écrit la valeur en nombre (le reste du JSON v2 n'a aucun nombre).
    static let numberKeys: Set<String> = ["remaining"]

    static func parse(_ object: [String: E2EEV2JSON]) -> E2EEV2MessageRequestBlock? {
        guard Set(object.keys) == ["role", "status", "remaining"],
              object["role"]?.stringValue == "sender", object["status"]?.stringValue == "pending",
              let remaining = object["remaining"]?.stringValue, ["0", "1"].contains(remaining) else { return nil }
        return .init(remaining: remaining == "1" ? 1 : 0)
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

/// D.16 : liste de référence des emojis (`emoji-rgi-15.1`), une séquence par
/// ligne, points de code en hexadécimal majuscule (4 chiffres au moins)
/// séparés par une espace. Tirée des lignes `fully-qualified` de
/// `emoji-test.txt` 15.1 (SHA-256 d876ee24…37ed9) ; un test recalcule son
/// empreinte. À régénérer, jamais à éditer à la main.
enum E2EEV2EmojiRGI {
    static let version = "15.1"
    static let maxBytes = 64
    /// SHA-256 de `list` suivi d'un saut de ligne.
    static let listSHA256 = "4418f1a71f5faa41c350fc6dd4039078a63a1881a4bda11788266a39fb535151"

    static let sequences: Set<String> = Set(list.split(separator: "\n").map(String.init))

    /// Une seule séquence de la liste, en NFC, de 1 à 64 octets UTF-8. Les
    /// points de code sont comparés un à un : l'égalité de `String` confond
    /// les formes canoniquement équivalentes.
    static func isValid(_ emoji: String) -> Bool {
        guard (1...maxBytes).contains(emoji.utf8.count),
              Array(emoji.unicodeScalars) == Array(emoji.precomposedStringWithCanonicalMapping.unicodeScalars) else {
            return false
        }
        return sequences.contains(key(emoji))
    }

    static func key(_ emoji: String) -> String {
        emoji.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    static let list = """
1F600
1F603
1F604
1F601
1F606
1F605
1F923
1F602
1F642
1F643
1FAE0
1F609
1F60A
1F607
1F970
1F60D
1F929
1F618
1F617
263A FE0F
1F61A
1F619
1F972
1F60B
1F61B
1F61C
1F92A
1F61D
1F911
1F917
1F92D
1FAE2
1FAE3
1F92B
1F914
1FAE1
1F910
1F928
1F610
1F611
1F636
1FAE5
1F636 200D 1F32B FE0F
1F60F
1F612
1F644
1F62C
1F62E 200D 1F4A8
1F925
1FAE8
1F642 200D 2194 FE0F
1F642 200D 2195 FE0F
1F60C
1F614
1F62A
1F924
1F634
1F637
1F912
1F915
1F922
1F92E
1F927
1F975
1F976
1F974
1F635
1F635 200D 1F4AB
1F92F
1F920
1F973
1F978
1F60E
1F913
1F9D0
1F615
1FAE4
1F61F
1F641
2639 FE0F
1F62E
1F62F
1F632
1F633
1F97A
1F979
1F626
1F627
1F628
1F630
1F625
1F622
1F62D
1F631
1F616
1F623
1F61E
1F613
1F629
1F62B
1F971
1F624
1F621
1F620
1F92C
1F608
1F47F
1F480
2620 FE0F
1F4A9
1F921
1F479
1F47A
1F47B
1F47D
1F47E
1F916
1F63A
1F638
1F639
1F63B
1F63C
1F63D
1F640
1F63F
1F63E
1F648
1F649
1F64A
1F48C
1F498
1F49D
1F496
1F497
1F493
1F49E
1F495
1F49F
2763 FE0F
1F494
2764 FE0F 200D 1F525
2764 FE0F 200D 1FA79
2764 FE0F
1FA77
1F9E1
1F49B
1F49A
1F499
1FA75
1F49C
1F90E
1F5A4
1FA76
1F90D
1F48B
1F4AF
1F4A2
1F4A5
1F4AB
1F4A6
1F4A8
1F573 FE0F
1F4AC
1F441 FE0F 200D 1F5E8 FE0F
1F5E8 FE0F
1F5EF FE0F
1F4AD
1F4A4
1F44B
1F44B 1F3FB
1F44B 1F3FC
1F44B 1F3FD
1F44B 1F3FE
1F44B 1F3FF
1F91A
1F91A 1F3FB
1F91A 1F3FC
1F91A 1F3FD
1F91A 1F3FE
1F91A 1F3FF
1F590 FE0F
1F590 1F3FB
1F590 1F3FC
1F590 1F3FD
1F590 1F3FE
1F590 1F3FF
270B
270B 1F3FB
270B 1F3FC
270B 1F3FD
270B 1F3FE
270B 1F3FF
1F596
1F596 1F3FB
1F596 1F3FC
1F596 1F3FD
1F596 1F3FE
1F596 1F3FF
1FAF1
1FAF1 1F3FB
1FAF1 1F3FC
1FAF1 1F3FD
1FAF1 1F3FE
1FAF1 1F3FF
1FAF2
1FAF2 1F3FB
1FAF2 1F3FC
1FAF2 1F3FD
1FAF2 1F3FE
1FAF2 1F3FF
1FAF3
1FAF3 1F3FB
1FAF3 1F3FC
1FAF3 1F3FD
1FAF3 1F3FE
1FAF3 1F3FF
1FAF4
1FAF4 1F3FB
1FAF4 1F3FC
1FAF4 1F3FD
1FAF4 1F3FE
1FAF4 1F3FF
1FAF7
1FAF7 1F3FB
1FAF7 1F3FC
1FAF7 1F3FD
1FAF7 1F3FE
1FAF7 1F3FF
1FAF8
1FAF8 1F3FB
1FAF8 1F3FC
1FAF8 1F3FD
1FAF8 1F3FE
1FAF8 1F3FF
1F44C
1F44C 1F3FB
1F44C 1F3FC
1F44C 1F3FD
1F44C 1F3FE
1F44C 1F3FF
1F90C
1F90C 1F3FB
1F90C 1F3FC
1F90C 1F3FD
1F90C 1F3FE
1F90C 1F3FF
1F90F
1F90F 1F3FB
1F90F 1F3FC
1F90F 1F3FD
1F90F 1F3FE
1F90F 1F3FF
270C FE0F
270C 1F3FB
270C 1F3FC
270C 1F3FD
270C 1F3FE
270C 1F3FF
1F91E
1F91E 1F3FB
1F91E 1F3FC
1F91E 1F3FD
1F91E 1F3FE
1F91E 1F3FF
1FAF0
1FAF0 1F3FB
1FAF0 1F3FC
1FAF0 1F3FD
1FAF0 1F3FE
1FAF0 1F3FF
1F91F
1F91F 1F3FB
1F91F 1F3FC
1F91F 1F3FD
1F91F 1F3FE
1F91F 1F3FF
1F918
1F918 1F3FB
1F918 1F3FC
1F918 1F3FD
1F918 1F3FE
1F918 1F3FF
1F919
1F919 1F3FB
1F919 1F3FC
1F919 1F3FD
1F919 1F3FE
1F919 1F3FF
1F448
1F448 1F3FB
1F448 1F3FC
1F448 1F3FD
1F448 1F3FE
1F448 1F3FF
1F449
1F449 1F3FB
1F449 1F3FC
1F449 1F3FD
1F449 1F3FE
1F449 1F3FF
1F446
1F446 1F3FB
1F446 1F3FC
1F446 1F3FD
1F446 1F3FE
1F446 1F3FF
1F595
1F595 1F3FB
1F595 1F3FC
1F595 1F3FD
1F595 1F3FE
1F595 1F3FF
1F447
1F447 1F3FB
1F447 1F3FC
1F447 1F3FD
1F447 1F3FE
1F447 1F3FF
261D FE0F
261D 1F3FB
261D 1F3FC
261D 1F3FD
261D 1F3FE
261D 1F3FF
1FAF5
1FAF5 1F3FB
1FAF5 1F3FC
1FAF5 1F3FD
1FAF5 1F3FE
1FAF5 1F3FF
1F44D
1F44D 1F3FB
1F44D 1F3FC
1F44D 1F3FD
1F44D 1F3FE
1F44D 1F3FF
1F44E
1F44E 1F3FB
1F44E 1F3FC
1F44E 1F3FD
1F44E 1F3FE
1F44E 1F3FF
270A
270A 1F3FB
270A 1F3FC
270A 1F3FD
270A 1F3FE
270A 1F3FF
1F44A
1F44A 1F3FB
1F44A 1F3FC
1F44A 1F3FD
1F44A 1F3FE
1F44A 1F3FF
1F91B
1F91B 1F3FB
1F91B 1F3FC
1F91B 1F3FD
1F91B 1F3FE
1F91B 1F3FF
1F91C
1F91C 1F3FB
1F91C 1F3FC
1F91C 1F3FD
1F91C 1F3FE
1F91C 1F3FF
1F44F
1F44F 1F3FB
1F44F 1F3FC
1F44F 1F3FD
1F44F 1F3FE
1F44F 1F3FF
1F64C
1F64C 1F3FB
1F64C 1F3FC
1F64C 1F3FD
1F64C 1F3FE
1F64C 1F3FF
1FAF6
1FAF6 1F3FB
1FAF6 1F3FC
1FAF6 1F3FD
1FAF6 1F3FE
1FAF6 1F3FF
1F450
1F450 1F3FB
1F450 1F3FC
1F450 1F3FD
1F450 1F3FE
1F450 1F3FF
1F932
1F932 1F3FB
1F932 1F3FC
1F932 1F3FD
1F932 1F3FE
1F932 1F3FF
1F91D
1F91D 1F3FB
1F91D 1F3FC
1F91D 1F3FD
1F91D 1F3FE
1F91D 1F3FF
1FAF1 1F3FB 200D 1FAF2 1F3FC
1FAF1 1F3FB 200D 1FAF2 1F3FD
1FAF1 1F3FB 200D 1FAF2 1F3FE
1FAF1 1F3FB 200D 1FAF2 1F3FF
1FAF1 1F3FC 200D 1FAF2 1F3FB
1FAF1 1F3FC 200D 1FAF2 1F3FD
1FAF1 1F3FC 200D 1FAF2 1F3FE
1FAF1 1F3FC 200D 1FAF2 1F3FF
1FAF1 1F3FD 200D 1FAF2 1F3FB
1FAF1 1F3FD 200D 1FAF2 1F3FC
1FAF1 1F3FD 200D 1FAF2 1F3FE
1FAF1 1F3FD 200D 1FAF2 1F3FF
1FAF1 1F3FE 200D 1FAF2 1F3FB
1FAF1 1F3FE 200D 1FAF2 1F3FC
1FAF1 1F3FE 200D 1FAF2 1F3FD
1FAF1 1F3FE 200D 1FAF2 1F3FF
1FAF1 1F3FF 200D 1FAF2 1F3FB
1FAF1 1F3FF 200D 1FAF2 1F3FC
1FAF1 1F3FF 200D 1FAF2 1F3FD
1FAF1 1F3FF 200D 1FAF2 1F3FE
1F64F
1F64F 1F3FB
1F64F 1F3FC
1F64F 1F3FD
1F64F 1F3FE
1F64F 1F3FF
270D FE0F
270D 1F3FB
270D 1F3FC
270D 1F3FD
270D 1F3FE
270D 1F3FF
1F485
1F485 1F3FB
1F485 1F3FC
1F485 1F3FD
1F485 1F3FE
1F485 1F3FF
1F933
1F933 1F3FB
1F933 1F3FC
1F933 1F3FD
1F933 1F3FE
1F933 1F3FF
1F4AA
1F4AA 1F3FB
1F4AA 1F3FC
1F4AA 1F3FD
1F4AA 1F3FE
1F4AA 1F3FF
1F9BE
1F9BF
1F9B5
1F9B5 1F3FB
1F9B5 1F3FC
1F9B5 1F3FD
1F9B5 1F3FE
1F9B5 1F3FF
1F9B6
1F9B6 1F3FB
1F9B6 1F3FC
1F9B6 1F3FD
1F9B6 1F3FE
1F9B6 1F3FF
1F442
1F442 1F3FB
1F442 1F3FC
1F442 1F3FD
1F442 1F3FE
1F442 1F3FF
1F9BB
1F9BB 1F3FB
1F9BB 1F3FC
1F9BB 1F3FD
1F9BB 1F3FE
1F9BB 1F3FF
1F443
1F443 1F3FB
1F443 1F3FC
1F443 1F3FD
1F443 1F3FE
1F443 1F3FF
1F9E0
1FAC0
1FAC1
1F9B7
1F9B4
1F440
1F441 FE0F
1F445
1F444
1FAE6
1F476
1F476 1F3FB
1F476 1F3FC
1F476 1F3FD
1F476 1F3FE
1F476 1F3FF
1F9D2
1F9D2 1F3FB
1F9D2 1F3FC
1F9D2 1F3FD
1F9D2 1F3FE
1F9D2 1F3FF
1F466
1F466 1F3FB
1F466 1F3FC
1F466 1F3FD
1F466 1F3FE
1F466 1F3FF
1F467
1F467 1F3FB
1F467 1F3FC
1F467 1F3FD
1F467 1F3FE
1F467 1F3FF
1F9D1
1F9D1 1F3FB
1F9D1 1F3FC
1F9D1 1F3FD
1F9D1 1F3FE
1F9D1 1F3FF
1F471
1F471 1F3FB
1F471 1F3FC
1F471 1F3FD
1F471 1F3FE
1F471 1F3FF
1F468
1F468 1F3FB
1F468 1F3FC
1F468 1F3FD
1F468 1F3FE
1F468 1F3FF
1F9D4
1F9D4 1F3FB
1F9D4 1F3FC
1F9D4 1F3FD
1F9D4 1F3FE
1F9D4 1F3FF
1F9D4 200D 2642 FE0F
1F9D4 1F3FB 200D 2642 FE0F
1F9D4 1F3FC 200D 2642 FE0F
1F9D4 1F3FD 200D 2642 FE0F
1F9D4 1F3FE 200D 2642 FE0F
1F9D4 1F3FF 200D 2642 FE0F
1F9D4 200D 2640 FE0F
1F9D4 1F3FB 200D 2640 FE0F
1F9D4 1F3FC 200D 2640 FE0F
1F9D4 1F3FD 200D 2640 FE0F
1F9D4 1F3FE 200D 2640 FE0F
1F9D4 1F3FF 200D 2640 FE0F
1F468 200D 1F9B0
1F468 1F3FB 200D 1F9B0
1F468 1F3FC 200D 1F9B0
1F468 1F3FD 200D 1F9B0
1F468 1F3FE 200D 1F9B0
1F468 1F3FF 200D 1F9B0
1F468 200D 1F9B1
1F468 1F3FB 200D 1F9B1
1F468 1F3FC 200D 1F9B1
1F468 1F3FD 200D 1F9B1
1F468 1F3FE 200D 1F9B1
1F468 1F3FF 200D 1F9B1
1F468 200D 1F9B3
1F468 1F3FB 200D 1F9B3
1F468 1F3FC 200D 1F9B3
1F468 1F3FD 200D 1F9B3
1F468 1F3FE 200D 1F9B3
1F468 1F3FF 200D 1F9B3
1F468 200D 1F9B2
1F468 1F3FB 200D 1F9B2
1F468 1F3FC 200D 1F9B2
1F468 1F3FD 200D 1F9B2
1F468 1F3FE 200D 1F9B2
1F468 1F3FF 200D 1F9B2
1F469
1F469 1F3FB
1F469 1F3FC
1F469 1F3FD
1F469 1F3FE
1F469 1F3FF
1F469 200D 1F9B0
1F469 1F3FB 200D 1F9B0
1F469 1F3FC 200D 1F9B0
1F469 1F3FD 200D 1F9B0
1F469 1F3FE 200D 1F9B0
1F469 1F3FF 200D 1F9B0
1F9D1 200D 1F9B0
1F9D1 1F3FB 200D 1F9B0
1F9D1 1F3FC 200D 1F9B0
1F9D1 1F3FD 200D 1F9B0
1F9D1 1F3FE 200D 1F9B0
1F9D1 1F3FF 200D 1F9B0
1F469 200D 1F9B1
1F469 1F3FB 200D 1F9B1
1F469 1F3FC 200D 1F9B1
1F469 1F3FD 200D 1F9B1
1F469 1F3FE 200D 1F9B1
1F469 1F3FF 200D 1F9B1
1F9D1 200D 1F9B1
1F9D1 1F3FB 200D 1F9B1
1F9D1 1F3FC 200D 1F9B1
1F9D1 1F3FD 200D 1F9B1
1F9D1 1F3FE 200D 1F9B1
1F9D1 1F3FF 200D 1F9B1
1F469 200D 1F9B3
1F469 1F3FB 200D 1F9B3
1F469 1F3FC 200D 1F9B3
1F469 1F3FD 200D 1F9B3
1F469 1F3FE 200D 1F9B3
1F469 1F3FF 200D 1F9B3
1F9D1 200D 1F9B3
1F9D1 1F3FB 200D 1F9B3
1F9D1 1F3FC 200D 1F9B3
1F9D1 1F3FD 200D 1F9B3
1F9D1 1F3FE 200D 1F9B3
1F9D1 1F3FF 200D 1F9B3
1F469 200D 1F9B2
1F469 1F3FB 200D 1F9B2
1F469 1F3FC 200D 1F9B2
1F469 1F3FD 200D 1F9B2
1F469 1F3FE 200D 1F9B2
1F469 1F3FF 200D 1F9B2
1F9D1 200D 1F9B2
1F9D1 1F3FB 200D 1F9B2
1F9D1 1F3FC 200D 1F9B2
1F9D1 1F3FD 200D 1F9B2
1F9D1 1F3FE 200D 1F9B2
1F9D1 1F3FF 200D 1F9B2
1F471 200D 2640 FE0F
1F471 1F3FB 200D 2640 FE0F
1F471 1F3FC 200D 2640 FE0F
1F471 1F3FD 200D 2640 FE0F
1F471 1F3FE 200D 2640 FE0F
1F471 1F3FF 200D 2640 FE0F
1F471 200D 2642 FE0F
1F471 1F3FB 200D 2642 FE0F
1F471 1F3FC 200D 2642 FE0F
1F471 1F3FD 200D 2642 FE0F
1F471 1F3FE 200D 2642 FE0F
1F471 1F3FF 200D 2642 FE0F
1F9D3
1F9D3 1F3FB
1F9D3 1F3FC
1F9D3 1F3FD
1F9D3 1F3FE
1F9D3 1F3FF
1F474
1F474 1F3FB
1F474 1F3FC
1F474 1F3FD
1F474 1F3FE
1F474 1F3FF
1F475
1F475 1F3FB
1F475 1F3FC
1F475 1F3FD
1F475 1F3FE
1F475 1F3FF
1F64D
1F64D 1F3FB
1F64D 1F3FC
1F64D 1F3FD
1F64D 1F3FE
1F64D 1F3FF
1F64D 200D 2642 FE0F
1F64D 1F3FB 200D 2642 FE0F
1F64D 1F3FC 200D 2642 FE0F
1F64D 1F3FD 200D 2642 FE0F
1F64D 1F3FE 200D 2642 FE0F
1F64D 1F3FF 200D 2642 FE0F
1F64D 200D 2640 FE0F
1F64D 1F3FB 200D 2640 FE0F
1F64D 1F3FC 200D 2640 FE0F
1F64D 1F3FD 200D 2640 FE0F
1F64D 1F3FE 200D 2640 FE0F
1F64D 1F3FF 200D 2640 FE0F
1F64E
1F64E 1F3FB
1F64E 1F3FC
1F64E 1F3FD
1F64E 1F3FE
1F64E 1F3FF
1F64E 200D 2642 FE0F
1F64E 1F3FB 200D 2642 FE0F
1F64E 1F3FC 200D 2642 FE0F
1F64E 1F3FD 200D 2642 FE0F
1F64E 1F3FE 200D 2642 FE0F
1F64E 1F3FF 200D 2642 FE0F
1F64E 200D 2640 FE0F
1F64E 1F3FB 200D 2640 FE0F
1F64E 1F3FC 200D 2640 FE0F
1F64E 1F3FD 200D 2640 FE0F
1F64E 1F3FE 200D 2640 FE0F
1F64E 1F3FF 200D 2640 FE0F
1F645
1F645 1F3FB
1F645 1F3FC
1F645 1F3FD
1F645 1F3FE
1F645 1F3FF
1F645 200D 2642 FE0F
1F645 1F3FB 200D 2642 FE0F
1F645 1F3FC 200D 2642 FE0F
1F645 1F3FD 200D 2642 FE0F
1F645 1F3FE 200D 2642 FE0F
1F645 1F3FF 200D 2642 FE0F
1F645 200D 2640 FE0F
1F645 1F3FB 200D 2640 FE0F
1F645 1F3FC 200D 2640 FE0F
1F645 1F3FD 200D 2640 FE0F
1F645 1F3FE 200D 2640 FE0F
1F645 1F3FF 200D 2640 FE0F
1F646
1F646 1F3FB
1F646 1F3FC
1F646 1F3FD
1F646 1F3FE
1F646 1F3FF
1F646 200D 2642 FE0F
1F646 1F3FB 200D 2642 FE0F
1F646 1F3FC 200D 2642 FE0F
1F646 1F3FD 200D 2642 FE0F
1F646 1F3FE 200D 2642 FE0F
1F646 1F3FF 200D 2642 FE0F
1F646 200D 2640 FE0F
1F646 1F3FB 200D 2640 FE0F
1F646 1F3FC 200D 2640 FE0F
1F646 1F3FD 200D 2640 FE0F
1F646 1F3FE 200D 2640 FE0F
1F646 1F3FF 200D 2640 FE0F
1F481
1F481 1F3FB
1F481 1F3FC
1F481 1F3FD
1F481 1F3FE
1F481 1F3FF
1F481 200D 2642 FE0F
1F481 1F3FB 200D 2642 FE0F
1F481 1F3FC 200D 2642 FE0F
1F481 1F3FD 200D 2642 FE0F
1F481 1F3FE 200D 2642 FE0F
1F481 1F3FF 200D 2642 FE0F
1F481 200D 2640 FE0F
1F481 1F3FB 200D 2640 FE0F
1F481 1F3FC 200D 2640 FE0F
1F481 1F3FD 200D 2640 FE0F
1F481 1F3FE 200D 2640 FE0F
1F481 1F3FF 200D 2640 FE0F
1F64B
1F64B 1F3FB
1F64B 1F3FC
1F64B 1F3FD
1F64B 1F3FE
1F64B 1F3FF
1F64B 200D 2642 FE0F
1F64B 1F3FB 200D 2642 FE0F
1F64B 1F3FC 200D 2642 FE0F
1F64B 1F3FD 200D 2642 FE0F
1F64B 1F3FE 200D 2642 FE0F
1F64B 1F3FF 200D 2642 FE0F
1F64B 200D 2640 FE0F
1F64B 1F3FB 200D 2640 FE0F
1F64B 1F3FC 200D 2640 FE0F
1F64B 1F3FD 200D 2640 FE0F
1F64B 1F3FE 200D 2640 FE0F
1F64B 1F3FF 200D 2640 FE0F
1F9CF
1F9CF 1F3FB
1F9CF 1F3FC
1F9CF 1F3FD
1F9CF 1F3FE
1F9CF 1F3FF
1F9CF 200D 2642 FE0F
1F9CF 1F3FB 200D 2642 FE0F
1F9CF 1F3FC 200D 2642 FE0F
1F9CF 1F3FD 200D 2642 FE0F
1F9CF 1F3FE 200D 2642 FE0F
1F9CF 1F3FF 200D 2642 FE0F
1F9CF 200D 2640 FE0F
1F9CF 1F3FB 200D 2640 FE0F
1F9CF 1F3FC 200D 2640 FE0F
1F9CF 1F3FD 200D 2640 FE0F
1F9CF 1F3FE 200D 2640 FE0F
1F9CF 1F3FF 200D 2640 FE0F
1F647
1F647 1F3FB
1F647 1F3FC
1F647 1F3FD
1F647 1F3FE
1F647 1F3FF
1F647 200D 2642 FE0F
1F647 1F3FB 200D 2642 FE0F
1F647 1F3FC 200D 2642 FE0F
1F647 1F3FD 200D 2642 FE0F
1F647 1F3FE 200D 2642 FE0F
1F647 1F3FF 200D 2642 FE0F
1F647 200D 2640 FE0F
1F647 1F3FB 200D 2640 FE0F
1F647 1F3FC 200D 2640 FE0F
1F647 1F3FD 200D 2640 FE0F
1F647 1F3FE 200D 2640 FE0F
1F647 1F3FF 200D 2640 FE0F
1F926
1F926 1F3FB
1F926 1F3FC
1F926 1F3FD
1F926 1F3FE
1F926 1F3FF
1F926 200D 2642 FE0F
1F926 1F3FB 200D 2642 FE0F
1F926 1F3FC 200D 2642 FE0F
1F926 1F3FD 200D 2642 FE0F
1F926 1F3FE 200D 2642 FE0F
1F926 1F3FF 200D 2642 FE0F
1F926 200D 2640 FE0F
1F926 1F3FB 200D 2640 FE0F
1F926 1F3FC 200D 2640 FE0F
1F926 1F3FD 200D 2640 FE0F
1F926 1F3FE 200D 2640 FE0F
1F926 1F3FF 200D 2640 FE0F
1F937
1F937 1F3FB
1F937 1F3FC
1F937 1F3FD
1F937 1F3FE
1F937 1F3FF
1F937 200D 2642 FE0F
1F937 1F3FB 200D 2642 FE0F
1F937 1F3FC 200D 2642 FE0F
1F937 1F3FD 200D 2642 FE0F
1F937 1F3FE 200D 2642 FE0F
1F937 1F3FF 200D 2642 FE0F
1F937 200D 2640 FE0F
1F937 1F3FB 200D 2640 FE0F
1F937 1F3FC 200D 2640 FE0F
1F937 1F3FD 200D 2640 FE0F
1F937 1F3FE 200D 2640 FE0F
1F937 1F3FF 200D 2640 FE0F
1F9D1 200D 2695 FE0F
1F9D1 1F3FB 200D 2695 FE0F
1F9D1 1F3FC 200D 2695 FE0F
1F9D1 1F3FD 200D 2695 FE0F
1F9D1 1F3FE 200D 2695 FE0F
1F9D1 1F3FF 200D 2695 FE0F
1F468 200D 2695 FE0F
1F468 1F3FB 200D 2695 FE0F
1F468 1F3FC 200D 2695 FE0F
1F468 1F3FD 200D 2695 FE0F
1F468 1F3FE 200D 2695 FE0F
1F468 1F3FF 200D 2695 FE0F
1F469 200D 2695 FE0F
1F469 1F3FB 200D 2695 FE0F
1F469 1F3FC 200D 2695 FE0F
1F469 1F3FD 200D 2695 FE0F
1F469 1F3FE 200D 2695 FE0F
1F469 1F3FF 200D 2695 FE0F
1F9D1 200D 1F393
1F9D1 1F3FB 200D 1F393
1F9D1 1F3FC 200D 1F393
1F9D1 1F3FD 200D 1F393
1F9D1 1F3FE 200D 1F393
1F9D1 1F3FF 200D 1F393
1F468 200D 1F393
1F468 1F3FB 200D 1F393
1F468 1F3FC 200D 1F393
1F468 1F3FD 200D 1F393
1F468 1F3FE 200D 1F393
1F468 1F3FF 200D 1F393
1F469 200D 1F393
1F469 1F3FB 200D 1F393
1F469 1F3FC 200D 1F393
1F469 1F3FD 200D 1F393
1F469 1F3FE 200D 1F393
1F469 1F3FF 200D 1F393
1F9D1 200D 1F3EB
1F9D1 1F3FB 200D 1F3EB
1F9D1 1F3FC 200D 1F3EB
1F9D1 1F3FD 200D 1F3EB
1F9D1 1F3FE 200D 1F3EB
1F9D1 1F3FF 200D 1F3EB
1F468 200D 1F3EB
1F468 1F3FB 200D 1F3EB
1F468 1F3FC 200D 1F3EB
1F468 1F3FD 200D 1F3EB
1F468 1F3FE 200D 1F3EB
1F468 1F3FF 200D 1F3EB
1F469 200D 1F3EB
1F469 1F3FB 200D 1F3EB
1F469 1F3FC 200D 1F3EB
1F469 1F3FD 200D 1F3EB
1F469 1F3FE 200D 1F3EB
1F469 1F3FF 200D 1F3EB
1F9D1 200D 2696 FE0F
1F9D1 1F3FB 200D 2696 FE0F
1F9D1 1F3FC 200D 2696 FE0F
1F9D1 1F3FD 200D 2696 FE0F
1F9D1 1F3FE 200D 2696 FE0F
1F9D1 1F3FF 200D 2696 FE0F
1F468 200D 2696 FE0F
1F468 1F3FB 200D 2696 FE0F
1F468 1F3FC 200D 2696 FE0F
1F468 1F3FD 200D 2696 FE0F
1F468 1F3FE 200D 2696 FE0F
1F468 1F3FF 200D 2696 FE0F
1F469 200D 2696 FE0F
1F469 1F3FB 200D 2696 FE0F
1F469 1F3FC 200D 2696 FE0F
1F469 1F3FD 200D 2696 FE0F
1F469 1F3FE 200D 2696 FE0F
1F469 1F3FF 200D 2696 FE0F
1F9D1 200D 1F33E
1F9D1 1F3FB 200D 1F33E
1F9D1 1F3FC 200D 1F33E
1F9D1 1F3FD 200D 1F33E
1F9D1 1F3FE 200D 1F33E
1F9D1 1F3FF 200D 1F33E
1F468 200D 1F33E
1F468 1F3FB 200D 1F33E
1F468 1F3FC 200D 1F33E
1F468 1F3FD 200D 1F33E
1F468 1F3FE 200D 1F33E
1F468 1F3FF 200D 1F33E
1F469 200D 1F33E
1F469 1F3FB 200D 1F33E
1F469 1F3FC 200D 1F33E
1F469 1F3FD 200D 1F33E
1F469 1F3FE 200D 1F33E
1F469 1F3FF 200D 1F33E
1F9D1 200D 1F373
1F9D1 1F3FB 200D 1F373
1F9D1 1F3FC 200D 1F373
1F9D1 1F3FD 200D 1F373
1F9D1 1F3FE 200D 1F373
1F9D1 1F3FF 200D 1F373
1F468 200D 1F373
1F468 1F3FB 200D 1F373
1F468 1F3FC 200D 1F373
1F468 1F3FD 200D 1F373
1F468 1F3FE 200D 1F373
1F468 1F3FF 200D 1F373
1F469 200D 1F373
1F469 1F3FB 200D 1F373
1F469 1F3FC 200D 1F373
1F469 1F3FD 200D 1F373
1F469 1F3FE 200D 1F373
1F469 1F3FF 200D 1F373
1F9D1 200D 1F527
1F9D1 1F3FB 200D 1F527
1F9D1 1F3FC 200D 1F527
1F9D1 1F3FD 200D 1F527
1F9D1 1F3FE 200D 1F527
1F9D1 1F3FF 200D 1F527
1F468 200D 1F527
1F468 1F3FB 200D 1F527
1F468 1F3FC 200D 1F527
1F468 1F3FD 200D 1F527
1F468 1F3FE 200D 1F527
1F468 1F3FF 200D 1F527
1F469 200D 1F527
1F469 1F3FB 200D 1F527
1F469 1F3FC 200D 1F527
1F469 1F3FD 200D 1F527
1F469 1F3FE 200D 1F527
1F469 1F3FF 200D 1F527
1F9D1 200D 1F3ED
1F9D1 1F3FB 200D 1F3ED
1F9D1 1F3FC 200D 1F3ED
1F9D1 1F3FD 200D 1F3ED
1F9D1 1F3FE 200D 1F3ED
1F9D1 1F3FF 200D 1F3ED
1F468 200D 1F3ED
1F468 1F3FB 200D 1F3ED
1F468 1F3FC 200D 1F3ED
1F468 1F3FD 200D 1F3ED
1F468 1F3FE 200D 1F3ED
1F468 1F3FF 200D 1F3ED
1F469 200D 1F3ED
1F469 1F3FB 200D 1F3ED
1F469 1F3FC 200D 1F3ED
1F469 1F3FD 200D 1F3ED
1F469 1F3FE 200D 1F3ED
1F469 1F3FF 200D 1F3ED
1F9D1 200D 1F4BC
1F9D1 1F3FB 200D 1F4BC
1F9D1 1F3FC 200D 1F4BC
1F9D1 1F3FD 200D 1F4BC
1F9D1 1F3FE 200D 1F4BC
1F9D1 1F3FF 200D 1F4BC
1F468 200D 1F4BC
1F468 1F3FB 200D 1F4BC
1F468 1F3FC 200D 1F4BC
1F468 1F3FD 200D 1F4BC
1F468 1F3FE 200D 1F4BC
1F468 1F3FF 200D 1F4BC
1F469 200D 1F4BC
1F469 1F3FB 200D 1F4BC
1F469 1F3FC 200D 1F4BC
1F469 1F3FD 200D 1F4BC
1F469 1F3FE 200D 1F4BC
1F469 1F3FF 200D 1F4BC
1F9D1 200D 1F52C
1F9D1 1F3FB 200D 1F52C
1F9D1 1F3FC 200D 1F52C
1F9D1 1F3FD 200D 1F52C
1F9D1 1F3FE 200D 1F52C
1F9D1 1F3FF 200D 1F52C
1F468 200D 1F52C
1F468 1F3FB 200D 1F52C
1F468 1F3FC 200D 1F52C
1F468 1F3FD 200D 1F52C
1F468 1F3FE 200D 1F52C
1F468 1F3FF 200D 1F52C
1F469 200D 1F52C
1F469 1F3FB 200D 1F52C
1F469 1F3FC 200D 1F52C
1F469 1F3FD 200D 1F52C
1F469 1F3FE 200D 1F52C
1F469 1F3FF 200D 1F52C
1F9D1 200D 1F4BB
1F9D1 1F3FB 200D 1F4BB
1F9D1 1F3FC 200D 1F4BB
1F9D1 1F3FD 200D 1F4BB
1F9D1 1F3FE 200D 1F4BB
1F9D1 1F3FF 200D 1F4BB
1F468 200D 1F4BB
1F468 1F3FB 200D 1F4BB
1F468 1F3FC 200D 1F4BB
1F468 1F3FD 200D 1F4BB
1F468 1F3FE 200D 1F4BB
1F468 1F3FF 200D 1F4BB
1F469 200D 1F4BB
1F469 1F3FB 200D 1F4BB
1F469 1F3FC 200D 1F4BB
1F469 1F3FD 200D 1F4BB
1F469 1F3FE 200D 1F4BB
1F469 1F3FF 200D 1F4BB
1F9D1 200D 1F3A4
1F9D1 1F3FB 200D 1F3A4
1F9D1 1F3FC 200D 1F3A4
1F9D1 1F3FD 200D 1F3A4
1F9D1 1F3FE 200D 1F3A4
1F9D1 1F3FF 200D 1F3A4
1F468 200D 1F3A4
1F468 1F3FB 200D 1F3A4
1F468 1F3FC 200D 1F3A4
1F468 1F3FD 200D 1F3A4
1F468 1F3FE 200D 1F3A4
1F468 1F3FF 200D 1F3A4
1F469 200D 1F3A4
1F469 1F3FB 200D 1F3A4
1F469 1F3FC 200D 1F3A4
1F469 1F3FD 200D 1F3A4
1F469 1F3FE 200D 1F3A4
1F469 1F3FF 200D 1F3A4
1F9D1 200D 1F3A8
1F9D1 1F3FB 200D 1F3A8
1F9D1 1F3FC 200D 1F3A8
1F9D1 1F3FD 200D 1F3A8
1F9D1 1F3FE 200D 1F3A8
1F9D1 1F3FF 200D 1F3A8
1F468 200D 1F3A8
1F468 1F3FB 200D 1F3A8
1F468 1F3FC 200D 1F3A8
1F468 1F3FD 200D 1F3A8
1F468 1F3FE 200D 1F3A8
1F468 1F3FF 200D 1F3A8
1F469 200D 1F3A8
1F469 1F3FB 200D 1F3A8
1F469 1F3FC 200D 1F3A8
1F469 1F3FD 200D 1F3A8
1F469 1F3FE 200D 1F3A8
1F469 1F3FF 200D 1F3A8
1F9D1 200D 2708 FE0F
1F9D1 1F3FB 200D 2708 FE0F
1F9D1 1F3FC 200D 2708 FE0F
1F9D1 1F3FD 200D 2708 FE0F
1F9D1 1F3FE 200D 2708 FE0F
1F9D1 1F3FF 200D 2708 FE0F
1F468 200D 2708 FE0F
1F468 1F3FB 200D 2708 FE0F
1F468 1F3FC 200D 2708 FE0F
1F468 1F3FD 200D 2708 FE0F
1F468 1F3FE 200D 2708 FE0F
1F468 1F3FF 200D 2708 FE0F
1F469 200D 2708 FE0F
1F469 1F3FB 200D 2708 FE0F
1F469 1F3FC 200D 2708 FE0F
1F469 1F3FD 200D 2708 FE0F
1F469 1F3FE 200D 2708 FE0F
1F469 1F3FF 200D 2708 FE0F
1F9D1 200D 1F680
1F9D1 1F3FB 200D 1F680
1F9D1 1F3FC 200D 1F680
1F9D1 1F3FD 200D 1F680
1F9D1 1F3FE 200D 1F680
1F9D1 1F3FF 200D 1F680
1F468 200D 1F680
1F468 1F3FB 200D 1F680
1F468 1F3FC 200D 1F680
1F468 1F3FD 200D 1F680
1F468 1F3FE 200D 1F680
1F468 1F3FF 200D 1F680
1F469 200D 1F680
1F469 1F3FB 200D 1F680
1F469 1F3FC 200D 1F680
1F469 1F3FD 200D 1F680
1F469 1F3FE 200D 1F680
1F469 1F3FF 200D 1F680
1F9D1 200D 1F692
1F9D1 1F3FB 200D 1F692
1F9D1 1F3FC 200D 1F692
1F9D1 1F3FD 200D 1F692
1F9D1 1F3FE 200D 1F692
1F9D1 1F3FF 200D 1F692
1F468 200D 1F692
1F468 1F3FB 200D 1F692
1F468 1F3FC 200D 1F692
1F468 1F3FD 200D 1F692
1F468 1F3FE 200D 1F692
1F468 1F3FF 200D 1F692
1F469 200D 1F692
1F469 1F3FB 200D 1F692
1F469 1F3FC 200D 1F692
1F469 1F3FD 200D 1F692
1F469 1F3FE 200D 1F692
1F469 1F3FF 200D 1F692
1F46E
1F46E 1F3FB
1F46E 1F3FC
1F46E 1F3FD
1F46E 1F3FE
1F46E 1F3FF
1F46E 200D 2642 FE0F
1F46E 1F3FB 200D 2642 FE0F
1F46E 1F3FC 200D 2642 FE0F
1F46E 1F3FD 200D 2642 FE0F
1F46E 1F3FE 200D 2642 FE0F
1F46E 1F3FF 200D 2642 FE0F
1F46E 200D 2640 FE0F
1F46E 1F3FB 200D 2640 FE0F
1F46E 1F3FC 200D 2640 FE0F
1F46E 1F3FD 200D 2640 FE0F
1F46E 1F3FE 200D 2640 FE0F
1F46E 1F3FF 200D 2640 FE0F
1F575 FE0F
1F575 1F3FB
1F575 1F3FC
1F575 1F3FD
1F575 1F3FE
1F575 1F3FF
1F575 FE0F 200D 2642 FE0F
1F575 1F3FB 200D 2642 FE0F
1F575 1F3FC 200D 2642 FE0F
1F575 1F3FD 200D 2642 FE0F
1F575 1F3FE 200D 2642 FE0F
1F575 1F3FF 200D 2642 FE0F
1F575 FE0F 200D 2640 FE0F
1F575 1F3FB 200D 2640 FE0F
1F575 1F3FC 200D 2640 FE0F
1F575 1F3FD 200D 2640 FE0F
1F575 1F3FE 200D 2640 FE0F
1F575 1F3FF 200D 2640 FE0F
1F482
1F482 1F3FB
1F482 1F3FC
1F482 1F3FD
1F482 1F3FE
1F482 1F3FF
1F482 200D 2642 FE0F
1F482 1F3FB 200D 2642 FE0F
1F482 1F3FC 200D 2642 FE0F
1F482 1F3FD 200D 2642 FE0F
1F482 1F3FE 200D 2642 FE0F
1F482 1F3FF 200D 2642 FE0F
1F482 200D 2640 FE0F
1F482 1F3FB 200D 2640 FE0F
1F482 1F3FC 200D 2640 FE0F
1F482 1F3FD 200D 2640 FE0F
1F482 1F3FE 200D 2640 FE0F
1F482 1F3FF 200D 2640 FE0F
1F977
1F977 1F3FB
1F977 1F3FC
1F977 1F3FD
1F977 1F3FE
1F977 1F3FF
1F477
1F477 1F3FB
1F477 1F3FC
1F477 1F3FD
1F477 1F3FE
1F477 1F3FF
1F477 200D 2642 FE0F
1F477 1F3FB 200D 2642 FE0F
1F477 1F3FC 200D 2642 FE0F
1F477 1F3FD 200D 2642 FE0F
1F477 1F3FE 200D 2642 FE0F
1F477 1F3FF 200D 2642 FE0F
1F477 200D 2640 FE0F
1F477 1F3FB 200D 2640 FE0F
1F477 1F3FC 200D 2640 FE0F
1F477 1F3FD 200D 2640 FE0F
1F477 1F3FE 200D 2640 FE0F
1F477 1F3FF 200D 2640 FE0F
1FAC5
1FAC5 1F3FB
1FAC5 1F3FC
1FAC5 1F3FD
1FAC5 1F3FE
1FAC5 1F3FF
1F934
1F934 1F3FB
1F934 1F3FC
1F934 1F3FD
1F934 1F3FE
1F934 1F3FF
1F478
1F478 1F3FB
1F478 1F3FC
1F478 1F3FD
1F478 1F3FE
1F478 1F3FF
1F473
1F473 1F3FB
1F473 1F3FC
1F473 1F3FD
1F473 1F3FE
1F473 1F3FF
1F473 200D 2642 FE0F
1F473 1F3FB 200D 2642 FE0F
1F473 1F3FC 200D 2642 FE0F
1F473 1F3FD 200D 2642 FE0F
1F473 1F3FE 200D 2642 FE0F
1F473 1F3FF 200D 2642 FE0F
1F473 200D 2640 FE0F
1F473 1F3FB 200D 2640 FE0F
1F473 1F3FC 200D 2640 FE0F
1F473 1F3FD 200D 2640 FE0F
1F473 1F3FE 200D 2640 FE0F
1F473 1F3FF 200D 2640 FE0F
1F472
1F472 1F3FB
1F472 1F3FC
1F472 1F3FD
1F472 1F3FE
1F472 1F3FF
1F9D5
1F9D5 1F3FB
1F9D5 1F3FC
1F9D5 1F3FD
1F9D5 1F3FE
1F9D5 1F3FF
1F935
1F935 1F3FB
1F935 1F3FC
1F935 1F3FD
1F935 1F3FE
1F935 1F3FF
1F935 200D 2642 FE0F
1F935 1F3FB 200D 2642 FE0F
1F935 1F3FC 200D 2642 FE0F
1F935 1F3FD 200D 2642 FE0F
1F935 1F3FE 200D 2642 FE0F
1F935 1F3FF 200D 2642 FE0F
1F935 200D 2640 FE0F
1F935 1F3FB 200D 2640 FE0F
1F935 1F3FC 200D 2640 FE0F
1F935 1F3FD 200D 2640 FE0F
1F935 1F3FE 200D 2640 FE0F
1F935 1F3FF 200D 2640 FE0F
1F470
1F470 1F3FB
1F470 1F3FC
1F470 1F3FD
1F470 1F3FE
1F470 1F3FF
1F470 200D 2642 FE0F
1F470 1F3FB 200D 2642 FE0F
1F470 1F3FC 200D 2642 FE0F
1F470 1F3FD 200D 2642 FE0F
1F470 1F3FE 200D 2642 FE0F
1F470 1F3FF 200D 2642 FE0F
1F470 200D 2640 FE0F
1F470 1F3FB 200D 2640 FE0F
1F470 1F3FC 200D 2640 FE0F
1F470 1F3FD 200D 2640 FE0F
1F470 1F3FE 200D 2640 FE0F
1F470 1F3FF 200D 2640 FE0F
1F930
1F930 1F3FB
1F930 1F3FC
1F930 1F3FD
1F930 1F3FE
1F930 1F3FF
1FAC3
1FAC3 1F3FB
1FAC3 1F3FC
1FAC3 1F3FD
1FAC3 1F3FE
1FAC3 1F3FF
1FAC4
1FAC4 1F3FB
1FAC4 1F3FC
1FAC4 1F3FD
1FAC4 1F3FE
1FAC4 1F3FF
1F931
1F931 1F3FB
1F931 1F3FC
1F931 1F3FD
1F931 1F3FE
1F931 1F3FF
1F469 200D 1F37C
1F469 1F3FB 200D 1F37C
1F469 1F3FC 200D 1F37C
1F469 1F3FD 200D 1F37C
1F469 1F3FE 200D 1F37C
1F469 1F3FF 200D 1F37C
1F468 200D 1F37C
1F468 1F3FB 200D 1F37C
1F468 1F3FC 200D 1F37C
1F468 1F3FD 200D 1F37C
1F468 1F3FE 200D 1F37C
1F468 1F3FF 200D 1F37C
1F9D1 200D 1F37C
1F9D1 1F3FB 200D 1F37C
1F9D1 1F3FC 200D 1F37C
1F9D1 1F3FD 200D 1F37C
1F9D1 1F3FE 200D 1F37C
1F9D1 1F3FF 200D 1F37C
1F47C
1F47C 1F3FB
1F47C 1F3FC
1F47C 1F3FD
1F47C 1F3FE
1F47C 1F3FF
1F385
1F385 1F3FB
1F385 1F3FC
1F385 1F3FD
1F385 1F3FE
1F385 1F3FF
1F936
1F936 1F3FB
1F936 1F3FC
1F936 1F3FD
1F936 1F3FE
1F936 1F3FF
1F9D1 200D 1F384
1F9D1 1F3FB 200D 1F384
1F9D1 1F3FC 200D 1F384
1F9D1 1F3FD 200D 1F384
1F9D1 1F3FE 200D 1F384
1F9D1 1F3FF 200D 1F384
1F9B8
1F9B8 1F3FB
1F9B8 1F3FC
1F9B8 1F3FD
1F9B8 1F3FE
1F9B8 1F3FF
1F9B8 200D 2642 FE0F
1F9B8 1F3FB 200D 2642 FE0F
1F9B8 1F3FC 200D 2642 FE0F
1F9B8 1F3FD 200D 2642 FE0F
1F9B8 1F3FE 200D 2642 FE0F
1F9B8 1F3FF 200D 2642 FE0F
1F9B8 200D 2640 FE0F
1F9B8 1F3FB 200D 2640 FE0F
1F9B8 1F3FC 200D 2640 FE0F
1F9B8 1F3FD 200D 2640 FE0F
1F9B8 1F3FE 200D 2640 FE0F
1F9B8 1F3FF 200D 2640 FE0F
1F9B9
1F9B9 1F3FB
1F9B9 1F3FC
1F9B9 1F3FD
1F9B9 1F3FE
1F9B9 1F3FF
1F9B9 200D 2642 FE0F
1F9B9 1F3FB 200D 2642 FE0F
1F9B9 1F3FC 200D 2642 FE0F
1F9B9 1F3FD 200D 2642 FE0F
1F9B9 1F3FE 200D 2642 FE0F
1F9B9 1F3FF 200D 2642 FE0F
1F9B9 200D 2640 FE0F
1F9B9 1F3FB 200D 2640 FE0F
1F9B9 1F3FC 200D 2640 FE0F
1F9B9 1F3FD 200D 2640 FE0F
1F9B9 1F3FE 200D 2640 FE0F
1F9B9 1F3FF 200D 2640 FE0F
1F9D9
1F9D9 1F3FB
1F9D9 1F3FC
1F9D9 1F3FD
1F9D9 1F3FE
1F9D9 1F3FF
1F9D9 200D 2642 FE0F
1F9D9 1F3FB 200D 2642 FE0F
1F9D9 1F3FC 200D 2642 FE0F
1F9D9 1F3FD 200D 2642 FE0F
1F9D9 1F3FE 200D 2642 FE0F
1F9D9 1F3FF 200D 2642 FE0F
1F9D9 200D 2640 FE0F
1F9D9 1F3FB 200D 2640 FE0F
1F9D9 1F3FC 200D 2640 FE0F
1F9D9 1F3FD 200D 2640 FE0F
1F9D9 1F3FE 200D 2640 FE0F
1F9D9 1F3FF 200D 2640 FE0F
1F9DA
1F9DA 1F3FB
1F9DA 1F3FC
1F9DA 1F3FD
1F9DA 1F3FE
1F9DA 1F3FF
1F9DA 200D 2642 FE0F
1F9DA 1F3FB 200D 2642 FE0F
1F9DA 1F3FC 200D 2642 FE0F
1F9DA 1F3FD 200D 2642 FE0F
1F9DA 1F3FE 200D 2642 FE0F
1F9DA 1F3FF 200D 2642 FE0F
1F9DA 200D 2640 FE0F
1F9DA 1F3FB 200D 2640 FE0F
1F9DA 1F3FC 200D 2640 FE0F
1F9DA 1F3FD 200D 2640 FE0F
1F9DA 1F3FE 200D 2640 FE0F
1F9DA 1F3FF 200D 2640 FE0F
1F9DB
1F9DB 1F3FB
1F9DB 1F3FC
1F9DB 1F3FD
1F9DB 1F3FE
1F9DB 1F3FF
1F9DB 200D 2642 FE0F
1F9DB 1F3FB 200D 2642 FE0F
1F9DB 1F3FC 200D 2642 FE0F
1F9DB 1F3FD 200D 2642 FE0F
1F9DB 1F3FE 200D 2642 FE0F
1F9DB 1F3FF 200D 2642 FE0F
1F9DB 200D 2640 FE0F
1F9DB 1F3FB 200D 2640 FE0F
1F9DB 1F3FC 200D 2640 FE0F
1F9DB 1F3FD 200D 2640 FE0F
1F9DB 1F3FE 200D 2640 FE0F
1F9DB 1F3FF 200D 2640 FE0F
1F9DC
1F9DC 1F3FB
1F9DC 1F3FC
1F9DC 1F3FD
1F9DC 1F3FE
1F9DC 1F3FF
1F9DC 200D 2642 FE0F
1F9DC 1F3FB 200D 2642 FE0F
1F9DC 1F3FC 200D 2642 FE0F
1F9DC 1F3FD 200D 2642 FE0F
1F9DC 1F3FE 200D 2642 FE0F
1F9DC 1F3FF 200D 2642 FE0F
1F9DC 200D 2640 FE0F
1F9DC 1F3FB 200D 2640 FE0F
1F9DC 1F3FC 200D 2640 FE0F
1F9DC 1F3FD 200D 2640 FE0F
1F9DC 1F3FE 200D 2640 FE0F
1F9DC 1F3FF 200D 2640 FE0F
1F9DD
1F9DD 1F3FB
1F9DD 1F3FC
1F9DD 1F3FD
1F9DD 1F3FE
1F9DD 1F3FF
1F9DD 200D 2642 FE0F
1F9DD 1F3FB 200D 2642 FE0F
1F9DD 1F3FC 200D 2642 FE0F
1F9DD 1F3FD 200D 2642 FE0F
1F9DD 1F3FE 200D 2642 FE0F
1F9DD 1F3FF 200D 2642 FE0F
1F9DD 200D 2640 FE0F
1F9DD 1F3FB 200D 2640 FE0F
1F9DD 1F3FC 200D 2640 FE0F
1F9DD 1F3FD 200D 2640 FE0F
1F9DD 1F3FE 200D 2640 FE0F
1F9DD 1F3FF 200D 2640 FE0F
1F9DE
1F9DE 200D 2642 FE0F
1F9DE 200D 2640 FE0F
1F9DF
1F9DF 200D 2642 FE0F
1F9DF 200D 2640 FE0F
1F9CC
1F486
1F486 1F3FB
1F486 1F3FC
1F486 1F3FD
1F486 1F3FE
1F486 1F3FF
1F486 200D 2642 FE0F
1F486 1F3FB 200D 2642 FE0F
1F486 1F3FC 200D 2642 FE0F
1F486 1F3FD 200D 2642 FE0F
1F486 1F3FE 200D 2642 FE0F
1F486 1F3FF 200D 2642 FE0F
1F486 200D 2640 FE0F
1F486 1F3FB 200D 2640 FE0F
1F486 1F3FC 200D 2640 FE0F
1F486 1F3FD 200D 2640 FE0F
1F486 1F3FE 200D 2640 FE0F
1F486 1F3FF 200D 2640 FE0F
1F487
1F487 1F3FB
1F487 1F3FC
1F487 1F3FD
1F487 1F3FE
1F487 1F3FF
1F487 200D 2642 FE0F
1F487 1F3FB 200D 2642 FE0F
1F487 1F3FC 200D 2642 FE0F
1F487 1F3FD 200D 2642 FE0F
1F487 1F3FE 200D 2642 FE0F
1F487 1F3FF 200D 2642 FE0F
1F487 200D 2640 FE0F
1F487 1F3FB 200D 2640 FE0F
1F487 1F3FC 200D 2640 FE0F
1F487 1F3FD 200D 2640 FE0F
1F487 1F3FE 200D 2640 FE0F
1F487 1F3FF 200D 2640 FE0F
1F6B6
1F6B6 1F3FB
1F6B6 1F3FC
1F6B6 1F3FD
1F6B6 1F3FE
1F6B6 1F3FF
1F6B6 200D 2642 FE0F
1F6B6 1F3FB 200D 2642 FE0F
1F6B6 1F3FC 200D 2642 FE0F
1F6B6 1F3FD 200D 2642 FE0F
1F6B6 1F3FE 200D 2642 FE0F
1F6B6 1F3FF 200D 2642 FE0F
1F6B6 200D 2640 FE0F
1F6B6 1F3FB 200D 2640 FE0F
1F6B6 1F3FC 200D 2640 FE0F
1F6B6 1F3FD 200D 2640 FE0F
1F6B6 1F3FE 200D 2640 FE0F
1F6B6 1F3FF 200D 2640 FE0F
1F6B6 200D 27A1 FE0F
1F6B6 1F3FB 200D 27A1 FE0F
1F6B6 1F3FC 200D 27A1 FE0F
1F6B6 1F3FD 200D 27A1 FE0F
1F6B6 1F3FE 200D 27A1 FE0F
1F6B6 1F3FF 200D 27A1 FE0F
1F6B6 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 1F3FB 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 1F3FC 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 1F3FD 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 1F3FE 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 1F3FF 200D 2640 FE0F 200D 27A1 FE0F
1F6B6 200D 2642 FE0F 200D 27A1 FE0F
1F6B6 1F3FB 200D 2642 FE0F 200D 27A1 FE0F
1F6B6 1F3FC 200D 2642 FE0F 200D 27A1 FE0F
1F6B6 1F3FD 200D 2642 FE0F 200D 27A1 FE0F
1F6B6 1F3FE 200D 2642 FE0F 200D 27A1 FE0F
1F6B6 1F3FF 200D 2642 FE0F 200D 27A1 FE0F
1F9CD
1F9CD 1F3FB
1F9CD 1F3FC
1F9CD 1F3FD
1F9CD 1F3FE
1F9CD 1F3FF
1F9CD 200D 2642 FE0F
1F9CD 1F3FB 200D 2642 FE0F
1F9CD 1F3FC 200D 2642 FE0F
1F9CD 1F3FD 200D 2642 FE0F
1F9CD 1F3FE 200D 2642 FE0F
1F9CD 1F3FF 200D 2642 FE0F
1F9CD 200D 2640 FE0F
1F9CD 1F3FB 200D 2640 FE0F
1F9CD 1F3FC 200D 2640 FE0F
1F9CD 1F3FD 200D 2640 FE0F
1F9CD 1F3FE 200D 2640 FE0F
1F9CD 1F3FF 200D 2640 FE0F
1F9CE
1F9CE 1F3FB
1F9CE 1F3FC
1F9CE 1F3FD
1F9CE 1F3FE
1F9CE 1F3FF
1F9CE 200D 2642 FE0F
1F9CE 1F3FB 200D 2642 FE0F
1F9CE 1F3FC 200D 2642 FE0F
1F9CE 1F3FD 200D 2642 FE0F
1F9CE 1F3FE 200D 2642 FE0F
1F9CE 1F3FF 200D 2642 FE0F
1F9CE 200D 2640 FE0F
1F9CE 1F3FB 200D 2640 FE0F
1F9CE 1F3FC 200D 2640 FE0F
1F9CE 1F3FD 200D 2640 FE0F
1F9CE 1F3FE 200D 2640 FE0F
1F9CE 1F3FF 200D 2640 FE0F
1F9CE 200D 27A1 FE0F
1F9CE 1F3FB 200D 27A1 FE0F
1F9CE 1F3FC 200D 27A1 FE0F
1F9CE 1F3FD 200D 27A1 FE0F
1F9CE 1F3FE 200D 27A1 FE0F
1F9CE 1F3FF 200D 27A1 FE0F
1F9CE 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 1F3FB 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 1F3FC 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 1F3FD 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 1F3FE 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 1F3FF 200D 2640 FE0F 200D 27A1 FE0F
1F9CE 200D 2642 FE0F 200D 27A1 FE0F
1F9CE 1F3FB 200D 2642 FE0F 200D 27A1 FE0F
1F9CE 1F3FC 200D 2642 FE0F 200D 27A1 FE0F
1F9CE 1F3FD 200D 2642 FE0F 200D 27A1 FE0F
1F9CE 1F3FE 200D 2642 FE0F 200D 27A1 FE0F
1F9CE 1F3FF 200D 2642 FE0F 200D 27A1 FE0F
1F9D1 200D 1F9AF
1F9D1 1F3FB 200D 1F9AF
1F9D1 1F3FC 200D 1F9AF
1F9D1 1F3FD 200D 1F9AF
1F9D1 1F3FE 200D 1F9AF
1F9D1 1F3FF 200D 1F9AF
1F9D1 200D 1F9AF 200D 27A1 FE0F
1F9D1 1F3FB 200D 1F9AF 200D 27A1 FE0F
1F9D1 1F3FC 200D 1F9AF 200D 27A1 FE0F
1F9D1 1F3FD 200D 1F9AF 200D 27A1 FE0F
1F9D1 1F3FE 200D 1F9AF 200D 27A1 FE0F
1F9D1 1F3FF 200D 1F9AF 200D 27A1 FE0F
1F468 200D 1F9AF
1F468 1F3FB 200D 1F9AF
1F468 1F3FC 200D 1F9AF
1F468 1F3FD 200D 1F9AF
1F468 1F3FE 200D 1F9AF
1F468 1F3FF 200D 1F9AF
1F468 200D 1F9AF 200D 27A1 FE0F
1F468 1F3FB 200D 1F9AF 200D 27A1 FE0F
1F468 1F3FC 200D 1F9AF 200D 27A1 FE0F
1F468 1F3FD 200D 1F9AF 200D 27A1 FE0F
1F468 1F3FE 200D 1F9AF 200D 27A1 FE0F
1F468 1F3FF 200D 1F9AF 200D 27A1 FE0F
1F469 200D 1F9AF
1F469 1F3FB 200D 1F9AF
1F469 1F3FC 200D 1F9AF
1F469 1F3FD 200D 1F9AF
1F469 1F3FE 200D 1F9AF
1F469 1F3FF 200D 1F9AF
1F469 200D 1F9AF 200D 27A1 FE0F
1F469 1F3FB 200D 1F9AF 200D 27A1 FE0F
1F469 1F3FC 200D 1F9AF 200D 27A1 FE0F
1F469 1F3FD 200D 1F9AF 200D 27A1 FE0F
1F469 1F3FE 200D 1F9AF 200D 27A1 FE0F
1F469 1F3FF 200D 1F9AF 200D 27A1 FE0F
1F9D1 200D 1F9BC
1F9D1 1F3FB 200D 1F9BC
1F9D1 1F3FC 200D 1F9BC
1F9D1 1F3FD 200D 1F9BC
1F9D1 1F3FE 200D 1F9BC
1F9D1 1F3FF 200D 1F9BC
1F9D1 200D 1F9BC 200D 27A1 FE0F
1F9D1 1F3FB 200D 1F9BC 200D 27A1 FE0F
1F9D1 1F3FC 200D 1F9BC 200D 27A1 FE0F
1F9D1 1F3FD 200D 1F9BC 200D 27A1 FE0F
1F9D1 1F3FE 200D 1F9BC 200D 27A1 FE0F
1F9D1 1F3FF 200D 1F9BC 200D 27A1 FE0F
1F468 200D 1F9BC
1F468 1F3FB 200D 1F9BC
1F468 1F3FC 200D 1F9BC
1F468 1F3FD 200D 1F9BC
1F468 1F3FE 200D 1F9BC
1F468 1F3FF 200D 1F9BC
1F468 200D 1F9BC 200D 27A1 FE0F
1F468 1F3FB 200D 1F9BC 200D 27A1 FE0F
1F468 1F3FC 200D 1F9BC 200D 27A1 FE0F
1F468 1F3FD 200D 1F9BC 200D 27A1 FE0F
1F468 1F3FE 200D 1F9BC 200D 27A1 FE0F
1F468 1F3FF 200D 1F9BC 200D 27A1 FE0F
1F469 200D 1F9BC
1F469 1F3FB 200D 1F9BC
1F469 1F3FC 200D 1F9BC
1F469 1F3FD 200D 1F9BC
1F469 1F3FE 200D 1F9BC
1F469 1F3FF 200D 1F9BC
1F469 200D 1F9BC 200D 27A1 FE0F
1F469 1F3FB 200D 1F9BC 200D 27A1 FE0F
1F469 1F3FC 200D 1F9BC 200D 27A1 FE0F
1F469 1F3FD 200D 1F9BC 200D 27A1 FE0F
1F469 1F3FE 200D 1F9BC 200D 27A1 FE0F
1F469 1F3FF 200D 1F9BC 200D 27A1 FE0F
1F9D1 200D 1F9BD
1F9D1 1F3FB 200D 1F9BD
1F9D1 1F3FC 200D 1F9BD
1F9D1 1F3FD 200D 1F9BD
1F9D1 1F3FE 200D 1F9BD
1F9D1 1F3FF 200D 1F9BD
1F9D1 200D 1F9BD 200D 27A1 FE0F
1F9D1 1F3FB 200D 1F9BD 200D 27A1 FE0F
1F9D1 1F3FC 200D 1F9BD 200D 27A1 FE0F
1F9D1 1F3FD 200D 1F9BD 200D 27A1 FE0F
1F9D1 1F3FE 200D 1F9BD 200D 27A1 FE0F
1F9D1 1F3FF 200D 1F9BD 200D 27A1 FE0F
1F468 200D 1F9BD
1F468 1F3FB 200D 1F9BD
1F468 1F3FC 200D 1F9BD
1F468 1F3FD 200D 1F9BD
1F468 1F3FE 200D 1F9BD
1F468 1F3FF 200D 1F9BD
1F468 200D 1F9BD 200D 27A1 FE0F
1F468 1F3FB 200D 1F9BD 200D 27A1 FE0F
1F468 1F3FC 200D 1F9BD 200D 27A1 FE0F
1F468 1F3FD 200D 1F9BD 200D 27A1 FE0F
1F468 1F3FE 200D 1F9BD 200D 27A1 FE0F
1F468 1F3FF 200D 1F9BD 200D 27A1 FE0F
1F469 200D 1F9BD
1F469 1F3FB 200D 1F9BD
1F469 1F3FC 200D 1F9BD
1F469 1F3FD 200D 1F9BD
1F469 1F3FE 200D 1F9BD
1F469 1F3FF 200D 1F9BD
1F469 200D 1F9BD 200D 27A1 FE0F
1F469 1F3FB 200D 1F9BD 200D 27A1 FE0F
1F469 1F3FC 200D 1F9BD 200D 27A1 FE0F
1F469 1F3FD 200D 1F9BD 200D 27A1 FE0F
1F469 1F3FE 200D 1F9BD 200D 27A1 FE0F
1F469 1F3FF 200D 1F9BD 200D 27A1 FE0F
1F3C3
1F3C3 1F3FB
1F3C3 1F3FC
1F3C3 1F3FD
1F3C3 1F3FE
1F3C3 1F3FF
1F3C3 200D 2642 FE0F
1F3C3 1F3FB 200D 2642 FE0F
1F3C3 1F3FC 200D 2642 FE0F
1F3C3 1F3FD 200D 2642 FE0F
1F3C3 1F3FE 200D 2642 FE0F
1F3C3 1F3FF 200D 2642 FE0F
1F3C3 200D 2640 FE0F
1F3C3 1F3FB 200D 2640 FE0F
1F3C3 1F3FC 200D 2640 FE0F
1F3C3 1F3FD 200D 2640 FE0F
1F3C3 1F3FE 200D 2640 FE0F
1F3C3 1F3FF 200D 2640 FE0F
1F3C3 200D 27A1 FE0F
1F3C3 1F3FB 200D 27A1 FE0F
1F3C3 1F3FC 200D 27A1 FE0F
1F3C3 1F3FD 200D 27A1 FE0F
1F3C3 1F3FE 200D 27A1 FE0F
1F3C3 1F3FF 200D 27A1 FE0F
1F3C3 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 1F3FB 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 1F3FC 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 1F3FD 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 1F3FE 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 1F3FF 200D 2640 FE0F 200D 27A1 FE0F
1F3C3 200D 2642 FE0F 200D 27A1 FE0F
1F3C3 1F3FB 200D 2642 FE0F 200D 27A1 FE0F
1F3C3 1F3FC 200D 2642 FE0F 200D 27A1 FE0F
1F3C3 1F3FD 200D 2642 FE0F 200D 27A1 FE0F
1F3C3 1F3FE 200D 2642 FE0F 200D 27A1 FE0F
1F3C3 1F3FF 200D 2642 FE0F 200D 27A1 FE0F
1F483
1F483 1F3FB
1F483 1F3FC
1F483 1F3FD
1F483 1F3FE
1F483 1F3FF
1F57A
1F57A 1F3FB
1F57A 1F3FC
1F57A 1F3FD
1F57A 1F3FE
1F57A 1F3FF
1F574 FE0F
1F574 1F3FB
1F574 1F3FC
1F574 1F3FD
1F574 1F3FE
1F574 1F3FF
1F46F
1F46F 200D 2642 FE0F
1F46F 200D 2640 FE0F
1F9D6
1F9D6 1F3FB
1F9D6 1F3FC
1F9D6 1F3FD
1F9D6 1F3FE
1F9D6 1F3FF
1F9D6 200D 2642 FE0F
1F9D6 1F3FB 200D 2642 FE0F
1F9D6 1F3FC 200D 2642 FE0F
1F9D6 1F3FD 200D 2642 FE0F
1F9D6 1F3FE 200D 2642 FE0F
1F9D6 1F3FF 200D 2642 FE0F
1F9D6 200D 2640 FE0F
1F9D6 1F3FB 200D 2640 FE0F
1F9D6 1F3FC 200D 2640 FE0F
1F9D6 1F3FD 200D 2640 FE0F
1F9D6 1F3FE 200D 2640 FE0F
1F9D6 1F3FF 200D 2640 FE0F
1F9D7
1F9D7 1F3FB
1F9D7 1F3FC
1F9D7 1F3FD
1F9D7 1F3FE
1F9D7 1F3FF
1F9D7 200D 2642 FE0F
1F9D7 1F3FB 200D 2642 FE0F
1F9D7 1F3FC 200D 2642 FE0F
1F9D7 1F3FD 200D 2642 FE0F
1F9D7 1F3FE 200D 2642 FE0F
1F9D7 1F3FF 200D 2642 FE0F
1F9D7 200D 2640 FE0F
1F9D7 1F3FB 200D 2640 FE0F
1F9D7 1F3FC 200D 2640 FE0F
1F9D7 1F3FD 200D 2640 FE0F
1F9D7 1F3FE 200D 2640 FE0F
1F9D7 1F3FF 200D 2640 FE0F
1F93A
1F3C7
1F3C7 1F3FB
1F3C7 1F3FC
1F3C7 1F3FD
1F3C7 1F3FE
1F3C7 1F3FF
26F7 FE0F
1F3C2
1F3C2 1F3FB
1F3C2 1F3FC
1F3C2 1F3FD
1F3C2 1F3FE
1F3C2 1F3FF
1F3CC FE0F
1F3CC 1F3FB
1F3CC 1F3FC
1F3CC 1F3FD
1F3CC 1F3FE
1F3CC 1F3FF
1F3CC FE0F 200D 2642 FE0F
1F3CC 1F3FB 200D 2642 FE0F
1F3CC 1F3FC 200D 2642 FE0F
1F3CC 1F3FD 200D 2642 FE0F
1F3CC 1F3FE 200D 2642 FE0F
1F3CC 1F3FF 200D 2642 FE0F
1F3CC FE0F 200D 2640 FE0F
1F3CC 1F3FB 200D 2640 FE0F
1F3CC 1F3FC 200D 2640 FE0F
1F3CC 1F3FD 200D 2640 FE0F
1F3CC 1F3FE 200D 2640 FE0F
1F3CC 1F3FF 200D 2640 FE0F
1F3C4
1F3C4 1F3FB
1F3C4 1F3FC
1F3C4 1F3FD
1F3C4 1F3FE
1F3C4 1F3FF
1F3C4 200D 2642 FE0F
1F3C4 1F3FB 200D 2642 FE0F
1F3C4 1F3FC 200D 2642 FE0F
1F3C4 1F3FD 200D 2642 FE0F
1F3C4 1F3FE 200D 2642 FE0F
1F3C4 1F3FF 200D 2642 FE0F
1F3C4 200D 2640 FE0F
1F3C4 1F3FB 200D 2640 FE0F
1F3C4 1F3FC 200D 2640 FE0F
1F3C4 1F3FD 200D 2640 FE0F
1F3C4 1F3FE 200D 2640 FE0F
1F3C4 1F3FF 200D 2640 FE0F
1F6A3
1F6A3 1F3FB
1F6A3 1F3FC
1F6A3 1F3FD
1F6A3 1F3FE
1F6A3 1F3FF
1F6A3 200D 2642 FE0F
1F6A3 1F3FB 200D 2642 FE0F
1F6A3 1F3FC 200D 2642 FE0F
1F6A3 1F3FD 200D 2642 FE0F
1F6A3 1F3FE 200D 2642 FE0F
1F6A3 1F3FF 200D 2642 FE0F
1F6A3 200D 2640 FE0F
1F6A3 1F3FB 200D 2640 FE0F
1F6A3 1F3FC 200D 2640 FE0F
1F6A3 1F3FD 200D 2640 FE0F
1F6A3 1F3FE 200D 2640 FE0F
1F6A3 1F3FF 200D 2640 FE0F
1F3CA
1F3CA 1F3FB
1F3CA 1F3FC
1F3CA 1F3FD
1F3CA 1F3FE
1F3CA 1F3FF
1F3CA 200D 2642 FE0F
1F3CA 1F3FB 200D 2642 FE0F
1F3CA 1F3FC 200D 2642 FE0F
1F3CA 1F3FD 200D 2642 FE0F
1F3CA 1F3FE 200D 2642 FE0F
1F3CA 1F3FF 200D 2642 FE0F
1F3CA 200D 2640 FE0F
1F3CA 1F3FB 200D 2640 FE0F
1F3CA 1F3FC 200D 2640 FE0F
1F3CA 1F3FD 200D 2640 FE0F
1F3CA 1F3FE 200D 2640 FE0F
1F3CA 1F3FF 200D 2640 FE0F
26F9 FE0F
26F9 1F3FB
26F9 1F3FC
26F9 1F3FD
26F9 1F3FE
26F9 1F3FF
26F9 FE0F 200D 2642 FE0F
26F9 1F3FB 200D 2642 FE0F
26F9 1F3FC 200D 2642 FE0F
26F9 1F3FD 200D 2642 FE0F
26F9 1F3FE 200D 2642 FE0F
26F9 1F3FF 200D 2642 FE0F
26F9 FE0F 200D 2640 FE0F
26F9 1F3FB 200D 2640 FE0F
26F9 1F3FC 200D 2640 FE0F
26F9 1F3FD 200D 2640 FE0F
26F9 1F3FE 200D 2640 FE0F
26F9 1F3FF 200D 2640 FE0F
1F3CB FE0F
1F3CB 1F3FB
1F3CB 1F3FC
1F3CB 1F3FD
1F3CB 1F3FE
1F3CB 1F3FF
1F3CB FE0F 200D 2642 FE0F
1F3CB 1F3FB 200D 2642 FE0F
1F3CB 1F3FC 200D 2642 FE0F
1F3CB 1F3FD 200D 2642 FE0F
1F3CB 1F3FE 200D 2642 FE0F
1F3CB 1F3FF 200D 2642 FE0F
1F3CB FE0F 200D 2640 FE0F
1F3CB 1F3FB 200D 2640 FE0F
1F3CB 1F3FC 200D 2640 FE0F
1F3CB 1F3FD 200D 2640 FE0F
1F3CB 1F3FE 200D 2640 FE0F
1F3CB 1F3FF 200D 2640 FE0F
1F6B4
1F6B4 1F3FB
1F6B4 1F3FC
1F6B4 1F3FD
1F6B4 1F3FE
1F6B4 1F3FF
1F6B4 200D 2642 FE0F
1F6B4 1F3FB 200D 2642 FE0F
1F6B4 1F3FC 200D 2642 FE0F
1F6B4 1F3FD 200D 2642 FE0F
1F6B4 1F3FE 200D 2642 FE0F
1F6B4 1F3FF 200D 2642 FE0F
1F6B4 200D 2640 FE0F
1F6B4 1F3FB 200D 2640 FE0F
1F6B4 1F3FC 200D 2640 FE0F
1F6B4 1F3FD 200D 2640 FE0F
1F6B4 1F3FE 200D 2640 FE0F
1F6B4 1F3FF 200D 2640 FE0F
1F6B5
1F6B5 1F3FB
1F6B5 1F3FC
1F6B5 1F3FD
1F6B5 1F3FE
1F6B5 1F3FF
1F6B5 200D 2642 FE0F
1F6B5 1F3FB 200D 2642 FE0F
1F6B5 1F3FC 200D 2642 FE0F
1F6B5 1F3FD 200D 2642 FE0F
1F6B5 1F3FE 200D 2642 FE0F
1F6B5 1F3FF 200D 2642 FE0F
1F6B5 200D 2640 FE0F
1F6B5 1F3FB 200D 2640 FE0F
1F6B5 1F3FC 200D 2640 FE0F
1F6B5 1F3FD 200D 2640 FE0F
1F6B5 1F3FE 200D 2640 FE0F
1F6B5 1F3FF 200D 2640 FE0F
1F938
1F938 1F3FB
1F938 1F3FC
1F938 1F3FD
1F938 1F3FE
1F938 1F3FF
1F938 200D 2642 FE0F
1F938 1F3FB 200D 2642 FE0F
1F938 1F3FC 200D 2642 FE0F
1F938 1F3FD 200D 2642 FE0F
1F938 1F3FE 200D 2642 FE0F
1F938 1F3FF 200D 2642 FE0F
1F938 200D 2640 FE0F
1F938 1F3FB 200D 2640 FE0F
1F938 1F3FC 200D 2640 FE0F
1F938 1F3FD 200D 2640 FE0F
1F938 1F3FE 200D 2640 FE0F
1F938 1F3FF 200D 2640 FE0F
1F93C
1F93C 200D 2642 FE0F
1F93C 200D 2640 FE0F
1F93D
1F93D 1F3FB
1F93D 1F3FC
1F93D 1F3FD
1F93D 1F3FE
1F93D 1F3FF
1F93D 200D 2642 FE0F
1F93D 1F3FB 200D 2642 FE0F
1F93D 1F3FC 200D 2642 FE0F
1F93D 1F3FD 200D 2642 FE0F
1F93D 1F3FE 200D 2642 FE0F
1F93D 1F3FF 200D 2642 FE0F
1F93D 200D 2640 FE0F
1F93D 1F3FB 200D 2640 FE0F
1F93D 1F3FC 200D 2640 FE0F
1F93D 1F3FD 200D 2640 FE0F
1F93D 1F3FE 200D 2640 FE0F
1F93D 1F3FF 200D 2640 FE0F
1F93E
1F93E 1F3FB
1F93E 1F3FC
1F93E 1F3FD
1F93E 1F3FE
1F93E 1F3FF
1F93E 200D 2642 FE0F
1F93E 1F3FB 200D 2642 FE0F
1F93E 1F3FC 200D 2642 FE0F
1F93E 1F3FD 200D 2642 FE0F
1F93E 1F3FE 200D 2642 FE0F
1F93E 1F3FF 200D 2642 FE0F
1F93E 200D 2640 FE0F
1F93E 1F3FB 200D 2640 FE0F
1F93E 1F3FC 200D 2640 FE0F
1F93E 1F3FD 200D 2640 FE0F
1F93E 1F3FE 200D 2640 FE0F
1F93E 1F3FF 200D 2640 FE0F
1F939
1F939 1F3FB
1F939 1F3FC
1F939 1F3FD
1F939 1F3FE
1F939 1F3FF
1F939 200D 2642 FE0F
1F939 1F3FB 200D 2642 FE0F
1F939 1F3FC 200D 2642 FE0F
1F939 1F3FD 200D 2642 FE0F
1F939 1F3FE 200D 2642 FE0F
1F939 1F3FF 200D 2642 FE0F
1F939 200D 2640 FE0F
1F939 1F3FB 200D 2640 FE0F
1F939 1F3FC 200D 2640 FE0F
1F939 1F3FD 200D 2640 FE0F
1F939 1F3FE 200D 2640 FE0F
1F939 1F3FF 200D 2640 FE0F
1F9D8
1F9D8 1F3FB
1F9D8 1F3FC
1F9D8 1F3FD
1F9D8 1F3FE
1F9D8 1F3FF
1F9D8 200D 2642 FE0F
1F9D8 1F3FB 200D 2642 FE0F
1F9D8 1F3FC 200D 2642 FE0F
1F9D8 1F3FD 200D 2642 FE0F
1F9D8 1F3FE 200D 2642 FE0F
1F9D8 1F3FF 200D 2642 FE0F
1F9D8 200D 2640 FE0F
1F9D8 1F3FB 200D 2640 FE0F
1F9D8 1F3FC 200D 2640 FE0F
1F9D8 1F3FD 200D 2640 FE0F
1F9D8 1F3FE 200D 2640 FE0F
1F9D8 1F3FF 200D 2640 FE0F
1F6C0
1F6C0 1F3FB
1F6C0 1F3FC
1F6C0 1F3FD
1F6C0 1F3FE
1F6C0 1F3FF
1F6CC
1F6CC 1F3FB
1F6CC 1F3FC
1F6CC 1F3FD
1F6CC 1F3FE
1F6CC 1F3FF
1F9D1 200D 1F91D 200D 1F9D1
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FB
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FC
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FD
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FE
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FF
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FB
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FC
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FD
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FE
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FF
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FB
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FC
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FD
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FE
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FF
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FB
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FC
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FD
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FE
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FF
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FB
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FC
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FD
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FE
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FF
1F46D
1F46D 1F3FB
1F469 1F3FB 200D 1F91D 200D 1F469 1F3FC
1F469 1F3FB 200D 1F91D 200D 1F469 1F3FD
1F469 1F3FB 200D 1F91D 200D 1F469 1F3FE
1F469 1F3FB 200D 1F91D 200D 1F469 1F3FF
1F469 1F3FC 200D 1F91D 200D 1F469 1F3FB
1F46D 1F3FC
1F469 1F3FC 200D 1F91D 200D 1F469 1F3FD
1F469 1F3FC 200D 1F91D 200D 1F469 1F3FE
1F469 1F3FC 200D 1F91D 200D 1F469 1F3FF
1F469 1F3FD 200D 1F91D 200D 1F469 1F3FB
1F469 1F3FD 200D 1F91D 200D 1F469 1F3FC
1F46D 1F3FD
1F469 1F3FD 200D 1F91D 200D 1F469 1F3FE
1F469 1F3FD 200D 1F91D 200D 1F469 1F3FF
1F469 1F3FE 200D 1F91D 200D 1F469 1F3FB
1F469 1F3FE 200D 1F91D 200D 1F469 1F3FC
1F469 1F3FE 200D 1F91D 200D 1F469 1F3FD
1F46D 1F3FE
1F469 1F3FE 200D 1F91D 200D 1F469 1F3FF
1F469 1F3FF 200D 1F91D 200D 1F469 1F3FB
1F469 1F3FF 200D 1F91D 200D 1F469 1F3FC
1F469 1F3FF 200D 1F91D 200D 1F469 1F3FD
1F469 1F3FF 200D 1F91D 200D 1F469 1F3FE
1F46D 1F3FF
1F46B
1F46B 1F3FB
1F469 1F3FB 200D 1F91D 200D 1F468 1F3FC
1F469 1F3FB 200D 1F91D 200D 1F468 1F3FD
1F469 1F3FB 200D 1F91D 200D 1F468 1F3FE
1F469 1F3FB 200D 1F91D 200D 1F468 1F3FF
1F469 1F3FC 200D 1F91D 200D 1F468 1F3FB
1F46B 1F3FC
1F469 1F3FC 200D 1F91D 200D 1F468 1F3FD
1F469 1F3FC 200D 1F91D 200D 1F468 1F3FE
1F469 1F3FC 200D 1F91D 200D 1F468 1F3FF
1F469 1F3FD 200D 1F91D 200D 1F468 1F3FB
1F469 1F3FD 200D 1F91D 200D 1F468 1F3FC
1F46B 1F3FD
1F469 1F3FD 200D 1F91D 200D 1F468 1F3FE
1F469 1F3FD 200D 1F91D 200D 1F468 1F3FF
1F469 1F3FE 200D 1F91D 200D 1F468 1F3FB
1F469 1F3FE 200D 1F91D 200D 1F468 1F3FC
1F469 1F3FE 200D 1F91D 200D 1F468 1F3FD
1F46B 1F3FE
1F469 1F3FE 200D 1F91D 200D 1F468 1F3FF
1F469 1F3FF 200D 1F91D 200D 1F468 1F3FB
1F469 1F3FF 200D 1F91D 200D 1F468 1F3FC
1F469 1F3FF 200D 1F91D 200D 1F468 1F3FD
1F469 1F3FF 200D 1F91D 200D 1F468 1F3FE
1F46B 1F3FF
1F46C
1F46C 1F3FB
1F468 1F3FB 200D 1F91D 200D 1F468 1F3FC
1F468 1F3FB 200D 1F91D 200D 1F468 1F3FD
1F468 1F3FB 200D 1F91D 200D 1F468 1F3FE
1F468 1F3FB 200D 1F91D 200D 1F468 1F3FF
1F468 1F3FC 200D 1F91D 200D 1F468 1F3FB
1F46C 1F3FC
1F468 1F3FC 200D 1F91D 200D 1F468 1F3FD
1F468 1F3FC 200D 1F91D 200D 1F468 1F3FE
1F468 1F3FC 200D 1F91D 200D 1F468 1F3FF
1F468 1F3FD 200D 1F91D 200D 1F468 1F3FB
1F468 1F3FD 200D 1F91D 200D 1F468 1F3FC
1F46C 1F3FD
1F468 1F3FD 200D 1F91D 200D 1F468 1F3FE
1F468 1F3FD 200D 1F91D 200D 1F468 1F3FF
1F468 1F3FE 200D 1F91D 200D 1F468 1F3FB
1F468 1F3FE 200D 1F91D 200D 1F468 1F3FC
1F468 1F3FE 200D 1F91D 200D 1F468 1F3FD
1F46C 1F3FE
1F468 1F3FE 200D 1F91D 200D 1F468 1F3FF
1F468 1F3FF 200D 1F91D 200D 1F468 1F3FB
1F468 1F3FF 200D 1F91D 200D 1F468 1F3FC
1F468 1F3FF 200D 1F91D 200D 1F468 1F3FD
1F468 1F3FF 200D 1F91D 200D 1F468 1F3FE
1F46C 1F3FF
1F48F
1F48F 1F3FB
1F48F 1F3FC
1F48F 1F3FD
1F48F 1F3FE
1F48F 1F3FF
1F9D1 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FC
1F9D1 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FD
1F9D1 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FE
1F9D1 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FF
1F9D1 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FB
1F9D1 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FD
1F9D1 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FE
1F9D1 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FF
1F9D1 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FB
1F9D1 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FC
1F9D1 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FE
1F9D1 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FF
1F9D1 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FB
1F9D1 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FC
1F9D1 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FD
1F9D1 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FF
1F9D1 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FB
1F9D1 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FC
1F9D1 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FD
1F9D1 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F9D1 1F3FE
1F469 200D 2764 FE0F 200D 1F48B 200D 1F468
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F468 200D 2764 FE0F 200D 1F48B 200D 1F468
1F468 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F468 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F468 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F468 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F468 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F468 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F468 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F468 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F468 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F468 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F468 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F468 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F468 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F468 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F468 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F468 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F468 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F468 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F468 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F468 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F468 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FB
1F468 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FC
1F468 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FD
1F468 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FE
1F468 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F468 1F3FF
1F469 200D 2764 FE0F 200D 1F48B 200D 1F469
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FB
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FC
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FD
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FE
1F469 1F3FB 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FF
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FB
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FC
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FD
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FE
1F469 1F3FC 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FF
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FB
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FC
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FD
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FE
1F469 1F3FD 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FF
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FB
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FC
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FD
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FE
1F469 1F3FE 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FF
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FB
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FC
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FD
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FE
1F469 1F3FF 200D 2764 FE0F 200D 1F48B 200D 1F469 1F3FF
1F491
1F491 1F3FB
1F491 1F3FC
1F491 1F3FD
1F491 1F3FE
1F491 1F3FF
1F9D1 1F3FB 200D 2764 FE0F 200D 1F9D1 1F3FC
1F9D1 1F3FB 200D 2764 FE0F 200D 1F9D1 1F3FD
1F9D1 1F3FB 200D 2764 FE0F 200D 1F9D1 1F3FE
1F9D1 1F3FB 200D 2764 FE0F 200D 1F9D1 1F3FF
1F9D1 1F3FC 200D 2764 FE0F 200D 1F9D1 1F3FB
1F9D1 1F3FC 200D 2764 FE0F 200D 1F9D1 1F3FD
1F9D1 1F3FC 200D 2764 FE0F 200D 1F9D1 1F3FE
1F9D1 1F3FC 200D 2764 FE0F 200D 1F9D1 1F3FF
1F9D1 1F3FD 200D 2764 FE0F 200D 1F9D1 1F3FB
1F9D1 1F3FD 200D 2764 FE0F 200D 1F9D1 1F3FC
1F9D1 1F3FD 200D 2764 FE0F 200D 1F9D1 1F3FE
1F9D1 1F3FD 200D 2764 FE0F 200D 1F9D1 1F3FF
1F9D1 1F3FE 200D 2764 FE0F 200D 1F9D1 1F3FB
1F9D1 1F3FE 200D 2764 FE0F 200D 1F9D1 1F3FC
1F9D1 1F3FE 200D 2764 FE0F 200D 1F9D1 1F3FD
1F9D1 1F3FE 200D 2764 FE0F 200D 1F9D1 1F3FF
1F9D1 1F3FF 200D 2764 FE0F 200D 1F9D1 1F3FB
1F9D1 1F3FF 200D 2764 FE0F 200D 1F9D1 1F3FC
1F9D1 1F3FF 200D 2764 FE0F 200D 1F9D1 1F3FD
1F9D1 1F3FF 200D 2764 FE0F 200D 1F9D1 1F3FE
1F469 200D 2764 FE0F 200D 1F468
1F469 1F3FB 200D 2764 FE0F 200D 1F468 1F3FB
1F469 1F3FB 200D 2764 FE0F 200D 1F468 1F3FC
1F469 1F3FB 200D 2764 FE0F 200D 1F468 1F3FD
1F469 1F3FB 200D 2764 FE0F 200D 1F468 1F3FE
1F469 1F3FB 200D 2764 FE0F 200D 1F468 1F3FF
1F469 1F3FC 200D 2764 FE0F 200D 1F468 1F3FB
1F469 1F3FC 200D 2764 FE0F 200D 1F468 1F3FC
1F469 1F3FC 200D 2764 FE0F 200D 1F468 1F3FD
1F469 1F3FC 200D 2764 FE0F 200D 1F468 1F3FE
1F469 1F3FC 200D 2764 FE0F 200D 1F468 1F3FF
1F469 1F3FD 200D 2764 FE0F 200D 1F468 1F3FB
1F469 1F3FD 200D 2764 FE0F 200D 1F468 1F3FC
1F469 1F3FD 200D 2764 FE0F 200D 1F468 1F3FD
1F469 1F3FD 200D 2764 FE0F 200D 1F468 1F3FE
1F469 1F3FD 200D 2764 FE0F 200D 1F468 1F3FF
1F469 1F3FE 200D 2764 FE0F 200D 1F468 1F3FB
1F469 1F3FE 200D 2764 FE0F 200D 1F468 1F3FC
1F469 1F3FE 200D 2764 FE0F 200D 1F468 1F3FD
1F469 1F3FE 200D 2764 FE0F 200D 1F468 1F3FE
1F469 1F3FE 200D 2764 FE0F 200D 1F468 1F3FF
1F469 1F3FF 200D 2764 FE0F 200D 1F468 1F3FB
1F469 1F3FF 200D 2764 FE0F 200D 1F468 1F3FC
1F469 1F3FF 200D 2764 FE0F 200D 1F468 1F3FD
1F469 1F3FF 200D 2764 FE0F 200D 1F468 1F3FE
1F469 1F3FF 200D 2764 FE0F 200D 1F468 1F3FF
1F468 200D 2764 FE0F 200D 1F468
1F468 1F3FB 200D 2764 FE0F 200D 1F468 1F3FB
1F468 1F3FB 200D 2764 FE0F 200D 1F468 1F3FC
1F468 1F3FB 200D 2764 FE0F 200D 1F468 1F3FD
1F468 1F3FB 200D 2764 FE0F 200D 1F468 1F3FE
1F468 1F3FB 200D 2764 FE0F 200D 1F468 1F3FF
1F468 1F3FC 200D 2764 FE0F 200D 1F468 1F3FB
1F468 1F3FC 200D 2764 FE0F 200D 1F468 1F3FC
1F468 1F3FC 200D 2764 FE0F 200D 1F468 1F3FD
1F468 1F3FC 200D 2764 FE0F 200D 1F468 1F3FE
1F468 1F3FC 200D 2764 FE0F 200D 1F468 1F3FF
1F468 1F3FD 200D 2764 FE0F 200D 1F468 1F3FB
1F468 1F3FD 200D 2764 FE0F 200D 1F468 1F3FC
1F468 1F3FD 200D 2764 FE0F 200D 1F468 1F3FD
1F468 1F3FD 200D 2764 FE0F 200D 1F468 1F3FE
1F468 1F3FD 200D 2764 FE0F 200D 1F468 1F3FF
1F468 1F3FE 200D 2764 FE0F 200D 1F468 1F3FB
1F468 1F3FE 200D 2764 FE0F 200D 1F468 1F3FC
1F468 1F3FE 200D 2764 FE0F 200D 1F468 1F3FD
1F468 1F3FE 200D 2764 FE0F 200D 1F468 1F3FE
1F468 1F3FE 200D 2764 FE0F 200D 1F468 1F3FF
1F468 1F3FF 200D 2764 FE0F 200D 1F468 1F3FB
1F468 1F3FF 200D 2764 FE0F 200D 1F468 1F3FC
1F468 1F3FF 200D 2764 FE0F 200D 1F468 1F3FD
1F468 1F3FF 200D 2764 FE0F 200D 1F468 1F3FE
1F468 1F3FF 200D 2764 FE0F 200D 1F468 1F3FF
1F469 200D 2764 FE0F 200D 1F469
1F469 1F3FB 200D 2764 FE0F 200D 1F469 1F3FB
1F469 1F3FB 200D 2764 FE0F 200D 1F469 1F3FC
1F469 1F3FB 200D 2764 FE0F 200D 1F469 1F3FD
1F469 1F3FB 200D 2764 FE0F 200D 1F469 1F3FE
1F469 1F3FB 200D 2764 FE0F 200D 1F469 1F3FF
1F469 1F3FC 200D 2764 FE0F 200D 1F469 1F3FB
1F469 1F3FC 200D 2764 FE0F 200D 1F469 1F3FC
1F469 1F3FC 200D 2764 FE0F 200D 1F469 1F3FD
1F469 1F3FC 200D 2764 FE0F 200D 1F469 1F3FE
1F469 1F3FC 200D 2764 FE0F 200D 1F469 1F3FF
1F469 1F3FD 200D 2764 FE0F 200D 1F469 1F3FB
1F469 1F3FD 200D 2764 FE0F 200D 1F469 1F3FC
1F469 1F3FD 200D 2764 FE0F 200D 1F469 1F3FD
1F469 1F3FD 200D 2764 FE0F 200D 1F469 1F3FE
1F469 1F3FD 200D 2764 FE0F 200D 1F469 1F3FF
1F469 1F3FE 200D 2764 FE0F 200D 1F469 1F3FB
1F469 1F3FE 200D 2764 FE0F 200D 1F469 1F3FC
1F469 1F3FE 200D 2764 FE0F 200D 1F469 1F3FD
1F469 1F3FE 200D 2764 FE0F 200D 1F469 1F3FE
1F469 1F3FE 200D 2764 FE0F 200D 1F469 1F3FF
1F469 1F3FF 200D 2764 FE0F 200D 1F469 1F3FB
1F469 1F3FF 200D 2764 FE0F 200D 1F469 1F3FC
1F469 1F3FF 200D 2764 FE0F 200D 1F469 1F3FD
1F469 1F3FF 200D 2764 FE0F 200D 1F469 1F3FE
1F469 1F3FF 200D 2764 FE0F 200D 1F469 1F3FF
1F468 200D 1F469 200D 1F466
1F468 200D 1F469 200D 1F467
1F468 200D 1F469 200D 1F467 200D 1F466
1F468 200D 1F469 200D 1F466 200D 1F466
1F468 200D 1F469 200D 1F467 200D 1F467
1F468 200D 1F468 200D 1F466
1F468 200D 1F468 200D 1F467
1F468 200D 1F468 200D 1F467 200D 1F466
1F468 200D 1F468 200D 1F466 200D 1F466
1F468 200D 1F468 200D 1F467 200D 1F467
1F469 200D 1F469 200D 1F466
1F469 200D 1F469 200D 1F467
1F469 200D 1F469 200D 1F467 200D 1F466
1F469 200D 1F469 200D 1F466 200D 1F466
1F469 200D 1F469 200D 1F467 200D 1F467
1F468 200D 1F466
1F468 200D 1F466 200D 1F466
1F468 200D 1F467
1F468 200D 1F467 200D 1F466
1F468 200D 1F467 200D 1F467
1F469 200D 1F466
1F469 200D 1F466 200D 1F466
1F469 200D 1F467
1F469 200D 1F467 200D 1F466
1F469 200D 1F467 200D 1F467
1F5E3 FE0F
1F464
1F465
1FAC2
1F46A
1F9D1 200D 1F9D1 200D 1F9D2
1F9D1 200D 1F9D1 200D 1F9D2 200D 1F9D2
1F9D1 200D 1F9D2
1F9D1 200D 1F9D2 200D 1F9D2
1F463
1F435
1F412
1F98D
1F9A7
1F436
1F415
1F9AE
1F415 200D 1F9BA
1F429
1F43A
1F98A
1F99D
1F431
1F408
1F408 200D 2B1B
1F981
1F42F
1F405
1F406
1F434
1FACE
1FACF
1F40E
1F984
1F993
1F98C
1F9AC
1F42E
1F402
1F403
1F404
1F437
1F416
1F417
1F43D
1F40F
1F411
1F410
1F42A
1F42B
1F999
1F992
1F418
1F9A3
1F98F
1F99B
1F42D
1F401
1F400
1F439
1F430
1F407
1F43F FE0F
1F9AB
1F994
1F987
1F43B
1F43B 200D 2744 FE0F
1F428
1F43C
1F9A5
1F9A6
1F9A8
1F998
1F9A1
1F43E
1F983
1F414
1F413
1F423
1F424
1F425
1F426
1F427
1F54A FE0F
1F985
1F986
1F9A2
1F989
1F9A4
1FAB6
1F9A9
1F99A
1F99C
1FABD
1F426 200D 2B1B
1FABF
1F426 200D 1F525
1F438
1F40A
1F422
1F98E
1F40D
1F432
1F409
1F995
1F996
1F433
1F40B
1F42C
1F9AD
1F41F
1F420
1F421
1F988
1F419
1F41A
1FAB8
1FABC
1F40C
1F98B
1F41B
1F41C
1F41D
1FAB2
1F41E
1F997
1FAB3
1F577 FE0F
1F578 FE0F
1F982
1F99F
1FAB0
1FAB1
1F9A0
1F490
1F338
1F4AE
1FAB7
1F3F5 FE0F
1F339
1F940
1F33A
1F33B
1F33C
1F337
1FABB
1F331
1FAB4
1F332
1F333
1F334
1F335
1F33E
1F33F
2618 FE0F
1F340
1F341
1F342
1F343
1FAB9
1FABA
1F344
1F347
1F348
1F349
1F34A
1F34B
1F34B 200D 1F7E9
1F34C
1F34D
1F96D
1F34E
1F34F
1F350
1F351
1F352
1F353
1FAD0
1F95D
1F345
1FAD2
1F965
1F951
1F346
1F954
1F955
1F33D
1F336 FE0F
1FAD1
1F952
1F96C
1F966
1F9C4
1F9C5
1F95C
1FAD8
1F330
1FADA
1FADB
1F344 200D 1F7EB
1F35E
1F950
1F956
1FAD3
1F968
1F96F
1F95E
1F9C7
1F9C0
1F356
1F357
1F969
1F953
1F354
1F35F
1F355
1F32D
1F96A
1F32E
1F32F
1FAD4
1F959
1F9C6
1F95A
1F373
1F958
1F372
1FAD5
1F963
1F957
1F37F
1F9C8
1F9C2
1F96B
1F371
1F358
1F359
1F35A
1F35B
1F35C
1F35D
1F360
1F362
1F363
1F364
1F365
1F96E
1F361
1F95F
1F960
1F961
1F980
1F99E
1F990
1F991
1F9AA
1F366
1F367
1F368
1F369
1F36A
1F382
1F370
1F9C1
1F967
1F36B
1F36C
1F36D
1F36E
1F36F
1F37C
1F95B
2615
1FAD6
1F375
1F376
1F37E
1F377
1F378
1F379
1F37A
1F37B
1F942
1F943
1FAD7
1F964
1F9CB
1F9C3
1F9C9
1F9CA
1F962
1F37D FE0F
1F374
1F944
1F52A
1FAD9
1F3FA
1F30D
1F30E
1F30F
1F310
1F5FA FE0F
1F5FE
1F9ED
1F3D4 FE0F
26F0 FE0F
1F30B
1F5FB
1F3D5 FE0F
1F3D6 FE0F
1F3DC FE0F
1F3DD FE0F
1F3DE FE0F
1F3DF FE0F
1F3DB FE0F
1F3D7 FE0F
1F9F1
1FAA8
1FAB5
1F6D6
1F3D8 FE0F
1F3DA FE0F
1F3E0
1F3E1
1F3E2
1F3E3
1F3E4
1F3E5
1F3E6
1F3E8
1F3E9
1F3EA
1F3EB
1F3EC
1F3ED
1F3EF
1F3F0
1F492
1F5FC
1F5FD
26EA
1F54C
1F6D5
1F54D
26E9 FE0F
1F54B
26F2
26FA
1F301
1F303
1F3D9 FE0F
1F304
1F305
1F306
1F307
1F309
2668 FE0F
1F3A0
1F6DD
1F3A1
1F3A2
1F488
1F3AA
1F682
1F683
1F684
1F685
1F686
1F687
1F688
1F689
1F68A
1F69D
1F69E
1F68B
1F68C
1F68D
1F68E
1F690
1F691
1F692
1F693
1F694
1F695
1F696
1F697
1F698
1F699
1F6FB
1F69A
1F69B
1F69C
1F3CE FE0F
1F3CD FE0F
1F6F5
1F9BD
1F9BC
1F6FA
1F6B2
1F6F4
1F6F9
1F6FC
1F68F
1F6E3 FE0F
1F6E4 FE0F
1F6E2 FE0F
26FD
1F6DE
1F6A8
1F6A5
1F6A6
1F6D1
1F6A7
2693
1F6DF
26F5
1F6F6
1F6A4
1F6F3 FE0F
26F4 FE0F
1F6E5 FE0F
1F6A2
2708 FE0F
1F6E9 FE0F
1F6EB
1F6EC
1FA82
1F4BA
1F681
1F69F
1F6A0
1F6A1
1F6F0 FE0F
1F680
1F6F8
1F6CE FE0F
1F9F3
231B
23F3
231A
23F0
23F1 FE0F
23F2 FE0F
1F570 FE0F
1F55B
1F567
1F550
1F55C
1F551
1F55D
1F552
1F55E
1F553
1F55F
1F554
1F560
1F555
1F561
1F556
1F562
1F557
1F563
1F558
1F564
1F559
1F565
1F55A
1F566
1F311
1F312
1F313
1F314
1F315
1F316
1F317
1F318
1F319
1F31A
1F31B
1F31C
1F321 FE0F
2600 FE0F
1F31D
1F31E
1FA90
2B50
1F31F
1F320
1F30C
2601 FE0F
26C5
26C8 FE0F
1F324 FE0F
1F325 FE0F
1F326 FE0F
1F327 FE0F
1F328 FE0F
1F329 FE0F
1F32A FE0F
1F32B FE0F
1F32C FE0F
1F300
1F308
1F302
2602 FE0F
2614
26F1 FE0F
26A1
2744 FE0F
2603 FE0F
26C4
2604 FE0F
1F525
1F4A7
1F30A
1F383
1F384
1F386
1F387
1F9E8
2728
1F388
1F389
1F38A
1F38B
1F38D
1F38E
1F38F
1F390
1F391
1F9E7
1F380
1F381
1F397 FE0F
1F39F FE0F
1F3AB
1F396 FE0F
1F3C6
1F3C5
1F947
1F948
1F949
26BD
26BE
1F94E
1F3C0
1F3D0
1F3C8
1F3C9
1F3BE
1F94F
1F3B3
1F3CF
1F3D1
1F3D2
1F94D
1F3D3
1F3F8
1F94A
1F94B
1F945
26F3
26F8 FE0F
1F3A3
1F93F
1F3BD
1F3BF
1F6F7
1F94C
1F3AF
1FA80
1FA81
1F52B
1F3B1
1F52E
1FA84
1F3AE
1F579 FE0F
1F3B0
1F3B2
1F9E9
1F9F8
1FA85
1FAA9
1FA86
2660 FE0F
2665 FE0F
2666 FE0F
2663 FE0F
265F FE0F
1F0CF
1F004
1F3B4
1F3AD
1F5BC FE0F
1F3A8
1F9F5
1FAA1
1F9F6
1FAA2
1F453
1F576 FE0F
1F97D
1F97C
1F9BA
1F454
1F455
1F456
1F9E3
1F9E4
1F9E5
1F9E6
1F457
1F458
1F97B
1FA71
1FA72
1FA73
1F459
1F45A
1FAAD
1F45B
1F45C
1F45D
1F6CD FE0F
1F392
1FA74
1F45E
1F45F
1F97E
1F97F
1F460
1F461
1FA70
1F462
1FAAE
1F451
1F452
1F3A9
1F393
1F9E2
1FA96
26D1 FE0F
1F4FF
1F484
1F48D
1F48E
1F507
1F508
1F509
1F50A
1F4E2
1F4E3
1F4EF
1F514
1F515
1F3BC
1F3B5
1F3B6
1F399 FE0F
1F39A FE0F
1F39B FE0F
1F3A4
1F3A7
1F4FB
1F3B7
1FA97
1F3B8
1F3B9
1F3BA
1F3BB
1FA95
1F941
1FA98
1FA87
1FA88
1F4F1
1F4F2
260E FE0F
1F4DE
1F4DF
1F4E0
1F50B
1FAAB
1F50C
1F4BB
1F5A5 FE0F
1F5A8 FE0F
2328 FE0F
1F5B1 FE0F
1F5B2 FE0F
1F4BD
1F4BE
1F4BF
1F4C0
1F9EE
1F3A5
1F39E FE0F
1F4FD FE0F
1F3AC
1F4FA
1F4F7
1F4F8
1F4F9
1F4FC
1F50D
1F50E
1F56F FE0F
1F4A1
1F526
1F3EE
1FA94
1F4D4
1F4D5
1F4D6
1F4D7
1F4D8
1F4D9
1F4DA
1F4D3
1F4D2
1F4C3
1F4DC
1F4C4
1F4F0
1F5DE FE0F
1F4D1
1F516
1F3F7 FE0F
1F4B0
1FA99
1F4B4
1F4B5
1F4B6
1F4B7
1F4B8
1F4B3
1F9FE
1F4B9
2709 FE0F
1F4E7
1F4E8
1F4E9
1F4E4
1F4E5
1F4E6
1F4EB
1F4EA
1F4EC
1F4ED
1F4EE
1F5F3 FE0F
270F FE0F
2712 FE0F
1F58B FE0F
1F58A FE0F
1F58C FE0F
1F58D FE0F
1F4DD
1F4BC
1F4C1
1F4C2
1F5C2 FE0F
1F4C5
1F4C6
1F5D2 FE0F
1F5D3 FE0F
1F4C7
1F4C8
1F4C9
1F4CA
1F4CB
1F4CC
1F4CD
1F4CE
1F587 FE0F
1F4CF
1F4D0
2702 FE0F
1F5C3 FE0F
1F5C4 FE0F
1F5D1 FE0F
1F512
1F513
1F50F
1F510
1F511
1F5DD FE0F
1F528
1FA93
26CF FE0F
2692 FE0F
1F6E0 FE0F
1F5E1 FE0F
2694 FE0F
1F4A3
1FA83
1F3F9
1F6E1 FE0F
1FA9A
1F527
1FA9B
1F529
2699 FE0F
1F5DC FE0F
2696 FE0F
1F9AF
1F517
26D3 FE0F 200D 1F4A5
26D3 FE0F
1FA9D
1F9F0
1F9F2
1FA9C
2697 FE0F
1F9EA
1F9EB
1F9EC
1F52C
1F52D
1F4E1
1F489
1FA78
1F48A
1FA79
1FA7C
1FA7A
1FA7B
1F6AA
1F6D7
1FA9E
1FA9F
1F6CF FE0F
1F6CB FE0F
1FA91
1F6BD
1FAA0
1F6BF
1F6C1
1FAA4
1FA92
1F9F4
1F9F7
1F9F9
1F9FA
1F9FB
1FAA3
1F9FC
1FAE7
1FAA5
1F9FD
1F9EF
1F6D2
1F6AC
26B0 FE0F
1FAA6
26B1 FE0F
1F9FF
1FAAC
1F5FF
1FAA7
1FAAA
1F3E7
1F6AE
1F6B0
267F
1F6B9
1F6BA
1F6BB
1F6BC
1F6BE
1F6C2
1F6C3
1F6C4
1F6C5
26A0 FE0F
1F6B8
26D4
1F6AB
1F6B3
1F6AD
1F6AF
1F6B1
1F6B7
1F4F5
1F51E
2622 FE0F
2623 FE0F
2B06 FE0F
2197 FE0F
27A1 FE0F
2198 FE0F
2B07 FE0F
2199 FE0F
2B05 FE0F
2196 FE0F
2195 FE0F
2194 FE0F
21A9 FE0F
21AA FE0F
2934 FE0F
2935 FE0F
1F503
1F504
1F519
1F51A
1F51B
1F51C
1F51D
1F6D0
269B FE0F
1F549 FE0F
2721 FE0F
2638 FE0F
262F FE0F
271D FE0F
2626 FE0F
262A FE0F
262E FE0F
1F54E
1F52F
1FAAF
2648
2649
264A
264B
264C
264D
264E
264F
2650
2651
2652
2653
26CE
1F500
1F501
1F502
25B6 FE0F
23E9
23ED FE0F
23EF FE0F
25C0 FE0F
23EA
23EE FE0F
1F53C
23EB
1F53D
23EC
23F8 FE0F
23F9 FE0F
23FA FE0F
23CF FE0F
1F3A6
1F505
1F506
1F4F6
1F6DC
1F4F3
1F4F4
2640 FE0F
2642 FE0F
26A7 FE0F
2716 FE0F
2795
2796
2797
1F7F0
267E FE0F
203C FE0F
2049 FE0F
2753
2754
2755
2757
3030 FE0F
1F4B1
1F4B2
2695 FE0F
267B FE0F
269C FE0F
1F531
1F4DB
1F530
2B55
2705
2611 FE0F
2714 FE0F
274C
274E
27B0
27BF
303D FE0F
2733 FE0F
2734 FE0F
2747 FE0F
00A9 FE0F
00AE FE0F
2122 FE0F
0023 FE0F 20E3
002A FE0F 20E3
0030 FE0F 20E3
0031 FE0F 20E3
0032 FE0F 20E3
0033 FE0F 20E3
0034 FE0F 20E3
0035 FE0F 20E3
0036 FE0F 20E3
0037 FE0F 20E3
0038 FE0F 20E3
0039 FE0F 20E3
1F51F
1F520
1F521
1F522
1F523
1F524
1F170 FE0F
1F18E
1F171 FE0F
1F191
1F192
1F193
2139 FE0F
1F194
24C2 FE0F
1F195
1F196
1F17E FE0F
1F197
1F17F FE0F
1F198
1F199
1F19A
1F201
1F202 FE0F
1F237 FE0F
1F236
1F22F
1F250
1F239
1F21A
1F232
1F251
1F238
1F234
1F233
3297 FE0F
3299 FE0F
1F23A
1F235
1F534
1F7E0
1F7E1
1F7E2
1F535
1F7E3
1F7E4
26AB
26AA
1F7E5
1F7E7
1F7E8
1F7E9
1F7E6
1F7EA
1F7EB
2B1B
2B1C
25FC FE0F
25FB FE0F
25FE
25FD
25AA FE0F
25AB FE0F
1F536
1F537
1F538
1F539
1F53A
1F53B
1F4A0
1F518
1F533
1F532
1F3C1
1F6A9
1F38C
1F3F4
1F3F3 FE0F
1F3F3 FE0F 200D 1F308
1F3F3 FE0F 200D 26A7 FE0F
1F3F4 200D 2620 FE0F
1F1E6 1F1E8
1F1E6 1F1E9
1F1E6 1F1EA
1F1E6 1F1EB
1F1E6 1F1EC
1F1E6 1F1EE
1F1E6 1F1F1
1F1E6 1F1F2
1F1E6 1F1F4
1F1E6 1F1F6
1F1E6 1F1F7
1F1E6 1F1F8
1F1E6 1F1F9
1F1E6 1F1FA
1F1E6 1F1FC
1F1E6 1F1FD
1F1E6 1F1FF
1F1E7 1F1E6
1F1E7 1F1E7
1F1E7 1F1E9
1F1E7 1F1EA
1F1E7 1F1EB
1F1E7 1F1EC
1F1E7 1F1ED
1F1E7 1F1EE
1F1E7 1F1EF
1F1E7 1F1F1
1F1E7 1F1F2
1F1E7 1F1F3
1F1E7 1F1F4
1F1E7 1F1F6
1F1E7 1F1F7
1F1E7 1F1F8
1F1E7 1F1F9
1F1E7 1F1FB
1F1E7 1F1FC
1F1E7 1F1FE
1F1E7 1F1FF
1F1E8 1F1E6
1F1E8 1F1E8
1F1E8 1F1E9
1F1E8 1F1EB
1F1E8 1F1EC
1F1E8 1F1ED
1F1E8 1F1EE
1F1E8 1F1F0
1F1E8 1F1F1
1F1E8 1F1F2
1F1E8 1F1F3
1F1E8 1F1F4
1F1E8 1F1F5
1F1E8 1F1F7
1F1E8 1F1FA
1F1E8 1F1FB
1F1E8 1F1FC
1F1E8 1F1FD
1F1E8 1F1FE
1F1E8 1F1FF
1F1E9 1F1EA
1F1E9 1F1EC
1F1E9 1F1EF
1F1E9 1F1F0
1F1E9 1F1F2
1F1E9 1F1F4
1F1E9 1F1FF
1F1EA 1F1E6
1F1EA 1F1E8
1F1EA 1F1EA
1F1EA 1F1EC
1F1EA 1F1ED
1F1EA 1F1F7
1F1EA 1F1F8
1F1EA 1F1F9
1F1EA 1F1FA
1F1EB 1F1EE
1F1EB 1F1EF
1F1EB 1F1F0
1F1EB 1F1F2
1F1EB 1F1F4
1F1EB 1F1F7
1F1EC 1F1E6
1F1EC 1F1E7
1F1EC 1F1E9
1F1EC 1F1EA
1F1EC 1F1EB
1F1EC 1F1EC
1F1EC 1F1ED
1F1EC 1F1EE
1F1EC 1F1F1
1F1EC 1F1F2
1F1EC 1F1F3
1F1EC 1F1F5
1F1EC 1F1F6
1F1EC 1F1F7
1F1EC 1F1F8
1F1EC 1F1F9
1F1EC 1F1FA
1F1EC 1F1FC
1F1EC 1F1FE
1F1ED 1F1F0
1F1ED 1F1F2
1F1ED 1F1F3
1F1ED 1F1F7
1F1ED 1F1F9
1F1ED 1F1FA
1F1EE 1F1E8
1F1EE 1F1E9
1F1EE 1F1EA
1F1EE 1F1F1
1F1EE 1F1F2
1F1EE 1F1F3
1F1EE 1F1F4
1F1EE 1F1F6
1F1EE 1F1F7
1F1EE 1F1F8
1F1EE 1F1F9
1F1EF 1F1EA
1F1EF 1F1F2
1F1EF 1F1F4
1F1EF 1F1F5
1F1F0 1F1EA
1F1F0 1F1EC
1F1F0 1F1ED
1F1F0 1F1EE
1F1F0 1F1F2
1F1F0 1F1F3
1F1F0 1F1F5
1F1F0 1F1F7
1F1F0 1F1FC
1F1F0 1F1FE
1F1F0 1F1FF
1F1F1 1F1E6
1F1F1 1F1E7
1F1F1 1F1E8
1F1F1 1F1EE
1F1F1 1F1F0
1F1F1 1F1F7
1F1F1 1F1F8
1F1F1 1F1F9
1F1F1 1F1FA
1F1F1 1F1FB
1F1F1 1F1FE
1F1F2 1F1E6
1F1F2 1F1E8
1F1F2 1F1E9
1F1F2 1F1EA
1F1F2 1F1EB
1F1F2 1F1EC
1F1F2 1F1ED
1F1F2 1F1F0
1F1F2 1F1F1
1F1F2 1F1F2
1F1F2 1F1F3
1F1F2 1F1F4
1F1F2 1F1F5
1F1F2 1F1F6
1F1F2 1F1F7
1F1F2 1F1F8
1F1F2 1F1F9
1F1F2 1F1FA
1F1F2 1F1FB
1F1F2 1F1FC
1F1F2 1F1FD
1F1F2 1F1FE
1F1F2 1F1FF
1F1F3 1F1E6
1F1F3 1F1E8
1F1F3 1F1EA
1F1F3 1F1EB
1F1F3 1F1EC
1F1F3 1F1EE
1F1F3 1F1F1
1F1F3 1F1F4
1F1F3 1F1F5
1F1F3 1F1F7
1F1F3 1F1FA
1F1F3 1F1FF
1F1F4 1F1F2
1F1F5 1F1E6
1F1F5 1F1EA
1F1F5 1F1EB
1F1F5 1F1EC
1F1F5 1F1ED
1F1F5 1F1F0
1F1F5 1F1F1
1F1F5 1F1F2
1F1F5 1F1F3
1F1F5 1F1F7
1F1F5 1F1F8
1F1F5 1F1F9
1F1F5 1F1FC
1F1F5 1F1FE
1F1F6 1F1E6
1F1F7 1F1EA
1F1F7 1F1F4
1F1F7 1F1F8
1F1F7 1F1FA
1F1F7 1F1FC
1F1F8 1F1E6
1F1F8 1F1E7
1F1F8 1F1E8
1F1F8 1F1E9
1F1F8 1F1EA
1F1F8 1F1EC
1F1F8 1F1ED
1F1F8 1F1EE
1F1F8 1F1EF
1F1F8 1F1F0
1F1F8 1F1F1
1F1F8 1F1F2
1F1F8 1F1F3
1F1F8 1F1F4
1F1F8 1F1F7
1F1F8 1F1F8
1F1F8 1F1F9
1F1F8 1F1FB
1F1F8 1F1FD
1F1F8 1F1FE
1F1F8 1F1FF
1F1F9 1F1E6
1F1F9 1F1E8
1F1F9 1F1E9
1F1F9 1F1EB
1F1F9 1F1EC
1F1F9 1F1ED
1F1F9 1F1EF
1F1F9 1F1F0
1F1F9 1F1F1
1F1F9 1F1F2
1F1F9 1F1F3
1F1F9 1F1F4
1F1F9 1F1F7
1F1F9 1F1F9
1F1F9 1F1FB
1F1F9 1F1FC
1F1F9 1F1FF
1F1FA 1F1E6
1F1FA 1F1EC
1F1FA 1F1F2
1F1FA 1F1F3
1F1FA 1F1F8
1F1FA 1F1FE
1F1FA 1F1FF
1F1FB 1F1E6
1F1FB 1F1E8
1F1FB 1F1EA
1F1FB 1F1EC
1F1FB 1F1EE
1F1FB 1F1F3
1F1FB 1F1FA
1F1FC 1F1EB
1F1FC 1F1F8
1F1FD 1F1F0
1F1FE 1F1EA
1F1FE 1F1F9
1F1FF 1F1E6
1F1FF 1F1F2
1F1FF 1F1FC
1F3F4 E0067 E0062 E0065 E006E E0067 E007F
1F3F4 E0067 E0062 E0073 E0063 E0074 E007F
1F3F4 E0067 E0062 E0077 E006C E0073 E007F
"""
}
