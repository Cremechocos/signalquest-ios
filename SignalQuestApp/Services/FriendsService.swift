import Foundation

struct FriendPresence: Codable, Equatable {
    let status: String?
    let customStatus: String?
    let lastSeenAt: Date?
    let isOnline: Bool?
    let hasActiveSession: Bool?
}

struct Friend: Codable, Identifiable, Equatable {
    let friendshipId: String
    let userId: String
    let name: String?
    let email: String?
    let handle: String?
    let avatarUrl: URL?
    let since: Date?
    let presence: FriendPresence?

    var id: String { friendshipId }
    var displayName: String { name ?? handle.map { "@\($0)" } ?? (email?.components(separatedBy: "@").first ?? "Ami") }
}

struct FriendRequestUser: Codable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?
    var displayName: String { name ?? handle.map { "@\($0)" } ?? "Utilisateur" }
}

struct FriendRequest: Codable, Identifiable, Equatable {
    let id: String
    let status: String?
    /// Le backend renvoie `sender`/`receiver` (et NON `user`/`direction`).
    let sender: FriendRequestUser?
    let receiver: FriendRequestUser?
    let createdAt: Date?
    /// Personne à afficher pour une demande REÇUE = l'expéditeur.
    var user: FriendRequestUser? { sender ?? receiver }
}

struct BlockedUser: Codable, Identifiable, Equatable {
    let userId: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?
    let blockedAt: Date?
    var id: String { userId }
    var displayName: String { name ?? handle.map { "@\($0)" } ?? "Utilisateur" }
}

protocol FriendsServicing: Sendable {
    func list() async throws -> [Friend]
    func requests() async throws -> [FriendRequest]
    func sendRequest(toUserId: String) async throws
    func accept(requestId: String) async throws
    func decline(requestId: String) async throws
    func remove(userId: String) async throws
    func block(userId: String) async throws
    func blocks() async throws -> [BlockedUser]
}

final class FriendsService: FriendsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list() async throws -> [Friend] {
        struct Response: Codable { let friends: [Friend]?; let items: [Friend]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/friends"), as: Response.self)
        return r.friends ?? r.items ?? []
    }

    func requests() async throws -> [FriendRequest] {
        // Le backend renvoie { received, sent } (et NON { requests/items }).
        // L'UI traite les demandes REÇUES (accepter/refuser).
        struct Response: Codable { let received: [FriendRequest]?; let sent: [FriendRequest]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/friends/requests"), as: Response.self)
        return r.received ?? []
    }

    func sendRequest(toUserId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/friends/requests", body: ["userId": toUserId])
    }

    func accept(requestId: String) async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/friends/requests/\(requestId)/accept", method: .post),
            as: SuccessResponse.self
        )
    }

    func decline(requestId: String) async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/friends/requests/\(requestId)/decline", method: .post),
            as: SuccessResponse.self
        )
    }

    func remove(userId: String) async throws {
        // Le backend attend ?userId=<id de l'AMI> (et NON ?id=<friendshipId>).
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/friends", method: .delete,
                        query: [URLQueryItem(name: "userId", value: userId)]),
            as: SuccessResponse.self
        )
    }

    func block(userId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/friends/block", body: ["userId": userId])
    }

    func blocks() async throws -> [BlockedUser] {
        struct Response: Codable { let blocks: [BlockedUser]?; let items: [BlockedUser]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/users/blocks"), as: Response.self)
        return r.blocks ?? r.items ?? []
    }
}
