import SwiftUI
import CoreLocation

// MARK: - Tolerant decoding helpers

private extension KeyedDecodingContainer {
    /// Decode tolérant : valeur absente, nulle ou mal typée → `fallback`.
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// Decode tolérant d'un optionnel : absent ou erreur → `nil`.
    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

// MARK: - Operator

/// Opérateur ANFR. Couleurs portées d'Android `AnfrOperator` / `SQBrand`.
enum ANFROperator: String, CaseIterable, Identifiable, Sendable, Hashable {
    case orange
    case sfr
    case bouygues
    case free

    var id: String { rawValue }

    /// Libellé court affiché dans les filtres / pastilles.
    var label: String {
        switch self {
        case .orange: return "Orange"
        case .sfr: return "SFR"
        case .bouygues: return "Bouygues"
        case .free: return "Free"
        }
    }

    /// Clé utilisée par l'API stats (`operator` : sfr/orange/bytel/free).
    var apiKey: String {
        switch self {
        case .orange: return "orange"
        case .sfr: return "sfr"
        case .bouygues: return "bytel"
        case .free: return "free"
        }
    }

    /// Couleur de marque (identique clair/sombre) — alignée sur `SQBrand`.
    var color: Color {
        SQBrand.operatorColor(label)
    }

    /// Résolution tolérante depuis un libellé brut ANFR ou une clé API.
    static func from(raw: String?) -> ANFROperator? {
        guard let raw, !raw.isEmpty else { return nil }
        let n = raw.lowercased()
        if n.contains("orange") { return .orange }
        if n.contains("bouygues") || n.contains("bytel") { return .bouygues }
        if (n.contains("free") && !n.contains("freedom")) { return .free }
        if n.contains("sfr") && !n.contains("srr") { return .sfr }
        return nil
    }
}

// MARK: - Modification type

/// Type de modification d'une antenne entre deux relevés ANFR.
/// Priorité du type dominant d'un site : la règle du web (nouveau > ajoutée >
/// mise en service > retirée), pour qu'un même support ait le même repère partout.
enum ANFRModType: String, CaseIterable, Identifiable, Sendable, Hashable {
    case new
    case activated
    case deleted
    case added
    /// Antenne revenue de « En service » à un statut de projet.
    case modified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: return String(localized: "Nouveau support")
        case .activated: return String(localized: "Mise en service")
        case .deleted: return String(localized: "Antenne retirée")
        case .added: return String(localized: "Antenne ajoutée")
        case .modified: return String(localized: "Repassée en projet")
        }
    }

    var glyph: String {
        switch self {
        case .new: return "star.fill"
        case .activated: return "checkmark"
        case .deleted: return "xmark"
        case .added: return "plus"
        case .modified: return "arrow.uturn.backward"
        }
    }

    var color: Color {
        switch self {
        case .new: return SQColor.info
        case .activated: return SQColor.success
        case .deleted: return SQColor.danger
        case .added: return SQColor.label
        case .modified: return SQColor.warning
        }
    }

    /// Rang de priorité pour choisir le type dominant d'un site (ordre du web).
    var priority: Int {
        switch self {
        case .new: return 5
        case .added: return 4
        case .activated: return 3
        case .modified: return 2
        case .deleted: return 1
        }
    }

    static func from(raw: String?) -> ANFRModType {
        switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "activated": return .activated
        case "deleted": return .deleted
        case "new": return .new
        case "modified": return .modified
        default: return .added
        }
    }
}

// MARK: - Generation

/// Génération radio normalisée (2G/3G/4G/5G). Sert au filtre et au badge techno.
enum ANFRGeneration: String, CaseIterable, Identifiable, Sendable, Hashable {
    case g2 = "2G"
    case g3 = "3G"
    case g4 = "4G"
    case g5 = "5G"

    var id: String { rawValue }
    var label: String { rawValue }
    var color: Color { SQBrand.techColor(rawValue) }
    var rank: Int {
        switch self {
        case .g5: return 5
        case .g4: return 4
        case .g3: return 3
        case .g2: return 2
        }
    }

    /// Normalise un libellé brut (`generation` ou `emr_lb_systeme`).
    static func normalize(_ raw: String?) -> ANFRGeneration? {
        guard let raw, !raw.isEmpty else { return nil }
        let u = raw.uppercased()
        if u.contains("5G") || u.contains("NR") { return .g5 }
        if u.contains("4G") || u.contains("LTE") { return .g4 }
        if u.contains("3G") || u.contains("UMTS") || u.contains("WCDMA") { return .g3 }
        if u.contains("2G") || u.contains("GSM") || u.contains("EDGE") { return .g2 }
        return nil
    }
}

// MARK: - Stats response (GET /api/anfr/stats)

/// Réponse complète de `/api/anfr/stats`. Décodage tolérant : tout champ absent
/// retombe sur une valeur vide, jamais d'échec dur.
struct ANFRStats: Decodable, Sendable {
    let latestDate: String?
    /// Série temporelle nationale (un point par date × opérateur × bande).
    let series: [ANFRStatsPoint]
    /// Dernier relevé par opérateur × bande, avec deltas hebdo.
    let latest: [ANFRStatsLatest]
    /// Métriques territoriales (régions) du dernier relevé.
    let regions: [ANFRTerritoryMetric]

    enum CodingKeys: String, CodingKey {
        case meta, national, territories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let meta = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        latestDate = meta?.optional(String.self, .latestDate)

        if let national = try? c.nestedContainer(keyedBy: NationalKeys.self, forKey: .national) {
            series = national.value([ANFRStatsPoint].self, .series, [])
            latest = national.value([ANFRStatsLatest].self, .latest, [])
        } else {
            series = []
            latest = []
        }

        if let territories = try? c.nestedContainer(keyedBy: TerritoryKeys.self, forKey: .territories) {
            regions = territories.value([ANFRTerritoryMetric].self, .regions, [])
        } else {
            regions = []
        }
    }

    private enum MetaKeys: String, CodingKey { case latestDate }
    private enum NationalKeys: String, CodingKey { case series, latest }
    private enum TerritoryKeys: String, CodingKey { case regions, departments, crozon }

    /// Constructeur direct (données de démo).
    init(latestDate: String?, series: [ANFRStatsPoint], latest: [ANFRStatsLatest], regions: [ANFRTerritoryMetric]) {
        self.latestDate = latestDate
        self.series = series
        self.latest = latest
        self.regions = regions
    }
}

/// Un point de la série nationale.
struct ANFRStatsPoint: Decodable, Sendable, Identifiable {
    let date: String
    let operatorKey: String
    let operatorLabel: String
    let band: String
    let bandLabel: String
    let technology: String
    let operational: Int
    let projected: Int
    let total: Int

