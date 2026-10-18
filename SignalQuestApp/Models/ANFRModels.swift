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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: return String(localized: "Nouveau support")
        case .activated: return String(localized: "Mise en service")
        case .deleted: return String(localized: "Antenne retirée")
        case .added: return String(localized: "Antenne ajoutée")
        }
    }

    var glyph: String {
        switch self {
        case .new: return "star.fill"
        case .activated: return "checkmark"
        case .deleted: return "xmark"
        case .added: return "plus"
        }
    }

    var color: Color {
        switch self {
        case .new: return SQColor.info
        case .activated: return SQColor.success
        case .deleted: return SQColor.danger
        case .added: return SQColor.label
        }
    }

    /// Rang de priorité pour choisir le type dominant d'un site (ordre du web).
    var priority: Int {
        switch self {
        case .new: return 4
        case .added: return 3
        case .activated: return 2
        case .deleted: return 1
        }
    }

    static func from(raw: String?) -> ANFRModType {
        switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "activated": return .activated
        case "deleted": return .deleted
        case "new": return .new
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
    /// Vrai quand la copie vient du disque faute de réseau (relevé courant).
    var servedFromCache = false

    enum CodingKeys: String, CodingKey {
        case source, snapshotDate, lastUpdate, siteCount, sites
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
    }

    init(source: String?, snapshotDate: String?, lastUpdate: String?, sites: [ANFRMapSite]) {
        self.source = source
        self.snapshotDate = snapshotDate
        self.lastUpdate = lastUpdate
        self.sites = sites
        self.siteCount = sites.count
    }
}

/// Un site ANFR (un support) et ses antennes modifiées au relevé.
struct ANFRMapSite: Decodable, Sendable, Identifiable, Equatable {
    let supId: String
    let latitude: Double
    let longitude: Double
    let city: String
    let antennas: [ANFRMapAntenna]

    var id: String { supId }

    enum CodingKeys: String, CodingKey {
        case info, antennas
    }
    private enum InfoKeys: String, CodingKey {
        case sup_id, lat, lon, city
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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

    init(supId: String, latitude: Double, longitude: Double, city: String, antennas: [ANFRMapAntenna]) {
        self.supId = supId
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.antennas = antennas
    }

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
        antennas.map(\.modType).max { $0.priority < $1.priority } ?? .activated
    }

    /// Génération la plus élevée présente sur le site.
    var highestGeneration: ANFRGeneration? {
        antennas.compactMap(\.generationEnum).max { $0.rank < $1.rank }
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
    /// Morceaux d'adresse bruts, assemblés à la demande (`address`).
    private let addressLieu: String?
    private let addressLine: String?
    private let postalCode: String?

    enum CodingKeys: String, CodingKey {
        case id, sup_id, adm_lb_nom, emr_lb_systeme, generation, type, statut, date_maj
        case lat, lon, city, changeDate, catchUp
        case adr_lb_lieu, adr_lb_add1, adr_nm_cp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(String.self, .id, UUID().uuidString)
        supId = c.optional(String.self, .sup_id)
        operatorRaw = c.value(String.self, .adm_lb_nom, "")
        system = c.value(String.self, .emr_lb_systeme, "")
        generationRaw = c.value(String.self, .generation, "")
        modTypeRaw = c.value(String.self, .type, "")
        statut = c.value(String.self, .statut, "")
        dateMaj = c.value(String.self, .date_maj, "")
        latitude = Double(c.optional(String.self, .lat) ?? "")
        longitude = Double(c.optional(String.self, .lon) ?? "")
        city = c.optional(String.self, .city)
        changeDate = c.optional(String.self, .changeDate)
        catchUp = c.value(Bool.self, .catchUp, false)
        addressLieu = c.optional(String.self, .adr_lb_lieu)
        addressLine = c.optional(String.self, .adr_lb_add1)
        postalCode = c.optional(String.self, .adr_nm_cp)
    }

    init(id: String, supId: String?, operatorRaw: String, system: String, generationRaw: String, modTypeRaw: String, statut: String, dateMaj: String, latitude: Double?, longitude: Double?, city: String?, address: String?,
         changeDate: String? = nil, catchUp: Bool = false) {
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
    let catchUp: Int
    let total: Int

    var id: String { date }

    private enum CodingKeys: String, CodingKey { case date, counts, total }
    private enum CountKeys: String, CodingKey { case new, added, activated, deleted, catchUp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.value(String.self, .date, "")
        let counts = try? c.nestedContainer(keyedBy: CountKeys.self, forKey: .counts)
        new = counts?.value(Int.self, .new, 0) ?? 0
        added = counts?.value(Int.self, .added, 0) ?? 0
        activated = counts?.value(Int.self, .activated, 0) ?? 0
        deleted = counts?.value(Int.self, .deleted, 0) ?? 0
        catchUp = counts?.value(Int.self, .catchUp, 0) ?? 0
        total = c.value(Int.self, .total, new + added + activated + deleted)
    }

    init(date: String, new: Int, added: Int, activated: Int, deleted: Int, catchUp: Int = 0, total: Int? = nil) {
        self.date = date
        self.new = new
        self.added = added
        self.activated = activated
        self.deleted = deleted
        self.catchUp = catchUp
        self.total = total ?? new + added + activated + deleted
    }

    func count(for type: ANFRModType) -> Int {
        switch type {
        case .new: return new
        case .added: return added
        case .activated: return activated
        case .deleted: return deleted
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
    /// (mai 2022) sont l'état complet du parc, des dizaines de milliers de supports,
    /// et non un différentiel : la carte ne les ouvre pas.
    static let firstWeeklyDate = "2025-10-01"

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

    /// Relevé d'état complet (et non d'un différentiel hebdomadaire) à ne pas charger.
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
