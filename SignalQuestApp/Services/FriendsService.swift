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
    /// Personne à afficher pour une demande ENVOYÉE = le destinataire. Utiliser
    /// `user` pour une demande envoyée afficherait l'utilisateur courant.
    var recipient: FriendRequestUser? { receiver ?? sender }
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
    func requests() async throws -> FriendRequests
    func sendRequest(toUserId: String) async throws
    func accept(requestId: String) async throws
    func decline(requestId: String) async throws
    func cancelRequest(requestId: String) async throws
    func remove(userId: String) async throws
    func block(userId: String) async throws
    func unblock(userId: String) async throws
    func blocks() async throws -> [BlockedUser]
}

/// Les deux sens d'une demande d'ami.
///
/// `sent` était auparavant décodé puis **jeté** (`return r.received ?? []`) :
/// l'utilisateur ne voyait pas ses demandes en attente et ne pouvait pas les
/// annuler, alors que le backend les renvoie et expose la route de suppression.
struct FriendRequests: Equatable, Sendable {
    let received: [FriendRequest]
    let sent: [FriendRequest]

    static let empty = FriendRequests(received: [], sent: [])
    var isEmpty: Bool { received.isEmpty && sent.isEmpty }
}

final class FriendsService: FriendsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list() async throws -> [Friend] {
        struct Response: Decodable {
            let friends: [Friend]?
            let items: [Friend]?
            enum CodingKeys: String, CodingKey { case friends, items }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Un ami à avatarUrl malformée est ignoré au lieu de casser la liste (ROB-04).
                friends = c.contains(.friends) ? c.decodeLossyElementArray([Friend].self, forKey: .friends) : nil
                items = c.contains(.items) ? c.decodeLossyElementArray([Friend].self, forKey: .items) : nil
            }
        }
        let r: Response = try await api.request(APIEndpoint(path: "/api/friends"), as: Response.self)
        return r.friends ?? r.items ?? []
    }

    func requests() async throws -> FriendRequests {
        // Le backend renvoie { received, sent } (et NON { requests/items }).
        struct Response: Decodable {
            let received: [FriendRequest]
            let sent: [FriendRequest]
            enum CodingKeys: String, CodingKey { case received, sent }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Une demande à avatar malformé est ignorée au lieu de casser la
                // liste entière (même politique que `list()`).
                received = c.decodeLossyArray([FriendRequest].self, forKey: .received)
                sent = c.decodeLossyArray([FriendRequest].self, forKey: .sent)
            }
        }
        let r: Response = try await api.request(APIEndpoint(path: "/api/friends/requests"), as: Response.self)
        return FriendRequests(received: r.received, sent: r.sent)
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

    /// Annule une demande que J'AI envoyée (l'accepter/refuser concerne celles
    /// que je reçois). L'identifiant est porté par le chemin.
    func cancelRequest(requestId: String) async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/friends/requests/\(requestId)", method: .delete),
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
        let _: SuccessResponse = try await api.requestJSON("/api/users/blocks", body: ["userId": userId])
    }

    /// Sans cette route, un blocage était **irréversible depuis l'app** : un
    /// cul-de-sac que la revue App Store regarde, et un défaut de contrôle de
    /// l'utilisateur sur ses propres données. Le backend lit `userId` dans le
    /// CORPS de la requête DELETE, pas en paramètre d'URL.
    func unblock(userId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/users/blocks",
            method: .delete,
            body: ["userId": userId]
        )
    }

    func blocks() async throws -> [BlockedUser] {
        struct Response: Codable { let blocks: [BlockedUser]?; let items: [BlockedUser]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/users/blocks"), as: Response.self)
        return r.blocks ?? r.items ?? []
    }
}