    var id: String { "\(date)|\(operatorKey)|\(band)" }

    enum CodingKeys: String, CodingKey {
        case date, operatorLabel, band, bandLabel, technology, operational, projected, total
        case operatorKey = "operator"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.value(String.self, .date, "")
        operatorKey = c.value(String.self, .operatorKey, "")
        operatorLabel = c.value(String.self, .operatorLabel, "")
        band = c.value(String.self, .band, "")
        bandLabel = c.value(String.self, .bandLabel, "")
        technology = c.value(String.self, .technology, "")
        operational = c.value(Int.self, .operational, 0)
        projected = c.value(Int.self, .projected, 0)
        total = c.value(Int.self, .total, 0)
    }

    init(date: String, operatorKey: String, operatorLabel: String, band: String, bandLabel: String, technology: String, operational: Int, projected: Int, total: Int) {
        self.date = date
        self.operatorKey = operatorKey
        self.operatorLabel = operatorLabel
        self.band = band
        self.bandLabel = bandLabel
        self.technology = technology
        self.operational = operational
        self.projected = projected
        self.total = total
    }
}

/// Dernier relevé par opérateur × bande, enrichi des deltas hebdomadaires.
struct ANFRStatsLatest: Decodable, Sendable, Identifiable {
    let date: String
    let operatorKey: String
    let operatorLabel: String
    let band: String
    let bandLabel: String
    let technology: String
    let operational: Int
    let projected: Int
    let total: Int
    let deltaOperational: Int
    let deltaTotal: Int

    var id: String { "\(operatorKey)|\(band)" }

    enum CodingKeys: String, CodingKey {
        case date, operatorLabel, band, bandLabel, technology, operational, projected, total
        case operatorKey = "operator"
        case deltaOperational, deltaTotal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.value(String.self, .date, "")
        operatorKey = c.value(String.self, .operatorKey, "")
        operatorLabel = c.value(String.self, .operatorLabel, "")
        band = c.value(String.self, .band, "")
        bandLabel = c.value(String.self, .bandLabel, "")
        technology = c.value(String.self, .technology, "")
        operational = c.value(Int.self, .operational, 0)
        projected = c.value(Int.self, .projected, 0)
        total = c.value(Int.self, .total, 0)
        deltaOperational = c.value(Int.self, .deltaOperational, 0)
        deltaTotal = c.value(Int.self, .deltaTotal, 0)
    }

    init(date: String, operatorKey: String, operatorLabel: String, band: String, bandLabel: String, technology: String, operational: Int, projected: Int, total: Int, deltaOperational: Int, deltaTotal: Int) {
        self.date = date
        self.operatorKey = operatorKey
        self.operatorLabel = operatorLabel
        self.band = band
        self.bandLabel = bandLabel
        self.technology = technology
        self.operational = operational
        self.projected = projected
        self.total = total
        self.deltaOperational = deltaOperational
        self.deltaTotal = deltaTotal
    }
}

/// Métrique territoriale (région) du dernier relevé.
struct ANFRTerritoryMetric: Decodable, Sendable, Identifiable {
    let key: String
    let label: String
    let operatorKey: String
    let band: String
    let technology: String
    let operational: Int
    let total: Int

    var id: String { "\(key)|\(operatorKey)|\(band)" }

    enum CodingKeys: String, CodingKey {
        case key, label, band, technology, operational, total
        case operatorKey = "operator"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.value(String.self, .key, "")
        label = c.value(String.self, .label, "")
        operatorKey = c.value(String.self, .operatorKey, "")
        band = c.value(String.self, .band, "")
        technology = c.value(String.self, .technology, "")
        operational = c.value(Int.self, .operational, 0)
        total = c.value(Int.self, .total, 0)
    }

    init(key: String, label: String, operatorKey: String, band: String, technology: String, operational: Int, total: Int) {
        self.key = key
        self.label = label
        self.operatorKey = operatorKey
        self.band = band
        self.technology = technology
        self.operational = operational
        self.total = total
    }
}

// MARK: - Map snapshot (GET /api/anfr/map-snapshot)

/// Snapshot carte ANFR : le DIFFÉRENTIEL d'une semaine (les supports qui ont
/// changé, et pour chacun seulement ses antennes modifiées), pas le parc entier.
struct ANFRMapSnapshot: Decodable, Sendable {
    let source: String?
    let snapshotDate: String?
    let lastUpdate: String?
    let siteCount: Int
    let sites: [ANFRMapSite]
    /// Antennes du relevé ; seul le relevé léger le donne, le complet les porte.
    let antennaCount: Int
    /// Relevé léger (`fields=lite`) : des compteurs par support, sans les antennes.
    let isLite: Bool
    /// Vrai quand la copie vient du disque faute de réseau (relevé courant).
    var servedFromCache = false

    enum CodingKeys: String, CodingKey {
        case source, snapshotDate, lastUpdate, siteCount, sites, antennaCount, fields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.optional(String.self, .source)
        snapshotDate = c.optional(String.self, .snapshotDate)
        lastUpdate = c.optional(String.self, .lastUpdate)
        let rawSites = c.value([ANFRMapSite].self, .sites, [])
        let valid = rawSites.filter { $0.hasValidCoordinate }
        sites = valid
        siteCount = c.value(Int.self, .siteCount, valid.count)
        isLite = c.optional(String.self, .fields) == "lite"
        antennaCount = c.optional(Int.self, .antennaCount) ?? valid.reduce(0) { $0 + $1.changeCount }
    }

    init(source: String?, snapshotDate: String?, lastUpdate: String?, sites: [ANFRMapSite], isLite: Bool = false) {
        self.source = source
        self.snapshotDate = snapshotDate
        self.lastUpdate = lastUpdate
        self.sites = sites
        self.siteCount = sites.count
        self.antennaCount = sites.reduce(0) { $0 + $1.changeCount }
        self.isLite = isLite
    }
}

// MARK: - Comparaison de deux relevés (GET /api/anfr/map-diff)

/// Ce qui a changé entre deux relevés, en net par antenne : seul compte son dernier
/// état sur la période. Les supports sont au format léger.
struct ANFRMapDiff: Decodable, Sendable {
    let from: String
    let to: String
    /// Relevés cumulés, du plus ancien au plus récent (`from` exclu).
    let weeks: [String]
    let siteCount: Int
    let antennaCount: Int
    let sites: [ANFRMapSite]

