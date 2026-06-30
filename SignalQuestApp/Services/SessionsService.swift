import Foundation

/// Un point de couverture contribué par iOS (F1). PAS de signal radio (iOS ne
/// l'expose pas) : seulement génération (`technology`) + connectivité + position,
/// et débit/latence aux points testés.
struct CoveragePointUpload: Encodable, Sendable {
    let latitude: Double
    let longitude: Double
    /// Horodatage en millisecondes epoch (non ambigu pour le backend).
    let timestamp: Int
    /// Génération : "2G"/"3G"/"4G"/"5G NSA"/"5G SA" ou "Aucun" (zone sans réseau).
    let technology: String
    var downloadMbps: Double? = nil
    var uploadMbps: Double? = nil
    var pingMs: Double? = nil
}

/// Session de couverture iOS à téléverser (`POST /api/coverage/session/import-ios`).
struct CoverageSessionUpload: Encodable, Sendable {
    var name: String? = nil
    let startTime: Int
    let endTime: Int
    var device: String? = nil
    var mcc: Int? = nil
    var mnc: Int? = nil
    var operatorKey: String? = nil
    var marketCode: String? = nil
    var showOnMap: Bool
    let points: [CoveragePointUpload]
}

/// Accès aux sessions/logs de mesure de l'utilisateur (synchronisées côté
/// serveur, donc visibles ici même si enregistrées sur Android).
protocol SessionsServicing: Sendable {
    func sessions(offset: Int, limit: Int) async throws -> SessionsListResponse
    func sessionDetail(id: String) async throws -> CoverageSessionDetail
    /// Téléverse une session de couverture iOS (F1). Best-effort côté appelant.
    func createCoverageSession(_ session: CoverageSessionUpload) async throws
}

final class SessionsService: SessionsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func createCoverageSession(_ session: CoverageSessionUpload) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/coverage/session/import-ios", body: session)
    }

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
