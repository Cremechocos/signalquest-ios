import Foundation

struct LeaderboardResult: Codable, Equatable {
    let category: String
    let period: String
    let scope: String
    let entries: [LeaderboardEntry]
    let myRank: LeaderboardMyRank?
    let generatedAt: Date?
    let requestId: String?
    /// Département classé, servi seulement avec `scope=department` (contrat classements v1).
    let department: LeaderboardDepartment?

    enum CodingKeys: String, CodingKey {
        case category, period, scope, entries, myRank, generatedAt, requestId, department
    }

    init(category: String, period: String, scope: String, entries: [LeaderboardEntry], myRank: LeaderboardMyRank?,
         generatedAt: Date?, requestId: String?, department: LeaderboardDepartment? = nil) {
        self.category = category
        self.period = period
        self.scope = scope
        self.entries = entries
        self.myRank = myRank
        self.generatedAt = generatedAt
        self.requestId = requestId
        self.department = department
    }

    // Décodage défensif aligné sur le classement « points » : une entrée malformée
    // ou une date non parsable ne doit pas faire échouer TOUT le classement (ROB-05).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = c.decodeFlexibleString(forKey: .category) ?? "download"
        period = c.decodeFlexibleString(forKey: .period) ?? "all"
        scope = c.decodeFlexibleString(forKey: .scope) ?? "global"
        entries = c.decodeLossyElementArray([LeaderboardEntry].self, forKey: .entries)
        myRank = try? c.decodeIfPresent(LeaderboardMyRank.self, forKey: .myRank)
        generatedAt = try? c.decodeIfPresent(Date.self, forKey: .generatedAt)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        department = try? c.decodeIfPresent(LeaderboardDepartment.self, forKey: .department)
    }
}

struct LeaderboardDepartment: Codable, Equatable {
    let code: String
    let name: String?
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
    /// Test classé, pour ouvrir son détail ; `nil` pour les points ou un test retiré de la carte.
    let speedtestId: String?

    enum CodingKeys: String, CodingKey {
        case rank, user, value, unit, detail, tech, city, capturedAt, speedtestId
        case `operator` = "operator"
    }

    init(rank: Int, user: SocialFeedAuthor, value: Double, unit: String, detail: String?, tech: String?,
         operator: String?, city: String?, capturedAt: Date?, speedtestId: String? = nil) {
        self.rank = rank
        self.user = user
        self.value = value
        self.unit = unit
        self.detail = detail
        self.tech = tech
        self.operator = `operator`
        self.city = city
        self.capturedAt = capturedAt
        self.speedtestId = speedtestId
    }

    // Les champs ajoutés par le contrat v1 sont lus sans échec : une valeur malformée ne
    // doit jamais faire tomber l'entrée (décodage défensif ROB-05).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = try c.decode(Int.self, forKey: .rank)
        user = try c.decode(SocialFeedAuthor.self, forKey: .user)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        tech = try? c.decodeIfPresent(String.self, forKey: .tech)
        `operator` = try? c.decodeIfPresent(String.self, forKey: .operator)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        speedtestId = c.decodeFlexibleString(forKey: .speedtestId)
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
    /// Écart avec le rang juste au-dessus, dans l'unité des entrées ; `nil` au 1er rang.
    let gapToNext: LeaderboardGap?
    /// Mon rang sans les contributions d'aujourd'hui (jour de Paris) ; `nil` si je n'étais pas classé.
    let previousRank: Int?

    enum CodingKeys: String, CodingKey { case rank, total, entry, gapToNext, previousRank }

    init(rank: Int, total: Int, entry: LeaderboardEntry?, gapToNext: LeaderboardGap? = nil, previousRank: Int? = nil) {
        self.rank = rank
        self.total = total
        self.entry = entry
        self.gapToNext = gapToNext
        self.previousRank = previousRank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = try c.decode(Int.self, forKey: .rank)
        total = try c.decode(Int.self, forKey: .total)
        entry = try? c.decodeIfPresent(LeaderboardEntry.self, forKey: .entry)
        gapToNext = try? c.decodeIfPresent(LeaderboardGap.self, forKey: .gapToNext)
        previousRank = try? c.decodeIfPresent(Int.self, forKey: .previousRank)
    }

    /// Places gagnées depuis hier ; `nil` quand rien n'est gagné (le contrat ne montre que N > 0).
    var placesGained: Int? {
        guard let previousRank else { return nil }
        let gained = previousRank - rank
        return gained > 0 ? gained : nil
    }
}

struct LeaderboardGap: Codable, Equatable {
    let value: Double
    let unit: String
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
    /// Nom d'utilisateur, servi seulement si le membre a choisi de le montrer au classement.
    let handle: String?
    let avatarUrl: URL?
    let points: Int?
    let periodPoints: Int?
    let level: Int?
    let badges: [String]
    let stats: PointsLeaderboardStats?

    enum CodingKeys: String, CodingKey { case rank, userId, id, name, handle, avatarUrl, points, periodPoints, level, badges, stats }

    var id: String { userId ?? "rank-\(rank)" }
    /// Avec l'option « nom d'utilisateur au classement », le serveur met aussi le handle dans
    /// `name`, pour les anciens clients : il se lit alors « @handle ». Sans nom ni handle
    /// visible, « Quelqu'un ».
    var displayName: String { MemberIdentity.displayName(name == handle ? nil : name, handle: handle) }

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
        handle: String? = nil,
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
        self.handle = handle
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
        handle = c.decodeFlexibleString(forKey: .handle)
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

