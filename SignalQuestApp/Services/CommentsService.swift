import Foundation

protocol CommentsServicing: Sendable {
    func list(postId: String, cursor: String?) async throws -> SocialCommentsResponse
    func add(postId: String, text: String, parentId: String?) async throws -> SocialComment
    /// Les réponses d'un commentaire, chargées À LA DEMANDE.
    ///
    /// Pas avec le fil : une panne discutée porte vite des dizaines de réponses, et les descendre
    /// toutes pour n'en montrer aucune ferait payer à chacun la conversation des autres.
    func replies(postId: String, commentId: String, cursor: String?) async throws -> SocialCommentsResponse
    /// Like ❤️ d'un commentaire (idempotent). Renvoie l'état final `{ liked, count }`.
    func like(postId: String, commentId: String) async throws -> CommentReactionResponse
    /// Retire le like ❤️ d'un commentaire (idempotent).
    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse
    /// Supprime son propre commentaire (App Store, règle 1.2) : 403 pour celui
    /// d'un autre, 404 s'il n'existe plus.
    func delete(postId: String, commentId: String) async throws
}

extension CommentsServicing {
    /// Les doubles de test et de démonstration n'ont rien à supprimer.
    func delete(postId: String, commentId: String) async throws {}
}

final class CommentsService: CommentsServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Le feed unifié préfixe les ids de posts ("post-…") ; les routes de
    /// commentaires attendent l'id brut.
    private func normalizedPostId(_ raw: String) -> String {
        raw.hasPrefix("post-") ? String(raw.dropFirst("post-".count)) : raw
    }

    func list(postId: String, cursor: String? = nil) async throws -> SocialCommentsResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))/comments", query: query),
            as: SocialCommentsResponse.self
        )
    }

    func replies(
        postId: String,
        commentId: String,
        cursor: String? = nil
    ) async throws -> SocialCommentsResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "20")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/replies",
                query: query
            ),
            as: SocialCommentsResponse.self
        )
    }

    func add(postId: String, text: String, parentId: String? = nil) async throws -> SocialComment {
        let response: CreateCommentResponse = try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/comments",
            body: CreateCommentRequest(text: text, parentId: parentId)
        )
        return response.comment
    }

    /// `POST .../comments/{commentId}/reactions` avec `{ emoji: "❤️" }` (même
    /// convention que les réactions de post). Le backend borne l'emoji à ❤️.
    func like(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/reactions",
            body: ["emoji": "❤️"]
        )
    }

    /// `DELETE .../comments/{commentId}` → `{ deleted: true, commentId }`
    /// (suppression douce côté serveur, auteur seulement ; SOC-12).
    func delete(postId: String, commentId: String) async throws {
        try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)",
                method: .delete
            )
        )
    }

    /// `DELETE .../comments/{commentId}/reactions` (retire le ❤️, sans corps).
    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/reactions",
                method: .delete
            ),
            as: CommentReactionResponse.self
        )
    }

}

// MARK: - Fil d'un site (SITE-1)

/// Ce qu'on publie dans le fil d'un site : une remarque, ou une demande d'aide qui joint l'état
/// radio de l'appareil.
enum SiteCommentKind: String, Codable, Sendable {
    case comment, help
}

/// L'état radio joint à une demande d'aide, aux noms du serveur, jamais de position.
///
/// iOS n'en remplit que la technologie : le reste (bande, PCI, RSRP…) n'est pas lisible sur
/// iPhone. Les autres champs servent à afficher ce qu'Android ou le web ont joint.
struct SiteCommentRadio: Codable, Equatable, Sendable {
    var technology: String?
    var band: String?
    var arfcn: Int?
    var pci: Int?
    var cellId: String?
    var tac: Int?
    var rsrp: Double?
    var rsrq: Double?
    var sinr: Double?
    var timingAdvance: Int?

    /// La technologie au format du serveur (« 2G » à « 5G ») : NSA et SA y sont la même 5G.
    static func coarse(_ technology: CellularRadioTechnology?) -> SiteCommentRadio? {
        switch technology {
        case .twoG: return SiteCommentRadio(technology: "2G")
        case .threeG: return SiteCommentRadio(technology: "3G")
        case .fourG: return SiteCommentRadio(technology: "4G")
        case .fiveGNSA, .fiveGSA: return SiteCommentRadio(technology: "5G")
        case nil: return nil
        }
    }

