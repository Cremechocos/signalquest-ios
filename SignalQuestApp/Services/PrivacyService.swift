import Foundation

extension Notification.Name {
    static let sqPrivacyZoneMapChanged = Notification.Name("sqPrivacyZoneMapChanged")
}

@MainActor
enum SQPrivacyZoneMapChange {
    private(set) static var revision: UInt64 = 0

    static func publish() {
        revision &+= 1
        NotificationCenter.default.post(name: .sqPrivacyZoneMapChanged, object: nil)
    }
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
    /// « Masquer mes listes » (Abonnés / Abonnements). `nil` = le serveur ne
    /// l'expose pas (clé absente), ce qui n'est pas la même chose que « faux » :
    /// l'écran ne propose le réglage que s'il est connu.
    var hideFollowLists: Bool? = nil
    /// Audience par défaut des nouveaux posts (PRIVACY-DPV v1), servie avec
    /// `include=posts`. `nil` = ancien serveur : ni page de choix, ni lien.
    var defaultPostVisibility: DefaultPostVisibility? = nil
    /// Le membre n'a pas encore répondu : la page de choix s'ouvre sur le fil.
    var defaultPostVisibilityPending: Bool? = nil
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
        hideFollowLists = try? values.decodeIfPresent(Bool.self, forKey: .hideFollowLists)
        // Une valeur inconnue vaut absence : jamais de page ouverte sur une donnée mal lue.
        let visibility = (try? values.decodeIfPresent(String.self, forKey: .defaultPostVisibility)).flatMap { $0 }
        defaultPostVisibility = visibility.flatMap(DefaultPostVisibility.init(rawValue:))
        defaultPostVisibilityPending = defaultPostVisibility == nil
            ? nil : (try? values.decodeIfPresent(Bool.self, forKey: .defaultPostVisibilityPending)).flatMap { $0 }
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
    var hideFollowLists: Bool? = nil
}

/// Réponse de `/api/social/privacy` (GET et PATCH).
struct PrivacySettingsResponse: Decodable {
    let settings: SocialPrivacy
    /// PRIVACY-DPV v1 : à la racine, à côté de `settings`, seulement si la case
    /// était cochée (§7).
    let appliedToExistingPosts: Int?
}

struct DefaultPostVisibilityPatch: Encodable, Sendable {
    let defaultPostVisibility: DefaultPostVisibility
    /// Absent sauf case cochée : `false` ne servirait à rien.
    var applyToExistingPosts: Bool? = nil
}

struct UserPreferencesPatch: Encodable, Sendable {
    var unitsSystem: SQUnitsSystem? = nil
    var showHandleOnLeaderboard: Bool? = nil
    var showHypothesisSystem: Bool? = nil
    var addressForm: SQAddressForm? = nil
    /// « Mon pays » ; la chaîne vide revient au pays déduit (le serveur l'écrit `null`).
    var defaultMarket: String? = nil
}

protocol PrivacyServicing: Sendable {
    /// Lie le service au propriétaire et à la génération HTTP présents à
    /// l'ouverture de l'écran, avant le premier saut asynchrone.
    func scoped(to session: LocalAccountSession) -> any PrivacyServicing
    func get() async throws -> SocialPrivacy
    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy
    /// PRIVACY-DPV v1 : choisit l'audience par défaut, et l'applique aux
    /// publications automatiques déjà en ligne si la case est cochée.
    func setDefaultPostVisibility(_ value: DefaultPostVisibility, applyToExistingPosts: Bool) async throws -> DefaultPostVisibilityUpdate
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

extension PrivacyServicing {
    func setDefaultPostVisibility(_ value: DefaultPostVisibility, applyToExistingPosts: Bool) async throws -> DefaultPostVisibilityUpdate {
        throw APIError.decoding("default-post-visibility-unsupported")
    }
}

final class PrivacyService: PrivacyServicing {
    private let api: APIClient
    private let owner: LocalAccountSession?
    private let credentialSessionID: UUID?
    private let invalidatePublicMap: @Sendable () async -> Void
    /// Reçoit chaque réglage servi avec `include=posts`, et le compte qui l'a lu.
    private let recordSettings: @Sendable (SocialPrivacy, String) async -> Void
    init(api: APIClient, owner: LocalAccountSession? = nil, credentialSessionID: UUID? = nil,
         invalidatePublicMap: @escaping @Sendable () async -> Void = {},
         recordSettings: @escaping @Sendable (SocialPrivacy, String) async -> Void = { _, _ in }) {
        self.api = api
        self.owner = owner
        self.credentialSessionID = credentialSessionID
        self.invalidatePublicMap = invalidatePublicMap
        self.recordSettings = recordSettings
    }

