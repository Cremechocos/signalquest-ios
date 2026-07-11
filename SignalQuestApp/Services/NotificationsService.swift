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
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
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
    func list(cursor: String?) async throws -> [AppNotification]
    func markRead(id: String) async throws
    func markAllRead() async throws
    func deleteAll() async throws
}

final class NotificationsService: NotificationsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list(cursor: String? = nil) async throws -> [AppNotification] {
        struct Response: Codable {
            let notifications: [AppNotification]?
            let items: [AppNotification]?
        }
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let r: Response = try await api.request(
            APIEndpoint(path: "/api/notifications", query: query),
            as: Response.self
        )
        return r.notifications ?? r.items ?? []
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
