import Foundation
import CryptoKit
import FirebaseMessaging
import UIKit
import UserNotifications
import os

struct OutageNotificationReceiptPayload: Codable, Equatable, Sendable {
    let state: String
    let receiptToken: String

    static func parse(_ info: [AnyHashable: Any], state: String) -> (id: String, payload: Self)? {
        guard (info["type"] as? String)?.lowercased() == "community_outage",
              let id = info["outageNotificationId"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let token = info["outageNotificationReceiptToken"] as? String,
              token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              state == "received" || state == "opened" else { return nil }
        return (id, .init(state: state, receiptToken: token))
    }
}

private struct OutageNotificationReceiptResponse: Decodable {
    let status: String
}

struct PushRegistrationRecord: Codable, Equatable, Sendable {
    let ownerScopeId: String
    let token: String
    let deviceID: String
    let revocationSecret: String?
    let registeredAt: Date
}

enum PushOwnerScope {
    static func id(for userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "user:\(digest)"
    }

    static var current: String? {
        LocalAccountScope.currentUserId.map(id(for:))
    }
}

struct InstallationIdentity: Sendable {
    private enum Key {
        static let deviceID = "installation.device-id"
        static let fcmToken = "installation.fcm-token"
        static let pendingRevocations = "push.pending-revocations.v2"

