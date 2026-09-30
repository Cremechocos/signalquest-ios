import CryptoKit
import Foundation

/// Nom et discrétion de chaque conversation, pour l'écran d'appel d'iOS
/// (spec du chiffrement §10.5, IOS-CALL-5). La notification d'un appel chiffré
/// ne porte ni nom ni titre : l'app retrouve le nom ici, de façon synchrone,
/// quand PushKit la réveille.
///
/// Même scellement que les brouillons (`MessageDraftStore`) : un fichier par
/// compte, chiffré en AES-GCM avec une clé du trousseau propre à l'appareil,
/// lisible dès le premier déverrouillage (un appel peut sonner écran
/// verrouillé), exclu des sauvegardes et effacé à la déconnexion.
final class CallConversationDirectory: @unchecked Sendable {
    static let shared = CallConversationDirectory()
    /// Au-delà, les conversations vues le moins récemment tombent.
    static let maxEntries = 500
    static let maxTitleLength = 120

    struct Entry: Codable, Equatable, Sendable {
        let title: String
        let isEncrypted: Bool
        let seenAtMs: Int64
    }

    private struct DirectoryFile: Codable, Equatable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private static let folderName = "CallDirectoryV1"
    private static let keyService = "fr.signalquest.ios.call-directory"

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private let lock = NSLock()
    /// Dernier fichier lu : PushKit ne relit pas le disque à chaque appel.
    private var cached: (ownerScopeId: String, file: DirectoryFile)?

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        keyStore: TokenStore = KeychainStore(service: CallConversationDirectory.keyService)
    ) {
        self.fileManager = fileManager
        self.keyStore = keyStore
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.rootURL = support
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent(Self.folderName, isDirectory: true)
        }
    }

    /// Conversation connue de ce compte, lue de façon synchrone.
    func entry(conversationId: String, ownerScopeId: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(ownerScopeId: ownerScopeId).entries[conversationId]
    }

    /// Conversations vues dans la messagerie, avec le nom que l'app leur donne.
    func record(
        _ conversations: [MessageConversation],
        currentUserId: String?,
        ownerScopeId: String,
        now: Date = Date()
    ) {
        guard ownerScopeId.hasPrefix("user:"), !conversations.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var file = loadLocked(ownerScopeId: ownerScopeId)
        let before = file
        let seenAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        for conversation in conversations where !conversation.id.isEmpty {
            let title = String(
                conversation.displayTitle(excluding: currentUserId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maxTitleLength)
            )
            guard !title.isEmpty else { continue }
            let isEncrypted = conversation.e2eeEnabled == true
            let known = file.entries[conversation.id]
            guard known?.title != title || known?.isEncrypted != isEncrypted else { continue }
            file.entries[conversation.id] = Entry(title: title, isEncrypted: isEncrypted, seenAtMs: seenAtMs)
        }
        if file.entries.count > Self.maxEntries {
            let kept = file.entries.sorted { $0.value.seenAtMs > $1.value.seenAtMs }.prefix(Self.maxEntries)
            file.entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        guard file != before else { return }
        do {
            try writeLocked(file, ownerScopeId: ownerScopeId)
            cached = (ownerScopeId, file)
        } catch {
            cached = nil
        }
    }

    /// À la déconnexion : le fichier et sa clé partent avec le compte.
    func purge(ownerScopeId: String) {
        lock.lock()
        defer { lock.unlock() }
        let directory = ownerDirectory(ownerScopeId)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try? keyStore.remove(keyName(ownerScopeId))
        if cached?.ownerScopeId == ownerScopeId { cached = nil }
    }

    /// Un fichier illisible (clé perdue, contenu altéré) vaut un annuaire vide,
    /// remplacé au prochain enregistrement. Un échec n'est pas retenu : avant
    /// le premier déverrouillage, la clé n'est pas encore lisible.
    private func loadLocked(ownerScopeId: String) -> DirectoryFile {
        if let cached, cached.ownerScopeId == ownerScopeId { return cached.file }
        guard let file = try? read(ownerScopeId: ownerScopeId) else { return DirectoryFile() }
        cached = (ownerScopeId, file)
        return file
    }

    private func read(ownerScopeId: String) throws -> DirectoryFile {
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return DirectoryFile() }
        let combined = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let box = try AES.GCM.SealedBox(combined: combined)
        let cleartext = try AES.GCM.open(box, using: try key(ownerScopeId: ownerScopeId))
        let file = try JSONDecoder().decode(DirectoryFile.self, from: cleartext)
        guard file.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return file
    }

    private func writeLocked(_ file: DirectoryFile, ownerScopeId: String) throws {
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        try prepareDirectory(fileURL.deletingLastPathComponent())
        let cleartext = try JSONEncoder().encode(file)
        let box = try AES.GCM.seal(cleartext, using: try key(ownerScopeId: ownerScopeId))
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Hors des sauvegardes : la clé, propre à l'appareil, n'y serait pas.
    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = rootURL
        try? root.setResourceValues(values)
    }

    private func key(ownerScopeId: String) throws -> SymmetricKey {
        let name = keyName(ownerScopeId)
        if let encoded = try keyStore.string(for: name),
           let bytes = Data(base64Encoded: encoded),
           bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        try keyStore.set(bytes.base64EncodedString(), for: name, accessibility: .afterFirstUnlock)
        return key
    }

    private func keyName(_ ownerScopeId: String) -> String {
        "key:\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    private func ownerDirectory(_ ownerScopeId: String) -> URL {
        rootURL.appendingPathComponent(LocalAccountScope.storageNamespace(for: ownerScopeId), isDirectory: true)
    }

    private func encryptedFileURL(ownerScopeId: String) -> URL {
        ownerDirectory(ownerScopeId).appendingPathComponent("conversations.json.enc", isDirectory: false)
    }
}
