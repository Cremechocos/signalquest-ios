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

    init(
        id: String,
        type: String?,
        title: String?,
        message: String?,
        createdAt: Date?,
        read: Bool?,
        link: String?,
        metadata: [String: JSONValue]?
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.read = read
        self.link = link
        self.metadata = metadata
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
    }
}

protocol NotificationsServicing: Sendable {
    func list(cursor: String?) async throws -> AppNotificationPage
    func markRead(id: String) async throws
    func markAllRead() async throws
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

    func deleteAll() async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/notifications/delete-all", method: .post),
            as: SuccessResponse.self
        )
    }

}
