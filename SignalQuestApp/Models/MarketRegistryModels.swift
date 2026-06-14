import SwiftUI

/// Registre des marchés servi par GET /api/android/markets (et son fallback
/// bundlé market_registry_fallback.json). Décodage volontairement tolérant :
/// tout champ absent retombe sur une valeur sûre pour ne jamais bloquer la
/// carte sur un registre partiel.
struct MarketRegistryPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: String?
    let markets: [MarketRegistryEntry]
    let auditedCountries: [MarketRegistryEntry]

    static let empty = MarketRegistryPayload()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, markets, auditedCountries
    }

    init(
        schemaVersion: Int = 1,
        generatedAt: String? = nil,
        markets: [MarketRegistryEntry] = [],
        auditedCountries: [MarketRegistryEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.markets = markets
        self.auditedCountries = auditedCountries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        generatedAt = c.decodeFlexibleString(forKey: .generatedAt)
        markets = c.decodeLossyArray([MarketRegistryEntry].self, forKey: .markets)
        auditedCountries = c.decodeLossyArray([MarketRegistryEntry].self, forKey: .auditedCountries)
    }

    /// Même résolution qu'Android : marketCode d'abord, puis code, insensible
    /// à la casse.
    func market(forCode code: String?) -> MarketRegistryEntry? {
        guard let normalized = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !normalized.isEmpty else { return nil }
        return markets.first { entry in
            entry.marketCode.uppercased() == normalized || entry.code.uppercased() == normalized
        }
    }
}

struct MarketRegistryEntry: Codable, Equatable, Identifiable, Sendable {
    let code: String
    let label: String
    let countryCode: String
    let publicSelectable: Bool
    let antennaCompatible: Bool
    let defaultLanguage: String
    let supportedLanguages: [String]
    /// `[lat, lng]` côté backend.
    let defaultMapCenter: [Double]
    let defaultMapZoom: Double?
    let capabilities: MarketCapabilities
    let operators: [MarketRegistryOperator]
    let marketCode: String
    let mccs: [Int]
    let sourceMode: String

    var id: String { marketCode.isEmpty ? code : marketCode }

    var defaultCenterLatitude: Double? {
        defaultMapCenter.count >= 2 ? defaultMapCenter[0] : nil
    }

    var defaultCenterLongitude: Double? {
        defaultMapCenter.count >= 2 ? defaultMapCenter[1] : nil
    }

    /// Opérateurs affichables, sans doublons de clé (ordre du registre conservé).
    var selectableOperators: [MarketRegistryOperator] {
        var seen = Set<String>()
        return operators.filter { seen.insert($0.key.uppercased()).inserted }
    }

    /// Marché alimenté uniquement par les données communautaires : pas
    /// d'antennes officielles à afficher.
    var isCommunityOnly: Bool {
        sourceMode.caseInsensitiveCompare("community") == .orderedSame
    }

    func operatorEntry(forKey key: String?) -> MarketRegistryOperator? {
        guard let normalized = key?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !normalized.isEmpty else { return nil }
        return selectableOperators.first { $0.key.uppercased() == normalized }
    }

    /// Couleur registry de l'opérateur, avec repli sur la palette SQBrand.
    func operatorColor(forKey key: String?) -> Color {
        if let entry = operatorEntry(forKey: key), let color = Color(hexString: entry.color) {
            return color
        }
        return SQBrand.operatorColor(key)
    }

