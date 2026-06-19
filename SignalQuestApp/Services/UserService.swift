import Foundation

struct UserProfilePatch: Codable {
    let name: String?
    let handle: String?
    let bio: String?
    let avatarUrl: String?
}

/// Réponse de `GET /api/user/profile/handle-availability`.
struct HandleAvailability: Codable {
    let available: Bool
    let current: Bool?
    let cooldownActive: Bool?
    let remainingDays: Int?
    let code: String?
}

struct UserStats: Codable {
    let totalSpeedtests: Int?
    let totalPhotos: Int?
    let totalValidations: Int?
    let totalCoverageSessions: Int?
    let totalPoints: Int?
    let level: Int?

    enum CodingKeys: String, CodingKey {
        case profile
        case speedtests
        case photos
        case validations
        case coverageSessions
        case totalSpeedtests
        case totalPhotos
        case totalValidations
        case totalCoverageSessions
        case totalPoints
        case level
    }

    struct ProfileContainer: Codable {
        let level: Int?
        let gamificationPoints: Int?
    }

    init(totalSpeedtests: Int? = nil, totalPhotos: Int? = nil, totalValidations: Int? = nil, totalCoverageSessions: Int? = nil, totalPoints: Int? = nil, level: Int? = nil) {
        self.totalSpeedtests = totalSpeedtests
        self.totalPhotos = totalPhotos
        self.totalValidations = totalValidations
        self.totalCoverageSessions = totalCoverageSessions
        self.totalPoints = totalPoints
        self.level = level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.profile) {
            let profile = try container.decodeIfPresent(ProfileContainer.self, forKey: .profile)
            self.level = profile?.level
            self.totalPoints = profile?.gamificationPoints

            // For arrays returned by the backend, count their elements to get total counts
            if let speedtests = try? container.decodeIfPresent([JSONValue].self, forKey: .speedtests) {
                self.totalSpeedtests = speedtests.count
            } else {
                self.totalSpeedtests = nil
            }

            if let photos = try? container.decodeIfPresent([JSONValue].self, forKey: .photos) {
                self.totalPhotos = photos.count
            } else {
                self.totalPhotos = nil
            }

            if let validations = try? container.decodeIfPresent([JSONValue].self, forKey: .validations) {
                self.totalValidations = validations.count
            } else {
                self.totalValidations = nil
            }

            self.totalCoverageSessions = nil
        } else {
            // Flat / direct decoding fallback
            self.totalSpeedtests = try container.decodeIfPresent(Int.self, forKey: .totalSpeedtests)
            self.totalPhotos = try container.decodeIfPresent(Int.self, forKey: .totalPhotos)
            self.totalValidations = try container.decodeIfPresent(Int.self, forKey: .totalValidations)
            self.totalCoverageSessions = try container.decodeIfPresent(Int.self, forKey: .totalCoverageSessions)
            self.totalPoints = try container.decodeIfPresent(Int.self, forKey: .totalPoints)
            self.level = try container.decodeIfPresent(Int.self, forKey: .level)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(totalSpeedtests, forKey: .totalSpeedtests)
        try container.encodeIfPresent(totalPhotos, forKey: .totalPhotos)
        try container.encodeIfPresent(totalValidations, forKey: .totalValidations)
        try container.encodeIfPresent(totalCoverageSessions, forKey: .totalCoverageSessions)
        try container.encodeIfPresent(totalPoints, forKey: .totalPoints)
        try container.encodeIfPresent(level, forKey: .level)
    }
}

struct NotificationPreferences: Codable {
    var notifyPhotoCommentsEmail: Bool?
    var notifyPhotoCommentsPush: Bool?
    var notifyPhotoCommentsInApp: Bool?
    var notifyPhotoLikesEmail: Bool?
    var notifyPhotoLikesPush: Bool?
    var notifyPhotoLikesInApp: Bool?
    var notifyPhotoMentionsEmail: Bool?
    var notifyPhotoMentionsPush: Bool?
    var notifyPhotoMentionsInApp: Bool?
    var notifyPhotoRepliesEmail: Bool?
    var notifyPhotoRepliesPush: Bool?
    var notifyPhotoRepliesInApp: Bool?
    var notifyMessagesEmail: Bool?
    var notifyMessagesPush: Bool?
    var notifyMessagesInApp: Bool?
    var notifyAnfrUpdatesPush: Bool?
    var notifyAnfrUpdatesEmail: Bool?
    var callsDoNotDisturb: Bool?
}

