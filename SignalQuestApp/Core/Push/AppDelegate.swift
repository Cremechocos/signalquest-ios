import UIKit
import SwiftUI
import FirebaseCore

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

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        return true
    }

    /// Push silencieux `e2ee_sync` : un destinataire (ex. un appareil Android
    /// fraîchement configuré) demande le re-partage de la clé de conversation.
    /// On re-partage la clé en arrière-plan — possible car le matériel E2EE est
    /// stocké en Keychain `AfterFirstUnlock`, donc lisible ici. Best-effort :
    /// si l'app est verrouillée / sans clé, `shareConversationKeyIfNeeded` no-op.
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
        AppDelegate.sharedPush?.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppDelegate.sharedPush?.didFailToRegister(error: error)
    }
}