    enum CodingKeys: String, CodingKey {
        case code, label, countryCode, publicSelectable, antennaCompatible
        case defaultLanguage, supportedLanguages, defaultMapCenter, defaultMapZoom
        case capabilities, operators, marketCode, mccs, sourceMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCode = c.decodeFlexibleString(forKey: .code) ?? ""
        code = decodedCode
        label = c.decodeFlexibleString(forKey: .label) ?? decodedCode
        countryCode = c.decodeFlexibleString(forKey: .countryCode) ?? decodedCode.lowercased()
        publicSelectable = (try? c.decode(Bool.self, forKey: .publicSelectable)) ?? false
        antennaCompatible = (try? c.decode(Bool.self, forKey: .antennaCompatible)) ?? false
        defaultLanguage = c.decodeFlexibleString(forKey: .defaultLanguage) ?? "en"
        supportedLanguages = c.decodeLossyArray([String].self, forKey: .supportedLanguages)
        defaultMapCenter = c.decodeLossyArray([Double].self, forKey: .defaultMapCenter)
        defaultMapZoom = (try? c.decodeIfPresent(Double.self, forKey: .defaultMapZoom)) ?? nil
        capabilities = (try? c.decode(MarketCapabilities.self, forKey: .capabilities)) ?? MarketCapabilities()
        operators = c.decodeLossyArray([MarketRegistryOperator].self, forKey: .operators)
        marketCode = c.decodeFlexibleString(forKey: .marketCode) ?? decodedCode
        mccs = c.decodeLossyArray([Int].self, forKey: .mccs)
        sourceMode = c.decodeFlexibleString(forKey: .sourceMode) ?? "official"
    }
}

struct MarketCapabilities: Codable, Equatable, Sendable {
    let archives: Bool
    let previsionnel: Bool
    let incidents: Bool
    let offline: Bool
    let communityLayers: Bool

    enum CodingKeys: String, CodingKey {
        case archives, previsionnel, incidents, offline, communityLayers
    }

    init(
        archives: Bool = false,
        previsionnel: Bool = false,
        incidents: Bool = false,
        offline: Bool = false,
        communityLayers: Bool = false
    ) {
        self.archives = archives
        self.previsionnel = previsionnel
        self.incidents = incidents
        self.offline = offline
        self.communityLayers = communityLayers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archives = (try? c.decode(Bool.self, forKey: .archives)) ?? false
        previsionnel = (try? c.decode(Bool.self, forKey: .previsionnel)) ?? false
        incidents = (try? c.decode(Bool.self, forKey: .incidents)) ?? false
        offline = (try? c.decode(Bool.self, forKey: .offline)) ?? false
        communityLayers = (try? c.decode(Bool.self, forKey: .communityLayers)) ?? false
    }
}

struct MarketRegistryOperator: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let shortLabel: String
    /// Hex "#RRGGBB" du registre.
    let color: String
    let background: String?
    let mncs: [Int]
    let kind: String?
    let aliases: [String]

    var id: String { key }

    /// Couleur SwiftUI du registre, repli sur la palette SQBrand si le hex
    /// est invalide.
    var swiftUIColor: Color {
        Color(hexString: color) ?? SQBrand.operatorColor(key)
    }

    enum CodingKeys: String, CodingKey {
        case key, label, shortLabel, color, background, mncs, kind, aliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = c.decodeFlexibleString(forKey: .key) ?? ""
        key = decodedKey
        label = c.decodeFlexibleString(forKey: .label) ?? decodedKey
        shortLabel = c.decodeFlexibleString(forKey: .shortLabel)
            ?? c.decodeFlexibleString(forKey: .label)
            ?? decodedKey
        color = c.decodeFlexibleString(forKey: .color) ?? ""
        background = c.decodeFlexibleString(forKey: .background)
        mncs = c.decodeLossyArray([Int].self, forKey: .mncs)
        kind = c.decodeFlexibleString(forKey: .kind)
        aliases = c.decodeLossyArray([String].self, forKey: .aliases)
    }
}

extension Color {
    /// `Color(hexString: "#E2001A")` — tolère le "#" optionnel et les formats
    /// RGB (3), RRGGBB (6) ou RRGGBBAA (8 chiffres).
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8,
              let parsed = UInt64(value, radix: 16) else { return nil }
        if value.count == 8 {
            self.init(
                .sRGB,
                red: Double((parsed >> 24) & 0xFF) / 255,
                green: Double((parsed >> 16) & 0xFF) / 255,
                blue: Double((parsed >> 8) & 0xFF) / 255,
                opacity: Double(parsed & 0xFF) / 255
            )
        } else {
            self.init(hex: UInt32(parsed))
        }
    }
}
