import CryptoKit
import Foundation

/// Composition d'un message v2 (D.7, D.8) : `fk` et nonce tirés ici, signature
/// par le coffre de l'appareil, puis relue avec sa clé publique.
enum E2EEV2MessageComposerV2 {
    static func compose(
        payload: Data,
        conversationId: String,
        clientRequestId: String,
        ttlSeconds: Int,
        epoch: E2EEV2StoredEpochKey,
        device: E2EEV2DeviceDescriptor,
        fk: Data,
        nonce: Data,
        notifyUserId: String = "",
        marked: Bool = false,
        sign: (Data) throws -> Data
    ) throws -> E2EEV2SignedMessageEnvelopeV2 {
        let parsed = try E2EEV2ContentPayloadV2.parse(payload)
        guard epoch.conversationId == conversationId,
              try E2EEV2EpochCrypto.keyCommitment(epoch.epochKey) == epoch.keyCommitmentB64,
              let publicKeyData = Data(base64Encoded: device.publicSigningKeyB64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw E2EEV2MessageV2Error.invalidContext
        }
        // Une réaction part en v3, en annotation (D.16) ; le reste en v2, sauf
        // sous une époque marquée : tout en v3, en `message` (E2EE-AUTO §7.3, révision 15).
        // Révision 17 : les blobs cités, dans l'ordre du contenu (règle (a)), et la livraison de la nature.
        var blobIds: [String] = []
        if case .r17(let body) = parsed.body { blobIds = body.blobIds }
        var context = E2EEV2MessageContextV2(
            conversationId: conversationId, epochNumber: epoch.epochNumber, senderDeviceId: device.deviceId,
            clientRequestId: clientRequestId, counter: parsed.counter, ttlSeconds: ttlSeconds, encryptedBlobIds: blobIds
        )
        if case .r17(let body) = parsed.body {
            context.envelopeVersion = E2EEV2MessageCryptoV2.annotationEnvelopeVersion
            context.delivery = body.delivery
        } else if case .reaction = parsed.body {
            context.envelopeVersion = E2EEV2MessageCryptoV2.annotationEnvelopeVersion
            context.delivery = .annotation
            context.notifyUserId = notifyUserId
        } else if marked {
            context.envelopeVersion = E2EEV2MessageCryptoV2.annotationEnvelopeVersion
            context.delivery = .message
        }
        let envelope = try E2EEV2MessageCryptoV2.encrypt(
            payload: payload, fk: fk, epochKey: epoch.epochKey, nonce: nonce, context: context
        )
        var canonical = try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope)
        defer { canonical.resetBytes(in: 0..<canonical.count) }
        let signatureB64 = try sign(canonical).base64EncodedString()
        try E2EEV2MessageCryptoV2.verifySignature(
            context: context, envelope: envelope, signatureDerB64: signatureB64, senderSigningKey: publicKey
        )
        return .init(envelope: envelope, senderSignatureB64: signatureB64)
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw E2EEV2DeviceIdentityError.randomGenerationFailed }
        return bytes
    }
}

enum E2EEV2MessageSendResultV2: Sendable, Equatable {
    case sent(E2EEV2MessageReceiptV2, messageRef: String)
    /// Une version antérieure de ce message, signée par cet appareil et de même
    /// charge, a déjà été acceptée (`409 E2EE_MESSAGE_CONFLICT`) : il est remis,
    /// son accusé se relira dans la liste (E.3).
    case alreadyAccepted(messageRef: String)
    /// Pas d'époque courante vérifiée, ou le serveur en connaît une plus
    /// récente : synchroniser la conversation, puis réessayer.
    case needsEpoch
    /// L'époque courante doit tourner avant tout envoi (§3.3).
    case needsRotation
    /// Des membres dont l'identité n'est pas crue : rien n'est envoyé tant que
    /// l'utilisateur n'a pas accepté leur nouveau numéro (§2.4).
    case membersNotTrusted([String])
    /// La conversation ne peut pas recevoir ce contenu (§12) : un membre doit
    /// mettre à jour SignalQuest. Rien n'est envoyé, le message reste gardé
    /// (jamais de repli en clair). Ce qui manque, trié.
    case capabilityMissing([String])
    case failure(E2EEV2TransportFailure)
}

