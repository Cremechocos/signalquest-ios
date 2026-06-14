import Foundation

protocol SocialFeedServicing: Sendable {
    func loadFeed(cursor: String?, hashtag: String?) async throws -> SocialFeedPage
    /// Récupère un post unique (deep-link / notification) par son identifiant.
    func post(id: String) async throws -> UnifiedSocialFeedItem?
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?
    ) async throws -> UnifiedSocialFeedItem?
    func uploadImage(data: Data, mimeType: String) async throws -> CreatePostAttachment
    func react(postId: String, emoji: String) async throws -> ReactionResponse
    func favorite(postId: String) async throws -> ReactionResponse
    func repost(postId: String) async throws -> ReactionResponse
    func muteNotifications(postId: String) async throws -> SuccessResponse
    func share(postId: String, conversationId: String) async throws -> SuccessResponse

    // MARK: Réseau social (profils, follow, exploration)

    func userProfile(userId: String) async throws -> SocialUserProfile
    /// La route backend est un toggle unique (POST /api/social/follows/[userId]) :
    /// le même appel suit ou désabonne selon l'état courant.
    func toggleFollow(userId: String) async throws -> SocialFollowResult
    /// Posts d'un utilisateur. `mine` bascule sur filter=mine (pagination native) ;
    /// sinon le flux public est balayé côté client (pas de route auteur backend).
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage
    func trendingHashtags() async throws -> [TrendingHashtag]
    func suggestedUsers() async throws -> [SocialFeedAuthor]
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult]
    /// Dernier speedtest sauvegardé côté backend (pour l'attacher à un post).
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest?
}

extension SocialFeedServicing {
    /// Surcharge de compatibilité — post simple sans cible télécom.
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment]
    ) async throws -> UnifiedSocialFeedItem? {
        try await createPost(
            text: text,
            visibility: visibility,
            attachments: attachments,
            targetType: nil,
            targetId: nil,
            extraMetadata: nil
        )
    }
}

