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
}

protocol NotificationsServicing: Sendable {
    func list(cursor: String?) async throws -> [AppNotification]
    func markRead(id: String) async throws
    func markAllRead() async throws
    func deleteAll() async throws
    func subscribePush(fcmToken: String) async throws
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

    func subscribePush(fcmToken: String) async throws {
        // `/api/push/subscribe` est l'endpoint Web Push navigateur (pas iOS). On
        // enregistre uniquement le token FCM, comme Android.
        let _: SuccessResponse = try await api.requestJSON(
            "/api/user/fcm-token",
            body: ["fcmToken": fcmToken]
        )
    }
}
