import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Formatters de date partagés, créés **une seule fois**.
///
/// PERF-DEC-01 : l'ancienne stratégie de décodage instanciait jusqu'à 5
/// `DateFormatter`/`ISO8601DateFormatter` **par champ date décodé** — soit des
/// dizaines de milliers d'allocations sur un tableau de plusieurs milliers
/// d'éléments (carte par tuile, feed, ANFR, messages). Ces formatters sont
/// configurés à l'initialisation puis **seulement lus** (parsing). `DateFormatter`
/// est thread-safe depuis iOS 7 ; `nonisolated(unsafe)` documente ce partage
/// concurrent sûr (les types Foundation ne sont pas `Sendable`).
private enum SQDateParsing {
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localWithFraction = makeLocal("yyyy-MM-dd'T'HH:mm:ss.SSS")
    private static let localNoFraction = makeLocal("yyyy-MM-dd'T'HH:mm:ss")
    private static let dateOnly = makeLocal("yyyy-MM-dd")

    private static func makeLocal(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    /// Essaie les formats dans le MÊME ordre que l'ancienne stratégie : ISO avec
    /// puis sans fraction, local avec puis sans fraction, enfin « jour seul »
    /// (ex. `date5g` prévisionnel = "2026-06-30", `lastInServiceDate`). Comportement
    /// de parsing strictement identique.
    static func parse(_ value: String) -> Date? {
        if let date = isoWithFraction.date(from: value) { return date }
        if let date = isoNoFraction.date(from: value) { return date }
        if let date = localWithFraction.date(from: value) { return date }
        if let date = localNoFraction.date(from: value) { return date }
        if let date = dateOnly.date(from: value) { return date }
        return nil
    }
}

extension JSONDecoder {
    /// Décodeur partagé de l'app (instance unique réutilisée — cf. PERF-DEC-01).
    /// `JSONDecoder` n'est pas `Sendable`, mais une instance configurée une seule
    /// fois et seulement *lue* (décodages concurrents) est sûre.
    static let signalQuest: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // DEC-DATE-EPOCH-01 : tolère une date NUMÉRIQUE epoch (secondes ou
            // millisecondes) en plus des chaînes ISO. Sans cette branche, un seul
            // champ date renvoyé en epoch ferait jeter tout l'objet — et souvent
            // tout le tableau parent (fil de messages vidé, stories disparues…).
            if let epoch = try? container.decode(Double.self) {
                // Heuristique ms vs s : un epoch ≥ 10^12 est en millisecondes
                // (10^12 s = an 33658, invraisemblable comme date applicative).
                let seconds = epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            if let date = SQDateParsing.parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date: \(value)")
        }
        return decoder
    }()
}

extension JSONEncoder {
    /// Encodeur partagé de l'app (instance unique réutilisée — cf. PERF-DEC-01).
    static let signalQuest: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension KeyedDecodingContainer {
    func decodeLossyArray<T: Decodable>(_ type: [T].Type, forKey key: Key) -> [T] {
        (try? decode(type, forKey: key)) ?? []
    }

    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func decodeLossyURL(forKey key: Key) -> URL? {
        guard let raw = decodeFlexibleString(forKey: key) else { return nil }
        return URL(string: raw)
    }
}
