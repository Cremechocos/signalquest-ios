import Foundation

/// Ce qu'une conversation v2 montre après une relève.
struct E2EEV2MessagesV2: Equatable, Sendable {
    let snapshot: E2EEV2MessageStoreV2.Snapshot
    /// Messages authentiques d'un contenu inconnu de cette app (§5.2), lus
    /// pendant cette relève.
    let unsupported: [String]
    /// Messages manquants par appareil émetteur (§4.3), évalués seulement une
    /// fois la liste rattrapée ; sinon vide.
    let missingByDevice: [String: Int]
    /// L'appareil n'est pas encore destinataire de l'époque courante (§3.2).
    let waitingForEpoch: Bool
}

enum E2EEV2RefreshResultV2: Equatable, Sendable {
    case refreshed(E2EEV2MessagesV2)
    case failure(E2EEV2TransportFailure)
}

/// Messagerie v2 d'une conversation (§3, §4, E.2, E.3), au-dessus des briques
/// vérifiées : synchronisation de la chaîne et des époques, relève de la
/// liste, envoi, changements d'appartenance. La rotation décidée par
/// l'appareil (§3.3) y passe avant tout envoi, et aussitôt après un retrait
/// ou un départ.
final class E2EEV2ConversationMessagingV2: @unchecked Sendable {
    static let maxPages = 20
    /// Relèves arrêtées sur un même message avant de le dépasser : un appareil
    /// révoqué reste inconnu de l'annuaire, et rien ne doit bloquer la liste.
    static let maxRereads = 3
    /// Tentatives d'un envoi : rotation ou synchronisation, puis envoi.
    static let maxSendRounds = 3

