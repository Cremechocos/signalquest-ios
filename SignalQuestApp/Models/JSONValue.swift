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

extension JSONDecoder {
    static var signalQuest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: value) {
                return date
            }
            let noFraction = ISO8601DateFormatter()
            noFraction.formatOptions = [.withInternetDateTime]
            if let date = noFraction.date(from: value) {
                return date
            }
            let localWithFraction = DateFormatter()
            localWithFraction.locale = Locale(identifier: "en_US_POSIX")
            localWithFraction.timeZone = TimeZone(secondsFromGMT: 0)
            localWithFraction.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            if let date = localWithFraction.date(from: value) {
                return date
            }
            let localNoFraction = DateFormatter()
            localNoFraction.locale = Locale(identifier: "en_US_POSIX")
            localNoFraction.timeZone = TimeZone(secondsFromGMT: 0)
            localNoFraction.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let date = localNoFraction.date(from: value) {
                return date
            }
            // Dates « jour seul » (ex. `date5g` prévisionnel = "2026-06-30",
            // `lastInServiceDate`). SANS ce format, un seul de ces champs faisait
            // jeter TOUT le tableau (ex. ~1900 sites prévisionnels) → couche vide.
            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dateOnly.dateFormat = "yyyy-MM-dd"
            if let date = dateOnly.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date: \(value)")
        }
        return decoder
    }
}

extension JSONEncoder {
    static var signalQuest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
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
