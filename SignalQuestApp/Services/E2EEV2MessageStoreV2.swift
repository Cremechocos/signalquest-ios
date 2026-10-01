import CryptoKit
import Foundation

/// Messages v2 reçus et ouverts, gardés sur l'appareil (§4, §11, §13) : un
/// fichier par compte et par conversation, scellé en AES-GCM avec une clé du
/// trousseau propre à l'appareil, exclu des sauvegardes et effacé avec le
/// compte. Sur le modèle de `MessageDraftStore`. Le serveur ne garde que des
/// enveloppes : sans ce magasin, un message déjà vu ne se relirait plus,
/// puisque le registre le tient pour un doublon. Synchrone, sous verrou : il
/// s'écrit dans la mise à jour du registre, avant elle.
final class E2EEV2MessageStoreV2: @unchecked Sendable {
    static let keyService = "fr.signalquest.ios.e2ee-v2-messages"
    /// Au-delà, les plus anciens tombent (par séquence du serveur).
    static let maxMessages = 5_000

    struct Stored: Codable, Equatable, Sendable {
        let messageRef: String
        let envelopeId: String
        let sequence: Int64
        let senderUserId: String
        let senderDeviceId: String
        let clientRequestId: String
        let epochNumber: Int
        let serverTimeMs: Int64
        let serverTagB64: String
        let keyId: String
        let frankTagB64: String
        /// `TEXT`, `EDIT` ou `DELETE` ; seuls les `TEXT` s'affichent.
        let kind: String
        let targetRef: String?
        let replyToRef: String?
        let sentAtMs: Int64
        let expiresAtMs: Int64?
        /// Charge exacte et `fk`, pour le signalement (§11) ; effacées avec le message.
        var payloadB64: String?
        var fkB64: String?
        /// Texte affiché : celui du message, ou de sa dernière édition autorisée.
        /// Pour une édition, son nouveau texte.
        var text: String?
        var editedAtMs: Int64?
        var deleted: Bool
    }

    struct Snapshot: Equatable, Sendable {
        /// Séquence du dernier message lu : le curseur de la liste (E.3).
        let cursor: Int64
        /// Messages affichables, dans l'ordre du serveur.
        let messages: [Stored]
        /// Identités en équivoque : jamais affichées, l'utilisateur est prévenu.
        let equivocalRefs: Set<String>
    }

    private struct ConversationFile: Codable {
        var version = 1
        var cursor: Int64 = 0
        var messages: [String: Stored] = [:]
        var equivocal: Set<String> = []
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private static let lock = NSLock()

    init(rootURL: URL? = nil, fileManager: FileManager = .default, keyStore: TokenStore = KeychainStore(service: keyService)) {
        self.fileManager = fileManager
        self.keyStore = keyStore
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.rootURL = support
                .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
                .appendingPathComponent("e2ee-v2-messages", isDirectory: true)
        }
    }

