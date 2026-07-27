import SwiftUI

/// Cache de rendu mémoïsé, partagé par toutes les bulles et conservé entre les
/// réévaluations du `body` de `ConversationDetailView`. Type référence rangé
/// dans un `@State` : muter son contenu ne réassigne pas le `@State`, donc ne
/// déclenche NI warning « state during view update » NI re-render. Uniquement
/// touché depuis le chemin de rendu (MainActor).
///
/// Deux rôles :
///  1. PERF-MSG-03 — parsing des cartes de partage / positions
///     (`ShareCardData.parse` / `MessageLocationData.parse`) : coûteux
///     (JSONSerialization + tri localizedCompare) et appelé jusqu'à deux fois
///     par bulle porteuse. Sans cache, chaque invalidation du body (frappe,
///     sendStatus, surbrillance…) re-parse tout le JSON. Mémoïsé par id de
///     message, invalidé si le `metadata` du message change (édition).
///  2. PERF-MSG-04 — index O(1) d'un message dans la liste, pour l'accès aux
///     voisins sans matérialiser `Array(messages.enumerated())` à chaque body.
///
/// Bornage mémoire : entrées clés par id de message ; durée de vie = celle de la
/// conversation affichée (le `@State` est recréé à chaque nouvelle conversation),
/// comme `decryptedMessages` / `pollsByMessageId`.
final class MessageRenderCache {
    // MARK: PERF-MSG-03 — parsing metadata mémoïsé

    /// Résultat parsé + le `metadata` d'origine (pour invalider si le message est
    /// réédité avec un metadata différent tout en gardant le même id).
    var cards: [String: (metadata: String?, value: ShareCardData?)] = [:]
    var locations: [String: (metadata: String?, value: MessageLocationData?)] = [:]

    func shareCard(for message: MessageItem) -> ShareCardData? {
        if let cached = cards[message.id], cached.metadata == message.metadata {
            return cached.value
        }
        let value = ShareCardData.parse(fromMetadataJSON: message.metadata)
        cards[message.id] = (message.metadata, value)
        return value
    }

    func location(for message: MessageItem) -> MessageLocationData? {
        if let cached = locations[message.id], cached.metadata == message.metadata {
            return cached.value
        }
        let value = MessageLocationData.parse(fromMetadataJSON: message.metadata)
        locations[message.id] = (message.metadata, value)
        return value
    }

    // MARK: PERF-MSG-04 — index O(1) dans la liste

    struct ListSignature: Equatable {
        let count: Int
        let first: String?
        let last: String?
    }

    var indexByID: [String: Int] = [:]
    var indexSignature: ListSignature?

    /// Index du message dans `messages`. La table `[id: index]` n'est
    /// reconstruite que lorsque la structure de la liste change — détecté par une
    /// signature bon marché (nombre + premier/dernier id) : les réévaluations
    /// « chaudes » (frappe, sendStatus, surbrillance) qui ne touchent pas
    /// `messages` n'allouent donc rien. Auto-guérison : si l'entrée est absente
    /// ou pointe vers un autre message (structure changée à signature identique,
    /// cas théorique), on reconstruit — la valeur reste donc toujours correcte.
    func index(of message: MessageItem, in messages: [MessageItem]) -> Int {
        let signature = ListSignature(
            count: messages.count,
            first: messages.first?.id,
            last: messages.last?.id
        )
        if signature != indexSignature {
            rebuild(from: messages)
            indexSignature = signature
        }
        if let idx = indexByID[message.id], idx < messages.count, messages[idx].id == message.id {
            return idx
        }
        rebuild(from: messages)
        indexSignature = signature
        // `message` provient toujours de `messages` : après reconstruction, son
        // index est nécessairement présent (le repli 0 est donc inatteignable).
        return indexByID[message.id] ?? 0
    }

    func rebuild(from messages: [MessageItem]) {
        indexByID.removeAll(keepingCapacity: true)
        for (offset, item) in messages.enumerated() {
            indexByID[item.id] = offset
        }
    }
}
