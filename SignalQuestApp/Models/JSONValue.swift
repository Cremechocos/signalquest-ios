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
enum SQDateParsing {
    // Styles immuables et Sendable pour les deux formes UTC canoniques.
    private static let canonicalWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let canonicalNoFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

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

    /// Accélère uniquement les formes UTC canoniques validées. Pour toutes les
    /// autres entrées ou si le style échoue, garde l'ordre historique : ISO avec
    /// puis sans fraction, local avec puis sans fraction, enfin « jour seul »
    /// (ex. `date5g` prévisionnel = "2026-06-30", `lastInServiceDate`).
    static func parse(_ value: String) -> Date? {
        if let byteCount = canonicalUTCByteCount(value),
           let date = try? (byteCount == 24 ? canonicalWithFraction : canonicalNoFraction).parse(value) {
            // Le calcul depuis l'epoch Unix retrouve l'arrondi des formatters
            // historiques, y compris avant 2001. Seulement 0 ou 3 décimales ici :
            // les autres précisions restent intégralement sur le repli existant.
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        }
        if let date = isoWithFraction.date(from: value) { return date }
        if let date = isoNoFraction.date(from: value) { return date }
        if let date = localWithFraction.date(from: value) { return date }
        if let date = localNoFraction.date(from: value) { return date }
        if let date = dateOnly.date(from: value) { return date }
        return nil
    }

    /// Limite la voie rapide à `YYYY-MM-DDTHH:mm:ss[.SSS]Z` en ASCII et aux
    /// années 1900...2099, intervalle vérifié pour l'égalité avec le parseur
    /// historique. Les autres années et valeurs hors plage gardent son arrondi
    /// et ses règles d'acceptation (notamment les secondes 60/61).
    private static func canonicalUTCByteCount(_ value: String) -> Int? {
        let byteCount = value.utf8.count
        guard byteCount == 20 || byteCount == 24 else { return nil }
        let bytes = Array(value.utf8)
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes.last == 90 else { return nil }
        for index in 0..<19 where index != 4 && index != 7 && index != 10 && index != 13 && index != 16 {
            guard (48...57).contains(bytes[index]) else { return nil }
        }
        if byteCount == 24 {
            guard bytes[19] == 46 else { return nil }
            for index in 20...22 {
                guard (48...57).contains(bytes[index]) else { return nil }
            }
        }

        func pair(at index: Int) -> Int {
            Int(bytes[index] - 48) * 10 + Int(bytes[index + 1] - 48)
        }
        let year = pair(at: 0) * 100 + pair(at: 2)
        let month = pair(at: 5)
        let day = pair(at: 8)
        guard (1900...2099).contains(year), (1...12).contains(month),
              (1...31).contains(day), pair(at: 11) <= 23,
              pair(at: 14) <= 59, pair(at: 17) <= 59 else { return nil }
        // Une date civile impossible reste sur le repli : ne pas dépendre de
        // différences de normalisation entre les versions de Foundation.
        let maximumDay: Int
        switch month {
        case 2:
            maximumDay = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400)) ? 29 : 28
        case 4, 6, 9, 11: maximumDay = 30
        default: maximumDay = 31
        }
        guard day <= maximumDay else { return nil }
        return byteCount
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

/// Élément de tableau tolérant : décode `T` ou retombe sur `nil` sans propager
/// l'erreur, pour ignorer un élément malformé au lieu de casser tout le tableau.
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

extension KeyedDecodingContainer {
    /// Décode un tableau élément par élément, en IGNORANT les éléments invalides.
    /// Clé absente ou valeur non-tableau → tableau vide (ROB-01/ROB-02/T1-9).
    ///
    /// L'implémentation précédente était `(try? decode(type, forKey:)) ?? []`,
    /// c'est-à-dire du tout-ou-rien : **un seul** élément mal typé vidait le
    /// tableau entier, en contradiction avec le nom. Concrètement, un opérateur
    /// ajouté côté serveur avec une valeur inattendue faisait disparaître toute
    /// la liste des opérateurs, des bandes ou des clusters d'une tuile de carte.
    func decodeLossyArray<T: Decodable>(_ type: [T].Type, forKey key: Key) -> [T] {
        guard let wrapped = try? decode([LossyElement<T>].self, forKey: key) else { return [] }
        return wrapped.compactMap(\.value)
    }

    /// Alias historique de `decodeLossyArray`, conservé pour ne pas toucher aux
    /// sites d'appel existants : les deux ont désormais la même sémantique.
    func decodeLossyElementArray<T: Decodable>(_ type: [T].Type, forKey key: Key) -> [T] {
        decodeLossyArray(type, forKey: key)
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