    /// Messages `TEXT` affichables ; un message supprimé reste, sans texte ni
    /// charge, pour sa mention « supprimé ».
    func snapshot(conversationId: String, ownerScopeId: String, nowMs: Int64) throws -> Snapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let file = try read(conversationId: conversationId, ownerScopeId: ownerScopeId)
        let visible = file.messages.values
            .filter { $0.kind == "TEXT" && !file.equivocal.contains($0.messageRef) && ($0.expiresAtMs.map { $0 > nowMs } ?? true) }
            .sorted { $0.sequence < $1.sequence }
        return Snapshot(cursor: file.cursor, messages: visible, equivocalRefs: file.equivocal)
    }

    /// Garde une page reçue, puis avance le curseur. Les éditions et
    /// suppressions ne valent que venant de l'auteur du message visé, par
    /// utilisateur (§5.3) ; arrivées avant leur cible, elles s'appliquent quand
    /// elle arrive. À appeler avant d'écrire le registre : un arrêt entre les
    /// deux ne fait que relire la page.
    func apply(
        _ received: [E2EEV2ReceivedMessageV2],
        equivocal: [String],
        cursor: Int64,
        conversationId: String,
        ownerScopeId: String,
        nowMs: Int64
    ) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var file = try read(conversationId: conversationId, ownerScopeId: ownerScopeId)
        var touched: Set<String> = []
        for message in received where file.messages[message.messageRef] == nil {
            let target: String?, text: String?
            switch message.payload.body {
            case .text(let value): (target, text) = (nil, value)
            case .edit(let ref, let value): (target, text) = (ref, value)
            case .delete(let ref): (target, text) = (ref, nil)
            }
            file.messages[message.messageRef] = Stored(
                messageRef: message.messageRef, envelopeId: message.envelopeId, sequence: message.sequence,
                senderUserId: message.senderUserId, senderDeviceId: message.senderDeviceId,
                clientRequestId: message.clientRequestId, epochNumber: message.epochNumber,
                serverTimeMs: message.serverTimeMs, serverTagB64: message.serverTagB64, keyId: message.keyId,
                frankTagB64: message.frankTagB64, kind: message.payload.body.kind, targetRef: target,
                replyToRef: message.payload.replyToRef, sentAtMs: message.payload.sentAtMs,
                expiresAtMs: message.expiresAtMs, payloadB64: message.payloadBytes.base64EncodedString(),
                fkB64: message.fk.base64EncodedString(), text: text, editedAtMs: nil, deleted: false
            )
            touched.insert(target ?? message.messageRef)
        }
        for ref in touched { Self.settle(ref, in: &file.messages) }
        file.equivocal.formUnion(equivocal)
        // Un message éphémère expiré quitte aussi l'appareil (§13).
        file.messages = file.messages.filter { $0.value.expiresAtMs.map { $0 > nowMs } ?? true }
        file.cursor = max(file.cursor, cursor)
        if file.messages.count > Self.maxMessages {
            let kept = file.messages.values.sorted { $0.sequence > $1.sequence }.prefix(Self.maxMessages)
            file.messages = Dictionary(uniqueKeysWithValues: kept.map { ($0.messageRef, $0) })
        }
        try write(file, conversationId: conversationId, ownerScopeId: ownerScopeId)
    }

    /// Rejoue sur un message ses éditions et sa suppression autorisées, dans
    /// l'ordre de leur envoi. Une suppression efface texte et charge.
    private static func settle(_ ref: String, in messages: inout [String: Stored]) {
        guard var target = messages[ref], target.kind == "TEXT", !target.deleted else { return }
        let actions = messages.values
            .filter { $0.targetRef == ref && $0.senderUserId == target.senderUserId }
            .sorted { ($0.sentAtMs, $0.sequence) < ($1.sentAtMs, $1.sequence) }
        for action in actions {
            if action.kind == "DELETE" {
                target.text = nil
                target.payloadB64 = nil
                target.fkB64 = nil
                target.deleted = true
                break
            }
            if action.kind == "EDIT" {
                target.text = action.text
                target.editedAtMs = action.sentAtMs
            }
        }
        messages[ref] = target
    }

    /// Messages gardés, pour un signalement (§11) : seulement ceux reçus par
    /// cet appareil, dont la charge exacte et `fk` sont encore là.
    func reportable(_ refs: [String], conversationId: String, ownerScopeId: String) throws -> [E2EEV2ReceivedMessageV2] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let file = try read(conversationId: conversationId, ownerScopeId: ownerScopeId)
        return refs.compactMap { ref -> E2EEV2ReceivedMessageV2? in
            guard let stored = file.messages[ref], !file.equivocal.contains(ref),
                  let payloadBytes = stored.payloadB64.flatMap({ Data(base64Encoded: $0) }),
                  let fk = stored.fkB64.flatMap({ Data(base64Encoded: $0) }),
                  let payload = try? E2EEV2ContentPayloadV2.parse(payloadBytes) else { return nil }
            return E2EEV2ReceivedMessageV2(
                envelopeId: stored.envelopeId, sequence: stored.sequence, messageRef: stored.messageRef,
                senderUserId: stored.senderUserId, senderDeviceId: stored.senderDeviceId,
                clientRequestId: stored.clientRequestId, epochNumber: stored.epochNumber,
                frankTagB64: stored.frankTagB64, serverTagB64: stored.serverTagB64, serverTimeMs: stored.serverTimeMs,
                keyId: stored.keyId, payload: payload, payloadBytes: payloadBytes, fk: fk, expiresAtMs: stored.expiresAtMs
            )
        }
    }

    func purge(ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let directory = rootURL.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        try keyStore.remove(Self.digest(ownerScopeId))
    }

    // MARK: Fichiers scellés

    private func read(conversationId: String, ownerScopeId: String) throws -> ConversationFile {
        let url = fileURL(conversationId: conversationId, ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: url.path) else { return ConversationFile() }
        let key = try sealingKey(ownerScopeId: ownerScopeId, create: false)
        guard let key, let box = try? AES.GCM.SealedBox(combined: Data(contentsOf: url)),
              let clear = try? AES.GCM.open(box, using: key, authenticating: Data(conversationId.utf8)),
              let file = try? JSONDecoder().decode(ConversationFile.self, from: clear), file.version == 1 else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
        return file
    }

    private func write(_ file: ConversationFile, conversationId: String, ownerScopeId: String) throws {
        let url = fileURL(conversationId: conversationId, ownerScopeId: ownerScopeId)
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = rootURL
            try? root.setResourceValues(values)
        }
        guard let key = try sealingKey(ownerScopeId: ownerScopeId, create: true) else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(file), using: key, authenticating: Data(conversationId.utf8))
        guard let combined = sealed.combined else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Une clé par compte, propre à l'appareil, lisible seulement déverrouillé.
    private func sealingKey(ownerScopeId: String, create: Bool) throws -> SymmetricKey? {
        let name = Self.digest(ownerScopeId)
        if let stored = try keyStore.string(for: name), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try keyStore.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: name, accessibility: .whenUnlocked)
        return key
    }

    private func fileURL(conversationId: String, ownerScopeId: String) -> URL {
        rootURL.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
            .appendingPathComponent(Self.digest(conversationId) + ".sealed")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
