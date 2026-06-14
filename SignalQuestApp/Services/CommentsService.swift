import Foundation

protocol CommentsServicing: Sendable {
    func list(postId: String, cursor: String?) async throws -> SocialCommentsResponse
    func add(postId: String, text: String, parentId: String?) async throws -> SocialComment
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

    func add(postId: String, text: String, parentId: String? = nil) async throws -> SocialComment {
        let response: CreateCommentResponse = try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/comments",
            body: CreateCommentRequest(text: text, parentId: parentId)
        )
        return response.comment
    }

}
