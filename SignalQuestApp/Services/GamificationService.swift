import Foundation

struct GamificationProfile: Decodable, Equatable {
    let level: Int?
    let points: Int?
    let xpToNextLevel: Int?
    let consecutiveDays: Int?
    let badges: [GamificationBadge]

    enum CodingKeys: String, CodingKey {
        case profile, level, points, xpToNextLevel, pointsToNextLevel, nextLevelAt, consecutiveDays, badges
    }

    init(level: Int?, points: Int?, xpToNextLevel: Int?, consecutiveDays: Int?, badges: [GamificationBadge]) {
        self.level = level
        self.points = points
        self.xpToNextLevel = xpToNextLevel
        self.consecutiveDays = consecutiveDays
        self.badges = badges
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
                badges: nested.badges.isEmpty ? rootBadges : nested.badges
            )
            return
        }
        level = try root.decodeIfPresent(Int.self, forKey: .level)
        points = try root.decodeIfPresent(Int.self, forKey: .points)
        xpToNextLevel = (try? root.decodeIfPresent(Int.self, forKey: .xpToNextLevel))
            ?? (try? root.decodeIfPresent(Int.self, forKey: .pointsToNextLevel))
            ?? (try? root.decodeIfPresent(Int.self, forKey: .nextLevelAt)).flatMap { target in
                guard let current = try? root.decodeIfPresent(Int.self, forKey: .points) else { return nil }
                return max(0, target - current)
            }
        consecutiveDays = try root.decodeIfPresent(Int.self, forKey: .consecutiveDays)
        badges = root.decodeLossyArray([GamificationBadge].self, forKey: .badges)
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

    enum CodingKeys: String, CodingKey { case id, title, name, description, iconUrl, icon, unlockedAt, tier }

    init(id: String, title: String?, description: String?, iconUrl: URL?, icon: String? = nil, unlockedAt: Date?, tier: String?) {
        self.id = id
        self.title = title
        self.description = description
        self.iconUrl = iconUrl
        self.icon = icon
        self.unlockedAt = unlockedAt
        self.tier = tier
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
    func claimEasterEgg(eggId: String) async throws
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

    func claimEasterEgg(eggId: String) async throws {
        // Le backend valide la clé `eggId` (et NON `code`) contre sa liste d'eggs.
        let _: SuccessResponse = try await api.requestJSON("/api/gamification/easter-eggs/claim", body: ["eggId": eggId])
    }
}
