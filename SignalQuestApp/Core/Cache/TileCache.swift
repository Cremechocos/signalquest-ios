import Foundation

/// Cache mémoire/disque des tuiles. La date d'origine, la validité du contenu
/// et la génération de la requête restent identiques sur les deux niveaux.
actor TileCache {
    private struct Flight {
        let id: UUID
        let forced: Bool
        let task: Task<CacheEnvelope<Data>, Error>
    }
    private struct Barrier {
        let id: UUID
        let task: Task<Void, Never>
    }

    // Les anciennes versions ont pu conserver des faux vides ou du JSON non
    // décodable. Une nouvelle famille de clés évite de les réintroduire.
    static let storagePrefix = "tile-cache-v2:"
    private let disk: DiskCache
    private let memoryEntryLimit: Int
    private let memoryTTL: TimeInterval
    private let diskTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var memory: [String: CacheEnvelope<Data>] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Flight] = [:]
    /// Ordre explicite : un ancien write ne peut finir après une purge, ni
    /// écraser sur disque le résultat d'un rafraîchissement plus récent.
    private var lastDiskMutation: Task<Void, Never>?
    private var invalidation: Barrier?
    private var revision = UUID()

    init(
        disk: DiskCache = DiskCache(folderName: "SignalQuestTileCache"),
        memoryEntryLimit: Int = 200,
        memoryTTL: TimeInterval = 5 * 60,
        diskTTL: TimeInterval = 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.disk = disk
        self.memoryEntryLimit = max(1, memoryEntryLimit)
        self.memoryTTL = memoryTTL
        self.diskTTL = diskTTL
        self.now = now
    }

    /// maxAge=0 rejoint uniquement un autre vrai rafraîchissement réseau ; une
    /// ancienne lecture normale est remplacée, même si elle ignore l'annulation.
    func data(
        for key: String,
        maxAge: TimeInterval? = nil,
        validate: @escaping @Sendable (Data) throws -> Void = { _ in },
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        while let barrier = invalidation {
            await barrier.task.value
            if invalidation?.id == barrier.id { break }
        }
        try Task.checkCancellation()
        let readRevision = revision
        let memoryAge = maxAge ?? memoryTTL
        let diskAge = maxAge ?? diskTTL
        let forced = maxAge.map { $0 <= 0 } ?? false
        if let entry = memory[key], isFresh(entry, maxAge: memoryAge) {
            do {
                try validate(entry.value)
                touch(key)
                return entry.value
            } catch {
                memory[key] = nil
                accessOrder.removeAll { $0 == key }
            }
        }

        let flight: Flight
        if let existing = inFlight[key], !forced || existing.forced {
            flight = existing
        } else {
            if let replaced = inFlight[key] { replaced.task.cancel() }
            let id = UUID()
            let task = Task<CacheEnvelope<Data>, Error> {
                do {
                    let entry: CacheEnvelope<Data>
                    let fetched: Bool
                    if diskAge > 0,
                       let cached = try? await self.disk.readEntry(Data.self, for: Self.storagePrefix + key),
                       self.isFresh(cached, maxAge: diskAge),
                       (try? validate(cached.value)) != nil {
                        entry = cached
                        fetched = false
                    } else {
                        let bytes = try await fetch()
                        try Task.checkCancellation()
                        try validate(bytes)
                        entry = CacheEnvelope(createdAt: self.now(), value: bytes)
                        fetched = true
                    }
                    return try await self.publish(entry, fetched: fetched, key: key, id: id)
                } catch {
                    if self.inFlight[key]?.id == id { self.inFlight[key] = nil }
                    throw error
                }
            }
            flight = Flight(id: id, forced: forced, task: task)
            inFlight[key] = flight
        }
        let entry = try await flight.task.value
        try Task.checkCancellation()
        guard readRevision == revision else { throw CancellationError() }
        // Un appel plus strict peut rejoindre une lecture disque demandée avec
        // un TTL plus long. Il vérifie sa propre exigence avant toute restitution.
        if !forced && diskAge > 0 && !isFresh(entry, maxAge: diskAge) {
            return try await data(for: key, maxAge: 0, validate: validate, fetch: fetch)
        }
        try validate(entry.value)
        return entry.value
    }

    private func publish(_ entry: CacheEnvelope<Data>, fetched: Bool, key: String, id: UUID) async throws -> CacheEnvelope<Data> {
        try Task.checkCancellation()
        guard inFlight[key]?.id == id else { throw CancellationError() }
        memory[key] = entry
        touch(key)
        while memory.count > memoryEntryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            memory[oldest] = nil
        }
        if fetched {
            let previous = lastDiskMutation
            let disk = disk
            let write = Task {
                await previous?.value
                try? await disk.write(entry.value, for: Self.storagePrefix + key, createdAt: entry.createdAt)
            }
            lastDiskMutation = write
            await write.value
        }
        try Task.checkCancellation()
        guard inFlight[key]?.id == id else { throw CancellationError() }
        inFlight[key] = nil
        return entry
    }

    /// Retourne seulement après la purge disque. Les appels suivants attendent
    /// cette barrière ; les réponses antérieures ne peuvent repeupler le cache.
    func removeAll() async {
        revision = UUID()
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        memory.removeAll()
        accessOrder.removeAll()
        let previous = lastDiskMutation
        let disk = disk
        let purge = Task {
            await previous?.value
            await disk.removeAll(withPrefix: Self.storagePrefix)
        }
        invalidation = Barrier(id: UUID(), task: purge)
        lastDiskMutation = purge
        await purge.value
    }

    private func isFresh(_ entry: CacheEnvelope<Data>, maxAge: TimeInterval) -> Bool {
        let age = now().timeIntervalSince(entry.createdAt)
        return maxAge > 0 && age >= 0 && age <= maxAge
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}