    enum CodingKeys: String, CodingKey { case from, to, weeks, siteCount, antennaCount, sites }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = c.value(String.self, .from, "")
        to = c.value(String.self, .to, "")
        weeks = c.value([String].self, .weeks, [])
        sites = c.value([ANFRMapSite].self, .sites, []).filter { $0.hasValidCoordinate }
        siteCount = c.value(Int.self, .siteCount, sites.count)
        antennaCount = c.optional(Int.self, .antennaCount) ?? sites.reduce(0) { $0 + $1.changeCount }
    }

    init(from: String, to: String, weeks: [String], sites: [ANFRMapSite]) {
        self.from = from
        self.to = to
        self.weeks = weeks
        self.sites = sites
        self.siteCount = sites.count
        self.antennaCount = sites.reduce(0) { $0 + $1.changeCount }
    }

    /// La comparaison vue comme un relevé léger, pour la carte.
    var snapshot: ANFRMapSnapshot {
        ANFRMapSnapshot(source: "diff", snapshotDate: to, lastUpdate: nil, sites: sites, isLite: true)
    }
}

/// Ce que le relevé léger dit d'un support : ses opérateurs et ses changements par type.
struct ANFRSiteChangeSummary: Equatable, Sendable {
    /// Opérateurs suivis présents, dans l'ordre de l'enum.
    let operators: [ANFROperator]
    /// Un opérateur hors des quatre suivis figure aussi sur le support.
    let hasOtherOperator: Bool
    let counts: [ANFRModType: Int]
    /// Antennes en rattrapage, tous types confondus : elles recoupent `counts`.
    let catchUp: Int
    /// Dans une comparaison, le relevé de son dernier changement.
    let lastChangeDate: String?

    var total: Int { counts.values.reduce(0, +) }

    /// Types présents, dans l'ordre de l'enum.
    var presentTypes: [ANFRModType] { ANFRModType.allCases.filter { (counts[$0] ?? 0) > 0 } }

    func count(for type: ANFRModType) -> Int { counts[type] ?? 0 }
}

/// Un site ANFR (un support) et ses antennes modifiées au relevé.
struct ANFRMapSite: Decodable, Sendable, Identifiable, Equatable {
    let supId: String
    let latitude: Double
    let longitude: Double
    let city: String
    let antennas: [ANFRMapAntenna]
    /// Relevé léger ou comparaison : le support sans ses antennes, avec ses compteurs.
    /// `nil` dans un relevé complet.
    let summary: ANFRSiteChangeSummary?

    var id: String { supId }

    enum CodingKeys: String, CodingKey {
        case info, antennas
        case supId, lat, lon, city, operators, changes, catchUp, lastChangeDate
    }
    private enum InfoKeys: String, CodingKey {
        case sup_id, lat, lon, city
    }
    private enum ChangeKeys: String, CodingKey {
        case new, added, activated, deleted, modified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let changes = try? c.nestedContainer(keyedBy: ChangeKeys.self, forKey: .changes) {
            // Format léger : position en nombres, opérateurs en libellés ANFR bruts.
            supId = c.optional(String.self, .supId) ?? ""
            latitude = c.optional(ANFRLooseNumber.self, .lat)?.value ?? .nan
            longitude = c.optional(ANFRLooseNumber.self, .lon)?.value ?? .nan
            city = c.optional(String.self, .city) ?? ""
            antennas = []
            let rawOperators = c.value([String].self, .operators, [])
            let tracked = Set(rawOperators.compactMap(ANFROperator.from(raw:)))
            var counts: [ANFRModType: Int] = [:]
            let keys: [(ANFRModType, ChangeKeys)] = [(.new, .new), (.added, .added), (.activated, .activated),
                                                     (.deleted, .deleted), (.modified, .modified)]
            for (type, key) in keys {
                let count = changes.value(Int.self, key, 0)
                if count > 0 { counts[type] = count }
            }
            summary = ANFRSiteChangeSummary(
                operators: ANFROperator.allCases.filter(tracked.contains),
                hasOtherOperator: rawOperators.contains { ANFROperator.from(raw: $0) == nil },
                counts: counts,
                catchUp: max(c.value(Int.self, .catchUp, 0), 0),
                lastChangeDate: c.optional(String.self, .lastChangeDate)
            )
            return
        }
        summary = nil
        let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
        let rawAntennas = c.value([ANFRMapAntenna].self, .antennas, [])
        antennas = rawAntennas

        supId = info?.optional(String.self, .sup_id) ?? rawAntennas.first?.supId ?? ""

        // lat/lon sont des strings dans le JSON ANFR ; fallback sur la 1re antenne.
        let infoLat = info?.optional(String.self, .lat)
        let infoLon = info?.optional(String.self, .lon)
        latitude = Double(infoLat ?? "") ?? rawAntennas.first?.latitude ?? .nan
        longitude = Double(infoLon ?? "") ?? rawAntennas.first?.longitude ?? .nan

        let infoCity = info?.optional(String.self, .city)
        city = (infoCity?.isEmpty == false ? infoCity : nil) ?? rawAntennas.first?.city ?? ""
    }

    init(supId: String, latitude: Double, longitude: Double, city: String, antennas: [ANFRMapAntenna],
         summary: ANFRSiteChangeSummary? = nil) {
        self.supId = supId
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.antennas = antennas
        self.summary = summary
    }

    /// Changements du support : ses antennes, ou ses compteurs en relevé léger.
    var changeCount: Int { summary?.total ?? antennas.count }

