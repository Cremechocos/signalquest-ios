import Foundation

/// Motifs de signalement — alignés 1:1 sur l'enum backend
/// (`/api/social/reports` : `spam|harassment|privacy|illegal|misleading|other`).
/// Toute valeur hors de cet ensemble est rejetée en 400 côté serveur.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, privacy, illegal, misleading, other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harcèlement"
        case .privacy: return "Atteinte à la vie privée"
        case .illegal: return "Contenu illégal"
        case .misleading: return "Désinformation"
        case .other: return "Autre"
        }
    }
}

/// Cible d'un signalement.
///
/// Ce type était auparavant une simple `String`, ce qui a laissé passer un bug
/// silencieux : le signalement de photo envoyait `targetType: "photo"` à
/// `/api/social/reports`, dont le schéma zod n'accepte que
/// `post|comment|profile` — donc **400 systématique** sur un contenu généré par
/// les utilisateurs. Le compilateur garantit désormais qu'aucune cible ne peut
/// être routée vers un endpoint qui ne la comprend pas.
enum ReportTarget: Equatable, Sendable {
    case post(String)
    case comment(String)
    case profile(String)
    case photo(String)
    case photoComment(String)

    var id: String {
        switch self {
        case .post(let id), .comment(let id), .profile(let id),
             .photo(let id), .photoComment(let id):
            return id
        }
    }
}

/// Corps de `/api/social/reports` (posts, commentaires, profils).
struct ReportRequest: Codable {
    let targetType: String
    let targetId: String
    let reason: String
    /// Le backend lit le texte libre dans `details` (et non `comment`).
    let details: String?
}

/// Corps des routes de modération photo (`contentReportSchema` côté backend :
/// `{ reason, description }` — ni `targetType` ni `targetId`, portés par l'URL).
struct ContentReportRequest: Codable {
    let reason: String
    let description: String?
}

protocol ReportsServicing: Sendable {
    func report(_ target: ReportTarget, reason: ReportReason, comment: String?) async throws
}

final class ReportsService: ReportsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func report(_ target: ReportTarget, reason: ReportReason, comment: String?) async throws {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (trimmed?.isEmpty == false) ? trimmed : nil

        // Les photos ont leurs propres routes de modération, avec un corps
        // différent : la cible est portée par l'URL, pas par le payload.
        switch target {
        case .photo(let id):
            let _: SuccessResponse = try await api.requestJSON(
                "/api/photos/\(id)/report",
                body: ContentReportRequest(reason: reason.rawValue, description: details)
            )
        case .photoComment(let id):
            let _: SuccessResponse = try await api.requestJSON(
                "/api/photos/comments/\(id)/report",
                body: ContentReportRequest(reason: reason.rawValue, description: details)
            )
        case .post, .comment, .profile:
            let _: SuccessResponse = try await api.requestJSON(
                "/api/social/reports",
                body: ReportRequest(
                    targetType: Self.socialTargetType(target),
                    targetId: target.id,
                    reason: reason.rawValue,
                    details: details
                )
            )
        }
    }

    /// Valeurs acceptées par le schéma zod de `/api/social/reports`.
    private static func socialTargetType(_ target: ReportTarget) -> String {
        switch target {
        case .post: return "post"
        case .comment: return "comment"
        case .profile: return "profile"
        // Inatteignable : les cas photo sont routés vers leurs endpoints dédiés
        // avant d'arriver ici. Le `switch` reste exhaustif pour qu'un nouveau
        // cas force une décision explicite.
        case .photo, .photoComment: return "post"
        }
    }

    /// Contestation d'une décision de modération sur une photo. Apple attend ce
    /// recours sur un flux de contenu utilisateur modéré.
    func appealPhoto(id: String, reason: ReportReason, comment: String?) async throws {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: SuccessResponse = try await api.requestJSON(
            "/api/photos/\(id)/appeal",
            body: ContentReportRequest(
                reason: reason.rawValue,
                description: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        )
    }
}
