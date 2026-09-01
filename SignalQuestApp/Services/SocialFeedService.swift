import CryptoKit
import Foundation

protocol SocialFeedServicing: Sendable {
    func loadFeed(cursor: String?, hashtag: String?, tab: FeedTab?) async throws -> SocialFeedPage
    /// Récupère un post unique (deep-link / notification) par son identifiant.
    func post(id: String) async throws -> UnifiedSocialFeedItem?
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem?
    func uploadImage(data: Data, mimeType: String) async throws -> CreatePostAttachment
    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem?
    func retryPendingPosts() async
    func react(postId: String, emoji: String) async throws -> ReactionResponse
    func favorite(postId: String) async throws -> ReactionResponse
    func repost(postId: String) async throws -> ReactionResponse
    func muteNotifications(postId: String) async throws -> SuccessResponse
    /// Édite un post dont on est l'auteur. Le serveur vérifie la propriété et
    /// répond 403 sinon — on ne s'appuie donc pas sur le seul masquage de l'UI.
    func editPost(postId: String, text: String, visibility: String?) async throws -> UnifiedSocialFeedItem?
    /// Suppression définitive. Irréversible côté serveur.
    func deletePost(postId: String) async throws
    /// Épingle ou détache un post sur son profil. Le serveur ne garde qu'un seul
    /// post épinglé par auteur : épingler ailleurs détache automatiquement.
    func setPinned(postId: String, pinned: Bool) async throws
    /// Vote (ou retire son vote) sur le sondage d'une publication.
    /// `optionId == nil` retire tous les votes de l'utilisateur.
    func votePoll(postId: String, optionId: String?, removing: Bool) async throws -> FeedPoll?
    /// Hashtags suivis par l'utilisateur.
    func followedHashtags() async throws -> [FollowedHashtag]
    /// Suit ou arrête de suivre un hashtag.
    func setHashtagFollowed(_ tag: String, following: Bool) async throws
    /// Inventaire des masquages (hashtags + mots) en un appel.
    func mutes() async throws -> SocialMutes
    /// Masque ou démasque un hashtag.
    func setHashtagMuted(_ tag: String, muted: Bool) async throws
    /// Masque ou démasque un mot-clé.
    func setWordMuted(_ pattern: String, muted: Bool) async throws
    /// Exploration unifiée : publications, personnes et hashtags en UN appel.
    /// iOS n'interrogeait que les utilisateurs, et la recherche de publications
    /// n'existait pas.
    func explore(query: String?) async throws -> SocialExploreResult
    /// Bilan hebdomadaire de l'utilisateur (mis en cache 5 min côté serveur).
    func weeklyRecap() async throws -> WeeklyRecapStats?
    /// Publie le bilan sous forme de story. Idempotent sur la semaine : le
    /// serveur renvoie la story existante plutôt que d'en créer une seconde.
    func publishWeeklyRecap() async throws -> WeeklyRecapPublishResponse
    /// Partage un post vers une conversation. Renvoie l'id du message créé (pour
    /// permettre l'annulation), ou nil si le backend ne l'a pas fourni.
    func share(postId: String, conversationId: String) async throws -> String?

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
    /// Pouls réseau autour d'une position : `GET /api/social/network-pulse`.
    /// `radiusMeters` optionnel (défaut backend 3 km si nil/≤0).
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int?) async throws -> NetworkPulse
    /// Derniers speedtests communautaires HORODATÉS dans un rayon, triés par date
    /// (décroissante) côté serveur : `GET /api/social/nearby-speedtests`.
    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker]
}

extension SocialFeedServicing {
    func retryPendingPosts() async {}

    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? {
        var attachments: [CreatePostAttachment] = []
        if let imageData {
            attachments.append(try await uploadImage(data: imageData, mimeType: imageMimeType))
        }
        return try await createPost(
            text: text,
            visibility: visibility,
            attachments: attachments,
            targetType: targetType,
            targetId: targetId,
            extraMetadata: extraMetadata,
            poll: poll
        )
    }

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
            extraMetadata: nil,
            poll: nil
        )
    }
}

/// Réponse de `POST /api/social/posts/{id}/share` : `{ message: { id, … } }`.
/// On n'a besoin que de l'id du message créé (pour l'annulation).
struct SharePostResponse: Decodable {
    let messageId: String?