    var hasValidCoordinate: Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        if latitude == 0 && longitude == 0 { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: Derived — porté d'Android (AnfrMarkerStyleResolver / AnfrSite)

    /// Opérateurs présents, dédupliqués, ordonnés selon l'enum (cache-stable).
    var operators: [ANFROperator] {
        if let summary { return summary.operators }
        var seen = Set<ANFROperator>()
        var ordered: [ANFROperator] = []
        for op in ANFROperator.allCases where antennas.contains(where: { $0.operator == op }) {
            if seen.insert(op).inserted { ordered.append(op) }
        }
        return ordered
    }

    /// Opérateur dominant : plus grand nombre d'antennes, départage par ordre
    /// d'enum (le plus petit ordinal gagne, comme Android). `nil` quand aucune
    /// antenne n'est d'un des quatre opérateurs suivis.
    var dominantOperator: ANFROperator? {
        // Le relevé léger ne compte pas les antennes par opérateur : ordre de l'enum.
        if let summary { return summary.operators.first }
        let counts = Dictionary(grouping: antennas.compactMap(\.operator), by: { $0 })
            .mapValues(\.count)
        // `allCases` est déjà en ordre d'enum : `max(by:)` renvoie le dernier
        // élément maximal, donc on cherche le 1er maximum manuellement.
        return ANFROperator.allCases.reduce(nil) { (best: ANFROperator?, op) in
            guard let count = counts[op] else { return best }
            guard let best, let bestCount = counts[best] else { return op }
            return count > bestCount ? op : best
        }
    }

    /// Type de modification dominant (priorité : voir `ANFRModType.priority`).
    var dominantModType: ANFRModType {
        let types = summary?.presentTypes ?? antennas.map(\.modType)
        return types.max { $0.priority < $1.priority } ?? .activated
    }

    /// Génération la plus élevée présente sur le site.
    var highestGeneration: ANFRGeneration? {
        antennas.compactMap(\.generationEnum).max { $0.rank < $1.rank }
    }

    /// Azimuts des antennes de ce relevé, réunis par opérateur (ordre de l'enum).
    /// Les opérateurs sans azimut publié sont omis.
    var sectorsByOperator: [ANFRSiteSectors] {
        operators.compactMap { op in
            let azimuths = ANFRAzimuth.normalize(antennas.filter { $0.operator == op }.flatMap(\.azimuths).map(Double.init))
            return azimuths.isEmpty ? nil : ANFRSiteSectors(operator: op, azimuths: azimuths)
        }
    }
}

/// Les azimuts d'un opérateur sur un support.
struct ANFRSiteSectors: Identifiable, Equatable, Sendable {
    let `operator`: ANFROperator
    let azimuths: [Int]
    var id: ANFROperator { `operator` }
}

// MARK: - Azimuts

/// Nombre lu tel que le serveur l'écrit : nombre ou chaîne.
struct ANFRLooseNumber: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            value = number
        } else if let text = try? c.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        } else {
            value = nil
        }
    }
}

enum ANFRAzimuth {
    /// Degrés entiers 0-359 (360 se lit 0), triés, sans doublon ; le reste est écarté.
    static func normalize(_ raw: [Double]) -> [Int] {
        let values = raw.compactMap { value -> Int? in
            guard value.isFinite, value >= 0, value <= 360 else { return nil }
            let degrees = Int(value.rounded())
            return degrees == 360 ? 0 : degrees
        }
        return Array(Set(values)).sorted()
    }

    /// « 20°, 140°, 260° ».
    static func list(_ azimuths: [Int]) -> String {
        azimuths.map { "\($0)°" }.joined(separator: ", ")
    }
}

/// Une antenne au sein d'un site ANFR.
struct ANFRMapAntenna: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let supId: String?
    let operatorRaw: String
    let system: String
    let generationRaw: String
    let modTypeRaw: String
    let statut: String
    let dateMaj: String
    let latitude: Double?
    let longitude: Double?
    let city: String?
    /// Date réelle du changement (AAAA-MM-JJ) : la mise en service déclarée, pas
    /// la date de publication. Absente des anciennes réponses et des retraits.
    let changeDate: String?
    /// Rattrapage : mise en service déclarée plus de 30 jours après sa date réelle.
    let catchUp: Bool
    /// Azimuts déclarés des secteurs, en degrés 0-359 (0 = nord), triés et sans
    /// doublon. Vide quand l'ANFR n'en publie pas ou que la copie est ancienne.
    let azimuths: [Int]
    /// Morceaux d'adresse bruts, assemblés à la demande (`address`).
    private let addressLieu: String?
    private let addressLine: String?
    private let postalCode: String?

    enum CodingKeys: String, CodingKey {
        case id, sup_id, adm_lb_nom, emr_lb_systeme, generation, type, statut, date_maj
        case lat, lon, city, changeDate, catchUp, azimuts
        case adr_lb_lieu, adr_lb_add1, adr_nm_cp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSupId = c.optional(String.self, .sup_id)
        let decodedOperator = c.value(String.self, .adm_lb_nom, "")
        let decodedSystem = c.value(String.self, .emr_lb_systeme, "")
        supId = decodedSupId
        operatorRaw = decodedOperator
        system = decodedSystem
        generationRaw = c.value(String.self, .generation, "")
        modTypeRaw = c.value(String.self, .type, "")
        statut = c.value(String.self, .statut, "")
        dateMaj = c.value(String.self, .date_maj, "")
        // Position en chaîne (format complet) ou en nombre : les deux se lisent.
        latitude = c.optional(ANFRLooseNumber.self, .lat)?.value
        longitude = c.optional(ANFRLooseNumber.self, .lon)?.value
        // Sans `id` serveur, l'identifiant se déduit de la ligne : le même à chaque décodage,
        // pour que SwiftUI et MapKit reconnaissent l'antenne d'un affichage à l'autre.
        id = c.optional(String.self, .id)
            ?? [decodedSupId ?? "", decodedOperator, decodedSystem, c.optional(String.self, .adr_lb_add1) ?? ""]
                .joined(separator: "|")
        city = c.optional(String.self, .city)
        changeDate = c.optional(String.self, .changeDate)
        catchUp = c.value(Bool.self, .catchUp, false)
        azimuths = ANFRAzimuth.normalize(c.value([ANFRLooseNumber].self, .azimuts, []).compactMap(\.value))
        addressLieu = c.optional(String.self, .adr_lb_lieu)
        addressLine = c.optional(String.self, .adr_lb_add1)
        postalCode = c.optional(String.self, .adr_nm_cp)
    }

    init(id: String, supId: String?, operatorRaw: String, system: String, generationRaw: String, modTypeRaw: String, statut: String, dateMaj: String, latitude: Double?, longitude: Double?, city: String?, address: String?,
         changeDate: String? = nil, catchUp: Bool = false, azimuths: [Int] = []) {
        self.id = id
        self.supId = supId
        self.operatorRaw = operatorRaw
        self.system = system
        self.generationRaw = generationRaw
        self.modTypeRaw = modTypeRaw
        self.statut = statut
        self.dateMaj = dateMaj
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.changeDate = changeDate
        self.catchUp = catchUp
        self.azimuths = ANFRAzimuth.normalize(azimuths.map(Double.init))
        addressLieu = address
        addressLine = nil
        postalCode = nil
    }

    /// « Lieu, adresse, code postal », ou rien.
    var address: String? {
        let text = [addressLieu, addressLine, postalCode]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    var `operator`: ANFROperator? { ANFROperator.from(raw: operatorRaw) }
    var modType: ANFRModType { ANFRModType.from(raw: modTypeRaw) }
    var generationEnum: ANFRGeneration? {
        ANFRGeneration.normalize(generationRaw) ?? ANFRGeneration.normalize(system)
    }
}

// MARK: - Marker style (porté d'Android AnfrMarkerStyleResolver / AnfrMarkerStyle)

