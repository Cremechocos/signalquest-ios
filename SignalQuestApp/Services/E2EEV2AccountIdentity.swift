import CryptoKit
import Foundation

/// §2.1 : la clé d'identité de compte (UIK). Créée sur le premier appareil,
/// transmise chiffrée aux appareils approuvés (D.1), gardée seulement par les
/// appareils certifiés du compte. C'est une clé logicielle, puisqu'elle
/// circule : au repos, le trousseau la chiffre par la clé matérielle de
/// l'appareil (classe `WhenUnlockedThisDeviceOnly`, jamais synchronisée), comme
/// les clés d'appareil, dans le coffre E2EE du compte.
final class E2EEV2AccountIdentityStore: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case alreadyExists
        case invalidRecord
        case otherAccount
    }

    static func key(ownerNamespace: String) -> String { "uik-v1:\(ownerNamespace)" }
    /// §2.3 : la clé du compte a été vérifiée sur cet appareil.
    static func verifiedKey(ownerNamespace: String) -> String { "uik-verified-v1:\(ownerNamespace)" }
    /// Bootstrap en cours : l'heure des textes signés, tant que le serveur n'a pas répondu.
    static func pendingBootstrapKey(ownerNamespace: String) -> String { "uik-bootstrap-v1:\(ownerNamespace)" }
    /// Demande d'approbation par QR de cet appareil, tant que l'UIK n'est pas reçue.
    static func pendingApprovalKey(ownerNamespace: String) -> String { "uik-approval-v1:\(ownerNamespace)" }
    /// Réinitialisation demandée ici (lot A2) : la nouvelle UIK, l'heure du
    /// document signé et, une fois reçus, son identifiant et son échéance.
    static func pendingResetKey(ownerNamespace: String) -> String { "uik-reset-v1:\(ownerNamespace)" }

    struct PendingReset: Codable, Equatable, Sendable {
        let uikRawB64: String
        let requestedAtMs: Int64
        var resetId: String?
        var effectiveAtMs: Int64?
        var replacementDeviceId: String?

        var uik: P256.Signing.PrivateKey? {
            Data(base64Encoded: uikRawB64).flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) }
        }
    }
    /// Deux bootstraps simultanés ne créent qu'une UIK et une heure.
    private static let bootstrapLock = NSLock()

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    func load(ownerNamespace: String) throws -> P256.Signing.PrivateKey? {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard let raw = try tokenStore.string(for: Self.key(ownerNamespace: ownerNamespace)) else { return nil }
        guard let data = Data(base64Encoded: raw),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw Failure.invalidRecord
        }
        return key
    }

    /// La réinitialisation en attente, créée au premier appel : une reprise
    /// renvoie la même UIK et la même heure, donc les mêmes textes signés.
    func pendingReset(ownerNamespace: String, nowMs: Int64) throws -> PendingReset {
        try Self.bootstrapLock.withLock {
            if let existing = try loadPendingReset(ownerNamespace: ownerNamespace) { return existing }
            let created = PendingReset(
                uikRawB64: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(), requestedAtMs: nowMs
            )
            try savePendingReset(created, ownerNamespace: ownerNamespace)
            return created
        }
    }

    func loadPendingReset(ownerNamespace: String) throws -> PendingReset? {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard let raw = try tokenStore.string(for: Self.pendingResetKey(ownerNamespace: ownerNamespace)) else { return nil }
        guard let value = try? JSONDecoder().decode(PendingReset.self, from: Data(raw.utf8)), value.uik != nil else {
            throw Failure.invalidRecord
        }
        return value
    }

    func savePendingReset(_ value: PendingReset, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try tokenStore.set(raw, for: Self.pendingResetKey(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
    }

    func discardPendingReset(ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        try tokenStore.remove(Self.pendingResetKey(ownerNamespace: ownerNamespace))
    }

    /// Bascule faite par le serveur : la nouvelle UIK remplace l'ancienne,
    /// vérifiée puisqu'elle a été créée ici. Rejouable.
    func completePendingReset(ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard let pending = try loadPendingReset(ownerNamespace: ownerNamespace) else { return }
        try tokenStore.set(pending.uikRawB64, for: Self.key(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
        try tokenStore.set("1", for: Self.verifiedKey(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
        try tokenStore.remove(Self.pendingResetKey(ownerNamespace: ownerNamespace))
    }

    /// Premier appareil du compte : une nouvelle UIK, jamais par-dessus une autre.
    /// Il l'a créée lui-même : elle est vérifiée d'office.
    func create(ownerNamespace: String) throws -> P256.Signing.PrivateKey {
        guard try load(ownerNamespace: ownerNamespace) == nil else { throw Failure.alreadyExists }
        let key = P256.Signing.PrivateKey()
        try install(key, ownerNamespace: ownerNamespace)
        try tokenStore.set("1", for: Self.verifiedKey(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
        return key
    }

    func hasPendingBootstrap(ownerNamespace: String) throws -> Bool {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        return try tokenStore.string(for: Self.pendingBootstrapKey(ownerNamespace: ownerNamespace)) != nil
    }

    /// §2.3 : un appareil approuvé reçoit l'UIK sans pouvoir la comparer seul. Elle
    /// reste « clé du compte non vérifiée » jusqu'à ce que l'utilisateur compare les
    /// 30 chiffres du compte (D.12) avec un autre de ses appareils.
    func isVerified(ownerNamespace: String) throws -> Bool {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        return try tokenStore.string(for: Self.verifiedKey(ownerNamespace: ownerNamespace)) == "1"
    }

    func markVerified(ownerNamespace: String) throws {
        guard try load(ownerNamespace: ownerNamespace) != nil else { throw Failure.invalidRecord }
        try tokenStore.set("1", for: Self.verifiedKey(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
    }

    /// Appareil approuvé : l'UIK reçue chiffrée à l'approbation (D.1). Jamais
    /// par-dessus une autre : seule une réinitialisation d'identité change l'UIK.
    func install(_ key: P256.Signing.PrivateKey, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        if let existing = try load(ownerNamespace: ownerNamespace) {
            guard existing.rawRepresentation == key.rawRepresentation else { throw Failure.alreadyExists }
            return
        }
        // Une clé reçue n'est jamais vérifiée d'avance, même si un drapeau a
        // survécu à une purge interrompue.
        try tokenStore.remove(Self.verifiedKey(ownerNamespace: ownerNamespace))
        try tokenStore.set(
            key.rawRepresentation.base64EncodedString(),
            for: Self.key(ownerNamespace: ownerNamespace),
            accessibility: .whenUnlocked
        )
    }
}

/// §12 : le dernier document de capacités de cet appareil, gardé avant l'envoi
/// pour qu'une reprise renvoie le même, et sa date de publication. Republié à
/// chaque nouveau build et au moins tous les 30 jours.
final class E2EEV2CapabilitiesPublicationStore: @unchecked Sendable {
    struct State: Codable, Equatable {
        let deviceId: String
        let sequence: Int
        let document: String
        let signatureB64: String
        let appBuild: String
        /// Absente : envoi en cours, sans réponse du serveur.
        var publishedAtMs: Int64?
    }

    /// Ce qu'iOS sait lire en v2 : texte, modification, suppression ; « appels
    /// vérifiés » seulement quand le verrou d'appels est ouvert (§10.0), les
    /// médias chiffrés au jalon B. Les réactions (D.16) s'annoncent ensemble,
    /// enveloppe v3, `REACTION` et `reactions`, derrière leur verrou et la
    /// porte du serveur : le document est republié quand elle s'ouvre.
    static var announcesReactions: Bool { SQFeatures.e2eeReactionsEnabled && E2EEV2ServerGate.reactionsOpen }
    static var envelopeVersions: [String] { announcesReactions ? ["2", "3"] : ["2"] }
    static var kinds: [String] {
        announcesReactions ? ["DELETE", "EDIT", "REACTION", "TEXT"] : ["DELETE", "EDIT", "TEXT"]
    }
    static var features: [String] {
        var features: [String] = []
        #if DEBUG
        if announcesCallsForLocalQA { features = ["calls"] }
        #endif
        if features.isEmpty, E2EEV2CallRuntimeGate.allowsControlPlane() { features = ["calls"] }
        if announcesReactions { features.append("reactions") }
        return features
    }
    #if DEBUG
    /// Essai d'appel local (tests, pile en boucle locale) : « appels » annoncé
    /// sans ouvrir le verrou global. N'existe pas en Release.
    nonisolated(unsafe) static var announcesCallsForLocalQA = false
    #endif
    static let republishAfterMs: Int64 = 30 * 86_400_000

    static func key(ownerNamespace: String) -> String { "capabilities-v1:\(ownerNamespace)" }

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    func load(ownerNamespace: String) throws -> State? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2AccountIdentityStore.Failure.otherAccount }
        guard let raw = try tokenStore.string(for: Self.key(ownerNamespace: ownerNamespace)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: Data(raw.utf8))
    }

    func save(_ state: State, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2AccountIdentityStore.Failure.otherAccount }
        let value = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try tokenStore.set(value, for: Self.key(ownerNamespace: ownerNamespace), accessibility: .whenUnlocked)
    }

    func remove(ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2AccountIdentityStore.Failure.otherAccount }
        try tokenStore.remove(Self.key(ownerNamespace: ownerNamespace))
    }

    /// Écart toléré entre l'horloge d'ici et `issuedAtMs` d'un document en attente.
    static let pendingSkewMs = E2EEV2IdentityVerification.capabilityFutureSkewMs
    /// Avance maximale acceptée d'une séquence annoncée par le serveur
    /// (`currentSequence`) : au-delà, elle n'est pas crue.
    static let maxServerSequenceLead = 1_000

    /// À publier : rien encore, un autre appareil, un autre build, une autre
    /// liste, ou 30 jours passés depuis son émission (horloge qui recule
    /// comprise).
    static func isCurrent(_ state: State, deviceId: String, appBuild: String, nowMs: Int64) -> Bool {
        guard state.deviceId == deviceId, state.appBuild == appBuild, state.publishedAtMs != nil,
              let document = try? E2EEV2CapabilitiesDocument.parse(document: state.document),
              (0..<republishAfterMs).contains(nowMs - document.issuedAtMs) else { return false }
        return document.envelopeVersions == envelopeVersions && document.kinds == kinds && document.features == features
    }

    /// Un document envoyé sans réponse ne repart tel quel que s'il est récent.
    static func isReplayable(_ state: State, deviceId: String, appBuild: String, nowMs: Int64) -> Bool {
        guard state.publishedAtMs == nil, state.deviceId == deviceId, state.appBuild == appBuild,
              let document = try? E2EEV2CapabilitiesDocument.parse(document: state.document) else { return false }
        return abs(nowMs - document.issuedAtMs) <= pendingSkewMs
    }
}
