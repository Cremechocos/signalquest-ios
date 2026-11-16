import Foundation

/// Bilan mensuel (contrat Abonnements v1.20 §3, `recap.monthly`, D13), tel que servi par
/// `GET /api/me/recap/{yyyy-mm}`. Valeurs brutes : mètres, bit/s, dates ISO 8601 avec le
/// décalage du fuseau du Bilan. Aucun texte : l'app écrit ses phrases à partir des clés du
/// récit. Une valeur sans donnée vaut `null` et sa ligne disparaît, jamais un « 0 ».
///
/// Décodage tolérant, bloc par bloc : un bloc mal formé tombe seul, le reste du Bilan s'affiche.
struct MonthlyRecap: Codable, Equatable, Sendable {
    struct Period: Codable, Equatable, Sendable {
        let start: String
        let end: String
    }

    /// Une phrase du récit : sa clé et ses paramètres. Une clé inconnue est ignorée.
    struct StoryEntry: Codable, Equatable, Sendable {
        let key: String
        let params: [String: JSONValue]

        func number(_ name: String) -> Double? {
            guard case .number(let value)? = params[name], value.isFinite else { return nil }
            return value
        }

        func text(_ name: String) -> String? {
            guard case .string(let value)? = params[name] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct Field: Codable, Equatable, Sendable {
        struct LongestSession: Codable, Equatable, Sendable {
            let distanceM: Double
            let at: String
        }
        let sessions: Int
        let distanceM: Double?
        let longestSession: LongestSession?
    }

    struct Measures: Codable, Equatable, Sendable {
        struct BestDownload: Codable, Equatable, Sendable {
            let bps: Double
            let operatorKey: String?
            let generation: String?
            let at: String
            /// Commune du record : la page seulement, jamais l'image ni l'e-mail.
            let nearPlace: String?
        }
        struct TopNetwork: Codable, Equatable, Sendable {
            let operatorKey: String
            let speedtests: Int
        }
        /// Tous les speedtests, Wi-Fi compris.
        let speedtests: Int
        /// Médiane, record et réseau : speedtests en données mobiles seulement.
        let medianDownloadBps: Double?
        let bestDownload: BestDownload?
        let topNetwork: TopNetwork?
    }

    struct Contributions: Codable, Equatable, Sendable {
        let identifications: Int?
        let firstIdentifications: Int?
        let photos: Int?
        let outagesReported: Int?
    }

    struct Progress: Codable, Equatable, Sendable {
        struct Rank: Codable, Equatable, Sendable {
            let position: Int
            let marketCode: String?
        }
        struct Badge: Codable, Equatable, Sendable {
            let id: String
        }
        let points: Int?
        let rank: Rank?
        let longestStreakDays: Int?
        let badges: [Badge]
    }

    struct ActiveDays: Codable, Equatable, Sendable {
        struct Day: Codable, Equatable, Sendable {
            let date: String
            let intensity: Int
        }
        let daysInMonth: Int
        let days: [Day]
    }

    /// Le Bilan du mois précédent, pour la comparaison ; `null` sans Bilan précédent.
    struct Previous: Codable, Equatable, Sendable {
        let month: String
        let distanceM: Double?
        let speedtests: Int?
        let identifications: Int?
        let rankPosition: Int?
    }

    let month: String
    let timeZone: String?
    let period: Period?
    let frozenAt: String?
    let story: [StoryEntry]
    let field: Field?
    let measures: Measures?
    let contributions: Contributions?
    let progress: Progress?
    let activeDays: ActiveDays?
    let previous: Previous?

    init(month: String, timeZone: String?, period: Period?, frozenAt: String?, story: [StoryEntry],
         field: Field?, measures: Measures?, contributions: Contributions?, progress: Progress?,
         activeDays: ActiveDays?, previous: Previous?) {
        self.month = month
        self.timeZone = timeZone
        self.period = period
        self.frozenAt = frozenAt
        self.story = story
        self.field = field
        self.measures = measures
        self.contributions = contributions
        self.progress = progress
        self.activeDays = activeDays
        self.previous = previous
    }

    private enum CodingKeys: String, CodingKey {
        case month, timeZone, period, frozenAt, story, field, measures, contributions, progress, activeDays, previous
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        timeZone = try? c.decodeIfPresent(String.self, forKey: .timeZone)
        period = try? c.decodeIfPresent(Period.self, forKey: .period)
        frozenAt = try? c.decodeIfPresent(String.self, forKey: .frozenAt)
        // Une entrée mal formée tombe seule, les autres restent.
        let rawStory = (try? c.decodeIfPresent([JSONValue].self, forKey: .story)) ?? []
        story = rawStory.compactMap { value in
            guard case .object(let object) = value, case .string(let key)? = object["key"] else { return nil }
            if case .object(let params)? = object["params"] { return StoryEntry(key: key, params: params) }
            return StoryEntry(key: key, params: [:])
        }
        field = try? c.decodeIfPresent(Field.self, forKey: .field)
        measures = try? c.decodeIfPresent(Measures.self, forKey: .measures)
        contributions = try? c.decodeIfPresent(Contributions.self, forKey: .contributions)
        progress = try? c.decodeIfPresent(Progress.self, forKey: .progress)
        activeDays = try? c.decodeIfPresent(ActiveDays.self, forKey: .activeDays)
        previous = try? c.decodeIfPresent(Previous.self, forKey: .previous)
    }
}

/// Un des 12 derniers mois clos (`GET /api/me/recap`) ; `available: false` = mois sans activité.
struct MonthlyRecapMonth: Codable, Equatable, Hashable, Sendable {
    let month: String
    let available: Bool
}

struct MonthlyRecapMonthList: Decodable {
    let months: [MonthlyRecapMonth]

    private enum CodingKeys: String, CodingKey { case months }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .months)) ?? []
        // Du plus récent au plus ancien, comme le serveur ; un mois mal formé est ignoré.
        months = raw.compactMap { value in
            guard case .object(let object) = value, case .string(let month)? = object["month"],
                  MonthlyRecapLink.isMonth(month) else { return nil }
            if case .bool(let available)? = object["available"] { return MonthlyRecapMonth(month: month, available: available) }
            return nil
        }
    }
}

/// Lien du Bilan : `/profile/bilan/{yyyy-mm}` (notification `recap.ready`, lien universel,
/// cloche). Le mois seul est repris, après contrôle de sa forme.
enum MonthlyRecapLink {
    static func isMonth(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 7, parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let month = Int(parts[1]) else { return false }
        return (1...12).contains(month)
    }

    /// Mois d'un lien universel `https://<site>/profile/bilan/{yyyy-mm}`.
    static func month(from url: URL, appOrigin: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == appOrigin.host?.lowercased(),
              components.port == appOrigin.port else { return nil }
        return month(fromPath: url.path)
    }

    /// Mois d'un chemin `/profile/bilan/{yyyy-mm}` (le `link` d'une entrée de la cloche).
    static func month(fromPath path: String) -> String? {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = bare.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "profile", parts[1] == "bilan", isMonth(parts[2]) else { return nil }
        return parts[2]
    }
}
