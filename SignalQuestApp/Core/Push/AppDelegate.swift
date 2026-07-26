import UIKit
import SwiftUI
import os
import FirebaseCore
import FirebaseMessaging

/// We bridge UIApplicationDelegate via SwiftUI's `@UIApplicationDelegateAdaptor`
/// to receive the APNs device token. The push service is injected from the
/// SwiftUI environment once it's available.
/// 
final class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var sharedPush: PushNotificationService?
    static weak var sharedCallManager: CallManager?
    // `E2EEServicing` n'est pas class-bound (donc pas `weak`). Référence forte :
    // le service vit le temps de l'app (détenu par AppServices), aucun cycle.
    static var sharedE2EE: E2EEServicing?

    /// `GoogleService-Info.plist` est volontairement gitignoré (dépôt public ;
    /// il est réinjecté par `ci_scripts/ci_post_clone.sh` sur Xcode Cloud). Sur
    /// un clone frais, `FirebaseApp.configure()` lève une exception Objective-C
    /// non rattrapable en Swift : l'app crashait au lancement avant même
    /// d'afficher un écran. On dégrade donc proprement — push et Crashlytics
    /// inopérants, tout le reste fonctionne.
    private(set) static var isFirebaseConfigured = false

    private static let logger = Logger(subsystem: "fr.signalquest.ios", category: "firebase")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else {
            Self.logger.error("GoogleService-Info.plist absent : Firebase désactivé (push et Crashlytics inopérants).")
            return true
        }
        FirebaseApp.configure()
        Self.isFirebaseConfigured = true
        // FCM remonte le token de registration via MessagingDelegate ci-dessous.
        Messaging.messaging().delegate = self
        return true
    }

    /// Push silencieux `e2ee_sync` : un destinataire (ex. un appareil Android
    /// fraîchement configuré) demande le re-partage de la clé de conversation.
    /// Best-effort : le matériel E2EE est stocké en Keychain `whenUnlocked`
    /// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), donc lisible SEULEMENT
    /// écran déverrouillé — verrouillé, `shareConversationKeyIfNeeded` no-op (voulu :
    /// ne pas abaisser la protection des clés). Le re-partage se fera à la prochaine
    /// ouverture/déverrouillage (SEC-06).
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard (userInfo["type"] as? String) == "e2ee_sync",
              let conversationId = (userInfo["conversationId"] as? String)
                  ?? (userInfo["conversation_id"] as? String),
              let e2ee = AppDelegate.sharedE2EE else {
            return .noData
        }
        await e2ee.shareConversationKeyIfNeeded(conversationId: conversationId)
        return .newData
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // On transmet le token APNs à FCM, qui en dérive le token de registration
        // FCM (le seul que le backend sait utiliser via firebase-admin). Le token
        // FCM remonte ensuite via `messaging(_:didReceiveRegistrationToken:)`.
        // `Messaging.messaging()` exige une app Firebase par défaut : sans plist,
        // l'appel serait fatal (cf. `isFirebaseConfigured`).
        guard Self.isFirebaseConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppDelegate.sharedPush?.didFailToRegister(error: error)
    }
}

// MARK: - Firebase Cloud Messaging
extension AppDelegate: MessagingDelegate {
    /// Token de registration FCM (généré/rafraîchi par le SDK). C'est lui — et non
    /// le token APNs brut — qu'on enregistre côté backend. `nonisolated` car le
    /// protocole FCM n'est pas isolé au MainActor ; on y repasse pour l'accès au
    /// service partagé.
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task { @MainActor in
            AppDelegate.sharedPush?.didRegister(fcmToken: fcmToken)
        }
    }
}
