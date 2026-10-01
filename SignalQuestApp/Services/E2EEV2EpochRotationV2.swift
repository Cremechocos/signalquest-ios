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
        /// 30 jours au plus par époque.
        case age
    }

    static let maxEpochAgeMs: Int64 = 30 * 24 * 60 * 60 * 1_000

    static func reasons(
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        membership: E2EEV2MembershipState,
        expectedRecipients: [String],
        nowMs: Int64
    ) -> [Reason] {
        var reasons: [Reason] = []
        if Set(current.memberIds) != membership.members { reasons.append(.members) }
        if E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: expectedRecipients)
            != current.recipientsDigest {
            reasons.append(.devices)
        }
        if current.excludesWeb != membership.excludesWeb { reasons.append(.browsers) }
        if nowMs - current.createdAtMs >= maxEpochAgeMs { reasons.append(.age) }
        return reasons
    }
}

/// Réponses du serveur aux routes d'époque v2 (proposition iOS, E.2).
enum E2EEV2EpochContractV2 {
    struct Accepted: Equatable, Sendable {
        let epochId: String
        let epochNumber: Int
        let createdAt: String
    }

    /// Époque courante servie à un appareil : l'époque acceptée, son manifeste
    /// et l'enveloppe de cet appareil.
    struct Current: Equatable, Sendable {
        let accepted: Accepted
        let manifest: E2EEV2SignedString
        let recipients: [String]
        let envelope: E2EEV2SignedEpochEnvelope
    }

