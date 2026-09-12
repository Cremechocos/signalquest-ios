import Foundation

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

// Le serveur a retiré cette ancienne préférence, puis rétabli une clé de
// compatibilité. Décoder les deux contrats sans perdre les autres réglages.
// Cette valeur n’est plus une préférence modifiable dans la nouvelle UI.
extension SocialPrivacy {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shareLiveLocationWithFriends = try values.decode(Bool.self, forKey: .shareLiveLocationWithFriends)
        shareRadioDataWithFriends = try values.decode(Bool.self, forKey: .shareRadioDataWithFriends)
        shareSessionsWithFriends = try values.decode(Bool.self, forKey: .shareSessionsWithFriends)
        sharePhotosOnFriendMap = try values.decode(Bool.self, forKey: .sharePhotosOnFriendMap)
        shareExactMeasurements = try values.decodeIfPresent(Bool.self, forKey: .shareExactMeasurements) ?? true
        lastSeenVisibility = try values.decode(LastSeenVisibility.self, forKey: .lastSeenVisibility)
        messageRequestPolicy = try values.decode(MessageRequestPolicy.self, forKey: .messageRequestPolicy)
    }
}

struct UpdatePrivacyRequest: Codable, Sendable {
    var shareLiveLocationWithFriends: Bool? = nil
    var shareRadioDataWithFriends: Bool? = nil
    var shareSessionsWithFriends: Bool? = nil
    var sharePhotosOnFriendMap: Bool? = nil
    var shareExactMeasurements: Bool? = nil
    var lastSeenVisibility: LastSeenVisibility? = nil
    var messageRequestPolicy: MessageRequestPolicy? = nil
}

struct UserPreferencesPatch: Encodable, Sendable {
    var unitsSystem: SQUnitsSystem? = nil
    var showHandleOnLeaderboard: Bool? = nil
    var showHypothesisSystem: Bool? = nil
}

protocol PrivacyServicing: Sendable {
    /// Lie le service au propriétaire et à la génération HTTP présents à
    /// l'ouverture de l'écran, avant le premier saut asynchrone.
    func scoped(to session: LocalAccountSession) -> any PrivacyServicing
    func get() async throws -> SocialPrivacy
    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy
    /// Préférences de compte (unités, affichage du `@` dans les classements).
    /// Elles vivent hors de `/social/privacy` côté serveur, mais relèvent du même
    /// écran pour l'utilisateur.
    func preferences() async throws -> UserPreferences
    func updatePreferences(_ patch: UserPreferencesPatch) async throws -> UserPreferences
    /// Zones privées : autour d'elles, les speedtests peuvent être masqués de la
    /// carte publique.
    func zones() async throws -> [PrivacyZone]
    func createZone(_ request: CreatePrivacyZoneRequest) async throws -> PrivacyZone
    func updateZone(_ patch: UpdatePrivacyZoneRequest) async throws -> PrivacyZone
    func deleteZone(id: String) async throws
}

final class PrivacyService: PrivacyServicing {
    private let api: APIClient
    private let owner: LocalAccountSession?
    private let credentialSessionID: UUID?
    private let invalidatePublicMap: @Sendable () async -> Void
    init(api: APIClient, owner: LocalAccountSession? = nil, credentialSessionID: UUID? = nil,
         invalidatePublicMap: @escaping @Sendable () async -> Void = {}) {
        self.api = api
        self.owner = owner
        self.credentialSessionID = credentialSessionID
        self.invalidatePublicMap = invalidatePublicMap
    }

    func scoped(to session: LocalAccountSession) -> any PrivacyServicing {
        PrivacyService(api: api, owner: session, credentialSessionID: api.credentials.snapshot().sessionID,
            invalidatePublicMap: invalidatePublicMap)
    }

    func preferences() async throws -> UserPreferences {
        try await request(APIEndpoint(path: "/api/user/preferences"), as: UserPreferences.self)
    }

    func updatePreferences(_ patch: UserPreferencesPatch) async throws -> UserPreferences {
        return try await requestJSON(
            "/api/user/preferences",
            method: .patch,
            body: patch
        )
    }

    func zones() async throws -> [PrivacyZone] {
        try await request(APIEndpoint(path: "/api/user/zones"), as: PrivacyZonesResponse.self).zones
    }

    func createZone(_ request: CreatePrivacyZoneRequest) async throws -> PrivacyZone {
        let response: PrivacyZoneResponse = try await requestJSON("/api/user/zones", body: request)
        await invalidatePublicMap()
        return response.zone
    }

    func updateZone(_ patch: UpdatePrivacyZoneRequest) async throws -> PrivacyZone {
        let response: PrivacyZoneResponse = try await requestJSON("/api/user/zones", method: .patch, body: patch)
        guard response.zone.id == patch.id else { throw APIError.decoding("zone-response-identity-mismatch") }
        await invalidatePublicMap()
        return response.zone
    }

    func deleteZone(id: String) async throws {
        let response: ZoneDeletionResponse = try await request(APIEndpoint(path: "/api/user/zones", method: .delete,
            query: [URLQueryItem(name: "id", value: id)]), as: ZoneDeletionResponse.self)
        guard response.success else { throw APIError.decoding("zone-deletion-not-confirmed") }
        await invalidatePublicMap()
    }

    func get() async throws -> SocialPrivacy {
        struct Response: Decodable { let settings: SocialPrivacy }
        return try await request(
            APIEndpoint(path: "/api/social/privacy"),
            as: Response.self
        ).settings
    }

    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy {
        struct Response: Decodable { let settings: SocialPrivacy }
        let response: Response = try await requestJSON(
            "/api/social/privacy",
            method: .patch,
            body: patch
        )
        return response.settings
    }

    private struct ZoneDeletionResponse: Decodable { let success: Bool }

    private func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        guard owner?.isCurrent != false else { throw APIError.cancelled }
        let value = try await api.request(endpoint, as: type, expectedSessionID: credentialSessionID)
        guard owner?.isCurrent != false else { throw APIError.cancelled }
        return value
    }

    private func requestJSON<T: Decodable, Body: Encodable>(_ path: String, method: HTTPMethod = .post, body: Body) async throws -> T {
        try await request(APIEndpoint(path: path, method: method, headers: ["Content-Type": "application/json"],
            body: JSONEncoder.signalQuest.encode(body)), as: T.self)
    }
}
