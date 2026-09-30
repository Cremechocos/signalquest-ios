import CryptoKit
import Foundation

/// §10.4 : ce qui rattache une preuve de jonction à l'appel en cours.
struct E2EEV2CallJoinContext: Equatable, Sendable {
    let conversationId: String
    let callId: String
    let callNonceB64: String
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

    private let configuration: E2EEV2CallJoinConfiguration
    private let lock = NSLock()
    private var arrivals: [String: Date] = [:]
    private var devices: [String: Device] = [:]

    init(configuration: E2EEV2CallJoinConfiguration) {
        self.configuration = configuration
    }

    /// Preuve de l'appareil local, envoyée à la jonction puis à chaque
    /// nouvel arrivant, toujours avec la même heure de jonction.
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
        guard devices[identity] == nil, arrivals[identity] == nil else { return }
        arrivals[identity] = now
    }

    func remove(_ identity: String) {
        lock.lock()
        defer { lock.unlock() }
        arrivals[identity] = nil
        devices[identity] = nil
    }

    /// Vérifie un message du sujet `sq.e2ee.join`, déjà déchiffré par le SDK.
    /// `senderIdentity` est l'identité LiveKit de l'émetteur du paquet.
    func receive(_ message: Data, from senderIdentity: String) -> Outcome {
        let context = configuration.context
        guard let signed = try? E2EEV2CallJoinProof.readMessage(message),
              let proof = try? E2EEV2CallJoinProof.parse(signed.canonical),
              proof.conversationId == context.conversationId,
              proof.callId == context.callId,
              proof.callNonceB64 == context.callNonceB64,
              proof.livekitIdentity == senderIdentity,
              // L'appareil local ne rejoint qu'une fois, sous sa propre identité.
              proof.deviceId != configuration.deviceId,
              let signingKey = configuration.deviceSigningKey(proof.userId, proof.deviceId),
              signed.verify(with: signingKey) else {
            return .rejected
        }
        let device = Device(userId: proof.userId, deviceId: proof.deviceId)
        lock.lock()
        defer { lock.unlock() }
        if let known = devices[senderIdentity] {
            // Une identité ne change jamais d'appareil en cours d'appel.
            return known == device ? .confirmed : .rejected
        }
        devices[senderIdentity] = device
        arrivals[senderIdentity] = nil
        return .proven
    }

    func isProven(_ identity: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices[identity] != nil
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
    }
}