    /// « 4G · B3 · PCI 214 · −98 dBm », dans l'ordre où on lit une cellule.
    var summary: String {
        var parts: [String] = []
        if let technology { parts.append(technology) }
        if let band { parts.append(band.uppercased()) }
        if let pci { parts.append("PCI \(pci)") }
        if let rsrp { parts.append(String(localized: "\(Int(rsrp.rounded())) dBm")) }
        if let sinr { parts.append(String(localized: "SINR \(Int(sinr.rounded())) dB")) }
        return parts.joined(separator: " · ")
    }
}

struct SiteComment: Decodable, Identifiable, Equatable {
    let id: String
    let kind: SiteCommentKind
    let text: String
    let createdAt: Date?
    let radio: SiteCommentRadio?
    let author: SocialFeedAuthor
    let own: Bool
    let canDelete: Bool
}

struct SiteThreadSummary: Decodable, Equatable {
    let commentCount: Int
}

struct SiteCommentsPage: Decodable {
    let thread: SiteThreadSummary
    let comments: [SiteComment]
    let nextCursor: String?
}

private struct SiteCommentCreateRequest: Encodable {
    let market: String
    let `operator`: String
    let siteId: String
    let kind: SiteCommentKind
    let text: String
    let radio: SiteCommentRadio?
}

private struct SiteCommentCreateResponse: Decodable {
    let comment: SiteComment
}

protocol SiteCommentsServicing: Sendable {
    /// Le fil d'un site pour un opérateur, du plus récent au plus ancien. Lecture ouverte à tous.
    func list(market: String, operatorKey: String, siteId: String, cursor: String?) async throws -> SiteCommentsPage
    func add(market: String, operatorKey: String, siteId: String, kind: SiteCommentKind, text: String, radio: SiteCommentRadio?) async throws -> SiteComment
    /// Ses propres messages seulement.
    func delete(id: String) async throws
}

final class SiteCommentsService: SiteCommentsServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// La clé du fil passe en query string : certains identifiants de site contiennent « : ».
    func list(market: String, operatorKey: String, siteId: String, cursor: String? = nil) async throws -> SiteCommentsPage {
        if AppEnvironment.usesDemoData { return Self.demoPage }
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorKey),
            URLQueryItem(name: "siteId", value: siteId),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/site-threads/comments", query: query),
            as: SiteCommentsPage.self
        )
    }

    func add(market: String, operatorKey: String, siteId: String, kind: SiteCommentKind, text: String, radio: SiteCommentRadio?) async throws -> SiteComment {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return SiteComment(
                id: UUID().uuidString, kind: kind, text: text, createdAt: Date(), radio: radio,
                author: SocialFeedAuthor(id: "demo-me", name: "Alex", handle: "alex", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: true, canDelete: true
            )
        }
        let response: SiteCommentCreateResponse = try await api.requestJSON(
            "/api/site-threads/comments",
            body: SiteCommentCreateRequest(market: market, operator: operatorKey, siteId: siteId,
                                           kind: kind, text: text, radio: kind == .help ? radio : nil)
        )
        return response.comment
    }

    func delete(id: String) async throws {
        if AppEnvironment.usesDemoData { return }
        try await api.request(APIEndpoint(path: "/api/site-threads/comments/\(id)", method: .delete))
    }

    private static var demoPage: SiteCommentsPage { SiteCommentsPage(
        thread: SiteThreadSummary(commentCount: 2),
        comments: [
            SiteComment(
                id: "demo-site-comment-2", kind: .help,
                text: "Débit très faible ce soir au pied du pylône, quelqu'un d'autre ?",
                createdAt: Date().addingTimeInterval(-3_600),
                radio: SiteCommentRadio(technology: "4G", band: "b3", pci: 214, rsrp: -98),
                author: SocialFeedAuthor(id: "demo-camille", name: "Camille", handle: "camille", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: false, canDelete: false
            ),
            SiteComment(
                id: "demo-site-comment-1", kind: .comment,
                text: "La 5G est active sur ce site depuis lundi, 700 Mbit/s mesurés au centre-ville.",
                createdAt: Date().addingTimeInterval(-86_400 * 2),
                radio: nil,
                author: SocialFeedAuthor(id: "demo-yanis", name: "Yanis", handle: "yanis", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: false, canDelete: false
            ),
        ],
        nextCursor: nil
    ) }
}