        static func registration(ownerScopeId: String) -> String {
            let digest = SHA256.hash(data: Data(ownerScopeId.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "push.registration.v2.\(digest)"
        }
    }

    private final class Storage: @unchecked Sendable {
        let store: TokenStore
        private let lock = NSLock()

        init(store: TokenStore) {
            self.store = store
        }

        func withLock<T>(_ body: (TokenStore) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(store)
        }
    }

    private let storage: Storage

    init(store: TokenStore = KeychainStore(service: "fr.signalquest.ios.installation")) {
        storage = Storage(store: store)
    }

    func deviceID() -> String {
        storage.withLock { store in
            if let existing = (try? store.string(for: Key.deviceID)) ?? nil,
               !existing.isEmpty {
                return existing
            }
            let created = UUID().uuidString.lowercased()
            try? store.set(created, for: Key.deviceID, accessibility: .afterFirstUnlock)
            return created
        }
    }

    func saveFCMToken(_ token: String) {
        storage.withLock { store in
            try? store.set(token, for: Key.fcmToken, accessibility: .afterFirstUnlock)
        }
    }

    func storedFCMToken() -> String? {
        storage.withLock { store in
            (try? store.string(for: Key.fcmToken)) ?? nil
        }
    }

    func clearFCMToken() {
        storage.withLock { store in
            try? store.remove(Key.fcmToken)
        }
    }

    func saveRegistration(_ record: PushRegistrationRecord) -> Bool {
        guard record.ownerScopeId.hasPrefix("user:"),
              !record.token.isEmpty,
              !record.deviceID.isEmpty,
              let data = try? JSONEncoder.signalQuest.encode(record),
              let json = String(data: data, encoding: .utf8) else { return false }
        return storage.withLock { store in
            do {
                try store.set(
                    json,
                    for: Key.registration(ownerScopeId: record.ownerScopeId),
                    accessibility: .afterFirstUnlock
                )
                removePendingLocked(matchingToken: record.token, store: store)
                return true
            } catch {
                return false
            }
        }
    }

    func registration(ownerScopeId: String) -> PushRegistrationRecord? {
        guard ownerScopeId.hasPrefix("user:") else { return nil }
        return storage.withLock { store in
            guard let json = (try? store.string(for: Key.registration(ownerScopeId: ownerScopeId))) ?? nil,
                  let data = json.data(using: .utf8),
                  let record = try? JSONDecoder.signalQuest.decode(PushRegistrationRecord.self, from: data),
                  record.ownerScopeId == ownerScopeId,
                  !record.token.isEmpty,
                  !record.deviceID.isEmpty else {
                try? store.remove(Key.registration(ownerScopeId: ownerScopeId))
                return nil
            }
            return record
        }
    }

    func removeRegistration(ownerScopeId: String) {
        guard ownerScopeId.hasPrefix("user:") else { return }
        storage.withLock { store in
            try? store.remove(Key.registration(ownerScopeId: ownerScopeId))
        }
    }

    func enqueuePendingRevocation(_ record: PushRegistrationRecord) {
        guard let secret = record.revocationSecret, !secret.isEmpty else { return }
        storage.withLock { store in
            var pending = pendingRevocationsLocked(store: store)
            pending.removeAll { $0.ownerScopeId == record.ownerScopeId || $0.token == record.token }
            pending.append(record)
            savePendingRevocationsLocked(pending, store: store)
        }
    }

    func pendingRevocations() -> [PushRegistrationRecord] {
        storage.withLock { pendingRevocationsLocked(store: $0) }
    }

    func completePendingRevocation(_ record: PushRegistrationRecord) {
        storage.withLock { store in
            var pending = pendingRevocationsLocked(store: store)
            pending.removeAll { $0.ownerScopeId == record.ownerScopeId && $0.token == record.token }
            savePendingRevocationsLocked(pending, store: store)
        }
    }

    private func pendingRevocationsLocked(store: TokenStore) -> [PushRegistrationRecord] {
        guard let json = (try? store.string(for: Key.pendingRevocations)) ?? nil,
              let data = json.data(using: .utf8),
              let records = try? JSONDecoder.signalQuest.decode([PushRegistrationRecord].self, from: data) else {
            try? store.remove(Key.pendingRevocations)
            return []
        }
        return records.filter {
            $0.ownerScopeId.hasPrefix("user:") &&
                !$0.token.isEmpty &&
                !$0.deviceID.isEmpty &&
                !($0.revocationSecret?.isEmpty ?? true)
        }
    }

    private func savePendingRevocationsLocked(_ records: [PushRegistrationRecord], store: TokenStore) {
        guard !records.isEmpty else {
            try? store.remove(Key.pendingRevocations)
            return
        }
        guard let data = try? JSONEncoder.signalQuest.encode(records),
              let json = String(data: data, encoding: .utf8) else { return }
        try? store.set(json, for: Key.pendingRevocations, accessibility: .afterFirstUnlock)
    }

    private func removePendingLocked(matchingToken token: String, store: TokenStore) {
        var pending = pendingRevocationsLocked(store: store)
        pending.removeAll { $0.token == token }
        savePendingRevocationsLocked(pending, store: store)
    }
}

private struct DevicePushRegistration: Encodable {
    let fcmToken: String
    let platform: String
    let deviceId: String
    let environment: String
    let locale: String
    let timeZone: String
}

private struct DevicePushRegistrationResponse: Decodable {
    let success: Bool?
    let ownerScope: String?
    let revocationSecret: String?
    let deviceId: String?
}

private struct DevicePushRevocation: Encodable {
    let fcmToken: String
    let platform: String?
    let deviceId: String?
    let environment: String?
    let revocationSecret: String?
}

struct E2EEV2NotificationScope: Equatable, Sendable {
    let ownerScopeId: String
    let sessionId: String

    func matches(ownerScopeId: String?, sessionId: String?) -> Bool {
        self.ownerScopeId == ownerScopeId && self.sessionId == sessionId
    }

    var isCurrent: Bool {
        matches(ownerScopeId: PushOwnerScope.current, sessionId: LocalAccountScope.currentSessionId)
    }

    static func capture() -> E2EEV2NotificationScope? {
        guard let ownerScopeId = PushOwnerScope.current,
              let sessionId = LocalAccountScope.currentSessionId else { return nil }
        let scope = E2EEV2NotificationScope(ownerScopeId: ownerScopeId, sessionId: sessionId)
        return scope.isCurrent ? scope : nil
    }

    static func publishIfCurrent(
        isCurrent: () -> Bool,
        publish: () async -> Bool,
        cancel: () -> Void
    ) async -> Bool {
        guard isCurrent() else { return false }
        let published = await publish()
        guard isCurrent() else {
            cancel()
            return false
        }
        return published
    }

