import Foundation
import UserNotifications

/// Actions d'une notification de message (plan 3, vague 2).
///
/// L'extension de notification pose la catégorie ; l'app déclare les actions
/// et les exécute. Dans une conversation normale : « Répondre » et « Marquer
/// comme lu ». Dans une conversation chiffrée, une réponse partirait en clair :
/// seul « Marquer comme lu » est proposé.
enum MessageNotificationCategory {
    static let plain = "fr.signalquest.message"
    static let encrypted = "fr.signalquest.message.encrypted"
    static let replyAction = "fr.signalquest.message.reply"
    static let markReadAction = "fr.signalquest.message.markRead"

    /// Catégorie d'une notification reçue, `nil` si ce n'est pas un message.
    static func category(for userInfo: [AnyHashable: Any]) -> String? {
        switch (userInfo["type"] as? String)?.lowercased() {
        case "message_new": return isEncrypted(userInfo) ? encrypted : plain
        // Une mention n'existe que hors chiffrement : le serveur ne lit pas le reste.
        case "message_mention": return plain
        default: return nil
        }
    }

    /// Le serveur envoie `isE2EE: "1"` ; un booléen est accepté aussi.
    static func isEncrypted(_ userInfo: [AnyHashable: Any]) -> Bool {
        switch userInfo["isE2EE"] {
        case let value as String: return value == "1" || value.lowercased() == "true"
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return false
        }
    }

    /// Contenu avec sa catégorie, inchangé pour tout ce qui n'est pas un message.
    static func categorized(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let category = category(for: content.userInfo),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        mutable.categoryIdentifier = category
        return mutable
    }
}
