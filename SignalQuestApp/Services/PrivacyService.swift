import Foundation

struct SocialPrivacy: Codable, Equatable {
    let defaultVisibility: String?
    let allowMentions: Bool?
    let allowFollow: Bool?
    let allowDMs: Bool?
    let showRadioOnPosts: Bool?
}

struct UpdatePrivacyRequest: Codable {
    let defaultVisibility: String?
    let allowMentions: Bool?
    let allowFollow: Bool?
    let allowDMs: Bool?
    let showRadioOnPosts: Bool?
}

protocol PrivacyServicing: Sendable {
    func get() async throws -> SocialPrivacy
    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy
}

final class PrivacyService: PrivacyServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func get() async throws -> SocialPrivacy {
        try await api.request(APIEndpoint(path: "/api/social/privacy"), as: SocialPrivacy.self)
    }

    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy {
        try await api.requestJSON("/api/social/privacy", method: .patch, body: patch)
    }
}
