import Foundation

enum MeasurementPrivacySettings {
    /// Miroir local du réglage serveur, uniquement pour décider si le client peut
    /// transmettre la précision complète. Le backend reste la source d'autorité.
    static let shareExactMeasurementsKey = "privacy_share_exact_measurements"
}

enum LastSeenVisibility: String, Codable, CaseIterable, Sendable {
    case friends
    case none
}

enum MessageRequestPolicy: String, Codable, CaseIterable, Sendable {
    case everyone
    case friendsOnly = "friends_only"
    case noOne = "no_one"
}

struct SocialPrivacy: Codable, Equatable, Sendable {
    let shareLiveLocationWithFriends: Bool
    let shareRadioDataWithFriends: Bool
    let shareSessionsWithFriends: Bool
    let sharePhotosOnFriendMap: Bool
    let shareExactMeasurements: Bool
    let lastSeenVisibility: LastSeenVisibility
    let messageRequestPolicy: MessageRequestPolicy
}

struct UpdatePrivacyRequest: Codable, Sendable {
    let shareLiveLocationWithFriends: Bool
    let shareRadioDataWithFriends: Bool
    let shareSessionsWithFriends: Bool
    let sharePhotosOnFriendMap: Bool
    let shareExactMeasurements: Bool
    let lastSeenVisibility: LastSeenVisibility
    let messageRequestPolicy: MessageRequestPolicy
}

protocol PrivacyServicing: Sendable {
    func get() async throws -> SocialPrivacy
    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy
}

final class PrivacyService: PrivacyServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func get() async throws -> SocialPrivacy {
        struct Response: Decodable { let settings: SocialPrivacy }
        return try await api.request(
            APIEndpoint(path: "/api/social/privacy"),
            as: Response.self
        ).settings
    }

    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy {
        struct Response: Decodable { let settings: SocialPrivacy }
        let response: Response = try await api.requestJSON(
            "/api/social/privacy",
            method: .patch,
            body: patch
        )
        return response.settings
    }
}
