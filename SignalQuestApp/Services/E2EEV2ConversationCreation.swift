import CryptoKit
import Foundation

/// Époque proposée par cet appareil (§3.1, §3.5) : clé tirée ici, enveloppée et
/// signée pour chaque appareil visé, manifeste format 2 qui engage l'état
/// d'appartenance. Elle ne sert qu'une fois acceptée par le serveur.
struct E2EEV2EpochProposal: Sendable {
    let conversationId: String
    let epochNumber: Int
    let keyCommitmentB64: String
    let manifest: E2EEV2SignedString
    let recipients: [String]
    let envelopes: [E2EEV2SignedEpochEnvelope]
    let createdAtMs: Int64

    /// `{epochNumber, previousEpochNumber, manifest, envelopes}` (E.2), entiers
    /// en chaînes (D.0).
    var json: E2EEV2JSON {
        .object([
            "epochNumber": .string(String(epochNumber)),
            "previousEpochNumber": .string(String(epochNumber - 1)),
            "manifest": E2EEV2EpochManifest.json(manifest, recipients: recipients),
            "envelopes": .array(envelopes.map { envelope in
                .object([
                    "recipientDeviceId": .string(envelope.recipientDeviceId),
                    "wrapAlgorithm": .string(envelope.wrapAlgorithm),
                    "ephemeralPublicKeyB64": .string(envelope.ephemeralPublicKeyB64),
                    "wrappedEpochKeyB64": .string(envelope.wrappedEpochKeyB64),
                    "nonceB64": .string(envelope.nonceB64),
                    "aadB64": .string(envelope.aadB64),
                    "signatureB64": .string(envelope.signatureB64),
                ])
            }),
        ])
    }
}

enum E2EEV2EpochProposals {
    /// Appareils visés (§3.1, §3.3, §12) : certifiés et non mis à l'écart, des
    /// membres de l'état, sans navigateur quand ils sont exclus. Un membre sans
    /// appareil certifié attend la prochaine époque (§3.2).
    static func recipients(
        _ devices: E2EEV2CertifiedDeviceSet,
        members: Set<String>,
        excludesWeb: Bool,
        nowMs: Int64
    ) -> [E2EEV2CertifiedDevice] {
        members.flatMap { devices.devicesByUser[$0] ?? [] }
            .filter { !$0.isSidelined(nowMs: nowMs) && !(excludesWeb && $0.platform == "web") }
            .sorted { lhs, rhs in
                lhs.userId == rhs.userId
                    ? Array(lhs.deviceId.utf8).lexicographicallyPrecedes(Array(rhs.deviceId.utf8))
                    : Array(lhs.userId.utf8).lexicographicallyPrecedes(Array(rhs.userId.utf8))
            }
    }

    /// Manifeste signé puis relu comme un destinataire le relira, enveloppes
    /// signées pour chaque appareil visé.
    static func make(
        conversationId: String,
        epochNumber: Int,
        creator: E2EEV2MembershipChain.Actor,
        creatorSigningKey: P256.Signing.PublicKey,
        recipients: [E2EEV2CertifiedDevice],
        membership: E2EEV2MembershipState,
        previousMembershipChangeNumber: Int?,
        epochKey: Data,
        nowMs: Int64,
        sign: (Data) throws -> Data,
        wrap: (_ context: E2EEV2EpochContext, _ recipientIdentityKeyB64: String) throws -> E2EEV2SignedEpochEnvelope
    ) throws -> E2EEV2EpochProposal {
        guard epochKey.count == 32, epochNumber >= 1, let last = membership.lastCanonical,
              (1...E2EEV2EpochManifest.maxRecipients).contains(recipients.count) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let lines = recipients.map {
            E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint)
        }
        let manifest = E2EEV2EpochManifest.make(
            conversationId: conversationId, epochNumber: epochNumber, creatorUserId: creator.userId,
            creatorDeviceId: creator.deviceId, keyCommitmentB64: commitment, recipients: lines,
            excludesWeb: membership.excludesWeb, membershipChangeNumber: membership.changeNumber,
            membershipDigest: E2EEV2MembershipChange.digest(of: last), createdAtMs: nowMs
        )
        let signed = E2EEV2SignedString(
            canonical: manifest.canonical, signatureB64: try sign(Data(manifest.canonical.utf8)).base64EncodedString()
        )
        let verified = try E2EEV2EpochManifest.verify(signed, recipients: lines, creatorSigningKey: creatorSigningKey)
        try E2EEV2EpochBinding.check(
            verified, recipients: lines, state: membership, previousMembershipChangeNumber: previousMembershipChangeNumber
        )
        let envelopes = try recipients.map { device in
            try wrap(
                E2EEV2EpochContext(
                    conversationId: conversationId, epochNumber: epochNumber,
                    senderDeviceId: creator.deviceId, recipientDeviceId: device.deviceId
                ),
                device.identityKeyB64
            )
        }
        return E2EEV2EpochProposal(
            conversationId: conversationId, epochNumber: epochNumber, keyCommitmentB64: commitment,
            manifest: signed, recipients: lines, envelopes: envelopes, createdAtMs: nowMs
        )
    }
}

