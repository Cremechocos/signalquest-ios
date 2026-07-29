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
    /// Préférences de compte (unités, affichage du `@` dans les classements).
    /// Elles vivent hors de `/social/privacy` côté serveur, mais relèvent du même
    /// écran pour l'utilisateur.
    func preferences() async throws -> UserPreferences
    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences
    /// Zones privées : autour d'elles, les speedtests peuvent être masqués de la
    /// carte publique.
    func zones() async throws -> [PrivacyZone]
    func updateZone(id: String, hideSpeedtestsOnMap: Bool?, isActive: Bool?) async throws
}

final class PrivacyService: PrivacyServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func preferences() async throws -> UserPreferences {
        try await api.request(APIEndpoint(path: "/api/user/preferences"), as: UserPreferences.self)
    }

    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        struct Body: Encodable {
            let unitsSystem: String
            let showHandleOnLeaderboard: Bool
            let showHypothesisSystem: Bool
        }
        return try await api.requestJSON(
            "/api/user/preferences",
            method: .patch,
            body: Body(
                unitsSystem: preferences.unitsSystem.rawValue,
                showHandleOnLeaderboard: preferences.showHandleOnLeaderboard,
                showHypothesisSystem: preferences.showHypothesisSystem
            )
        )
    }

    func zones() async throws -> [PrivacyZone] {
        try await api.request(APIEndpoint(path: "/api/user/zones"), as: PrivacyZonesResponse.self).zones
    }

    func updateZone(id: String, hideSpeedtestsOnMap: Bool?, isActive: Bool?) async throws {
        struct Body: Encodable {
            let id: String
            let hideSpeedtestsOnMap: Bool?
            let isActive: Bool?
        }
        // La route exige `id` et ne touche que les champs fournis : on n'envoie
        // donc QUE ce qui change, pour ne pas réécrire un rayon ou un nom réglés
        // depuis le web avec des valeurs qu'on n'affiche même pas ici.
        try await api.requestJSON(
            "/api/user/zones",
            method: .patch,
            body: Body(id: id, hideSpeedtestsOnMap: hideSpeedtestsOnMap, isActive: isActive)
        )
    }

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
