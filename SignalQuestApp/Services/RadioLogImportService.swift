import Foundation

/// Orchestration de l'import de logs radio : parse → **résout en lot** (lecture seule,
/// `/api/android/map/identify/quick/batch`) → l'utilisateur valide → **écrit** les
/// identifications rattachées via `identify/direct` (le serveur gère le nœud eNB/gNB).
protocol RadioLogImportServicing: Sendable {
    /// Parse le contenu, dédoublonne les cellules et résout chacune contre les sites connus.
    func resolve(fileName: String, content: String) async throws -> RadioLogImportPreview
    /// Écrit les identifications pour les lignes rattachées à un site.
    func confirm(rows: [ResolvedRadioLogRow]) async -> RadioLogImportOutcome
}

final class RadioLogImportService: RadioLogImportServicing, @unchecked Sendable {
    private let api: APIClient
    private let identify: IdentifyServicing
    /// Le batch serveur est borné à 150 items/requête.
    private let batchSize = 150

    init(api: APIClient, identify: IdentifyServicing) {
        self.api = api
        self.identify = identify
    }

    func resolve(fileName: String, content: String) async throws -> RadioLogImportPreview {
        let parsed = RadioLogImportParser.parse(fileName: fileName, content: content)
        let uniqueRows = deduplicate(parsed.rows.filter { $0.hasRadioIdentity })

        var resolved: [ResolvedRadioLogRow] = []
        resolved.reserveCapacity(uniqueRows.count)

        for chunk in uniqueRows.chunked(into: batchSize) {
            let items = chunk.map(batchItem(for:))
            let response: QuickIdentifyBatchResponse = try await api.requestJSON(
                "/api/android/map/identify/quick/batch",
                method: .post,
                body: QuickIdentifyBatchRequest(items: items)
            )
            let bySiteId = Dictionary(
                response.results.compactMap { result -> (String, QuickIdentifyBatchResult)? in
                    guard let id = result.id else { return nil }
                    return (id, result)
                },
                uniquingKeysWith: { first, _ in first }
            )
            for row in chunk {
                let match = bySiteId[row.id.uuidString]?.result
                let siteId = (match?.found == true) ? match?.siteId : nil
                resolved.append(ResolvedRadioLogRow(id: row.id, row: row, siteId: siteId, matched: siteId != nil))
            }
        }

        return RadioLogImportPreview(
            fileName: fileName,
            totalLines: parsed.totalLines,
            parsedRows: uniqueRows.count,
            resolvedRows: resolved
        )
    }

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
    /// même cellule ; on ne résout/écrit qu'une fois par (opérateur, nœud, ci, pci).
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
