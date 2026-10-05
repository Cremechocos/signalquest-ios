import CryptoKit
import Foundation

/// §10.4 : ce qui rattache une preuve de jonction à l'appel en cours.
struct E2EEV2CallJoinContext: Equatable, Sendable {
    let conversationId: String
    let callId: String
    let callNonceB64: String
    /// Heure du descripteur : une jonction ne la précède pas (v0.4.25).
    var createdAtMs: Int64? = nil
}

/// Ce qu'il faut à un appel chiffré pour prouver ses participants : l'appel,
/// l'appareil local qui signe sa preuve, et les clés des appareils certifiés.
struct E2EEV2CallJoinConfiguration: Sendable {
    let context: E2EEV2CallJoinContext
    let userId: String
    let deviceId: String
    /// Signature DER, en forme low-S, de l'appareil local.
    let sign: @Sendable (Data) throws -> Data
    /// Clé de signature d'un appareil certifié d'un membre de la conversation,
    /// doté de la capacité « appels vérifiés » ; nil pour tout autre appareil.
    let deviceSigningKey: @Sendable (_ userId: String, _ deviceId: String) -> P256.Signing.PublicKey?
    var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
}

/// Preuves de jonction d'un appel chiffré (spec §10.4). Chaque participant
/// lie, par une signature de son appareil certifié, l'identité LiveKit sous
/// laquelle il a rejoint. Une preuve invalide met fin à l'appel ; un
/// participant sans preuve valide 10 secondes après son arrivée aussi.
final class E2EEV2CallJoinVerifier: @unchecked Sendable {
    static let deadline: TimeInterval = 10

    enum Outcome: Equatable {
        /// Première preuve valide de ce participant.
        case proven
        /// La même preuve, ou une preuve du même appareil, renvoyée.
        case confirmed
        /// L'appel prend fin.
        case rejected
    }

    private struct Device: Equatable {
        let userId: String
        let deviceId: String
    }

    /// Une preuve vérifiée : l'appareil et l'heure de jonction qu'il a signée.
    private struct Verified {
        let device: Device
        let joinedAtMs: Int64
    }

    /// Écart d'horloge toléré entre appareils pour l'heure de jonction (v0.4.25).
    static let joinClockSkewMs: Int64 = 10 * 60 * 1_000

    private let configuration: E2EEV2CallJoinConfiguration
    private let lock = NSLock()
    private var arrivals: [String: Date] = [:]
    private var devices: [String: Device] = [:]
    /// Participants dans la salle (annoncés ou attendus), pour l'attribution D.11.
    private var present: Set<String> = []
    /// Dernière heure de jonction prouvée de chaque identité, gardée après son
    /// départ : un retour signe une heure plus récente, selon sa propre
    /// horloge ; une preuve d'avant le départ, rejouée, est refusée (v0.4.25).
    private var lastJoinedAtMs: [String: Int64] = [:]
    /// Première arrivée de chaque identité pendant l'appel : partir puis revenir
    /// ne relance pas le délai de 10 secondes.
    private var firstArrivals: [String: Date] = [:]

    init(configuration: E2EEV2CallJoinConfiguration) {
        self.configuration = configuration
    }

    /// Preuve de l'appareil local, envoyée à la jonction puis à chaque
    /// nouvel arrivant, toujours avec la même heure de jonction. Le serveur doit
    /// avoir émis le jeton sous l'identité `<userId>.<deviceId>` de cet appareil.
    func localProof(livekitIdentity: String, joinedAtMs: Int64) throws -> Data {
        let context = configuration.context
        let proof = E2EEV2CallJoinProof(
            conversationId: context.conversationId,
            callId: context.callId,
            callNonceB64: context.callNonceB64,
            livekitIdentity: livekitIdentity,
            userId: configuration.userId,
            deviceId: configuration.deviceId,
            joinedAtMs: joinedAtMs
        )
        // Relue avant d'être signée : jamais de preuve que les autres refuseraient.
        guard (try? E2EEV2CallJoinProof.parse(proof.canonical)) == proof else {
            throw E2EEV2CallFormatError.invalidField
        }
        let signature = try configuration.sign(Data(proof.canonical.utf8))
        return E2EEV2CallJoinProof.message(E2EEV2SignedString(
            canonical: proof.canonical,
            signatureB64: signature.base64EncodedString()
        ))
    }

    /// Un participant distant est là : son délai de 10 secondes commence.
    func expect(_ identity: String, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        present.insert(identity)
        guard devices[identity] == nil, arrivals[identity] == nil else { return }
        let first = firstArrivals[identity] ?? now
        firstArrivals[identity] = first
        arrivals[identity] = first
    }