    static func clearPostedNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications
                .map(\.request.identifier).filter { $0.hasPrefix("e2ee-v2:") })
        }
        center.getPendingNotificationRequests { requests in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: requests
                .map(\.identifier).filter { $0.hasPrefix("e2ee-v2:") })
        }
    }
}

enum E2EEV2NotificationPrivacyStore {
    static func get(ownerScopeId: String? = PushOwnerScope.current) -> E2EEV2NotificationPrivacy {
        guard let ownerScopeId else { return .hidden }
        return E2EEV2NotificationPrivacy(
            rawValue: UserDefaults.standard.string(forKey: key(ownerScopeId)) ?? ""
        ) ?? .full
    }

    @discardableResult
    static func set(_ value: E2EEV2NotificationPrivacy, ownerScopeId: String? = PushOwnerScope.current) -> Bool {
        guard let ownerScopeId else { return false }
        let previous = get(ownerScopeId: ownerScopeId)
        UserDefaults.standard.set(value.rawValue, forKey: key(ownerScopeId))
        if ownerScopeId == PushOwnerScope.current {
            if previous != value {
                guard E2EEV2NotificationContextEvents.revoke() else {
                    UserDefaults.standard.set(previous.rawValue, forKey: key(ownerScopeId))
                    return false
                }
                E2EEV2NotificationScope.clearPostedNotifications()
            }
            E2EEV2NotificationContextEvents.requestRefresh(.preferences)
        }
        return true
    }

    static func isNoticeAcknowledged(ownerScopeId: String? = PushOwnerScope.current) -> Bool {
        guard let ownerScopeId else { return false }
        return UserDefaults.standard.bool(forKey: "e2ee-v2-preview-notice-v1.\(ownerScopeId)")
    }

    @discardableResult
    static func acknowledgeNotice(
        privacy: E2EEV2NotificationPrivacy,
        ownerScopeId: String? = PushOwnerScope.current
    ) -> Bool {
        guard let ownerScopeId, ownerScopeId == PushOwnerScope.current else { return false }
        let previous = get(ownerScopeId: ownerScopeId)
        let previouslyAcknowledged = isNoticeAcknowledged(ownerScopeId: ownerScopeId)
        UserDefaults.standard.set(privacy.rawValue, forKey: key(ownerScopeId))
        UserDefaults.standard.set(true, forKey: "e2ee-v2-preview-notice-v1.\(ownerScopeId)")
        guard E2EEV2NotificationContextEvents.revoke() else {
            UserDefaults.standard.set(previous.rawValue, forKey: key(ownerScopeId))
            UserDefaults.standard.set(previouslyAcknowledged, forKey: "e2ee-v2-preview-notice-v1.\(ownerScopeId)")
            return false
        }
        E2EEV2NotificationScope.clearPostedNotifications()
        E2EEV2NotificationContextEvents.requestRefresh(.preferences)
        return true
    }

    private static func key(_ ownerScopeId: String) -> String {
        "e2ee-v2-notification-privacy.\(ownerScopeId)"
    }
}

enum PushRecipientDecision: Equatable {
    case acceptTargeted
    case acceptPublic
    case rejectNoActiveAccount
    case rejectMissingTarget
    case rejectWrongAccount
}

enum PushRecipientPolicy {
    static func evaluate(
        _ info: [AnyHashable: Any],
        currentOwnerScopeId: String? = PushOwnerScope.current
    ) -> PushRecipientDecision {
        let declaredOwner = string(info, "recipientOwnerScope")
        if let declaredOwner {
            guard let currentOwnerScopeId else { return .rejectNoActiveAccount }
            return declaredOwner == currentOwnerScopeId ? .acceptTargeted : .rejectWrongAccount
        }

        guard isAccountBound(info) else { return .acceptPublic }
        return currentOwnerScopeId == nil ? .rejectNoActiveAccount : .rejectMissingTarget
    }

    static func accepts(
        _ info: [AnyHashable: Any],
        currentOwnerScopeId: String? = PushOwnerScope.current
    ) -> Bool {
        switch evaluate(info, currentOwnerScopeId: currentOwnerScopeId) {
        case .acceptTargeted, .acceptPublic: true
        case .rejectNoActiveAccount, .rejectMissingTarget, .rejectWrongAccount: false
        }
    }

