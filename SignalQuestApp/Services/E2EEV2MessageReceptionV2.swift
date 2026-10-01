import CryptoKit
import Foundation

/// Registre des messages v2 reçus dans une conversation (§4.2, §4.3) :
/// identités récentes et leur enveloppe, compteurs vus par appareil, et
/// identités en équivoque, jamais affichées. Seul un message authentique
/// (signature et déchiffrement vérifiés) y entre.
struct E2EEV2MessageLedgerV2: Codable, Equatable, Sendable {
    static let recentLimit = 2_000
    /// Au-delà, les deux plus anciens intervalles d'un appareil fusionnent : le
    /// trou qui les séparait n'est plus signalé, le fichier reste borné.
    static let rangeLimit = 1_000

    struct Entry: Codable, Equatable, Sendable {
        let deviceId: String
        let counter: Int
        /// `frankTag` vérifié : il lie la charge exacte, quelle que soit
        /// l'époque sous laquelle elle a été chiffrée.
        let frankTagB64: String
    }

    enum Outcome: Equatable, Sendable {
        case accepted
        /// La même identité et le même `frankTag`, donc la même charge : déjà
        /// reçue, au besoin rechiffrée sous une autre époque.
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
    /// Messages acceptés par époque : au plus 10 000 avant une rotation (§3.3).
    private(set) var acceptedPerEpoch: [String: Int] = [:]
    /// Toutes les identités vues, à vie (§4.2) : les 96 premiers bits de leur
    /// `messageRef`. Au-delà des identités récentes, une identité déjà vue n'est
    /// plus jamais affichée de nouveau.
    private(set) var seenRefs: Set<String> = []
    /// Heure locale où un registre illisible a été repris de zéro : ses
    /// compteurs ne disent plus tout ce qui a été reçu (miroir de notification).
    private(set) var resetAtMs: Int64?

    mutating func markReset(atMs: Int64) {
        resetAtMs = atMs
    }

    static func refPrefix(_ messageRef: String) -> String { String(messageRef.prefix(16)) }

    /// Intervalles bien formés, triés et disjoints ; identités récentes cohérentes.
    var isConsistent: Bool {
        counters.values.allSatisfy { ranges in
            ranges.allSatisfy { $0.count == 2 && 1 <= $0[0] && $0[0] <= $0[1] && $0[1] <= E2EEV2Canonical.maxSequenceNumber }
                && zip(ranges, ranges.dropFirst()).allSatisfy { $0.0[1] + 1 < $0.1[0] }
        } && order.count == recent.count && Set(order) == Set(recent.keys)
    }