    /// Un participant est dans la salle, sans que son délai commence : de quoi
    /// lui attribuer une preuve dont le SDK n'a pas résolu l'émetteur.
    func announce(_ identity: String) {
        lock.lock()
        defer { lock.unlock() }
        present.insert(identity)
    }

    /// Preuve dont le SDK n'a pas résolu l'émetteur : le SDK Swift lit
    /// l'émetteur d'un paquet chiffré dans le paquet intérieur, que d'autres
    /// SDK ne remplissent pas (D.11). Elle est attribuée à l'identité qu'elle
    /// nomme, seulement si ce participant est dans la salle, puis vérifiée en
    /// entier, sous le même verrou. La signature atteste que l'appareil nommé
    /// a écrit cette preuve pour cet appel, pas que ce paquet vient de sa
    /// connexion : un rejeu ne prouve que son véritable auteur. `nil` : rien
    /// n'est conclu, le paquet est ignoré.
    func receiveUnattributed(_ message: Data) -> (identity: String, outcome: Outcome)? {
        guard let signed = try? E2EEV2CallJoinProof.readMessage(message),
              let identity = (try? E2EEV2CallJoinProof.parse(signed.canonical))?.livekitIdentity else { return nil }
        let verified = verifiedDevice(signed, from: identity)
        lock.lock()
        defer { lock.unlock() }
        guard present.contains(identity) || arrivals[identity] != nil || devices[identity] != nil else { return nil }
        guard let verified else { return (identity, .rejected) }
        return (identity, record(verified, for: identity))
    }

    func remove(_ identity: String) {
        lock.lock()
        defer { lock.unlock() }
        arrivals[identity] = nil
        devices[identity] = nil
        present.remove(identity)
    }

    /// Vérifie un message du sujet `sq.e2ee.join`, déjà déchiffré par le SDK.
    /// `senderIdentity` est l'identité LiveKit de l'émetteur du paquet.
    func receive(_ message: Data, from senderIdentity: String) -> Outcome {
        guard let signed = try? E2EEV2CallJoinProof.readMessage(message),
              let verified = verifiedDevice(signed, from: senderIdentity) else { return .rejected }
        lock.lock()
        defer { lock.unlock() }
        return record(verified, for: senderIdentity)
    }

    /// L'appareil certifié qui a signé cette preuve pour cet appel, sous cette identité.
    private func verifiedDevice(_ signed: E2EEV2SignedString, from senderIdentity: String) -> Verified? {
        let context = configuration.context
        guard let proof = try? E2EEV2CallJoinProof.parse(signed.canonical),
              proof.conversationId == context.conversationId,
              proof.callId == context.callId,
              proof.callNonceB64 == context.callNonceB64,
              proof.livekitIdentity == senderIdentity,
              // L'appareil local ne rejoint qu'une fois, sous sa propre identité.
              proof.deviceId != configuration.deviceId,
              let signingKey = configuration.deviceSigningKey(proof.userId, proof.deviceId),
              signed.verify(with: signingKey),
              // Heure de jonction plausible : pas avant le descripteur, pas dans
              // le futur, à l'écart d'horloge près (v0.4.25).
              proof.joinedAtMs >= (context.createdAtMs ?? 0) - Self.joinClockSkewMs,
              proof.joinedAtMs <= configuration.nowMs() + Self.joinClockSkewMs else {
            return nil
        }
        return Verified(device: Device(userId: proof.userId, deviceId: proof.deviceId), joinedAtMs: proof.joinedAtMs)
    }

    /// À appeler sous le verrou.
    private func record(_ verified: Verified, for senderIdentity: String) -> Outcome {
        let device = verified.device
        if let known = devices[senderIdentity] {
            // L'identité porte l'appareil : elle n'en change jamais.
            return known == device ? .confirmed : .rejected
        }
        // Après un départ, seule une jonction plus récente prouve un retour.
        if let previous = lastJoinedAtMs[senderIdentity], verified.joinedAtMs <= previous { return .rejected }
        lastJoinedAtMs[senderIdentity] = verified.joinedAtMs
        devices[senderIdentity] = device
        arrivals[senderIdentity] = nil
        return .proven
    }

    func isProven(_ identity: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices[identity] != nil
    }

    /// Utilisateur que la preuve de jonction de cette identité a prouvé.
    func provenUserId(_ identity: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return devices[identity]?.userId
    }

    /// Participants arrivés depuis au moins 10 secondes sans preuve valide.
    func overdue(at now: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
            .filter { now.timeIntervalSince($0.value) >= Self.deadline }
            .map(\.key)
            .sorted()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        arrivals.removeAll()
        devices.removeAll()
        present.removeAll()
        lastJoinedAtMs.removeAll()
        firstArrivals.removeAll()
    }
}
