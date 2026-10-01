import Foundation

/// Entrées du miroir de notification (§2.6), écrites par l'app après chaque
/// relève, envoi ou changement d'une conversation v2 réussi : les époques
/// vérifiées (la courante, et celles remplacées depuis moins de 24 heures),
/// leurs membres, les clés publiques certifiées des appareils de ces membres,
/// les membres actuels et les départs récents, et le plus haut compteur reçu
/// de chaque appareil. Les clés d'époque seulement avec l'aperçu complet ;
/// jamais de clé d'appareil ; rien sans contexte actif de ce compte et de
/// cette session, donc rien en mode « aucun aperçu ». Au moindre échec,
/// l'entrée part : l'extension montre alors un aperçu générique.
struct E2EEV2NotificationMirrorWriter: Sendable {
    /// Ordre des opérations, par conversation : une opération plus ancienne
    /// ne réécrit jamais l'entrée par-dessus une plus récente.
    private final class Generations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: UInt64] = [:]

        func next(_ conversationId: String) -> UInt64 {
            lock.withLock {
                let value = (values[conversationId] ?? 0) &+ 1
                values[conversationId] = value
                return value
            }
        }

        func current(_ conversationId: String) -> UInt64 {
            lock.withLock { values[conversationId] ?? 0 }
        }
    }

    private static let generations = Generations()

    let keyStore: E2EEV2EpochKeyStore
    let stateStore: E2EEV2ConversationStateStore
    let ledgerStore: E2EEV2MessageLedgerStore
    let contextStore: E2EEV2NotificationContextStore
    var now: @Sendable () -> Date = Date.init
    /// Tests déterministes seulement : écrit même verrou de lecture fermé.
    var contractPreview = false

    /// L'entrée d'une conversation v2 pour ce contexte, ou nil si l'appareil
    /// n'en connaît aucune époque.
    func entry(
        conversationId: String,
        devices: E2EEV2CertifiedDeviceSet,
        latestMemberIds: Set<String>,
        context: E2EEV2NotificationContext,
        session: LocalAccountSession
    ) throws -> E2EEV2NotificationConversation? {
        let ownerNamespace = session.ownerNamespace
        guard let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
        else { return nil }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let window = E2EEV2MessageReceiverV2.replacedEpochWindowMs
        let includesKeys = context.privacy == .full
        let accepted = try stateStore.acceptedEpochs(conversationId: conversationId, ownerNamespace: ownerNamespace)
        var epochs: [E2EEV2NotificationConversation.Epoch] = []
        for epoch in accepted.reversed() where epoch.epochNumber < current.epochNumber {
            let replacedAtMs = accepted.filter { $0.epochNumber > epoch.epochNumber }.map(\.acceptedAtMs).min()
                ?? current.acceptedAtMs
            guard nowMs - replacedAtMs <= window,
                  epochs.count < E2EEV2NotificationConversation.maxEpochs - 1 else { break }
            // Seulement une époque dont l'appareil détient la clé, même quand
            // elle n'est pas recopiée.
            guard var stored = try keyStore.loadEpoch(
                conversationId: conversationId, epochNumber: epoch.epochNumber, ownerNamespace: ownerNamespace
            ) else { continue }
            let keyB64 = includesKeys ? stored.epochKey.base64EncodedString() : nil
            stored.epochKey.resetBytes(in: 0..<stored.epochKey.count)
            epochs.append(.init(
                epochNumber: epoch.epochNumber, keyB64: keyB64, memberIds: epoch.memberIds, replacedAtMs: replacedAtMs
            ))
        }
        guard var stored = try keyStore.loadEpoch(
            conversationId: conversationId, epochNumber: current.epochNumber, ownerNamespace: ownerNamespace
        ) else { return nil }
        let currentKeyB64 = includesKeys ? stored.epochKey.base64EncodedString() : nil
        stored.epochKey.resetBytes(in: 0..<stored.epochKey.count)
        epochs.insert(.init(
            epochNumber: current.epochNumber, keyB64: currentKeyB64, memberIds: current.memberIds, replacedAtMs: nil
        ), at: 0)
        var signingKeys: [String: String] = [:]
        var certifiedDeviceIds = Set<String>()
        for userId in Set(epochs.flatMap(\.memberIds)).sorted() {
            for device in devices.devicesByUser[userId] ?? [] where signingKeys.count < E2EEV2NotificationConversation.maxSigningKeys {
                signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: userId, deviceId: device.deviceId)] =
                    device.signingKeyB64
                certifiedDeviceIds.insert(device.deviceId)
            }
        }
        // Le registre de l'app, pour les seuls appareils dont un message peut
        // s'afficher ; illisible, ou repris de zéro depuis moins de 48 heures
        // (ses compteurs ne disent plus tout ce qui a été reçu), pas d'entrée.
        let ledger = try ledgerStore.read(conversationId: conversationId, ownerScopeId: session.ownerScopeId)
        if let resetAtMs = ledger.resetAtMs, nowMs - resetAtMs < E2EEV2NotificationProcessor.maxMessageAgeMs {
            return nil
        }
        let counters = certifiedDeviceIds.reduce(into: [String: Int]()) { result, deviceId in
            if let highest = ledger.highestCounter(deviceId: deviceId) { result[deviceId] = highest }
        }
        let departures = try stateStore.departures(conversationId: conversationId, ownerNamespace: ownerNamespace)
            .filter { nowMs - $0.value <= window }
        return .init(
            version: E2EEV2NotificationConversation.currentVersion, conversationId: conversationId,
            ownerScopeId: context.ownerScopeId, sessionId: context.sessionId, writtenAtMs: nowMs, epochs: epochs,
            latestMemberIds: latestMemberIds.sorted(), departures: departures, counters: counters, signingKeys: signingKeys
        )
    }

    /// Avant tout ce qui peut changer l'état de la conversation : l'entrée
    /// part, et la réécriture d'une opération commencée plus tôt ne vaut plus.
    @discardableResult
    func invalidate(_ conversationId: String) -> UInt64 {
        let generation = Self.generations.next(conversationId)
        remove(conversationId)
        return generation
    }

    /// Réécrit l'entrée si un contexte de notification de ce compte et de
    /// cette session est actif et qu'aucune opération n'a commencé depuis
    /// `generation` ; sinon, ou au moindre échec, elle part.
    @discardableResult
    func update(
        conversationId: String,
        devices: E2EEV2CertifiedDeviceSet,
        latestMemberIds: Set<String>,
        session: LocalAccountSession,
        generation: UInt64
    ) -> Bool {
        guard contractPreview || E2EEV2RuntimeReadGate.enabled,
              Self.generations.current(conversationId) == generation else { return false }
        do {
            guard session.isCurrent, session.ownerScopeId.hasPrefix("user:"),
                  let context = try contextStore.load(now: now()),
                  context.ownerScopeId == PushOwnerScope.id(for: String(session.ownerScopeId.dropFirst("user:".count))),
                  context.sessionId == session.sessionId,
                  let entry = try entry(
                      conversationId: conversationId, devices: devices, latestMemberIds: latestMemberIds,
                      context: context, session: session
                  ) else {
                remove(conversationId)
                return false
            }
            if contractPreview {
                try contextStore.saveConversationContractPreview(entry, now: now())
            } else {
                guard try contextStore.saveConversationRuntime(entry, now: now()) else {
                    remove(conversationId)
                    return false
                }
            }
            // Une opération commencée pendant l'écriture la réécrira.
            guard session.isCurrent, Self.generations.current(conversationId) == generation else {
                remove(conversationId)
                return false
            }
            return true
        } catch {
            remove(conversationId)
            return false
        }
    }

    /// Retire l'entrée. Une entrée qui ne part pas rend tout le miroir muet :
    /// la prochaine activation efface les entrées avant tout.
    func remove(_ conversationId: String) {
        guard contractPreview || E2EEV2RuntimeReadGate.enabled else { return }
        do { try contextStore.removeConversation(conversationId) } catch { try? contextStore.revoke() }
    }

    /// Conversation quittée : l'entrée et ce que l'extension en a montré.
    func forget(_ conversationId: String) {
        guard contractPreview || E2EEV2RuntimeReadGate.enabled else { return }
        _ = Self.generations.next(conversationId)
        do { try contextStore.forgetConversation(conversationId) } catch { try? contextStore.revoke() }
    }
}