/// Création d'une conversation v2 (§3.2, E.2) : la conversation, sa genèse
/// signée et son époque 1, en une seule requête. Le serveur ne génère rien.
struct E2EEV2ConversationCreation: Sendable {
    enum Failure: Error, Equatable {
        case invalidMembers
        /// Cet appareil n'est pas certifié, ou pas tel que l'annuaire le connaît.
        case deviceNotCertified
    }

    let conversationId: String
    let isGroup: Bool
    let title: String?
    let participantIds: [String]
    let membership: [E2EEV2SignedString]
    let genesis: E2EEV2MembershipState
    let epoch: E2EEV2EpochProposal
    /// Membres sans appareil certifié : ils recevront la clé à leur arrivée.
    let pendingUserIds: [String]

    var body: Data {
        E2EEV2CanonicalJSON.encode(.object([
            "conversationId": .string(conversationId),
            "isGroup": .bool(isGroup),
            "title": title.map(E2EEV2JSON.string) ?? .null,
            "participantIds": .array(participantIds.map(E2EEV2JSON.string)),
            "membership": .array(membership.map(E2EEV2MembershipChange.json)),
            "epoch": epoch.json,
        ]))
    }

    /// Identifiant choisi par l'appareil : 128 bits aléatoires au format opaque.
    static func newConversationId() throws -> String {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw E2EEV2DeviceIdentityError.randomGenerationFailed }
        return "conv_" + E2EEV2Canonical.base64URL(bytes)
    }

    static func make(
        conversationId: String,
        ownUserId: String,
        device: E2EEV2DeviceDescriptor,
        participantIds: [String],
        isGroup: Bool,
        title: String?,
        excludesWeb: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        epochKey: Data,
        nowMs: Int64,
        sign: (Data) throws -> Data,
        wrap: (_ context: E2EEV2EpochContext, _ recipientIdentityKeyB64: String) throws -> E2EEV2SignedEpochEnvelope
    ) throws -> E2EEV2ConversationCreation {
        let members = Set(participantIds + [ownUserId])
        guard members.count == participantIds.count + 1, isGroup || members.count == 2 else {
            throw Failure.invalidMembers
        }
        let actor = E2EEV2MembershipChain.Actor(userId: ownUserId, deviceId: device.deviceId)
        guard let ownCertified = devices.device(userId: ownUserId, deviceId: device.deviceId),
              ownCertified.identityKeyB64 == device.publicIdentityKeyB64,
              ownCertified.signingKeyB64 == device.publicSigningKeyB64,
              let signingKey = ownCertified.signingKey else {
            throw Failure.deviceNotCertified
        }
        let changes = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: Array(members), adminIds: isGroup ? [ownUserId] : [],
            isGroup: isGroup, excludesWeb: excludesWeb, actor: actor, createdAtMs: nowMs
        )
        let signedChanges = try changes.map {
            E2EEV2SignedString(canonical: $0.canonical, signatureB64: try sign(Data($0.canonical.utf8)).base64EncodedString())
        }
        // Relue comme les autres membres la reliront.
        let genesis = try E2EEV2MembershipChain.apply(
            signedChanges, conversationId: conversationId, isGroup: isGroup, genesisLength: signedChanges.count
        ) { userId, deviceId in
            userId == ownUserId && deviceId == device.deviceId ? signingKey : nil
        }
        let recipients = E2EEV2EpochProposals.recipients(
            devices, members: genesis.members, excludesWeb: excludesWeb, nowMs: nowMs
        )
        guard recipients.contains(where: { $0.userId == ownUserId && $0.deviceId == device.deviceId }) else {
            throw Failure.deviceNotCertified
        }
        let epoch = try E2EEV2EpochProposals.make(
            conversationId: conversationId, epochNumber: 1, creator: actor, creatorSigningKey: signingKey,
            recipients: recipients, membership: genesis, previousMembershipChangeNumber: nil,
            epochKey: epochKey, nowMs: nowMs, sign: sign, wrap: wrap
        )
        let served = Set(recipients.map(\.userId))
        return E2EEV2ConversationCreation(
            conversationId: conversationId, isGroup: isGroup, title: title,
            participantIds: participantIds.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) },
            membership: signedChanges, genesis: genesis, epoch: epoch,
            pendingUserIds: genesis.members.subtracting(served).sorted()
        )
    }
}

/// Reçu de création (proposition iOS, E.2) : la conversation v2 et son époque 1
/// acceptée, sous la forme du reçu de rotation.
enum E2EEV2ConversationCreationReceipt {
    struct Accepted: Equatable, Sendable {
        let epochId: String
        let createdAt: String
    }

