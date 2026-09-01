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
            fullText = text.isEmpty ? String(localized: "Nouveau message chiffré") : String(text.prefix(240))
        case "MEDIA": fullText = String(localized: "Pièce jointe chiffrée")
        case "AUDIO": fullText = String(localized: "Message vocal chiffré")
        case "LOCATION": fullText = String(localized: "Position chiffrée")
        case "LIVE_LOCATION": fullText = String(localized: "Partage en direct chiffré")
        case "CARD": fullText = String(localized: "Carte SignalQuest chiffrée")
        case "REACTION": fullText = String(localized: "Nouvelle réaction chiffrée")
        case "EDIT": fullText = String(localized: "Message chiffré modifié")
        default: fullText = String(localized: "Nouveau message chiffré")
        }
        let normalizedSender = senderName?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let senderTitle = normalizedSender.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        switch privacy {
        case .full:
            return .init(title: senderTitle ?? String(localized: "Nouveau message"), body: fullText, privacy: privacy)
        case .senderOnly:
            return .init(
                title: senderTitle ?? String(localized: "Nouveau message chiffré"),
                body: String(localized: "Nouveau message chiffré"),
                privacy: privacy
            )
        case .hidden:
            return .init(title: "SignalQuest", body: String(localized: "Nouveau contenu privé"), privacy: privacy)
        }
    }

    static let placeholder = E2EEV2NotificationPresentation(
        title: String(localized: "Nouveau message chiffré"),
        body: String(localized: "Ouvrez SignalQuest pour afficher le message."),
        privacy: .hidden
    )
}