enum E2EEV2ScheduleResultV2: Sendable, Equatable {
    case scheduled(E2EEAutoScheduledMessage.Ack)
    /// Pas d'époque courante vérifiée, ou le serveur en connaît une plus récente.
    case needsEpoch
    /// L'époque courante doit tourner avant tout envoi (§3.3).
    case needsRotation
    case membersNotTrusted([String])
    case failure(E2EEV2TransportFailure)
}

/// Programmé chiffré tel que `GET …/scheduled` le rend (E2EE-AUTO §7.8 F, point 4).
struct E2EEAutoScheduledMessage: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case scheduled
        /// Époque changée ou compromise : à rechiffrer par un appareil actif du compte.
        case needsReencrypt
        /// `MEMBER_LEFT`, `DEVICE_REVOKED`, `REENCRYPT_EXPIRED`, `INVALID`, ou une valeur inconnue.
        case failed(reason: String?)

        init?(_ raw: String?, failureReason: String?) {
            switch raw {
            case "SCHEDULED"?: self = .scheduled
            case "NEEDS_REENCRYPT"?: self = .needsReencrypt
            case "FAILED"?: self = .failed(reason: failureReason)
            default: return nil
            }
        }
    }

    /// Réponse d'un dépôt : `201` du `POST` ou vue du `PUT`.
    struct Ack: Equatable, Sendable {
        let scheduledId: String
        let status: Status
        let sendAt: Date

        static func parse(_ data: Data) -> Ack? {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = root["scheduledId"] as? String, isScheduledId(id),
                  let status = Status(root["status"] as? String, failureReason: root["failureReason"] as? String),
                  let sendAt = (root["sendAt"] as? String).flatMap(E2EEAutoScheduledMessage.date) else { return nil }
            return Ack(scheduledId: id, status: status, sendAt: sendAt)
        }
    }

    let scheduledId: String
    let status: Status
    let sendAt: Date
    let signed: E2EEV2SignedMessageEnvelopeV2
    /// L'appareil qui a signé le corps stocké, lié par l'AAD sans être dans l'enveloppe.
    let senderDeviceId: String

    var clientRequestId: String { signed.envelope.clientRequestId }

    /// Un élément de la liste ; nil pour un programmé de l'ancien format ou illisible.
    static func parse(_ object: [String: Any]) -> E2EEAutoScheduledMessage? {
        guard let id = object["scheduledId"] as? String, isScheduledId(id),
              let status = Status(object["status"] as? String, failureReason: object["failureReason"] as? String),
              let sendAt = (object["sendAt"] as? String).flatMap(date),
              let sender = object["senderDeviceId"] as? String, E2EEV2Canonical.isOpaque(sender),
              let message = object["e2eeMessage"], JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              let value = try? E2EEV2CanonicalJSON.parseStrict(data),
              let signed = E2EEV2SignedMessageEnvelopeV2.parse(value),
              signed.envelope.envelopeVersion == E2EEV2MessageCryptoV2.annotationEnvelopeVersion,
              signed.envelope.delivery == .message else { return nil }
        return E2EEAutoScheduledMessage(scheduledId: id, status: status, sendAt: sendAt, signed: signed, senderDeviceId: sender)
    }

    static func isScheduledId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z"#, options: .regularExpression) != nil
    }

    /// Corps exact `{ "e2eeMessage", "sendAt"? }` (point 1 et 3), signé A.2 tel quel.
    static func requestBody(_ signed: E2EEV2SignedMessageEnvelopeV2, sendAt: Date?) -> Data {
        var fields: [String: E2EEV2JSON] = ["e2eeMessage": signed.json]
        if let sendAt { fields["sendAt"] = .string(isoFormatter.string(from: sendAt)) }
        return E2EEV2CanonicalJSON.encode(.object(fields))
    }

    static func date(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Envoi d'un message texte v2 (§4, E.3). Le compteur est réservé, la charge
/// et `fk` gardés avant le premier envoi ; le même `clientRequestId` renvoie
/// ensuite la même enveloppe, à l'octet, tant que son époque est la courante.
/// Rechiffrée sous une époque plus récente, elle garde son identité, son
/// compteur, sa charge et son `frankTag` : les destinataires la reconnaissent
/// comme un doublon, jamais comme une équivoque (§4.2).
final class E2EEV2MessageSenderV2: @unchecked Sendable {
    struct Draft: Equatable, Sendable {
        let body: E2EEV2ContentPayloadV2.Body
        let replyToRef: String?
        let mentions: [String]
        let ttlSeconds: Int
        /// Réaction `ADD` au message d'un autre membre : son auteur, seul notifié (D.16).
        var notifyUserId = ""
    }

    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let keyStore: E2EEV2EpochKeyStore
    private let stateStore: E2EEV2ConversationStateStore
    private let expectedSession: LocalAccountSession?
    private let now: @Sendable () -> Date

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        expectedSession: LocalAccountSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.stateStore = stateStore
        self.expectedSession = expectedSession
        self.now = now
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    /// `membership` est l'état en tête de la chaîne relue ; `devices`, les
    /// appareils certifiés des membres ; `messageCount`, les messages acceptés
    /// sous l'époque courante (registre). Pour un envoi déjà préparé, `draft`
    /// est ignoré : c'est la charge gardée qui part.
    func send(
        _ draft: Draft,
        conversationId: String,
        clientRequestId: String,
        membership: E2EEV2MembershipState,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String,
        messageCount: Int = 0
    ) async -> E2EEV2MessageSendResultV2 {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId), E2EEV2MessageCryptoV2.isClientRequestId(clientRequestId) else {
            return .failure(localError("invalid-e2ee-send-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let device: E2EEV2DeviceDescriptor
        let current: E2EEV2ConversationStateStore.CurrentEpoch?
        do {
            guard let loaded = try identityStore.load(ownerNamespace: ownerNamespace),
                  try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) != nil else {
                return .failure(localError("e2ee-send-state-unavailable"))
            }
            device = loaded
            current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
            // Déjà remis : le même accusé, jamais un second envoi.
            if let receipt = try stateStore.sentReceipt(
                conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace
            ) {
                return .sent(receipt, messageRef: messageRef(conversationId, device, clientRequestId))
            }
        } catch {
            return .failure(localError("e2ee-send-state-unavailable"))
        }
        guard let current, membership.changeNumber >= current.membershipChangeNumber else { return .needsEpoch }
        guard membership.members.contains(ownUserId) else {
            forget(conversationId, clientRequestId, ownerNamespace)
            return .failure(localError("e2ee-sender-not-member"))
        }
        guard E2EEV2RotationPolicy.reasons(
            current: current, membership: membership, devices: devices, nowMs: nowMs, messageCount: messageCount
        ).isEmpty else { return .needsRotation }
        // §12 : l'émetteur n'envoie pas ce que l'intersection ne contient pas.
        // Sous une époque marquée, la version minimale en tient lieu (E2EE-AUTO §7.3).
        let missing = current.e2eeAuto == true ? [] : Self.missingCapabilities(
            draft, devices: devices, members: membership.members, excludesWeb: membership.excludesWeb, nowMs: nowMs
        )
        guard missing.isEmpty else { return .capabilityMissing(missing) }

        // Préparé sous verrou : deux appels pour un même message ne signent
        // jamais deux enveloppes, ni ne réservent deux compteurs.
        let outgoing: E2EEV2ConversationStateStore.PendingSend
        do {
            switch try Self.lock.withLock({
                try pendingEnvelope(
                    draft, conversationId: conversationId, clientRequestId: clientRequestId, current: current, device: device,
                    ownerNamespace: ownerNamespace, nowMs: nowMs
                )
            }) {
            case .delivered(let receipt):
                return .sent(receipt, messageRef: messageRef(conversationId, device, clientRequestId))
            case .pending(let pending):
                outgoing = pending
            }
        } catch let failure as SendFailure {
            return .failure(localError(failure.reason))
        } catch {
            return .failure(localError("e2ee-send-preparation-failed"))
        }

        switch await transport.bound(to: session).postJSON(
            path: "/api/e2ee/v2/conversations/\(conversationId)/messages", body: Data(outgoing.wire.utf8),
            expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .success(let data, _, _):
            guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
            guard let receipt = E2EEV2MessageReceiptV2.parse(data, clientRequestId: clientRequestId) else {
                return .failure(localError("invalid-e2ee-message-receipt"))
            }
            try? stateStore.completeSend(receipt, conversationId: conversationId, ownerNamespace: ownerNamespace)
            return .sent(receipt, messageRef: messageRef(conversationId, device, clientRequestId))
        case .failure(let error) where error.statusCode == 409 && error.code == "E2EE_MESSAGE_CONFLICT":
            // Seul cet appareil signe cette identité : l'enveloppe acceptée est
            // une version antérieure du même message, de même charge.
            forget(conversationId, clientRequestId, ownerNamespace)
            return .alreadyAccepted(messageRef: messageRef(conversationId, device, clientRequestId))
        case .failure(let error) where error.statusCode == 409 && error.code == "E2EE_CAPABILITY_MISSING":
            // Le serveur voit ce que l'appareil n'a pas su voir : rien ne part, le message reste gardé.
            var missing: [String] = []
            if case .array(let values)? = error.details?["missing"] {
                missing = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
            }
            return .capabilityMissing(missing.isEmpty ? ["intersection"] : missing.sorted())
        case .failure(let error) where error.statusCode == 409
            && (error.code == "E2EE_EPOCH_STALE" || error.code == "E2EE_MEMBERSHIP_STALE"):
            // Le serveur connaît une époque ou un état plus récent : synchroniser,
            // puis l'envoi suivant rechiffre sous l'époque vérifiée.
            return .needsEpoch
        case .failure(let error) where error.kind == .permanent:
            forget(conversationId, clientRequestId, ownerNamespace)
            return .failure(error)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static let lock = NSLock()

    /// Ce que l'intersection des appareils comptés (§12) ne contient pas pour
    /// ce message : version d'enveloppe, de charge, ou son type ; `intersection`
    /// si elle est indisponible.
    static func missingCapabilities(
        _ draft: Draft, devices: E2EEV2CertifiedDeviceSet, members: Set<String>, excludesWeb: Bool, nowMs: Int64
    ) -> [String] {
        let scoped = E2EEV2CertifiedDeviceSet(
            devicesByUser: devices.devicesByUser.filter { members.contains($0.key) },
            refusals: devices.refusals.filter { members.contains($0.key) }
        )
        guard let intersection = scoped.capabilityIntersection(nowMs: nowMs, excludesWeb: excludesWeb) else { return ["intersection"] }
        var missing: [String] = []
        if !intersection.envelopeVersions.contains("2") { missing.append("envelopeVersion") }
        if !intersection.payloadVersions.contains("2") { missing.append("payloadVersion") }
        if !intersection.kinds.contains(draft.body.kind) { missing.append(draft.body.kind) }
        // D.16 : une réaction exige l'enveloppe v3 et la fonction, sans repli.
        if case .reaction = draft.body {
            if !intersection.envelopeVersions.contains("3") { missing.append("envelopeVersions:3") }
            if !intersection.features.contains("reactions") { missing.append("reactions") }
        }
        return missing.sorted()
    }

    private struct SendFailure: Error {
        let reason: String
    }

    private enum Outgoing {
        /// Remis entre-temps par un autre appel : son accusé.
        case delivered(E2EEV2MessageReceiptV2)
        case pending(E2EEV2ConversationStateStore.PendingSend)
    }

    /// L'enveloppe gardée, renvoyée telle quelle sous l'époque courante ; sinon
    /// rechiffrée sous l'époque vérifiée avant de partir, avec la même identité,
    /// le même compteur, la même charge et le même `fk` (E.3). Jamais envoyée
    /// sous une époque que l'appareil sait remplacée. Sans enveloppe gardée :
    /// compteur réservé, charge et `fk` tirés, puis gardés avant tout envoi.
    private func pendingEnvelope(
        _ draft: Draft,
        conversationId: String,
        clientRequestId: String,
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        device: E2EEV2DeviceDescriptor,
        ownerNamespace: String,
        nowMs: Int64
    ) throws -> Outgoing {
        // L'accusé est rangé avant que l'enveloppe en attente ne parte : l'un
        // des deux est toujours là pour un message en cours.
        if let receipt = try stateStore.sentReceipt(
            conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace
        ) {
            return .delivered(receipt)
        }
        if let known = try stateStore.pendingSend(
            conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace
        ) {
            guard known.deviceId == device.deviceId else {
                forget(conversationId, clientRequestId, ownerNamespace)
                throw SendFailure(reason: "e2ee-pending-send-other-device")
            }
            guard nowMs - known.createdAtMs <= E2EEV2ConversationStateStore.pendingSendMaxAgeMs else {
                forget(conversationId, clientRequestId, ownerNamespace)
                throw SendFailure(reason: "e2ee-pending-send-expired")
            }
            if known.epochNumber == current.epochNumber { return .pending(known) }
            guard let payload = Data(base64Encoded: known.payloadB64), var fk = Data(base64Encoded: known.fkB64) else {
                forget(conversationId, clientRequestId, ownerNamespace)
                throw SendFailure(reason: "e2ee-pending-send-invalid")
            }
            defer { fk.resetBytes(in: 0..<fk.count) }
            return .pending(try prepare(
                payload: payload, fk: fk, counter: known.counter, ttlSeconds: known.ttlSeconds,
                conversationId: conversationId, clientRequestId: clientRequestId, epochNumber: current.epochNumber,
                device: device, ownerNamespace: ownerNamespace, createdAtMs: known.createdAtMs,
                notifyUserId: known.notifyUserId ?? "", marked: current.e2eeAuto == true
            ))
        }
        // La charge canonique doit tenir dans sa borne (D.7), échappements
        // compris, et se relire : vérifié avant de réserver un compteur.
        guard let probe = try? E2EEV2ContentPayloadV2(
            sentAtMs: nowMs, counter: Int64(E2EEV2Canonical.maxSequenceNumber), replyToRef: draft.replyToRef,
            mentions: draft.mentions, body: draft.body
        ).encoded() else { throw SendFailure(reason: "e2ee-message-too-long") }
        guard (try? E2EEV2ContentPayloadV2.parse(probe)) != nil else {
            throw SendFailure(reason: "invalid-e2ee-message-draft")
        }
        let counter: Int
        do {
            counter = try stateStore.reserveSendCounter(
                conversationId: conversationId, deviceId: device.deviceId, ownerNamespace: ownerNamespace
            )
        } catch E2EEV2ConversationStateStore.Failure.counterExhausted {
            throw SendFailure(reason: "e2ee-send-counter-exhausted")
        }
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: nowMs, counter: Int64(counter), replyToRef: draft.replyToRef, mentions: draft.mentions,
            body: draft.body
        ).encoded()
        var fk = try E2EEV2MessageComposerV2.randomBytes(32)
        defer { fk.resetBytes(in: 0..<fk.count) }
        return .pending(try prepare(
            payload: payload, fk: fk, counter: counter, ttlSeconds: draft.ttlSeconds, conversationId: conversationId,
            clientRequestId: clientRequestId, epochNumber: current.epochNumber, device: device,
            ownerNamespace: ownerNamespace, createdAtMs: nowMs, notifyUserId: draft.notifyUserId,
            marked: current.e2eeAuto == true
        ))
    }

    /// Compose sous l'époque vérifiée désignée, puis garde avant tout envoi.
    private func prepare(
        payload: Data,
        fk: Data,
        counter: Int,
        ttlSeconds: Int,
        conversationId: String,
        clientRequestId: String,
        epochNumber: Int,
        device: E2EEV2DeviceDescriptor,
        ownerNamespace: String,
        createdAtMs: Int64,
        notifyUserId: String,
        marked: Bool
    ) throws -> E2EEV2ConversationStateStore.PendingSend {
        let signed = try signedEnvelope(
            payload: payload, fk: fk, ttlSeconds: ttlSeconds, conversationId: conversationId, clientRequestId: clientRequestId,
            epochNumber: epochNumber, device: device, ownerNamespace: ownerNamespace, notifyUserId: notifyUserId, marked: marked
        )
        let pending = E2EEV2ConversationStateStore.PendingSend(
            conversationId: conversationId, clientRequestId: clientRequestId, deviceId: device.deviceId,
            counter: counter, ttlSeconds: ttlSeconds, payloadB64: payload.base64EncodedString(),
            fkB64: fk.base64EncodedString(), epochNumber: epochNumber, createdAtMs: createdAtMs,
            wire: String(decoding: signed.encoded, as: UTF8.self),
            notifyUserId: notifyUserId.isEmpty ? nil : notifyUserId
        )
        try stateStore.savePendingSend(pending, ownerNamespace: ownerNamespace)
        return pending
    }

    /// Enveloppe signée sous l'époque vérifiée désignée.
    private func signedEnvelope(
        payload: Data,
        fk: Data,
        ttlSeconds: Int,
        conversationId: String,
        clientRequestId: String,
        epochNumber: Int,
        device: E2EEV2DeviceDescriptor,
        ownerNamespace: String,
        notifyUserId: String,
        marked: Bool
    ) throws -> E2EEV2SignedMessageEnvelopeV2 {
        guard var epoch = try E2EEV2VerifiedEpochKeys.exact(
            conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace,
            keyStore: keyStore, stateStore: stateStore
        ) else { throw E2EEV2MessageV2Error.invalidContext }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        return try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: conversationId, clientRequestId: clientRequestId, ttlSeconds: ttlSeconds,
            epoch: epoch, device: device, fk: fk, nonce: E2EEV2MessageComposerV2.randomBytes(12),
            notifyUserId: notifyUserId, marked: marked
        ) { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) }
    }

    // MARK: Programmés chiffrés (E2EE-AUTO §7.8 F)

    /// Programme `draft` sous l'époque marquée courante : composé comme un envoi,
    /// avec un compteur neuf, puis déposé tel quel. Rien n'entre dans la file
    /// d'envoi : seul l'ordonnanceur publie ce message. Avec `scheduledId`, le
    /// programmé existant est rechiffré par `PUT`, sous son `clientRequestId`.
    func schedule(
        _ draft: Draft,
        conversationId: String,
        clientRequestId: String,
        sendAt: Date?,
        scheduledId: String?,
        membership: E2EEV2MembershipState,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String,
        messageCount: Int = 0
    ) async -> E2EEV2ScheduleResultV2 {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId), E2EEV2MessageCryptoV2.isClientRequestId(clientRequestId),
              scheduledId.map(E2EEAutoScheduledMessage.isScheduledId) ?? true,
              (sendAt != nil) || (scheduledId != nil) else {
            return .failure(localError("invalid-e2ee-schedule-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let device: E2EEV2DeviceDescriptor
        let current: E2EEV2ConversationStateStore.CurrentEpoch?
        do {
            guard let loaded = try identityStore.load(ownerNamespace: ownerNamespace),
                  try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) != nil else {
                return .failure(localError("e2ee-send-state-unavailable"))
            }
            device = loaded
            current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return .failure(localError("e2ee-send-state-unavailable"))
        }
        guard let current, membership.changeNumber >= current.membershipChangeNumber else { return .needsEpoch }
        // Seule une époque marquée porte des enveloppes v3 de nature `message`.
        guard current.e2eeAuto == true else { return .failure(localError("e2ee-schedule-requires-auto")) }
        guard membership.members.contains(ownUserId) else { return .failure(localError("e2ee-sender-not-member")) }
        guard E2EEV2RotationPolicy.reasons(
            current: current, membership: membership, devices: devices, nowMs: nowMs, messageCount: messageCount
        ).isEmpty else { return .needsRotation }

        let signed: E2EEV2SignedMessageEnvelopeV2
        do {
            signed = try Self.lock.withLock {
                guard let probe = try? E2EEV2ContentPayloadV2(
                    sentAtMs: nowMs, counter: Int64(E2EEV2Canonical.maxSequenceNumber), replyToRef: draft.replyToRef,
                    mentions: draft.mentions, body: draft.body
                ).encoded(), (try? E2EEV2ContentPayloadV2.parse(probe)) != nil else {
                    throw SendFailure(reason: "e2ee-message-too-long")
                }
                let counter: Int
                do {
                    counter = try stateStore.reserveSendCounter(
                        conversationId: conversationId, deviceId: device.deviceId, ownerNamespace: ownerNamespace
                    )
                } catch E2EEV2ConversationStateStore.Failure.counterExhausted {
                    throw SendFailure(reason: "e2ee-send-counter-exhausted")
                }
                let payload = try E2EEV2ContentPayloadV2(
                    sentAtMs: nowMs, counter: Int64(counter), replyToRef: draft.replyToRef, mentions: draft.mentions,
                    body: draft.body
                ).encoded()
                var fk = try E2EEV2MessageComposerV2.randomBytes(32)
                defer { fk.resetBytes(in: 0..<fk.count) }
                return try signedEnvelope(
                    payload: payload, fk: fk, ttlSeconds: draft.ttlSeconds, conversationId: conversationId,
                    clientRequestId: clientRequestId, epochNumber: current.epochNumber, device: device,
                    ownerNamespace: ownerNamespace, notifyUserId: "", marked: true
                )
            }
        } catch let failure as SendFailure {
            return .failure(localError(failure.reason))
        } catch {
            return .failure(localError("e2ee-send-preparation-failed"))
        }

        let body = E2EEAutoScheduledMessage.requestBody(signed, sendAt: sendAt)
        let bound = transport.bound(to: session)
        let result: E2EEV2TransportResult<Data>
        if let scheduledId {
            result = await bound.putJSON(
                path: "/api/messages/conversations/\(conversationId)/scheduled/\(scheduledId)", body: body,
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            )
        } else {
            result = await bound.postJSON(
                path: "/api/messages/conversations/\(conversationId)/scheduled", body: body,
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            )
        }
        switch result {
        case .success(let data, _, _):
            guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
            guard let ack = E2EEAutoScheduledMessage.Ack.parse(data) else {
                return .failure(localError("invalid-e2ee-schedule-receipt"))
            }
            return .scheduled(ack)
        case .failure(let error) where error.statusCode == 409
            && (error.code == "E2EE_EPOCH_STALE" || error.code == "E2EE_MEMBERSHIP_STALE"):
            return .needsEpoch
        case .failure(let error):
            return .failure(error)
        }
    }

    /// La charge d'un programmé de son compte, signée par `scheduled.senderDeviceId`
    /// (cet appareil ou un autre du compte), lue sous l'époque de son enveloppe, même
    /// remplacée ou compromise (§7.8 F, point 4). nil : appareil inconnu, clé absente
    /// ou enveloppe fausse.
    func openScheduled(
        _ scheduled: E2EEAutoScheduledMessage,
        conversationId: String,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) -> E2EEV2ContentPayloadV2? {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:") else { return nil }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        let signingKey: P256.Signing.PublicKey?
        if let own = try? identityStore.load(ownerNamespace: ownerNamespace), own.deviceId == scheduled.senderDeviceId {
            signingKey = Data(base64Encoded: own.publicSigningKeyB64).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
        } else {
            signingKey = devices.signingKey(userId: ownUserId, deviceId: scheduled.senderDeviceId)
        }
        guard let signingKey else { return nil }
        let context = scheduled.signed.context(conversationId: conversationId, senderDeviceId: scheduled.senderDeviceId)
        guard (try? E2EEV2MessageCryptoV2.verifySignature(
            context: context, envelope: scheduled.signed.envelope, signatureDerB64: scheduled.signed.senderSignatureB64,
            senderSigningKey: signingKey
        )) != nil,
              var epoch = try? keyStore.loadEpoch(
                conversationId: conversationId, epochNumber: scheduled.signed.envelope.epochNumber,
                ownerNamespace: ownerNamespace, includeRestored: false
              ) else { return nil }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        guard var opened = try? E2EEV2MessageCryptoV2.decrypt(
            envelope: scheduled.signed.envelope, epochKey: epoch.epochKey, context: context
        ) else { return nil }
        opened.fk.resetBytes(in: 0..<opened.fk.count)
        return opened.payload
    }

    /// Envoi abandonné : sa charge en clair quitte le trousseau.
    private func forget(_ conversationId: String, _ clientRequestId: String, _ ownerNamespace: String) {
        try? stateStore.clearPendingSend(conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace)
    }

    private func messageRef(_ conversationId: String, _ device: E2EEV2DeviceDescriptor, _ clientRequestId: String) -> String {
        E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: device.deviceId, clientRequestId: clientRequestId)
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
