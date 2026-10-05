import Foundation

/// Réponses des routes de réception v2 (proposition iOS, E.2).
enum E2EEV2MembershipContractV2 {
    static let pageLimit = 100

    /// `{changes: [{change, signatureB64}], hasMore}`.
    static func parsePage(_ data: Data) -> (changes: [E2EEV2SignedString], hasMore: Bool)? {
        guard let root = E2EEV2EpochContractV2.object(data), Set(root.keys) == ["changes", "hasMore"],
              let items = root["changes"]?.arrayValue, items.count <= pageLimit,
              let hasMore = root["hasMore"]?.boolValue else { return nil }
        let changes = items.compactMap(E2EEV2MembershipChange.signed(from:))
        // Une page vide qui en annonce d'autres bouclerait.
        guard changes.count == items.count, !(hasMore && changes.isEmpty) else { return nil }
        return (changes, hasMore)
    }

    /// `{epochNumber, manifest: {manifest, signatureB64, recipients}}`, entiers en chaînes.
    static func parseManifest(_ data: Data, epochNumber: Int) -> (manifest: E2EEV2SignedString, recipients: [String])? {
        guard let root = E2EEV2EpochContractV2.object(data), Set(root.keys) == ["epochNumber", "manifest"],
              root["epochNumber"]?.stringValue == String(epochNumber) else {
            return nil
        }
        return root["manifest"].flatMap(E2EEV2EpochManifest.signed(from:))
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
    /// Au-delà, les époques sautées ne sont pas relues une à une : leurs
    /// messages, sans doute hors de la fenêtre de 24 heures, sont perdus.
    static let maxSkippedEpochs = 32

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
        // Auteurs et cibles des changements nouveaux (toute la chaîne, créateur
        // compris, à la découverte) que l'annuaire n'a pas encore lus, par exemple
        // partis du groupe : nommés pour relecture, comme le serveur le ferait,
        // plutôt qu'un échec de vérification. La chaîne gardée, déjà vérifiée,
        // n'exige pas de relire ses anciens auteurs.
        var unread = Set<String>()
        for change in fresh {
            guard let fields = E2EEV2Canonical.split(change.canonical, tag: E2EEV2MembershipChange.tag, version: "1", fieldCount: 10)
            else { continue }
            for userId in [fields[5], fields[6]] where E2EEV2Canonical.isOpaque(userId)
                && devices.devicesByUser[userId] == nil && devices.refusals[userId] == nil {
                unread.insert(userId)
            }
        }
        if !unread.isEmpty {
            return .failure(E2EEV2TransportFailure(
                kind: .localState, code: "E2EE_DEVICE_LIST_STALE", message: "e2ee-membership-authors-unread",
                details: ["userIds": .array(unread.sorted().map { .string($0) })]
            ))
        }

        // 2. La genèse : vérifiée une fois sur le manifeste de l'époque 1, puis
        //    revérifiée à chaque passage (longueur, condensat, auteur). Rien
        //    n'est écrit avant que toute la chaîne soit relue.
        let genesis: E2EEV2ConversationStateStore.Genesis
        let isNewGenesis: Bool
        do {
            if let recorded = try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) {
                genesis = recorded
                isNewGenesis = false
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
                guard manifest.conversationId == conversationId, manifest.epochNumber == 1,
                      all.count >= manifest.membershipChangeNumber else {
                    return .failure(localError("invalid-e2ee-genesis-manifest"))
                }
                _ = try E2EEV2EpochBinding.verifyGenesis(
                    manifest, recipients: served.recipients, chain: Array(all.prefix(manifest.membershipChangeNumber)),
                    isGroup: isGroup, signingKey: signingKey
                )
                genesis = .init(
                    conversationId: conversationId, creatorUserId: manifest.creatorUserId,
                    creatorDeviceId: manifest.creatorDeviceId,
                    manifestDigest: E2EEV2Canonical.sha256B64URL(Data(served.manifest.canonical.utf8)),
                    membershipChangeNumber: manifest.membershipChangeNumber,
                    membershipDigest: manifest.membershipDigest,
                    recordedAtMs: Int64(now().timeIntervalSince1970 * 1_000)
                )
                isNewGenesis = true
            }
            guard all.count >= genesis.membershipChangeNumber,
                  E2EEV2MembershipChange.digest(of: all[genesis.membershipChangeNumber - 1].canonical) == genesis.membershipDigest
            else { return .failure(localError("invalid-e2ee-membership")) }
            // Toute la chaîne est relue, la suite comprise ; la partie déjà
            // gardée l'a été vérifiée, sans dépendre de l'annuaire du jour.
            let head = try E2EEV2MembershipChain.apply(
                all, conversationId: conversationId, isGroup: isGroup, genesisLength: genesis.membershipChangeNumber,
                verifiedCount: known.count, signingKey: signingKey
            )
            guard head.genesisActor == E2EEV2MembershipChain.Actor(userId: genesis.creatorUserId, deviceId: genesis.creatorDeviceId)
            else { return .failure(localError("invalid-e2ee-membership")) }
            // Chaîne d'abord, genèse ensuite : une genèse n'est jamais gardée
            // sans la chaîne qui la porte.
            try stateStore.appendMembership(fresh, conversationId: conversationId, ownerNamespace: ownerNamespace)
            if isNewGenesis { try stateStore.record(genesis, ownerNamespace: ownerNamespace) }
        } catch {
            return .failure(localError("invalid-e2ee-membership"))
        }
        guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }

        // 3. L'époque courante, et celles qu'elle a sautées depuis la dernière
        //    relue : leurs messages en vol se lisent encore (§3.4, E.2).
        let served: E2EEV2EpochContractV2.Current
        switch await bound.getJSON(
            path: "\(base)/epochs/current", expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .failure(let error) where error.statusCode == 404 && error.code == "E2EE_EPOCH_ENVELOPE_NOT_FOUND":
            return .waitingForEpoch
        case .failure(let error): return .failure(error)
        case .success(let value, _, _):
            guard let parsed = E2EEV2EpochContractV2.parseCurrent(value, conversationId: conversationId) else {
                return .failure(localError("invalid-e2ee-current-epoch"))
            }
            served = parsed
        }
        let knownEpoch: E2EEV2ConversationStateStore.CurrentEpoch?
        do {
            knownEpoch = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return .failure(localError("e2ee-sync-state-unavailable"))
        }
        if let knownEpoch, served.accepted.epochNumber <= knownEpoch.epochNumber {
            // Accusé perdu, du créateur comme d'un destinataire : le serveur sert
            // encore notre enveloppe d'une époque dont la clé est gardée. L'accusé,
            // idempotent, se rejoue à chaque relève jusqu'à `envelope: null` (E.2, v0.4.26).
            if served.envelope != nil, served.accepted.epochNumber == knownEpoch.epochNumber,
               served.accepted.epochId == knownEpoch.epochId, session.isCurrent {
                _ = await bound.postJSON(
                    path: "\(base)/epochs/\(knownEpoch.epochNumber)/ack", body: Data(),
                    expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
                )
            }
            return .upToDate(epochNumber: knownEpoch.epochNumber)
        }
        let membershipAt = { (number: Int) -> E2EEV2MembershipState? in
            guard number >= genesis.membershipChangeNumber, number <= all.count else { return nil }
            return try? E2EEV2MembershipChain.apply(
                Array(all.prefix(number)), conversationId: conversationId, isGroup: isGroup,
                genesisLength: genesis.membershipChangeNumber, verifiedCount: all.count, signingKey: signingKey
            )
        }
        // Époques dont la clé vient d'être gardée : accusées en fin de relève (E.2).
        var kept: [Int] = []
        let open = { (epoch: E2EEV2EpochContractV2.Current) -> E2EEV2ConversationSyncResult? in
            let previous = try? self.stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
            switch E2EEV2EpochVerifierV2.open(
                epoch, conversationId: conversationId, ownUserId: String(expectedOwnerScopeId.dropFirst("user:".count)),
                ownDeviceId: device.deviceId, genesis: genesis,
                previousMembershipChangeNumber: previous?.membershipChangeNumber, devices: devices,
                membershipAt: membershipAt,
                unwrap: { [identityStore = self.identityStore] in
                    try identityStore.unwrapEpochKey(delivery: $0, ownerNamespace: ownerNamespace)
                }
            ) {
            case .notRecipient:
                return .waitingForEpoch
            case .needsMembershipSync:
                return .failure(self.localError("e2ee-membership-behind"))
            case .invalid:
                return .failure(self.localError("invalid-e2ee-current-epoch"))
            case .opened(var epochKey, let manifest, let state):
                defer { epochKey.resetBytes(in: 0..<epochKey.count) }
                guard E2EEV2EpochVerifierV2.keep(
                    epochKey: epochKey, accepted: epoch.accepted, conversationId: conversationId,
                    commitment: manifest.keyCommitmentB64, membership: state, recipients: epoch.recipients,
                    createdAtMs: manifest.createdAtMs, acceptedAtMs: Int64(self.now().timeIntervalSince1970 * 1_000),
                    session: session, keyStore: self.keyStore, stateStore: self.stateStore
                ) else { return .failure(self.localError("e2ee-received-epoch-storage-failed")) }
                kept.append(manifest.epochNumber)
                return nil
            }
        }
        // Époques sautées, dans l'ordre. Celle dont l'appareil n'est pas
        // destinataire ne se lit pas : ses messages non plus.
        if let knownEpoch, served.accepted.epochNumber - knownEpoch.epochNumber <= Self.maxSkippedEpochs {
            for number in (knownEpoch.epochNumber + 1)..<served.accepted.epochNumber {
                switch await bound.getJSON(
                    path: "\(base)/epochs/\(number)", expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
                ) {
                case .failure(let error) where error.statusCode == 404 && error.code == "E2EE_EPOCH_ENVELOPE_NOT_FOUND":
                    continue
                case .failure(let error): return .failure(error)
                case .success(let value, _, _):
                    guard let skipped = E2EEV2EpochContractV2.parseCurrent(value, conversationId: conversationId),
                          skipped.accepted.epochNumber == number else {
                        return .failure(localError("invalid-e2ee-current-epoch"))
                    }
                    if let result = open(skipped), result != .waitingForEpoch { return result }
                }
            }
        }
        guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
        let result = open(served) ?? .received(epochNumber: served.accepted.epochNumber)
        // Accusé une fois la clé gardée : le serveur passe l'enveloppe en ligne
        // témoin (§2.6). Sans effet sur le résultat : un accusé perdu se refait.
        for number in kept where session.isCurrent {
            _ = await bound.postJSON(
                path: "\(base)/epochs/\(number)/ack", body: Data(),
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            )
        }
        return result
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