    mutating func record(messageRef: String, deviceId: String, counter: Int, frankTagB64: String, epochNumber: Int) -> Outcome {
        if equivocal.contains(messageRef) { return .equivocation([messageRef]) }
        if let known = recent[messageRef] {
            guard known.frankTagB64 == frankTagB64, known.deviceId == deviceId, known.counter == counter else {
                equivocal.insert(messageRef)
                return .equivocation([messageRef])
            }
            return .duplicate
        }
        if seenRefs.contains(Self.refPrefix(messageRef)) { return .replayed }
        if seen(deviceId: deviceId, counter: counter) {
            guard let other = order.first(where: { recent[$0]?.deviceId == deviceId && recent[$0]?.counter == counter })
            else { return .replayed }
            equivocal.formUnion([messageRef, other])
            return .equivocation([other, messageRef])
        }
        insert(deviceId: deviceId, counter: counter)
        recent[messageRef] = Entry(deviceId: deviceId, counter: counter, frankTagB64: frankTagB64)
        order.append(messageRef)
        seenRefs.insert(Self.refPrefix(messageRef))
        acceptedPerEpoch[String(epochNumber), default: 0] += 1
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

    func acceptedCount(epochNumber: Int) -> Int {
        acceptedPerEpoch[String(epochNumber)] ?? 0
    }

    /// Plus haut compteur vu d'un appareil : celui de cet appareil ne doit
    /// jamais redescendre en dessous (sauvegarde restaurée, E.3).
    func highestCounter(deviceId: String) -> Int? {
        counters[deviceId]?.last?[1]
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
        if merged.count > Self.rangeLimit {
            merged[1][0] = merged[0][0]
            merged.removeFirst()
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
        var unreadable = false
        // Illisible ou incohérent : repart de zéro plutôt que de bloquer la
        // conversation, en le notant. Le magasin des messages garde les siens
        // et ses équivoques.
        if fileManager.fileExists(atPath: file.path) {
            if let decoded = try? JSONDecoder().decode(E2EEV2MessageLedgerV2.self, from: Data(contentsOf: file)),
               decoded.isConsistent {
                ledger = decoded
            } else {
                unreadable = true
            }
        }
        let before = ledger
        if unreadable { ledger.markReset(atMs: Int64(Date().timeIntervalSince1970 * 1_000)) }
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

    /// Le registre tel qu'il est, sans le réécrire : vide s'il n'existe pas,
    /// une erreur s'il ne se lit pas (le miroir de notification ne s'écrit
    /// pas sans lui).
    func read(conversationId: String, ownerScopeId: String) throws -> E2EEV2MessageLedgerV2 {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let file = baseDirectory.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
            .appendingPathComponent(Self.digest(conversationId) + ".json")
        guard fileManager.fileExists(atPath: file.path) else { return E2EEV2MessageLedgerV2() }
        let decoded = try JSONDecoder().decode(E2EEV2MessageLedgerV2.self, from: Data(contentsOf: file))
        guard decoded.isConsistent else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
        return decoded
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
    /// Message éphémère dont l'heure d'effacement, d'après l'horloge signée de
    /// son émetteur, est passée : rien à afficher, son compteur est compté.
    case expired
    /// Message authentique d'une version ou d'un `kind` inconnus : « Contenu
    /// non pris en charge » (§5.2). Son compteur est compté.
    case unsupported(messageRef: String, senderUserId: String)
    /// Époque que l'appareil ne connaît pas encore : synchroniser la conversation.
    case needsEpoch
    /// Échec passager (annuaire en retard, coffre verrouillé, stockage, session
    /// changée) : le curseur ne dépasse pas ce message, qui se relira.
    case retryLater(String)
    case rejected(String)
}

/// Réception des messages v2 d'une conversation (§3.4, §4, D.7), dans cet
/// ordre : appareil certifié, signature, époque connue et dans sa fenêtre,
/// membre de l'époque et de l'état le plus récent, puis déchiffrement,
/// franking, charge, compteur et registre.
final class E2EEV2MessageReceiverV2: @unchecked Sendable {
    /// Fenêtre des messages en vol, sous une époque remplacée ou d'un membre
    /// parti (§3.4).
    static let replacedEpochWindowMs: Int64 = 24 * 60 * 60 * 1_000

    private let identityStore: E2EEV2DeviceIdentityStore
    private let keyStore: E2EEV2EpochKeyStore
    private let stateStore: E2EEV2ConversationStateStore
    private let ledgerStore: E2EEV2MessageLedgerStore
    private let expectedSession: LocalAccountSession?
    private let now: @Sendable () -> Date

    init(
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        ledgerStore: E2EEV2MessageLedgerStore,
        expectedSession: LocalAccountSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.stateStore = stateStore
        self.ledgerStore = ledgerStore
        self.expectedSession = expectedSession
        self.now = now
    }

    /// Une page de messages, dans l'ordre du serveur ; le registre est relu et
    /// réécrit une fois par page. `persist` garde les messages reçus et les
    /// identités en équivoque avant l'écriture du registre : s'il échoue, rien
    /// n'est retenu et la page se relira.
    func receive(
        _ messages: [E2EEV2DeliveredMessageV2],
        conversationId: String,
        isGroup: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        expectedOwnerScopeId: String,
        persist: (_ received: [E2EEV2ReceivedMessageV2], _ equivocal: [String]) throws -> Void = { _, _ in }
    ) -> [E2EEV2MessageReceptionV2] {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId) else {
            return messages.map { _ in .rejected("invalid-e2ee-receive-scope") }
        }
        let ownerNamespace = session.ownerNamespace
        let context: Context
        do {
            guard let genesis = try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace),
                  let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace) else {
                return messages.map { _ in .needsEpoch }
            }
            let chain = try stateStore.membershipChain(conversationId: conversationId, ownerNamespace: ownerNamespace)
            // Chaîne gardée, déjà vérifiée : sa tête donne les membres actuels.
            let head = try E2EEV2MembershipChain.apply(
                chain, conversationId: conversationId, isGroup: isGroup, genesisLength: genesis.membershipChangeNumber,
                verifiedCount: chain.count
            ) { _, _ in nil }
            context = Context(
                conversationId: conversationId, current: current,
                accepted: try stateStore.acceptedEpochs(conversationId: conversationId, ownerNamespace: ownerNamespace),
                latestMembers: head.members,
                departures: try stateStore.departures(conversationId: conversationId, ownerNamespace: ownerNamespace),
                devices: devices, ownerNamespace: ownerNamespace, nowMs: Int64(now().timeIntervalSince1970 * 1_000)
            )
        } catch {
            return messages.map { _ in .retryLater("e2ee-receive-state-unavailable") }
        }
        let opened = messages.map { open($0, context) }
        let ownDeviceId = (try? identityStore.load(ownerNamespace: ownerNamespace))?.deviceId
        do {
            let (results, ownHighest) = try ledgerStore.update(
                conversationId: conversationId, ownerScopeId: expectedOwnerScopeId
            ) { ledger -> ([E2EEV2MessageReceptionV2], Int?) in
                let results = opened.map { result -> E2EEV2MessageReceptionV2 in
                    let entry: Counted
                    switch result {
                    case .done(let reception): return reception
                    case .counted(let counted): entry = counted
                    }
                    switch ledger.record(
                        messageRef: entry.messageRef, deviceId: entry.deviceId, counter: entry.counter,
                        frankTagB64: entry.frankTagB64, epochNumber: entry.epochNumber
                    ) {
                    case .accepted:
                        if case .received(let message) = entry.outcome, let expiresAtMs = message.expiresAtMs,
                           expiresAtMs <= context.nowMs {
                            return .expired
                        }
                        return entry.outcome
                    case .duplicate: return .duplicate
                    case .replayed: return .replayed
                    case .equivocation(let refs): return .equivocation(refs)
                    }
                }
                // Rien n'est retenu pour un compte qui n'est plus le courant.
                guard session.isCurrent else { throw E2EEV2ConversationStateStore.Failure.otherAccount }
                try persist(
                    results.compactMap { if case .received(let message) = $0 { return message } else { return nil } },
                    results.flatMap { if case .equivocation(let refs) = $0 { return refs } else { return [] } }
                )
                return (results, ownDeviceId.flatMap { ledger.highestCounter(deviceId: $0) })
            }
            // Le compteur de cet appareil ne redescend jamais sous ce que la liste montre.
            if let ownDeviceId, let ownHighest {
                try? stateStore.raiseSendCounter(
                    conversationId: conversationId, deviceId: ownDeviceId, atLeast: ownHighest, ownerNamespace: ownerNamespace
                )
            }
            return results
        } catch {
            return messages.map { _ in .retryLater("e2ee-ledger-unavailable") }
        }
    }

    private struct Context {
        let conversationId: String
        let current: E2EEV2ConversationStateStore.CurrentEpoch
        let accepted: [E2EEV2ConversationStateStore.AcceptedEpoch]
        let latestMembers: Set<String>
        let departures: [String: Int64]
        let devices: E2EEV2CertifiedDeviceSet
        let ownerNamespace: String
        let nowMs: Int64
    }

    /// Un message authentique, qui entre au registre avec son issue.
    private struct Counted {
        let messageRef: String
        let deviceId: String
        let counter: Int
        let frankTagB64: String
        let epochNumber: Int
        let outcome: E2EEV2MessageReceptionV2
    }

    private enum Opened {
        case counted(Counted)
        case done(E2EEV2MessageReceptionV2)
    }

    private func open(_ message: E2EEV2DeliveredMessageV2, _ context: Context) -> Opened {
        let envelope = message.signed.envelope
        let epochNumber = envelope.epochNumber
        let current = context.current
        // 1. Appareil certifié, non révoqué, de l'utilisateur annoncé (§3.4) ;
        //    un annuaire en retard se relit.
        guard let senderKey = context.devices.signingKey(userId: message.senderUserId, deviceId: message.senderDeviceId) else {
            return .done(.retryLater("e2ee-sender-not-certified"))
        }
        // 2. Signature, avant tout accès à une clé : un message non signé
        //    n'oblige à rien, pas même à une synchronisation.
        let signatureContext = message.signed.context(
            conversationId: context.conversationId, senderDeviceId: message.senderDeviceId
        )
        do {
            try E2EEV2MessageCryptoV2.verifySignature(
                context: signatureContext, envelope: envelope, signatureDerB64: message.signed.senderSignatureB64,
                senderSigningKey: senderKey
            )
        } catch {
            return .done(.rejected("invalid-e2ee-message-signature"))
        }
        // 3. Époque connue : la courante, ou une remplacée depuis moins de 24 heures.
        guard epochNumber <= current.epochNumber else { return .done(.needsEpoch) }
        let members: [String]
        if epochNumber == current.epochNumber {
            members = current.memberIds
        } else {
            guard let epoch = context.accepted.first(where: { $0.epochNumber == epochNumber }),
                  let replacedAtMs = context.accepted.filter({ $0.epochNumber > epochNumber }).map(\.acceptedAtMs).min()
                    ?? (current.epochNumber > epochNumber ? current.acceptedAtMs : nil) else {
                return .done(.rejected("e2ee-epoch-unknown"))
            }
            guard context.nowMs - replacedAtMs <= Self.replacedEpochWindowMs else {
                return .done(.rejected("e2ee-epoch-replaced"))
            }
            members = epoch.memberIds
        }
        // 4. Membre de l'époque ; et, s'il est parti depuis, en vol depuis moins
        //    de 24 heures après que cet appareil l'a appris (§3.4, §5.3).
        guard members.contains(message.senderUserId) else { return .done(.rejected("e2ee-sender-not-member")) }
        if !context.latestMembers.contains(message.senderUserId) {
            guard let departedAtMs = context.departures[message.senderUserId],
                  context.nowMs - departedAtMs <= Self.replacedEpochWindowMs else {
                return .done(.rejected("e2ee-sender-departed"))
            }
        }
        // 5. Clé de l'époque : absente, c'est définitif ; coffre verrouillé, passager.
        var epoch: E2EEV2StoredEpochKey
        do {
            guard let stored = try keyStore.loadEpoch(
                conversationId: context.conversationId, epochNumber: epochNumber, ownerNamespace: context.ownerNamespace
            ) else { return .done(.rejected("e2ee-epoch-key-unavailable")) }
            epoch = stored
        } catch {
            return .done(.retryLater("e2ee-epoch-key-locked"))
        }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        // 6. Déchiffrement, bourrage, fk et frankTag : la charge exacte, authentique.
        let opened: (fk: Data, payloadBytes: Data)
        do {
            opened = try E2EEV2MessageCryptoV2.openFranked(envelope: envelope, epochKey: epoch.epochKey, context: signatureContext)
        } catch {
            return .done(.rejected("invalid-e2ee-message"))
        }
        let messageRef = E2EEV2MessageRef.make(
            conversationId: context.conversationId, senderDeviceId: message.senderDeviceId,
            clientRequestId: envelope.clientRequestId
        )
        func counted(_ outcome: E2EEV2MessageReceptionV2) -> Opened {
            .counted(Counted(
                messageRef: messageRef, deviceId: message.senderDeviceId, counter: Int(envelope.counter),
                frankTagB64: envelope.frankTagB64, epochNumber: epochNumber, outcome: outcome
            ))
        }
        // 7. Charge : un contenu inconnu mais authentique compte, sans être interprété.
        let payload: E2EEV2ContentPayloadV2
        do {
            payload = try E2EEV2ContentPayloadV2.parse(opened.payloadBytes)
        } catch {
            return E2EEV2ContentPayloadV2.isUnsupported(opened.payloadBytes)
                ? counted(.unsupported(messageRef: messageRef, senderUserId: message.senderUserId))
                : counted(.rejected("invalid-e2ee-payload"))
        }
        // Compteur de la charge égal à celui de l'AAD ; jalon A : aucun blob.
        guard payload.counter == envelope.counter, envelope.encryptedBlobIds.isEmpty else {
            return counted(.rejected("invalid-e2ee-payload"))
        }
        let ttlMs = Int64(envelope.ttlSeconds) * 1_000
        return counted(.received(E2EEV2ReceivedMessageV2(
            envelopeId: message.envelopeId, sequence: message.sequence, messageRef: messageRef,
            senderUserId: message.senderUserId, senderDeviceId: message.senderDeviceId,
            clientRequestId: envelope.clientRequestId, epochNumber: epochNumber, frankTagB64: envelope.frankTagB64,
            serverTagB64: message.serverTagB64, serverTimeMs: message.serverTimeMs, keyId: message.keyId,
            payload: payload, payloadBytes: opened.payloadBytes, fk: opened.fk,
            // Horloge signée de l'émetteur seule : le serveur ne peut ni
            // prolonger ni effacer en silence un message éphémère.
            expiresAtMs: ttlMs > 0 ? payload.sentAtMs + ttlMs : nil
        )))
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
