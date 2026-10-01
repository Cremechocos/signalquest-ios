import CryptoKit
import Foundation

/// Registre des messages v2 reçus dans une conversation (§4.2, §4.3) :
/// identités récentes et leur enveloppe, compteurs vus par appareil, et
/// identités en équivoque, jamais affichées. Seul un message authentique
/// (signature et déchiffrement vérifiés) y entre.
struct E2EEV2MessageLedgerV2: Codable, Equatable, Sendable {
    static let recentLimit = 2_000

    struct Entry: Codable, Equatable, Sendable {
        let deviceId: String
        let counter: Int
        /// `b64url(SHA-256(chaîne signée de l'enveloppe))`.
        let envelopeDigest: String
    }

    enum Outcome: Equatable, Sendable {
        case accepted
        /// La même enveloppe, déjà reçue.
        case duplicate
        /// Compteur déjà vu, hors des identités récentes : rien à afficher.
        case replayed
        /// Deux enveloppes signées pour une identité ou un compteur : aucune
        /// n'est affichée (§4.2). Les références à masquer.
        case equivocation([String])
    }

    /// Compteurs vus par appareil, en intervalles `[premier, dernier]` triés et disjoints.
    private(set) var counters: [String: [[Int]]] = [:]
    private(set) var recent: [String: Entry] = [:]
    private(set) var order: [String] = []
    private(set) var equivocal: Set<String> = []

    mutating func record(messageRef: String, deviceId: String, counter: Int, envelopeDigest: String) -> Outcome {
        if equivocal.contains(messageRef) { return .equivocation([messageRef]) }
        if let known = recent[messageRef] {
            guard known.envelopeDigest == envelopeDigest, known.deviceId == deviceId, known.counter == counter else {
                equivocal.insert(messageRef)
                return .equivocation([messageRef])
            }
            return .duplicate
        }
        if seen(deviceId: deviceId, counter: counter) {
            guard let other = order.first(where: { recent[$0]?.deviceId == deviceId && recent[$0]?.counter == counter })
            else { return .replayed }
            equivocal.formUnion([messageRef, other])
            return .equivocation([other, messageRef])
        }
        insert(deviceId: deviceId, counter: counter)
        recent[messageRef] = Entry(deviceId: deviceId, counter: counter, envelopeDigest: envelopeDigest)
        order.append(messageRef)
        if order.count > Self.recentLimit {
            let evicted = order.removeFirst()
            recent[evicted] = nil
        }
        return .accepted
    }

    /// Compteurs manquants entre le premier et le dernier vus de l'appareil
    /// (§4.3) : « des messages de X n'ont pas été reçus ». Avant le premier
    /// compteur vu, ce n'est pas un trou : l'appareil a pu rejoindre plus tard.
    func missingCount(deviceId: String) -> Int {
        let ranges = counters[deviceId] ?? []
        return zip(ranges, ranges.dropFirst()).reduce(0) { $0 + ($1.1[0] - $1.0[1] - 1) }
    }

    private func seen(deviceId: String, counter: Int) -> Bool {
        (counters[deviceId] ?? []).contains { $0[0] <= counter && counter <= $0[1] }
    }

    private mutating func insert(deviceId: String, counter: Int) {
        var ranges = counters[deviceId] ?? []
        ranges.append([counter, counter])
        ranges.sort { $0[0] < $1[0] }
        var merged: [[Int]] = []
        for range in ranges {
            if let last = merged.last, range[0] <= last[1] + 1 {
                merged[merged.count - 1][1] = max(last[1], range[1])
            } else {
                merged.append(range)
            }
        }
        counters[deviceId] = merged
    }
}

