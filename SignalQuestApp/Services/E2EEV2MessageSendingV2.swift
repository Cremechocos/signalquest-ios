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
        sign: (Data) throws -> Data
    ) throws -> E2EEV2SignedMessageEnvelopeV2 {
        let parsed = try E2EEV2ContentPayloadV2.parse(payload)
        guard epoch.conversationId == conversationId,
              try E2EEV2EpochCrypto.keyCommitment(epoch.epochKey) == epoch.keyCommitmentB64,
              let publicKeyData = Data(base64Encoded: device.publicSigningKeyB64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw E2EEV2MessageV2Error.invalidContext
        }
        let context = E2EEV2MessageContextV2(
            conversationId: conversationId, epochNumber: epoch.epochNumber, senderDeviceId: device.deviceId,
            clientRequestId: clientRequestId, counter: parsed.counter, ttlSeconds: ttlSeconds, encryptedBlobIds: []
        )
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
    /// Pas d'époque courante vérifiée, ou le serveur en connaît une plus
    /// récente : synchroniser la conversation, puis réessayer.
    case needsEpoch
    /// L'époque courante doit tourner avant tout envoi (§3.3).
    case needsRotation
    case failure(E2EEV2TransportFailure)
}

/// Envoi d'un message texte v2 (§4, E.3). Le compteur est réservé et la charge
/// gardée avant le premier envoi ; le même `clientRequestId` renvoie ensuite la
/// même enveloppe, à l'octet. Elle n'est rechiffrée sous l'époque courante que
/// si le serveur la refuse comme obsolète : une enveloppe déjà acceptée dont
/// l'accusé s'est perdu n'a jamais de jumelle (§4.2).
final class E2EEV2MessageSenderV2: @unchecked Sendable {
    struct Draft: Equatable, Sendable {
        let body: E2EEV2ContentPayloadV2.Body
        let replyToRef: String?
        let mentions: [String]
        let ttlSeconds: Int
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
    /// appareils certifiés des membres. Pour un envoi déjà préparé, `draft` est
    /// ignoré : c'est la charge gardée qui part.
    func send(
        _ draft: Draft,
        conversationId: String,
        clientRequestId: String,
        membership: E2EEV2MembershipState,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
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
        var pending: E2EEV2ConversationStateStore.PendingSend?
        do {
            guard let loaded = try identityStore.load(ownerNamespace: ownerNamespace),
                  try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) != nil else {
                return .failure(localError("e2ee-send-state-unavailable"))
            }
            device = loaded
            current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
            pending = try stateStore.pendingSend(
                conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace
            )
        } catch {
            return .failure(localError("e2ee-send-state-unavailable"))
        }
        guard let current, membership.changeNumber >= current.membershipChangeNumber else { return .needsEpoch }
        guard membership.members.contains(ownUserId) else { return .failure(localError("e2ee-sender-not-member")) }
        guard E2EEV2RotationPolicy.reasons(current: current, membership: membership, devices: devices, nowMs: nowMs).isEmpty
        else { return .needsRotation }
        if let known = pending, known.deviceId != device.deviceId {
            try? stateStore.clearPendingSend(conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace)
            return .failure(localError("e2ee-pending-send-other-device"))
        }

        if pending == nil {
            do {
                let counter = try stateStore.reserveSendCounter(
                    conversationId: conversationId, deviceId: device.deviceId, ownerNamespace: ownerNamespace
                )
                let payload = try E2EEV2ContentPayloadV2(
                    sentAtMs: nowMs, counter: Int64(counter), replyToRef: draft.replyToRef, mentions: draft.mentions,
                    body: draft.body
                ).encoded()
                pending = try prepare(
                    payload: payload, counter: counter, ttlSeconds: draft.ttlSeconds, conversationId: conversationId,
                    clientRequestId: clientRequestId, epochNumber: current.epochNumber, device: device,
                    ownerNamespace: ownerNamespace
                )
            } catch E2EEV2ConversationStateStore.Failure.counterExhausted {
                return .failure(localError("e2ee-send-counter-exhausted"))
            } catch {
                return .failure(localError("e2ee-send-preparation-failed"))
            }
        }
        guard var outgoing = pending else { return .failure(localError("e2ee-send-preparation-failed")) }

        // Un seul rechiffrement par appel : sur refus d'une enveloppe composée
        // sous une époque que l'appareil sait déjà remplacée.
        for attempt in 0..<2 {
            switch await transport.bound(to: session).postJSON(
                path: "/api/e2ee/v2/conversations/\(conversationId)/messages", body: Data(outgoing.wire.utf8),
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            ) {
            case .success(let data, _, _):
                guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
                guard let receipt = E2EEV2MessageReceiptV2.parse(data, clientRequestId: clientRequestId) else {
                    return .failure(localError("invalid-e2ee-message-receipt"))
                }
                try? stateStore.clearPendingSend(
                    conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace
                )
                return .sent(receipt, messageRef: E2EEV2MessageRef.make(
                    conversationId: conversationId, senderDeviceId: device.deviceId, clientRequestId: clientRequestId
                ))
            case .failure(let error) where error.statusCode == 409
                && (error.code == "E2EE_EPOCH_STALE" || error.code == "E2EE_MEMBERSHIP_STALE"):
                guard attempt == 0, error.code == "E2EE_EPOCH_STALE", outgoing.epochNumber < current.epochNumber,
                      let payload = Data(base64Encoded: outgoing.payloadB64) else { return .needsEpoch }
                do {
                    outgoing = try prepare(
                        payload: payload, counter: outgoing.counter, ttlSeconds: outgoing.ttlSeconds,
                        conversationId: conversationId, clientRequestId: clientRequestId,
                        epochNumber: current.epochNumber, device: device, ownerNamespace: ownerNamespace
                    )
                } catch {
                    return .failure(localError("e2ee-send-preparation-failed"))
                }
            case .failure(let error):
                return .failure(error)
            }
        }
        return .needsEpoch
    }

    /// Compose sous l'époque vérifiée désignée, puis garde avant tout envoi.
    private func prepare(
        payload: Data,
        counter: Int,
        ttlSeconds: Int,
        conversationId: String,
        clientRequestId: String,
        epochNumber: Int,
        device: E2EEV2DeviceDescriptor,
        ownerNamespace: String
    ) throws -> E2EEV2ConversationStateStore.PendingSend {
        guard var epoch = try E2EEV2VerifiedEpochKeys.exact(
            conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace,
            keyStore: keyStore, stateStore: stateStore
        ) else { throw E2EEV2MessageV2Error.invalidContext }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        var fk = try E2EEV2MessageComposerV2.randomBytes(32)
        defer { fk.resetBytes(in: 0..<fk.count) }
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: conversationId, clientRequestId: clientRequestId, ttlSeconds: ttlSeconds,
            epoch: epoch, device: device, fk: fk, nonce: E2EEV2MessageComposerV2.randomBytes(12)
        ) { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) }
        let pending = E2EEV2ConversationStateStore.PendingSend(
            conversationId: conversationId, clientRequestId: clientRequestId, deviceId: device.deviceId,
            counter: counter, ttlSeconds: ttlSeconds, payloadB64: payload.base64EncodedString(), epochNumber: epochNumber,
            wire: String(decoding: signed.encoded, as: UTF8.self)
        )
        try stateStore.savePendingSend(pending, ownerNamespace: ownerNamespace)
        return pending
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
