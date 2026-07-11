import Foundation

protocol StoriesServicing: Sendable {
    func list() async throws -> [SocialStory]
    /// Crée une story. `displayDurationSeconds` = durée d'affichage (5/10/15) ;
    /// `ttlHours` = durée de vie (24 h par défaut ; 48/72 h réservé Premium côté
    /// backend). `visibility` ∈ public|friends|close_friends|private.
    func create(
        text: String?,
        mediaUrl: URL?,
        thumbnailUrl: URL?,
        mediaKind: String?,
        displayDurationSeconds: Int,
        visibility: String,
        ttlHours: Int,
        hiddenUserIds: [String],
        background: String?
    ) async throws -> SocialStory?
    /// Téléverse une image de story et renvoie ses URLs (média + miniature).
    func uploadMedia(data: Data) async throws -> StoryUpload
    func markViewed(_ storyId: String) async throws
    /// Supprime une story (auteur uniquement).
    func delete(_ storyId: String) async throws
    /// Utilisateurs ayant vu la story (auteur uniquement) — « Vu par N ».
    func viewers(storyId: String) async throws -> [StoryViewerEntry]
    /// Liste persistante des amis proches.
    func closeFriends() async throws -> [CloseFriend]
    /// Remplace la liste des amis proches ; renvoie les ids finalement retenus.
    func setCloseFriends(userIds: [String]) async throws -> [String]
}

struct StoriesListResponse: Decodable {
    let stories: [SocialStory]
    enum CodingKeys: String, CodingKey { case stories, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stories = (try? c.decode([SocialStory].self, forKey: .stories))
            ?? (try? c.decode([SocialStory].self, forKey: .items))
            ?? []
    }
}

/// Réponse de `/api/social/uploads` : média stocké + miniature.
struct StoryUpload: Decodable, Sendable {
    let kind: String?
    let url: URL
    let thumbnailUrl: URL?
    let width: Int?
    let height: Int?
}

private struct StoryUploadResponse: Decodable {
    let upload: StoryUpload
}

/// Corps de `POST /api/social/stories`. On envoie `ttlHours` (nouveau contrat) —
/// 24 h passe pour tous, 48/72 h est gaté Premium côté backend (403 sinon).
struct CreateStoryRequest: Codable {
    let text: String?
    let mediaUrl: String?
    let thumbnailUrl: String?
    let mediaKind: String?
    let durationSeconds: Int
    let visibility: String
    let ttlHours: Int
    let hiddenUserIds: [String]?
    let background: String?
}

struct CreateStoryResponse: Codable {
    let story: SocialStory?
}

// MARK: - Audience & « Vu par N »

/// Ami proche (liste persistante) renvoyé par `GET /api/social/close-friends`.
struct CloseFriend: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?

    var displayName: String { name ?? handle.map { "@\($0)" } ?? "Ami" }
}

private struct CloseFriendsResponse: Decodable { let closeFriends: [CloseFriend] }
/// `PUT /api/social/close-friends` renvoie les ids finalement retenus.
private struct SetCloseFriendsResponse: Decodable { let closeFriends: [String] }

/// Une entrée « Vu par » : l'utilisateur + l'instant de visualisation.
struct StoryViewerEntry: Decodable, Identifiable, Equatable {
    let user: SocialFeedAuthor
    let viewedAt: Date?
    var id: String { user.id }
}

private struct StoryViewsResponse: Decodable {
    let viewers: [StoryViewerEntry]
    enum CodingKeys: String, CodingKey { case viewers, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viewers = (try? c.decode([StoryViewerEntry].self, forKey: .viewers))
            ?? (try? c.decode([StoryViewerEntry].self, forKey: .items))
            ?? []
    }
}

final class StoriesService: StoriesServicing {
    private let api: APIClient
    /// Durées d'affichage autorisées par le backend.
    private static let allowedDisplayDurations: Set<Int> = [5, 10, 15]
    init(api: APIClient) { self.api = api }

    func list() async throws -> [SocialStory] {
        try await api.request(APIEndpoint(path: "/api/social/stories"), as: StoriesListResponse.self).stories
    }

    func uploadMedia(data: Data) async throws -> StoryUpload {
        let response: StoryUploadResponse = try await api.uploadMultipart(
            path: "/api/social/uploads",
            fields: [:],
            fileField: "file",
            fileName: "signalquest-story-\(UUID().uuidString).jpg",
            mimeType: "image/jpeg",
            data: data,
            as: StoryUploadResponse.self
        )
        return response.upload
    }

    func create(
        text: String?,
        mediaUrl: URL?,
        thumbnailUrl: URL?,
        mediaKind: String?,
        displayDurationSeconds: Int = 10,
        visibility: String = "friends",
        ttlHours: Int = 24,
        hiddenUserIds: [String] = [],
        background: String? = nil
    ) async throws -> SocialStory? {
        let duration = Self.allowedDisplayDurations.contains(displayDurationSeconds) ? displayDurationSeconds : 10
        let body = CreateStoryRequest(
            text: text,
            mediaUrl: mediaUrl?.absoluteString,
            thumbnailUrl: thumbnailUrl?.absoluteString,
            mediaKind: mediaUrl != nil ? (mediaKind ?? "image") : nil,
            durationSeconds: duration,
            visibility: visibility,
            ttlHours: min(72, max(1, ttlHours)),
            hiddenUserIds: hiddenUserIds.isEmpty ? nil : hiddenUserIds,
            background: background
        )
        let response: CreateStoryResponse = try await api.requestJSON("/api/social/stories", body: body)
        return response.story
    }

    func markViewed(_ storyId: String) async throws {
        _ = try await api.request(
            APIEndpoint(path: "/api/social/stories/\(storyId)/view", method: .post),
            as: SuccessResponse.self
        )
    }

    func delete(_ storyId: String) async throws {
        try await api.request(APIEndpoint(path: "/api/social/stories/\(storyId)", method: .delete))
    }

    func viewers(storyId: String) async throws -> [StoryViewerEntry] {
        try await api.request(
            APIEndpoint(path: "/api/social/stories/\(storyId)/views"),
            as: StoryViewsResponse.self
        ).viewers
    }

    func closeFriends() async throws -> [CloseFriend] {
        try await api.request(
            APIEndpoint(path: "/api/social/close-friends"),
            as: CloseFriendsResponse.self
        ).closeFriends
    }

    func setCloseFriends(userIds: [String]) async throws -> [String] {
        let response: SetCloseFriendsResponse = try await api.requestJSON(
            "/api/social/close-friends",
            method: .put,
            body: ["userIds": userIds]
        )
        return response.closeFriends
    }
}
