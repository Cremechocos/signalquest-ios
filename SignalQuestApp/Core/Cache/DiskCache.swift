import Foundation

actor DiskCache {
    private let root: URL
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest
    /// Plafond de taille du dossier ; au-delà, on supprime les plus anciens fichiers.
    private let maxBytes: Int
    /// Âge maximal d'un fichier avant suppression inconditionnelle.
    private let maxAge: TimeInterval
    /// Throttle de l'éviction : on ne scanne pas le dossier à chaque write.
    private var lastEvictionAt: Date = .distantPast

    init(
        folderName: String = "SignalQuestCache",
        maxBytes: Int = 64 * 1024 * 1024,          // 64 Mo
        maxAge: TimeInterval = 7 * 24 * 60 * 60,    // 7 jours
        fileManager: FileManager = .default
    ) {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appendingPathComponent(folderName, isDirectory: true)
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write<T: Codable>(_ value: T, for key: String) async throws {
        let data = try encoder.encode(CacheEnvelope(createdAt: Date(), value: value))
        try data.write(to: url(for: key), options: [.atomic])
        evictIfNeeded()
    }

    func read<T: Codable>(_ type: T.Type, for key: String, maxAge: TimeInterval? = nil) async throws -> T? {
        let url = url(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let envelope = try decoder.decode(CacheEnvelope<T>.self, from: data)
        if let maxAge, Date().timeIntervalSince(envelope.createdAt) > maxAge {
            return nil
        }
        return envelope.value
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    private func url(for key: String) -> URL {
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        return root.appendingPathComponent(safe).appendingPathExtension("json")
    }

    // MARK: - Éviction (bornage taille + âge)

    /// Borne le cache disque, au plus une fois toutes les 2 min (le scan du dossier
    /// est trop coûteux pour s'exécuter à chaque write). Premier write après
    /// lancement : `lastEvictionAt == .distantPast` → s'exécute immédiatement.
    private func evictIfNeeded() {
        guard Date().timeIntervalSince(lastEvictionAt) > 120 else { return }
        lastEvictionAt = Date()
        evict()
    }

    private func evict() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry { let url: URL; let size: Int; let date: Date }
        var entries: [Entry] = []
        var total = 0
        let now = Date()
        for fileURL in urls {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            // 1) Suppression par âge (inconditionnelle).
            if now.timeIntervalSince(date) > maxAge {
                try? fm.removeItem(at: fileURL)
                continue
            }
            let size = values.fileSize ?? 0
            entries.append(Entry(url: fileURL, size: size, date: date))
            total += size
        }

        guard total > maxBytes else { return }
        // 2) Bornage par taille : on supprime les plus anciens (par date de modif)
        //    jusqu'à repasser sous le plafond.
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maxBytes else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

private struct CacheEnvelope<T: Codable>: Codable {
    let createdAt: Date
    let value: T
}
