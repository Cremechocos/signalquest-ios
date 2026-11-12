import Foundation

struct AppNotification: Codable, Identifiable, Equatable {
    // Le backend renvoie type/message/read/link (et NON kind/body/readAt/actionUrl)
    // → le décodage était cassé. `read` est un Bool, pas une date.
    let id: String
    let type: String?
    let title: String?
    let message: String?
    let createdAt: Date?
    let read: Bool?
    let link: String?
    let metadata: [String: JSONValue]?
    /// NOTIF-I18N (contrat Hors France r1, servi le 12/11) : clé stable et arguments
    /// typés, pour écrire le titre et le texte dans la langue de l'app.
    var textKey: String? = nil
    var textArgs: [String: JSONValue]? = nil

    /// Le texte du serveur, sauf quand l'app sait écrire la clé servie.
    var displayTitle: String? { NotificationTextKey(key: textKey, args: textArgs)?.title ?? title }
    var displayMessage: String? { NotificationTextKey(key: textKey, args: textArgs)?.message ?? message }

    init(
        id: String,
        type: String?,
        title: String?,
        message: String?,
        createdAt: Date?,
        read: Bool?,
        link: String?,
        metadata: [String: JSONValue]?,
        textKey: String? = nil,
        textArgs: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.read = read
        self.link = link
        self.metadata = metadata
        self.textKey = textKey
        self.textArgs = textArgs
    }

    // NOTIF-DECODE-01 : le backend sérialise `metadata` tantôt en OBJET JSON,
    // tantôt en CHAÎNE contenant du JSON (`"{\"bugId\":…}"`, colonnes texte).
    // Un décodage strict en objet faisait échouer TOUTE la liste (« Réponse
    // inattendue du serveur ») dès qu'une notification portait la variante
    // chaîne. On accepte les deux, et on ignore un JSON de chaîne invalide
    // plutôt que de casser la liste.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        // `try?` (et non `try`) : la stratégie de date JETTE sur une chaîne non
        // parsable (ex. ""), ce que decodeIfPresent n'avale pas → une seule notif
        // à date invalide faisait échouer toute la liste (ROB-03).
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        read = try c.decodeIfPresent(Bool.self, forKey: .read)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        if let object = try? c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) {
            metadata = object
        } else if let raw = try? c.decodeIfPresent(String.self, forKey: .metadata),
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            metadata = parsed
        } else {
            metadata = nil
        }
        // Une clé illisible ne fait pas tomber la notification : elle garde son texte.
        textKey = (try? c.decodeIfPresent(String.self, forKey: .textKey)) ?? nil
        textArgs = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .textArgs)) ?? nil
    }
}

/// Texte traduisible d'une notification (NOTIF-I18N, `contracts/notification-text-keys/v1.json`),
/// même mécanique que `FeedTextKey` : tout ou rien. Une clé inconnue, un argument
/// manquant, vide ou mal typé donnent `nil`, et la ligne garde `title`/`message`.
/// `actorName` est un nom de membre, jamais traduit ; le ton suit le réglage tu/vous.
struct NotificationTextKey: Equatable {
    let key: String
    private let args: [String: JSONValue]

    private enum Kind { case string, count }

    private static let catalog: [String: [String: Kind]] = [
        "notif.social.reaction_heart": ["actorName": .string],
        "notif.social.reaction_emoji": ["actorName": .string, "emoji": .string],
        "notif.social.reaction_group": ["actorName": .string, "otherCount": .count],
        "notif.social.comment": ["actorName": .string],
        "notif.social.comment_group": ["actorName": .string, "otherCount": .count],
        "notif.social.reply": ["actorName": .string],
        "notif.social.reply_group": ["actorName": .string, "otherCount": .count],
        "notif.social.repost": ["actorName": .string],
        "notif.social.repost_group": ["actorName": .string, "otherCount": .count],
        "notif.social.mention": ["actorName": .string],
        "notif.social.mention_group": ["actorName": .string, "otherCount": .count],
        "notif.social.follow": ["actorName": .string],
        "notif.progress.badge": ["badgeId": .string, "badgeName": .string],
        "notif.progress.level": ["newLevel": .count],
    ]

    /// Schéma au format du contrat (`string` / `integer`), pour le test qui le compare.
    static var contractArgs: [String: [String: String]] {
        catalog.mapValues { $0.mapValues { $0 == .count ? "integer" : "string" } }
    }

    init?(key: String?, args: [String: JSONValue]?) {
        guard let key, let schema = Self.catalog[key] else { return nil }
        let args = args ?? [:]
        for (name, kind) in schema {
            switch (kind, args[name]) {
            case (.string, .string(let text)?) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: continue
            case (.count, .number(let number)?) where number.isFinite && number >= 1 && number == number.rounded()
                && number <= 9_007_199_254_740_991: continue
            default: return nil
            }
        }
        self.key = key
        self.args = args
    }