/// Registres gardés en fichiers protégés, un par conversation et par compte,
/// exclus des sauvegardes et effacés avec le compte.
final class E2EEV2MessageLedgerStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private static let lock = NSLock()

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) throws {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.baseDirectory = applicationSupport
                .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
                .appendingPathComponent("e2ee-v2-ledger", isDirectory: true)
        } else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
    }

    /// Lit, modifie et réécrit le registre sous verrou.
    func update<T>(
        conversationId: String,
        ownerScopeId: String,
        _ body: (inout E2EEV2MessageLedgerV2) throws -> T
    ) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let directory = baseDirectory.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
        let file = directory.appendingPathComponent(Self.digest(conversationId) + ".json")
        var ledger = E2EEV2MessageLedgerV2()
        if fileManager.fileExists(atPath: file.path) {
            guard let decoded = try? JSONDecoder().decode(E2EEV2MessageLedgerV2.self, from: Data(contentsOf: file)) else {
                throw E2EEV2ConversationStateStore.Failure.invalidRecord
            }
            ledger = decoded
        }
        let before = ledger
        let result = try body(&ledger)
        guard ledger != before else { return result }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = baseDirectory
            try? mutable.setResourceValues(values)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path
            )
        }
        try JSONEncoder().encode(ledger).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return result
    }

    func purge(ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let directory = baseDirectory.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Un message v2 reçu, vérifié et ouvert. `fk` et la charge exacte restent
/// avec lui : le signalement en a besoin (§11).
struct E2EEV2ReceivedMessageV2: Equatable, Sendable {
    let envelopeId: String
    let sequence: Int64
    let messageRef: String
    let senderUserId: String
    let senderDeviceId: String
    let clientRequestId: String
    let epochNumber: Int
    let frankTagB64: String
    let serverTagB64: String
    let serverTimeMs: Int64
    let keyId: String
    let payload: E2EEV2ContentPayloadV2
    let payloadBytes: Data
    let fk: Data
    /// Heure d'effacement d'un message éphémère, ou nil.
    let expiresAtMs: Int64?
}

enum E2EEV2MessageReceptionV2: Equatable, Sendable {
    case received(E2EEV2ReceivedMessageV2)
    case duplicate
    case replayed
    case equivocation([String])
    case expired
    /// Époque que l'appareil ne connaît pas encore : synchroniser la conversation.
    case needsEpoch
    case rejected(String)
}

/// Réception des messages v2 d'une conversation (§3.4, §4, D.7) : appareil
/// certifié d'un membre de l'époque, époque connue et dans sa fenêtre,
/// signature vérifiée avant tout déchiffrement, puis franking, charge,
/// compteur et registre.
final class E2EEV2MessageReceiverV2: @unchecked Sendable {
    /// Fenêtre des messages en vol sous une époque remplacée (§3.4).
    static let replacedEpochWindowMs: Int64 = 24 * 60 * 60 * 1_000

    private let keyStore: E2EEV2EpochKeyStore
    private let stateStore: E2EEV2ConversationStateStore
    private let ledgerStore: E2EEV2MessageLedgerStore
    private let expectedSession: LocalAccountSession?
    private let now: @Sendable () -> Date

    init(
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        ledgerStore: E2EEV2MessageLedgerStore,
        expectedSession: LocalAccountSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keyStore = keyStore
        self.stateStore = stateStore
        self.ledgerStore = ledgerStore
        self.expectedSession = expectedSession
        self.now = now
    }

    /// Une page de messages, dans l'ordre du serveur ; le registre est relu et
    /// réécrit une fois par page.
    func receive(
        _ messages: [E2EEV2DeliveredMessageV2],
        conversationId: String,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String
    ) -> [E2EEV2MessageReceptionV2] {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId) else {
            return messages.map { _ in .rejected("invalid-e2ee-receive-scope") }
        }
        let ownerNamespace = session.ownerNamespace
        let current: E2EEV2ConversationStateStore.CurrentEpoch
        let accepted: [E2EEV2ConversationStateStore.AcceptedEpoch]
        do {
            guard try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace) != nil,
                  let known = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace) else {
                return messages.map { _ in .needsEpoch }
            }
            current = known
            accepted = try stateStore.acceptedEpochs(conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return messages.map { _ in .rejected("e2ee-receive-state-unavailable") }
        }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let opened = messages.map {
            open($0, conversationId: conversationId, current: current, accepted: accepted, devices: devices,
                 ownerNamespace: ownerNamespace, nowMs: nowMs)
        }
        do {
            return try ledgerStore.update(conversationId: conversationId, ownerScopeId: expectedOwnerScopeId) { ledger in
                opened.map { result in
                    guard case .received(let message, let digest) = result else {
                        if case .done(let reception) = result { return reception }
                        return .rejected("invalid-e2ee-message")
                    }
                    switch ledger.record(
                        messageRef: message.messageRef, deviceId: message.senderDeviceId,
                        counter: Int(message.payload.counter), envelopeDigest: digest
                    ) {
                    case .accepted:
                        if let expiresAtMs = message.expiresAtMs, expiresAtMs <= nowMs { return .expired }
                        return .received(message)
                    case .duplicate: return .duplicate
                    case .replayed: return .replayed
                    case .equivocation(let refs): return .equivocation(refs)
                    }
                }
            }
        } catch {
            return messages.map { _ in .rejected("e2ee-ledger-unavailable") }
        }
    }

    private enum Opened {
        case received(E2EEV2ReceivedMessageV2, digest: String)
        case done(E2EEV2MessageReceptionV2)
    }

    private func open(
        _ message: E2EEV2DeliveredMessageV2,
        conversationId: String,
        current: E2EEV2ConversationStateStore.CurrentEpoch,
        accepted: [E2EEV2ConversationStateStore.AcceptedEpoch],
        devices: E2EEV2CertifiedDeviceSet,
        ownerNamespace: String,
        nowMs: Int64
    ) -> Opened {
        let envelope = message.signed.envelope
        let epochNumber = envelope.epochNumber
        // Appareil certifié, non révoqué, de l'utilisateur annoncé (§3.4).
        guard let senderKey = devices.signingKey(userId: message.senderUserId, deviceId: message.senderDeviceId) else {
            return .done(.rejected("e2ee-sender-not-certified"))
        }
        // Époque connue : la courante, ou une remplacée depuis moins de 24 heures.
        guard epochNumber <= current.epochNumber else { return .done(.needsEpoch) }
        let members: [String]
        if epochNumber == current.epochNumber {
            members = current.memberIds
        } else {
            guard let epoch = accepted.first(where: { $0.epochNumber == epochNumber }),
                  let replacedAtMs = accepted.filter({ $0.epochNumber > epochNumber }).map(\.acceptedAtMs).min()
                    ?? (current.epochNumber > epochNumber ? current.acceptedAtMs : nil) else {
                return .done(.rejected("e2ee-epoch-unknown"))
            }
            guard nowMs - replacedAtMs <= Self.replacedEpochWindowMs else { return .done(.rejected("e2ee-epoch-replaced")) }
            members = epoch.memberIds
        }
        // Membre de l'époque, par utilisateur (§5.3).
        guard members.contains(message.senderUserId) else { return .done(.rejected("e2ee-sender-not-member")) }
        let context = message.signed.context(conversationId: conversationId, senderDeviceId: message.senderDeviceId)
        let canonical: Data
        do {
            canonical = try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope)
            try E2EEV2MessageCryptoV2.verifySignature(
                context: context, envelope: envelope, signatureDerB64: message.signed.senderSignatureB64, senderSigningKey: senderKey
            )
        } catch {
            return .done(.rejected("invalid-e2ee-message-signature"))
        }
        guard var epoch = try? keyStore.loadEpoch(conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace)
        else { return .done(.rejected("e2ee-epoch-key-unavailable")) }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        let opened: (fk: Data, payload: E2EEV2ContentPayloadV2, payloadBytes: Data)
        do {
            opened = try E2EEV2MessageCryptoV2.decrypt(envelope: envelope, epochKey: epoch.epochKey, context: context)
        } catch {
            return .done(.rejected("invalid-e2ee-message"))
        }
        // Jalon A : texte, édition et suppression, sans blob.
        guard envelope.encryptedBlobIds.isEmpty else { return .done(.rejected("invalid-e2ee-message")) }
        let ttlMs = Int64(envelope.ttlSeconds) * 1_000
        return .received(
            E2EEV2ReceivedMessageV2(
                envelopeId: message.envelopeId, sequence: message.sequence,
                messageRef: E2EEV2MessageRef.make(
                    conversationId: conversationId, senderDeviceId: message.senderDeviceId,
                    clientRequestId: envelope.clientRequestId
                ),
                senderUserId: message.senderUserId, senderDeviceId: message.senderDeviceId,
                clientRequestId: envelope.clientRequestId, epochNumber: epochNumber, frankTagB64: envelope.frankTagB64,
                serverTagB64: message.serverTagB64, serverTimeMs: message.serverTimeMs, keyId: message.keyId,
                payload: opened.payload, payloadBytes: opened.payloadBytes, fk: opened.fk,
                // Le plus tôt des deux : un serveur ne prolonge pas un message éphémère.
                expiresAtMs: ttlMs > 0 ? min(opened.payload.sentAtMs, message.serverTimeMs) + ttlMs : nil
            ),
            digest: E2EEV2Canonical.sha256B64URL(canonical)
        )
    }
}

/// §5.3 : une édition ou une suppression ne vaut que venant de l'auteur du
/// message visé, par utilisateur (n'importe lequel de ses appareils). Une
/// cible inconnue n'autorise rien.
enum E2EEV2MessageAuthorization {
    static func allows(_ message: E2EEV2ReceivedMessageV2, targetAuthorUserId: String?) -> Bool {
        switch message.payload.body {
        case .text: return true
        case .edit, .delete: return targetAuthorUserId == message.senderUserId
        }
    }
}
