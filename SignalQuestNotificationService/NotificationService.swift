import Foundation
import UserNotifications

private final class ReceiptCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let content: UNNotificationContent
    private let handler: (UNNotificationContent) -> Void
    private var finished = false

    init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        handler(content)
    }
}

/// L'alerte reste entièrement présentée par APNs. L'extension ne lit que le jeton opaque
/// signé par le serveur afin d'accuser la réception, y compris lorsque l'app est tuée.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ReceiptCompletion?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let completion = ReceiptCompletion(content: request.content, handler: contentHandler)
        lock.lock()
        current?.finish()
        current = completion
        lock.unlock()

        guard let receipt = OutageNotificationReceiptSender.parse(request.content.userInfo) else {
            completion.finish()
            return
        }
        Task { [completion] in
            _ = await OutageNotificationReceiptSender.send(receipt)
            completion.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let completion = current
        lock.unlock()
        completion?.finish()
    }
}
