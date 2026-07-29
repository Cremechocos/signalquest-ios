import Foundation

/// Instantané local du journal radio : les lignes, la position du curseur, la date
/// de la dernière synchronisation réussie.
struct RadioLogSnapshot: Codable, Sendable {
    var entries: [RadioLogEntry] = []
    var cursor: RadioLogCursor?
    var lastSyncedAtMs: Int?

    var lastSyncedAt: Date? {
        lastSyncedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// Persistance locale du journal radio synchronisé.
///
/// iOS n'a pas de Room : comme `RadioLogImportStore`, on garde un fichier JSON
/// durable en Application Support. Le journal du compte de test pèse ~15 500
/// lignes, soit ~2 Mo une fois réduit aux champs affichés — l'écriture est donc
/// FAITE UNE FOIS par synchronisation, pas par page : trente et une réécritures de
/// 2 Mo pour un seul rattrapage ne se défendraient pas.
protocol RadioLogStoring: Sendable {
    func load() -> RadioLogSnapshot
    /// Applique un lot reçu du serveur : upsert par `dedupeKey`, et RETRAIT des
    /// lignes portant une pierre tombale. Écrit une seule fois.
    @discardableResult
    func merge(incoming: [RadioLogEntry], cursor: RadioLogCursor?, nowMs: Int) -> RadioLogSnapshot
    func clear()
}

/// Fichier durable, mutations sous verrou et écriture atomique. Même patron que
/// `RadioLogImportStore`.
final class RadioLogStore: RadioLogStoring, @unchecked Sendable {
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
                .appendingPathComponent("RadioLogJournal.json", isDirectory: false)
        }
    }

    func load() -> RadioLogSnapshot {
        lock.lock(); defer { lock.unlock() }
        return (try? readUnlocked()) ?? RadioLogSnapshot()
    }

    @discardableResult
    func merge(incoming: [RadioLogEntry], cursor: RadioLogCursor?, nowMs: Int) -> RadioLogSnapshot {
        lock.lock(); defer { lock.unlock() }
        var snapshot = (try? readUnlocked()) ?? RadioLogSnapshot()
        snapshot.entries = Self.applying(incoming: incoming, to: snapshot.entries)
        if let cursor { snapshot.cursor = cursor }
        snapshot.lastSyncedAtMs = nowMs
        try? writeUnlocked(snapshot)
        return snapshot
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Fusion pure — extraite pour être testable sans toucher au disque.
    ///
    /// Le serveur peut renvoyer PLUSIEURS fois la même ligne au sein d'un même
    /// rattrapage (le recul de sécurité du curseur en garantit le recouvrement) :
    /// l'application doit donc être idempotente, et le dernier état reçu gagne.
    static func applying(incoming: [RadioLogEntry], to existing: [RadioLogEntry]) -> [RadioLogEntry] {
        var byKey = Dictionary(existing.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { _, last in last })
        for entry in incoming {
            if entry.isDeleted {
                byKey.removeValue(forKey: entry.dedupeKey)
            } else {
                byKey[entry.dedupeKey] = entry
            }
        }
        return Array(byKey.values)
    }

    // MARK: - Internals

    private func readUnlocked() throws -> RadioLogSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return RadioLogSnapshot() }
        return try decoder.decode(RadioLogSnapshot.self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ snapshot: RadioLogSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

// MARK: - Cache du statut d'identification par SITE

/// Cache disque du statut d'identification des SITES (clé = `RadioLogSite.id`).
/// Jumeau de `RadioLogImportStatusStore`, dont la clé est une identité de CELLULE.
/// Il permet de rouvrir la page avec ses pastilles déjà posées au lieu de relancer
/// un balayage complet de 4 800 sites à chaque fois.
protocol RadioLogSiteStatusStoring: Sendable {
    func fresh(ttlMs: Int, nowMs: Int) -> [String: RadioLogSiteState]
    func merge(_ states: [String: RadioLogSiteState], nowMs: Int)
    func clear()
}

private struct RadioLogSiteStatusFile: Codable {
    var states: [String: CachedRadioLogSiteState] = [:]
}

final class RadioLogSiteStatusStore: RadioLogSiteStatusStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest
    /// Garde-fou de taille : au-delà, on ne garde que les plus récents.
    private let maxEntries = 20_000

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent("RadioLogSiteStatuses.json", isDirectory: false)
        }
    }

    func fresh(ttlMs: Int, nowMs: Int) -> [String: RadioLogSiteState] {
        lock.lock(); defer { lock.unlock() }
        let file = (try? readUnlocked()) ?? RadioLogSiteStatusFile()
        var out: [String: RadioLogSiteState] = [:]
        for (key, cached) in file.states where nowMs - cached.updatedAtMs <= ttlMs {
            out[key] = cached.state
        }
        return out
    }

    func merge(_ states: [String: RadioLogSiteState], nowMs: Int) {
        guard !states.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var file = (try? readUnlocked()) ?? RadioLogSiteStatusFile()
        for (key, state) in states {
            file.states[key] = CachedRadioLogSiteState(state: state, updatedAtMs: nowMs)
        }
        if file.states.count > maxEntries {
            let kept = file.states.sorted { $0.value.updatedAtMs > $1.value.updatedAtMs }.prefix(maxEntries)
            file.states = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        try? writeUnlocked(file)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func readUnlocked() throws -> RadioLogSiteStatusFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return RadioLogSiteStatusFile() }
        return try decoder.decode(RadioLogSiteStatusFile.self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ file: RadioLogSiteStatusFile) throws {
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
