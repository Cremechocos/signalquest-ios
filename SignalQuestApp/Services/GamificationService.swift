import Foundation

struct GamificationProfile: Decodable, Equatable {
    let level: Int?
    let points: Int?
    /// Ancien champ « taille du palier » : lu seulement s'il est présent.
    let xpToNextLevel: Int?
    let consecutiveDays: Int?
    let badges: [GamificationBadge]
    /// Points RESTANT à gagner avant le prochain niveau (`pointsToNextLevel`).
    let pointsToNextLevel: Int?
    /// Total de points qui ouvre le prochain niveau.
    let nextLevelAt: Int?
    /// Avancement dans le niveau courant, de 0 à 100.
    let levelProgress: Double?

    enum CodingKeys: String, CodingKey {
        case profile, level, points, xpToNextLevel, pointsToNextLevel, nextLevelAt, levelProgress, consecutiveDays, badges
    }

    init(
        level: Int?, points: Int?, xpToNextLevel: Int?, consecutiveDays: Int?, badges: [GamificationBadge],
        pointsToNextLevel: Int? = nil, nextLevelAt: Int? = nil, levelProgress: Double? = nil
    ) {
        self.level = level
        self.points = points
        self.xpToNextLevel = xpToNextLevel
        self.consecutiveDays = consecutiveDays
        self.badges = badges
        self.pointsToNextLevel = pointsToNextLevel
        self.nextLevelAt = nextLevelAt
        self.levelProgress = levelProgress
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        if root.contains(.profile), let nested = try? root.decode(GamificationProfile.self, forKey: .profile) {
            let rootBadges = root.decodeLossyArray([GamificationBadge].self, forKey: .badges)
            self = GamificationProfile(
                level: nested.level,
                points: nested.points,
                xpToNextLevel: nested.xpToNextLevel,
                consecutiveDays: nested.consecutiveDays,
                badges: nested.badges.isEmpty ? rootBadges : nested.badges,
                pointsToNextLevel: nested.pointsToNextLevel,
                nextLevelAt: nested.nextLevelAt,
                levelProgress: nested.levelProgress
            )
            return
        }
        level = try root.decodeIfPresent(Int.self, forKey: .level)
        points = try root.decodeIfPresent(Int.self, forKey: .points)
        xpToNextLevel = try? root.decodeIfPresent(Int.self, forKey: .xpToNextLevel)
        pointsToNextLevel = try? root.decodeIfPresent(Int.self, forKey: .pointsToNextLevel)
        nextLevelAt = try? root.decodeIfPresent(Int.self, forKey: .nextLevelAt)
        levelProgress = try? root.decodeIfPresent(Double.self, forKey: .levelProgress)
        consecutiveDays = try root.decodeIfPresent(Int.self, forKey: .consecutiveDays)
        badges = root.decodeLossyArray([GamificationBadge].self, forKey: .badges)
    }

    /// Points restant à gagner : la valeur du serveur, sinon `nextLevelAt - points`,
    /// sinon (ancien champ) le complément de `points` dans le palier.
    var pointsRemaining: Int? {
        if let pointsToNextLevel { return max(0, pointsToNextLevel) }
        if let nextLevelAt, let points { return max(0, nextLevelAt - points) }
        if let xpToNextLevel, xpToNextLevel > 0, let points { return xpToNextLevel - (points % xpToNextLevel) }
        return nil
    }

    /// Avancement dans le niveau, de 0 à 1 : `levelProgress / 100` du serveur ;
    /// l'ancien champ `xpToNextLevel` ne sert que s'il est seul présent.
    var levelFraction: Double? {
        if let levelProgress { return min(1, max(0, levelProgress / 100)) }
        if let xpToNextLevel, xpToNextLevel > 0, let points {
            return min(1, Double(points % xpToNextLevel) / Double(xpToNextLevel))
        }
        return nil
    }
}

struct GamificationBadge: Decodable, Identifiable, Equatable {
    let id: String
    let title: String?
    let description: String?
    let iconUrl: URL?
    let icon: String?
    let unlockedAt: Date?
    let tier: String?
    /// Famille et rareté du catalogue serveur, quand la réponse les porte.
    let category: String?
    let rarity: String?

    enum CodingKeys: String, CodingKey { case id, title, name, description, iconUrl, icon, unlockedAt, tier, category, rarity }

    init(
        id: String, title: String?, description: String?, iconUrl: URL?, icon: String? = nil,
        unlockedAt: Date?, tier: String?, category: String? = nil, rarity: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconUrl = iconUrl
        self.icon = icon
        self.unlockedAt = unlockedAt
        self.tier = tier
        self.category = category
        self.rarity = rarity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        title = c.decodeFlexibleString(forKey: .title) ?? c.decodeFlexibleString(forKey: .name)
        description = c.decodeFlexibleString(forKey: .description)
        iconUrl = c.decodeLossyURL(forKey: .iconUrl)
        icon = c.decodeFlexibleString(forKey: .icon)
        unlockedAt = try c.decodeIfPresent(Date.self, forKey: .unlockedAt)
        tier = c.decodeFlexibleString(forKey: .tier)
        category = c.decodeFlexibleString(forKey: .category)
        rarity = c.decodeFlexibleString(forKey: .rarity)
    }
}

struct GamificationEvent: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String?
    let pointsDelta: Int?
    let createdAt: Date?
    let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey { case id, kind, type, pointsDelta, points, createdAt, metadata }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        kind = c.decodeFlexibleString(forKey: .kind) ?? c.decodeFlexibleString(forKey: .type)
        pointsDelta = (try? c.decodeIfPresent(Int.self, forKey: .pointsDelta))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .points))
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }
}

protocol GamificationServicing: Sendable {
    func profile() async throws -> GamificationProfile
    func catalog() async throws -> [GamificationBadge]
    func events() async throws -> [GamificationEvent]
    /// Grille de territoires sur une bbox. Le serveur agrège en SQL et complète
    /// les cellules vides — c'est lui qui décide de la taille de maille.
    func territories(
        south: Double, west: Double, north: Double, east: Double,
        marketCode: String?, operatorKey: String?
    ) async throws -> TerritoryGrid
}

final class GamificationService: GamificationServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func profile() async throws -> GamificationProfile {
        try await api.request(APIEndpoint(path: "/api/gamification/profile"), as: GamificationProfile.self)
    }

    func catalog() async throws -> [GamificationBadge] {
        struct Response: Decodable { let badges: [GamificationBadge]?; let items: [GamificationBadge]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/gamification/catalog"), as: Response.self)
        return r.badges ?? r.items ?? []
    }

    func events() async throws -> [GamificationEvent] {
        struct Response: Decodable { let events: [GamificationEvent]?; let items: [GamificationEvent]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/gamification/events"), as: Response.self)
        return r.events ?? r.items ?? []
    }

    func territories(
        south: Double, west: Double, north: Double, east: Double,
        marketCode: String?, operatorKey: String?
    ) async throws -> TerritoryGrid {
        var query = [
            // Le serveur accepte aussi north/south/east/west séparés ; `bbox`
            // est plus court et c'est la forme documentée.
            URLQueryItem(name: "bbox", value: "\(west),\(south),\(east),\(north)")
        ]
        if let marketCode, !marketCode.isEmpty {
            query.append(URLQueryItem(name: "marketCode", value: marketCode))
        }
        if let operatorKey, !operatorKey.isEmpty {
            query.append(URLQueryItem(name: "operatorKey", value: operatorKey))
        }
        return try await api.request(
            APIEndpoint(path: "/api/gamification/v2/territories", query: query),
            as: TerritoryGrid.self
        )
    }
}
