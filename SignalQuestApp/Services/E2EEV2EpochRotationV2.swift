import CryptoKit
import Foundation

/// Rotation décidée par l'appareil (§3.3) : avant tout envoi, les destinataires
/// de l'époque courante doivent être les appareils certifiés des membres
/// actuels. L'absence d'exigence du serveur n'en dispense jamais.
enum E2EEV2RotationPolicy {
    enum Reason: Equatable, Sendable {
        /// Membre ajouté ou retiré.
        case members
        /// Appareil ajouté, révoqué ou mis à l'écart.
        case devices
        /// Réglage « exclure les navigateurs » modifié.
        case browsers
        /// 30 jours au plus par époque, comptés depuis son acceptation locale.
        case age
        /// 10 000 messages au plus par époque.
        case volume
    }

    static let maxEpochAgeMs: Int64 = 30 * 24 * 60 * 60 * 1_000
    static let maxEpochMessages = 10_000

    static func reasons(
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        membership: E2EEV2MembershipState,
        expectedRecipients: [String],
        nowMs: Int64,
        messageCount: Int = 0
    ) -> [Reason] {
        var reasons: [Reason] = []
        if Set(current.memberIds) != membership.members { reasons.append(.members) }
        if E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: expectedRecipients)
            != current.recipientsDigest {
            reasons.append(.devices)
        }
        if current.excludesWeb != membership.excludesWeb { reasons.append(.browsers) }
        if nowMs - current.acceptedAtMs >= maxEpochAgeMs { reasons.append(.age) }
        if messageCount >= maxEpochMessages { reasons.append(.volume) }
        return reasons
    }

    /// Destinataires attendus : les appareils certifiés des membres actuels.
    /// `messageCount` : messages acceptés sous l'époque courante (registre).
    static func reasons(
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        membership: E2EEV2MembershipState,
        devices: E2EEV2CertifiedDeviceSet,
        nowMs: Int64,
        messageCount: Int = 0
    ) -> [Reason] {
        let expected = E2EEV2EpochProposals.recipients(
            devices, members: membership.members, excludesWeb: membership.excludesWeb, nowMs: nowMs
        ).map {
            E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint)
        }
        return reasons(
            current: current, membership: membership, expectedRecipients: expected, nowMs: nowMs, messageCount: messageCount
        )
    }
}

/// Réponses du serveur aux routes d'époque v2 (proposition iOS, E.2) : JSON
/// strict, clés exactes, entiers en chaînes décimales (D.0).
enum E2EEV2EpochContractV2 {
    struct Accepted: Equatable, Sendable {
        let epochId: String
        let epochNumber: Int
        let createdAt: String
    }

    /// Époque courante servie à un appareil : l'époque acceptée, son manifeste
    /// et l'enveloppe de cet appareil. Sans enveloppe (`null`, serveur A3) :
    /// l'appareil n'est pas destinataire, ou a déjà accusé réception ; il en
    /// juge d'après le manifeste signé, jamais d'après cette absence.
    struct Current: Equatable, Sendable {
        let accepted: Accepted
        let manifest: E2EEV2SignedString
        let recipients: [String]
        let envelope: E2EEV2SignedEpochEnvelope?
    }

    /// `{epoch: {id, epochNumber, status, createdAt}, recipientCount}`.
    static func parseReceipt(_ data: Data, epochNumber: Int, recipientCount: Int) -> Accepted? {
        guard let root = object(data), Set(root.keys) == ["epoch", "recipientCount"],
              let accepted = epoch(root["epoch"]), accepted.epochNumber == epochNumber,
              root["recipientCount"]?.stringValue == String(recipientCount) else { return nil }
        return accepted
    }

    /// `{conversationId, epoch: {…}, manifest: {manifest, signatureB64, recipients}, envelope: {A.3}}`.
    static func parseCurrent(_ data: Data, conversationId: String) -> Current? {
        guard let root = object(data), Set(root.keys) == ["conversationId", "epoch", "manifest", "envelope"],
              root["conversationId"]?.stringValue == conversationId,
              let accepted = epoch(root["epoch"]),
              let manifest = root["manifest"].flatMap(E2EEV2EpochManifest.signed(from:)),
              let served = root["envelope"] else {
            return nil
        }
        let envelope: E2EEV2SignedEpochEnvelope?
        if case .null = served {
            envelope = nil
        } else {
            guard let parsed = Self.envelope(served) else { return nil }
            envelope = parsed
        }
        return Current(accepted: accepted, manifest: manifest.manifest, recipients: manifest.recipients, envelope: envelope)
    }

