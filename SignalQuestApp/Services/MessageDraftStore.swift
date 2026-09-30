import CryptoKit
import Foundation

/// Brouillons de messagerie, un par conversation : ce qu'on avait commencé à
/// écrire revient quand on rouvre la conversation (plan 3, vague 1).
///
/// Sur le modèle de `CustomSiteOutboxStore` : un fichier par compte, scellé en
/// AES-GCM avec une clé du trousseau propre à l'appareil, et exclu des
/// sauvegardes. Un brouillon de conversation chiffrée ne passe donc jamais en
/// clair par UserDefaults ni par une sauvegarde (spec du chiffrement, §13).
/// Rien ne part au serveur.
actor MessageDraftStore {
    static let shared = MessageDraftStore()
    static let didChange = Notification.Name("SignalQuest.MessageDraftsDidChange")
    /// Au-delà, les plus anciens tombent : un brouillon oublié ne s'accumule pas.
    static let maxDrafts = 200

    struct Draft: Codable, Equatable, Sendable {
        let text: String
        let updatedAtMs: Int64
    }

    private struct DraftFile: Codable {
        var version = 1
        var drafts: [String: Draft] = [:]
    }

    private static let folderName = "MessageDraftsV1"
    private static let keyService = "fr.signalquest.ios.message-drafts"

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        keyStore: TokenStore = KeychainStore(service: MessageDraftStore.keyService)
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

    func text(conversationId: String, ownerScopeId: String) -> String? {
        (try? read(ownerScopeId: ownerScopeId))?.drafts[conversationId]?.text
    }

    /// Brouillons du compte, par conversation, pour la liste des conversations.
    func all(ownerScopeId: String) -> [String: String] {
        ((try? read(ownerScopeId: ownerScopeId))?.drafts ?? [:]).mapValues(\.text)
    }

    /// Un texte vide, ou fait d'espaces, efface le brouillon. Un fichier
    /// illisible (clé perdue, contenu altéré) est remplacé plutôt que bloquant.
    func save(_ text: String, conversationId: String, ownerScopeId: String, now: Date = Date()) throws {
        guard !conversationId.isEmpty else { return }
        var file = (try? read(ownerScopeId: ownerScopeId)) ?? DraftFile()
        let previous = file.drafts[conversationId]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard previous != nil else { return }
            file.drafts[conversationId] = nil
        } else {
            guard previous?.text != text else { return }
            file.drafts[conversationId] = Draft(text: text, updatedAtMs: Int64(now.timeIntervalSince1970 * 1_000))
            if file.drafts.count > Self.maxDrafts {
                let kept = file.drafts.sorted { $0.value.updatedAtMs > $1.value.updatedAtMs }.prefix(Self.maxDrafts)
                file.drafts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
        }
        try write(file, ownerScopeId: ownerScopeId)
        Self.announce()
    }

    /// À la déconnexion : le fichier et sa clé partent avec le compte.
    func purge(ownerScopeId: String) {
        let directory = ownerDirectory(ownerScopeId)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try? keyStore.remove(keyName(ownerScopeId))
        Self.announce()
    }

    private static func announce() {
        Task { @MainActor in NotificationCenter.default.post(name: didChange, object: nil) }
    }

    private func read(ownerScopeId: String) throws -> DraftFile {
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return DraftFile() }
        let combined = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let box = try AES.GCM.SealedBox(combined: combined)
        let cleartext = try AES.GCM.open(box, using: try key(ownerScopeId: ownerScopeId))
        let file = try JSONDecoder().decode(DraftFile.self, from: cleartext)
        guard file.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return file
    }

    private func write(_ file: DraftFile, ownerScopeId: String) throws {
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        if file.drafts.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
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
        ownerDirectory(ownerScopeId).appendingPathComponent("drafts.json.enc", isDirectory: false)
    }
}

/// Sauvegarde du brouillon d'une conversation ouverte. Tenue hors de l'état
/// SwiftUI : la frappe ne redessine pas la conversation (PERF-MSG-01).
@MainActor
final class MessageDraftAutosaver {
    let conversationId: String
    let ownerScopeId: String
    /// Brouillon courant, hors édition d'un message.
    private(set) var text = ""
    private let store: MessageDraftStore
    private var pending: Task<Void, Never>?

    init(
        conversationId: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        store: MessageDraftStore = .shared
    ) {
        self.conversationId = conversationId
        self.ownerScopeId = ownerScopeId
        self.store = store
    }

    /// Brouillon à remettre dans le champ, sauf si l'on a déjà commencé à écrire.
    func load() async -> String? {
        let stored = await store.text(conversationId: conversationId, ownerScopeId: ownerScopeId) ?? ""
        guard text.isEmpty, !stored.isEmpty else { return nil }
        text = stored
        return stored
    }

    /// Frappe : enregistré après une courte pause.
    func textChanged(_ value: String) {
        guard value != text else { return }
        text = value
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Message envoyé : le brouillon part tout de suite, pour ne pas revenir
    /// après un arrêt brutal de l'app.
    func discard() {
        text = ""
        pending?.cancel()
        pending = Task { [weak self] in await self?.flush() }
    }

    /// Sortie de la conversation ou passage en arrière-plan : sans attendre.
    func flush() async {
        // Un compte qui a changé entre-temps n'hérite pas du brouillon.
        guard LocalAccountScope.currentOwnerScopeId == ownerScopeId else { return }
        try? await store.save(text, conversationId: conversationId, ownerScopeId: ownerScopeId)
    }
}