    private func string(_ name: String) -> String {
        guard case .string(let text)? = args[name] else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func count(_ name: String) -> Int {
        guard case .number(let number)? = args[name] else { return 0 }
        return Int(clamping: Int64(number))
    }

    /// Titre fixe par clé dans la liste ; la variante `_group` garde celui de sa clé de base.
    var title: String {
        switch key {
        case "notif.social.reaction_heart", "notif.social.reaction_emoji", "notif.social.reaction_group":
            return String(localized: "Réaction à ta publication")
        case "notif.social.comment", "notif.social.comment_group": return String(localized: "Nouveau commentaire")
        case "notif.social.reply", "notif.social.reply_group": return String(localized: "Nouvelle réponse")
        case "notif.social.repost", "notif.social.repost_group": return String(localized: "Publication repartagée")
        case "notif.social.mention", "notif.social.mention_group": return String(localized: "Tu as été mentionné")
        case "notif.social.follow": return String(localized: "Nouvel abonné")
        case "notif.progress.badge": return String(localized: "Nouveau badge")
        case "notif.progress.level": return String(localized: "Niveau \(count("newLevel"))")
        default: return ""
        }
    }

    var message: String {
        let actor = string("actorName")
        let others = count("otherCount")
        switch key {
        case "notif.social.reaction_heart": return String(localized: "\(actor) a aimé ta publication.")
        case "notif.social.reaction_emoji": return String(localized: "\(actor) a réagi \(string("emoji")) à ta publication.")
        case "notif.social.reaction_group":
            return others == 1
                ? String(localized: "\(actor) et 1 autre personne ont réagi à ta publication.")
                : String(localized: "\(actor) et \(others) autres personnes ont réagi à ta publication.")
        case "notif.social.comment": return String(localized: "\(actor) a commenté ta publication.")
        case "notif.social.comment_group":
            return others == 1
                ? String(localized: "\(actor) et 1 autre personne ont commenté ta publication.")
                : String(localized: "\(actor) et \(others) autres personnes ont commenté ta publication.")
        case "notif.social.reply": return String(localized: "\(actor) a répondu à ton commentaire.")
        case "notif.social.reply_group":
            return others == 1
                ? String(localized: "\(actor) et 1 autre personne ont répondu à ton commentaire.")
                : String(localized: "\(actor) et \(others) autres personnes ont répondu à ton commentaire.")
        case "notif.social.repost": return String(localized: "\(actor) a repartagé ta publication.")
        case "notif.social.repost_group":
            return others == 1
                ? String(localized: "\(actor) et 1 autre personne ont repartagé ta publication.")
                : String(localized: "\(actor) et \(others) autres personnes ont repartagé ta publication.")
        case "notif.social.mention": return String(localized: "\(actor) t’a mentionné dans le réseau social.")
        case "notif.social.mention_group":
            return others == 1
                ? String(localized: "\(actor) et 1 autre personne t’ont mentionné.")
                : String(localized: "\(actor) et \(others) autres personnes t’ont mentionné.")
        case "notif.social.follow": return String(localized: "\(actor) suit maintenant ton profil public.")
        case "notif.progress.badge": return String(localized: "Badge « \(string("badgeName")) » obtenu.")
        case "notif.progress.level": return String(localized: "Tu passes au niveau \(count("newLevel")).")
        default: return ""
        }
    }
}

protocol NotificationsServicing: Sendable {
    func list(cursor: String?) async throws -> AppNotificationPage
    func markRead(id: String) async throws
    func markAllRead() async throws
    func delete(id: String) async throws
    func deleteAll() async throws
}

struct AppNotificationPage: Decodable {
    let notifications: [AppNotification]
    let nextCursor: String?
    let unreadCount: Int?

    init(notifications: [AppNotification], nextCursor: String?, unreadCount: Int?) {
        self.notifications = notifications
        self.nextCursor = nextCursor
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey { case notifications, items, nextCursor, unreadCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Une notification malformée est ignorée sans perdre les autres (ROB-03).
        if c.contains(.notifications) {
            notifications = c.decodeLossyElementArray([AppNotification].self, forKey: .notifications)
        } else if c.contains(.items) {
            notifications = c.decodeLossyElementArray([AppNotification].self, forKey: .items)
        } else {
            notifications = []
        }
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount)
    }
}

final class NotificationsService: NotificationsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list(cursor: String? = nil) async throws -> AppNotificationPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/notifications", query: query),
            as: AppNotificationPage.self
        )
    }

    func markRead(id: String) async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/notifications/\(id)/read", method: .post),
            as: SuccessResponse.self
        )
    }

    func markAllRead() async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/notifications/read-all", method: .post),
            as: SuccessResponse.self
        )
    }

    func delete(id: String) async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/notifications/\(id)", method: .delete),
            as: SuccessResponse.self
        )
    }

    func deleteAll() async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/notifications/delete-all", method: .post),
            as: SuccessResponse.self
        )
    }

}