final class SocialFeedService: SocialFeedServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Le feed unifié renvoie des ids préfixés ("post-…") alors que les routes
    /// d'action (/api/social/posts/[id]/…) attendent l'id brut.
    private func normalizedPostId(_ raw: String) -> String {
        raw.hasPrefix("post-") ? String(raw.dropFirst("post-".count)) : raw
    }

    func loadFeed(cursor: String? = nil, hashtag: String? = nil) async throws -> SocialFeedPage {
        var query = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "filter", value: "all"),
            URLQueryItem(name: "ranking", value: "smart"),
            URLQueryItem(name: "include", value: "items,stories,trends,suggestions")
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let hashtag, !hashtag.isEmpty { query.append(URLQueryItem(name: "hashtag", value: hashtag)) }
        return try await api.request(APIEndpoint(path: "/api/social/feed", query: query), as: SocialFeedPage.self)
    }

    func post(id: String) async throws -> UnifiedSocialFeedItem? {
        struct SinglePostResponse: Decodable { let item: UnifiedSocialFeedItem? }
        let response: SinglePostResponse = try await api.request(
            APIEndpoint(path: "/api/social/posts/\(normalizedPostId(id))"),
            as: SinglePostResponse.self
        )
        return response.item
    }

    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?
    ) async throws -> UnifiedSocialFeedItem? {
        var metadata: [String: JSONValue] = ["platform": .string("ios")]
        if let extraMetadata {
            for (key, value) in extraMetadata { metadata[key] = value }
        }
        let request = CreatePostRequest(
            text: text,
            visibility: visibility,
            targetType: targetType,
            targetId: targetId,
            placeLabel: nil,
            latitude: nil,
            longitude: nil,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments,
            attachRadio: false
        )
        let response: CreatePostResponse = try await api.requestJSON("/api/social/v2/posts", body: request)
        return response.post
    }

    func uploadImage(data: Data, mimeType: String = "image/jpeg") async throws -> CreatePostAttachment {
        let response: SocialUploadResponse = try await api.uploadMultipart(
            path: "/api/social/uploads",
            fields: ["platform": "ios"],
            fileField: "file",
            fileName: "signalquest-social-\(UUID().uuidString).jpg",
            mimeType: mimeType,
            data: data,
            as: SocialUploadResponse.self
        )
        return response.upload
    }

    func react(postId: String, emoji: String = "❤️") async throws -> ReactionResponse {
        try await api.requestJSON("/api/social/posts/\(normalizedPostId(postId))/reactions", body: ["emoji": emoji])
    }

    func favorite(postId: String) async throws -> ReactionResponse {
        try await api.request(APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))/favorite", method: .post), as: ReactionResponse.self)
    }

    func repost(postId: String) async throws -> ReactionResponse {
        try await api.request(APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))/repost", method: .post), as: ReactionResponse.self)
    }

    func muteNotifications(postId: String) async throws -> SuccessResponse {
        try await api.request(APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))/notifications", method: .post), as: SuccessResponse.self)
    }

    func share(postId: String, conversationId: String) async throws -> SuccessResponse {
        try await api.requestJSON("/api/social/posts/\(normalizedPostId(postId))/share", body: ["conversationId": conversationId])
    }

    // MARK: - Profils & follow

    func userProfile(userId: String) async throws -> SocialUserProfile {
        let response: SocialUserProfileResponse = try await api.request(
            APIEndpoint(path: "/api/users/\(userId)/profile"),
            as: SocialUserProfileResponse.self
        )
        return response.profile
    }

    func toggleFollow(userId: String) async throws -> SocialFollowResult {
        try await api.request(
            APIEndpoint(path: "/api/social/follows/\(userId)", method: .post),
            as: SocialFollowResult.self
        )
    }

    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage {
        if mine {
            // filter=mine : pagination cursor native côté backend.
            var query = [
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "filter", value: "mine"),
                URLQueryItem(name: "ranking", value: "latest"),
                URLQueryItem(name: "include", value: "items")
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            return try await api.request(APIEndpoint(path: "/api/social/feed", query: query), as: SocialFeedPage.self)
        }

        // Pas de route "posts d'un auteur" côté backend : on balaie le flux
        // public récent (ranking=latest) et on filtre côté client, en suivant
        // quelques curseurs pour remplir la page.
        var collected: [UnifiedSocialFeedItem] = []
        var nextCursor = cursor
        var scannedPages = 0
        let maxScannedPages = 4
        let targetCount = 10

        repeat {
            var query = [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "filter", value: "all"),
                URLQueryItem(name: "ranking", value: "latest"),
                URLQueryItem(name: "include", value: "items")
            ]
            if let nextCursorValue = nextCursor {
                query.append(URLQueryItem(name: "cursor", value: nextCursorValue))
            }
            let page = try await api.request(APIEndpoint(path: "/api/social/feed", query: query), as: SocialFeedPage.self)
            collected.append(contentsOf: page.items.filter { $0.author.id == userId })
            nextCursor = page.nextCursor
            scannedPages += 1
        } while nextCursor != nil && collected.count < targetCount && scannedPages < maxScannedPages

        return SocialFeedPage(
            items: collected,
            nextCursor: nextCursor,
            stories: [],
            trendingHashtags: [],
            suggestedUsers: [],
            requestId: nil
        )
    }

    // MARK: - Exploration

    func trendingHashtags() async throws -> [TrendingHashtag] {
        let query = [
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include", value: "trends")
        ]
        let page = try await api.request(APIEndpoint(path: "/api/social/feed", query: query), as: SocialFeedPage.self)
        return page.trendingHashtags
    }

    func suggestedUsers() async throws -> [SocialFeedAuthor] {
        let query = [
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include", value: "suggestions")
        ]
        let page = try await api.request(APIEndpoint(path: "/api/social/feed", query: query), as: SocialFeedPage.self)
        return page.suggestedUsers
    }

    func searchUsers(query: String, limit: Int = 10) async throws -> [SocialUserSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await api.request(
            APIEndpoint(path: "/api/users/search", query: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "limit", value: String(limit))
            ]),
            as: [SocialUserSearchResult].self
        )
    }

    // MARK: - Speedtest joignable au composer

    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? {
        let response: UserSpeedtestsResponse = try await api.request(
            APIEndpoint(path: "/api/user/speedtests", query: [
                URLQueryItem(name: "period", value: "all"),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "page", value: "1")
            ]),
            as: UserSpeedtestsResponse.self
        )
        return response.speedtests.first
    }
}
