import Foundation

/// Réponses des routes de réception v2 (proposition iOS, E.2).
enum E2EEV2MembershipContractV2 {
    static let pageLimit = 100

    /// `{changes: [{change, signatureB64}], hasMore}`.
    static func parsePage(_ data: Data) -> (changes: [E2EEV2SignedString], hasMore: Bool)? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["changes", "hasMore"],
              let items = root["changes"] as? [Any], items.count <= pageLimit,
              let hasMore = root["hasMore"] as? Bool else { return nil }
        let changes = items.compactMap { E2EEV2MembershipChange.signed(from: E2EEV2EpochContractV2.json($0)) }
        // Une page vide qui en annonce d'autres bouclerait.
        guard changes.count == items.count, !(hasMore && changes.isEmpty) else { return nil }
        return (changes, hasMore)
    }

    /// `{epochNumber, manifest: {manifest, signatureB64, recipients}}`.
    static func parseManifest(_ data: Data, epochNumber: Int) -> (manifest: E2EEV2SignedString, recipients: [String])? {
        guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["epochNumber", "manifest"], root["epochNumber"] as? Int == epochNumber else {
            return nil
        }
        return E2EEV2EpochManifest.signed(from: E2EEV2EpochContractV2.json(root["manifest"]))
    }
}

enum E2EEV2ConversationSyncResult: Sendable, Equatable {
    case upToDate(epochNumber: Int)
    case received(epochNumber: Int)
    /// Cet appareil n'est pas encore destinataire : il le sera à la prochaine
    /// époque, qu'un autre membre crée (§3.2).
    case waitingForEpoch
    case failure(E2EEV2TransportFailure)
}

/// Réception d'une conversation v2 par un membre (§3.4, §3.5, §12) : chaîne
/// d'appartenance relue et gardée ; genèse vérifiée sur le manifeste de
/// l'époque 1, qui rend la conversation v2 pour toujours ; époque courante
/// vérifiée comme un destinataire, puis gardée.
final class E2EEV2ConversationSyncV2: @unchecked Sendable {
    static let maxPages = 20

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

