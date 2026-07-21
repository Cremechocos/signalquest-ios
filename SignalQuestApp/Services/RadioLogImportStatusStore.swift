import Foundation

/// Cache disque du STATUT d'identification des cellules importées (clé = identité
/// cellule stable `ParsedRadioLogRow.stableIdentityKey`). iOS n'a pas de Room : ce
/// fichier JSON joue le rôle du cache Room *stale-while-revalidate* d'Android — à la
/// réouverture de la page Imports, les statuts encore FRAIS s'affichent immédiatement
/// au lieu de tout re-résoudre via `/identify/quick/batch`.
protocol RadioLogImportStatusStoring: Sendable {
    /// Statuts encore frais (âge ≤ `ttlMs`). Les périmés sont ignorés → re-résolus.
    func fresh(ttlMs: Int, nowMs: Int) -> [String: RadioLogImportCellStatus]
    /// Fusionne/écrase les statuts fournis avec l'horodatage `nowMs`.
    func merge(_ statuses: [String: RadioLogImportCellStatus], nowMs: Int)
}

private struct RadioLogImportStatusFile: Codable {
    var statuses: [String: CachedRadioLogStatus] = [:]
}

/// Fichier durable en Application Support, mutations sous verrou + écriture atomique.
/// Même patron que `RadioLogImportStore`.
final class RadioLogImportStatusStore: RadioLogImportStatusStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest
    /// Garde-fou : au-delà, on ne conserve que les plus récents (un gros import ne doit
    /// pas faire enfler le cache indéfiniment).
    private let maxEntries = 5000

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent("RadioLogImportStatuses.json", isDirectory: false)
        }
    }

    func fresh(ttlMs: Int, nowMs: Int) -> [String: RadioLogImportCellStatus] {
        lock.lock(); defer { lock.unlock() }
        let file = (try? readUnlocked()) ?? RadioLogImportStatusFile()
        var out: [String: RadioLogImportCellStatus] = [:]
        for (key, cached) in file.statuses where nowMs - cached.updatedAtMs <= ttlMs {
            out[key] = cached.status
        }
        return out
    }

    func merge(_ statuses: [String: RadioLogImportCellStatus], nowMs: Int) {
        guard !statuses.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var file = (try? readUnlocked()) ?? RadioLogImportStatusFile()
        for (key, status) in statuses {
            file.statuses[key] = CachedRadioLogStatus(status: status, updatedAtMs: nowMs)
        }
        if file.statuses.count > maxEntries {
            let kept = file.statuses.sorted { $0.value.updatedAtMs > $1.value.updatedAtMs }.prefix(maxEntries)
            file.statuses = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        try? writeUnlocked(file)
    }

    // MARK: - Internals

    private func readUnlocked() throws -> RadioLogImportStatusFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return RadioLogImportStatusFile() }
        return try decoder.decode(RadioLogImportStatusFile.self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ file: RadioLogImportStatusFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}
