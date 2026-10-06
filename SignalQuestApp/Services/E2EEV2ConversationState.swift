import CryptoKit
import Foundation

/// États collants d'une conversation v2 (spec §12) : « v2 » dérive du
/// manifeste signé de l'époque 1, mémorisé par l'appareil. Aucune réponse du
/// serveur ne le fait régresser, et un second manifeste d'époque 1 est refusé.
final class E2EEV2ConversationStateStore: @unchecked Sendable {
    static let keyPrefix = "conv-v2-v1"

    /// Ce que l'appareil a vérifié de l'époque 1 d'une conversation.
    struct Genesis: Codable, Equatable, Sendable {
        let conversationId: String
        let creatorUserId: String
        let creatorDeviceId: String
        /// `b64url(SHA-256(chaîne du manifeste de l'époque 1))`.
        let manifestDigest: String
        /// Fin de la genèse dans la chaîne d'appartenance.
        let membershipChangeNumber: Int
        /// Condensat du dernier changement de la genèse : à chaque relecture, la
        /// chaîne doit reproduire exactement cette genèse.
        let membershipDigest: String
        let recordedAtMs: Int64
    }

    /// Époque courante vérifiée (§3.3, §3.5) : de quoi décider d'une rotation
    /// et refuser un recul.
    struct CurrentEpoch: Codable, Equatable, Sendable {
        let conversationId: String
        let epochNumber: Int
        let membershipChangeNumber: Int
        let memberIds: [String]
        let recipientsDigest: String
        let excludesWeb: Bool
        let createdAtMs: Int64
        /// Heure locale de l'acceptation : l'âge d'une époque s'y mesure, pas à
        /// la date que son créateur a signée.
        let acceptedAtMs: Int64
        /// Identité et engagement de la clé de cette époque, épinglés ici,
        /// lisibles après le premier déverrouillage : une clé lue verrouillé dans
        /// le miroir des aperçus, que l'extension peut écrire, ne sert que si elle
        /// tient cet engagement (§2.6, v0.4.13). Absents des époques gardées avant.
        var epochId: String? = nil
        var keyCommitmentB64: String? = nil
    }

    /// Époque acceptée, gardée après son remplacement : membres de l'époque
    /// (§5.3) et fenêtre de 24 heures des messages en vol (§3.4).
    struct AcceptedEpoch: Codable, Equatable, Sendable {
        let epochNumber: Int
        let membershipChangeNumber: Int
        let memberIds: [String]
        let acceptedAtMs: Int64
    }

    /// Au-delà des 10 époques par heure du quota (§16), sur la fenêtre de 24 heures.
    static let acceptedEpochLimit = 256
    /// Accusés gardés après un envoi : un nouvel essai du même message les rend.
    static let sentReceiptLimit = 64
    /// Un envoi en attente plus vieux est abandonné, sa charge effacée.
    static let pendingSendMaxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1_000

    /// Dernier compteur d'envoi réservé par cet appareil (§4.3).
    struct SendCounter: Codable, Equatable, Sendable {
        let conversationId: String
        let deviceId: String
        let last: Int
    }

    /// Envoi en attente (E.3) : la charge exacte et son compteur, gardés avant le
    /// premier envoi et jusqu'à l'accusé. Un nouvel essai renvoie la même
    /// enveloppe, ou rechiffre la même charge sous l'époque courante.
    struct PendingSend: Codable, Equatable, Sendable {
        let conversationId: String
        let clientRequestId: String
        let deviceId: String
        let counter: Int
        let ttlSeconds: Int
        let payloadB64: String
        /// Gardée avec la charge : un rechiffrement garde le même `frankTag`.
        let fkB64: String
        let epochNumber: Int
        let createdAtMs: Int64
        /// Enveloppe signée, en JSON canonique, telle qu'envoyée.
        let wire: String
    }

    enum Failure: Error, Equatable {
        /// Un autre manifeste d'époque 1 a déjà été vérifié pour cette conversation.
        case genesisConflict
        /// Époque ou état d'appartenance antérieur à ce qui est déjà vérifié.
        case regressed
        case invalidRecord
        case otherAccount
        case counterExhausted
    }

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool
    private static let lock = NSLock()

