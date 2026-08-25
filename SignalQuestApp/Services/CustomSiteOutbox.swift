import CryptoKit
import Foundation

struct PendingCustomSiteCreation: Codable, Equatable, Sendable {
    let requestId: String
    let ownerScopeId: String
    let draft: CustomSiteDraft
    let createdAtMs: Int64
}

private struct CustomSiteOutboxFile: Codable, Sendable {
    var version = 1
    var records: [PendingCustomSiteCreation] = []
}

enum CustomSiteOutboxOwner {
    static func scope(for userId: String) -> String {
        precondition(!userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let digest = SHA256.hash(data: Data(userId.utf8))
        return "user:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(scope: String) -> Bool {
        guard scope.hasPrefix("user:") else { return false }
        let digest = scope.dropFirst("user:".count)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// File chiffrée, atomique et isolée par compte des sites qui n'ont pas encore
/// reçu d'accusé serveur. Le brouillon ne passe jamais par UserDefaults/Caches.
actor CustomSiteOutboxStore {
    private static let folderName = "CustomSiteOutboxV1"
    private static let keyService = "fr.signalquest.ios.custom-site-outbox"

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        keyStore: TokenStore = KeychainStore(service: CustomSiteOutboxStore.keyService)
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

    /// Retourne le brouillon équivalent déjà présent afin qu'un double-tap ou une
    /// réouverture de l'écran ne fabrique pas une seconde proposition logique.
    func stage(userId: String, draft: CustomSiteDraft) throws -> PendingCustomSiteCreation {
        let normalized = draft.normalized().withoutClientRequestId()
        let ownerScopeId = CustomSiteOutboxOwner.scope(for: userId)
        var snapshot = try read(ownerScopeId: ownerScopeId)
        if let existing = snapshot.records.first(where: { $0.draft == normalized }) {
            return existing
        }
        let record = PendingCustomSiteCreation(
            requestId: "site:\(UUID().uuidString.lowercased())",
            ownerScopeId: ownerScopeId,
            draft: normalized,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try validate(record)
        snapshot.records.append(record)
        try write(snapshot, ownerScopeId: ownerScopeId)
        return record
    }

    func pending(userId: String) throws -> [PendingCustomSiteCreation] {
        let ownerScopeId = CustomSiteOutboxOwner.scope(for: userId)
        return try read(ownerScopeId: ownerScopeId).records
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    func remove(userId: String, requestId: String) throws {
        let ownerScopeId = CustomSiteOutboxOwner.scope(for: userId)
        var snapshot = try read(ownerScopeId: ownerScopeId)
        snapshot.records.removeAll { $0.requestId == requestId }
        try write(snapshot, ownerScopeId: ownerScopeId)
    }

    private func read(ownerScopeId: String) throws -> CustomSiteOutboxFile {
        guard CustomSiteOutboxOwner.isValid(scope: ownerScopeId) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return CustomSiteOutboxFile() }
        let combined = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let box = try AES.GCM.SealedBox(combined: combined)
        let cleartext = try AES.GCM.open(box, using: try key(ownerScopeId: ownerScopeId))
        let snapshot = try decoder.decode(CustomSiteOutboxFile.self, from: cleartext)
        guard snapshot.version == 1 else { throw CocoaError(.fileReadUnknown) }
        try snapshot.records.forEach(validate)
        guard snapshot.records.allSatisfy({ $0.ownerScopeId == ownerScopeId }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    private func write(_ snapshot: CustomSiteOutboxFile, ownerScopeId: String) throws {
        let fileURL = encryptedFileURL(ownerScopeId: ownerScopeId)
        if snapshot.records.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        try snapshot.records.forEach(validate)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleartext = try encoder.encode(snapshot)
        let box = try AES.GCM.seal(cleartext, using: try key(ownerScopeId: ownerScopeId))
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    private func validate(_ record: PendingCustomSiteCreation) throws {
        guard Self.isValidRequestId(record.requestId),
              CustomSiteOutboxOwner.isValid(scope: record.ownerScopeId),
              record.draft.isValid,
              record.draft.clientRequestId == nil
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func key(ownerScopeId: String) throws -> SymmetricKey {
        let keyName = "key:\(ownerScopeId)"
        if let encoded = try keyStore.string(for: keyName),
           let bytes = Data(base64Encoded: encoded),
           bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        try keyStore.set(bytes.base64EncodedString(), for: keyName, accessibility: .afterFirstUnlock)
        return key
    }

    private func encryptedFileURL(ownerScopeId: String) -> URL {
        precondition(CustomSiteOutboxOwner.isValid(scope: ownerScopeId))
        return rootURL
            .appendingPathComponent(String(ownerScopeId.dropFirst("user:".count)), isDirectory: true)
            .appendingPathComponent("pending.json.enc", isDirectory: false)
    }

    private static func isValidRequestId(_ value: String) -> Bool {
        guard (8...128).contains(value.count),
              let first = value.first,
              first.isASCII && (first.isLetter || first.isNumber)
        else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._:-".contains(character))
        }
    }
}

extension CustomSiteDraft {
    fileprivate func withoutClientRequestId() -> CustomSiteDraft {
        var copy = self
        copy.clientRequestId = nil
        return copy
    }
}

enum CustomSiteOutboxRetryPolicy {
    static func isRetryable(_ error: Error) -> Bool {
        if error.isCancellation { return false }
        if let apiError = error as? APIError {
            switch apiError {
            case .transport, .decoding:
                // Une réponse indécodable peut suivre une création réellement
                // acquittée : le rejeu avec la même clé est le seul choix sûr.
                return true
            case .http(let status, _, _, _, _):
                return status == 408 || status == 425 || status == 429 || status >= 500
            default:
                return false
            }
        }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        return false
    }
}