    private enum RootKeys: String, CodingKey { case message }
    private enum MessageKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let message = try? root.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        messageId = try? message?.decode(String.self, forKey: .id)
    }
}

final class SocialFeedService: SocialFeedServicing {
    private let api: APIClient
    private let postOutbox: SocialPostOutboxStore

    init(api: APIClient, postOutbox: SocialPostOutboxStore = SocialPostOutboxStore()) {
        self.api = api
        self.postOutbox = postOutbox
    }

    /// Le feed unifié renvoie des ids préfixés ("post-…") alors que les routes
    /// d'action (/api/social/posts/[id]/…) attendent l'id brut.
    private func normalizedPostId(_ raw: String) -> String {
        raw.hasPrefix("post-") ? String(raw.dropFirst("post-".count)) : raw
    }

    /// `tab` porte le couple filtre/classement. Les valeurs par défaut
    /// reproduisent exactement l'ancien comportement (`all` + `smart`), pour que
    /// les appelants non migrés soient inchangés.
    func loadFeed(
        cursor: String? = nil,
        hashtag: String? = nil,
        tab: FeedTab? = nil
    ) async throws -> SocialFeedPage {
        var query = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "filter", value: tab?.filter ?? "all"),
            URLQueryItem(name: "ranking", value: tab?.ranking ?? "smart"),
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
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll? = nil
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
            attachRadio: false,
            poll: poll
        )
        let response: CreatePostResponse = try await api.requestJSON("/api/social/v2/posts", body: request)
        return response.post
    }

    func uploadImage(data: Data, mimeType _: String = "image/jpeg") async throws -> CreatePostAttachment {
        guard let sanitized = await Task.detached(priority: .userInitiated, operation: {
            SocialImagePrivacy.sanitizedJPEG(from: data, maxSide: 1600, quality: 0.84)
        }).value else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let response: SocialUploadResponse = try await api.uploadMultipart(
            path: "/api/social/uploads",
            fields: ["platform": "ios"],
            fileField: "file",
            fileName: "signalquest-social-\(UUID().uuidString).jpg",
            mimeType: "image/jpeg",
            data: sanitized,
            as: SocialUploadResponse.self
        )
        return response.upload
    }

    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? {
        guard let session = LocalAccountScope.sessionSnapshot() else {
            throw CancellationError()
        }
        let requestId = "post:\(UUID().uuidString.lowercased())"
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
            attachments: nil,
            attachRadio: false,
            poll: poll,
            clientRequestId: requestId
        )
        let record = SocialPostOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            clientRequestId: requestId,
            request: request,
            imageMimeType: imageData == nil ? nil : imageMimeType,
            imageSha256: imageData.map(Self.sha256Hex),
            uploadedAttachment: nil,
            createdAt: Date()
        )
        try await postOutbox.stage(record, imageData: imageData, session: session)
        return try await submitPreparedPost(record, session: session)
    }

    func retryPendingPosts() async {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return }
        guard let records = try? await postOutbox.pending(session: session) else { return }
        for record in records {
            guard session.isCurrent else { return }
            do {
                _ = try await submitPreparedPost(record, session: session)
            } catch {
                return
            }
        }
    }

    private func submitPreparedPost(
        _ staged: SocialPostOutboxRecord,
        session: LocalAccountSession
    ) async throws -> UnifiedSocialFeedItem? {
        guard session.isCurrent,
              staged.ownerScopeId == session.ownerScopeId,
              staged.sessionId == session.sessionId else {
            throw CancellationError()
        }
        var record = try await postOutbox.record(
            session: session,
            clientRequestId: staged.clientRequestId
        ) ?? staged
        var attachment = record.uploadedAttachment
        if attachment == nil, record.imageSha256 != nil {
            let source = try await postOutbox.imageData(record, session: session)
            let response: SocialUploadResponse = try await api.uploadMultipart(
                path: "/api/social/uploads",
                fields: [
                    "platform": "ios",
                    "clientRequestId": record.clientRequestId,
                    "attachmentSlot": "image-0",
                ],
                fileField: "file",
                fileName: "signalquest-social-\(record.clientRequestId).jpg",
                mimeType: record.imageMimeType ?? "image/jpeg",
                data: source,
                as: SocialUploadResponse.self
            )
            attachment = response.upload
            try await postOutbox.markUploaded(
                session: session,
                clientRequestId: record.clientRequestId,
                attachment: response.upload
            )
            record = SocialPostOutboxRecord(
                ownerScopeId: record.ownerScopeId,
                sessionId: record.sessionId,
                clientRequestId: record.clientRequestId,
                request: record.request,
                imageMimeType: record.imageMimeType,
                imageSha256: record.imageSha256,
                uploadedAttachment: response.upload,
                createdAt: record.createdAt
            )
        }
        let request = CreatePostRequest(
            text: record.request.text,
            visibility: record.request.visibility,
            targetType: record.request.targetType,
            targetId: record.request.targetId,
            placeLabel: record.request.placeLabel,
            latitude: record.request.latitude,
            longitude: record.request.longitude,
            metadata: record.request.metadata,
            attachments: attachment.map { [$0] },
            attachRadio: record.request.attachRadio,
            poll: record.request.poll,
            clientRequestId: record.clientRequestId
        )
        let response: CreatePostResponse = try await api.requestJSON(
            "/api/social/v2/posts",
            body: request,
            idempotencyKey: record.clientRequestId
        )
        try await postOutbox.acknowledge(
            session: session,
            clientRequestId: record.clientRequestId
        )
        return response.post
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    func editPost(postId: String, text: String, visibility: String?) async throws -> UnifiedSocialFeedItem? {
        // Le schéma backend est `.strict()` : n'envoyer QUE les champs modifiés.
        // Une clé inconnue ferait échouer tout le patch en 400.
        struct Patch: Encodable {
            let text: String
            let visibility: String?
        }
        struct Response: Decodable { let item: UnifiedSocialFeedItem? }
        let body = try JSONEncoder.signalQuest.encode(Patch(text: text, visibility: visibility))
        let response: Response = try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))",
                method: .patch,
                headers: ["Content-Type": "application/json"],
                body: body
            ),
            as: Response.self
        )
        return response.item
    }

    func deletePost(postId: String) async throws {
        try await api.request(
            APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))", method: .delete)
        )
    }

    func followedHashtags() async throws -> [FollowedHashtag] {
        struct Response: Decodable { let follows: [FollowedHashtag]? }
        let response: Response = try await api.request(
            APIEndpoint(path: "/api/social/hashtags/follows"),
            as: Response.self
        )
        return response.follows ?? []
    }

    func setHashtagFollowed(_ tag: String, following: Bool) async throws {
        let normalized = tag.normalizedHashtag
        guard !normalized.isEmpty else { return }
        try await api.request(
            APIEndpoint(
                path: "/api/social/hashtags/\(normalized)/follow",
                method: following ? .post : .delete
            )
        )
    }

    func mutes() async throws -> SocialMutes {
        try await api.request(APIEndpoint(path: "/api/social/mutes"), as: SocialMutes.self)
    }

    func setHashtagMuted(_ tag: String, muted: Bool) async throws {
        let normalized = tag.normalizedHashtag
        guard !normalized.isEmpty else { return }
        try await api.request(
            APIEndpoint(
                path: "/api/social/mutes/hashtag/\(normalized)",
                method: muted ? .post : .delete
            )
        )
    }

    func setWordMuted(_ pattern: String, muted: Bool) async throws {
        // Le motif voyage dans le CHEMIN : sans encodage, un mot accentué ou
        // espacé produirait une URL invalide.
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return }
        try await api.request(
            APIEndpoint(
                path: "/api/social/mutes/word/\(encoded)",
                method: muted ? .post : .delete
            )
        )
    }

    func explore(query: String?) async throws -> SocialExploreResult {
        var items: [URLQueryItem] = []
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        return try await api.request(
            APIEndpoint(path: "/api/social/explore", query: items),
            as: SocialExploreResult.self
        )
    }

    func weeklyRecap() async throws -> WeeklyRecapStats? {
        struct Response: Decodable { let stats: WeeklyRecapStats? }
        let response: Response = try await api.request(
            APIEndpoint(path: "/api/social/recap"),
            as: Response.self
        )
        return response.stats
    }

    func publishWeeklyRecap() async throws -> WeeklyRecapPublishResponse {
        try await api.request(
            APIEndpoint(path: "/api/social/recap", method: .post),
            as: WeeklyRecapPublishResponse.self
        )
    }

    func votePoll(postId: String, optionId: String?, removing: Bool) async throws -> FeedPoll? {
        struct Body: Encodable { let optionId: String? }
        struct Response: Decodable { let poll: FeedPoll? }
        // POST vote, DELETE retire — `optionId` est requis au vote, facultatif
        // au retrait (absent = retirer tous ses votes).
        let body = try JSONEncoder.signalQuest.encode(Body(optionId: optionId))
        let response: Response = try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/poll/vote",
                method: removing ? .delete : .post,
                headers: ["Content-Type": "application/json"],
                body: body
            ),
            as: Response.self
        )
        return response.poll
    }

    func setPinned(postId: String, pinned: Bool) async throws {
        // POST épingle, DELETE détache — deux verbes sur la même route, sans corps.
        try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/pin",
                method: pinned ? .post : .delete
            )
        )
    }

    func share(postId: String, conversationId: String) async throws -> String? {
        let response: SharePostResponse = try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/share",
            body: ["conversationId": conversationId]
        )
        return response.messageId
    }

    /// `radiusMeters` nil/≤0 → le backend applique 3 km par défaut. Un radius > 0
    /// est transmis tel quel (le zod backend rejette 0, on ne l'envoie donc jamais).
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int? = nil) async throws -> NetworkPulse {
        var query = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude))
        ]
        if let radiusMeters, radiusMeters > 0 {
            query.append(URLQueryItem(name: "radius", value: String(radiusMeters)))
        }
        return try await api.request(
            APIEndpoint(
                path: "/api/social/network-pulse",
                query: query,
                headers: ["Cache-Control": "no-cache"]
            ),
            as: NetworkPulse.self
        )
    }

    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker] {
        struct Response: Decodable { let speedtests: [AndroidSpeedtestMarker] }
        let response: Response = try await api.request(
            APIEndpoint(path: "/api/social/nearby-speedtests", query: [
                URLQueryItem(name: "lat", value: String(latitude)),
                URLQueryItem(name: "lng", value: String(longitude)),
                URLQueryItem(name: "radius", value: String(radiusMeters)),
                URLQueryItem(name: "limit", value: String(limit))
            ]),
            as: Response.self
        )
        return response.speedtests
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

enum SocialPostOutboxError: Error, Equatable {
    case requestConflict
    case sessionChanged
    case imageMissing
    case imageCorrupted
    case imageTooLarge
}

struct SocialPostOutboxRecord: Codable, Equatable, Sendable {
    let ownerScopeId: String
    let sessionId: String
    let clientRequestId: String
    let request: CreatePostRequest
    let imageMimeType: String?
    let imageSha256: String?
    let uploadedAttachment: CreatePostAttachment?
    let createdAt: Date
}

actor SocialPostOutboxStore {
    private static let maximumImageBytes = 20 * 1_024 * 1_024
    private let root: URL
    private let currentSession: MessageTextOutboxStore.CurrentSession
    private let publisher: MessageTextOutboxStore.Publisher
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(
        baseDirectory: URL? = nil,
        currentSession: @escaping MessageTextOutboxStore.CurrentSession = { $0.isCurrent },
        publisher: @escaping MessageTextOutboxStore.Publisher = { session, write in
            try LocalAccountScope.publish(for: session, write)
        }
    ) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("SignalQuestSocialPostOutbox", isDirectory: true)
        self.currentSession = currentSession
        self.publisher = publisher
    }

    func stage(
        _ record: SocialPostOutboxRecord,
        imageData: Data?,
        session: LocalAccountSession
    ) throws {
        guard currentSession(session),
              record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else {
            throw SocialPostOutboxError.sessionChanged
        }
        if let imageData {
            guard imageData.count <= Self.maximumImageBytes else { throw SocialPostOutboxError.imageTooLarge }
            guard Self.sha256Hex(imageData) == record.imageSha256 else {
                throw SocialPostOutboxError.imageCorrupted
            }
        } else if record.imageSha256 != nil {
            throw SocialPostOutboxError.imageMissing
        }
        if let existing = try self.record(session: session, clientRequestId: record.clientRequestId) {
            guard existing == record else { throw SocialPostOutboxError.requestConflict }
            if existing.imageSha256 != nil { _ = try self.imageData(existing, session: session) }
            return
        }

        let directory = ownerDirectory(session.ownerNamespace)
        let metadataURL = self.metadataURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let imageURL = self.imageURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let metadata = try encoder.encode(record)
        try publisher(session) {
            try Self.prepareDirectory(directory)
            do {
                if let imageData { try imageData.write(to: imageURL, options: [.atomic]) }
                try metadata.write(to: metadataURL, options: [.atomic])
                if imageData != nil { Self.protect(imageURL) }
                Self.protect(metadataURL)
            } catch {
                try? FileManager.default.removeItem(at: imageURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw error
            }
        }
    }

    func pending(session: LocalAccountSession) throws -> [SocialPostOutboxRecord] {
        guard currentSession(session) else { throw SocialPostOutboxError.sessionChanged }
        let directory = ownerDirectory(session.ownerNamespace)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var active: [SocialPostOutboxRecord] = []
        for url in files {
            let value = try decoder.decode(SocialPostOutboxRecord.self, from: Data(contentsOf: url))
            if value.ownerScopeId == session.ownerScopeId && value.sessionId == session.sessionId {
                active.append(value)
            } else {
                try remove(value, session: session)
            }
        }
        return active.sorted {
            if $0.createdAt == $1.createdAt { return $0.clientRequestId < $1.clientRequestId }
            return $0.createdAt < $1.createdAt
        }
    }

    func record(session: LocalAccountSession, clientRequestId: String) throws -> SocialPostOutboxRecord? {
        try pending(session: session).first { $0.clientRequestId == clientRequestId }
    }

    func imageData(_ record: SocialPostOutboxRecord, session: LocalAccountSession) throws -> Data {
        guard currentSession(session), record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else { throw SocialPostOutboxError.sessionChanged }
        guard let expected = record.imageSha256 else { throw SocialPostOutboxError.imageMissing }
        let url = imageURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SocialPostOutboxError.imageMissing }
        let data = try Data(contentsOf: url)
        guard Self.sha256Hex(data) == expected else { throw SocialPostOutboxError.imageCorrupted }
        return data
    }

    func markUploaded(
        session: LocalAccountSession,
        clientRequestId: String,
        attachment: CreatePostAttachment
    ) throws {
        guard let current = try record(session: session, clientRequestId: clientRequestId) else {
            throw SocialPostOutboxError.imageMissing
        }
        let updated = SocialPostOutboxRecord(
            ownerScopeId: current.ownerScopeId,
            sessionId: current.sessionId,
            clientRequestId: current.clientRequestId,
            request: current.request,
            imageMimeType: current.imageMimeType,
            imageSha256: current.imageSha256,
            uploadedAttachment: attachment,
            createdAt: current.createdAt
        )
        let url = metadataURL(clientRequestId, ownerNamespace: session.ownerNamespace)
        let data = try encoder.encode(updated)
        try publisher(session) {
            try data.write(to: url, options: [.atomic])
            Self.protect(url)
        }
    }

    func acknowledge(session: LocalAccountSession, clientRequestId: String) throws {
        guard currentSession(session) else { throw SocialPostOutboxError.sessionChanged }
        if let value = try record(session: session, clientRequestId: clientRequestId) {
            try remove(value, session: session)
        }
    }

    private func remove(_ record: SocialPostOutboxRecord, session: LocalAccountSession) throws {
        let metadata = metadataURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let image = imageURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        try publisher(session) {
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.removeItem(at: metadata)
            }
            if FileManager.default.fileExists(atPath: image.path) {
                try FileManager.default.removeItem(at: image)
            }
        }
    }

    private func ownerDirectory(_ namespace: String) -> URL {
        root.appendingPathComponent(namespace, isDirectory: true)
    }

    private func metadataURL(_ requestId: String, ownerNamespace: String) -> URL {
        ownerDirectory(ownerNamespace).appendingPathComponent(Self.fileStem(requestId)).appendingPathExtension("json")
    }

    private func imageURL(_ requestId: String, ownerNamespace: String) -> URL {
        ownerDirectory(ownerNamespace).appendingPathComponent(Self.fileStem(requestId)).appendingPathExtension("blob")
    }

    private static func fileStem(_ requestId: String) -> String {
        sha256Hex(Data(requestId.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
