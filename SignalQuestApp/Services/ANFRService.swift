import Foundation

struct ANFRDataset: Codable {
    let date: String?
    let version: String?
    let sitesCount: Int?
    let antennasCount: Int?
}

/// Historique des modifications d'un site ANFR
/// (`GET /api/anfr/site-history/{supId}`). Forme réelle : `entries` regroupées
/// par date d'archive, chacune listant ses `changes`. Décodage tolérant.
struct ANFRSiteHistory: Decodable, Sendable {
    let supId: String
    let currentSnapshotDate: String?
    let entries: [ANFRSiteHistoryEntry]

    enum CodingKeys: String, CodingKey { case supId, currentSnapshotDate, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supId = (try? c.decodeIfPresent(String.self, forKey: .supId)) ?? ""
        currentSnapshotDate = (try? c.decodeIfPresent(String.self, forKey: .currentSnapshotDate)) ?? nil
        entries = (try? c.decodeIfPresent([ANFRSiteHistoryEntry].self, forKey: .entries)) ?? []
    }

    init(supId: String, currentSnapshotDate: String?, entries: [ANFRSiteHistoryEntry]) {
        self.supId = supId
        self.currentSnapshotDate = currentSnapshotDate
        self.entries = entries
    }
}

/// Un relevé daté de l'historique : ses opérateurs, ses types de modif, ses
/// changements d'antennes.
struct ANFRSiteHistoryEntry: Decodable, Sendable, Identifiable {
    let archiveDate: String
    let isCurrentSnapshot: Bool
    let city: String
    let address: String?
    let operators: [String]
    let modTypes: [String]
    let changeCount: Int
    let changes: [ANFRSiteHistoryChange]

    var id: String { archiveDate }

    enum CodingKeys: String, CodingKey {
        case archiveDate, isCurrentSnapshot, city, address, operators, modTypes, changeCount, changes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archiveDate = (try? c.decodeIfPresent(String.self, forKey: .archiveDate)) ?? ""
        isCurrentSnapshot = (try? c.decodeIfPresent(Bool.self, forKey: .isCurrentSnapshot)) ?? false
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? ""
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? nil
        operators = (try? c.decodeIfPresent([String].self, forKey: .operators)) ?? []
        modTypes = (try? c.decodeIfPresent([String].self, forKey: .modTypes)) ?? []
        let parsedChanges = (try? c.decodeIfPresent([ANFRSiteHistoryChange].self, forKey: .changes)) ?? []
        changes = parsedChanges
        changeCount = (try? c.decodeIfPresent(Int.self, forKey: .changeCount)) ?? parsedChanges.count
    }

    init(archiveDate: String, isCurrentSnapshot: Bool, city: String, address: String?, operators: [String], modTypes: [String], changeCount: Int, changes: [ANFRSiteHistoryChange]) {
        self.archiveDate = archiveDate
        self.isCurrentSnapshot = isCurrentSnapshot
        self.city = city
        self.address = address
        self.operators = operators
        self.modTypes = modTypes
        self.changeCount = changeCount
        self.changes = changes
    }
}

/// Une modification d'antenne au sein d'un relevé daté.
struct ANFRSiteHistoryChange: Decodable, Sendable, Identifiable {
    let id: String
    let operatorRaw: String
    let technology: String
    let generation: String
    let modTypeRaw: String
    let statut: String
    /// Date du changement : sa date réelle (mise en service déclarée), sinon celle du relevé.
    let effectiveDate: String?
    /// Rattrapage : la date réelle précède de plus de 30 jours le relevé.
    let catchUp: Bool

    enum CodingKeys: String, CodingKey {
        case id, technology, generation, statut, effectiveDate, catchUp
        case operatorRaw = "operator"
        case modTypeRaw = "modType"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        operatorRaw = (try? c.decodeIfPresent(String.self, forKey: .operatorRaw)) ?? ""
        technology = (try? c.decodeIfPresent(String.self, forKey: .technology)) ?? ""
        generation = (try? c.decodeIfPresent(String.self, forKey: .generation)) ?? ""
        modTypeRaw = (try? c.decodeIfPresent(String.self, forKey: .modTypeRaw)) ?? ""
        statut = (try? c.decodeIfPresent(String.self, forKey: .statut)) ?? ""
        effectiveDate = (try? c.decodeIfPresent(String.self, forKey: .effectiveDate)) ?? nil
        catchUp = (try? c.decodeIfPresent(Bool.self, forKey: .catchUp)) ?? false
    }

