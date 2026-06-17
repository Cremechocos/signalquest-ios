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

struct ReportRequest: Codable {
    let targetType: String
    let targetId: String
    let reason: String
    /// Le backend lit le texte libre dans `details` (et non `comment`).
    let details: String?
}

protocol ReportsServicing: Sendable {
    func report(targetType: String, targetId: String, reason: ReportReason, comment: String?) async throws
}

final class ReportsService: ReportsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func report(targetType: String, targetId: String, reason: ReportReason, comment: String?) async throws {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: SuccessResponse = try await api.requestJSON(
            "/api/social/reports",
            body: ReportRequest(
                targetType: Self.normalizedTargetType(targetType),
                targetId: targetId,
                reason: reason.rawValue,
                details: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        )
    }

    /// Le backend n'accepte que `post|comment|profile`. On mappe les libellés
    /// internes iOS (« user » → « profile ») ; `post`/`comment` passent tels quels.
    /// Les autres cibles (ex. `photo`) ne sont pas encore supportées côté backend
    /// et sont laissées intactes (le serveur renverra 400) plutôt que d'envoyer un
    /// identifiant mal typé.
    private static func normalizedTargetType(_ raw: String) -> String {
        switch raw {
        case "user", "profile": return "profile"
        case "post": return "post"
        case "comment": return "comment"
        default: return raw
        }
    }
}
