import SwiftUI

private func parseRegistryPlmn(_ value: String?) -> (plmn: String, mcc: Int, mnc: Int)? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.utf8.count == 5 || text.utf8.count == 6,
          text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let mcc = Int(text.prefix(3)), let mnc = Int(text.dropFirst(3)) else { return nil }
    return (text, mcc, mnc)
}

private func registryIdentityToken(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    let folded = value.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    let token = folded.filter { $0.isLetter || $0.isNumber }.lowercased()
    return token.isEmpty ? nil : token
}

/// Registre des marchés servi par GET /api/android/markets (et son fallback
/// bundlé market_registry_fallback.json). Décodage volontairement tolérant :
/// tout champ absent retombe sur une valeur sûre pour ne jamais bloquer la
/// carte sur un registre partiel.
struct MarketRegistryPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: String?
    let contract: MarketRegistryContract?
    let markets: [MarketRegistryEntry]
    let auditedCountries: [MarketRegistryEntry]
    let registeredPlmnMarkets: [String: String?]

    static let empty = MarketRegistryPayload()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, contract, markets, auditedCountries, registeredPlmnMarkets
    }

    init(
        schemaVersion: Int = 1,
        generatedAt: String? = nil,
        contract: MarketRegistryContract? = nil,
        markets: [MarketRegistryEntry] = [],
        auditedCountries: [MarketRegistryEntry] = [],
        registeredPlmnMarkets: [String: String?] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.contract = contract
        self.markets = markets
        self.auditedCountries = auditedCountries
        self.registeredPlmnMarkets = registeredPlmnMarkets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        generatedAt = c.decodeFlexibleString(forKey: .generatedAt)
        contract = try? c.decode(MarketRegistryContract.self, forKey: .contract)
        if let contract, contract.minimumCompatibleSchemaVersion > 3 {
            throw DecodingError.dataCorruptedError(
                forKey: .contract,
                in: c,
                debugDescription: "Market registry contract requires schema \(contract.minimumCompatibleSchemaVersion), client supports 3"
            )
        }
        markets = c.decodeLossyArray([MarketRegistryEntry].self, forKey: .markets)
        auditedCountries = c.decodeLossyArray([MarketRegistryEntry].self, forKey: .auditedCountries)
        registeredPlmnMarkets = (try? c.decode([String: String?].self, forKey: .registeredPlmnMarkets)) ?? [:]
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

    var supportsExactPlmnResolution: Bool {
        (contract?.plmnResolutionVersion ?? 0) >= 1 && !registeredPlmnMarkets.isEmpty
    }

    var supportsVersionedMarketContent: Bool {
        guard let contract, let hash = contract.marketContentSha256 else { return false }
        return contract.registryVersion.hasSuffix(String(hash.prefix(12))) &&
            hash.utf8.count == 64 && hash.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    func canReplaceRadioReference(_ reference: MarketRegistryPayload) -> Bool {
        guard !markets.isEmpty else { return false }
        guard reference.supportsExactPlmnResolution else { return true }
        let contentCompatible = !reference.supportsVersionedMarketContent || (
            supportsVersionedMarketContent &&
                (
                    contract?.registryVersion != reference.contract?.registryVersion ||
                        contract?.marketContentSha256 == reference.contract?.marketContentSha256
                )
        )
        return supportsExactPlmnResolution
            && contentCompatible
            && (contract?.plmnResolutionVersion ?? 0) >= (reference.contract?.plmnResolutionVersion ?? 0)
            && (contract?.positionDate ?? "") >= (reference.contract?.positionDate ?? "")
    }

    func market(forObservedPlmn value: String?) -> MarketRegistryEntry? {
        guard let parsed = parseRegistryPlmn(value) else { return nil }
        if registeredPlmnMarkets.keys.contains(parsed.plmn) {
            return market(forCode: registeredPlmnMarkets[parsed.plmn] ?? nil)
        }
        let exact = markets.filter { entry in
            entry.radioOperators.contains { $0.plmns.contains { $0.plmn == parsed.plmn } }
        }
        if exact.count == 1 { return exact[0] }
        let matchingMcc = markets.filter { $0.mccs.contains(parsed.mcc) }
        return matchingMcc.count == 1 ? matchingMcc[0] : nil
    }

    /// Identité commerciale de la SIM, sans modifier l'opérateur de la cellule servante.
    func radioMvno(simPlmn: String?, simOperatorName: String?) -> MarketRadioMvno? {
        if let simMarket = market(forObservedPlmn: simPlmn) {
            return simMarket.radioMvno(simPlmn: simPlmn, simOperatorName: simOperatorName)
        }
        let matches = markets.compactMap {
            $0.radioMvno(simPlmn: nil, simOperatorName: simOperatorName)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Métadonnées immuables qui permettent de vérifier que les clients utilisent
/// le même instantané mondial et la même source PLMN officielle.
struct MarketRegistryContract: Codable, Equatable, Sendable {
    let registryVersion: String
    let minimumCompatibleSchemaVersion: Int
    let positionDate: String
    let plmnRegistryVersion: String
    let plmnContentSha256: String
    let plmnResolutionVersion: Int?
    let plmnResolutionSha256: String?
    let marketContentSha256: String?
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
    let radioCapabilities: MarketRadioCapabilities
    let source: MarketRegistrySource
    /// Opérateurs RADIO (résolution SIM par MNC/PLMN), distincts des opérateurs
    /// d'affichage `operators` (qui n'ont pas de MNC). Indispensable pour rattacher
    /// une SIM DROM (MCC 340/647) à son opérateur exact.
    let radioOperators: [MarketRadioOperator]
    /// Marques MVNO et réseau hôte, séparés des PLMN de cellule.
    let radioMvnos: [MarketRadioMvno]

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

    /// Le nom d'opérateur tel que le registre du marché l'écrit — « Orange », jamais la clé
    /// « ORANGE ».
    ///
    /// Statique et tolérante au marché absent, pour qu'il n'y ait QU'UN endroit qui décide :
    /// la carte, ses feuilles et la page « Pannes signalées » affichaient trois choses pour un
    /// même opérateur, dont la clé brute. `entry` reste optionnel parce que le registre est
    /// chargé de façon asynchrone — avant sa réponse, la clé est ce qu'on a de moins faux.
    static func operatorLabel(_ key: String, in entry: MarketRegistryEntry?) -> String {
        if let label = entry?.operatorEntry(forKey: key)?.label { return label }
        return key.uppercased() == "ALL" ? String(localized: "Tous les opérateurs") : key
    }

    func operatorEntry(forKey key: String?) -> MarketRegistryOperator? {
        guard let normalized = key?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !normalized.isEmpty else { return nil }
        let canonical = radioOperators.first { $0.legacyKeys.contains(normalized) }?.key ?? normalized
        return selectableOperators.first { $0.key.uppercased() == canonical }
    }

    /// Clé de l'opérateur réellement diffusé par la cellule servante.
    /// `radioMvnos` n'est jamais consulté ici : son PLMN décrit la SIM.
    func radioOperatorKey(mcc: Int, mnc: Int, observedPlmn: String? = nil) -> String? {
        let parsed = parseRegistryPlmn(observedPlmn)
        if let raw = observedPlmn, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parsed == nil { return nil }
        let matches = radioOperators.filter { radioOperator in
            if let parsed { return radioOperator.plmns.contains { $0.plmn == parsed.plmn } }
            return radioOperator.plmns.contains { $0.mcc == mcc && $0.mnc == mnc }
        }
        let keys = Set(matches.map(\.key))
        guard keys.count == 1, let key = keys.first, operatorEntry(forKey: key) != nil else { return nil }
        return key
    }

    /// Résolution conservant le PLMN textuel exact (`310001` reste distinct de
    /// `31001`). Un PLMN de longueur invalide ne produit aucune attribution.
    func radioOperatorKey(observedPlmn: String?) -> String? {
        guard let parsed = parseRegistryPlmn(observedPlmn) else { return nil }
        return radioOperatorKey(mcc: parsed.mcc, mnc: parsed.mnc, observedPlmn: parsed.plmn)
    }

    /// Résolution MVNO strictement réservée à la SIM.
    func radioMvno(simPlmn: String?, simOperatorName: String?) -> MarketRadioMvno? {
        let parsed = parseRegistryPlmn(simPlmn)
        let exactMatches = parsed.map { parsed in
            radioMvnos.filter { mvno in mvno.plmns.contains { $0.plmn == parsed.plmn } }
        } ?? []
        guard exactMatches.count <= 1 else { return nil }

        let nameToken = registryIdentityToken(simOperatorName)
        let aliasMatches = nameToken.map { token in
            radioMvnos.filter { mvno in
                ([mvno.key, mvno.label] + mvno.aliases)
                    .compactMap { registryIdentityToken($0) }
                    .contains(token)
            }
        } ?? []
        let exact = exactMatches.first
        if let exact {
            guard aliasMatches.isEmpty || (aliasMatches.count == 1 && aliasMatches[0].key == exact.key) else {
                return nil
            }
            return exact
        }
        return aliasMatches.count == 1 ? aliasMatches[0] : nil
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
        case capabilities, operators, marketCode, mccs, sourceMode, radioCapabilities, radioOperators, radioMvnos, source
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
        radioCapabilities = (try? c.decode(MarketRadioCapabilities.self, forKey: .radioCapabilities)) ?? MarketRadioCapabilities()
        radioOperators = c.decodeLossyArray([MarketRadioOperator].self, forKey: .radioOperators)
        radioMvnos = c.decodeLossyArray([MarketRadioMvno].self, forKey: .radioMvnos)
        source = (try? c.decode(MarketRegistrySource.self, forKey: .source)) ?? MarketRegistrySource()
    }
}

/// Opérateur RADIO (résolution SIM) — bloc `radioOperators` du registre, distinct
/// des opérateurs d'AFFICHAGE (`operators`). Porte les MNC/PLMN pour rattacher une
/// SIM à son opérateur, y compris en DROM (MCC 340/647 où le MNC seul est ambigu).
struct MarketRadioOperator: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let aliases: [String]
    let networkGroupKey: String
    let mncs: [Int]
    let plmns: [MarketPlmn]
    let legacyKeys: [String]

    enum CodingKeys: String, CodingKey { case key, label, aliases, networkGroupKey, mncs, plmns, legacyKeys }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.decodeFlexibleString(forKey: .key) ?? ""
        label = c.decodeFlexibleString(forKey: .label) ?? key
        aliases = c.decodeLossyArray([String].self, forKey: .aliases)
        networkGroupKey = c.decodeFlexibleString(forKey: .networkGroupKey) ?? key
        mncs = c.decodeLossyArray([Int].self, forKey: .mncs)
        plmns = c.decodeLossyArray([MarketPlmn].self, forKey: .plmns)
        legacyKeys = c.decodeLossyArray([String].self, forKey: .legacyKeys)
    }
}

struct MarketRadioMvno: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let hostOperatorKey: String
    let plmns: [MarketPlmn]
    let aliases: [String]

    enum CodingKeys: String, CodingKey { case key, label, hostOperatorKey, plmns, aliases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.decodeFlexibleString(forKey: .key) ?? ""
        label = c.decodeFlexibleString(forKey: .label) ?? key
        hostOperatorKey = c.decodeFlexibleString(forKey: .hostOperatorKey) ?? ""
        plmns = c.decodeLossyArray([MarketPlmn].self, forKey: .plmns)
        aliases = c.decodeLossyArray([String].self, forKey: .aliases)
    }
}

struct MarketPlmn: Codable, Equatable, Sendable {
    let mcc: Int
    let mnc: Int
    let plmn: String?

    enum CodingKeys: String, CodingKey { case mcc, mnc, plmn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcc = (try? c.decode(Int.self, forKey: .mcc)) ?? -1
        mnc = (try? c.decode(Int.self, forKey: .mnc)) ?? -1
        plmn = c.decodeFlexibleString(forKey: .plmn)
    }
}

struct MarketRadioCapabilities: Codable, Equatable, Sendable {
    let officialAntennas: Bool
    let communitySpeedtests: Bool
    let communityCoverage: Bool
    let communityRatings: Bool
    let communityProbableSites: Bool
    let communityPhotos: Bool
    let offline: Bool
    let officialAzimuths: Bool
    let officialCoverage: String

    init(
        officialAntennas: Bool = false,
        communitySpeedtests: Bool = false,
        communityCoverage: Bool = false,
        communityRatings: Bool = false,
        communityProbableSites: Bool = false,
        communityPhotos: Bool = false,
        offline: Bool = false,
        officialAzimuths: Bool = false,
        officialCoverage: String = "none"
    ) {
        self.officialAntennas = officialAntennas
        self.communitySpeedtests = communitySpeedtests
        self.communityCoverage = communityCoverage
        self.communityRatings = communityRatings
        self.communityProbableSites = communityProbableSites
        self.communityPhotos = communityPhotos
        self.offline = offline
        self.officialAzimuths = officialAzimuths
        self.officialCoverage = officialCoverage
    }
}

struct MarketRegistrySource: Codable, Equatable, Sendable {
    let label: String
    let authority: String
    let url: String
    let status: String
    let checkedAt: String
    let notes: String

    init(
        label: String = "",
        authority: String = "",
        url: String = "",
        status: String = "unavailable",
        checkedAt: String = "",
        notes: String = ""
    ) {
        self.label = label
        self.authority = authority
        self.url = url
        self.status = status
        self.checkedAt = checkedAt
        self.notes = notes
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