    private let transport: E2EEV2APITransport
    private let stateStore: E2EEV2ConversationStateStore
    private let ledgerStore: E2EEV2MessageLedgerStore
    private let messageStore: E2EEV2MessageStoreV2
    private let syncer: E2EEV2ConversationSyncV2
    private let rotator: E2EEV2EpochRotatorV2
    private let sender: E2EEV2MessageSenderV2
    private let receiver: E2EEV2MessageReceiverV2
    private let writer: E2EEV2MembershipWriterV2
    /// Entrées du miroir de notification (§2.6) : retirées avant tout ce qui
    /// peut changer l'état de la conversation, réécrites seulement après une
    /// relève, un envoi ou un changement réussis.
    private let notificationMirror: E2EEV2NotificationMirrorWriter?
    private let expectedSession: LocalAccountSession?
    private let now: @Sendable () -> Date

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        ledgerStore: E2EEV2MessageLedgerStore,
        messageStore: E2EEV2MessageStoreV2,
        notificationMirror: E2EEV2NotificationMirrorWriter? = nil,
        expectedSession: LocalAccountSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.notificationMirror = notificationMirror
        self.stateStore = stateStore
        self.ledgerStore = ledgerStore
        self.messageStore = messageStore
        self.expectedSession = expectedSession
        self.now = now
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        syncer = E2EEV2ConversationSyncV2(
            api: api, identityStore: identityStore, keyStore: keyStore, stateStore: stateStore,
            expectedSession: expectedSession, now: now
        )
        rotator = E2EEV2EpochRotatorV2(
            api: api, identityStore: identityStore, keyStore: keyStore, stateStore: stateStore,
            expectedSession: expectedSession, now: now
        )
        sender = E2EEV2MessageSenderV2(
            api: api, identityStore: identityStore, keyStore: keyStore, stateStore: stateStore,
            expectedSession: expectedSession, now: now
        )
        receiver = E2EEV2MessageReceiverV2(
            identityStore: identityStore, keyStore: keyStore, stateStore: stateStore, ledgerStore: ledgerStore,
            expectedSession: expectedSession, now: now
        )
        writer = E2EEV2MembershipWriterV2(
            api: api, identityStore: identityStore, stateStore: stateStore, expectedSession: expectedSession, now: now
        )
    }

    // MARK: Relève

    /// Synchronise la conversation, puis lit la liste depuis le curseur gardé.
    /// Le curseur n'avance jamais au-delà d'un message à relire (échec
    /// passager, époque pas encore connue).
    func refresh(
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2RefreshResultV2 {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId else {
            return .failure(localError("invalid-e2ee-refresh-scope"))
        }
        let mirrorGeneration = notificationMirror?.invalidate(conversationId)
        let synced = await syncer.sync(
            conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: expectedOwnerScopeId
        )
        if case .failure(let error) = synced { return .failure(error) }
        // Un départ ou un retrait appris ici, pas encore suivi d'une époque :
        // le premier membre restant qui l'apprend la crée (§3.3).
        if let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup),
           let current = try? stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: session.ownerNamespace),
           Set(current.memberIds) != context.head.members, context.head.members.contains(ownUserId(expectedOwnerScopeId)) {
            _ = await rotator.rotateIfNeeded(
                conversationId: conversationId, membership: context.head, membershipAt: context.membershipAt,
                devices: devices, expectedOwnerScopeId: expectedOwnerScopeId, messageCount: context.messageCount
            )
        }
        var unsupported: [String] = []
        var caughtUp = false
        var cursor: Int64
        do {
            cursor = try messageStore.snapshot(
                conversationId: conversationId, ownerScopeId: expectedOwnerScopeId, nowMs: nowMs()
            ).cursor
        } catch {
            return .failure(localError("e2ee-message-store-unavailable"))
        }
        pages: for _ in 0..<Self.maxPages {
            let data: Data
            switch await transport.bound(to: session).getJSON(
                path: "/api/e2ee/v2/conversations/\(conversationId)/messages",
                query: [
                    URLQueryItem(name: "after", value: String(cursor)),
                    URLQueryItem(name: "limit", value: String(E2EEV2DeliveredMessageV2.pageLimit)),
                ],
                expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
            ) {
            case .failure(let error): return .failure(error)
            case .success(let value, _, _): data = value
            }
            guard let page = E2EEV2DeliveredMessageV2.parsePage(data, after: cursor) else {
                return .failure(localError("invalid-e2ee-message-page"))
            }
            let store = messageStore
            let results = receiver.receive(
                page.messages, conversationId: conversationId, isGroup: isGroup, devices: devices,
                expectedOwnerScopeId: expectedOwnerScopeId
            ) { received, equivocal in
                try store.apply(
                    received, equivocal: equivocal, cursor: 0, conversationId: conversationId,
                    ownerScopeId: expectedOwnerScopeId, nowMs: self.nowMs()
                )
            }
            // Jusqu'au premier message à relire, exclu, sauf s'il a déjà arrêté
            // la relève trop souvent. Sous une époque dont l'appareil n'est pas
            // destinataire, un message ne se lira jamais : il est dépassé.
            var stop = false
            for (message, result) in zip(page.messages, results) {
                // Seul un émetteur inconnu de l'annuaire (appareil révoqué) peut
                // être dépassé après quelques relèves ; une clé verrouillée, le
                // stockage ou l'état bloquent toujours le curseur : le message se
                // relira (relecture Android du 04/10).
                var reread = false
                var bounded = false
                switch result {
                case .retryLater(let reason):
                    reread = true
                    bounded = reason == "e2ee-sender-not-certified"
                case .needsEpoch: reread = synced != .waitingForEpoch
                case .unsupported(let ref, _): unsupported.append(ref)
                default: break
                }
                if reread {
                    guard bounded, let count = try? messageStore.noteReread(
                        sequence: message.sequence, conversationId: conversationId, ownerScopeId: expectedOwnerScopeId
                    ), count > Self.maxRereads else {
                        stop = true
                        break
                    }
                }
                cursor = message.sequence
            }
            do {
                try messageStore.advanceCursor(to: cursor, conversationId: conversationId, ownerScopeId: expectedOwnerScopeId)
            } catch {
                return .failure(localError("e2ee-message-store-unavailable"))
            }
            if stop { break pages }
            if !page.hasMore {
                caughtUp = true
                break pages
            }
        }
        do {
            let snapshot = try messageStore.snapshot(
                conversationId: conversationId, ownerScopeId: expectedOwnerScopeId, nowMs: nowMs()
            )
            // Les trous ne se comptent qu'une fois la liste rattrapée (E.3).
            var missing: [String: Int] = [:]
            if caughtUp {
                missing = try ledgerStore.update(conversationId: conversationId, ownerScopeId: expectedOwnerScopeId) { ledger in
                    Dictionary(uniqueKeysWithValues: Set(snapshot.messages.map(\.senderDeviceId)).compactMap { device in
                        let count = ledger.missingCount(deviceId: device)
                        return count > 0 ? (device, count) : nil
                    })
                }
            }
            updateMirror(conversationId: conversationId, isGroup: isGroup, devices: devices, generation: mirrorGeneration)
            return .refreshed(E2EEV2MessagesV2(
                snapshot: snapshot, unsupported: unsupported, missingByDevice: missing,
                waitingForEpoch: synced == .waitingForEpoch
            ))
        } catch {
            return .failure(localError("e2ee-message-store-unavailable"))
        }
    }

    // MARK: Envoi

    /// Envoie un texte, une édition ou une suppression. Une rotation ou une
    /// synchronisation nécessaire passe d'abord, puis l'envoi reprend.
    func send(
        _ draft: E2EEV2MessageSenderV2.Draft,
        clientRequestId: String,
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2MessageSendResultV2 {
        // Avant tout, pour ne rien retirer du miroir : un membre dont l'identité
        // n'est pas crue suspend l'envoi, il n'est jamais exclu en silence (§2.4).
        if let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) {
            let untrusted = devices.untrustedMembers(context.head.members)
            guard untrusted.isEmpty else { return .membersNotTrusted(untrusted) }
            let unread = devices.unread(context.head.members)
            guard unread.isEmpty else { return .failure(E2EEV2DeviceListReread.failure(unread)) }
        }
        let mirrorGeneration = notificationMirror?.invalidate(conversationId)
        var last = E2EEV2MessageSendResultV2.needsEpoch
        for _ in 0..<Self.maxSendRounds {
            guard let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) else {
                return .failure(localError("e2ee-send-state-unavailable"))
            }
            last = await sender.send(
                draft, conversationId: conversationId, clientRequestId: clientRequestId, membership: context.head,
                devices: devices, expectedOwnerScopeId: expectedOwnerScopeId, messageCount: context.messageCount
            )
            switch last {
            case .needsRotation:
                switch await rotator.rotateIfNeeded(
                    conversationId: conversationId, membership: context.head, membershipAt: context.membershipAt,
                    devices: devices, expectedOwnerScopeId: expectedOwnerScopeId, messageCount: context.messageCount
                ) {
                case .failure(let error): return .failure(error)
                case .membersNotTrusted(let untrusted): return .membersNotTrusted(untrusted)
                case .needsMembershipSync:
                    if case .failure(let error) = await syncer.sync(
                        conversationId: conversationId, isGroup: isGroup, devices: devices,
                        expectedOwnerScopeId: expectedOwnerScopeId
                    ) { return .failure(error) }
                case .upToDate, .rotated, .adopted:
                    continue
                }
            case .needsEpoch:
                if case .failure(let error) = await syncer.sync(
                    conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: expectedOwnerScopeId
                ) { return .failure(error) }
            case .sent, .alreadyAccepted:
                updateMirror(conversationId: conversationId, isGroup: isGroup, devices: devices, generation: mirrorGeneration)
                return last
            default:
                return last
            }
        }
        return last
    }

    // MARK: Membres

    /// Un changement d'appartenance, puis aussitôt l'époque suivante après un
    /// retrait ou un changement du réglage des navigateurs (§3.3) : un membre
    /// retiré ne lit plus rien de neuf. Après un départ, ce sont les membres
    /// restants qui la créent, à leur prochaine relève.
    func change(
        _ change: E2EEV2MembershipWriterV2.Change,
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2MembershipWriteResultV2 {
        let mirrorGeneration = notificationMirror?.invalidate(conversationId)
        var result = await writer.submit(change, conversationId: conversationId, isGroup: isGroup, expectedOwnerScopeId: expectedOwnerScopeId)
        if result == .needsSync {
            if case .failure(let error) = await syncer.sync(
                conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: expectedOwnerScopeId
            ) { return .failure(error) }
            result = await writer.submit(change, conversationId: conversationId, isGroup: isGroup, expectedOwnerScopeId: expectedOwnerScopeId)
        }
        guard case .applied = result else { return result }
        switch change {
        case .remove, .excludeBrowsers:
            if let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) {
                _ = await rotator.rotateIfNeeded(
                    conversationId: conversationId, membership: context.head, membershipAt: context.membershipAt,
                    devices: devices, expectedOwnerScopeId: expectedOwnerScopeId, messageCount: context.messageCount
                )
            }
        case .add, .leave, .promote, .demote:
            break
        }
        // Conversation quittée : son entrée et ce que l'extension en a montré partent.
        updateMirror(conversationId: conversationId, isGroup: isGroup, devices: devices, generation: mirrorGeneration)
        return result
    }

    // MARK: Rotation demandée

    enum StoredMembership: Equatable {
        case v2(isGroup: Bool, members: [String], excludesWeb: Bool = false)
        /// Aucune genèse gardée : la conversation n'est pas v2 sur cet appareil.
        case notV2
        /// Coffre ou disque illisible : jamais pris pour « pas v2 ».
        case unreadable
    }

    /// Genre et membres d'une conversation v2 gardée, d'après sa chaîne
    /// vérifiée : la genèse d'un groupe a des administrateurs, celle d'une
    /// conversation à deux n'en a aucun (D.4), si bien qu'une seule lecture
    /// réussit.
    func storedMembership(conversationId: String) -> StoredMembership {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot() else { return .unreadable }
        do {
            guard try stateStore.genesis(conversationId: conversationId, ownerNamespace: session.ownerNamespace) != nil
            else { return .notV2 }
        } catch {
            return .unreadable
        }
        for isGroup in [true, false] {
            if let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) {
                return .v2(isGroup: isGroup, members: context.head.members.sorted(), excludesWeb: context.head.excludesWeb)
            }
        }
        return .unreadable
    }

    /// Rotation hors envoi (§3.3) : appareil ajouté ou révoqué, exigence
    /// publiée par le serveur. Synchronise, puis décide comme avant un envoi ;
    /// une époque adoptée ou une chaîne en retard refont la décision.
    func rotate(
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) async -> E2EEV2EpochRotationV2Result {
        let mirrorGeneration = notificationMirror?.invalidate(conversationId)
        if case .failure(let error) = await syncer.sync(
            conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: expectedOwnerScopeId
        ) { return .failure(error) }
        var result = E2EEV2EpochRotationV2Result.upToDate
        rounds: for _ in 0..<Self.maxSendRounds {
            guard let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) else {
                return .failure(localError("e2ee-rotation-state-unavailable"))
            }
            // Conversation quittée : plus rien à créer d'ici.
            guard context.head.members.contains(ownUserId(expectedOwnerScopeId)) else { result = .upToDate; break }
            result = await rotator.rotateIfNeeded(
                conversationId: conversationId, membership: context.head, membershipAt: context.membershipAt,
                devices: devices, expectedOwnerScopeId: expectedOwnerScopeId, messageCount: context.messageCount
            )
            switch result {
            case .adopted: continue
            case .needsMembershipSync:
                if case .failure(let error) = await syncer.sync(
                    conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: expectedOwnerScopeId
                ) { return .failure(error) }
            case .upToDate, .rotated, .membersNotTrusted, .failure:
                break rounds
            }
        }
        updateMirror(conversationId: conversationId, isGroup: isGroup, devices: devices, generation: mirrorGeneration)
        return result
    }

    // MARK: Aides

    private struct MembershipContext {
        let head: E2EEV2MembershipState
        let membershipAt: (Int) -> E2EEV2MembershipState?
        let messageCount: Int
    }

    /// Tête de la chaîne gardée, déjà vérifiée, et messages acceptés sous
    /// l'époque courante (§3.3).
    private func membershipContext(conversationId: String, isGroup: Bool) throws -> MembershipContext {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(),
              let genesis = try stateStore.genesis(conversationId: conversationId, ownerNamespace: session.ownerNamespace)
        else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
        let chain = try stateStore.membershipChain(conversationId: conversationId, ownerNamespace: session.ownerNamespace)
        let replay = { (changes: [E2EEV2SignedString]) throws -> E2EEV2MembershipState in
            try E2EEV2MembershipChain.apply(
                changes, conversationId: conversationId, isGroup: isGroup, genesisLength: genesis.membershipChangeNumber,
                verifiedCount: chain.count
            ) { _, _ in nil }
        }
        let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: session.ownerNamespace)
        let count = try current.map { epoch in
            try ledgerStore.update(conversationId: conversationId, ownerScopeId: session.ownerScopeId) {
                $0.acceptedCount(epochNumber: epoch.epochNumber)
            }
        } ?? 0
        return MembershipContext(
            head: try replay(chain),
            membershipAt: { number in
                guard number >= genesis.membershipChangeNumber, number <= chain.count else { return nil }
                return try? replay(Array(chain.prefix(number)))
            },
            messageCount: count
        )
    }

    /// Réécrit l'entrée du miroir après une opération réussie, tant que ce
    /// compte est courant et membre, et qu'aucune opération n'a commencé
    /// depuis ; sinon elle reste retirée, ou part avec ce que l'extension a
    /// montré si la conversation est quittée.
    private func updateMirror(conversationId: String, isGroup: Bool, devices: E2EEV2CertifiedDeviceSet, generation: UInt64?) {
        guard let notificationMirror, let generation else { return }
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              let context = try? membershipContext(conversationId: conversationId, isGroup: isGroup) else {
            notificationMirror.remove(conversationId)
            return
        }
        guard context.head.members.contains(ownUserId(session.ownerScopeId)) else {
            notificationMirror.forget(conversationId)
            return
        }
        notificationMirror.update(
            conversationId: conversationId, devices: devices, latestMemberIds: context.head.members, session: session,
            generation: generation
        )
    }

    private func ownUserId(_ ownerScopeId: String) -> String {
        String(ownerScopeId.dropFirst("user:".count))
    }

    private func nowMs() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1_000)
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
