import Foundation

struct LeaderboardResult: Codable, Equatable {
    let category: String
    let period: String
    let scope: String
    let entries: [LeaderboardEntry]
    let myRank: LeaderboardMyRank?
    let generatedAt: Date?
    let requestId: String?
}

struct LeaderboardEntry: Codable, Identifiable, Equatable {
    let rank: Int
    let user: SocialFeedAuthor
    let value: Double
    let unit: String
    let detail: String?
    let tech: String?
    let `operator`: String?
    let city: String?
    let capturedAt: Date?

    enum CodingKeys: String, CodingKey {
        case rank, user, value, unit, detail, tech, city, capturedAt
        case `operator` = "operator"
    }

    var id: String { "\(rank)-\(user.id)-\(categoryHint)" }
    private var categoryHint: String { unit }

    var isProbablyIOS: Bool {
        let lowered = [detail, tech].compactMap { $0?.lowercased() }.joined(separator: " ")
        return lowered.contains("ios") || lowered.contains("iphone")
    }
}

struct LeaderboardMyRank: Codable, Equatable {
    let rank: Int
    let total: Int
    let entry: LeaderboardEntry?
}

