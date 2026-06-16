import Foundation

/// Accès aux sessions/logs de mesure de l'utilisateur (synchronisées côté
/// serveur, donc visibles ici même si enregistrées sur Android).
protocol SessionsServicing: Sendable {
    func sessions(offset: Int, limit: Int) async throws -> SessionsListResponse
    func sessionDetail(id: String) async throws -> CoverageSessionDetail
}

final class SessionsService: SessionsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func sessions(offset: Int = 0, limit: Int = 30) async throws -> SessionsListResponse {
        try await api.request(
            APIEndpoint(
                path: "/api/coverage/sessions",
                query: [
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(limit))
                ]
            ),
            as: SessionsListResponse.self
        )
    }

    func sessionDetail(id: String) async throws -> CoverageSessionDetail {
        try await api.request(
            APIEndpoint(
                path: "/api/coverage/sessions",
                query: [
                    URLQueryItem(name: "sessionId", value: id),
                    URLQueryItem(name: "withAntennas", value: "1")
                ]
            ),
            as: CoverageSessionDetail.self
        )
    }
}
