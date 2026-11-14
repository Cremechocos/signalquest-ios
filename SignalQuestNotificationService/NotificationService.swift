import Foundation
import UserNotifications

private final class OutageReceiptCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let content: UNNotificationContent
    private let completion: (UNNotificationContent) -> Void
    private var finished = false

    init(content: UNNotificationContent, completion: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.completion = completion
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion(content)
    }
}

/// The system owns notification presentation. No Firebase, UI or app-service graph is loaded.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private struct PendingDelivery {
        let id: UUID
        let request: E2EEV2OpaqueNotificationRequest?
        let completion: (UNNotificationContent) -> Void
        var processing: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var pending: PendingDelivery?
    private var outageCompletion: OutageReceiptCompletion?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        finishCurrent()
        let info = request.content.userInfo
        if (info["type"] as? String)?.lowercased() == "community_outage" {
            guard let receipt = OutageNotificationReceiptSender.parse(info) else {
                contentHandler(request.content)
                return
            }
            let completion = OutageReceiptCompletion(
                content: request.content,
                completion: contentHandler
            )
            lock.lock()
            outageCompletion = completion
            lock.unlock()
            Task { [weak self, receipt, completion] in
                _ = await OutageNotificationReceiptSender.send(receipt)
                self?.finishOutage(completion)
            }
            return
        }
        if (info["type"] as? String)?.lowercased() == "e2ee_history_request" {
            contentHandler(Self.historyRequestContent(request.content))
            return
        }
        if (info["type"] as? String)?.lowercased() == "e2ee_device_added" {
            contentHandler(Self.deviceAddedContent(request.content))
            return
        }
        guard (info["type"] as? String)?.lowercased() == "e2ee_v2_envelope" else {
            // Message : « Répondre » et « Marquer comme lu » selon la conversation.
            contentHandler(MessageNotificationCategory.categorized(request.content))
            return
        }
        let opaque: E2EEV2OpaqueNotificationRequest?
        if info["type"] as? String == "e2ee_v2_envelope",
           let envelopeId = info["envelopeId"] as? String,
           let ownerScopeId = info["recipientOwnerScope"] as? String {
            opaque = .init(envelopeId: envelopeId, recipientOwnerScope: ownerScopeId)
        } else {
            opaque = nil
        }
        let id = UUID()
        lock.lock()
        pending = PendingDelivery(id: id, request: opaque, completion: contentHandler)
        lock.unlock()

        let processing = Task { [weak self] in
            guard let opaque,
                  let contextStore = E2EEV2NotificationContextStore.configured(),
                  let rawURL = Bundle.main.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String,
                  !rawURL.contains("$("), let apiBaseURL = URL(string: rawURL) else {
                self?.finish(id: id, prepared: nil)
                return
            }
            #if DEBUG
            let allowLocalHTTP = true
            #else
            let allowLocalHTTP = false
            #endif
            let result = await E2EEV2NotificationProcessor.processRuntime(
                request: opaque,
                apiBaseURL: apiBaseURL,
                allowLocalHTTP: allowLocalHTTP,
                dependencies: .init(
                    loadContext: { try contextStore.load() },
                    isCurrent: { try contextStore.isCurrent($0) },
                    loadConversation: { try contextStore.conversation($0) },
                    claimShown: { try contextStore.claimShown(conversationId: $0, deviceId: $1, counter: $2, floor: $3) },
                    fetch: { try await E2EEV2NotificationNetwork.fetch($0) }
                )
            )
            if case .preview(let prepared) = result {
                self?.finish(id: id, prepared: prepared)
            } else {
                self?.finish(id: id, prepared: nil)
            }
        }
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            self?.finish(id: id, prepared: nil)
        }
        lock.lock()
        let stillPending = pending?.id == id
        if stillPending {
            pending?.processing = processing
            pending?.deadline = deadline
        }
        lock.unlock()
        if !stillPending {
            processing.cancel()
            deadline.cancel()
        }
    }

    /// « C'est moi » (E2EE-AUTO §5.3) : le texte de l'app pour le compte connecté,
    /// sans tutoiement ni vouvoiement (le ton n'est pas lu ici). Un push d'un autre
    /// compte devient neutre ; sans compte connu, le texte constant du serveur reste.
    /// Une demande d'activation (`activate`, mode renforcé §6) a son propre texte :
    /// elle part aussi vers les appareils sans historique (Alexandre, 14/11).
    private static func historyRequestContent(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent,
              let current = try? E2EEV2NotificationContextStore.configured()?.load()?.ownerScopeId else { return original }
        if original.userInfo["recipientOwnerScope"] as? String == current, E2EEAutoHistoryRequestPush.isActivation(original.userInfo) {
            content.title = String(localized: "Activer un nouvel appareil ?")
            content.body = String(localized: "Un appareil de ce compte attend d’être activé. Confirmation dans SignalQuest.")
        } else if original.userInfo["recipientOwnerScope"] as? String == current {
            content.title = String(localized: "Ouvrir l’historique sur un nouvel appareil ?")
            content.body = String(localized: "Un appareil de ce compte demande l’historique des messages chiffrés. Confirmation dans SignalQuest.")
        } else {
            content.title = "SignalQuest"
            content.body = String(localized: "Nouveau contenu privé")
        }
        return content
    }

    /// Révision 21 : texte constant, le même pour tous ; l'app vérifie l'appareil
    /// dans le journal avant de le montrer. Sans tu ni vous : l'extension ne
    /// connaît pas le réglage d'adresse.
    private static func deviceAddedContent(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        let current = try? E2EEV2NotificationContextStore.configured()?.load()?.ownerScopeId
        if let current, original.userInfo["recipientOwnerScope"] as? String == current {
            content.title = String(localized: "Nouvel appareil sur ce compte")
            content.body = String(localized: "Un appareil a été ajouté à ce compte. Vérification dans SignalQuest.")
        } else {
            content.title = "SignalQuest"
            content.body = String(localized: "Nouveau contenu privé")
        }
        return content
    }

    override func serviceExtensionTimeWillExpire() {
        finishCurrent()
    }

    private func finishCurrent() {
        lock.lock()
        let id = pending?.id
        let outage = outageCompletion
        outageCompletion = nil
        lock.unlock()
        outage?.finish()
        if let id { finish(id: id, prepared: nil) }
    }

    private func finishOutage(_ completion: OutageReceiptCompletion) {
        lock.lock()
        if outageCompletion === completion {
            outageCompletion = nil
        }
        lock.unlock()
        completion.finish()
    }

    private func finish(id: UUID, prepared: E2EEV2PreparedNotification?) {
        lock.lock()
        guard let delivery = pending, delivery.id == id else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        delivery.processing?.cancel()
        delivery.deadline?.cancel()

        // Never copy the original title/body: only fixed copy or verified local decryption.
        let content = UNMutableNotificationContent()
        content.title = "SignalQuest"
        // Message illisible ici (miroir absent ou périmé) : « Nouveau message »,
        // sans le mot « chiffré » (choix d'Alexandre, 08/11), sauf en mode
        // « aucun aperçu », qui ne dit même pas qu'il s'agit d'un message.
        let privacy = (try? E2EEV2NotificationContextStore.configured()?.load())?.privacy
        content.body = privacy == nil || privacy == .hidden
            ? String(localized: "Nouveau contenu privé") : String(localized: "Nouveau message")
        content.sound = .default
        if let request = delivery.request {
            content.userInfo = [
                "type": "e2ee_v2_envelope",
                "envelopeId": request.envelopeId,
                "recipientOwnerScope": request.recipientOwnerScope,
                "e2eeNotificationServiceVersion": "1",
            ]
        }
        if let prepared,
           let store = E2EEV2NotificationContextStore.configured(),
           (try? store.permits(prepared)) == true {
            content.title = prepared.presentation.title
            content.body = prepared.presentation.body
            content.threadIdentifier = prepared.conversationId
            content.userInfo["conversationId"] = prepared.conversationId
            content.userInfo["e2eeNotificationSessionId"] = prepared.sessionId
            content.userInfo["privacy"] = prepared.presentation.privacy.rawValue
            // Reply is encrypted by the app on this device; a protected conversation only offers "mark as read".
            content.userInfo["isE2EE"] = "1"
            content.categoryIdentifier = MessageNotificationCategory.v2Category(conversationId: prepared.conversationId)
            if !prepared.presentation.playsSound { content.sound = nil }
        }
        delivery.completion(content)
    }
}
