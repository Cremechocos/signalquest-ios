import Foundation
import UserNotifications

private final class OutageReceiptCompletion: @unchecked Sendable {
    private let content: UNNotificationContent
    private let completion: (UNNotificationContent) -> Void

    init(content: UNNotificationContent, completion: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.completion = completion
    }

    func finish() { completion(content) }
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
            Task { [receipt, completion] in
                _ = await OutageNotificationReceiptSender.send(receipt)
                completion.finish()
            }
            return
        }
        guard (info["type"] as? String)?.lowercased() == "e2ee_v2_envelope" else {
            contentHandler(request.content)
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

    override func serviceExtensionTimeWillExpire() {
        finishCurrent()
    }

    private func finishCurrent() {
        lock.lock()
        let id = pending?.id
        lock.unlock()
        if let id { finish(id: id, prepared: nil) }
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
        content.body = String(localized: "Nouveau contenu privé")
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
        }
        // No legacy category/action can send a clear direct reply.
        delivery.completion(content)
    }
}