    init(id: String, operatorRaw: String, technology: String, generation: String, modTypeRaw: String, statut: String, effectiveDate: String?, catchUp: Bool = false) {
        self.id = id
        self.operatorRaw = operatorRaw
        self.technology = technology
        self.generation = generation
        self.modTypeRaw = modTypeRaw
        self.statut = statut
        self.effectiveDate = effectiveDate
        self.catchUp = catchUp
    }
}

/// `GET /api/anfr/archives` → dates disponibles + relevé courant.
struct ANFRArchiveDates: Decodable, Sendable {
    let dates: [String]
    let current: String?

    enum CodingKeys: String, CodingKey { case dates, current }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dates = (try? c.decodeIfPresent([String].self, forKey: .dates)) ?? []
        current = (try? c.decodeIfPresent(String.self, forKey: .current)) ?? nil
    }

    init(dates: [String], current: String?) {
        self.dates = dates
        self.current = current
    }
}

protocol ANFRServicing: Sendable {
    func current() async throws -> ANFRDataset
    func archives() async throws -> [ANFRDataset]
    func search(query: String) async throws -> [AntennaSite]
    func siteHistory(supId: String) async throws -> ANFRSiteHistory
    /// Statistiques nationales agrégées (séries, dernier relevé, régions).
    func stats() async throws -> ANFRStats
    /// Progression par génération et par bande (contrat `view=bands` v1) ;
    /// `weeks` : les N derniers relevés (1 à 520), nul pour tout l'historique.
    /// Toujours filtrée (génération, opérateur, semaines) : la réponse complète
    /// pèse 2,2 Mo, une génération d'un opérateur sur 53 semaines 20 à 45 Ko.
    func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats
    /// Snapshot carte : tous les sites du relevé `date` (ou le dernier si `nil`).
    func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot
    /// Relevé léger d'une date : supports et compteurs par type, sans les antennes.
    func mapSnapshotLite(date: String) async throws -> ANFRMapSnapshot
    /// Changements nets entre le relevé `from` et le relevé `to` (le dernier si `nil`).
    func mapDiff(from: String, to: String?) async throws -> ANFRMapDiff
    /// Dates d'archives disponibles + relevé courant (sélecteur de date carte).
    func archiveDates() async throws -> ANFRArchiveDates
    /// Les `count` dernières semaines avec leurs compteurs par type (barres de la carte).
    func archiveWeeks(count: Int) async throws -> [ANFRWeekSummary]
    /// Supports réorientés au relevé `date` (le dernier si `nil`) ; `nil` quand
    /// aucune réorientation n'est connue pour cette semaine.
    func reorientations(date: String?) async throws -> ANFRReorientationsWeek?
    /// Sites ANFR en service et en projet autour d'un point, par opérateur du marché
    /// (`market` : `FR` ou `DROM`). `includeBands` ajoute le détail par bande.
    func zoneCompare(latitude: Double, longitude: Double, radius: ANFRZoneRadius,
                     market: String, includeBands: Bool) async throws -> ANFRZoneCompare
}

extension ANFRServicing {
    /// Les services qui n'affichent pas de barres n'ont rien à fournir.
    func archiveWeeks(count: Int) async throws -> [ANFRWeekSummary] { [] }

    /// Les services sans couche des réorientations n'en connaissent aucune.
    func reorientations(date: String?) async throws -> ANFRReorientationsWeek? { nil }

    /// Les services sans mode léger ne savent ni l'un ni l'autre.
    func mapSnapshotLite(date: String) async throws -> ANFRMapSnapshot { throw URLError(.unsupportedURL) }
    func mapDiff(from: String, to: String?) async throws -> ANFRMapDiff { throw URLError(.unsupportedURL) }

