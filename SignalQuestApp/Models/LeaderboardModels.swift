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

// MARK: - Classement points / niveaux

/// Réponse de `GET /api/gamification/leaderboard` : classement communautaire
/// par points de gamification (le backend fusionne points legacy et XP v2 en
/// prenant le max des deux).
struct PointsLeaderboardResult: Decodable, Equatable {
    let scope: String
    let period: String
    let entries: [PointsLeaderboardEntry]
    let currentUserRank: Int?

    enum CodingKeys: String, CodingKey { case scope, period, leaderboard, entries, currentUserRank }

    init(scope: String, period: String, entries: [PointsLeaderboardEntry], currentUserRank: Int?) {
        self.scope = scope
        self.period = period
        self.entries = entries
        self.currentUserRank = currentUserRank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = c.decodeFlexibleString(forKey: .scope) ?? "global"
        period = c.decodeFlexibleString(forKey: .period) ?? "all"
        let list = c.decodeLossyArray([PointsLeaderboardEntry].self, forKey: .leaderboard)
        entries = list.isEmpty ? c.decodeLossyArray([PointsLeaderboardEntry].self, forKey: .entries) : list
        currentUserRank = try? c.decodeIfPresent(Int.self, forKey: .currentUserRank)
    }
}

struct PointsLeaderboardEntry: Decodable, Identifiable, Equatable {
    let rank: Int
    let userId: String?
    let name: String?
    let avatarUrl: URL?
    let points: Int?
    let periodPoints: Int?
    let level: Int?
    let badges: [String]
    let stats: PointsLeaderboardStats?

    enum CodingKeys: String, CodingKey { case rank, userId, id, name, avatarUrl, points, periodPoints, level, badges, stats }

    var id: String { userId ?? "rank-\(rank)" }
    var displayName: String { name ?? "Membre" }

    /// Score pertinent pour la période affichée : points de la période quand le
    /// backend les fournit, cumul sinon.
    func score(for period: String) -> Int {
        if period == "all" { return points ?? periodPoints ?? 0 }
        return periodPoints ?? points ?? 0
    }

    init(
        rank: Int,
        userId: String?,
        name: String?,
        avatarUrl: URL?,
        points: Int?,
        periodPoints: Int?,
        level: Int?,
        badges: [String] = [],
        stats: PointsLeaderboardStats? = nil
    ) {
        self.rank = rank
        self.userId = userId
        self.name = name
        self.avatarUrl = avatarUrl
        self.points = points
        self.periodPoints = periodPoints
        self.level = level
        self.badges = badges
        self.stats = stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = (try? c.decode(Int.self, forKey: .rank)) ?? 0
        userId = c.decodeFlexibleString(forKey: .userId) ?? c.decodeFlexibleString(forKey: .id)
        name = c.decodeFlexibleString(forKey: .name)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        points = try? c.decodeIfPresent(Int.self, forKey: .points)
        periodPoints = try? c.decodeIfPresent(Int.self, forKey: .periodPoints)
        level = try? c.decodeIfPresent(Int.self, forKey: .level)
        badges = (try? c.decodeIfPresent([String].self, forKey: .badges)) ?? []
        stats = try? c.decodeIfPresent(PointsLeaderboardStats.self, forKey: .stats)
    }
}

struct PointsLeaderboardStats: Decodable, Equatable {
    let validations: Int?
    let photos: Int?
    let speedtests: Int?
    let badges: Int?
}

