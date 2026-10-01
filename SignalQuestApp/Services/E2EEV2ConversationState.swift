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
        let recordedAtMs: Int64
    }

    enum Failure: Error, Equatable {
        /// Un autre manifeste d'époque 1 a déjà été vérifié pour cette conversation.
        case genesisConflict
        case invalidRecord
        case otherAccount
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

    static func prefix(ownerNamespace: String) -> String {
        "\(keyPrefix):\(ownerNamespace):"
    }

    private func key(conversationId: String, ownerNamespace: String) -> String {
        Self.prefix(ownerNamespace: ownerNamespace)
            + SHA256.hash(data: Data(conversationId.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
