import Foundation

/// Anciens messages d'une conversation passée au chiffrement automatique
/// (E2EE-AUTO §8) : lus par la route v1, montrés après le bloc « historique
/// importé » et avant les messages v2. Un message en clair reste lisible avec
/// sa mention ; un message v1 qu'un import vérifié cite disparaît derrière lui ;
/// les autres messages v1 restent « ancien message non importé ».
enum E2EEAutoLegacyHistory {
    /// Sous `local-` exprès : le fil v2 ne propose aucune action serveur sur une
    /// bulle locale (réponse, réaction, suppression), et ces lignes v1 n'en
    /// acceptent plus.
    static let idPrefix = "local-legacy-"

    /// `importRefs` : identifiant v1 cité par un import vérifié → message v2.
    static func present(
        _ legacy: [MessageItem],
        importRefs: [String: String]
    ) -> (messages: [MessageItem], captions: [String: String]) {
        let shown = legacy.filter { importRefs[$0.id] == nil && !$0.id.hasPrefix("local-") }
        let shownIds = Set(shown.map(\.id))
        var captions: [String: String] = [:]
        let messages = shown.map { item -> MessageItem in
            let id = idPrefix + item.id
            let replyToId = item.replyToId.flatMap { target in
                importRefs[target] ?? (shownIds.contains(target) ? idPrefix + target : nil)
            }
            guard item.isEncrypted else {
                captions[id] = String(localized: "ancien message non chiffré")
                return MessageItem(
                    id: id, conversationId: item.conversationId, senderId: item.senderId, kind: item.kind,
                    content: item.content, e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil,
                    metadata: item.metadata, createdAt: item.createdAt, editedAt: item.editedAt, deletedAt: item.deletedAt,
                    expiresAt: item.expiresAt, replyToId: replyToId, threadReplyCount: nil, sender: item.sender,
                    attachments: item.attachments, reactions: item.reactions
                )
            }
            return MessageItem(
                id: id, conversationId: item.conversationId, senderId: item.senderId, kind: "TEXT",
                content: item.deletedAt == nil ? String(localized: "ancien message non importé") : nil,
                e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                createdAt: item.createdAt, editedAt: nil, deletedAt: item.deletedAt, expiresAt: item.expiresAt,
                replyToId: replyToId, threadReplyCount: nil, sender: item.sender, attachments: [], reactions: []
            )
        }
        return (messages, captions)
    }
}
