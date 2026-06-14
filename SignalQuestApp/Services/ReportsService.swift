import Foundation

enum ReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, hate, sexual, violence, falseInfo, other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harcèlement"
        case .hate: return "Discours haineux"
        case .sexual: return "Contenu inapproprié"
        case .violence: return "Violence"
        case .falseInfo: return "Désinformation"
        case .other: return "Autre"
        }
    }
}

struct ReportRequest: Codable {
    let targetType: String
    let targetId: String
    let reason: String
    let comment: String?
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
        let _: SuccessResponse = try await api.requestJSON(
            "/api/social/reports",
            body: ReportRequest(targetType: targetType, targetId: targetId, reason: reason.rawValue, comment: comment)
        )
    }
}