    /// Réponse bornée, lue strictement : clés dupliquées et nombres refusés.
    static func object(_ data: Data) -> [String: E2EEV2JSON]? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes else { return nil }
        return (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue
    }

    static func epoch(_ value: E2EEV2JSON?) -> Accepted? {
        guard let epoch = value?.objectValue, Set(epoch.keys) == ["id", "epochNumber", "status", "createdAt"],
              let epochId = epoch["id"]?.stringValue, E2EEV2Canonical.isOpaque(epochId),
              let number = epoch["epochNumber"]?.stringValue.flatMap(E2EEV2Canonical.sequenceNumber),
              // « retired » : une époque remplacée depuis (relue après coup) ;
              // le client n'en décide rien.
              ["active", "retired"].contains(epoch["status"]?.stringValue ?? ""),
              let createdAt = epoch["createdAt"]?.stringValue, !createdAt.isEmpty, createdAt.count <= 64 else {
            return nil
        }
        return Accepted(epochId: epochId, epochNumber: number, createdAt: createdAt)
    }

    static func envelope(_ value: E2EEV2JSON?) -> E2EEV2SignedEpochEnvelope? {
        guard let object = value?.objectValue, Set(object.keys) == [
            "recipientDeviceId", "wrapAlgorithm", "ephemeralPublicKeyB64", "wrappedEpochKeyB64",
            "nonceB64", "aadB64", "signatureB64",
        ],
              let recipient = object["recipientDeviceId"]?.stringValue,
              let algorithm = object["wrapAlgorithm"]?.stringValue,
              let ephemeral = object["ephemeralPublicKeyB64"]?.stringValue,
              let wrapped = object["wrappedEpochKeyB64"]?.stringValue,
              let nonce = object["nonceB64"]?.stringValue,
              let aad = object["aadB64"]?.stringValue,
              let signature = object["signatureB64"]?.stringValue else { return nil }
        return E2EEV2SignedEpochEnvelope(
            recipientDeviceId: recipient, wrapAlgorithm: algorithm, ephemeralPublicKeyB64: ephemeral,
            wrappedEpochKeyB64: wrapped, nonceB64: nonce, aadB64: aad, signatureB64: signature
        )
    }
}

/// Époque servie par le serveur, vérifiée comme un destinataire (§3.5) avant
/// toute adoption : genèse enregistrée, manifeste signé par un appareil
/// certifié (clé lue dans l'annuaire), liaison à la chaîne relue, ligne exacte
/// de cet appareil parmi les destinataires, enveloppe signée par le créateur,
/// engagement de la clé.
enum E2EEV2EpochVerifierV2 {
    enum Outcome {
        case opened(epochKey: Data, manifest: E2EEV2EpochManifest, membership: E2EEV2MembershipState)
        /// La chaîne locale n'atteint pas l'état sur lequel repose l'époque.
        case needsMembershipSync
        /// Époque valide, mais cet appareil n'en est pas destinataire.
        case notRecipient
        case invalid
    }

    /// Verrou commun aux avancées d'époque (adoption, réception, rotation).
    private static let advanceLock = NSLock()

