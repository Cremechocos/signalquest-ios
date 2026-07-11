import Foundation

protocol LeaderboardServicing: Sendable {
    func leaderboard(period: String, scope: String, category: String) async throws -> LeaderboardResult
    func pointsLeaderboard(period: String, scope: String) async throws -> PointsLeaderboardResult
}

final class LeaderboardService: LeaderboardServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func leaderboard(period: String = "week", scope: String = "global", category: String = "download") async throws -> LeaderboardResult {
        try await api.request(
            APIEndpoint(
                path: "/api/social/leaderboards",
                query: [
                    URLQueryItem(name: "period", value: period),
                    URLQueryItem(name: "scope", value: scope),
                    URLQueryItem(name: "category", value: category)
                ]
            ),
            as: LeaderboardResult.self
        )
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
