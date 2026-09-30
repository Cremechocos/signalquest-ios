import CryptoKit
import Foundation
import Security

/// D.11 : clé JSON `e2eeV2` d'un appel chiffré, relayée telle quelle par le
/// serveur dans la réponse d'initiation, la notification VoIP et `pending`.
struct E2EEV2SignedCallDescriptor: Equatable, Sendable {
    let signed: E2EEV2SignedString
    let callerDeviceId: String
    let descriptor: E2EEV2CallDescriptor

    private static let keys: Set<String> = ["descriptor", "signatureB64", "callerDeviceId"]

    /// Lecture stricte : exactement trois clés, un descripteur bien formé, et
    /// l'appareil appelant que le descripteur signe lui-même.
    static func parse(_ value: JSONValue) -> E2EEV2SignedCallDescriptor? {
        guard case .object(let object) = value, Set(object.keys) == keys,
              case .string(let canonical)? = object["descriptor"],
              case .string(let signatureB64)? = object["signatureB64"],
              case .string(let callerDeviceId)? = object["callerDeviceId"],
              let signature = Data(base64Encoded: signatureB64), !signature.isEmpty,
              let descriptor = try? E2EEV2CallDescriptor.parse(canonical),
              descriptor.callerDeviceId == callerDeviceId else { return nil }
        return E2EEV2SignedCallDescriptor(
            signed: E2EEV2SignedString(canonical: canonical, signatureB64: signatureB64),
            callerDeviceId: callerDeviceId,
            descriptor: descriptor
        )
    }

    /// Valeur de `e2eeV2` dans le corps de l'initiation (annexe E.4).
    var jsonValue: JSONValue {
        .object([
            "descriptor": .string(signed.canonical),
            "signatureB64": .string(signed.signatureB64),
            "callerDeviceId": .string(callerDeviceId),
        ])
    }
}

/// L'appelant choisit l'identifiant de l'appel et signe son descripteur avec
/// son appareil (§10.1) : le descripteur part dès l'initiation.
enum E2EEV2CallDescriptorFactory {
    /// 128 bits aléatoires au format opaque (annexe A.1).
    static func newCallId() throws -> String {
        "call_" + base64URL(try randomBytes(16))
    }

    /// 32 octets aléatoires, en base64 standard (D.11).
    static func newCallNonceB64() throws -> String {
        try randomBytes(32).base64EncodedString()
    }

    static func make(
        conversationId: String,
        callId: String,
        callerDeviceId: String,
        epochId: String,
        epochNumber: Int,
        keyCommitmentB64: String,
        callNonceB64: String,
        createdAtMs: Int64,
        sign: (Data) throws -> Data
    ) throws -> E2EEV2SignedCallDescriptor {
        let descriptor = E2EEV2CallDescriptor(
            conversationId: conversationId,
            callId: callId,
            callerDeviceId: callerDeviceId,
            epochId: epochId,
            epochNumber: epochNumber,
            keyCommitmentB64: keyCommitmentB64,
            callNonceB64: callNonceB64,
            createdAtMs: createdAtMs
        )
        // Relu avant d'être signé : jamais un descripteur que l'appelé refuserait.
        guard (try? E2EEV2CallDescriptor.parse(descriptor.canonical)) == descriptor else {
            throw E2EEV2CallFormatError.invalidField
        }
        let signature = try sign(Data(descriptor.canonical.utf8))
        return E2EEV2SignedCallDescriptor(
            signed: E2EEV2SignedString(canonical: descriptor.canonical, signatureB64: signature.base64EncodedString()),
            callerDeviceId: callerDeviceId,
            descriptor: descriptor
        )
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw E2EEV2CallFormatError.invalidField
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Vérifications de l'appelé (§10.1), avant de faire sonner ou de rejoindre.
enum E2EEV2CallDescriptorCheck {
    enum Failure: Error, Equatable {
        /// Autre conversation ou autre appel que celui annoncé.
        case otherCall
        /// Appareil appelant absent des appareils certifiés des membres.
        case untrustedCaller
        case invalidSignature
        /// Sonnerie annoncée plus de 60 secondes après le descripteur.
        case expired
        /// Époque autre que la plus récente active connue ici.
        case notLatestEpoch
        /// `callNonce` déjà vu pour un autre appel.
        case replayedNonce
    }

    struct LocalEpoch: Equatable, Sendable {
        let epochId: String
        let epochNumber: Int
        let keyCommitmentB64: String
    }

    static func verify(
        _ candidate: E2EEV2SignedCallDescriptor,
        conversationId: String,
        callId: String,
        callerSigningKey: (_ deviceId: String) -> P256.Signing.PublicKey?,
        latestEpoch: LocalEpoch?,
        nonces: E2EEV2CallNonceLedger,
        nowMs: Int64,
        ringing: Bool
    ) -> Result<E2EEV2CallDescriptor, Failure> {
        let descriptor = candidate.descriptor
        guard descriptor.conversationId == conversationId, descriptor.callId == callId else {
            return .failure(.otherCall)
        }
        guard let signingKey = callerSigningKey(candidate.callerDeviceId) else {
            return .failure(.untrustedCaller)
        }
        do {
            _ = try E2EEV2CallDescriptor.verify(
                candidate.signed, callerSigningKey: signingKey, nowMs: nowMs, ringing: ringing
            )
        } catch E2EEV2CallFormatError.expired {
            return .failure(.expired)
        } catch {
            return .failure(.invalidSignature)
        }
        let announced = LocalEpoch(
            epochId: descriptor.epochId,
            epochNumber: descriptor.epochNumber,
            keyCommitmentB64: descriptor.keyCommitmentB64
        )
        guard let latestEpoch, latestEpoch == announced else { return .failure(.notLatestEpoch) }
        // En dernier : seul un descripteur valide réserve son nonce.
        guard nonces.claim(descriptor.callNonceB64, callId: descriptor.callId, nowMs: nowMs) else {
            return .failure(.replayedNonce)
        }
        return .success(descriptor)
    }
}

/// `callNonce` déjà vus (§10.1) : un nonce ne sert qu'à un seul appel. Gardés
/// sur le disque pour survivre à un réveil par PushKit ; rien de secret (le
/// nonce entre dans un sel, pas dans une clé).
final class E2EEV2CallNonceLedger: @unchecked Sendable {
    static let shared = E2EEV2CallNonceLedger()
    static let retentionMs: Int64 = 7 * 24 * 60 * 60 * 1_000
    static let maxEntries = 2_000

    private struct Record: Codable, Equatable {
        let callId: String
        let seenAtMs: Int64
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var records: [String: Record]?

    /// `fileURL` nil : en mémoire seulement (tests).
    init(fileURL: URL? = E2EEV2CallNonceLedger.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Vrai pour un nonce nouveau, ou déjà vu pour ce même appel (notification
    /// relivrée, rapprochement avec `pending`).
    func claim(_ nonceB64: String, callId: String, nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = loadLocked().filter { nowMs - $0.value.seenAtMs < Self.retentionMs }
        if let known = current[nonceB64] { return known.callId == callId }
        current[nonceB64] = Record(callId: callId, seenAtMs: nowMs)
        if current.count > Self.maxEntries {
            let kept = current.sorted { $0.value.seenAtMs > $1.value.seenAtMs }.prefix(Self.maxEntries)
            current = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        records = current
        save(current)
        return true
    }

    private func loadLocked() -> [String: Record] {
        if let records { return records }
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        records = decoded
        return decoded
    }

    private func save(_ records: [String: Record]) {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SignalQuest", isDirectory: true)
            .appendingPathComponent("CallNoncesV1.json", isDirectory: false)
    }
}
