import Foundation

/// Un lot d'import persisté (métadonnées + cellules parsées dédoublonnées). Le statut
/// d'identification n'est PAS stocké : il est re-résolu à l'ouverture de la page
/// (rapide + toujours à jour), comme l'onglet « Import » d'Android.
struct StoredRadioLogImport: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let importedAtMs: Int
    let totalLines: Int
    var rows: [ParsedRadioLogRow]

    var importedAt: Date { Date(timeIntervalSince1970: Double(importedAtMs) / 1000) }
}

private struct RadioLogImportStoreFile: Codable {
    var imports: [StoredRadioLogImport] = []
}

/// Persistance locale des imports de logs radio. iOS ne stocke pas les métriques
/// radio en base (pas de Room) : on garde les cellules parsées dans un fichier JSON
/// durable pour pouvoir les ré-afficher, ré-identifier et supprimer par lot ou cellule.
protocol RadioLogImportStoring: Sendable {
    func all() throws -> [StoredRadioLogImport]
    func add(_ batch: StoredRadioLogImport) throws
    func deleteBatch(id: UUID) throws
    func deleteRows(batchId: UUID, rowIds: Set<UUID>) throws
}

/// Fichier durable en Application Support (pas Caches, qui peut être purgé). Chaque
/// mutation est ré-encodée et remplacée atomiquement, sous verrou. Calqué sur
/// `CoverageSessionQueue`.
final class RadioLogImportStore: RadioLogImportStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent("RadioLogImports.json", isDirectory: false)
        }
    }

    func all() throws -> [StoredRadioLogImport] {
        try withLock { try readUnlocked().imports.sorted { $0.importedAtMs > $1.importedAtMs } }
    }

    func add(_ batch: StoredRadioLogImport) throws {
        try withLock {
            var file = try readUnlocked()
            file.imports.removeAll { $0.id == batch.id }
            file.imports.append(batch)
            try writeUnlocked(file)
        }
    }

    func deleteBatch(id: UUID) throws {
        try withLock {
            var file = try readUnlocked()
            let before = file.imports.count
            file.imports.removeAll { $0.id == id }
            if file.imports.count != before { try writeUnlocked(file) }
        }
    }

    func deleteRows(batchId: UUID, rowIds: Set<UUID>) throws {
        guard !rowIds.isEmpty else { return }
        try withLock {
            var file = try readUnlocked()
            guard let index = file.imports.firstIndex(where: { $0.id == batchId }) else { return }
            file.imports[index].rows.removeAll { rowIds.contains($0.id) }
            // Un lot vidé disparaît de la liste.
            if file.imports[index].rows.isEmpty { file.imports.remove(at: index) }
            try writeUnlocked(file)
        }
    }

    // MARK: - Internals

    private func readUnlocked() throws -> RadioLogImportStoreFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return RadioLogImportStoreFile() }
        return try decoder.decode(RadioLogImportStoreFile.self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ file: RadioLogImportStoreFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if file.imports.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
            return
        }
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
