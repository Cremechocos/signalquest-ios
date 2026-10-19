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
    /// Pour une conversation chiffrée (§13), le texte du serveur ne passe jamais :
    /// ni titre de conversation, ni nom, ni emoji, ni pièce jointe.
    static func categorized(
        _ content: UNNotificationContent,
        isProtected: (String) -> Bool = { ProtectedConversationList.contains($0) }
    ) -> UNNotificationContent {
        guard var category = category(for: content.userInfo),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        // Une conversation protégée n'a ni aperçu ni réponse rapide : « Marquer
        // comme lu » seulement, sous un texte générique.
        let hidden = category == plain && conversationId(in: content.userInfo).map(isProtected) == true
        if hidden { category = encrypted }
        mutable.categoryIdentifier = category
        if category == encrypted {
            mutable.title = "SignalQuest"
            mutable.subtitle = ""
            mutable.body = hidden ? String(localized: "Nouveau message") : String(localized: "Nouveau message chiffré")
            mutable.attachments = []
        }
        return mutable
    }

    /// Conversation visée par la notification (`conversationId` ou `conversation_id`).
    static func conversationId(in userInfo: [AnyHashable: Any]) -> String? {
        for key in ["conversationId", "conversation_id"] {
            if let value = userInfo[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

/// Conversations « protégées » (verrou à l'ouverture ou capture bloquée) connues
/// de l'app, partagées avec l'extension de notification par l'App Group : leurs
/// notifications n'ont ni aperçu ni réponse rapide, et Siri ne les propose pas.
/// Des identifiants de conversation seulement, jamais de contenu.
enum ProtectedConversationList {
    private static let key = "sq.messages.protectedConversations.v1"

    /// Même lecture de `SQ_APP_GROUP` que le dépôt de partage : alimentée par le
    /// xcconfig dans l'Info.plist de l'app ET de l'extension.
    static func appGroupDefaults(bundle: Bundle = .main) -> UserDefaults? {
        guard let group = bundle.object(forInfoDictionaryKey: "SQ_APP_GROUP") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func contains(_ conversationId: String, defaults: UserDefaults? = appGroupDefaults()) -> Bool {
        ids(defaults).contains(conversationId)
    }

    /// Ajoute `protected` à la liste et en retire `others` (conversations qui ne
    /// le sont plus, ou d'un compte qui s'en va).
    static func update(
        adding protected: Set<String>,
        removing others: Set<String> = [],
        defaults: UserDefaults? = appGroupDefaults()
    ) {
        guard let defaults else { return }
        let current = ids(defaults)
        let next = current.subtracting(others).union(protected)
        guard next != current else { return }
        defaults.set(Array(next).sorted(), forKey: key)
    }

    private static func ids(_ defaults: UserDefaults?) -> Set<String> {
        Set(defaults?.stringArray(forKey: key) ?? [])
    }
}
