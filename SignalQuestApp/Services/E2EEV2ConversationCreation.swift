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
        genesisLength: Int,
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
            verified, recipients: lines, state: membership, genesisLength: genesisLength,
            previousMembershipChangeNumber: previousMembershipChangeNumber
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
        /// Des membres dont l'identité n'est pas crue : la conversation attend
        /// que l'utilisateur ait accepté leur nouveau numéro (§2.4).
        case membersNotTrusted([String])
        /// Un appareil compté ne lit pas encore le v2 (v0.4.17) : la
        /// conversation chiffrée naît en v1 tant que le serveur l'accepte.
        case capabilityMissing
    }

    /// Règle commune iOS et Android (v0.4.17) : une conversation ne passe en
    /// v2, par création ou par migration, que si l'intersection des capacités
    /// de ses membres (§12) contient l'enveloppe et la charge « 2 » et le texte.
    /// Un appareil au document vide la vide : rien ne passe en v2 avec lui.
    static func readsV2(_ devices: E2EEV2CertifiedDeviceSet, members: Set<String>, excludesWeb: Bool, nowMs: Int64) -> Bool {
        let scoped = E2EEV2CertifiedDeviceSet(
            devicesByUser: devices.devicesByUser.filter { members.contains($0.key) },
            refusals: devices.refusals.filter { members.contains($0.key) }
        )
        guard let intersection = scoped.capabilityIntersection(nowMs: nowMs, excludesWeb: excludesWeb) else { return false }
        return intersection.envelopeVersions.contains("2") && intersection.payloadVersions.contains("2")
            && intersection.kinds.contains("TEXT")
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

    /// Migration d'une conversation v1 (§14.2) : la conversation existe déjà.
    var migrationBody: Data {
        E2EEV2CanonicalJSON.encode(.object([
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
        adminIds: [String]? = nil,
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
        // Un membre sans identité v2 (E2EE_IDENTITY_NOT_FOUND) ne lit pas le v2 :
        // la conversation naît en v1 (v0.4.17). Une identité changée ou
        // invalide, elle, suspend tout (§2.4).
        guard !members.contains(where: { devices.refusals[$0] == .notFound }) else { throw Failure.capabilityMissing }
        let untrusted = devices.untrustedMembers(members)
        guard untrusted.isEmpty else { throw Failure.membersNotTrusted(untrusted) }
        guard readsV2(devices, members: members, excludesWeb: excludesWeb, nowMs: nowMs) else { throw Failure.capabilityMissing }
        let actor = E2EEV2MembershipChain.Actor(userId: ownUserId, deviceId: device.deviceId)
        guard let ownCertified = devices.device(userId: ownUserId, deviceId: device.deviceId),
              ownCertified.identityKeyB64 == device.publicIdentityKeyB64,
              ownCertified.signingKeyB64 == device.publicSigningKeyB64,
              let signingKey = ownCertified.signingKey else {
            throw Failure.deviceNotCertified
        }
        // Création : le créateur administre son groupe. Migration : les
        // administrateurs v1, que seul le serveur peut vérifier (§14.2).
        let changes = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: Array(members),
            adminIds: adminIds ?? (isGroup ? [ownUserId] : []),
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
            recipients: recipients, membership: genesis, genesisLength: signedChanges.count,
            previousMembershipChangeNumber: nil,
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

/// Migration d'une conversation chiffrée v1 à son ouverture (§14.2) : le
/// premier appareil v2 qui l'ouvre signe sa genèse (membres actuels, puis
/// propriétaire et administrateurs v1) et son époque 1. Elle est alors v2 pour
/// toujours. La genèse hérite de la confiance v1 : seul le serveur peut
/// vérifier les administrateurs v1.
enum E2EEV2ConversationMigration {
    enum Decision: Equatable, Sendable {
        case migrate
        case alreadyV2
        case notEncrypted
        /// Membres sans appareil certifié à jour : la migration attend.
        case membersWaiting([String])
        /// Un appareil compté ne lit pas encore le v2 : la conversation reste
        /// v1 (règle commune, v0.4.17).
        case capabilityWaiting
    }

    /// `isV2` nil : état « v2 » illisible. On ne migre jamais sur un doute, une
    /// seconde genèse serait possible.
    static func decide(
        _ conversation: MessageConversation,
        isV2: Bool?,
        devices: E2EEV2CertifiedDeviceSet,
        nowMs: Int64
    ) -> Decision {
        guard isV2 == false else { return .alreadyV2 }
        guard conversation.e2eeEnabled == true else { return .notEncrypted }
        let waiting = conversation.participants.map(\.userId).filter { user in
            !(devices.devicesByUser[user] ?? []).contains { !$0.isSidelined(nowMs: nowMs) }
        }
        guard waiting.isEmpty else { return .membersWaiting(waiting.sorted()) }
        let members = Set(conversation.participants.map(\.userId))
        return E2EEV2ConversationCreation.readsV2(devices, members: members, excludesWeb: false, nowMs: nowMs)
            ? .migrate : .capabilityWaiting
    }

    /// Administrateurs v1 : propriétaire et administrateurs d'un groupe.
    static func adminIds(_ conversation: MessageConversation) -> [String] {
        guard conversation.isGroup else { return [] }
        return conversation.participants.filter { $0.role == "owner" || $0.role == "admin" }.map(\.userId)
    }

    static func make(
        _ conversation: MessageConversation,
        ownUserId: String,
        device: E2EEV2DeviceDescriptor,
        devices: E2EEV2CertifiedDeviceSet,
        epochKey: Data,
        nowMs: Int64,
        sign: (Data) throws -> Data,
        wrap: (_ context: E2EEV2EpochContext, _ recipientIdentityKeyB64: String) throws -> E2EEV2SignedEpochEnvelope
    ) throws -> E2EEV2ConversationCreation {
        let members = conversation.participants.map(\.userId)
        guard members.contains(ownUserId) else { throw E2EEV2ConversationCreation.Failure.invalidMembers }
        return try E2EEV2ConversationCreation.make(
            conversationId: conversation.id, ownUserId: ownUserId, device: device,
            participantIds: members.filter { $0 != ownUserId }, isGroup: conversation.isGroup,
            title: conversation.title, excludesWeb: false, adminIds: adminIds(conversation),
            devices: devices, epochKey: epochKey, nowMs: nowMs, sign: sign, wrap: wrap
        )
    }
}

/// Reçu de création (proposition iOS, E.2) : la conversation v2 et son époque
/// 1 acceptée. JSON strict, entiers en chaînes (D.0).
enum E2EEV2ConversationCreationReceipt {
    /// `{conversationId, epoch: {id, epochNumber, status, createdAt}, recipientCount}`.
    static func parse(_ data: Data, conversationId: String, recipientCount: Int) -> E2EEV2EpochContractV2.Accepted? {
        guard let root = E2EEV2EpochContractV2.object(data),
              Set(root.keys) == ["conversationId", "epoch", "recipientCount"],
              root["conversationId"]?.stringValue == conversationId,
              let accepted = E2EEV2EpochContractV2.epoch(root["epoch"]), accepted.epochNumber == 1,
              root["recipientCount"]?.stringValue == String(recipientCount) else { return nil }
        return accepted
    }
}

enum E2EEV2ConversationCreationResult: Sendable {
    case created(conversationId: String, pendingUserIds: [String])
    case failure(E2EEV2TransportFailure)
}

/// Crée ou migre une conversation, puis, seulement une fois l'époque 1
/// acceptée, garde sa chaîne, sa genèse, sa clé et son époque courante (§3.1,
/// §12), dans cet ordre.
final class E2EEV2ConversationCreator: @unchecked Sendable {
    /// Ce qui part au serveur et ce qu'il faut garder après son reçu.
    private struct Prepared {
        let conversationId: String
        let isGroup: Bool
        let membership: [E2EEV2SignedString]
        let manifest: E2EEV2SignedString
        let recipients: [String]
        let envelopes: [E2EEV2SignedEpochEnvelope]
        let pendingUserIds: [String]
        let body: Data

        init(_ creation: E2EEV2ConversationCreation, body: Data) {
            conversationId = creation.conversationId
            isGroup = creation.isGroup
            membership = creation.membership
            manifest = creation.epoch.manifest
            recipients = creation.epoch.recipients
            envelopes = creation.epoch.envelopes
            pendingUserIds = creation.pendingUserIds
            self.body = body
        }

        /// Corps de création gardé (reçu perdu), relu strictement.
        init?(creationBody: String, pendingUserIds: [String]) {
            guard let root = try? E2EEV2CanonicalJSON.parseCanonical(creationBody).objectValue,
                  Set(root.keys) == ["conversationId", "isGroup", "title", "participantIds", "membership", "epoch"],
                  let conversationId = root["conversationId"]?.stringValue, E2EEV2Canonical.isOpaque(conversationId),
                  case .bool(let isGroup)? = root["isGroup"],
                  let migration = Self(
                      migrationBody: E2EEV2CanonicalJSON.encodeString(.object([
                          "membership": root["membership"] ?? .null, "epoch": root["epoch"] ?? .null,
                      ])),
                      conversationId: conversationId, isGroup: isGroup
                  ) else { return nil }
            self.conversationId = conversationId
            self.isGroup = isGroup
            membership = migration.membership
            manifest = migration.manifest
            recipients = migration.recipients
            envelopes = migration.envelopes
            self.pendingUserIds = pendingUserIds
            body = Data(creationBody.utf8)
        }

        /// Corps de migration gardé, relu strictement.
        init?(migrationBody: String, conversationId: String, isGroup: Bool) {
            guard let root = try? E2EEV2CanonicalJSON.parseCanonical(migrationBody).objectValue,
                  Set(root.keys) == ["membership", "epoch"],
                  let items = root["membership"]?.arrayValue,
                  let epoch = root["epoch"]?.objectValue,
                  Set(epoch.keys) == ["epochNumber", "previousEpochNumber", "manifest", "envelopes"],
                  let wire = epoch["manifest"].flatMap(E2EEV2EpochManifest.signed(from:)),
                  let envelopeItems = epoch["envelopes"]?.arrayValue else { return nil }
            let changes = items.compactMap(E2EEV2MembershipChange.signed(from:))
            let envelopes = envelopeItems.compactMap(E2EEV2EpochContractV2.envelope)
            guard changes.count == items.count, envelopes.count == envelopeItems.count else { return nil }
            self.conversationId = conversationId
            self.isGroup = isGroup
            membership = changes
            manifest = wire.manifest
            recipients = wire.recipients
            self.envelopes = envelopes
            pendingUserIds = []
            body = Data(migrationBody.utf8)
        }
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

    func create(
        participantIds: [String],
        isGroup: Bool,
        title: String?,
        excludesWeb: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2ConversationCreationResult {
        guard let context = context(expectedOwnerScopeId) else {
            return .failure(localError("invalid-e2ee-creation-scope"))
        }
        // Une même demande reprise dans l'heure renvoie le même corps (reçu perdu).
        let request = Self.creationRequest(participantIds: participantIds, isGroup: isGroup, title: title, excludesWeb: excludesWeb)
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        // Lecture et écriture du corps gardé d'un seul geste : un double appui
        // reprend le même corps, que le serveur traite comme un rejeu.
        let prepared: Prepared
        do {
            prepared = try Self.creationLock.withLock { () throws -> Prepared in
                // Destinataires attendus maintenant : un corps gardé dont les
                // appareils ont changé (révocation, ajout) n'est jamais renvoyé.
                let expectedRecipients = Set(E2EEV2EpochProposals.recipients(
                    devices, members: Set(participantIds + [context.ownUserId]), excludesWeb: excludesWeb, nowMs: nowMs
                ).map { E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint) })
                if let pending = try stateStore.pendingCreation(request: request, ownerNamespace: context.ownerNamespace),
                   (0..<Self.pendingCreationLifetimeMs).contains(nowMs - pending.savedAtMs),
                   let restored = Prepared(creationBody: pending.body, pendingUserIds: pending.pendingUserIds),
                   Set(restored.recipients) == expectedRecipients {
                    return restored
                }
                let creation = try build(context) {
                    try E2EEV2ConversationCreation.make(
                        conversationId: try E2EEV2ConversationCreation.newConversationId(), ownUserId: context.ownUserId,
                        device: context.device, participantIds: participantIds, isGroup: isGroup, title: title,
                        excludesWeb: excludesWeb, devices: devices, epochKey: $0, nowMs: $1, sign: $2, wrap: $3
                    )
                }
                // Gardé avant tout envoi : jamais deux conversations pour une demande.
                try stateStore.savePendingCreation(
                    .init(body: String(decoding: creation.body, as: UTF8.self), pendingUserIds: creation.pendingUserIds, savedAtMs: nowMs),
                    request: request, ownerNamespace: context.ownerNamespace
                )
                return Prepared(creation, body: creation.body)
            }
        } catch E2EEV2ConversationCreation.Failure.capabilityMissing {
            // Un membre ne lit pas encore le v2 : l'appelant crée en v1 (v0.4.17).
            return .failure(localError("e2ee-v2-capability-missing"))
        } catch E2EEV2ConversationCreation.Failure.membersNotTrusted {
            // Identité d'un membre illisible ou changée (§2.4) : rien n'est créé.
            return .failure(localError("e2ee-v2-members-not-trusted"))
        } catch {
            return .failure(localError("e2ee-conversation-creation-invalid"))
        }
        let result = await submit(prepared, path: "/api/e2ee/v2/conversations", context: context, devices: devices)
        switch result {
        case .created:
            try? stateStore.clearPendingCreation(request: request, ownerNamespace: context.ownerNamespace)
        case .failure(let failure) where failure.kind == .permanent:
            // Refus du serveur (liste périmée, identifiant pris…) : la prochaine demande repart d'un corps neuf.
            try? stateStore.clearPendingCreation(request: request, ownerNamespace: context.ownerNamespace)
        case .failure:
            // Réseau, session, ou échec local après la réponse (reçu illisible,
            // stockage) : le serveur a peut-être créé la conversation, la
            // reprise renverra le même corps.
            break
        }
        return result
    }

    static let pendingCreationLifetimeMs: Int64 = 60 * 60 * 1_000
    private static let creationLock = NSLock()

    /// Empreinte d'une demande de création : mêmes participants (triés), même
    /// nature, même titre, même exclusion des navigateurs.
    static func creationRequest(participantIds: [String], isGroup: Bool, title: String?, excludesWeb: Bool) -> String {
        let description = E2EEV2CanonicalJSON.encodeString(.object([
            "participantIds": .array(Array(Set(participantIds)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                .map(E2EEV2JSON.string)),
            "isGroup": .bool(isGroup), "title": title.map(E2EEV2JSON.string) ?? .null, "excludesWeb": .bool(excludesWeb),
        ]))
        return E2EEV2Canonical.sha256B64URL(Data(description.utf8))
    }

    /// Migration d'une conversation chiffrée v1 (§14.2), sous son identifiant.
    /// Une seule genèse est jamais signée : un nouvel essai renvoie le même corps.
    func migrate(
        _ conversation: MessageConversation,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2ConversationCreationResult {
        guard let context = context(expectedOwnerScopeId) else {
            return .failure(localError("invalid-e2ee-creation-scope"))
        }
        let prepared: Prepared
        do {
            if let pending = try stateStore.pendingGenesis(conversationId: conversation.id, ownerNamespace: context.ownerNamespace) {
                guard let restored = Prepared(migrationBody: pending, conversationId: conversation.id, isGroup: conversation.isGroup)
                else { return .failure(localError("e2ee-pending-genesis-invalid")) }
                prepared = restored
            } else {
                let migration = try build(context) {
                    try E2EEV2ConversationMigration.make(
                        conversation, ownUserId: context.ownUserId, device: context.device, devices: devices,
                        epochKey: $0, nowMs: $1, sign: $2, wrap: $3
                    )
                }
                // Gardé avant tout envoi : un échec ne fait jamais signer une seconde genèse.
                try stateStore.savePendingGenesis(
                    String(decoding: migration.migrationBody, as: UTF8.self),
                    conversationId: conversation.id, ownerNamespace: context.ownerNamespace
                )
                prepared = Prepared(migration, body: migration.migrationBody)
            }
        } catch {
            return .failure(localError("e2ee-conversation-creation-invalid"))
        }
        let result = await submit(
            prepared, path: "/api/e2ee/v2/conversations/\(conversation.id)/genesis", context: context, devices: devices
        )
        switch result {
        case .created:
            try? stateStore.clearPendingGenesis(conversationId: conversation.id, ownerNamespace: context.ownerNamespace)
        case .failure(let failure)
            where ["E2EE_CONVERSATION_ALREADY_V2", "E2EE_GENESIS_NOT_ELIGIBLE"].contains(failure.code ?? ""):
            // v0.4.16 : refus définitif, la conversation se relit ; la genèse ne repartira plus.
            try? stateStore.clearPendingGenesis(conversationId: conversation.id, ownerNamespace: context.ownerNamespace)
        case .failure:
            break
        }
        return result
    }

    private struct Context {
        let session: LocalAccountSession
        let ownerNamespace: String
        let ownUserId: String
        let device: E2EEV2DeviceDescriptor
        let expectedOwnerScopeId: String
    }

    private func context(_ expectedOwnerScopeId: String) -> Context? {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              let device = try? identityStore.load(ownerNamespace: session.ownerNamespace) else { return nil }
        return Context(
            session: session, ownerNamespace: session.ownerNamespace,
            ownUserId: String(expectedOwnerScopeId.dropFirst("user:".count)), device: device,
            expectedOwnerScopeId: expectedOwnerScopeId
        )
    }

    /// Clé tirée ici, signatures et enveloppes par le coffre de l'appareil.
    /// La clé n'est pas gardée : après le reçu, elle se relit dans l'enveloppe
    /// que l'appareil s'est adressée.
    private func build<T>(
        _ context: Context,
        _ make: (Data, Int64, (Data) throws -> Data, (E2EEV2EpochContext, String) throws -> E2EEV2SignedEpochEnvelope) throws -> T
    ) throws -> T {
        var epochKey = Data(count: 32)
        let status = epochKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        guard status == errSecSuccess else { throw E2EEV2DeviceIdentityError.randomGenerationFailed }
        let ownerNamespace = context.ownerNamespace
        return try make(
            epochKey, Int64(now().timeIntervalSince1970 * 1_000),
            { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) },
            { [identityStore] epochContext, recipientKey in
                try identityStore.createSignedEpochEnvelope(
                    context: epochContext, epochKey: epochKey, recipientPublicIdentityKeyB64: recipientKey,
                    ownerNamespace: ownerNamespace
                )
            }
        )
    }

    private func submit(
        _ prepared: Prepared,
        path: String,
        context: Context,
        devices: E2EEV2CertifiedDeviceSet
    ) async -> E2EEV2ConversationCreationResult {
        let response: Data
        switch await transport.bound(to: context.session).postJSON(
            path: path, body: prepared.body, expectedOwnerScopeId: context.expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .failure(let error): return .failure(error)
        case .success(let data, _, _): response = data
        }
        guard context.session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
        guard let accepted = E2EEV2ConversationCreationReceipt.parse(
            response, conversationId: prepared.conversationId, recipientCount: prepared.envelopes.count
        ) else {
            return .failure(localError("invalid-e2ee-conversation-creation-response"))
        }
        do {
            try finish(prepared, accepted: accepted, context: context, devices: devices)
        } catch {
            return .failure(localError("e2ee-created-epoch-storage-failed"))
        }
        return .created(conversationId: prepared.conversationId, pendingUserIds: prepared.pendingUserIds)
    }

    /// Relit ce que l'appareil a lui-même signé, puis garde : la chaîne, la
    /// genèse (avec le condensat de son dernier changement), et sous verrou la
    /// clé et l'époque courante.
    private func finish(
        _ prepared: Prepared,
        accepted: E2EEV2EpochContractV2.Accepted,
        context: Context,
        devices: E2EEV2CertifiedDeviceSet
    ) throws {
        guard let own = devices.device(userId: context.ownUserId, deviceId: context.device.deviceId),
              own.signingKeyB64 == context.device.publicSigningKeyB64, let signingKey = own.signingKey,
              let last = prepared.membership.last?.canonical,
              let ownEnvelope = prepared.envelopes.first(where: { $0.recipientDeviceId == context.device.deviceId }) else {
            throw E2EEV2ConversationCreation.Failure.deviceNotCertified
        }
        let genesis = try E2EEV2MembershipChain.apply(
            prepared.membership, conversationId: prepared.conversationId, isGroup: prepared.isGroup,
            genesisLength: prepared.membership.count
        ) { userId, deviceId in
            userId == context.ownUserId && deviceId == context.device.deviceId ? signingKey : nil
        }
        let manifest = try E2EEV2EpochManifest.verify(prepared.manifest, recipients: prepared.recipients, creatorSigningKey: signingKey)
        try E2EEV2EpochBinding.check(
            manifest, recipients: prepared.recipients, state: genesis, genesisLength: prepared.membership.count,
            previousMembershipChangeNumber: nil
        )
        var epochKey = try identityStore.unwrapEpochKey(
            delivery: E2EEV2EpochDelivery(
                conversationId: prepared.conversationId, epochId: accepted.epochId, epochNumber: 1,
                keyCommitmentB64: manifest.keyCommitmentB64, reason: "INITIAL", status: "active",
                createdAt: accepted.createdAt, senderDeviceId: context.device.deviceId,
                senderPublicSigningKeyB64: context.device.publicSigningKeyB64, envelope: ownEnvelope
            ),
            ownerNamespace: context.ownerNamespace
        )
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        if try stateStore.membershipChain(conversationId: prepared.conversationId, ownerNamespace: context.ownerNamespace).isEmpty {
            try stateStore.appendMembership(prepared.membership, conversationId: prepared.conversationId, ownerNamespace: context.ownerNamespace)
        }
        try stateStore.record(
            .init(
                conversationId: prepared.conversationId, creatorUserId: context.ownUserId,
                creatorDeviceId: context.device.deviceId,
                manifestDigest: E2EEV2Canonical.sha256B64URL(Data(prepared.manifest.canonical.utf8)),
                membershipChangeNumber: prepared.membership.count,
                membershipDigest: E2EEV2MembershipChange.digest(of: last),
                recordedAtMs: Int64(now().timeIntervalSince1970 * 1_000)
            ),
            ownerNamespace: context.ownerNamespace
        )
        guard E2EEV2EpochVerifierV2.keep(
            epochKey: epochKey, accepted: accepted, conversationId: prepared.conversationId,
            commitment: manifest.keyCommitmentB64, membership: genesis, recipients: prepared.recipients,
            createdAtMs: manifest.createdAtMs, acceptedAtMs: Int64(now().timeIntervalSince1970 * 1_000),
            session: context.session, keyStore: keyStore, stateStore: stateStore
        ) else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
