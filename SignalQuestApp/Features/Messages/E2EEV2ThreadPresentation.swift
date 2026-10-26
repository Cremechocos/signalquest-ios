import Foundation

/// Ce que le fil montre d'une conversation v2 (§4.2, §4.3, §5) : les messages
/// du magasin v2 sous la forme commune `MessageItem`, et les avis à poser dans
/// le fil. Rien ici ne touche au réseau ni aux clés : la relève et la
/// vérification sont faites avant, par la messagerie v2.
struct E2EEV2ThreadPresentation: Equatable {
    enum Notice: Equatable {
        /// Un membre a un nouveau numéro de sécurité : rien ne lui est envoyé
        /// tant que l'utilisateur ne l'a pas vu (§2.4). L'avis mène à son numéro.
        case identityChanged(userId: String, name: String?)
        /// Le paquet de confiance d'un membre est refusé (liste en recul,
        /// lacune, signature invalide) : rien ne lui est envoyé non plus.
        case identityUnverified(userId: String, name: String?)
        /// Deux versions d'un même message : aucune n'est affichée (§4.2).
        case equivocation(count: Int)
        /// Des messages d'un membre n'ont pas été reçus (§4.3).
        case missing(senderName: String?, count: Int)
        /// Messages d'une version plus récente de l'app (§5.2).
        case unsupported(count: Int)
        /// L'appareil n'a pas encore la clé de l'époque courante (§3.2).
        case waitingForEpoch
        /// Un manifeste cite un appareil que le journal des appareils refuse
        /// (E2EE-AUTO §7.1) : la conversation passe à une nouvelle clé sans lui.
        case deviceRefused(userId: String, name: String?)
        /// Une clé de la conversation n'a pas pu être vérifiée (époque non
        /// marquée après une époque marquée, §7.2) : elle est remplacée.
        case keyUnverified
        /// Un appareil a été ajouté chez un membre (E2EE-AUTO §3.5), dans les 7 derniers jours.
        case devicesChanged(userId: String, name: String?)

        var text: String {
            switch self {
            case .identityChanged(_, let name?):
                return String(localized: "\(name) a un nouveau numéro de sécurité. Rien ne lui est envoyé tant que tu ne l’as pas vu.")
            case .identityChanged(_, nil):
                return String(localized: "Un membre a un nouveau numéro de sécurité. Rien ne lui est envoyé tant que tu ne l’as pas vu.")
            case .identityUnverified(_, let name?):
                return String(localized: "Le chiffrement avec \(name) n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
            case .identityUnverified(_, nil):
                return String(localized: "Le chiffrement avec un membre n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
            case .equivocation:
                return String(localized: "Un message est arrivé en deux versions différentes : aucune n’est affichée.")
            case .missing(let name?, _):
                return String(localized: "Des messages envoyés par \(name) n’ont pas été reçus.")
            case .missing(nil, _):
                return String(localized: "Des messages n’ont pas été reçus.")
            case .unsupported:
                return String(localized: "Un message demande une version plus récente de SignalQuest.")
            case .waitingForEpoch:
                return String(localized: "En attente de la clé de cette conversation chiffrée.")
            case .deviceRefused(_, let name?):
                return String(localized: "Un appareil de \(name) ne figure pas tel quel dans le journal des appareils : la conversation passe à une nouvelle clé sans lui.")
            case .deviceRefused(_, nil):
                return String(localized: "Un appareil d’un membre ne figure pas tel quel dans le journal des appareils : la conversation passe à une nouvelle clé sans lui.")
            case .keyUnverified:
                return String(localized: "Une clé de cette conversation n’a pas pu être vérifiée : elle est remplacée par une nouvelle.")
            case .devicesChanged(_, let name?):
                return String(localized: "Les appareils de \(name) ont changé.")
            case .devicesChanged(_, nil):
                return String(localized: "Les appareils d’un membre ont changé.")
            }
        }
    }

    let messages: [MessageItem]
    let notices: [Notice]
    /// Enveloppe du dernier message d'un autre membre : de quoi accuser « distribué »
    /// depuis le fil (U05), sans toucher à `MessageItem` dont l'identifiant est le `messageRef`.
    var lastIncomingEnvelopeId: String? = nil
    /// Identifiants de requête des messages déjà acceptés : une bulle locale « non envoyé »
    /// qui y figure est déjà partie (B02).
    var clientRequestIds: Set<String> = []
    /// Des messages plus anciens existent dans le magasin local mais ne sont pas présentés.
    var hasOlder: Bool = false
    /// Tous les appareils des membres lisent les réactions chiffrées (D.16) :
    /// sinon ni bouton ni double tap, jamais de repli en clair.
    var reactionsAvailable = false
}

/// Taille de la fenêtre du fil v2 : les derniers messages d'abord, puis des pages de même taille.
enum E2EEV2ThreadWindow {
    static let pageSize = 200
}

enum E2EEV2ThreadPresenter {
    /// Durée de la ligne « les appareils de X ont changé ».
    static let deviceChangeWindowMs: Int64 = 7 * 24 * 3_600_000

    /// `members` : nom et avatar par utilisateur ; `deviceOwners` : l'utilisateur
    /// de chaque appareil certifié, pour nommer qui a des messages manquants ;
    /// `refusals` : les membres dont l'annuaire n'a pas cru l'identité, en tête
    /// des avis puisque l'envoi les attend.
    static func present(
        _ result: E2EEV2MessagesV2,
        conversationId: String,
        members: [String: MessageUser],
        deviceOwners: [String: String],
        refusals: [String: E2EEV2IdentityVerification.Failure] = [:],
        ownUserId: String? = nil,
        limit: Int? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2ThreadPresentation {
        // Le magasin garde jusqu'à des milliers de messages : seuls les derniers deviennent des
        // `MessageItem`, les précédents se présentent par pages (P03).
        let shown = limit.map { Array(result.snapshot.messages.suffix($0)) } ?? result.snapshot.messages
        let messages = shown.map { stored in
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
                reactions: result.snapshot.reactions[stored.messageRef]?.map {
                    MessageReaction(emoji: $0.emoji, userId: $0.userId)
                } ?? []
            )
        }
        var notices: [E2EEV2ThreadPresentation.Notice] = refusals.keys.sorted().map { userId in
            let name = members[userId]?.displayName
            return refusals[userId] == .uikChanged
                ? .identityChanged(userId: userId, name: name)
                : .identityUnverified(userId: userId, name: name)
        }
        // Une ligne par appareil refusé, la plus récente gardée.
        var refusedDevices = Set<String>()
        for alert in result.securityAlerts.reversed() {
            if alert.code == "UNMARKED_EPOCH" {
                if !notices.contains(.keyUnverified) { notices.append(.keyUnverified) }
            } else if refusedDevices.insert(alert.userId + "\n" + alert.deviceId).inserted {
                notices.append(.deviceRefused(userId: alert.userId, name: members[alert.userId]?.displayName))
            }
        }
        for change in result.deviceChanges.reversed()
        where change.userId != ownUserId && nowMs - change.atMs < deviceChangeWindowMs {
            notices.append(.devicesChanged(userId: change.userId, name: members[change.userId]?.displayName))
        }
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
        let lastIncoming = ownUserId.flatMap { own in
            result.snapshot.messages.last { $0.senderUserId != own && !$0.deleted }?.envelopeId
        }
        return E2EEV2ThreadPresentation(
            messages: messages, notices: notices,
            lastIncomingEnvelopeId: lastIncoming,
            clientRequestIds: Set(result.snapshot.messages.map(\.clientRequestId)),
            hasOlder: shown.count < result.snapshot.messages.count
        )
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