    static func parse(_ data: Data, conversationId: String, recipientCount: Int) -> Accepted? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["conversation", "epoch", "recipientCount"],
              let conversation = root["conversation"] as? [String: Any],
              conversation["id"] as? String == conversationId,
              conversation["e2eeProtocolVersion"] as? Int == 2,
              let epoch = root["epoch"] as? [String: Any],
              Set(epoch.keys) == ["id", "epochNumber", "status", "createdAt"],
              let epochId = epoch["id"] as? String, E2EEV2Canonical.isOpaque(epochId),
              epoch["epochNumber"] as? Int == 1, epoch["status"] as? String == "active",
              let createdAt = epoch["createdAt"] as? String, !createdAt.isEmpty, createdAt.count <= 64,
              root["recipientCount"] as? Int == recipientCount else { return nil }
        return Accepted(epochId: epochId, createdAt: createdAt)
    }
}

enum E2EEV2ConversationCreationResult: Sendable {
    case created(conversationId: String, pendingUserIds: [String])
    case failure(E2EEV2TransportFailure)
}

/// Crée la conversation, puis, seulement une fois l'époque 1 acceptée, garde sa
/// clé et l'état « v2 » collant (§3.1, §12).
final class E2EEV2ConversationCreator: @unchecked Sendable {
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

    func create(
        participantIds: [String],
        isGroup: Bool,
        title: String?,
        excludesWeb: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2ConversationCreationResult {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:") else {
            return .failure(localError("invalid-e2ee-creation-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        guard let device = try? identityStore.load(ownerNamespace: ownerNamespace) else {
            return .failure(localError("e2ee-device-identity-unavailable"))
        }
        var epochKey = Data(count: 32)
        let status = epochKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        guard status == errSecSuccess else { return .failure(localError("e2ee-epoch-random-generation-failed")) }

        let creation: E2EEV2ConversationCreation
        do {
            let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
            creation = try E2EEV2ConversationCreation.make(
                conversationId: try E2EEV2ConversationCreation.newConversationId(),
                ownUserId: ownUserId, device: device, participantIds: participantIds, isGroup: isGroup,
                title: title, excludesWeb: excludesWeb, devices: devices, epochKey: epochKey, nowMs: nowMs,
                sign: { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) },
                wrap: { [identityStore] context, recipientKey in
                    try identityStore.createSignedEpochEnvelope(
                        context: context, epochKey: epochKey, recipientPublicIdentityKeyB64: recipientKey,
                        ownerNamespace: ownerNamespace
                    )
                }
            )
        } catch {
            return .failure(localError("e2ee-conversation-creation-invalid"))
        }

        let response: Data
        switch await transport.bound(to: session).postJSON(
            path: "/api/e2ee/v2/conversations",
            body: creation.body,
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let error): return .failure(error)
        case .success(let data, _, _): response = data
        }
        guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
        guard let accepted = E2EEV2ConversationCreationReceipt.parse(
            response, conversationId: creation.conversationId, recipientCount: creation.epoch.envelopes.count
        ) else {
            return .failure(localError("invalid-e2ee-conversation-creation-response"))
        }
        do {
            guard try keyStore.put(
                recordInput: .init(
                    conversationId: creation.conversationId, epochId: accepted.epochId, epochNumber: 1,
                    keyCommitmentB64: creation.epoch.keyCommitmentB64
                ),
                epochKey: epochKey, ownerNamespace: ownerNamespace, expectedSession: session
            ) else { return .failure(localError("e2ee-created-epoch-storage-failed")) }
            try stateStore.record(
                .init(
                    conversationId: creation.conversationId, creatorUserId: ownUserId, creatorDeviceId: device.deviceId,
                    manifestDigest: E2EEV2Canonical.sha256B64URL(Data(creation.epoch.manifest.canonical.utf8)),
                    membershipChangeNumber: creation.genesis.changeNumber,
                    recordedAtMs: Int64(now().timeIntervalSince1970 * 1_000)
                ),
                ownerNamespace: ownerNamespace
            )
            try stateStore.recordCurrentEpoch(
                .init(
                    conversationId: creation.conversationId, epochNumber: 1,
                    membershipChangeNumber: creation.genesis.changeNumber,
                    memberIds: creation.genesis.members.sorted(),
                    recipientsDigest: E2EEV2Canonical.listDigest(
                        tag: E2EEV2EpochManifest.recipientsTag, lines: creation.epoch.recipients
                    ),
                    excludesWeb: creation.genesis.excludesWeb, createdAtMs: creation.epoch.createdAtMs
                ),
                ownerNamespace: ownerNamespace
            )
        } catch {
            return .failure(localError("e2ee-created-epoch-storage-failed"))
        }
        return .created(conversationId: creation.conversationId, pendingUserIds: creation.pendingUserIds)
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
