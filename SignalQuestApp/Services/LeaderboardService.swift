import Foundation

protocol LeaderboardServicing: Sendable {
    func leaderboard(period: String, scope: String, category: String) async throws -> LeaderboardResult
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
}