    /// `devices` couvre chaque auteur de la chaîne, anciens membres compris : un
    /// changement signé par un appareil inconnu de l'annuaire fait échouer la
    /// relecture, fermée par défaut.
    func sync(
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2ConversationSyncResult {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId) else {
            return .failure(localError("invalid-e2ee-sync-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        guard let device = try? identityStore.load(ownerNamespace: ownerNamespace),
              let known = try? stateStore.membershipChain(conversationId: conversationId, ownerNamespace: ownerNamespace)
        else { return .failure(localError("e2ee-sync-state-unavailable")) }
        let bound = transport.bound(to: session)
        let base = "/api/e2ee/v2/conversations/\(conversationId)"
        let signingKey = { (userId: String, deviceId: String) in devices.signingKey(userId: userId, deviceId: deviceId) }

        // 1. La suite de la chaîne d'appartenance.
        var fresh: [E2EEV2SignedString] = []
        pages: for _ in 0..<Self.maxPages {
            switch await bound.getJSON(
                path: "\(base)/membership",
                query: [URLQueryItem(name: "after", value: String(known.count + fresh.count))],
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            ) {
            case .failure(let error): return .failure(error)
            case .success(let data, _, _):
                guard let page = E2EEV2MembershipContractV2.parsePage(data) else {
                    return .failure(localError("invalid-e2ee-membership-page"))
                }
                fresh += page.changes
                if !page.hasMore { break pages }
            }
        }
        let all = known + fresh

        // 2. La genèse, vérifiée une fois sur le manifeste de l'époque 1.
        let genesisLength: Int
        do {
            if let genesis = try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) {
                genesisLength = genesis.membershipChangeNumber
            } else {
                let data: Data
                switch await bound.getJSON(
                    path: "\(base)/epochs/1/manifest", expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
                ) {
                case .failure(let error): return .failure(error)
                case .success(let value, _, _): data = value
                }
                guard let served = E2EEV2MembershipContractV2.parseManifest(data, epochNumber: 1) else {
                    return .failure(localError("invalid-e2ee-genesis-manifest"))
                }
                let fields = served.manifest.canonical.components(separatedBy: "\n")
                guard fields.count == 13, let creatorKey = signingKey(fields[4], fields[5]) else {
                    return .failure(localError("invalid-e2ee-genesis-manifest"))
                }
                let manifest = try E2EEV2EpochManifest.verify(
                    served.manifest, recipients: served.recipients, creatorSigningKey: creatorKey
                )
                guard manifest.conversationId == conversationId, all.count >= manifest.membershipChangeNumber else {
                    return .failure(localError("invalid-e2ee-genesis-manifest"))
                }
                _ = try E2EEV2EpochBinding.verifyGenesis(
                    manifest, recipients: served.recipients, chain: Array(all.prefix(manifest.membershipChangeNumber)),
                    isGroup: isGroup, signingKey: signingKey
                )
                try stateStore.record(
                    .init(
                        conversationId: conversationId, creatorUserId: manifest.creatorUserId,
                        creatorDeviceId: manifest.creatorDeviceId,
                        manifestDigest: E2EEV2Canonical.sha256B64URL(Data(served.manifest.canonical.utf8)),
                        membershipChangeNumber: manifest.membershipChangeNumber,
                        recordedAtMs: Int64(now().timeIntervalSince1970 * 1_000)
                    ),
                    ownerNamespace: ownerNamespace
                )
                genesisLength = manifest.membershipChangeNumber
            }
            // Toute la chaîne est relue, la suite comprise, avant d'être gardée.
            _ = try E2EEV2MembershipChain.apply(
                all, conversationId: conversationId, isGroup: isGroup, genesisLength: genesisLength, signingKey: signingKey
            )
            try stateStore.appendMembership(fresh, conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return .failure(localError("invalid-e2ee-membership"))
        }
        guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }

        // 3. L'époque courante.
        let data: Data
        switch await bound.getJSON(
            path: "\(base)/epochs/current", expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .failure(let error) where error.statusCode == 404 && error.code == "E2EE_EPOCH_ENVELOPE_NOT_FOUND":
            return .waitingForEpoch
        case .failure(let error): return .failure(error)
        case .success(let value, _, _): data = value
        }
        guard let served = E2EEV2EpochContractV2.parseCurrent(data, conversationId: conversationId) else {
            return .failure(localError("invalid-e2ee-current-epoch"))
        }
        let current: E2EEV2ConversationStateStore.CurrentEpoch?
        do {
            current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return .failure(localError("e2ee-sync-state-unavailable"))
        }
        if let current, served.accepted.epochNumber <= current.epochNumber {
            return .upToDate(epochNumber: current.epochNumber)
        }
        let membershipAt = { (number: Int) -> E2EEV2MembershipState? in
            guard number >= genesisLength, number <= all.count else { return nil }
            return try? E2EEV2MembershipChain.apply(
                Array(all.prefix(number)), conversationId: conversationId, isGroup: isGroup,
                genesisLength: genesisLength, signingKey: signingKey
            )
        }
        switch E2EEV2EpochVerifierV2.open(
            served, conversationId: conversationId, ownDeviceId: device.deviceId,
            previousMembershipChangeNumber: current?.membershipChangeNumber, devices: devices,
            membershipAt: membershipAt,
            unwrap: { [identityStore] in try identityStore.unwrapEpochKey(delivery: $0, ownerNamespace: ownerNamespace) }
        ) {
        case .notRecipient:
            return .waitingForEpoch
        case .needsMembershipSync:
            return .failure(localError("e2ee-membership-behind"))
        case .invalid:
            return .failure(localError("invalid-e2ee-current-epoch"))
        case .opened(var epochKey, let manifest, let state):
            defer { epochKey.resetBytes(in: 0..<epochKey.count) }
            return E2EEV2EpochVerifierV2.keep(
                epochKey: epochKey, accepted: served.accepted, conversationId: conversationId,
                commitment: manifest.keyCommitmentB64, membership: state, recipients: served.recipients,
                createdAtMs: manifest.createdAtMs, session: session, keyStore: keyStore, stateStore: stateStore
            ) ? .received(epochNumber: manifest.epochNumber) : .failure(localError("e2ee-received-epoch-storage-failed"))
        }
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