    private static func isAccountBound(_ info: [AnyHashable: Any]) -> Bool {
        if string(info, "conversationId", "conversation_id", "messageId", "message_id",
                  "callId", "call_id", "sessionId", "session_id") != nil {
            return true
        }
        let type = string(info, "type")?.lowercased() ?? ""
        return type.hasPrefix("message_") ||
            type.hasPrefix("call_") ||
            type.hasPrefix("live_share_") ||
            type.hasPrefix("friend_") ||
            type.hasPrefix("bug_") ||
            type.hasPrefix("badge_") ||
            type.hasPrefix("level_") ||
            type.hasPrefix("streak_") ||
            [
                "e2ee_sync", "favorite_antenna_issue", "zone_antenna_issue",
                "zone_new_antenna", "zone_antenna_upgrade", "coverage_session_auto_closed",
                "antenna_report_reply", "photo_comment", "photo_like", "photo_mention",
                "photo_reply", "test_push", "new_bug", "e2ee_v2_device_approval",
                "e2ee_v2_envelope"
            ].contains(type)
    }

    private static func string(_ info: [AnyHashable: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = info[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
        }
        return nil
    }
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
    private let e2eeV2Delivery: E2EEV2MessageDeliveryClient
    private let notificationContextBridge: E2EEV2NotificationContextBridge
    private var notificationContextObserver: NSObjectProtocol?
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
        e2eeV2Delivery = E2EEV2MessageDeliveryClient(api: api)
        notificationContextBridge = E2EEV2NotificationContextBridge(api: api)
        super.init()
        notificationContextObserver = NotificationCenter.default.addObserver(
            forName: E2EEV2NotificationContextEvents.refresh, object: nil, queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?["reason"] as? String)
                .flatMap(E2EEV2NotificationContextRefreshReason.init(rawValue:)) ?? .foreground
            Task { [weak self] in await self?.refreshE2eeV2NotificationContext(reason: reason) }
        }
    }

    deinit {
        if let notificationContextObserver { NotificationCenter.default.removeObserver(notificationContextObserver) }
    }

    func refreshE2eeV2NotificationContext(reason: E2EEV2NotificationContextRefreshReason = .foreground) async {
        _ = await notificationContextBridge.refreshRuntime(reason: reason)
    }

    @discardableResult
    func acknowledgeOutageNotification(_ info: [AnyHashable: Any], state: String) async -> Bool {
        guard let receipt = OutageNotificationReceiptPayload.parse(info, state: state) else { return false }
        return await acknowledgeOutageNotification(id: receipt.id, payload: receipt.payload)
    }

    @discardableResult
    func acknowledgeOutageNotification(
        id: String,
        payload: OutageNotificationReceiptPayload
    ) async -> Bool {
        do {
            let _: OutageNotificationReceiptResponse = try await api.requestJSON(
                "/api/community-outages/notifications/\(id)/receipt",
                method: .post,
                body: payload,
                authenticated: false
            )
            return true
        } catch {
            return false
        }
    }

    func handleE2eeV2Envelope(_ envelopeId: String) async -> Bool {
        guard envelopeId.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#,
            options: .regularExpression
        ) != nil,
        let scope = E2EEV2NotificationScope.capture() else { return false }
        let identifier = "e2ee-v2:\(scope.ownerScopeId):\(scope.sessionId):\(envelopeId)"
        let placeholderPosted = await postE2eeV2LocalNotification(
            identifier: identifier,
            scope: scope,
            conversationId: nil,
            presentation: E2EEV2NotificationPresentationPolicy.placeholder,
            playSound: true
        )
        guard scope.isCurrent else { return false }
        guard E2EEV2RuntimeReadGate.enabled else { return placeholderPosted }
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        let result = await e2eeV2Delivery.fetchOpaqueNotificationRuntime(
            ownerScopeId: ownerScopeId,
            envelopeId: envelopeId
        )
        guard scope.isCurrent else { return false }
        switch result {
        case .failure:
            return placeholderPosted // le placeholder générique reste visible avant déverrouillage
        case .success(let delivered):
            let requestedPrivacy = E2EEV2NotificationPrivacyStore.get(ownerScopeId: scope.ownerScopeId)
            let senderName = requestedPrivacy == .hidden ? nil : await resolveE2eeV2SenderName(
                conversationId: delivered.delivery.incoming.conversationId,
                senderId: delivered.delivery.senderId
            )
            guard scope.isCurrent else { return false }
            let privacy = E2EEV2NotificationPrivacyStore.get(ownerScopeId: scope.ownerScopeId)
            let presentation = E2EEV2NotificationPresentationPolicy.present(
                delivered.message,
                privacy: privacy,
                senderName: senderName
            )
            return await postE2eeV2LocalNotification(
                identifier: identifier,
                scope: scope,
                conversationId: delivered.delivery.incoming.conversationId,
                presentation: presentation,
                playSound: false
            )
        }
    }

    private func resolveE2eeV2SenderName(
        conversationId: String,
        senderId: String
    ) async -> String? {
        guard let response = try? await api.request(
            APIEndpoint(path: "/api/messages/conversations"),
            as: ConversationsResponse.self
        ),
        let conversation = response.conversations.first(where: { $0.id == conversationId }),
        let sender = conversation.participants.first(where: { $0.userId == senderId })?.user else {
            return nil
        }
        let value = sender.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        return sender.email.split(separator: "@").first.map(String.init)
    }

    private func postE2eeV2LocalNotification(
        identifier: String,
        scope: E2EEV2NotificationScope,
        conversationId: String?,
        presentation: E2EEV2NotificationPresentation,
        playSound: Bool
    ) async -> Bool {
        guard scope.isCurrent else { return false }
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = playSound ? .default : nil
        // Aucune action de réponse directe héritée : le contenu v2 n'est disponible
        // qu'après vérification et déchiffrement local par un appareil approuvé.
        content.threadIdentifier = conversationId ?? "e2ee-v2"
        var info: [String: Any] = [
            "type": "e2ee_v2_envelope",
            "privacy": presentation.privacy.rawValue,
            "recipientOwnerScope": scope.ownerScopeId,
            "e2eeNotificationSessionId": scope.sessionId,
        ]
        if let conversationId { info["conversationId"] = conversationId }
        content.userInfo = info
        let center = UNUserNotificationCenter.current()
        return await E2EEV2NotificationScope.publishIfCurrent(
            isCurrent: {
                scope.isCurrent && (conversationId == nil ||
                    E2EEV2NotificationPrivacyStore.get(ownerScopeId: scope.ownerScopeId) == presentation.privacy)
            },
            publish: {
                do {
                    try await center.add(
                        UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                    )
                    return true
                } catch {
                    return false
                }
            },
            cancel: {
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            }
        )
    }

    @MainActor
    func requestAuthorizationAndRegister() async {
        Task { [weak self] in await self?.refreshE2eeV2NotificationContext() }
        await retryPendingRevocations()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Les catégories sont posées AVANT la demande d'autorisation, et non
        // après : iOS les consulte à la livraison, y compris pour une
        // notification arrivée juste après l'accord. Sans `.allowInCarPlay`
        // (porté par ces catégories), rien n'atteint l'écran du véhicule — même
        // une notification qui s'affiche parfaitement sur l'iPhone.
        //
        // ⚠️ Côté serveur, le payload APNs doit porter le `category`
        // correspondant, sinon la déclaration ici reste sans effet.
        center.setNotificationCategories(CarPlayNotificationCategories.all())
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound, .providesAppNotificationSettings])
            logger.info("Notification permission granted=\(granted, privacy: .public)")
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
                // Un changement de compte ne provoque pas nécessairement une rotation du
                // token FCM, donc le delegate peut ne pas être rappelé. On relit le token
                // courant à chaque session authentifiée pour l'associer explicitement au
                // bon propriétaire côté serveur.
                if AppDelegate.isFirebaseConfigured,
                   let token = try? await Messaging.messaging().token(),
                   !token.isEmpty {
                    didRegister(fcmToken: token)
                }
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
            guard let expectedOwnerScopeId = PushOwnerScope.current else {
                logger.info("FCM token kept locally until an authenticated account is active")
                return
            }
            do {
                await retryPendingRevocations()
                let response: DevicePushRegistrationResponse = try await api.requestJSON(
                    "/api/user/fcm-token",
                    body: DevicePushRegistration(
                        fcmToken: token,
                        platform: "ios",
                        deviceId: deviceID,
                        environment: api.config.environment.rawValue,
                        locale: Locale.current.identifier,
                        timeZone: TimeZone.current.identifier
                    )
                )
                guard response.ownerScope == expectedOwnerScopeId else {
                    logger.error("Push registration rejected: owner scope was not verified")
                    if let secret = response.revocationSecret {
                        let untrusted = PushRegistrationRecord(
                            ownerScopeId: expectedOwnerScopeId,
                            token: token,
                            deviceID: response.deviceId ?? deviceID,
                            revocationSecret: secret,
                            registeredAt: Date()
                        )
                        identity.enqueuePendingRevocation(untrusted)
                        await retryPendingRevocations()
                    }
                    return
                }
                let record = PushRegistrationRecord(
                    ownerScopeId: expectedOwnerScopeId,
                    token: token,
                    deviceID: response.deviceId ?? deviceID,
                    revocationSecret: response.revocationSecret,
                    registeredAt: Date()
                )
                guard identity.saveRegistration(record) else {
                    logger.error("Push registration could not be persisted securely")
                    _ = await revokeUsingStoredSecret(record)
                    return
                }
                guard PushOwnerScope.current == expectedOwnerScopeId else {
                    identity.enqueuePendingRevocation(record)
                    identity.removeRegistration(ownerScopeId: expectedOwnerScopeId)
                    await retryPendingRevocations()
                    return
                }
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
        let ownerScopeId = PushOwnerScope.current
        // Le cycle d'authentification possède ce snapshot. L'invalider ici ferait
        // échouer la garde de `AuthSessionViewModel.logout()` avant même
        // `AuthService.logout()`, laissant le compte visuellement connecté.
        E2EEV2NotificationContextEvents.revoke()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        E2EEV2NotificationScope.clearPostedNotifications()
        let inMemoryToken = lastToken.withLock { value -> String? in
            let current = value
            value = nil
            return current
        }
        let token = inMemoryToken ?? identity.storedFCMToken()
        let storedRegistration = ownerScopeId.flatMap(identity.registration(ownerScopeId:))
        await MainActor.run {
            UIApplication.shared.unregisterForRemoteNotifications()
            UNUserNotificationCenter.current().setBadgeCountCompat(0)
        }
        if let token {
            do {
                let _: SuccessResponse = try await api.requestJSON(
                    "/api/user/fcm-token",
                    method: .delete,
                    body: DevicePushRevocation(
                        fcmToken: token,
                        platform: "ios",
                        deviceId: deviceID,
                        environment: api.config.environment.rawValue,
                        revocationSecret: nil
                    )
                )
                if let ownerScopeId { identity.removeRegistration(ownerScopeId: ownerScopeId) }
            } catch {
                if let storedRegistration, storedRegistration.token == token {
                    identity.enqueuePendingRevocation(storedRegistration)
                    if let ownerScopeId { identity.removeRegistration(ownerScopeId: ownerScopeId) }
                }
                logger.error("Push unregister deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        identity.clearFCMToken()
        let firebaseConfigured = await MainActor.run { AppDelegate.isFirebaseConfigured }
        if firebaseConfigured {
            try? await Messaging.messaging().deleteToken()
        }
        await retryPendingRevocations()
    }

    func acceptsPush(_ info: [AnyHashable: Any]) -> Bool {
        let decision = PushRecipientPolicy.evaluate(info)
        guard decision == .acceptTargeted || decision == .acceptPublic else {
            logger.error("Push ignored by recipient policy: \(String(describing: decision), privacy: .public)")
            return false
        }
        if Self.string(info, "type") == "e2ee_v2_envelope",
           let sessionId = Self.string(info, "e2eeNotificationSessionId") {
            guard let ownerScopeId = Self.string(info, "recipientOwnerScope"),
                  E2EEV2NotificationScope(ownerScopeId: ownerScopeId, sessionId: sessionId).isCurrent else {
                return false
            }
        }
        return true
    }

    private func retryPendingRevocations() async {
        for record in identity.pendingRevocations() {
            guard record.revocationSecret?.isEmpty == false else {
                identity.completePendingRevocation(record)
                continue
            }
            if await revokeUsingStoredSecret(record) {
                identity.completePendingRevocation(record)
            } else {
                logger.info("Pending push revocation will be retried later")
            }
        }
    }

    private func revokeUsingStoredSecret(_ record: PushRegistrationRecord) async -> Bool {
        guard let secret = record.revocationSecret, !secret.isEmpty else { return false }
        do {
            let _: SuccessResponse = try await api.requestJSON(
                "/api/user/fcm-token",
                method: .delete,
                body: DevicePushRevocation(
                    fcmToken: record.token,
                    platform: nil,
                    deviceId: nil,
                    environment: nil,
                    revocationSecret: secret
                ),
                authenticated: false
            )
            return true
        } catch {
            return false
        }
    }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        guard acceptsPush(info) else { return [] }
        _ = await acknowledgeOutageNotification(info, state: "received")
        if Self.string(info, "type")?.lowercased() == "e2ee_v2_device_approval",
           Self.e2eeDeviceApprovalID(info) == nil {
            center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
            return []
        }
        return [.banner, .sound, .badge]
    }

    /// Cible du lien « Réglages de notifications » exposé par iOS grâce à l'option
    /// `.providesAppNotificationSettings`. Sans cette implémentation, le lien
    /// n'ouvrait l'app nulle part (UXP-09). On amène l'utilisateur aux Réglages iOS
    /// de l'app (notifications), point d'action réel.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            openSettingsFor notification: UNNotification?) {
        Task { @MainActor in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    /// Handles a notification tap. We extract the identifiers off the (non-Sendable)
    /// payload here, then hand only `String?` values to the MainActor router so a
    /// tap reliably deep-links instead of doing nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard acceptsPush(info) else {
            center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
            return
        }
        _ = await acknowledgeOutageNotification(info, state: "opened")
        let type = Self.string(info, "type")
        let conversationId = Self.string(info, "conversationId", "conversation_id")
        let postId = Self.string(info, "postId", "post_id")
        let userId = Self.string(info, "userId", "user_id", "actorId", "actor_id")
        let siteId = Self.string(info, "siteId", "site_id")
        let reportId = Self.string(info, "reportId", "report_id")
        let targetId = Self.string(info, "targetId", "target_id")
        // Panne communautaire : le fan-out serveur envoie `outageId` à côté de `siteId`. Sans
        // cette extraction, le tap ouvrait la fiche du SITE — la panne, elle, restait à retrouver.
        let outageId = Self.string(info, "outageId", "outage_id")
        let e2eeDeviceApprovalId = Self.e2eeDeviceApprovalID(info)
        if type?.lowercased() == "e2ee_v2_device_approval", e2eeDeviceApprovalId == nil {
            center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
            return
        }
        await MainActor.run {
            self.router.handle(
                type: type,
                conversationId: conversationId,
                postId: postId,
                userId: userId,
                siteId: siteId,
                reportId: reportId,
                targetId: targetId,
                outageId: outageId,
                e2eeDeviceApprovalId: e2eeDeviceApprovalId
            )
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

    static func e2eeDeviceApprovalID(_ info: [AnyHashable: Any]) -> String? {
        guard let type = string(info, "type")?.lowercased(),
              let approvalId = string(info, "approvalId", "approval_id"),
              let expiresAt = string(info, "expiresAt", "expires_at") else { return nil }
        return E2EEV2DeviceApprovalContract.pushApprovalID([
            "type": type,
            "approvalId": approvalId,
            "expiresAt": expiresAt,
        ])
    }
}
