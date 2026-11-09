import Foundation
import CryptoKit

enum E2EEV2NotificationDeliveryPolicy {
    static func usesServiceExtension(_ info: [AnyHashable: Any]) -> Bool {
        guard info["type"] as? String == "e2ee_v2_envelope",
              let aps = info["aps"] as? [String: Any] else { return false }
        return (aps["mutable-content"] as? NSNumber)?.intValue == 1
    }
}

enum E2EEV2NotificationPrivacy: String, Codable, CaseIterable, Sendable {
    case full
    case senderOnly = "sender_only"
    case hidden
}

struct E2EEV2NotificationPresentation: Equatable, Sendable {
    let title: String
    let body: String
    let privacy: E2EEV2NotificationPrivacy
    /// Une modification ou une suppression ne sonne pas : ce n'est pas un
    /// nouveau message.
    var playsSound = true
}

enum E2EEV2NotificationPresentationPolicy {
    static func present(
        _ message: E2EEV2DecryptedMessage,
        privacy: E2EEV2NotificationPrivacy,
        senderName: String? = nil
    ) -> E2EEV2NotificationPresentation {
        let kind = message.content["kind"] as? String
        let body = message.content["body"] as? [String: Any]
        let fullText: String
        switch kind {
        case "TEXT":
            let text = (body?["text"] as? String)?
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ") ?? ""
            fullText = text.isEmpty ? String(localized: "Nouveau message") : String(text.prefix(240))
        case "MEDIA": fullText = String(localized: "Pièce jointe")
        case "AUDIO": fullText = String(localized: "Message vocal")
        case "LOCATION": fullText = String(localized: "Position")
        case "LIVE_LOCATION": fullText = String(localized: "Position en direct")
        case "CARD": fullText = String(localized: "Carte SignalQuest")
        case "REACTION": fullText = String(localized: "A réagi à un message")
        case "EDIT": fullText = String(localized: "Message modifié")
        default: fullText = String(localized: "Nouveau message")
        }
        return presentation(fullText: fullText, privacy: privacy, senderName: senderName)
    }

    /// Message v2 ouvert par l'extension (§2.6) : le texte seulement en mode
    /// complet, jamais celui d'un message éphémère (la notification lui
    /// survivrait), d'une édition ou d'une suppression. Une réaction reste
    /// générique, sans emoji : l'extension ne sait pas si la cible est un
    /// message du destinataire (D.16).
    static func present(
        _ payload: E2EEV2ContentPayloadV2,
        ephemeral: Bool,
        privacy: E2EEV2NotificationPrivacy,
        senderName: String? = nil
    ) -> E2EEV2NotificationPresentation {
        let fullText: String
        switch payload.body {
        case .text where ephemeral:
            fullText = String(localized: "Message éphémère")
        case .text(let text):
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            fullText = normalized.isEmpty ? String(localized: "Nouveau message") : String(normalized.prefix(240))
        case .edit: fullText = String(localized: "Message modifié")
        case .delete: fullText = String(localized: "Message supprimé")
        // La cible reste inconnue ici : « un message », jamais « ton message » (choix du 09/11).
        case .reaction: fullText = String(localized: "A réagi à un message")
        // Aucun push n'est envoyé pour un import (E2EE-AUTO §8) : jamais son contenu.
        case .historyImport: fullText = String(localized: "Nouveau message")
        case .r17(let body): fullText = r17Text(body, ephemeral: ephemeral)
        }
        var result = presentation(fullText: fullText, privacy: privacy, senderName: senderName)
        switch payload.body {
        case .edit, .delete, .historyImport: result.playsSound = false
        case .r17(let body) where body.delivery == .annotation: result.playsSound = false
        case .text, .reaction, .r17: break
        }
        return result
    }

    /// Révision 17 : la nature seule (« Photo », « Message vocal »…), jamais un nom de
    /// fichier ; la légende d'un message non éphémère, comme un texte.
    static func r17Text(_ body: E2EEAutoContentR17.Body, ephemeral: Bool) -> String {
        switch body {
        case .media(let caption, let attachments):
            if !ephemeral, let caption {
                let normalized = caption.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !normalized.isEmpty { return String(normalized.prefix(240)) }
            }
            let kinds = Set(attachments.map { E2EEAutoContentR17.presentation(mimeType: $0.file.mimeType) })
            if attachments.count > 1 { return String(localized: "Pièces jointes") }
            if kinds == [.image] { return String(localized: "Photo") }
            if kinds == [.video] { return String(localized: "Vidéo") }
            return String(localized: "Fichier")
        case .audio: return String(localized: "Message vocal")
        case .poll: return String(localized: "Sondage")
        case .card: return String(localized: "Publication partagée")
        case .pollVote, .pollClose: return String(localized: "Nouveau message")
        }
    }

    /// Expéditeur authentifié, contenu jamais lu (mode « expéditeur seulement »).
    static func presentSender(privacy: E2EEV2NotificationPrivacy, senderName: String?) -> E2EEV2NotificationPresentation {
        presentation(fullText: String(localized: "Nouveau message"), privacy: privacy, senderName: senderName)
    }

    private static func presentation(
        fullText: String,
        privacy: E2EEV2NotificationPrivacy,
        senderName: String?
    ) -> E2EEV2NotificationPresentation {
        let normalizedSender = senderName?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let senderTitle = normalizedSender.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        switch privacy {
        case .full:
            return .init(title: senderTitle ?? String(localized: "Nouveau message"), body: fullText, privacy: privacy)
        case .senderOnly:
            return .init(
                title: senderTitle ?? String(localized: "Nouveau message"),
                body: String(localized: "Nouveau message"),
                privacy: privacy
            )
        case .hidden:
            return .init(title: "SignalQuest", body: String(localized: "Nouveau contenu privé"), privacy: privacy)
        }
    }

    static let placeholder = E2EEV2NotificationPresentation(
        title: String(localized: "Nouveau message"),
        body: String(localized: "Ouvre SignalQuest pour afficher le message."),
        privacy: .hidden
    )
}
