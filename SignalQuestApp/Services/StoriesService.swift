import Foundation

protocol StoriesServicing: Sendable {
    func list() async throws -> [SocialStory]
    /// Crée une story. `displayDurationSeconds` est la durée d'affichage (5/10/15)
    /// — distincte de la durée de vie (24 h) encodée via `expiresAt` côté service.
    func create(
        text: String?,
        mediaUrl: URL?,
        thumbnailUrl: URL?,
        mediaKind: String?,
        displayDurationSeconds: Int
    ) async throws -> SocialStory?
    /// Téléverse une image de story et renvoie ses URLs (média + miniature).
    func uploadMedia(data: Data) async throws -> StoryUpload
    func markViewed(_ storyId: String) async throws
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

/// Corps de `POST /api/social/stories`. Le backend exige `expiresAt` (RFC3339)
/// et restreint `durationSeconds` à 5/10/15 (durée d'affichage).
struct CreateStoryRequest: Codable {
    let text: String?
    let mediaUrl: String?
    let thumbnailUrl: String?
    let mediaKind: String?
    let durationSeconds: Int
    let expiresAt: String
}

struct CreateStoryResponse: Codable {
    let story: SocialStory?
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
        displayDurationSeconds: Int = 10
    ) async throws -> SocialStory? {
        let duration = Self.allowedDisplayDurations.contains(displayDurationSeconds) ? displayDurationSeconds : 10
        // Durée de vie d'une story : 24 h. `expiresAt` au format RFC3339 UTC.
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(24 * 3600))
        let body = CreateStoryRequest(
            text: text,
            mediaUrl: mediaUrl?.absoluteString,
            thumbnailUrl: thumbnailUrl?.absoluteString,
            mediaKind: mediaUrl != nil ? (mediaKind ?? "image") : nil,
            durationSeconds: duration,
            expiresAt: expiresAt
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
}