protocol UserServicing: Sendable {
    func profile() async throws -> AuthUser
    func updateProfile(_ patch: UserProfilePatch) async throws -> AuthUser
    func checkHandleAvailability(_ handle: String) async throws -> HandleAvailability
    func uploadAvatar(data: Data, filename: String, mimeType: String) async throws -> AuthUser
    func stats() async throws -> UserStats
    func notificationPreferences() async throws -> NotificationPreferences
    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws -> NotificationPreferences
    func heartbeat() async throws
    func deleteAccount(password: String) async throws
    /// Archive RGPD complète (profil, mesures, contributions, messages…) au format
    /// JSON, telle que renvoyée par le backend `GET /api/export/my-data`.
    func exportPersonalData() async throws -> Data
}

final class UserService: UserServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func profile() async throws -> AuthUser {
        struct Response: Codable { let user: AuthUser }
        return try await api.request(APIEndpoint(path: "/api/user/profile"), as: Response.self).user
    }

    func updateProfile(_ patch: UserProfilePatch) async throws -> AuthUser {
        struct Response: Codable { let user: AuthUser }
        // Le backend n'expose que PUT (pas PATCH) sur /api/user/profile → un PATCH
        // renvoyait 405 et AUCUNE modif (nom/handle) ne passait. Android utilise PUT.
        let response: Response = try await api.requestJSON("/api/user/profile", method: .put, body: patch)
        return response.user
    }

    func checkHandleAvailability(_ handle: String) async throws -> HandleAvailability {
        try await api.request(
            APIEndpoint(
                path: "/api/user/profile/handle-availability",
                query: [URLQueryItem(name: "handle", value: handle)]
            ),
            as: HandleAvailability.self
        )
    }

    func uploadAvatar(data: Data, filename: String, mimeType: String) async throws -> AuthUser {
        // Le backend renvoie { success, avatarUrl } (PAS l'utilisateur complet) :
        // on déclenche l'upload puis on recharge le profil pour l'AuthUser à jour.
        struct UploadResponse: Codable { let success: Bool?; let avatarUrl: URL? }
        let _: UploadResponse = try await api.uploadMultipart(
            path: "/api/user/avatar",
            fields: [:],
            fileField: "file",
            fileName: filename,
            mimeType: mimeType,
            data: data,
            as: UploadResponse.self
        )
        return try await profile()
    }

    func stats() async throws -> UserStats {
        try await api.request(APIEndpoint(path: "/api/user/stats"), as: UserStats.self)
    }

    func notificationPreferences() async throws -> NotificationPreferences {
        try await api.request(APIEndpoint(path: "/api/user/notification-preferences"), as: NotificationPreferences.self)
    }

    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws -> NotificationPreferences {
        try await api.requestJSON("/api/user/notification-preferences", method: .patch, body: prefs)
    }

    func heartbeat() async throws {
        let _: SuccessResponse = try await api.request(
            APIEndpoint(path: "/api/user/heartbeat", method: .post),
            as: SuccessResponse.self
        )
    }

    func deleteAccount(password: String) async throws {
        // Le backend exige DELETE + { password, confirmation: "SUPPRIMER MON COMPTE" }.
        let _: SuccessResponse = try await api.requestJSON(
            "/api/user/delete-account",
            method: .delete,
            body: ["password": password, "confirmation": "SUPPRIMER MON COMPTE"]
        )
    }

    func exportPersonalData() async throws -> Data {
        // Renvoie l'archive JSON brute pour que l'UI puisse l'écrire dans un fichier
        // et la partager (droit d'accès RGPD, art. 15).
        try await api.requestData(APIEndpoint(path: "/api/export/my-data"))
    }
}