    static func open(
        _ served: E2EEV2EpochContractV2.Current,
        conversationId: String,
        ownUserId: String,
        ownDeviceId: String,
        genesis: E2EEV2ConversationStateStore.Genesis,
        previousMembershipChangeNumber: Int?,
        devices: E2EEV2CertifiedDeviceSet,
        membershipAt: (Int) -> E2EEV2MembershipState?,
        unwrap: (E2EEV2EpochDelivery) throws -> Data
    ) -> Outcome {
        let fields = served.manifest.canonical.components(separatedBy: "\n")
        guard genesis.conversationId == conversationId,
              fields.count == 13, let creatorKey = devices.signingKey(userId: fields[4], deviceId: fields[5]),
              let manifest = try? E2EEV2EpochManifest.verify(
                  served.manifest, recipients: served.recipients, creatorSigningKey: creatorKey
              ),
              manifest.conversationId == conversationId, manifest.epochNumber == served.accepted.epochNumber,
              // L'époque 1 est celle dont la genèse est enregistrée, et nulle autre.
              manifest.epochNumber != 1
                || E2EEV2Canonical.sha256B64URL(Data(served.manifest.canonical.utf8)) == genesis.manifestDigest else {
            return .invalid
        }
        guard let state = membershipAt(manifest.membershipChangeNumber) else { return .needsMembershipSync }
        let context = E2EEV2EpochContext(
            conversationId: conversationId, epochNumber: manifest.epochNumber,
            senderDeviceId: manifest.creatorDeviceId, recipientDeviceId: ownDeviceId
        )
        do {
            try E2EEV2EpochBinding.check(
                manifest, recipients: served.recipients, state: state,
                genesisLength: genesis.membershipChangeNumber,
                previousMembershipChangeNumber: previousMembershipChangeNumber
            )
            let lines = served.recipients.compactMap(E2EEV2EpochManifest.Recipient.parse)
            guard let ownLine = lines.first(where: { $0.deviceId == ownDeviceId }) else { return .notRecipient }
            // Notre ligne doit être exactement notre appareil certifié.
            guard let own = devices.device(userId: ownUserId, deviceId: ownDeviceId),
                  ownLine == E2EEV2EpochManifest.Recipient(
                      userId: own.userId, deviceId: own.deviceId, platform: own.platform, fingerprint: own.fingerprint
                  ) else {
                return .invalid
            }
            // Destinataire selon le manifeste, mais enveloppe déjà accusée
            // ailleurs ou retirée : la clé ne peut plus venir de là.
            guard let envelope = served.envelope else { return .notRecipient }
            guard envelope.recipientDeviceId == ownDeviceId,
                  let signature = Data(base64Encoded: envelope.signatureB64),
                  signature.base64EncodedString() == envelope.signatureB64,
                  E2EEV2LowS.verify(
                      derSignature: signature,
                      message: try E2EEV2EpochCrypto.signatureCanonical(
                          context: context, keyCommitmentB64: manifest.keyCommitmentB64,
                          envelope: envelope.cryptoEnvelope
                      ),
                      publicKey: creatorKey
                  ) else {
                return .invalid
            }
            let epochKey = try unwrap(E2EEV2EpochDelivery(
                conversationId: conversationId, epochId: served.accepted.epochId,
                epochNumber: manifest.epochNumber, keyCommitmentB64: manifest.keyCommitmentB64,
                reason: "ROTATION", status: "active", createdAt: served.accepted.createdAt,
                senderDeviceId: manifest.creatorDeviceId,
                senderPublicSigningKeyB64: creatorKey.x963Representation.base64EncodedString(),
                envelope: envelope
            ))
            return .opened(epochKey: epochKey, manifest: manifest, membership: state)
        } catch {
            return .invalid
        }
    }

    /// Une époque ne sert qu'acceptée. Sous un même verrou, sur une lecture
    /// fraîche de l'époque courante : refus d'un recul, PUIS clé gardée, puis
    /// époque courante avancée. Le pointeur de clé ne bouge jamais pour une
    /// époque qui recule.
    static func keep(
        epochKey: Data,
        accepted: E2EEV2EpochContractV2.Accepted,
        conversationId: String,
        commitment: String,
        membership: E2EEV2MembershipState,
        recipients: [String],
        createdAtMs: Int64,
        acceptedAtMs: Int64,
        session: LocalAccountSession,
        keyStore: E2EEV2EpochKeyStore,
        stateStore: E2EEV2ConversationStateStore
    ) -> Bool {
        advanceLock.lock()
        defer { advanceLock.unlock() }
        do {
            try stateStore.advanceCurrentEpoch(
                .init(
                    conversationId: conversationId, epochNumber: accepted.epochNumber,
                    membershipChangeNumber: membership.changeNumber, memberIds: membership.members.sorted(),
                    recipientsDigest: E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: recipients),
                    excludesWeb: membership.excludesWeb, createdAtMs: createdAtMs, acceptedAtMs: acceptedAtMs,
                    epochId: accepted.epochId, keyCommitmentB64: commitment
                ),
                ownerNamespace: session.ownerNamespace
            ) {
                guard try keyStore.put(
                    recordInput: .init(
                        conversationId: conversationId, epochId: accepted.epochId,
                        epochNumber: accepted.epochNumber, keyCommitmentB64: commitment
                    ),
                    epochKey: epochKey, ownerNamespace: session.ownerNamespace, expectedSession: session
                ) else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
            }
            return true
        } catch {
            return false
        }
    }
}

