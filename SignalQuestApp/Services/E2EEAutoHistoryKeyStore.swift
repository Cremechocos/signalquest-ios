import CryptoKit
import Foundation

/// Clé d'historique HK du compte (E2EE-AUTO §2.2, §5) : un scalaire P-256 par
/// clé publique, rangé dans le trousseau synchronisé par iCloud (§5.3 : la
/// synchro est le chemin normal d'un 2ᵉ appareil Apple). Il reste dans le
/// groupe propre à l'app, jamais dans celui de l'extension, qui n'en a pas
/// besoin. Les anciennes HK sont gardées : elles ouvrent les époques
/// sauvegardées avant une rotation (§5.6).
///
/// Une suppression ici part sur tous les appareils du compte iCloud : rien ne
/// vide ce trousseau à la déconnexion.
final class E2EEAutoHistoryKeyStore: @unchecked Sendable {
    static let service = "fr.signalquest.ios.e2ee-auto-history"

    private struct Record: Codable {
        let hkPubB64: String
        let scalarB64: String
    }

    private let store: TokenStore

    init(store: TokenStore = KeychainStore(service: service, synchronizable: true)) {
        self.store = store
    }

    /// Scalaire de `hkPubB64`, seulement s'il lui correspond (§2.2) : une
    /// entrée synchronisée abîmée ou d'une autre clé ne vaut rien.
    func scalar(userId: String, hkPubB64: String) throws -> Data? {
        guard let raw = try store.string(for: key(userId: userId, hkPubB64: hkPubB64)),
              let record = try? JSONDecoder().decode(Record.self, from: Data(raw.utf8)),
              record.hkPubB64 == hkPubB64,
              let scalar = Data(base64Encoded: record.scalarB64),
              E2EEAutoHistoryKey.publicKeyB64(scalar: scalar) == hkPubB64 else { return nil }
        return scalar
    }

    /// Range un scalaire reçu (synchro, passkey, « C'est moi ») ou tiré ici,
    /// sous sa clé publique ; rend celle-ci. Un scalaire hors de `[1, n − 1]`
    /// est refusé.
    @discardableResult
    func keep(scalar: Data, userId: String) throws -> String {
        guard let hkPubB64 = E2EEAutoHistoryKey.publicKeyB64(scalar: scalar) else { throw Failure.invalidScalar }
        let record = Record(hkPubB64: hkPubB64, scalarB64: scalar.base64EncodedString())
        try store.set(
            String(decoding: try JSONEncoder().encode(record), as: UTF8.self),
            for: key(userId: userId, hkPubB64: hkPubB64), accessibility: .afterFirstUnlock
        )
        return hkPubB64
    }

    /// Nouvelle HK, rangée avant toute publication (§5.1) : une publication
    /// réussie ne laisse jamais une clé que l'appareil n'aurait pas gardée.
    func create(userId: String) throws -> String {
        try keep(scalar: P256.Signing.PrivateKey().rawRepresentation, userId: userId)
    }

    /// Jette une HK tirée ici qui a perdu la comparaison-échange (§5.1).
    func discard(userId: String, hkPubB64: String) throws {
        try store.remove(key(userId: userId, hkPubB64: hkPubB64))
    }

    enum Failure: Error, Equatable { case invalidScalar }

    private func key(userId: String, hkPubB64: String) -> String {
        "hk-v1:\(userId):" + E2EEV2Canonical.sha256B64URL(Data(hkPubB64.utf8))
    }
}
