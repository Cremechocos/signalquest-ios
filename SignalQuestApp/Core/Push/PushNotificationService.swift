import Foundation
import UIKit
import UserNotifications
import os

struct InstallationIdentity: Sendable {
    private enum Key {
        static let deviceID = "installation.device-id"
        static let fcmToken = "installation.fcm-token"
    }

    private let store: TokenStore

    init(store: TokenStore = KeychainStore(service: "fr.signalquest.ios.installation")) {
        self.store = store
    }

    func deviceID() -> String {
        if let existing = (try? store.string(for: Key.deviceID)) ?? nil,
           !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        try? store.set(created, for: Key.deviceID, accessibility: .afterFirstUnlock)
        return created
    }

    func saveFCMToken(_ token: String) {
        try? store.set(token, for: Key.fcmToken, accessibility: .afterFirstUnlock)
    }

    func storedFCMToken() -> String? {
        (try? store.string(for: Key.fcmToken)) ?? nil
    }

    func clearFCMToken() {
        try? store.remove(Key.fcmToken)
    }
}

private struct DevicePushRegistration: Encodable {
    let fcmToken: String
    let platform: String
    let deviceId: String
    let environment: String
}

/// Registers the device for remote notifications. The backend supports Firebase
/// Cloud Messaging — we forward whichever token we have (APNs for now, FCM
/// once the firebase-ios-sdk Swift Package is wired in) via
/// `/api/user/fcm-token`.
final class PushNotificationService: NSObject, @unchecked Sendable {
    private let api: APIClient
    private let router: AppRouter
    private let identity: InstallationIdentity
    private let deviceID: String
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "Push")
    /// Protégé par un verrou : `didRegister` est appelé sur un thread système
    /// (callback APNs) tandis que `unregister` est appelé depuis une tâche async.
    private let lastToken = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(
        api: APIClient,
        router: AppRouter,
        identity: InstallationIdentity = InstallationIdentity()
    ) {
        self.api = api
        self.router = router
        self.identity = identity
        deviceID = identity.deviceID()
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

    /// Enregistre le token de registration FCM (remonté par `MessagingDelegate`).
    /// C'est ce token — et non le token APNs brut — que `firebase-admin` côté
    /// backend sait cibler pour livrer les notifications.
    func didRegister(fcmToken token: String) {
        lastToken.withLock { $0 = token }
        identity.saveFCMToken(token)
        Task {
            do {
                let _: SuccessResponse = try await api.requestJSON(
                    "/api/user/fcm-token",
                    body: DevicePushRegistration(
                        fcmToken: token,
                        platform: "ios",
                        deviceId: deviceID,
                        environment: api.config.environment.rawValue
                    )
                )
                logger.info("FCM token registered with backend")
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
        let inMemoryToken = lastToken.withLock { value -> String? in
            let current = value
            value = nil
            return current
        }
        let token = inMemoryToken ?? identity.storedFCMToken()
        await MainActor.run {
            UIApplication.shared.unregisterForRemoteNotifications()
            UNUserNotificationCenter.current().setBadgeCountCompat(0)
        }
        if let token {
            let _: SuccessResponse? = try? await api.requestJSON(
                "/api/user/fcm-token",
                method: .delete,
                body: DevicePushRegistration(
                    fcmToken: token,
                    platform: "ios",
                    deviceId: deviceID,
                    environment: api.config.environment.rawValue
                )
            )
        }
        identity.clearFCMToken()
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
            UNUserNotificationCenter.current().setBadgeCountCompat(0)
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