    /// Les services qui ne comparent pas les opérateurs d'une zone n'ont rien à fournir.
    func zoneCompare(latitude: Double, longitude: Double, radius: ANFRZoneRadius,
                     market: String, includeBands: Bool) async throws -> ANFRZoneCompare {
        throw APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
    }
}

final class ANFRService: ANFRServicing {
    private let api: APIClient
    private let diskCache: ANFRSnapshotDiskCache
    init(api: APIClient, diskCache: ANFRSnapshotDiskCache = ANFRSnapshotDiskCache()) {
        self.api = api
        self.diskCache = diskCache
    }

    func current() async throws -> ANFRDataset {
        try await api.request(APIEndpoint(path: "/api/anfr/current"), as: ANFRDataset.self)
    }

    func archives() async throws -> [ANFRDataset] {
        struct Response: Decodable {
            let archives: [ANFRDataset]
            enum CodingKeys: String, CodingKey { case archives, items }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                archives = (try? c.decode([ANFRDataset].self, forKey: .archives))
                    ?? (try? c.decode([ANFRDataset].self, forKey: .items))
                    ?? []
            }
        }
        return try await api.request(APIEndpoint(path: "/api/anfr/archives"), as: Response.self).archives
    }

    func search(query: String) async throws -> [AntennaSite] {
        try await api.request(
            APIEndpoint(path: "/api/anfr/search", query: [URLQueryItem(name: "q", value: query)]),
            as: AntennasListResponse.self
        ).antennas
    }

    func siteHistory(supId: String) async throws -> ANFRSiteHistory {
        let encoded = supId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? supId
        return try await api.request(APIEndpoint(path: "/api/anfr/site-history/\(encoded)"), as: ANFRSiteHistory.self)
    }

    func stats() async throws -> ANFRStats {
        try await api.request(APIEndpoint(path: "/api/anfr/stats"), as: ANFRStats.self)
    }

    func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
        var query = [URLQueryItem(name: "view", value: "bands")]
        if let generation { query.append(URLQueryItem(name: "generation", value: generation)) }
        if let operatorKey { query.append(URLQueryItem(name: "operator", value: operatorKey)) }
        if let weeks { query.append(URLQueryItem(name: "weeks", value: String(min(max(weeks, 1), 520)))) }
        return try await api.request(APIEndpoint(path: "/api/anfr/stats", query: query), as: ANFRBandStats.self)
    }

    /// Un relevé daté est immuable : lu sur le disque quand il y est, sinon
    /// téléchargé puis gardé. Le relevé courant se revalide à chaque appel et ne
    /// sert depuis le disque qu'à défaut de réseau (`servedFromCache`).
    func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot {
        if let date, let cached = diskCache.read(key: date), let snapshot = Self.decode(cached) {
            return snapshot
        }
        let query = date.map { [URLQueryItem(name: "date", value: $0)] } ?? []
        let data: Data
        do {
            data = try await api.requestData(APIEndpoint(path: "/api/anfr/map-snapshot", query: query))
        } catch {
            if date == nil, !error.isCancellation, var cached = diskCache.read(key: Self.currentKey).flatMap(Self.decode) {
                cached.servedFromCache = true
                return cached
            }
            throw error
        }
        guard let snapshot = Self.decode(data) else { throw APIError.decoding("map-snapshot") }
        diskCache.write(data, key: date ?? Self.currentKey)
        return snapshot
    }

    /// Relevé léger : demandé seulement quand le serveur l'annonce (`siteCount` des
    /// semaines), un relevé figé, gardé sur le disque comme le complet.
    func mapSnapshotLite(date: String) async throws -> ANFRMapSnapshot {
        let key = "lite-\(date)"
        if let cached = diskCache.read(key: key), let snapshot = Self.decode(cached), snapshot.isLite {
            return snapshot
        }
        let data = try await api.requestData(APIEndpoint(path: "/api/anfr/map-snapshot", query: [
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "fields", value: "lite")
        ]))
        guard let snapshot = Self.decode(data), snapshot.isLite else { throw APIError.decoding("map-snapshot") }
        diskCache.write(data, key: key)
        return snapshot
    }

    /// Une comparaison entre deux relevés figés ne change plus : gardée sur le disque.
    /// Celle qui va jusqu'au dernier relevé se redemande.
    func mapDiff(from: String, to: String?) async throws -> ANFRMapDiff {
        let key = to.map { "diff-\(from)-\($0)" }
        if let key, let cached = diskCache.read(key: key),
           let diff = try? JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: cached) {
            return diff
        }
        let data = try await api.requestData(APIEndpoint(path: "/api/anfr/map-diff", query: [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to ?? "current")
        ]))
        guard let diff = try? JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: data) else {
            throw APIError.decoding("map-diff")
        }
        if let key { diskCache.write(data, key: key) }
        return diff
    }

    private static let currentKey = "current"

    private static func decode(_ data: Data) -> ANFRMapSnapshot? {
        try? JSONDecoder.signalQuest.decode(ANFRMapSnapshot.self, from: data)
    }

    func archiveDates() async throws -> ANFRArchiveDates {
        try await api.request(APIEndpoint(path: "/api/anfr/archives"), as: ANFRArchiveDates.self)
    }

    /// Lecture ANFR de l'app (session, comme les autres routes `anfr`). Le centre part déjà
    /// ramené à la case de grille du serveur : la requête ne porte pas plus de précision
    /// que celle qu'il utilise, et la réponse est la même.
    static func zoneCompareEndpoint(latitude: Double, longitude: Double, radius: ANFRZoneRadius,
                                    market: String, includeBands: Bool) -> APIEndpoint {
        var query = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", radius.snapped(latitude))),
            URLQueryItem(name: "lon", value: String(format: "%.4f", radius.snapped(longitude))),
            URLQueryItem(name: "radiusKm", value: String(radius.kilometers)),
            URLQueryItem(name: "market", value: market)
        ]
        if includeBands { query.append(URLQueryItem(name: "bands", value: "1")) }
        return APIEndpoint(path: "/api/anfr/zone-compare", query: query)
    }

    func zoneCompare(latitude: Double, longitude: Double, radius: ANFRZoneRadius,
                     market: String, includeBands: Bool) async throws -> ANFRZoneCompare {
        try await api.request(
            Self.zoneCompareEndpoint(latitude: latitude, longitude: longitude, radius: radius,
                                     market: market, includeBands: includeBands),
            as: ANFRZoneCompare.self
        )
    }

    func archiveWeeks(count: Int) async throws -> [ANFRWeekSummary] {
        let weeks = min(max(count, 1), 26)
        return try await api.request(
            APIEndpoint(path: "/api/anfr/archives", query: [URLQueryItem(name: "weeks", value: String(weeks))]),
            as: ANFRArchiveWeeks.self
        ).weeks
    }

    /// 404 : semaine inconnue ou pas encore calculée, donc aucune réorientation connue.
    func reorientations(date: String?) async throws -> ANFRReorientationsWeek? {
        let query = date.map { [URLQueryItem(name: "date", value: $0)] } ?? []
        do {
            return try await api.request(APIEndpoint(path: "/api/anfr/reorientations", query: query), as: ANFRReorientationsWeek.self)
        } catch APIError.http(let status, _, _, _, _) where status == 404 {
            return nil
        }
    }
}

/// Copies disque des relevés de la carte. Données publiques de l'ANFR, sans lien
/// avec un compte : un dossier du système, que iOS peut purger quand la place manque.
struct ANFRSnapshotDiskCache: Sendable {
    let directory: URL
    /// Nombre de relevés gardés ; les moins récemment utilisés (écrits ou relus) partent.
    let maxFiles: Int

    init(directory: URL? = nil, maxFiles: Int = 12) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? base.appendingPathComponent("SignalQuestANFRMap", isDirectory: true)
        self.maxFiles = maxFiles
    }

    private func url(for key: String) -> URL {
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("map-\(safe).json")
    }

    func read(key: String) -> Data? {
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Un relevé relu est un relevé utile : sa date de modification passe à maintenant,
        // pour que `trim` retire d'abord ceux qu'on ne consulte plus.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func write(_ data: Data, key: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
        trim()
    }

    private func trim() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)),
              files.count > maxFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? Date.distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? manager.removeItem(at: file)
        }
    }
}
