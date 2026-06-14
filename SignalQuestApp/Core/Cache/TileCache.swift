import Foundation

/// Cache générique de tuiles : LRU mémoire (TTL court), repli sur DiskCache
/// (TTL plus long) et déduplication des requêtes en vol. La clé est fournie
/// par l'appelant (couche + marché + opérateur + z/x/y + paramètres).
actor TileCache {
    private struct MemoryEntry {
        let data: Data
        let storedAt: Date
    }

    private let disk: DiskCache
    private let memoryEntryLimit: Int
    private let memoryTTL: TimeInterval
    private let diskTTL: TimeInterval

    private var memory: [String: MemoryEntry] = [:]
    /// Ordre d'accès LRU : le plus ancien en tête, le plus récent en queue.
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(
        disk: DiskCache = DiskCache(folderName: "SignalQuestTileCache"),
        memoryEntryLimit: Int = 200,
        memoryTTL: TimeInterval = 5 * 60,
        diskTTL: TimeInterval = 60 * 60
    ) {
        self.disk = disk
        self.memoryEntryLimit = memoryEntryLimit
        self.memoryTTL = memoryTTL
        self.diskTTL = diskTTL
    }

    /// Renvoie la tuile en cache (mémoire puis disque), sinon exécute `fetch`
    /// une seule fois même si plusieurs appelants demandent la même clé.
    func data(for key: String, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let entry = memory[key], Date().timeIntervalSince(entry.storedAt) <= memoryTTL {
            touch(key)
            return entry.data
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> { [disk, diskTTL] in
            if let cached = try? await disk.read(Data.self, for: key, maxAge: diskTTL) {
                return cached
            }
            let fresh = try await fetch()
            try? await disk.write(fresh, for: key)
            return fresh
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        store(data, for: key)
        return data
    }

    func removeAll() {
        memory.removeAll()
        accessOrder.removeAll()
    }

    // MARK: LRU

    private func touch(_ key: String) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    private func store(_ data: Data, for key: String) {
        memory[key] = MemoryEntry(data: data, storedAt: Date())
        touch(key)
        while memory.count > memoryEntryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }
}