    func scoped(to session: LocalAccountSession) -> any PrivacyServicing {
        PrivacyService(api: api, owner: session, credentialSessionID: api.credentials.snapshot().sessionID,
            invalidatePublicMap: invalidatePublicMap, recordSettings: recordSettings)
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
        await invalidateMapAfterZoneMutation()
        return response.zone
    }

    func updateZone(_ patch: UpdatePrivacyZoneRequest) async throws -> PrivacyZone {
        let response: PrivacyZoneResponse = try await requestJSON("/api/user/zones", method: .patch, body: patch)
        guard response.zone.id == patch.id else { throw APIError.decoding("zone-response-identity-mismatch") }
        await invalidateMapAfterZoneMutation()
        return response.zone
    }

    func deleteZone(id: String) async throws {
        let response: ZoneDeletionResponse = try await request(APIEndpoint(path: "/api/user/zones", method: .delete,
            query: [URLQueryItem(name: "id", value: id)]), as: ZoneDeletionResponse.self)
        guard response.success else { throw APIError.decoding("zone-deletion-not-confirmed") }
        await invalidateMapAfterZoneMutation()
    }

    private func invalidateMapAfterZoneMutation() async {
        await invalidatePublicMap()
        await MainActor.run {
            SQPrivacyZoneMapChange.publish()
        }
    }

    /// `include=profile` ajoute `hideFollowLists`, `include=posts` l'audience par
    /// défaut ; sans eux la réponse est inchangée. Le paramètre est RÉPÉTÉ : un
    /// ancien serveur comparait la valeur entière et ignorait « profile,posts ».
    /// Le PATCH porte les mêmes : sa réponse passe par la même fonction.
    static let settingsQuery = [URLQueryItem(name: "include", value: "profile"), URLQueryItem(name: "include", value: "posts")]

    func get() async throws -> SocialPrivacy {
        struct Response: Decodable { let settings: SocialPrivacy }
        let settings = try await request(
            APIEndpoint(path: "/api/social/privacy", query: Self.settingsQuery),
            as: Response.self
        ).settings
        await recordSettings(settings, recordingOwner)
        return settings
    }

    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy {
        try await patchSettings(patch).settings
    }

    func setDefaultPostVisibility(_ value: DefaultPostVisibility, applyToExistingPosts: Bool) async throws -> DefaultPostVisibilityUpdate {
        // Sans la case, le corps ne porte que la valeur : c'est aussi le geste
        // de fermeture de la page de choix (§6), au champ près.
        let response = try await patchSettings(DefaultPostVisibilityPatch(
            defaultPostVisibility: value, applyToExistingPosts: applyToExistingPosts ? true : nil))
        return DefaultPostVisibilityUpdate(settings: response.settings, appliedToExistingPosts: response.appliedToExistingPosts)
    }

    private func patchSettings<Body: Encodable>(_ body: Body) async throws -> PrivacySettingsResponse {
        let response = try await request(APIEndpoint(path: "/api/social/privacy", method: .patch, query: Self.settingsQuery,
            headers: ["Content-Type": "application/json"], body: JSONEncoder.signalQuest.encode(body)), as: PrivacySettingsResponse.self)
        await recordSettings(response.settings, recordingOwner)
        return response
    }

    private var recordingOwner: String { owner?.ownerScopeId ?? LocalAccountScope.currentOwnerScopeId }

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
