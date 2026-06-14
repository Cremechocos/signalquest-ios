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
    let effectiveDate: String?

    enum CodingKeys: String, CodingKey {
        case id, technology, generation, statut, effectiveDate
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
    }

    init(id: String, operatorRaw: String, technology: String, generation: String, modTypeRaw: String, statut: String, effectiveDate: String?) {
        self.id = id
        self.operatorRaw = operatorRaw
        self.technology = technology
        self.generation = generation
        self.modTypeRaw = modTypeRaw
        self.statut = statut
        self.effectiveDate = effectiveDate
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
    /// Snapshot carte : tous les sites du relevé `date` (ou le dernier si `nil`).
    func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot
    /// Dates d'archives disponibles + relevé courant (sélecteur de date carte).
    func archiveDates() async throws -> ANFRArchiveDates
}

final class ANFRService: ANFRServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

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
        try await api.request(APIEndpoint(path: "/api/anfr/site-history/\(supId)"), as: ANFRSiteHistory.self)
    }

    func stats() async throws -> ANFRStats {
        try await api.request(APIEndpoint(path: "/api/anfr/stats"), as: ANFRStats.self)
    }

    func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot {
        let query = date.map { [URLQueryItem(name: "date", value: $0)] } ?? []
        return try await api.request(
            APIEndpoint(path: "/api/anfr/map-snapshot", query: query),
            as: ANFRMapSnapshot.self
        )
    }

    func archiveDates() async throws -> ANFRArchiveDates {
        try await api.request(APIEndpoint(path: "/api/anfr/archives"), as: ANFRArchiveDates.self)
    }
}
