import Foundation

// MARK: - Modèles de regroupement (miroir opérateur → nœud eNB/gNB → cellule)

struct RadioLogImportNodeGroup: Identifiable {
    let id: String            // nodeKey
    let title: String         // "eNB 626821" / "gNB 2098315" / "PCI 288 · NR"
    let cells: [ParsedRadioLogRow]
    let techs: [String]       // ex. ["5G","4G"]
    let pciCount: Int
    var cellCount: Int { cells.count }
    /// Label de l'identifiant cellule selon la techno (NCI/ECI/CellID).
    let cellIdLabel: String
}

struct RadioLogImportOperatorSection: Identifiable {
    let id: String
    let label: String
    let nodes: [RadioLogImportNodeGroup]
    var antennaCount: Int { nodes.count }
    var cellCount: Int { nodes.reduce(0) { $0 + $1.cellCount } }
}

@MainActor
final class RadioLogImportsViewModel: ObservableObject {
    enum Phase: Equatable { case loading, empty, ready, error(String) }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var sections: [RadioLogImportOperatorSection] = []
    @Published private(set) var statusById: [UUID: RadioLogImportCellStatus] = [:]
    @Published private(set) var resolving = false
    @Published private(set) var importing = false
    @Published var errorMessage: String?

    private let service: RadioLogImportServicing
    private var allRows: [ParsedRadioLogRow] = []
    private var rowBatchId: [UUID: UUID] = [:]
    private var resolveTask: Task<Void, Never>?

    init(service: RadioLogImportServicing) {
        self.service = service
    }

    // MARK: - Chargement

