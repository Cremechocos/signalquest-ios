import Foundation

/// Alertes de panne près de ses lieux (plan 3, vague 2) :
/// `GET` et `PUT /api/user/zones/preferences`. Le serveur prévient quand la
/// communauté signale une panne près d'un lieu enregistré (les zones de
/// Confidentialité), selon ces réglages.
struct ZoneAlertSettings: Decodable, Equatable {
    var preferences: ZoneAlertPreferences
    let capabilities: Capabilities

    struct Capabilities: Decodable, Equatable {
        let supportedOperators: [String]
        let notificationRadiusOptionsMeters: [Int]
    }

    static let demo = ZoneAlertSettings(
        preferences: ZoneAlertPreferences(
            notifyAntennaDown: true, notifyDegraded: false, quietHoursStart: 22, quietHoursEnd: 7,
            maxNotificationsPerDay: 5, notificationRadiusMeters: 5_000, watchedOperators: ["ORANGE"]
        ),
        capabilities: Capabilities(
            supportedOperators: ["SFR", "BOUYGUES", "ORANGE", "FREE"],
            notificationRadiusOptionsMeters: [1_000, 3_000, 5_000, 10_000]
        )
    )
}

struct ZoneAlertPreferences: Decodable, Equatable {
    var notifyAntennaDown: Bool
    var notifyDegraded: Bool
    var quietHoursStart: Int?
    var quietHoursEnd: Int?
    var maxNotificationsPerDay: Int
    var notificationRadiusMeters: Int
    var watchedOperators: [String]

    /// Règle du serveur : deux opérateurs surveillés au plus.
    static let maxWatchedOperators = 2
    static let maxPerDayRange = 1...50
}

/// Un réglage à la fois, enregistré au geste. Le serveur refuse toute clé
/// qu'il ne connaît pas, et les heures calmes s'effacent par un `null` explicite.
enum ZoneAlertChange: Equatable, Encodable {
    case notifyAntennaDown(Bool)
    case notifyDegraded(Bool)
    case radius(Int)
    case maxPerDay(Int)
    case watchedOperators([String])
    case quietHours(start: Int, end: Int)
    case quietHoursOff

    private enum Keys: String, CodingKey {
        case notifyAntennaDown, notifyDegraded, notificationRadiusMeters, maxNotificationsPerDay
        case watchedOperators, quietHoursStart, quietHoursEnd
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .notifyAntennaDown(let value): try container.encode(value, forKey: .notifyAntennaDown)
        case .notifyDegraded(let value): try container.encode(value, forKey: .notifyDegraded)
        case .radius(let meters): try container.encode(meters, forKey: .notificationRadiusMeters)
        case .maxPerDay(let count): try container.encode(count, forKey: .maxNotificationsPerDay)
        case .watchedOperators(let keys): try container.encode(keys, forKey: .watchedOperators)
        case .quietHours(let start, let end):
            try container.encode(start, forKey: .quietHoursStart)
            try container.encode(end, forKey: .quietHoursEnd)
        case .quietHoursOff:
            try container.encodeNil(forKey: .quietHoursStart)
            try container.encodeNil(forKey: .quietHoursEnd)
        }
    }

    /// Le réglage tel qu'il s'affiche avant la réponse du serveur.
    func applied(to preferences: ZoneAlertPreferences) -> ZoneAlertPreferences {
        var updated = preferences
        switch self {
        case .notifyAntennaDown(let value): updated.notifyAntennaDown = value
        case .notifyDegraded(let value): updated.notifyDegraded = value
        case .radius(let meters): updated.notificationRadiusMeters = meters
        case .maxPerDay(let count): updated.maxNotificationsPerDay = count
        case .watchedOperators(let keys): updated.watchedOperators = keys
        case .quietHours(let start, let end):
            updated.quietHoursStart = start
            updated.quietHoursEnd = end
        case .quietHoursOff:
            updated.quietHoursStart = nil
            updated.quietHoursEnd = nil
        }
        return updated
    }
}

struct ZoneAlertService: Sendable {
    let api: APIClient

    func settings() async throws -> ZoneAlertSettings {
        if AppEnvironment.usesDemoData { return .demo }
        return try await api.request(APIEndpoint(path: "/api/user/zones/preferences"), as: ZoneAlertSettings.self)
    }

    func apply(_ change: ZoneAlertChange, to current: ZoneAlertSettings) async throws -> ZoneAlertSettings {
        if AppEnvironment.usesDemoData {
            var updated = current
            updated.preferences = change.applied(to: current.preferences)
            return updated
        }
        return try await api.requestJSON("/api/user/zones/preferences", method: .put, body: change)
    }
}
