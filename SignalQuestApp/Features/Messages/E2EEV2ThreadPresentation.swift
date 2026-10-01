import Foundation

/// Ce que le fil montre d'une conversation v2 (§4.2, §4.3, §5) : les messages
/// du magasin v2 sous la forme commune `MessageItem`, et les avis à poser dans
/// le fil. Rien ici ne touche au réseau ni aux clés : la relève et la
/// vérification sont faites avant, par la messagerie v2.
struct E2EEV2ThreadPresentation: Equatable {
    enum Notice: Equatable {
        /// Deux versions d'un même message : aucune n'est affichée (§4.2).
        case equivocation(count: Int)
        /// Des messages d'un membre n'ont pas été reçus (§4.3).
        case missing(senderName: String?, count: Int)
        /// Messages d'une version plus récente de l'app (§5.2).
        case unsupported(count: Int)
        /// L'appareil n'a pas encore la clé de l'époque courante (§3.2).
        case waitingForEpoch

        var text: String {
            switch self {
            case .equivocation:
                return String(localized: "Un message est arrivé en deux versions différentes : aucune n’est affichée.")
            case .missing(let name?, _):
                return String(localized: "Des messages de \(name) n’ont pas été reçus.")
            case .missing(nil, _):
                return String(localized: "Des messages n’ont pas été reçus.")
            case .unsupported:
                return String(localized: "Un message demande une version plus récente de SignalQuest.")
            case .waitingForEpoch:
                return String(localized: "En attente de la clé de cette conversation chiffrée.")
            }
        }
    }

    let messages: [MessageItem]
    let notices: [Notice]
}

enum E2EEV2ThreadPresenter {
    /// `members` : nom et avatar par utilisateur ; `deviceOwners` : l'utilisateur
    /// de chaque appareil certifié, pour nommer qui a des messages manquants.
    static func present(
        _ result: E2EEV2MessagesV2,
        conversationId: String,
        members: [String: MessageUser],
        deviceOwners: [String: String]
    ) -> E2EEV2ThreadPresentation {
        let messages = result.snapshot.messages.map { stored in
            MessageItem(
                id: stored.messageRef,
                conversationId: conversationId,
                senderId: stored.senderUserId,
                kind: "TEXT",
                content: stored.deleted ? nil : stored.text,
                e2eeVersion: 2,
                e2eeIvB64: nil,
                e2eeCiphertextB64: nil,
                e2eeAadB64: nil,
                metadata: nil,
                // L'heure du serveur ordonne et date le fil ; l'heure signée
                // de l'émetteur ne sert qu'à l'expiration (§5.4).
                createdAt: date(stored.serverTimeMs),
                editedAt: stored.deleted ? nil : stored.editedAtMs.map(date),
                deletedAt: stored.deleted ? date(stored.editedAtMs ?? stored.serverTimeMs) : nil,
                expiresAt: stored.expiresAtMs.map(date),
                replyToId: stored.replyToRef,
                threadReplyCount: nil,
                sender: members[stored.senderUserId],
                attachments: [],
                reactions: []
            )
        }
        var notices: [E2EEV2ThreadPresentation.Notice] = []
        if result.waitingForEpoch { notices.append(.waitingForEpoch) }
        if !result.snapshot.equivocalRefs.isEmpty {
            notices.append(.equivocation(count: result.snapshot.equivocalRefs.count))
        }
        // Un avis par membre, pas par appareil : ses appareils s'additionnent.
        var missingByUser: [String?: Int] = [:]
        for (deviceId, count) in result.missingByDevice where count > 0 {
            missingByUser[deviceOwners[deviceId], default: 0] += count
        }
        for (userId, count) in missingByUser.sorted(by: { ($0.key ?? "") < ($1.key ?? "") }) {
            notices.append(.missing(senderName: userId.flatMap { members[$0]?.displayName }, count: count))
        }
        if !result.unsupported.isEmpty { notices.append(.unsupported(count: result.unsupported.count)) }
        return E2EEV2ThreadPresentation(messages: messages, notices: notices)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