/// Recette visuelle d'un marqueur ANFR, dérivée du domaine (opérateur dominant,
/// type de modif, génération, multi-opérateur). Pure data, sans Color/UIView.
struct ANFRMarkerStyle: Equatable {
    /// Vide quand le site n'a que des antennes d'un autre opérateur que les quatre suivis.
    let operators: [ANFROperator]
    let dominantOperator: ANFROperator?
    let modType: ANFRModType
    let generation: ANFRGeneration?

    var isMultiOperator: Bool { operators.count > 1 }

    init(site: ANFRMapSite) {
        operators = site.operators
        dominantOperator = site.dominantOperator
        modType = site.dominantModType
        generation = site.highestGeneration
    }
}

// MARK: - Site history derived accessors

extension ANFRSiteHistoryChange {
    var `operator`: ANFROperator? { ANFROperator.from(raw: operatorRaw) }
    var modType: ANFRModType { ANFRModType.from(raw: modTypeRaw) }
    var generationEnum: ANFRGeneration? {
        ANFRGeneration.normalize(generation) ?? ANFRGeneration.normalize(technology)
    }
}

extension ANFRSiteHistoryEntry {
    var operatorEnums: [ANFROperator] { operators.compactMap { ANFROperator.from(raw: $0) } }
    var modTypeEnums: [ANFRModType] { modTypes.map { ANFRModType.from(raw: $0) } }
}

// MARK: - Semaines (GET /api/anfr/archives?weeks=N)

/// Les changements d'une semaine ANFR par type : une antenne du différentiel = un
/// changement. `catchUp` recoupe les quatre types et n'entre pas dans `total`.
struct ANFRWeekSummary: Decodable, Sendable, Identifiable, Equatable {
    let date: String
    let new: Int
    let added: Int
    let activated: Int
    let deleted: Int
    let modified: Int
    let catchUp: Int
    let total: Int
    /// Supports réorientés cette semaine, hors `total`. Absent tant que la semaine
    /// n'est pas archivée ou que le calcul n'existe pas.
    let reoriented: Int?
    /// Poids de l'archive : supports et antennes. Absent avant le mode léger.
    let siteCount: Int?
    let antennaCount: Int?

    var id: String { date }

    private enum CodingKeys: String, CodingKey { case date, counts, total, reoriented, siteCount, antennaCount }
    private enum CountKeys: String, CodingKey { case new, added, activated, deleted, modified, catchUp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.value(String.self, .date, "")
        let counts = try? c.nestedContainer(keyedBy: CountKeys.self, forKey: .counts)
        new = counts?.value(Int.self, .new, 0) ?? 0
        added = counts?.value(Int.self, .added, 0) ?? 0
        activated = counts?.value(Int.self, .activated, 0) ?? 0
        deleted = counts?.value(Int.self, .deleted, 0) ?? 0
        modified = counts?.value(Int.self, .modified, 0) ?? 0
        catchUp = counts?.value(Int.self, .catchUp, 0) ?? 0
        // Le `total` du serveur somme les quatre types historiques : `modified` s'y ajoute.
        total = (c.optional(Int.self, .total) ?? new + added + activated + deleted) + modified
        reoriented = c.optional(Int.self, .reoriented)
        siteCount = c.optional(Int.self, .siteCount)
        antennaCount = c.optional(Int.self, .antennaCount)
    }

    init(date: String, new: Int, added: Int, activated: Int, deleted: Int, modified: Int = 0, catchUp: Int = 0, total: Int? = nil,
         reoriented: Int? = nil, siteCount: Int? = nil, antennaCount: Int? = nil) {
        self.date = date
        self.new = new
        self.added = added
        self.activated = activated
        self.deleted = deleted
        self.modified = modified
        self.catchUp = catchUp
        self.total = total ?? new + added + activated + deleted + modified
        self.reoriented = reoriented
        self.siteCount = siteCount
        self.antennaCount = antennaCount
    }

    func count(for type: ANFRModType) -> Int {
        switch type {
        case .new: return new
        case .added: return added
        case .activated: return activated
        case .deleted: return deleted
        case .modified: return modified
        }
    }
}

/// Réponse de `/api/anfr/archives?weeks=N` : seule la clé `weeks` nous sert.
struct ANFRArchiveWeeks: Decodable, Sendable {
    let weeks: [ANFRWeekSummary]

    private enum CodingKeys: String, CodingKey { case weeks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weeks = c.value([ANFRWeekSummary].self, .weeks, []).filter { !$0.date.isEmpty }
    }

    init(weeks: [ANFRWeekSummary]) { self.weeks = weeks }
}

// MARK: - Réorientations (GET /api/anfr/reorientations?date=)

/// Un opérateur dont les azimuts ont changé sur un support d'une semaine à l'autre.
/// Un support partagé revient une fois par opérateur.
struct ANFRReorientation: Decodable, Sendable, Identifiable, Equatable {
    let supId: String
    let latitude: Double
    let longitude: Double
    let city: String
    let operatorRaw: String
    let systems: [String]
    /// Azimuts de la semaine précédente et de celle-ci, triés, sans appariement.
    let before: [Int]
    let after: [Int]

    var id: String { "\(supId)|\(operatorRaw)" }
    var `operator`: ANFROperator? { ANFROperator.from(raw: operatorRaw) }

    private enum CodingKeys: String, CodingKey {
        case sup_id, lat, lon, city, `operator`, systems, before, after
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supId = c.optional(String.self, .sup_id) ?? c.optional(Int.self, .sup_id).map(String.init) ?? ""
        latitude = c.optional(ANFRLooseNumber.self, .lat)?.value ?? .nan
        longitude = c.optional(ANFRLooseNumber.self, .lon)?.value ?? .nan
        city = c.value(String.self, .city, "")
        operatorRaw = c.value(String.self, .operator, "")
        systems = c.value([String].self, .systems, [])
        before = ANFRAzimuth.normalize(c.value([ANFRLooseNumber].self, .before, []).compactMap(\.value))
        after = ANFRAzimuth.normalize(c.value([ANFRLooseNumber].self, .after, []).compactMap(\.value))
    }

    init(supId: String, latitude: Double, longitude: Double, city: String, operatorRaw: String, systems: [String], before: [Int], after: [Int]) {
        self.supId = supId
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.operatorRaw = operatorRaw
        self.systems = systems
        self.before = ANFRAzimuth.normalize(before.map(Double.init))
        self.after = ANFRAzimuth.normalize(after.map(Double.init))
    }
}

/// Une semaine comparée à la précédente.
struct ANFRReorientationsWeek: Decodable, Sendable, Equatable {
    let date: String?
    let previousDate: String?
    let reorientations: [ANFRReorientation]

