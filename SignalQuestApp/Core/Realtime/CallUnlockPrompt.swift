import UIKit
import UserNotifications

/// Spec §2.6 (v0.4.13) : un appel chiffré décroché téléphone verrouillé, sans
/// clé d'époque lisible (aperçu qui n'est pas complet), attend le
/// déverrouillage. L'écran de CallKit et une notification sans nom ni
/// conversation le disent.
@MainActor
enum CallUnlockPrompt {
    /// Plafond de l'attente, comptée depuis le décroché. La sonnerie, que le
    /// serveur expire 45 s après son début, peut la clore avant : l'appel se
    /// termine alors comme un appel sans réponse.
    static let maxWait: Duration = .seconds(40)

    /// Vrai dès que les données protégées sont lisibles, tant que l'appel est
    /// encore voulu ; faux à l'échéance, ou dès que `stillWanted` ne le
    /// demande plus (appel terminé entre-temps), même déverrouillé.
    static func waitForUnlock(
        timeout: Duration = maxWait,
        pollInterval: Duration = .milliseconds(250),
        isUnlocked: () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        stillWanted: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            guard stillWanted() else { return false }
            if isUnlocked() { return true }
            guard clock.now < deadline else { return false }
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        }
    }

    static func show(identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Appel chiffré")
        content.body = String(localized: "Déverrouille ton appareil pour rejoindre l’appel chiffré.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func dismiss(identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
