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
        /// Message où la relève s'est arrêtée, et combien de fois de suite.
        var rereadSequence: Int64?
        var rereadCount: Int?
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
        let file = Self.expiring(try read(conversationId: conversationId, ownerScopeId: ownerScopeId), nowMs: nowMs)
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
        // Une édition qui devient équivoque ne compte plus : sa cible se rejoue.
        for ref in Set(equivocal).subtracting(file.equivocal) {
            if let target = file.messages[ref]?.targetRef { touched.insert(target) }
        }
        file.equivocal.formUnion(equivocal)
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
        for ref in touched { Self.settle(ref, in: &file.messages, equivocal: file.equivocal) }
        file = Self.expiring(file, nowMs: nowMs)
        file.cursor = max(file.cursor, cursor)
        if file.messages.count > Self.maxMessages {
            let kept = file.messages.values.sorted { $0.sequence > $1.sequence }.prefix(Self.maxMessages)
            file.messages = Dictionary(uniqueKeysWithValues: kept.map { ($0.messageRef, $0) })
        }
        try write(file, conversationId: conversationId, ownerScopeId: ownerScopeId)
    }

    /// L'état à l'instant `nowMs` (§13, D.8) : un message éphémère expiré part
    /// avec ses éditions ; une édition expirée cesse de compter et sa cible se
    /// rejoue. `apply` l'écrit ; `snapshot` et `reportGroups` le calculent sans
    /// attendre la relève suivante, pour qu'affichage et signalement suivent
    /// l'heure.
    private static func expiring(_ file: ConversationFile, nowMs: Int64) -> ConversationFile {
        let expired = file.messages.values.filter { $0.expiresAtMs.map { $0 <= nowMs } ?? false }
        guard !expired.isEmpty else { return file }
        var file = file
        let expiredRefs = Set(expired.map(\.messageRef))
        let expiredTexts = Set(expired.filter { $0.kind == "TEXT" }.map(\.messageRef))
        let replayed = Set(expired.compactMap(\.targetRef)).subtracting(expiredTexts)
        file.messages = file.messages.filter {
            !expiredRefs.contains($0.key) && !($0.value.targetRef.map(expiredTexts.contains) ?? false)
        }
        for ref in replayed { settle(ref, in: &file.messages, equivocal: file.equivocal) }
        return file
    }

    /// Rejoue sur un message ses éditions et sa suppression autorisées, dans
    /// l'ordre de leur envoi, en repartant de son texte d'origine : une édition
    /// expirée ou équivoque cesse de compter. Une suppression efface texte et
    /// charge, ceux du message comme ceux de ses éditions, même arrivées après
    /// elle. Une action d'un autre membre est ignorée et gardée sans contenu (§5.3).
    private static func settle(_ ref: String, in messages: inout [String: Stored], equivocal: Set<String>) {
        guard var target = messages[ref], target.kind == "TEXT" else { return }
        let related = messages.values.filter { $0.targetRef == ref }
        // Seules les éditions et suppressions sont réservées à l'auteur : une
        // réaction ou un vote d'un autre membre, au jalon B, gardera son contenu.
        erase(related.filter { $0.senderUserId != target.senderUserId && ["EDIT", "DELETE"].contains($0.kind) }, in: &messages)
        let actions = related
            .filter { $0.senderUserId == target.senderUserId && !equivocal.contains($0.messageRef) }
            .sorted { ($0.sentAtMs, $0.sequence) < ($1.sentAtMs, $1.sequence) }
        guard !target.deleted else {
            erase(actions.filter { $0.kind == "EDIT" }, in: &messages)
            return
        }
        target.text = originalText(of: target)
        target.editedAtMs = nil
        for action in actions {
            if action.kind == "DELETE" {
                target.text = nil
                target.payloadB64 = nil
                target.fkB64 = nil
                target.deleted = true
                erase(actions.filter { $0.kind == "EDIT" }, in: &messages)
                break
            }
            if action.kind == "EDIT" {
                target.text = action.text
                target.editedAtMs = action.sentAtMs
            }
        }
        messages[ref] = target
    }

    private static func originalText(of stored: Stored) -> String? {
        guard let data = stored.payloadB64.flatMap({ Data(base64Encoded: $0) }),
              let payload = try? E2EEV2ContentPayloadV2.parse(data),
              case .text(let value) = payload.body else { return stored.text }
        return value
    }

    private static func erase(_ edits: [Stored], in messages: inout [String: Stored]) {
        for edit in edits {
            var erased = edit
            erased.text = nil
            erased.payloadB64 = nil
            erased.fkB64 = nil
            messages[edit.messageRef] = erased
        }
    }

    /// Avance le curseur de la liste (E.3), jamais en arrière. Séparé de
    /// `apply`, gardé avant le registre : la relève ne le pousse qu'après la
    /// page, jusqu'au premier message à relire.
    func advanceCursor(to cursor: Int64, conversationId: String, ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var file = try read(conversationId: conversationId, ownerScopeId: ownerScopeId)
        guard cursor > file.cursor else { return }
        file.cursor = cursor
        try write(file, conversationId: conversationId, ownerScopeId: ownerScopeId)
    }

    /// Compte les arrêts de la relève sur un même message : au-delà d'une
    /// borne, elle le dépasse, pour qu'aucun message ne bloque la conversation.
    func noteReread(sequence: Int64, conversationId: String, ownerScopeId: String) throws -> Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var file = try read(conversationId: conversationId, ownerScopeId: ownerScopeId)
        let count = file.rereadSequence == sequence ? (file.rereadCount ?? 0) + 1 : 1
        file.rereadSequence = sequence
        file.rereadCount = count
        try write(file, conversationId: conversationId, ownerScopeId: ownerScopeId)
        return count
    }

    /// Ce qu'un signalement peut porter d'un message (§11, v0.4.11).
    struct ReportGroup: Equatable, Sendable {
        /// La version affichée : sa dernière édition retenue, ou le message
        /// lui-même s'il n'a pas été modifié. Elle part toujours.
        let displayed: E2EEV2ReceivedMessageV2
        /// Le reste de son histoire, le plus utile d'abord : l'original, puis
        /// les éditions intermédiaires de la plus récente à la plus ancienne.
        let history: [E2EEV2ReceivedMessageV2]
    }

    /// Les messages choisis, gardés avec leur charge exacte et `fk`. Rien pour
    /// un message supprimé, expiré, en équivoque, dont une charge manque, ou
    /// dont le texte affiché ne correspond plus à une version gardée.
    func reportGroups(
        _ refs: [String], conversationId: String, ownerScopeId: String, nowMs: Int64
    ) throws -> [String: ReportGroup] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let file = Self.expiring(try read(conversationId: conversationId, ownerScopeId: ownerScopeId), nowMs: nowMs)
        func kept(_ stored: Stored) -> E2EEV2ReceivedMessageV2? {
            guard !file.equivocal.contains(stored.messageRef), stored.expiresAtMs.map({ $0 > nowMs }) ?? true,
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
        var groups: [String: ReportGroup] = [:]
        for ref in refs {
            guard let stored = file.messages[ref], stored.kind == "TEXT", !stored.deleted,
                  let original = kept(stored) else { continue }
            let edits = file.messages.values
                .filter { $0.kind == "EDIT" && $0.targetRef == ref && $0.senderUserId == stored.senderUserId }
                .sorted { ($0.sentAtMs, $0.sequence) < ($1.sentAtMs, $1.sequence) }
                .compactMap(kept)
            let displayed = edits.last ?? original
            // Ce que l'utilisateur voit doit être la version qui part.
            guard Self.text(of: displayed) == stored.text else { continue }
            groups[ref] = ReportGroup(
                displayed: displayed, history: edits.isEmpty ? [] : [original] + edits.dropLast().reversed()
            )
        }
        return groups
    }

    private static func text(of message: E2EEV2ReceivedMessageV2) -> String? {
        switch message.payload.body {
        case .text(let value), .edit(_, let value): return value
        case .delete: return nil
        }
    }

    /// Un message gardé tel quel, édition ou suppression comprises (tests).
    func stored(_ ref: String, conversationId: String, ownerScopeId: String) throws -> Stored? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try read(conversationId: conversationId, ownerScopeId: ownerScopeId).messages[ref]
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