    private enum CodingKeys: String, CodingKey { case date, previousDate, reorientations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.optional(String.self, .date)
        previousDate = c.optional(String.self, .previousDate)
        reorientations = c.value([ANFRReorientation].self, .reorientations, []).filter { !$0.supId.isEmpty }
    }

    init(date: String?, previousDate: String?, reorientations: [ANFRReorientation]) {
        self.date = date
        self.previousDate = previousDate
        self.reorientations = reorientations
    }

    /// Un support par repère : les opérateurs d'un support partagé se rejoignent.
    /// L'antenne de chaque opérateur porte ses azimuts d'après.
    var sites: [ANFRMapSite] {
        var order: [String] = []
        var grouped: [String: [ANFRReorientation]] = [:]
        for item in reorientations {
            if grouped[item.supId] == nil { order.append(item.supId) }
            grouped[item.supId, default: []].append(item)
        }
        return order.compactMap { supId in
            guard let items = grouped[supId], let first = items.first else { return nil }
            let antennas = items.map { item in
                ANFRMapAntenna(
                    id: item.id, supId: supId, operatorRaw: item.operatorRaw,
                    system: item.systems.first ?? "", generationRaw: "", modTypeRaw: "modified",
                    statut: "", dateMaj: date ?? "", latitude: item.latitude, longitude: item.longitude,
                    city: item.city, address: nil, azimuths: item.after
                )
            }
            let site = ANFRMapSite(supId: supId, latitude: first.latitude, longitude: first.longitude, city: first.city, antennas: antennas)
            return site.hasValidCoordinate ? site : nil
        }
    }
}

// MARK: - Ouverture ciblée (notification `anfr_update`)

/// Ce que la notification de mise à jour ANFR demande d'ouvrir : un relevé précis
/// et/ou une zone surveillée. Tout champ absent ou illisible est ignoré : sans rien
/// d'utilisable l'écran s'ouvre comme avant, sur le dernier relevé et toute la France.
struct ANFRFocus: Equatable, Sendable {
    var date: String?
    var zoneLatitude: Double?
    var zoneLongitude: Double?
    var radiusMeters: Double?

    var hasZone: Bool { zoneLatitude != nil && zoneLongitude != nil }

    /// Rayon d'une zone sans rayon annoncé.
    static let defaultRadiusMeters: Double = 5_000

    static func parse(date: String?, latitude: String?, longitude: String?, radiusMeters: String?) -> ANFRFocus? {
        var focus = ANFRFocus()
        if let date, ANFRMapPolicy.isISODate(date) { focus.date = date }
        if let lat = number(latitude), let lon = number(longitude),
           (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) {
            focus.zoneLatitude = lat
            focus.zoneLongitude = lon
            if let radius = number(radiusMeters), radius > 0 {
                focus.radiusMeters = min(max(radius, 200), 100_000)
            }
        }
        return focus.date == nil && !focus.hasZone ? nil : focus
    }

    private static func number(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }
}

// MARK: - Règles du relevé

enum ANFRMapPolicy {
    /// Première date d'une série hebdomadaire régulière. Les relevés antérieurs
    /// (mai 2022) sont des différentiels énormes, des dizaines de milliers de
    /// supports : la carte ne les ouvre qu'en relevé léger.
    static let firstWeeklyDate = "2025-10-01"
    /// Au-delà de ces antennes, une semaine se charge en relevé léger.
    static let liteAntennaThreshold = 20_000
    /// Relevés cumulés au plus par une comparaison (plafond du serveur).
    static let maxComparedWeeks = 26

    static func isISODate(_ raw: String) -> Bool {
        let chars = Array(raw.utf8)
        guard chars.count == 10 else { return false }
        for (index, char) in chars.enumerated() {
            if index == 4 || index == 7 {
                guard char == 45 else { return false }
            } else {
                guard (48...57).contains(char) else { return false }
            }
        }
        return ANFRDateParser.date(from: raw) != nil
    }

    /// Relevé antérieur à la série hebdomadaire : trop lourd pour le format complet.
    static func isFullStateDate(_ raw: String) -> Bool {
        isISODate(raw) && raw < firstWeeklyDate
    }
}

// MARK: - Textes ANFR

enum ANFRText {
    private static let lowercaseWords: Set<String> = ["en", "et", "le", "la", "les", "lès", "de", "du", "des", "sur", "sous", "aux", "au", "à"]