    func load() {
        do {
            let imports = try service.storedImports()
            rowBatchId = [:]
            allRows = imports.flatMap { batch -> [ParsedRadioLogRow] in
                for row in batch.rows { rowBatchId[row.id] = batch.id }
                return batch.rows
            }
            rebuildSections()
            phase = allRows.isEmpty ? .empty : .ready
            startResolving()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Import fichier

    func importPicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        importing = true
        Task {
            do {
                let (fileName, content) = try Self.readFile(url)
                _ = try await service.importFile(fileName: fileName, content: content)
                importing = false
                load()
            } catch {
                importing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Résolution progressive

    private func startResolving() {
        resolveTask?.cancel()
        let unresolved = allRows.filter {
            let s = statusById[$0.id]
            return s == nil || s == .pending
        }
        guard !unresolved.isEmpty else { return }
        for row in unresolved where statusById[row.id] == nil { statusById[row.id] = .pending }
        resolving = true
        resolveTask = Task {
            for await batch in service.resolveStream(rows: unresolved) {
                for resolved in batch {
                    // Ne pas écraser un « Identifié » déjà écrit par l'utilisateur.
                    if statusById[resolved.id] == .identified { continue }
                    statusById[resolved.id] = resolved.matched
                        ? .identifiable(siteId: resolved.siteId ?? "", distanceMeters: resolved.distanceMeters)
                        : .notFound
                }
            }
            resolving = false
        }
    }

    // MARK: - Suppression

    func deleteNode(_ node: RadioLogImportNodeGroup) {
        deleteRows(node.cells.map(\.id))
    }

    func deleteCell(_ row: ParsedRadioLogRow) {
        deleteRows([row.id])
    }

    func deleteAll() {
        do {
            for batch in try service.storedImports() { try service.deleteBatch(id: batch.id) }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRows(_ ids: [UUID]) {
        let byBatch = Dictionary(grouping: ids.compactMap { id in rowBatchId[id].map { (id, $0) } }, by: { $0.1 })
        do {
            for (batchId, pairs) in byBatch {
                try service.deleteRows(batchId: batchId, rowIds: Set(pairs.map(\.0)))
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Identification (écriture)

    func identifyNode(_ node: RadioLogImportNodeGroup) {
        let rows = node.cells.compactMap(resolvableRow(for:))
        guard !rows.isEmpty else { return }
        identify(rows)
    }

    func identifyCell(_ row: ParsedRadioLogRow) {
        guard let resolvable = resolvableRow(for: row) else { return }
        identify([resolvable])
    }

    private func identify(_ rows: [ResolvedRadioLogRow]) {
        Task {
            let outcome = await service.confirm(rows: rows)
            if outcome.submitted > 0 {
                for r in rows where r.matched { statusById[r.id] = .identified }
            }
            if outcome.failed > 0 {
                errorMessage = "\(outcome.failed) identification(s) ont échoué."
            }
        }
    }

    /// Construit une ligne résoluble (site rattaché) à partir du statut courant.
    private func resolvableRow(for row: ParsedRadioLogRow) -> ResolvedRadioLogRow? {
        guard case let .identifiable(siteId, distance) = statusById[row.id], !siteId.isEmpty else { return nil }
        return ResolvedRadioLogRow(id: row.id, row: row, siteId: siteId, matched: true, distanceMeters: distance)
    }

    func status(for row: ParsedRadioLogRow) -> RadioLogImportCellStatus {
        statusById[row.id] ?? .pending
    }

    // MARK: - Regroupement

    private func rebuildSections() {
        let byOperator = Dictionary(grouping: allRows, by: Self.operatorKey)
        sections = byOperator.map { key, rows in
            let byNode = Dictionary(grouping: rows, by: Self.nodeKey)
            let nodes: [RadioLogImportNodeGroup] = byNode.map { nodeKey, nodeRows in
                let sortedCells = nodeRows.sorted { ($0.pci ?? 0) < ($1.pci ?? 0) }
                let pcis = Set(nodeRows.compactMap { $0.pci })
                let techs = orderedTechs(nodeRows)
                return RadioLogImportNodeGroup(
                    id: nodeKey,
                    title: Self.nodeTitle(nodeRows[0]),
                    cells: sortedCells,
                    techs: techs,
                    pciCount: pcis.count,
                    cellIdLabel: Self.cellIdLabel(nodeRows[0])
                )
            }
            .sorted { $0.title < $1.title }
            return RadioLogImportOperatorSection(
                id: key,
                label: Self.operatorLabel(rows[0]),
                nodes: nodes
            )
        }
        .sorted { $0.label < $1.label }
    }

    private func orderedTechs(_ rows: [ParsedRadioLogRow]) -> [String] {
        let order = ["5G", "4G", "3G", "2G"]
        let present = Set(rows.compactMap { row -> String? in
            switch (row.technology ?? "").uppercased() {
            case let t where t.contains("NR") || t.contains("5G"): return "5G"
            case let t where t.contains("LTE") || t.contains("4G"): return "4G"
            case let t where t.contains("UMTS") || t.contains("3G"): return "3G"
            case let t where t.contains("GSM") || t.contains("2G"): return "2G"
            default: return nil
            }
        })
        return order.filter { present.contains($0) }
    }

    // MARK: - Clés / libellés (miroir RadioLogAnalytics)

    static func operatorKey(_ row: ParsedRadioLogRow) -> String {
        if let mcc = row.mcc, let mnc = row.mnc { return "\(mcc)/\(mnc)" }
        return (row.operatorName ?? "?").uppercased()
    }

    static func operatorLabel(_ row: ParsedRadioLogRow) -> String {
        if let name = row.operatorName, !name.isEmpty { return name.uppercased() }
        if row.mcc == "208", let mnc = row.mnc {
            switch mnc { case "1", "2": return "ORANGE"; case "10", "11", "13": return "SFR"
            case "15", "16": return "FREE"; case "20", "21", "88": return "BOUYGUES"; default: break }
        }
        if let mcc = row.mcc, let mnc = row.mnc { return "MCC \(mcc) / MNC \(mnc)" }
        return "INCONNU"
    }

    static func nodeKey(_ row: ParsedRadioLogRow) -> String {
        if let enb = row.enb, !enb.isEmpty { return "enb:\(enb)" }
        if let gnb = row.gnb, !gnb.isEmpty { return "gnb:\(gnb)" }
        if let pci = row.pci { return "pci:\(pci):\((row.technology ?? "").uppercased())" }
        return "unknown"
    }

    static func nodeTitle(_ row: ParsedRadioLogRow) -> String {
        if let enb = row.enb, !enb.isEmpty { return "eNB \(enb)" }
        if let gnb = row.gnb, !gnb.isEmpty { return "gNB \(gnb)" }
        if let pci = row.pci { return "PCI \(pci) · \(row.technology ?? "?")" }
        return "Cellule"
    }

    static func cellIdLabel(_ row: ParsedRadioLogRow) -> String {
        let t = (row.technology ?? "").uppercased()
        if t.contains("NR") || t.contains("5G") { return "NCI" }
        if t.contains("LTE") || t.contains("4G") { return "ECI" }
        return "CellID"
    }

    static func cellValue(_ row: ParsedRadioLogRow) -> String {
        if let ci = row.ci, ci > 0 { return String(ci) }
        return row.cellId ?? "?"
    }

    // MARK: - Lecture fichier (UTF-8 puis Latin-1)

    private static func readFile(_ url: URL) throws -> (name: String, content: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return (url.lastPathComponent, content)
    }
}
