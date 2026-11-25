import Foundation

/// Filtres du classement v1 (download et upload seulement ; le serveur les ignore pour points).
struct LeaderboardFilters: Equatable, Sendable {
    /// Clé canonique : `SFR`, `BOUYGUES`, `ORANGE` ou `FREE`.
    var operatorKey: String?
    /// `5G` (SA et NSA) ou `4G`.
    var tech: String?

    static let none = LeaderboardFilters()
}

protocol LeaderboardServicing: Sendable {
    /// `GET /api/social/leaderboards` : download, upload et points (XP), portée globale, amis
    /// ou département (le mien quand aucun code n'est donné).
    func leaderboard(period: String, scope: String, category: String, filters: LeaderboardFilters) async throws -> LeaderboardResult
    /// Classement des points de gamification, lu par l'Accueil et le Profil (« 3e de tes amis »).
    func pointsLeaderboard(period: String, scope: String) async throws -> PointsLeaderboardResult
}

extension LeaderboardServicing {
    func leaderboard(period: String, scope: String, category: String) async throws -> LeaderboardResult {
        try await leaderboard(period: period, scope: scope, category: category, filters: .none)
    }
}

final class LeaderboardService: LeaderboardServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func leaderboard(period: String, scope: String, category: String, filters: LeaderboardFilters) async throws -> LeaderboardResult {
        try await api.request(
            APIEndpoint(path: "/api/social/leaderboards",
                        query: Self.query(period: period, scope: scope, category: category, filters: filters)),
            as: LeaderboardResult.self
        )
    }

    /// Paramètres de la requête. Les filtres ne partent que pour les débits : le serveur les
    /// ignore pour points, autant ne pas les envoyer.
    static func query(period: String, scope: String, category: String, filters: LeaderboardFilters) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "category", value: category)
        ]
        if category == "download" || category == "upload" {
            if let op = filters.operatorKey { items.append(URLQueryItem(name: "operator", value: op)) }
            if let tech = filters.tech { items.append(URLQueryItem(name: "tech", value: tech)) }
        }
        return items
    }

    func pointsLeaderboard(period: String = "week", scope: String = "global") async throws -> PointsLeaderboardResult {
        // L'endpoint gamification attend weekly/monthly/all (≠ social qui parle
        // week/month/all) : on traduit pour partager le même état de filtre.
        let gamificationPeriod: String
        switch period {
        case "week": gamificationPeriod = "weekly"
        case "month": gamificationPeriod = "monthly"
        default: gamificationPeriod = "all"
        }
        return try await api.request(
            APIEndpoint(
                path: "/api/gamification/leaderboard",
                query: [
                    URLQueryItem(name: "period", value: gamificationPeriod),
                    URLQueryItem(name: "scope", value: scope),
                    URLQueryItem(name: "limit", value: "50")
                ]
            ),
            as: PointsLeaderboardResult.self
        )
    }
}
