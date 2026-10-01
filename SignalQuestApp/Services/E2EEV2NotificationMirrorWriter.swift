import Foundation

/// Entrées du miroir de notification (§2.6), écrites par l'app après chaque
/// relève, envoi ou changement d'une conversation v2 : les clés d'époque
/// vérifiées (la courante, et celles remplacées depuis moins de 24 heures),
/// leurs membres, et les clés publiques certifiées des appareils de ces
/// membres. Jamais de clé d'appareil ; rien sans contexte actif, donc rien en
/// mode « aucun aperçu ».
struct E2EEV2NotificationMirrorWriter: Sendable {
    let keyStore: E2EEV2EpochKeyStore
    let stateStore: E2EEV2ConversationStateStore
    let contextStore: E2EEV2NotificationContextStore
    var now: @Sendable () -> Date = Date.init

    /// L'entrée d'une conversation v2, ou nil si l'appareil n'en connaît
    /// aucune époque.
    func entry(
        conversationId: String,
        devices: E2EEV2CertifiedDeviceSet,
        ownerNamespace: String
    ) throws -> E2EEV2NotificationConversation? {
        guard let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
        else { return nil }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let accepted = try stateStore.acceptedEpochs(conversationId: conversationId, ownerNamespace: ownerNamespace)
        var epochs: [E2EEV2NotificationConversation.Epoch] = []
        for epoch in accepted.reversed() where epoch.epochNumber < current.epochNumber {
            let replacedAtMs = accepted.filter { $0.epochNumber > epoch.epochNumber }.map(\.acceptedAtMs).min()
                ?? current.acceptedAtMs
            guard nowMs - replacedAtMs <= E2EEV2MessageReceiverV2.replacedEpochWindowMs,
                  epochs.count < E2EEV2NotificationConversation.maxEpochs - 1 else { break }
            guard var stored = try keyStore.loadEpoch(
                conversationId: conversationId, epochNumber: epoch.epochNumber, ownerNamespace: ownerNamespace
            ) else { continue }
            defer { stored.epochKey.resetBytes(in: 0..<stored.epochKey.count) }
            epochs.append(.init(
                epochNumber: epoch.epochNumber, keyB64: stored.epochKey.base64EncodedString(),
                memberIds: epoch.memberIds, replacedAtMs: replacedAtMs
            ))
        }
        guard var stored = try keyStore.loadEpoch(
            conversationId: conversationId, epochNumber: current.epochNumber, ownerNamespace: ownerNamespace
        ) else { return nil }
        defer { stored.epochKey.resetBytes(in: 0..<stored.epochKey.count) }
        epochs.insert(.init(
            epochNumber: current.epochNumber, keyB64: stored.epochKey.base64EncodedString(),
            memberIds: current.memberIds, replacedAtMs: nil
        ), at: 0)
        var signingKeys: [String: String] = [:]
        for userId in Set(epochs.flatMap(\.memberIds)) {
            for device in devices.devicesByUser[userId] ?? [] where signingKeys.count < E2EEV2NotificationConversation.maxSigningKeys {
                signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: userId, deviceId: device.deviceId)] =
                    device.signingKeyB64
            }
        }
        return .init(
            version: E2EEV2NotificationConversation.currentVersion, conversationId: conversationId, epochs: epochs,
            signingKeys: signingKeys
        )
    }

    /// Écrit l'entrée si un contexte de notification est actif. Sans époque
    /// connue, l'ancienne entrée part.
    @discardableResult
    func update(conversationId: String, devices: E2EEV2CertifiedDeviceSet, ownerNamespace: String) -> Bool {
        do {
            guard let entry = try entry(conversationId: conversationId, devices: devices, ownerNamespace: ownerNamespace) else {
                try? contextStore.removeConversation(conversationId)
                return false
            }
            return try contextStore.saveConversationRuntime(entry, now: now())
        } catch {
            return false
        }
    }
}
