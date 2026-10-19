import SwiftUI

struct MessageReactionSummary: Identifiable {
    let emoji: String
    let count: Int
    /// L'utilisateur courant a posé cette réaction (capsule teintée accentSoft).
    let mine: Bool

    var id: String { emoji }
}

/// Marges internes d'une bulle de message : la conversation et le fil les
/// partagent pour que leurs bulles restent alignées.
enum MessageBubbleMetrics {
    static let verticalPadding: CGFloat = 11
    static let horizontalPadding: CGFloat = 15
}

/// Statut d'une bulle envoyée de façon optimiste (MSG-API-01).
enum MessageSendStatus: Equatable { case sending, failed }

/// Tout ce qu'il faut pour rejouer un envoi échoué à l'identique (sans
/// régénérer l'Idempotency-Key, donc sans risque de doublon serveur).
struct PendingSend {
    let text: String
    let replyToId: String?
    let idempotencyKey: String
    let ttlSeconds: Int
    /// Relu dans la file d'envoi durable après une fermeture : on le renvoie
    /// tel qu'il a été préparé (texte chiffré compris), pas en le réécrivant.
    var restored = false
    /// Cause du dernier refus, montrée sous la bulle « Non envoyé » (U06).
    var failureReason: String? = nil
}

/// Repère « N nouveaux messages » (M05) : le premier message reçu après la dernière lecture
/// connue au moment de l'ouverture, et combien en suivent. Calculé une fois à l'ouverture ;
/// les messages qui arrivent ensuite ne le déplacent pas.
struct UnreadDivider: Equatable {
    let messageId: String
    let count: Int

    /// Au-delà, l'ouverture se place sur le repère plutôt qu'en bas : quelques messages
    /// tiennent à l'écran avec le bas de la conversation.
    static let scrollsToDividerFrom = 7

    /// `messages` dans l'ordre du fil. Rien sans date de dernière lecture : tout paraîtrait nouveau.
    static func make(messages: [MessageItem], lastReadAt: Date?, currentUserId: String?) -> UnreadDivider? {
        guard let lastReadAt, let currentUserId else { return nil }
        let unread = messages.filter {
            !$0.id.hasPrefix("local-") && $0.deletedAt == nil && $0.senderId != currentUserId
                && ($0.createdAt ?? .distantPast) > lastReadAt
        }
        guard let first = unread.first else { return nil }
        return UnreadDivider(messageId: first.id, count: unread.count)
    }
}

/// Bandeau « Hors connexion » de la liste et du fil (U02) : les envois sont gardés et partent
/// au retour du réseau.
struct MessagesOfflineBanner: View {
    var body: some View {
        Label("Hors connexion : tes messages partiront au retour du réseau.", systemImage: "wifi.slash")
            .font(SQType.caption.weight(.semibold))
            .foregroundStyle(SQColor.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.warningSoft)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("messages.offlineBanner")
    }
}
