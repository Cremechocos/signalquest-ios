import Foundation

/// Signalement communautaire de pannes.
///
/// Trois gestes seulement : lire les pannes d'un site, en signaler une, se prononcer sur une
/// existante. La machine à états, les seuils et les points vivent entièrement côté serveur — le
/// client n'en réimplémente rien, il affiche ce qu'on lui rend.
protocol CommunityOutageServicing: Sendable {
    func outages(forSiteId siteId: String, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage]
    func feed(scope: OutageFeedScope, offset: Int, limit: Int) async throws -> (outages: [CommunityOutage], hasMore: Bool)
    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse
    func vote(outageId: String, kind: String, latitude: Double?, longitude: Double?, accuracyMeters: Double?) async throws -> OutageWriteResponse
}

final class CommunityOutageService: CommunityOutageServicing {
    private let api: APIClient

    init(api: APIClient) { self.api = api }

    /// Les pannes ouvertes d'un site.
    ///
    /// Jamais mise en cache : `myVote` et `canVote` dépendent de la personne connectée, et un
    /// cache ferait proposer « Confirmer » à quelqu'un qui a déjà voté.
    func outages(
        forSiteId siteId: String,
        marketCode: String,
        operatorKey: String?
    ) async throws -> [CommunityOutage] {
        var query = [
            URLQueryItem(name: "targetKey", value: "anfr:\(siteId)"),
            URLQueryItem(name: "marketCode", value: marketCode),
        ]
        if let operatorKey, !operatorKey.isEmpty, operatorKey != "ALL" {
            query.append(URLQueryItem(name: "operatorKey", value: operatorKey))
        }
        let response: CommunityOutagesResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages", method: .get, query: query),
            as: CommunityOutagesResponse.self
        )
        return response.outages
    }

    /// La liste paginée, pour la page « Pannes signalées » du profil.
    ///
    /// `mine` retient les pannes où l'on a mis quelque chose — signalée OU arbitrée. Quelqu'un
    /// qui a confirmé dix pannes a contribué autant que celui qui en a signalé une, et sa page
    /// doit le lui montrer.
    func feed(
        scope: OutageFeedScope,
        offset: Int,
        limit: Int
    ) async throws -> (outages: [CommunityOutage], hasMore: Bool) {
        var query = [
            URLQueryItem(name: "scope", value: scope == .mine ? "mine" : "all"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // « Les miennes » garde une mémoire : une panne rétablie reste quelque chose qu'on a
        // fait, la masquer donnerait l'impression d'avoir contribué moins qu'en réalité.
        if scope == .mine {
            query.append(URLQueryItem(name: "includeClosed", value: "true"))
        }
        let response: CommunityOutagesResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages", method: .get, query: query),
            as: CommunityOutagesResponse.self
        )
        return (response.outages, response.hasMore ?? false)
    }

    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse {
        try await write(path: "/api/community-outages", body: request)
    }

    func vote(
        outageId: String,
        kind: String,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?
    ) async throws -> OutageWriteResponse {
        try await write(
            path: "/api/community-outages/\(outageId)/vote",
            body: OutageVoteRequest(
                kind: kind,
                latitude: latitude,
                longitude: longitude,
                accuracyMeters: accuracyMeters
            )
        )
    }

    /// Envoi commun.
    ///
    /// Aucune traduction d'erreur ici : `APIError.http` porte déjà le `code` et le `message` du
    /// serveur, et son `errorDescription` privilégie ce message — qui est justement rédigé en
    /// français côté API (« Vous êtes trop loin de ce site », « Vous ne pouvez pas confirmer
    /// votre propre signalement »). Une couche de refus maison par-dessus aurait dupliqué ce
    /// travail, et surtout risqué de l'appauvrir.
    private func write<Body: Encodable>(path: String, body: Body) async throws -> OutageWriteResponse {
        try await api.requestJSON(path, method: .post, body: body)
    }
}
