import Foundation
import CryptoKit

struct FavoriteAntennasLocalState: Codable, Equatable, Sendable {
    let version: Int
    let ownerScopeID: String
    var localRevision: UInt64
    var confirmedFavorites: [FavoriteAntenna]
    var confirmedNotifications: Bool?
    var serverRevision: String?
    var pending: [FavoriteAntennaIntent]
    var attemptedRequestIDs: Set<String>

    init(ownerScopeID: String) {
        version = 1
        self.ownerScopeID = ownerScopeID
        localRevision = 0
        confirmedFavorites = []
        confirmedNotifications = nil
        serverRevision = nil
        pending = []
        attemptedRequestIDs = []
    }

    var hasSnapshot: Bool { serverRevision != nil && confirmedNotifications != nil }
    var favorites: [FavoriteAntenna] {
        var result = confirmedFavorites
        for intent in pending {
            switch intent.operation {
            case .upsert:
                guard let favorite = intent.favorite else { continue }
                if let index = result.firstIndex(where: { $0.id == favorite.id }) { result[index] = favorite }
                else { result.append(favorite) }
            case .remove:
                result.removeAll { $0.id == intent.targetKey }
            case .preferences: break
            }
        }
        return result
    }

    var notifyOnIssues: Bool {
        pending.last(where: { $0.operation == .preferences })?.notifyFavoriteAntennaIssuesPush
            ?? confirmedNotifications ?? false
    }

    mutating func enqueue(_ intent: FavoriteAntennaIntent) {
        // Conserver la dernière intention par cible. Une réponse déjà en vol
        // n'effacera celle-ci que si elle confirme exactement le même requestId.
        // Une intention déjà envoyée doit d'abord retrouver son reçu, même si
        // sa réponse a été perdue. La remplacer ici permettrait à un ancien
        // ajout encore en vol de dépasser un retrait plus récent.
        pending.removeAll { $0.targetKey == intent.targetKey && !attemptedRequestIDs.contains($0.requestId) }
        pending.append(intent)
        localRevision += 1
    }

    mutating func receive(_ response: FavoriteAntennasResponse, acknowledging requestId: String? = nil) {
        confirmedFavorites = response.favorites
        confirmedNotifications = response.notifyFavoriteAntennaIssuesPush
        serverRevision = response.revision
        if let requestId {
            pending.removeAll { $0.requestId == requestId }
            attemptedRequestIDs.remove(requestId)
        }
        localRevision += 1
    }

    /// Libère d'abord les emplacements supprimés, afin qu'un ajout refusé à la
    /// limite de 500 ne bloque pas le retrait demandé ensuite par l'utilisateur.
    var nextIntent: FavoriteAntennaIntent? {
        var targets = Set<String>()
        let eligible = pending.filter { targets.insert($0.targetKey).inserted }
        return eligible.first(where: { $0.operation == .remove })
            ?? eligible.first(where: { $0.operation == .preferences }) ?? eligible.first
    }

    mutating func markAttempted(_ requestId: String) {
        if attemptedRequestIDs.insert(requestId).inserted { localRevision += 1 }
    }

    mutating func rejectTerminal(_ requestId: String) {
        attemptedRequestIDs.remove(requestId)
        pending.removeAll { $0.requestId == requestId }
        localRevision += 1
    }

    func validate(owner: String) throws {
        let unsent = pending.filter { !attemptedRequestIDs.contains($0.requestId) }
        guard version == 1, ownerScopeID == owner, owner.hasPrefix("user:"), owner.count > 5,
              confirmedFavorites.count <= 500, pending.count <= 2000,
              (serverRevision == nil && confirmedNotifications == nil)
                || (serverRevision?.isEmpty == false && confirmedNotifications != nil),
              Set(confirmedFavorites.map(\.id)).count == confirmedFavorites.count,
              Set(pending.map(\.requestId)).count == pending.count,
              attemptedRequestIDs.isSubset(of: Set(pending.map(\.requestId))),
              Set(unsent.map(\.targetKey)).count == unsent.count,
              pending.allSatisfy({ intent in
                  guard UUID(uuidString: intent.requestId) != nil else { return false }
                  switch intent.operation {
                  case .upsert:
                      return intent.favorite.map { !$0.siteId.filter { !$0.isWhitespace }.isEmpty && !$0.market.isEmpty } == true
                  case .remove:
                      return intent.siteId?.isEmpty == false && intent.market?.isEmpty == false
                  case .preferences:
                      return intent.notifyFavoriteAntennaIssuesPush != nil
                  }
              }) else {
            throw APIError.decoding("invalid-local-favorites")
        }
    }
}

protocol FavoriteAntennasStoring: Sendable {
    func load(ownerScopeID: String) async throws -> FavoriteAntennasLocalState?
    func save(_ state: FavoriteAntennasLocalState) async throws
    func remove(ownerScopeID: String) async throws
}

/// I/O et JSON hors du main actor, fichier atomique et namespace propriétaire.
/// Une sauvegarde asynchrone plus ancienne ne peut remplacer une révision locale
/// plus récente. Le compteur local est indépendant de la révision opaque API.
actor FavoriteAntennasLocalStore: FavoriteAntennasStoring {
    private let directory: URL?
    private let environmentID: String
    private var persistedRevisions: [String: UInt64] = [:]
    private var erasedOwners: Set<String> = []
    private static let maximumBytes = 4 * 1024 * 1024

    init(directory: URL? = nil, environmentID: String = "default") {
        self.directory = directory
        self.environmentID = Self.normalizedEnvironment(environmentID)
    }

    func load(ownerScopeID: String) throws -> FavoriteAntennasLocalState? {
        let url = try file(owner: ownerScopeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes else { throw APIError.decoding("local-favorites-too-large") }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder.signalQuest.decode(FavoriteAntennasLocalState.self, from: data)
        try state.validate(owner: ownerScopeID)
        persistedRevisions[ownerScopeID] = max(persistedRevisions[ownerScopeID] ?? 0, state.localRevision)
        return state
    }

    func save(_ state: FavoriteAntennasLocalState) throws {
        try state.validate(owner: state.ownerScopeID)
        guard !erasedOwners.contains(state.ownerScopeID) else { throw APIError.cancelled }
        guard state.localRevision >= (persistedRevisions[state.ownerScopeID] ?? 0) else { return }
        let data = try JSONEncoder.signalQuest.encode(state)
        guard data.count <= Self.maximumBytes else { throw APIError.decoding("local-favorites-too-large") }
        let url = try file(owner: state.ownerScopeID)
        var options: Data.WritingOptions = [.atomic]
#if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
#endif
        try data.write(to: url, options: options)
        persistedRevisions[state.ownerScopeID] = state.localRevision
    }

    func remove(ownerScopeID: String) throws {
        erasedOwners.insert(ownerScopeID)
        let url = try file(owner: ownerScopeID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        persistedRevisions.removeValue(forKey: ownerScopeID)
    }

    private func file(owner: String) throws -> URL {
        guard owner.hasPrefix("user:"), owner.count > 5 else { throw APIError.missingAuthToken }
        let base: URL
        if let directory { base = directory }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("SignalQuest/FavoriteAntennas", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let identity = environmentID + "\n" + owner
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("\(digest).json")
    }

    private static func normalizedEnvironment(_ value: String) -> String {
        guard var url = URLComponents(string: value), let scheme = url.scheme, let host = url.host else { return value }
        url.scheme = scheme.lowercased(); url.host = host.lowercased(); url.fragment = nil
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        return url.string ?? value
    }
}
