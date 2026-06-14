import Foundation
import UIKit
import UserNotifications
import os

/// Registers the device for remote notifications. The backend supports Firebase
/// Cloud Messaging — we forward whichever token we have (APNs for now, FCM
/// once the firebase-ios-sdk Swift Package is wired in) via
/// `/api/user/fcm-token`.
final class PushNotificationService: NSObject, @unchecked Sendable {
    private let api: APIClient
    private let router: AppRouter
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "Push")
    /// Protégé par un verrou : `didRegister` est appelé sur un thread système
    /// (callback APNs) tandis que `unregister` est appelé depuis une tâche async.
    private let lastToken = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(api: APIClient, router: AppRouter) {
        self.api = api
        self.router = router
        super.init()
    }

    @MainActor
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound, .providesAppNotificationSettings])
            logger.info("Notification permission granted=\(granted, privacy: .public)")
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            logger.error("Permission error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        lastToken.withLock { $0 = token }
        Task {
            do {
                let _: SuccessResponse = try await api.requestJSON(
                    "/api/user/fcm-token",
                    body: ["fcmToken": token, "platform": "ios"]
                )
                logger.info("FCM/APNs token registered with backend")
            } catch {
                logger.error("Token registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func didFailToRegister(error: Error) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Called on logout/account deletion so this device stops receiving pushes for
    /// the previous account. Unregisters locally and best-effort revokes the token
    /// server-side, then clears the badge.
    func unregister() async {
        let token = lastToken.withLock { value -> String? in
            let current = value
            value = nil
            return current
        }
        await MainActor.run {
            UIApplication.shared.unregisterForRemoteNotifications()
            UNUserNotificationCenter.current().setBadgeCount(0)
        }
        if let token {
            let _: SuccessResponse? = try? await api.requestJSON(
                "/api/user/fcm-token",
                method: .delete,
                body: ["fcmToken": token, "platform": "ios"]
            )
        }
    }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Show alerts even when foreground.
        [.banner, .sound, .badge]
    }

    /// Handles a notification tap. We extract the identifiers off the (non-Sendable)
    /// payload here, then hand only `String?` values to the MainActor router so a
    /// tap reliably deep-links instead of doing nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let type = Self.string(info, "type")
        let conversationId = Self.string(info, "conversationId", "conversation_id")
        let postId = Self.string(info, "postId", "post_id")
        let userId = Self.string(info, "userId", "user_id", "actorId", "actor_id")
        let siteId = Self.string(info, "siteId", "site_id")
        await MainActor.run {
            self.router.handle(type: type, conversationId: conversationId, postId: postId, userId: userId, siteId: siteId)
            UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }
}

private extension PushNotificationService {
    static func string(_ info: [AnyHashable: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = info[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
