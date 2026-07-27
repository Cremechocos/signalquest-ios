import SwiftUI

struct MessageReactionSummary: Identifiable {
    let emoji: String
    let count: Int
    /// L'utilisateur courant a posé cette réaction (capsule teintée accentSoft).
    let mine: Bool

    var id: String { emoji }
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
}