enum E2EEV2EpochRotationV2Result: Sendable, Equatable {
    case upToDate
    case rotated(epochNumber: Int)
    /// Une autre époque a été acceptée entre-temps : vérifiée et adoptée. La
    /// décision se refait sur elle.
    case adopted(epochNumber: Int)
    /// La chaîne d'appartenance locale est en retard : la synchroniser d'abord.
    case needsMembershipSync
    /// Des membres dont l'identité n'est pas crue (numéro changé, paquet
    /// refusé) : aucune époque ne les exclut en silence (§2.4).
    case membersNotTrusted([String])
    case failure(E2EEV2TransportFailure)
}

/// Crée l'époque suivante quand la règle l'exige (§3.3), en comparaison-échange
/// sur le numéro (§3.1). Sur conflit, relit l'époque acceptée, la vérifie comme
/// un destinataire (manifeste, liaison, enveloppe signée) et l'adopte.
final class E2EEV2EpochRotatorV2: @unchecked Sendable {
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

    /// `membershipAt` rend l'état de la chaîne relue jusqu'à un numéro, ou nil
    /// si la chaîne locale n'y arrive pas encore. `messageCount` : messages
    /// acceptés sous l'époque courante, comme pour l'envoi.
    func rotateIfNeeded(
        conversationId: String,
        membership: E2EEV2MembershipState,
        membershipAt: (Int) -> E2EEV2MembershipState?,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String,
        messageCount: Int = 0
    ) async -> E2EEV2EpochRotationV2Result {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:") else {
            return .failure(localError("invalid-e2ee-rotation-scope"))
        }
        let untrusted = devices.untrustedMembers(membership.members)
        guard untrusted.isEmpty else { return .membersNotTrusted(untrusted) }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        guard let device = try? identityStore.load(ownerNamespace: ownerNamespace),
              let genesis = try? stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace),
              let current = try? stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace),
              membership.changeNumber >= current.membershipChangeNumber,
              current.epochNumber < E2EEV2Canonical.maxSequenceNumber else {
            return .failure(localError("e2ee-rotation-state-unavailable"))
        }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let expected = E2EEV2EpochProposals.recipients(
            devices, members: membership.members, excludesWeb: membership.excludesWeb, nowMs: nowMs
        )
        let lines = expected.map {
            E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint)
        }
        guard !E2EEV2RotationPolicy.reasons(
            current: current, membership: membership, expectedRecipients: lines, nowMs: nowMs, messageCount: messageCount
        ).isEmpty else { return .upToDate }
        guard let ownCertified = devices.device(userId: ownUserId, deviceId: device.deviceId),
              ownCertified.signingKeyB64 == device.publicSigningKeyB64,
              let signingKey = ownCertified.signingKey,
              expected.contains(where: { $0.deviceId == device.deviceId }) else {
            return .failure(localError("e2ee-device-not-certified"))
        }

        var epochKey = Data(count: 32)
        let status = epochKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        guard status == errSecSuccess else { return .failure(localError("e2ee-epoch-random-generation-failed")) }
        let epochNumber = current.epochNumber + 1
        let proposal: E2EEV2EpochProposal
        do {
            proposal = try E2EEV2EpochProposals.make(
                conversationId: conversationId, epochNumber: epochNumber,
                creator: .init(userId: ownUserId, deviceId: device.deviceId), creatorSigningKey: signingKey,
                recipients: expected, membership: membership, genesisLength: genesis.membershipChangeNumber,
                previousMembershipChangeNumber: current.membershipChangeNumber,
                epochKey: epochKey, nowMs: nowMs,
                sign: { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) },
                wrap: { [identityStore] context, recipientKey in
                    try identityStore.createSignedEpochEnvelope(
                        context: context, epochKey: epochKey, recipientPublicIdentityKeyB64: recipientKey,
                        ownerNamespace: ownerNamespace
                    )
                }
            )
        } catch {
            return .failure(localError("e2ee-epoch-proposal-invalid"))
        }

        let bound = transport.bound(to: session)
        switch await bound.postJSON(
            path: "/api/e2ee/v2/conversations/\(conversationId)/epochs",
            body: E2EEV2CanonicalJSON.encode(proposal.json),
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let error) where error.statusCode == 409 && error.code == "E2EE_MEMBERSHIP_STALE":
            return .needsMembershipSync
        case .failure(let error) where error.statusCode == 409 && error.code == "E2EE_EPOCH_STALE":
            return await adopt(
                conversationId: conversationId, current: current, genesis: genesis, ownUserId: ownUserId,
                ownDeviceId: device.deviceId, membershipAt: membershipAt, devices: devices, transport: bound,
                session: session, expectedOwnerScopeId: expectedOwnerScopeId
            )
        case .failure(let error):
            return .failure(error)
        case .success(let data, _, _):
            guard session.isCurrent,
                  let accepted = E2EEV2EpochContractV2.parseReceipt(
                      data, epochNumber: epochNumber, recipientCount: proposal.envelopes.count
                  ) else {
                return .failure(localError("invalid-e2ee-epoch-receipt"))
            }
            return keep(
                epochKey: epochKey, accepted: accepted, conversationId: conversationId,
                commitment: proposal.keyCommitmentB64, membership: membership, recipients: proposal.recipients,
                createdAtMs: proposal.createdAtMs, session: session
            ) ? .rotated(epochNumber: epochNumber) : .failure(localError("e2ee-rotated-epoch-storage-failed"))
        }
    }

    private func adopt(
        conversationId: String,
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        genesis: E2EEV2ConversationStateStore.Genesis,
        ownUserId: String,
        ownDeviceId: String,
        membershipAt: (Int) -> E2EEV2MembershipState?,
        devices: E2EEV2CertifiedDeviceSet,
        transport: E2EEV2APITransport,
        session: LocalAccountSession,
        expectedOwnerScopeId: String
    ) async -> E2EEV2EpochRotationV2Result {
        let data: Data
        switch await transport.getJSON(
            path: "/api/e2ee/v2/conversations/\(conversationId)/epochs/current",
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let error): return .failure(error)
        case .success(let value, _, _): data = value
        }
        guard session.isCurrent, let served = E2EEV2EpochContractV2.parseCurrent(data, conversationId: conversationId),
              served.accepted.epochNumber > current.epochNumber else {
            return .failure(localError("invalid-e2ee-current-epoch"))
        }
        switch E2EEV2EpochVerifierV2.open(
            served, conversationId: conversationId, ownUserId: ownUserId, ownDeviceId: ownDeviceId, genesis: genesis,
            previousMembershipChangeNumber: current.membershipChangeNumber, devices: devices,
            membershipAt: membershipAt,
            unwrap: { [identityStore] in try identityStore.unwrapEpochKey(delivery: $0, ownerNamespace: session.ownerNamespace) }
        ) {
        case .needsMembershipSync:
            return .needsMembershipSync
        case .notRecipient, .invalid:
            return .failure(localError("invalid-e2ee-current-epoch"))
        case .opened(var epochKey, let manifest, let state):
            defer { epochKey.resetBytes(in: 0..<epochKey.count) }
            guard keep(
                epochKey: epochKey, accepted: served.accepted, conversationId: conversationId,
                commitment: manifest.keyCommitmentB64, membership: state, recipients: served.recipients,
                createdAtMs: manifest.createdAtMs, session: session
            ) else { return .failure(localError("e2ee-adopted-epoch-storage-failed")) }
            // Accusé une fois la clé gardée (E.2) ; un accusé perdu se refait.
            if session.isCurrent {
                _ = await transport.postJSON(
                    path: "/api/e2ee/v2/conversations/\(conversationId)/epochs/\(manifest.epochNumber)/ack", body: Data(),
                    expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
                )
            }
            return .adopted(epochNumber: manifest.epochNumber)
        }
    }

    private func keep(
        epochKey: Data,
        accepted: E2EEV2EpochContractV2.Accepted,
        conversationId: String,
        commitment: String,
        membership: E2EEV2MembershipState,
        recipients: [String],
        createdAtMs: Int64,
        session: LocalAccountSession
    ) -> Bool {
        E2EEV2EpochVerifierV2.keep(
            epochKey: epochKey, accepted: accepted, conversationId: conversationId, commitment: commitment,
            membership: membership, recipients: recipients, createdAtMs: createdAtMs,
            acceptedAtMs: Int64(now().timeIntervalSince1970 * 1_000), session: session,
            keyStore: keyStore, stateStore: stateStore
        )
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
