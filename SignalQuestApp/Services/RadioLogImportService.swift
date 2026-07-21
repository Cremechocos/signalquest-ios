import Foundation

/// Orchestration de l'import de logs radio : parse (rapide) → **persistance locale** →
/// affichage groupé (comme l'onglet Import d'Android) → **résolution progressive** du
/// statut d'identification (`/identify/quick/batch`, lecture seule) → l'utilisateur
/// identifie (`identify/direct`), voit les infos, ou supprime.
protocol RadioLogImportServicing: Sendable {
    /// Parse le fichier, dédoublonne les cellules et persiste le lot. Rapide (aucun réseau).
    func importFile(fileName: String, content: String) async throws -> StoredRadioLogImport
    /// Lots persistés, plus récent d'abord.
    func storedImports() throws -> [StoredRadioLogImport]
    func deleteBatch(id: UUID) throws
    func deleteRows(batchId: UUID, rowIds: Set<UUID>) throws
    /// Résout le statut d'identification en parallèle borné ; émet chaque lot résolu au
    /// fur et à mesure (affichage progressif, pas d'attente du fichier entier).
    func resolveStream(rows: [ParsedRadioLogRow]) -> AsyncStream<[ResolvedRadioLogRow]>
    /// Écrit les identifications pour les lignes rattachées à un site (`identify/direct`).
    func confirm(rows: [ResolvedRadioLogRow]) async -> RadioLogImportOutcome
}

final class RadioLogImportService: RadioLogImportServicing, @unchecked Sendable {
    private let api: APIClient
    private let identify: IdentifyServicing
    private let store: RadioLogImportStoring
    /// Le batch serveur est borné à 150 items/requête.
    private let batchSize = 150
    /// Requêtes de résolution simultanées (accélère sans marteler le serveur).
    private let maxConcurrentResolves = 5

    init(api: APIClient, identify: IdentifyServicing, store: RadioLogImportStoring = RadioLogImportStore()) {
        self.api = api
        self.identify = identify
        self.store = store
    }

    // MARK: - Import & persistance

    func importFile(fileName: String, content: String) async throws -> StoredRadioLogImport {
        let parsed = RadioLogImportParser.parse(fileName: fileName, content: content)
        let uniqueRows = deduplicate(parsed.rows.filter { $0.hasRadioIdentity })
        let batch = StoredRadioLogImport(
            id: UUID(),
            fileName: fileName,
            importedAtMs: Int(Date().timeIntervalSince1970 * 1000),
            totalLines: parsed.totalLines,
            rows: uniqueRows
        )
        try store.add(batch)
        return batch
    }

    func storedImports() throws -> [StoredRadioLogImport] { try store.all() }
    func deleteBatch(id: UUID) throws { try store.deleteBatch(id: id) }
    func deleteRows(batchId: UUID, rowIds: Set<UUID>) throws { try store.deleteRows(batchId: batchId, rowIds: rowIds) }

    // MARK: - Résolution progressive (concurrente bornée)

    func resolveStream(rows: [ParsedRadioLogRow]) -> AsyncStream<[ResolvedRadioLogRow]> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let chunks = rows.chunked(into: self.batchSize)
                await withTaskGroup(of: [ResolvedRadioLogRow].self) { group in
                    var iterator = chunks.makeIterator()
                    var inFlight = 0
                    for _ in 0..<self.maxConcurrentResolves {
                        guard let chunk = iterator.next() else { break }
                        group.addTask { await self.resolveChunk(chunk) }
                        inFlight += 1
                    }
                    while inFlight > 0, let result = await group.next() {
                        inFlight -= 1
                        if Task.isCancelled { break }
                        continuation.yield(result)
                        if let chunk = iterator.next() {
                            group.addTask { await self.resolveChunk(chunk) }
                            inFlight += 1
                        }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolveChunk(_ chunk: [ParsedRadioLogRow]) async -> [ResolvedRadioLogRow] {
        let items = chunk.map(batchItem(for:))
        do {
            let response: QuickIdentifyBatchResponse = try await api.requestJSON(
                "/api/android/map/identify/quick/batch",
                method: .post,
                body: QuickIdentifyBatchRequest(items: items)
            )
            let byId = Dictionary(
                response.results.compactMap { r -> (String, QuickIdentifyBatchResult)? in
                    guard let id = r.id else { return nil }
                    return (id, r)
                },
                uniquingKeysWith: { first, _ in first }
            )
            return chunk.map { row in
                let match = byId[row.id.uuidString]?.result
                let siteId = (match?.found == true) ? match?.siteId : nil
                return ResolvedRadioLogRow(
                    id: row.id, row: row, siteId: siteId, matched: siteId != nil,
                    distanceMeters: match?.distanceMeters
                )
            }
        } catch {
            // Lecture seule best-effort : un lot en échec laisse ses cellules non résolues.
            return chunk.map { ResolvedRadioLogRow(id: $0.id, row: $0, siteId: nil, matched: false, distanceMeters: nil) }
        }
    }

    // MARK: - Écriture (identification)

    func confirm(rows: [ResolvedRadioLogRow]) async -> RadioLogImportOutcome {
        var outcome = RadioLogImportOutcome()
        for resolved in rows {
            guard let siteId = resolved.siteId, let lat = resolved.row.latitude, let lon = resolved.row.longitude else {
                outcome.failed += 1
                continue
            }
            let row = resolved.row
            do {
                _ = try await identify.identify(
                    siteId: siteId,
                    enb: row.enb,
                    gnb: row.gnb,
                    pci: row.pci.map(String.init),
                    cellId: row.cellId,
                    operatorName: row.operatorName,
                    mcc: row.mcc,
                    mnc: row.mnc,
                    lat: lat,
                    lng: lon
                )
                outcome.submitted += 1
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }

    // MARK: - Helpers

    private func batchItem(for row: ParsedRadioLogRow) -> QuickIdentifyBatchItem {
        QuickIdentifyBatchItem(
            id: row.id.uuidString,
            operator: row.operatorName,
            market: RadioLogOperatorResolver.marketCode(forOperator: row.operatorName, mcc: row.mcc),
            mcc: row.mcc,
            mnc: row.mnc,
            enb: row.enb,
            gnb: row.gnb,
            pci: row.pci.map(String.init),
            cellId: row.cellId,
            ci: row.ci.map(String.init),
            lat: row.latitude,
            lng: row.longitude,
            band: row.band,
            earfcn: row.earfcn,
            tech: row.technology
        )
    }

    /// Dédoublonne par identité cellule : un export contient beaucoup de lignes pour la
    /// même cellule ; on n'en garde qu'une par (opérateur, nœud, ci, pci).
    private func deduplicate(_ rows: [ParsedRadioLogRow]) -> [ParsedRadioLogRow] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = [
                row.mcc ?? "", row.mnc ?? "", row.enb ?? "", row.gnb ?? "",
                row.ci.map(String.init) ?? "", row.pci.map(String.init) ?? ""
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
