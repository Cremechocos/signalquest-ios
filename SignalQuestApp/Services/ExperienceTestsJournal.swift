import CryptoKit
import Foundation

/// État d'envoi d'un test gardé sur le téléphone.
enum ExperienceDelivery: String, Codable, Sendable {
    /// En file : le serveur confirmera.
    case pending
    case synced
    /// Refus définitif du serveur (400, 409 de conflit, 413) ou corps invalide : jamais rejoué.
    case rejected
    /// Sans compte : gardé sur le téléphone, jamais envoyé (pas de mode invité en v1).
    case localOnly = "local_only"
}

/// Un test d'expérience gardé sur le téléphone : le corps exact du POST, et ce que
/// l'écran montre en plus (consommation par test, cause d'un échec).
struct ExperienceJournalRecord: Codable, Equatable, Sendable {
    struct Usage: Codable, Equatable, Sendable {
        let bytes: Int64
        let durationMs: Int64
    }

    /// UUID en minuscules, écrit AVANT tout envoi : un rejeu repart avec le même.
    let clientSubmissionId: String
    let ownerScopeId: String
    let measuredAtMs: Int64
    /// Corps envoyé tel quel (`experience-tests-v1`), ville comprise : le fichier est chiffré.
    let body: Data
    var delivery: ExperienceDelivery
    var serverId: String?
    var postId: String?
    /// Code ou statut du dernier refus, pour le diagnostic ; jamais un message serveur brut.
    var lastError: String?
    /// Clés `ExperienceTestKind`.
    var usage: [String: Usage] = [:]
    /// Pourquoi un test a échoué (`serverBusy`, `routeChanged`), pour l'écran seulement.
    var failureCauses: [String: String] = [:]

    var result: ExperienceStoredResult? { ExperienceResultReader.read(body) }
}

private struct ExperienceJournalFile: Codable, Sendable {
    var version = 1
    var records: [ExperienceJournalRecord] = []
}

/// Journal chiffré, atomique et isolé par compte (ou invité) des tests d'expérience,
/// sur le modèle de `CustomSiteOutboxStore`.
actor ExperienceJournalStore {
    private static let folderName = "ExperienceTestsV1"
    private static let keyService = "fr.signalquest.ios.experience-tests"
    /// Au-delà, les plus anciens tests déjà envoyés ou refusés partent ; jamais un test en attente.
    static let maxRecords = 200

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        keyStore: TokenStore = KeychainStore(service: ExperienceJournalStore.keyService)
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

    /// Du plus récent au plus ancien.
    func records(ownerScopeId: String) throws -> [ExperienceJournalRecord] {
        try read(ownerScopeId: ownerScopeId).records.sorted { $0.measuredAtMs > $1.measuredAtMs }
    }

    func record(ownerScopeId: String, clientSubmissionId: String) throws -> ExperienceJournalRecord? {
        try read(ownerScopeId: ownerScopeId).records.first { $0.clientSubmissionId == clientSubmissionId }
    }

    /// Faux si le même identifiant est déjà là (double appui, relance).
    @discardableResult
    func insertIfAbsent(_ record: ExperienceJournalRecord) throws -> Bool {
        var snapshot = try read(ownerScopeId: record.ownerScopeId)
        guard !snapshot.records.contains(where: { $0.clientSubmissionId == record.clientSubmissionId }) else { return false }
        snapshot.records.append(record)
        snapshot.records = Self.pruned(snapshot.records)
        try write(snapshot, ownerScopeId: record.ownerScopeId)
        return true
    }

    func update(ownerScopeId: String, clientSubmissionId: String, _ change: @Sendable (inout ExperienceJournalRecord) -> Void) throws {
        var snapshot = try read(ownerScopeId: ownerScopeId)
        guard let index = snapshot.records.firstIndex(where: { $0.clientSubmissionId == clientSubmissionId }) else { return }
        change(&snapshot.records[index])
        try write(snapshot, ownerScopeId: ownerScopeId)
    }

    func remove(ownerScopeId: String, clientSubmissionId: String) throws {
        var snapshot = try read(ownerScopeId: ownerScopeId)
        snapshot.records.removeAll { $0.clientSubmissionId == clientSubmissionId }
        try write(snapshot, ownerScopeId: ownerScopeId)
    }

    static func pruned(_ records: [ExperienceJournalRecord]) -> [ExperienceJournalRecord] {
        guard records.count > maxRecords else { return records }
        var removable = records.filter { $0.delivery != .pending }.sorted { $0.measuredAtMs < $1.measuredAtMs }
        removable = Array(removable.prefix(records.count - maxRecords))
        let dropped = Set(removable.map(\.clientSubmissionId))
        return records.filter { !dropped.contains($0.clientSubmissionId) }
    }

    private func read(ownerScopeId: String) throws -> ExperienceJournalFile {
        let fileURL = fileURL(ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return ExperienceJournalFile() }
        let combined = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let cleartext: Data
        do {
            cleartext = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: try key(ownerScopeId: ownerScopeId))
        } catch {
            // Revenu d'une sauvegarde sans la clé de cet appareil : mis de côté, le journal repart vide.
            try? fileManager.removeItem(at: fileURL.appendingPathExtension("unreadable"))
            try? fileManager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("unreadable"))
            return ExperienceJournalFile()
        }
        let snapshot = try decoder.decode(ExperienceJournalFile.self, from: cleartext)
        guard snapshot.version == 1, snapshot.records.allSatisfy({ $0.ownerScopeId == ownerScopeId }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    private func write(_ snapshot: ExperienceJournalFile, ownerScopeId: String) throws {
        let fileURL = fileURL(ownerScopeId: ownerScopeId)
        if snapshot.records.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
            return
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Hors des sauvegardes : la clé, propre à l'appareil, n'y serait pas.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = rootURL
        try? root.setResourceValues(excluded)
        let box = try AES.GCM.seal(try encoder.encode(snapshot), using: try key(ownerScopeId: ownerScopeId))
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func key(ownerScopeId: String) throws -> SymmetricKey {
        let keyName = "key:\(Self.digest(ownerScopeId))"
        if let encoded = try keyStore.string(for: keyName), let bytes = Data(base64Encoded: encoded), bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        let key = SymmetricKey(size: .bits256)
        try keyStore.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: keyName, accessibility: .afterFirstUnlock)
        return key
    }

    /// Dossier nommé par l'empreinte de la portée : l'identifiant du compte n'apparaît pas sur le disque.
    private func fileURL(ownerScopeId: String) -> URL {
        rootURL
            .appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
            .appendingPathComponent("tests.json.enc", isDirectory: false)
    }

    private static func digest(_ ownerScopeId: String) -> String {
        SHA256.hash(data: Data(ownerScopeId.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
