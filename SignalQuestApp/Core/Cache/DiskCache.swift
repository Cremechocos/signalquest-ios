import Foundation

actor DiskCache {
    private let root: URL
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(folderName: String = "SignalQuestCache", fileManager: FileManager = .default) {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write<T: Codable>(_ value: T, for key: String) async throws {
        let data = try encoder.encode(CacheEnvelope(createdAt: Date(), value: value))
        try data.write(to: url(for: key), options: [.atomic])
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
}

private struct CacheEnvelope<T: Codable>: Codable {
    let createdAt: Date
    let value: T
}