    init(
        tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }
    ) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    /// Une conversation dont l'époque 1 a été vérifiée est v2 pour toujours.
    /// Un enregistrement illisible compte aussi : on ne régresse jamais.
    func isV2(conversationId: String, ownerNamespace: String) throws -> Bool {
        try tokenStore.string(for: key(conversationId: conversationId, ownerNamespace: ownerNamespace)) != nil
    }

    func genesis(conversationId: String, ownerNamespace: String) throws -> Genesis? {
        guard let raw = try tokenStore.string(for: key(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return nil }
        guard let data = raw.data(using: .utf8), let genesis = try? JSONDecoder().decode(Genesis.self, from: data),
              genesis.conversationId == conversationId else {
            throw Failure.invalidRecord
        }
        return genesis
    }

    /// Mémorise l'époque 1 vérifiée. La même : sans effet ; une autre : refusée.
    @discardableResult
    func record(_ genesis: Genesis, ownerNamespace: String) throws -> Genesis {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let known = try self.genesis(conversationId: genesis.conversationId, ownerNamespace: ownerNamespace) {
            guard known.manifestDigest == genesis.manifestDigest,
                  known.membershipChangeNumber == genesis.membershipChangeNumber else {
                throw Failure.genesisConflict
            }
            return known
        }
        let data = try JSONEncoder().encode(genesis)
        guard let value = String(data: data, encoding: .utf8) else { throw Failure.invalidRecord }
        try tokenStore.set(
            value, for: key(conversationId: genesis.conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
        return genesis
    }

    func currentEpoch(conversationId: String, ownerNamespace: String) throws -> CurrentEpoch? {
        guard let raw = try tokenStore.string(for: currentKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return nil }
        guard let data = raw.data(using: .utf8), let epoch = try? JSONDecoder().decode(CurrentEpoch.self, from: data),
              epoch.conversationId == conversationId else {
            throw Failure.invalidRecord
        }
        return epoch
    }

    /// N'avance que : numéro d'époque plus grand, état d'appartenance égal ou plus récent.
    func recordCurrentEpoch(_ epoch: CurrentEpoch, ownerNamespace: String) throws {
        try advanceCurrentEpoch(epoch, ownerNamespace: ownerNamespace) {}
    }

    /// Avance l'époque courante sous verrou : la règle « jamais en arrière » est
    /// vérifiée sur une lecture fraîche AVANT `beforeRecord` (la clé gardée),
    /// qui ne s'exécute donc jamais pour une époque qui recule.
    func advanceCurrentEpoch(
        _ epoch: CurrentEpoch,
        ownerNamespace: String,
        beforeRecord: () throws -> Void
    ) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let known = try currentEpoch(conversationId: epoch.conversationId, ownerNamespace: ownerNamespace) {
            guard epoch.epochNumber > known.epochNumber,
                  epoch.membershipChangeNumber >= known.membershipChangeNumber else {
                throw Failure.regressed
            }
        }
        try beforeRecord()
        let data = try JSONEncoder().encode(epoch)
        guard let value = String(data: data, encoding: .utf8) else { throw Failure.invalidRecord }
        let accepted = try acceptedEpochs(conversationId: epoch.conversationId, ownerNamespace: ownerNamespace)
            .filter { $0.epochNumber < epoch.epochNumber }
            + [AcceptedEpoch(
                epochNumber: epoch.epochNumber, membershipChangeNumber: epoch.membershipChangeNumber,
                memberIds: epoch.memberIds, acceptedAtMs: epoch.acceptedAtMs
            )]
        let history = try JSONEncoder().encode(Array(accepted.suffix(Self.acceptedEpochLimit)))
        try tokenStore.set(
            String(decoding: history, as: UTF8.self),
            for: acceptedKey(conversationId: epoch.conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
        try tokenStore.set(
            value, for: currentKey(conversationId: epoch.conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
    }

    /// Époques acceptées, les plus anciennes d'abord (64 au plus).
    func acceptedEpochs(conversationId: String, ownerNamespace: String) throws -> [AcceptedEpoch] {
        guard let raw = try tokenStore.string(for: acceptedKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return [] }
        guard let data = raw.data(using: .utf8), let epochs = try? JSONDecoder().decode([AcceptedEpoch].self, from: data)
        else { throw Failure.invalidRecord }
        return epochs
    }

    /// Réinitialisation d'identité : les clés d'époque partent avec l'ancienne
    /// identité, les époques courantes aussi, et ses envois en attente
    /// (messages et changement d'appartenance) ;
    /// genèses et chaînes restent. La nouvelle identité compte depuis 1.
    func removeCurrentEpochs(ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for key in try tokenStore.keys(withPrefix: Self.prefix(ownerNamespace: ownerNamespace))
        where key.hasSuffix(":current") || key.hasSuffix(":accepted") || key.hasSuffix(":counter") || key.contains(":send:")
            || key.hasSuffix(":sent") || key.hasSuffix(":membership-pending")
            // Genèses et créations en attente, signées par l'identité remplacée.
            || key.hasSuffix(":pending") {
            try tokenStore.remove(key)
        }
    }

    /// Réserve le compteur du prochain message de cet appareil (§4.3) : avant
    /// de composer, jamais rendu ni réutilisé pour un autre message.
    func reserveSendCounter(conversationId: String, deviceId: String, ownerNamespace: String) throws -> Int {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let key = counterKey(conversationId: conversationId, ownerNamespace: ownerNamespace)
        var last = 0
        if let raw = try tokenStore.string(for: key) {
            guard let data = raw.data(using: .utf8), let known = try? JSONDecoder().decode(SendCounter.self, from: data),
                  known.conversationId == conversationId else {
                throw Failure.invalidRecord
            }
            if known.deviceId == deviceId { last = known.last }
        }
        guard last < E2EEV2Canonical.maxSequenceNumber else { throw Failure.counterExhausted }
        let data = try JSONEncoder().encode(SendCounter(conversationId: conversationId, deviceId: deviceId, last: last + 1))
        try tokenStore.set(String(decoding: data, as: UTF8.self), for: key, accessibility: .afterFirstUnlock)
        return last + 1
    }

    /// Relève le compteur au plus haut compteur de cet appareil vu dans la
    /// liste (E.3) : une sauvegarde restaurée ne le fait pas reculer.
    func raiseSendCounter(conversationId: String, deviceId: String, atLeast floor: Int, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard (1...E2EEV2Canonical.maxSequenceNumber).contains(floor) else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let key = counterKey(conversationId: conversationId, ownerNamespace: ownerNamespace)
        if let raw = try tokenStore.string(for: key),
           let known = raw.data(using: .utf8).flatMap({ try? JSONDecoder().decode(SendCounter.self, from: $0) }),
           known.conversationId == conversationId, known.deviceId == deviceId, known.last >= floor {
            return
        }
        let data = try JSONEncoder().encode(SendCounter(conversationId: conversationId, deviceId: deviceId, last: floor))
        try tokenStore.set(String(decoding: data, as: UTF8.self), for: key, accessibility: .afterFirstUnlock)
    }

    func pendingSend(conversationId: String, clientRequestId: String, ownerNamespace: String) throws -> PendingSend? {
        guard let raw = try tokenStore.string(
            for: sendKey(conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace)
        ) else { return nil }
        guard let data = raw.data(using: .utf8), let pending = try? JSONDecoder().decode(PendingSend.self, from: data),
              pending.conversationId == conversationId, pending.clientRequestId == clientRequestId else {
            throw Failure.invalidRecord
        }
        return pending
    }

    /// La charge est en clair : réservée à l'appareil déverrouillé.
    func savePendingSend(_ pending: PendingSend, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        let data = try JSONEncoder().encode(pending)
        try tokenStore.set(
            String(decoding: data, as: UTF8.self),
            for: sendKey(conversationId: pending.conversationId, clientRequestId: pending.clientRequestId, ownerNamespace: ownerNamespace),
            accessibility: .whenUnlocked
        )
    }

    func clearPendingSend(conversationId: String, clientRequestId: String, ownerNamespace: String) throws {
        try tokenStore.remove(sendKey(conversationId: conversationId, clientRequestId: clientRequestId, ownerNamespace: ownerNamespace))
    }

    /// Migration en cours (§14.2) : le corps signé une fois est renvoyé tel quel,
    /// jamais une seconde genèse pour la même conversation.
    func pendingGenesis(conversationId: String, ownerNamespace: String) throws -> String? {
        try tokenStore.string(for: pendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
    }

    func savePendingGenesis(_ body: String, conversationId: String, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        try tokenStore.set(
            body, for: pendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
    }

    func clearPendingGenesis(conversationId: String, ownerNamespace: String) throws {
        try tokenStore.remove(pendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
    }

    /// Création v2 envoyée sans reçu (E.2) : le corps exact, sous l'empreinte
    /// de la demande, pour qu'une reprise renvoie le même identifiant et les
    /// mêmes octets, que le serveur accepte comme un rejeu.
    struct PendingCreation: Codable, Equatable {
        let body: String
        let pendingUserIds: [String]
        let savedAtMs: Int64
    }

    func pendingCreation(request: String, ownerNamespace: String) throws -> PendingCreation? {
        guard let raw = try tokenStore.string(for: pendingKey(conversationId: "creation:" + request, ownerNamespace: ownerNamespace))
        else { return nil }
        return try? JSONDecoder().decode(PendingCreation.self, from: Data(raw.utf8))
    }

    func savePendingCreation(_ pending: PendingCreation, request: String, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        try tokenStore.set(
            String(decoding: try JSONEncoder().encode(pending), as: UTF8.self),
            for: pendingKey(conversationId: "creation:" + request, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
    }

    func clearPendingCreation(request: String, ownerNamespace: String) throws {
        try tokenStore.remove(pendingKey(conversationId: "creation:" + request, ownerNamespace: ownerNamespace))
    }

    /// Accusé d'un message déjà remis (E.3), gardé pour les derniers envois.
    func sentReceipt(conversationId: String, clientRequestId: String, ownerNamespace: String) throws -> E2EEV2MessageReceiptV2? {
        try sentReceipts(conversationId: conversationId, ownerNamespace: ownerNamespace).first { $0.clientRequestId == clientRequestId }
    }

    /// Remplace l'envoi en attente par son accusé, sous verrou.
    func completeSend(_ receipt: E2EEV2MessageReceiptV2, conversationId: String, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var receipts = try sentReceipts(conversationId: conversationId, ownerNamespace: ownerNamespace)
            .filter { $0.clientRequestId != receipt.clientRequestId }
        receipts.append(receipt)
        let data = try JSONEncoder().encode(Array(receipts.suffix(Self.sentReceiptLimit)))
        try tokenStore.set(
            String(decoding: data, as: UTF8.self), for: sentKey(conversationId: conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
        try tokenStore.remove(sendKey(conversationId: conversationId, clientRequestId: receipt.clientRequestId, ownerNamespace: ownerNamespace))
    }

    private func sentReceipts(conversationId: String, ownerNamespace: String) throws -> [E2EEV2MessageReceiptV2] {
        guard let raw = try tokenStore.string(for: sentKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return [] }
        guard let data = raw.data(using: .utf8), let receipts = try? JSONDecoder().decode([E2EEV2MessageReceiptV2].self, from: data)
        else { throw Failure.invalidRecord }
        return receipts
    }

    /// Membres partis (retrait ou départ), à l'heure locale où cet appareil l'a
    /// appris : leurs messages en vol restent acceptés 24 heures (§3.4).
    func departures(conversationId: String, ownerNamespace: String) throws -> [String: Int64] {
        guard let raw = try tokenStore.string(for: departuresKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return [:] }
        guard let data = raw.data(using: .utf8), let departures = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { throw Failure.invalidRecord }
        return departures
    }

    /// Changement d'appartenance signé, gardé avant son envoi et renvoyé tel
    /// quel jusqu'à sa réponse (E.2) : jamais deux signatures pour un numéro.
    func pendingMembership(conversationId: String, ownerNamespace: String) throws -> E2EEV2SignedString? {
        guard let raw = try tokenStore.string(for: membershipPendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return nil }
        guard let value = try? E2EEV2CanonicalJSON.parseCanonical(raw), let signed = E2EEV2MembershipChange.signed(from: value)
        else { throw Failure.invalidRecord }
        return signed
    }

    func savePendingMembership(_ signed: E2EEV2SignedString, conversationId: String, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        try tokenStore.set(
            E2EEV2CanonicalJSON.encodeString(E2EEV2MembershipChange.json(signed)),
            for: membershipPendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
    }

    func clearPendingMembership(conversationId: String, ownerNamespace: String) throws {
        try tokenStore.remove(membershipPendingKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
    }

    /// Chaîne d'appartenance signée, telle que relue : rejouée pour vérifier une
    /// époque fondée sur un état plus ancien que la tête (§3.5).
    func membershipChain(conversationId: String, ownerNamespace: String) throws -> [E2EEV2SignedString] {
        guard let raw = try tokenStore.string(for: chainKey(conversationId: conversationId, ownerNamespace: ownerNamespace))
        else { return [] }
        guard let data = raw.data(using: .utf8),
              let items = (try? E2EEV2CanonicalJSON.parseCanonical(String(decoding: data, as: UTF8.self)))?.arrayValue else {
            throw Failure.invalidRecord
        }
        let chain = items.compactMap(E2EEV2MembershipChange.signed(from:))
        guard chain.count == items.count else { throw Failure.invalidRecord }
        return chain
    }

    /// Ajout seul : la suite doit prolonger la chaîne gardée, déjà vérifiée. Les
    /// départs qu'elle porte sont datés de `nowMs`, l'heure locale (§3.4).
    func appendMembership(
        _ changes: [E2EEV2SignedString],
        conversationId: String,
        ownerNamespace: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard !changes.isEmpty else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let known = try membershipChain(conversationId: conversationId, ownerNamespace: ownerNamespace)
        var previous = known.last?.canonical
        var departures = try self.departures(conversationId: conversationId, ownerNamespace: ownerNamespace)
        for change in changes {
            guard let parsed = try? E2EEV2MembershipChange.parse(change.canonical, previousCanonical: previous),
                  parsed.conversationId == conversationId else { throw Failure.regressed }
            switch parsed.action {
            case "REMOVE", "LEAVE": departures[parsed.targetUserId] = nowMs
            case "ADD": departures[parsed.targetUserId] = nil
            default: break
            }
            previous = change.canonical
        }
        let departed = try JSONEncoder().encode(departures)
        try tokenStore.set(
            String(decoding: departed, as: UTF8.self),
            for: departuresKey(conversationId: conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
        let value = E2EEV2CanonicalJSON.encodeString(.array((known + changes).map(E2EEV2MembershipChange.json)))
        try tokenStore.set(
            value, for: chainKey(conversationId: conversationId, ownerNamespace: ownerNamespace),
            accessibility: .afterFirstUnlock
        )
    }

    static func prefix(ownerNamespace: String) -> String {
        "\(keyPrefix):\(ownerNamespace):"
    }

    private func chainKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":chain"
    }

    private func pendingKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":pending"
    }

    private func acceptedKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":accepted"
    }

    private func sentKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":sent"
    }

    private func departuresKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":departures"
    }

    private func membershipPendingKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":membership-pending"
    }

    private func counterKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":counter"
    }

    private func sendKey(conversationId: String, clientRequestId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":send:"
            + SHA256.hash(data: Data(clientRequestId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func key(conversationId: String, ownerNamespace: String) -> String {
        Self.prefix(ownerNamespace: ownerNamespace)
            + SHA256.hash(data: Data(conversationId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Même préfixe que la genèse : effacé avec le compte.
    private func currentKey(conversationId: String, ownerNamespace: String) -> String {
        key(conversationId: conversationId, ownerNamespace: ownerNamespace) + ":current"
    }
}

/// Clé d'époque telle que l'envoi et les appels doivent la prendre (§3.5, §12).
/// Pour une conversation v2 : celle de l'époque courante vérifiée, lue par son
/// numéro, jamais le pointeur courant du coffre, que d'anciens chemins
/// (livraison, rotation pilotée par le serveur, récupération) peuvent déplacer.
/// Un état illisible lève une erreur : aucune clé.
enum E2EEV2VerifiedEpochKeys {
    static func current(
        conversationId: String,
        ownerNamespace: String,
        keyStore: E2EEV2EpochKeyStore,
        stateStore: E2EEV2ConversationStateStore
    ) throws -> E2EEV2StoredEpochKey? {
        if try stateStore.isV2(conversationId: conversationId, ownerNamespace: ownerNamespace) {
            guard let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace)
            else { return nil }
            return pinned(try keyStore.loadEpoch(
                conversationId: conversationId, epochNumber: current.epochNumber, ownerNamespace: ownerNamespace,
                includeRestored: false
            ), to: current)
        }
        return try keyStore.load(conversationId: conversationId, ownerNamespace: ownerNamespace)
    }

    /// La clé rangée ne sert que si elle tient l'engagement épinglé à l'époque
    /// vérifiée : une clé d'une autre source au même numéro n'est jamais utilisée.
    private static func pinned(
        _ stored: E2EEV2StoredEpochKey?,
        to current: E2EEV2ConversationStateStore.CurrentEpoch
    ) -> E2EEV2StoredEpochKey? {
        guard let stored else { return nil }
        if let commitment = current.keyCommitmentB64, stored.keyCommitmentB64 != commitment { return nil }
        return stored
    }

    /// Une époque désignée (réponse à un appel) : pour une conversation v2,
    /// seulement l'époque courante vérifiée.
    static func exact(
        conversationId: String,
        epochNumber: Int,
        ownerNamespace: String,
        keyStore: E2EEV2EpochKeyStore,
        stateStore: E2EEV2ConversationStateStore
    ) throws -> E2EEV2StoredEpochKey? {
        if try stateStore.isV2(conversationId: conversationId, ownerNamespace: ownerNamespace) {
            guard let current = try stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace),
                  current.epochNumber == epochNumber else { return nil }
            return pinned(
                try keyStore.loadEpoch(
                    conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace, includeRestored: false
                ),
                to: current
            )
        }
        return try keyStore.loadEpoch(conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace)
    }

    /// La même époque, appareil verrouillé (spec §2.6, v0.4.13). La clé vient
    /// du miroir des aperçus, que l'extension de notification peut écrire : elle
    /// ne sert que si elle tient l'engagement épinglé dans l'état de l'app, pour
    /// l'époque courante vérifiée, avec l'aperçu complet choisi sur l'appareil
    /// et un miroir de ce compte et de cette session. Sinon nil : l'appel attend
    /// le déverrouillage.
    static func exactWhileLocked(
        conversationId: String,
        epochNumber: Int,
        session: LocalAccountSession,
        stateStore: E2EEV2ConversationStateStore,
        contextStore: E2EEV2NotificationContextStore?,
        privacy: (String) -> E2EEV2NotificationPrivacy = { E2EEV2NotificationPrivacyStore.get(ownerScopeId: $0) },
        now: Date = Date()
    ) -> E2EEV2StoredEpochKey? {
        let ownerNamespace = session.ownerNamespace
        guard let contextStore, session.ownerScopeId.hasPrefix("user:") else { return nil }
        let pushOwnerScopeId = PushOwnerScope.id(for: String(session.ownerScopeId.dropFirst("user:".count)))
        guard privacy(pushOwnerScopeId) == .full,
              (try? stateStore.isV2(conversationId: conversationId, ownerNamespace: ownerNamespace)) == true,
              let current = try? stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: ownerNamespace),
              current.epochNumber == epochNumber,
              let epochId = current.epochId, let commitment = current.keyCommitmentB64,
              let context = try? contextStore.load(now: now), context.privacy == .full,
              context.ownerScopeId == pushOwnerScopeId, context.sessionId == session.sessionId,
              let entry = try? contextStore.conversation(conversationId, now: now),
              let epoch = entry.epochs.first(where: { $0.replacedAtMs == nil }), epoch.epochNumber == epochNumber,
              let keyB64 = epoch.keyB64, var key = Data(base64Encoded: keyB64) else { return nil }
        guard (try? E2EEV2EpochCrypto.keyCommitment(key)) == commitment else {
            key.resetBytes(in: 0..<key.count)
            return nil
        }
        return .init(
            conversationId: conversationId, epochId: epochId, epochNumber: epochNumber,
            keyCommitmentB64: commitment, epochKey: key
        )
    }

    /// Les anciens chemins pilotés par le serveur ne touchent jamais une
    /// conversation v2 ; un état illisible vaut v2.
    static func allowsLegacyEpochPath(
        conversationId: String,
        ownerNamespace: String,
        stateStore: E2EEV2ConversationStateStore
    ) -> Bool {
        (try? stateStore.isV2(conversationId: conversationId, ownerNamespace: ownerNamespace)) == false
    }
}
