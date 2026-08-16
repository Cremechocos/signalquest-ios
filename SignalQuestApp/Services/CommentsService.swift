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
