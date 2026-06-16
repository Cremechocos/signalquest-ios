import Foundation

/// Validations communautaires d'un site (consultation + vote) et identification
/// d'une cellule→site. Endpoints existants côté backend (utilisés par Android).
protocol ValidationsServicing: Sendable {
    func validations(siteId: String) async throws -> SiteValidations
    func vote(siteId: String, type: String, value: String, operatorName: String?, tech: String?, action: String) async throws
}

final class ValidationsService: ValidationsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func validations(siteId: String) async throws -> SiteValidations {
        try await api.request(
            APIEndpoint(path: "/api/validations", query: [URLQueryItem(name: "siteId", value: siteId)]),
            as: SiteValidations.self
        )
    }

    /// `action` = "submit" | "validate" | "reject".
    func vote(siteId: String, type: String, value: String, operatorName: String?, tech: String?, action: String) async throws {
        struct Body: Encodable {
            let siteId: String
            let type: String
            let value: String
            let `operator`: String?
            let tech: String?
            let action: String
        }
        try await api.requestJSON(
            "/api/validations",
            method: .post,
            body: Body(siteId: siteId, type: type, value: value, operator: operatorName, tech: tech, action: action)
        )
    }
}