    /// L'ANFR écrit les communes en capitales sans accents (« ST REMY EN ROLLAT ») :
    /// remises en casse française (« St Remy en Rollat », « L’Isle-d’Abeau »),
    /// comme le web. Les accents ne se devinent pas.
    static func city(_ raw: String) -> String {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return words.enumerated().map { wordIndex, word -> String in
            if wordIndex > 0, lowercaseWords.contains(word) { return word }
            return word.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { segmentIndex, segment -> String in
                let text = String(segment)
                let first = wordIndex == 0 && segmentIndex == 0
                if text.count > 2, let elided = elision(text) {
                    return (first ? elided.head.uppercased() : elided.head) + capitalized(elided.rest)
                }
                if !first, lowercaseWords.contains(text) { return text }
                return capitalized(text)
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// « d'abeau » → ("d’", "abeau") : l'élision d'un nom, apostrophe typographique.
    private static func elision(_ text: String) -> (head: String, rest: String)? {
        for apostrophe in ["'", "\u{2019}"] {
            for letter in ["d", "l"] where text.hasPrefix(letter + apostrophe) {
                return (letter + "\u{2019}", String(text.dropFirst(2)))
            }
        }
        return nil
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// « 5G NR 3500 » devient « 5G 3,5 GHz » ; « LTE 700 » devient « 4G 700 » (le séparateur suit la langue).
    static func technology(system: String, generation: String) -> String {
        let label = generation.isEmpty ? (system.split(separator: " ").first.map(String.init) ?? "") : generation
        var frequency: Int?
        for token in system.split(whereSeparator: { !$0.isNumber }) where (3...5).contains(token.count) {
            frequency = Int(token)
            break
        }
        guard let frequency, frequency > 0 else { return label.isEmpty ? system : label }
        let band = frequency >= 3000
            ? (Double(frequency) / 1000).formatted(.number.precision(.fractionLength(0...2))) + "\u{00A0}GHz"
            : String(frequency)
        return "\(label) \(band)".trimmingCharacters(in: .whitespaces)
    }

    /// Une date AAAA-MM-JJ du relevé, dite dans le fuseau du serveur : l'heure locale
    /// d'un téléphone à l'ouest de Greenwich afficherait la veille.
    static func date(_ raw: String?, month: Date.FormatStyle.Symbol.Month = .wide, year: Bool = true) -> String? {
        guard let raw, let date = ANFRDateParser.date(from: String(raw.prefix(10))) else { return nil }
        var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC") ?? .gmt).day().month(month)
        if year { style = style.year() }
        return date.formatted(style)
    }
}

// MARK: - Comparateur d'opérateurs de zone (CMP-1)

/// Rayon du comparateur (`radiusKm` de `GET /api/anfr/zone-compare`), sur l'échelle du
/// serveur : au kilomètre de 1 à 20, puis par pas de 5 jusqu'à 100.
struct ANFRZoneRadius: Hashable, Identifiable, Sendable {
    let kilometers: Int

    /// Ramène une valeur quelconque sur la marche la plus proche de l'échelle.
    init(kilometers: Int) {
        let clamped = min(max(kilometers, 1), 100)
        self.kilometers = Self.steps.min { abs($0 - clamped) < abs($1 - clamped) } ?? clamped
    }

    static let km20 = ANFRZoneRadius(kilometers: 20)
    static let km50 = ANFRZoneRadius(kilometers: 50)
    static let km100 = ANFRZoneRadius(kilometers: 100)
    /// Raccourcis proposés à côté du curseur.
    static let presets: [ANFRZoneRadius] = [.km20, .km50, .km100]
    static let `default`: ANFRZoneRadius = .km50
    /// Toutes les marches : 1…20, puis 25…100.
    static let steps: [Int] = Array(1...20) + Array(stride(from: 25, through: 100, by: 5))

    var id: Int { kilometers }

    /// Pas de la grille sur laquelle le serveur arrondit le centre (`radiusKm` × 0,001°) :
    /// deux points de la même case reçoivent la même réponse, donc le même cache mémoire.
    var gridDegrees: Double { Double(kilometers) * 0.001 }

    /// Coordonnée ramenée à la case de grille (arrondi à la demie supérieure, comme le serveur).
    func snapped(_ degrees: Double) -> Double {
        ((degrees / gridDegrees) + 0.5).rounded(.down) * gridDegrees
    }
}

/// Marchés dont l'ANFR publie les antennes : seuls ceux-là sont interrogés.
enum ANFRZoneMarket {
    static let supported: Set<String> = ["FR", "DROM"]

    /// `FR` ou `DROM` pour un code de marché du registre, `nil` sinon.
    static func apiCode(forMarket code: String?) -> String? {
        guard let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              supported.contains(normalized) else { return nil }
        return normalized
    }
}

/// Sites distincts par génération. Une génération absente de la réponse vaut 0.
struct ANFRZoneGenerations: Decodable, Equatable, Sendable {
    let g2: Int
    let g3: Int
    let g4: Int
    let g5: Int

    static let zero = ANFRZoneGenerations(g2: 0, g3: 0, g4: 0, g5: 0)

    enum CodingKeys: String, CodingKey {
        case g2 = "2G", g3 = "3G", g4 = "4G", g5 = "5G"
    }

    init(g2: Int, g3: Int, g4: Int, g5: Int) {
        self.g2 = g2
        self.g3 = g3
        self.g4 = g4
        self.g5 = g5
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        g2 = max(c.value(Int.self, .g2, 0), 0)
        g3 = max(c.value(Int.self, .g3, 0), 0)
        g4 = max(c.value(Int.self, .g4, 0), 0)
        g5 = max(c.value(Int.self, .g5, 0), 0)
    }

    /// Du plus ancien au plus récent, avec le libellé de génération.
    var ordered: [(label: String, count: Int)] {
        [("2G", g2), ("3G", g3), ("4G", g4), ("5G", g5)]
    }

    /// Somme des quatre compteurs : un site qui émet en 4G et en 5G y compte deux fois.
    var sum: Int { g2 + g3 + g4 + g5 }
}

/// Sites actifs d'une bande (identifiant 3GPP : `B20`, `n78`, `GSM900`, `U1`…).
struct ANFRZoneBandCount: Equatable, Identifiable, Sendable {
    let band: String
    let count: Int

    var id: String { band }

    /// Génération déduite de l'identifiant 3GPP ; `nil` si le préfixe est inconnu.
    var generation: String? { Self.generation(ofBand: band) }

    static func generation(ofBand band: String) -> String? {
        let id = band.trimmingCharacters(in: .whitespaces).uppercased()
        if id.hasPrefix("GSM") || id.hasPrefix("DCS") || id.hasPrefix("EGSM") { return "2G" }
        guard let first = id.first, id.dropFirst().first?.isNumber == true else { return nil }
        switch first {
        case "U": return "3G"
        case "B": return "4G"
        case "N": return "5G"
        default: return nil
        }
    }

    /// Fréquence en MHz des identifiants du registre de bandes du serveur
    /// (« U1 » est l'UMTS 2100, « n78 » couvre 3500 et 3700).
    static let megahertz: [String: Int] = [
        "GSM900": 900, "DCS1800": 1800,
        "U900": 900, "U1": 2100,
        "B28": 700, "B20": 800, "B8": 900, "B3": 1800, "B1": 2100, "B7": 2600,
        "n28": 700, "n8": 900, "n3": 1800, "n1": 2100, "n7": 2600, "n78": 3500
    ]

    var megahertz: Int? { Self.megahertz[band] }

    /// « 4G 800 » sur une pastille ; l'identifiant brut pour une bande hors registre.
    var displayName: String {
        guard let mhz = megahertz, let generation else { return band }
        return "\(generation) \(mhz)"
    }

    /// « 800 MHz » sous l'intitulé de sa génération ; l'identifiant brut hors registre.
    var frequencyLabel: String {
        megahertz.map { "\($0) MHz" } ?? band
    }

    /// « 4G 800 MHz », pour VoiceOver.
    var spokenName: String {
        guard let mhz = megahertz, let generation else { return band }
        return "\(generation) \(mhz) MHz"
    }

    /// De la génération la plus ancienne à la plus récente, puis par fréquence croissante.
    static func sorted(_ bands: [ANFRZoneBandCount]) -> [ANFRZoneBandCount] {
        func rank(_ band: ANFRZoneBandCount) -> Int {
            ["2G": 2, "3G": 3, "4G": 4, "5G": 5][band.generation ?? ""] ?? 9
        }
        func number(_ band: ANFRZoneBandCount) -> Int {
            band.megahertz ?? Int(band.band.filter(\.isNumber)) ?? 0
        }
        return bands.sorted { a, b in
            (rank(a), number(a), a.band) < (rank(b), number(b), b.band)
        }
    }
}

/// Un opérateur du comparateur de zone. Clés absentes = 0 ; `bands` seulement avec `bands=1`.
struct ANFRZoneOperator: Decodable, Equatable, Identifiable, Sendable {
    let key: String
    let active: Int
    let planned: Int
    let generations: ANFRZoneGenerations
    let bands: [ANFRZoneBandCount]?

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, active, planned, generations, bands }

    init(key: String, active: Int, planned: Int, generations: ANFRZoneGenerations, bands: [ANFRZoneBandCount]? = nil) {
        self.key = key
        self.active = active
        self.planned = planned
        self.generations = generations
        self.bands = bands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKey = try c.decode(String.self, forKey: .key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "empty operator key")
        }
        key = rawKey
        active = max(c.value(Int.self, .active, 0), 0)
        planned = max(c.value(Int.self, .planned, 0), 0)
        generations = c.value(ANFRZoneGenerations.self, .generations, .zero)
        bands = Self.decodeBands(c)
    }

    /// `{"4G": {"B20": 120, "B3": 98}, "5G": {"n78": 44}}` : sites actifs par bande, groupés par
    /// génération ; une génération ou une bande à 0 est omise. Absente ou illisible : `nil`.
    private static func decodeBands(_ c: KeyedDecodingContainer<CodingKeys>) -> [ANFRZoneBandCount]? {
        guard let byGeneration = try? c.decodeIfPresent([String: [String: Int]].self, forKey: .bands) else { return nil }
        return byGeneration.values.flatMap { bands in
            bands.map { ANFRZoneBandCount(band: $0.key, count: max($0.value, 0)) }
        }
    }
}

/// `GET /api/anfr/zone-compare` : sites ANFR en service et en projet autour d'un point.
struct ANFRZoneCompare: Decodable, Equatable, Sendable {
    let market: String
    /// Unité comptée (`site` : un support ANFR, quel que soit son nombre d'antennes).
    let unit: String
    /// Définition de « en service », affichée telle que le serveur la donne.
    let activeDefinition: String
    let snapshotDate: String?
    let snapshotSource: String?
    let radiusKm: Int
    let totalActive: Int
    let totalPlanned: Int
    let totalByGeneration: ANFRZoneGenerations
    let operators: [ANFRZoneOperator]
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case market, unit, activeDefinition, snapshot, radiusKm, total, totalByGeneration, operators, requestId
    }

    private struct Snapshot: Decodable {
        let date: String?
        let source: String?
    }

    private struct Total: Decodable {
        let active: Int
        let planned: Int

        static let zero = Total(active: 0, planned: 0)

        enum CodingKeys: String, CodingKey { case active, planned }
        init(active: Int, planned: Int) {
            self.active = active
            self.planned = planned
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            active = max(c.value(Int.self, .active, 0), 0)
            planned = max(c.value(Int.self, .planned, 0), 0)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        market = c.value(String.self, .market, "")
        unit = c.value(String.self, .unit, "site")
        activeDefinition = c.value(String.self, .activeDefinition, "")
        let snapshot = c.optional(Snapshot.self, .snapshot)
        snapshotDate = snapshot?.date
        snapshotSource = snapshot?.source
        radiusKm = c.value(Int.self, .radiusKm, 0)
        let total = c.value(Total.self, .total, Total.zero)
        totalActive = total.active
        totalPlanned = total.planned
        totalByGeneration = c.value(ANFRZoneGenerations.self, .totalByGeneration, .zero)
        operators = c.decodeLossyArray([ANFRZoneOperator].self, forKey: .operators)
        requestId = c.optional(String.self, .requestId)
    }

    init(market: String, unit: String = "site", activeDefinition: String, snapshotDate: String?, snapshotSource: String?,
         radiusKm: Int, totalActive: Int, totalPlanned: Int, totalByGeneration: ANFRZoneGenerations,
         operators: [ANFRZoneOperator], requestId: String? = nil) {
        self.market = market
        self.unit = unit
        self.activeDefinition = activeDefinition
        self.snapshotDate = snapshotDate
        self.snapshotSource = snapshotSource
        self.radiusKm = radiusKm
        self.totalActive = totalActive
        self.totalPlanned = totalPlanned
        self.totalByGeneration = totalByGeneration
        self.operators = operators
        self.requestId = requestId
    }

    /// Vrai si la réponse porte le détail par bande (`bands=1`).
    var hasBands: Bool { operators.contains { $0.bands != nil } }

    /// Une ligne du tableau des bandes : les sites actifs de chaque opérateur sur cette bande.
    struct BandRow: Identifiable, Equatable, Sendable {
        let band: ANFRZoneBandCount
        /// Clé d'opérateur → sites actifs ; absent = aucun.
        let counts: [String: Int]
        var id: String { band.band }
    }

    struct BandGroup: Identifiable, Equatable, Sendable {
        let generation: String
        let rows: [BandRow]
        var id: String { generation }
    }

    /// Tableau bandes × opérateurs, groupé de la 2G à la 5G puis par fréquence.
    var bandGroups: [BandGroup] {
        var counts: [String: [String: Int]] = [:]
        for item in operators {
            for band in item.bands ?? [] where band.count > 0 {
                counts[band.band, default: [:]][item.key] = band.count
            }
        }
        let sorted = ANFRZoneBandCount.sorted(counts.keys.map { ANFRZoneBandCount(band: $0, count: 0) })
        var groups: [BandGroup] = []
        for band in sorted {
            let row = BandRow(band: band, counts: counts[band.band] ?? [:])
            let generation = band.generation ?? "?"
            if let last = groups.last, last.generation == generation {
                groups[groups.count - 1] = BandGroup(generation: generation, rows: last.rows + [row])
            } else {
                groups.append(BandGroup(generation: generation, rows: [row]))
            }
        }
        return groups
    }

    /// Plus grand nombre de sites d'une case du tableau : il fixe la densité des teintes.
    var bandCellMax: Int {
        operators.flatMap { $0.bands ?? [] }.map(\.count).max() ?? 0
    }

    /// Largeur de barre de chaque opérateur : part de la plus grande somme de générations de
    /// la zone, découpée en segments 2G/3G/4G/5G. Les fractions d'un opérateur totalisent au plus 1.
    struct BarSegment: Equatable, Sendable {
        let generation: String
        let count: Int
        let fraction: Double
    }

    func barSegments(for item: ANFRZoneOperator) -> [BarSegment] {
        let scale = max(operators.map { $0.generations.sum }.max() ?? 0, 1)
        return item.generations.ordered.map {
            BarSegment(generation: $0.label, count: $0.count, fraction: min(max(Double($0.count) / Double(scale), 0), 1))
        }
    }
}