    /// `{epoch: {id, epochNumber, status, createdAt}, recipientCount}`.
    static func parseReceipt(_ data: Data, epochNumber: Int, recipientCount: Int) -> Accepted? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["epoch", "recipientCount"],
              let accepted = epoch(root["epoch"]), accepted.epochNumber == epochNumber,
              root["recipientCount"] as? Int == recipientCount else { return nil }
        return accepted
    }

    /// `{conversationId, epoch: {…}, manifest: {manifest, signatureB64, recipients}, envelope: {A.3}}`.
    static func parseCurrent(_ data: Data, conversationId: String) -> Current? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["conversationId", "epoch", "manifest", "envelope"],
              root["conversationId"] as? String == conversationId,
              let accepted = epoch(root["epoch"]),
              let manifest = E2EEV2EpochManifest.signed(from: json(root["manifest"])),
              let envelopeObject = root["envelope"] as? [String: Any],
              Set(envelopeObject.keys) == [
                  "recipientDeviceId", "wrapAlgorithm", "ephemeralPublicKeyB64", "wrappedEpochKeyB64",
                  "nonceB64", "aadB64", "signatureB64",
              ],
              let envelopeData = try? JSONSerialization.data(withJSONObject: envelopeObject),
              let envelope = try? JSONDecoder().decode(E2EEV2SignedEpochEnvelope.self, from: envelopeData) else {
            return nil
        }
        return Current(accepted: accepted, manifest: manifest.manifest, recipients: manifest.recipients, envelope: envelope)
    }

    private static func epoch(_ value: Any?) -> Accepted? {
        guard let epoch = value as? [String: Any], Set(epoch.keys) == ["id", "epochNumber", "status", "createdAt"],
              let epochId = epoch["id"] as? String, E2EEV2Canonical.isOpaque(epochId),
              let number = epoch["epochNumber"] as? Int, number >= 1, epoch["status"] as? String == "active",
              let createdAt = epoch["createdAt"] as? String, !createdAt.isEmpty, createdAt.count <= 64 else {
            return nil
        }
        return Accepted(epochId: epochId, epochNumber: number, createdAt: createdAt)
    }

    /// Le manifeste ne porte que des chaînes et des tableaux : tout autre type
    /// devient `null`, que la lecture stricte refuse.
    private static func json(_ value: Any?) -> E2EEV2JSON {
        switch value {
        case let text as String: return .string(text)
        case let items as [Any]: return .array(items.map(json))
        case let object as [String: Any]: return .object(object.mapValues(json))
        default: return .null
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
    /// si la chaîne locale n'y arrive pas encore.
    func rotateIfNeeded(
        conversationId: String,
        membership: E2EEV2MembershipState,
        membershipAt: (Int) -> E2EEV2MembershipState?,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2EpochRotationV2Result {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:") else {
            return .failure(localError("invalid-e2ee-rotation-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        guard let device = try? identityStore.load(ownerNamespace: ownerNamespace),
              let current = try? stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace),
              membership.changeNumber >= current.membershipChangeNumber else {
            return .failure(localError("e2ee-rotation-state-unavailable"))
        }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let expected = E2EEV2EpochProposals.recipients(
            devices, members: membership.members, excludesWeb: membership.excludesWeb, nowMs: nowMs
        )
        let lines = expected.map {
            E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint)
        }
        guard !E2EEV2RotationPolicy.reasons(current: current, membership: membership, expectedRecipients: lines, nowMs: nowMs).isEmpty
        else { return .upToDate }
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
                recipients: expected, membership: membership,
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
                conversationId: conversationId, current: current, ownDeviceId: device.deviceId,
                membershipAt: membershipAt, devices: devices, transport: bound, session: session,
                expectedOwnerScopeId: expectedOwnerScopeId
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
        // Le créateur se lit dans la chaîne signée, sa clé dans l'annuaire.
        let fields = served.manifest.canonical.components(separatedBy: "\n")
        guard fields.count == 13, let creatorKey = devices.signingKey(userId: fields[4], deviceId: fields[5]),
              let manifest = try? E2EEV2EpochManifest.verify(
                  served.manifest, recipients: served.recipients, creatorSigningKey: creatorKey
              ),
              manifest.conversationId == conversationId, manifest.epochNumber == served.accepted.epochNumber else {
            return .failure(localError("invalid-e2ee-current-epoch"))
        }
        guard let state = membershipAt(manifest.membershipChangeNumber) else { return .needsMembershipSync }
        let context = E2EEV2EpochContext(
            conversationId: conversationId, epochNumber: manifest.epochNumber,
            senderDeviceId: manifest.creatorDeviceId, recipientDeviceId: ownDeviceId
        )
        var epochKey: Data
        do {
            try E2EEV2EpochBinding.check(
                manifest, recipients: served.recipients, state: state,
                previousMembershipChangeNumber: current.membershipChangeNumber
            )
            guard served.recipients.compactMap(E2EEV2EpochManifest.Recipient.parse).contains(where: { $0.deviceId == ownDeviceId }),
                  served.envelope.recipientDeviceId == ownDeviceId,
                  let signature = Data(base64Encoded: served.envelope.signatureB64),
                  E2EEV2LowS.verify(
                      derSignature: signature,
                      message: try E2EEV2EpochCrypto.signatureCanonical(
                          context: context, keyCommitmentB64: manifest.keyCommitmentB64,
                          envelope: served.envelope.cryptoEnvelope
                      ),
                      publicKey: creatorKey
                  ) else {
                return .failure(localError("invalid-e2ee-current-epoch"))
            }
            epochKey = try identityStore.unwrapEpochKey(
                delivery: E2EEV2EpochDelivery(
                    conversationId: conversationId, epochId: served.accepted.epochId,
                    epochNumber: manifest.epochNumber, keyCommitmentB64: manifest.keyCommitmentB64,
                    reason: "ROTATION", status: "active", createdAt: served.accepted.createdAt,
                    senderDeviceId: manifest.creatorDeviceId, senderPublicSigningKeyB64: creatorKey.x963Representation.base64EncodedString(),
                    envelope: served.envelope
                ),
                ownerNamespace: session.ownerNamespace
            )
        } catch {
            return .failure(localError("invalid-e2ee-current-epoch"))
        }
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        return keep(
            epochKey: epochKey, accepted: served.accepted, conversationId: conversationId,
            commitment: manifest.keyCommitmentB64, membership: state, recipients: served.recipients,
            createdAtMs: manifest.createdAtMs, session: session
        ) ? .adopted(epochNumber: manifest.epochNumber) : .failure(localError("e2ee-adopted-epoch-storage-failed"))
    }

    /// Une époque ne sert qu'acceptée : clé gardée, puis époque courante avancée.
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
        do {
            guard try keyStore.put(
                recordInput: .init(
                    conversationId: conversationId, epochId: accepted.epochId,
                    epochNumber: accepted.epochNumber, keyCommitmentB64: commitment
                ),
                epochKey: epochKey, ownerNamespace: session.ownerNamespace, expectedSession: session
            ) else { return false }
            try stateStore.recordCurrentEpoch(
                .init(
                    conversationId: conversationId, epochNumber: accepted.epochNumber,
                    membershipChangeNumber: membership.changeNumber, memberIds: membership.members.sorted(),
                    recipientsDigest: E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: recipients),
                    excludesWeb: membership.excludesWeb, createdAtMs: createdAtMs
                ),
                ownerNamespace: session.ownerNamespace
            )
            return true
        } catch {
            return false
        }
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
