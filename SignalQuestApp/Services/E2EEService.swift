import Foundation
import CryptoKit
import CommonCrypto
import Security
import Combine

private struct ModerationPublicKeyResponse: Decodable {
    let publicKeyJwk: String
}

enum E2EEError: Error, LocalizedError, Equatable {
    case locked
    case unsupported(String)
    case invalidKey
    case wrongPassword
    case decryptFailed
    case keyGenerationFailed
    case staleKey

    var errorDescription: String? {
        switch self {
        case .locked:
            return String(localized: "Déverrouille tes messages chiffrés pour continuer.")
        case .unsupported(let value):
            return value
        case .invalidKey:
            return String(localized: "Clé de chiffrement invalide.")
        case .wrongPassword:
            return String(localized: "Mot de passe incorrect. Réessaie.")
        case .decryptFailed:
            return String(localized: "Déchiffrement impossible")
        case .keyGenerationFailed:
            return String(localized: "Impossible de créer ta clé de chiffrement. Réessaie.")
        case .staleKey:
            return String(localized: "La clé de cette conversation a changé. Elle sera mise à jour à la prochaine ouverture.")
        }
    }
}

protocol E2EEServicing: Sendable {
    func bootstrap() async throws -> E2EEBootstrapResponse
    func unlock(userId: String, password: String, bootstrapKey: E2EEBootstrapKey) async throws
    /// Première utilisation : génère une paire RSA-2048, chiffre la clé privée
    /// avec le mot de passe (PBKDF2 210k + AES-GCM) et l'enregistre côté serveur.
    /// L'utilisateur est déverrouillé à l'issue.
    func generateAndRegisterKey(userId: String, password: String) async throws
    /// Re-partage la clé de conversation aux participants qui n'en ont pas encore
    /// (nouveau membre du groupe, clé créée après coup). Silencieux et idempotent —
    /// même comportement qu'Android `shareConversationKeyIfNeeded`.
    func shareConversationKeyIfNeeded(conversationId: String) async
    func isUnlocked() async -> Bool
    func isConversationUnlocked(conversationId: String) async -> Bool
    func encryptText(conversationId: String, text: String) async throws -> E2EEPayload
    func encryptText(
        conversationId: String,
        text: String,
        contentType: EncryptedMessageContentType,
        operationId: String?
    ) async throws -> E2EEPayload
    /// Chiffre avec une AAD explicite (payload v2). Utilisé pour les messages
    /// planifiés E2EE (le backend exige `aadB64` non vide + un `nonce`). L'AAD est
    /// renvoyée dans le payload et utilisée telle quelle au déchiffrement.
    func encryptText(conversationId: String, text: String, aad: Data) async throws -> E2EEPayload
    func decryptText(conversationId: String, message: MessageItem) async throws -> String
    func moderationWrappedConversationKey(conversationId: String) async throws -> String?
    /// Logout revokes access and clears RAM/legacy v1, but keeps owner-scoped v2 vaults.
    func lockLocalKeys() async
    func lockLocalKeys(expectedSession: LocalAccountSession?) async
    /// Explicit erasure only; never used for ordinary logout or an expired session.
    func wipeLocalKeys() async
    func eraseLocalVault(ownerScopeId: String) async
}

enum EncryptedMessageContentType: String, Codable, Sendable {
    case text
    case edit
    case scheduled
    case threadReply = "thread_reply"
    case poll
    case attachmentCaption = "attachment_caption"
}

/// Métadonnées authentifiées mais non secrètes de l'enveloppe V2. Toute
/// modification de conversation, type ou appareil fait échouer AES-GCM.
struct EncryptedMessageEnvelopeV2AAD: Codable, Equatable, Sendable {
    let schema: String
    let cryptoVersion: Int
    let conversationId: String
    let contentType: EncryptedMessageContentType
    let senderDeviceId: String
    let operationId: String?

    init(
        conversationId: String,
        contentType: EncryptedMessageContentType,
        senderDeviceId: String,
        operationId: String? = nil
    ) {
        schema = "signalquest.encrypted-message"
        cryptoVersion = 2
        self.conversationId = conversationId
        self.contentType = contentType
        self.senderDeviceId = senderDeviceId
        self.operationId = operationId
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

final class E2EEService: E2EEServicing, @unchecked Sendable {
    private static let legacyLockedKey = "SignalQuest.E2EE.LegacyCacheLocked.v1"
    private let api: APIClient
    private let tokenStore: TokenStore
    private let senderDeviceId: String
    private let privacyLock: @Sendable () -> Void
    private let stateLock = NSLock()
    private var unlockedPrivateJwk: String?
    /// Cache mémoire des clés symétriques de conversation (PERF-KEY-01) : évite une
    /// lecture Keychain (IPC securityd) à CHAQUE message déchiffré. Source persistante =
    /// Keychain ; invalidé sur rotation de clé (409) et à `wipeLocalKeys()`.
    private var conversationKeyCache: [String: Data] = [:]

    init(
        api: APIClient,
        tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        senderDeviceId: String = InstallationIdentity().deviceID(),
        privacyLock: @escaping @Sendable () -> Void = {
            E2EEV2NotificationContextEvents.revoke()
            E2EEBiometric.clear()
        }
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.senderDeviceId = senderDeviceId
        self.privacyLock = privacyLock
    }

    func bootstrap() async throws -> E2EEBootstrapResponse {
        try await api.request(APIEndpoint(path: "/api/e2ee/bootstrap"), as: E2EEBootstrapResponse.self)
    }

    /// Plancher défensif d'itérations PBKDF2 accepté au déverrouillage. Très en
    /// dessous de la valeur canonique partagée (210 000) pour ne jamais rejeter un
    /// compte légitime, mais rejette un KDF trivialement cassable qu'un backend
    /// compromis annoncerait (ex. `iterations = 1`) — défense en profondeur (SEC-05).
    static let minAcceptableKdfIterations = 100_000

    func unlock(userId: String, password: String, bootstrapKey: E2EEBootstrapKey) async throws {
        let session = LocalAccountScope.sessionSnapshot()
        guard bootstrapKey.kdfIterations >= Self.minAcceptableKdfIterations else {
            throw E2EEError.invalidKey
        }
        let privateJwk = try Self.decryptPrivateJWK(
            password: password,
            encryptedPrivateJwkB64: bootstrapKey.encryptedPrivateJwk,
            kdfSaltB64: bootstrapKey.kdfSaltB64,
            iterations: bootstrapKey.kdfIterations
        )
        guard Self.privateJwk(privateJwk, matchesPublicJwk: bootstrapKey.publicKeyJwk) else {
            throw E2EEError.invalidKey
        }
        if UserDefaults.standard.bool(forKey: Self.legacyLockedKey) { try purgeLegacyKeys(session: session) }
        try LocalAccountScope.publishIfUnchanged(session) {
            try tokenStore.set(privateJwk, for: "privateJwk:\(userId)", accessibility: .whenUnlocked)
            try tokenStore.set(privateJwk, for: "privateJwk:current", accessibility: .whenUnlocked)
            stateLock.withLock { unlockedPrivateJwk = privateJwk }
            UserDefaults.standard.set(false, forKey: Self.legacyLockedKey)
        }
    }

    func isUnlocked() async -> Bool {
        (try? knownPrivateJwk()) ?? nil != nil
    }

    func generateAndRegisterKey(userId: String, password: String) async throws {
        let session = LocalAccountScope.sessionSnapshot()
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw E2EEError.invalidKey }

        // E2EE-PERF-06 : génération RSA-2048 + PBKDF2 210k = plusieurs centaines de
        // ms de calcul. On l'exécute hors de l'acteur appelant (Task.detached,
        // userInitiated) pour ne jamais figer le main thread ni le spinner du
        // bouton pendant la création de la clé.
        let (privateJwk, payload): (String, E2EEBootstrapInitRequest) = try await Task.detached(priority: .userInitiated) {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                  let privateDER = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
                throw E2EEError.keyGenerationFailed
            }

            // SecKeyCopyExternalRepresentation renvoie un RSAPrivateKey PKCS#1 :
            // SEQUENCE { version, n, e, d, p, q, dp, dq, qi }.
            let integers = try ASN1.parseSequenceOfIntegers(der: privateDER)
            guard integers.count >= 9 else { throw E2EEError.keyGenerationFailed }
            let fields = ["n", "e", "d", "p", "q", "dp", "dq", "qi"]
            var privateObj: [String: String] = ["kty": "RSA"]
            for (index, field) in fields.enumerated() {
                privateObj[field] = integers[index + 1].base64URLEncodedNoPadding()
            }
            let publicObj: [String: String] = [
                "kty": "RSA",
                "n": privateObj["n"]!,
                "e": privateObj["e"]!
            ]
            guard let privateJwkData = try? JSONSerialization.data(withJSONObject: privateObj),
                  let publicJwkData = try? JSONSerialization.data(withJSONObject: publicObj),
                  let privateJwk = String(data: privateJwkData, encoding: .utf8),
                  let publicJwk = String(data: publicJwkData, encoding: .utf8) else {
                throw E2EEError.keyGenerationFailed
            }

            // Chiffrement de la clé privée : salt 16 o, IV 12 o, PBKDF2-HMAC-SHA256
            // 210k itérations, AES-256-GCM — format Android/web (iv + ct + tag, b64 sans padding).
            let iterations = 210_000
            var salt = Data(count: 16)
            var iv = Data(count: 12)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
            let wrapKey = SymmetricKey(data: Self.pbkdf2SHA256(password: trimmed, salt: salt, iterations: iterations, keyLength: 32))
            let sealed = try AES.GCM.seal(Data(privateJwk.utf8), using: wrapKey, nonce: AES.GCM.Nonce(data: iv))
            var combined = iv
            combined.append(sealed.ciphertext)
            combined.append(sealed.tag)

            let payload = E2EEBootstrapInitRequest(
                publicKeyJwk: publicJwk,
                encryptedPrivateJwk: combined.base64EncodedNoPadding(),
                kdfSaltB64: salt.base64EncodedNoPadding(),
                kdfIterations: iterations
            )
            return (privateJwk, payload)
        }.value
        do {
            let _: E2EEBootstrapInitResponse = try await api.requestJSON("/api/e2ee/bootstrap/init", body: payload)
        } catch APIError.http(let status, _, _, _, _) where status == 404 || status == 405 {
            let _: E2EEBootstrapInitResponse = try await api.requestJSON("/api/e2ee/bootstrap", body: payload)
        }

        if UserDefaults.standard.bool(forKey: Self.legacyLockedKey) { try purgeLegacyKeys(session: session) }
        try LocalAccountScope.publishIfUnchanged(session) {
            try tokenStore.set(privateJwk, for: "privateJwk:\(userId)", accessibility: .whenUnlocked)
            try tokenStore.set(privateJwk, for: "privateJwk:current", accessibility: .whenUnlocked)
            stateLock.withLock { unlockedPrivateJwk = privateJwk }
            UserDefaults.standard.set(false, forKey: Self.legacyLockedKey)
        }
    }

    func shareConversationKeyIfNeeded(conversationId: String) async {
        guard let rawKey = try? await conversationKeyData(conversationId: conversationId) else { return }
        struct MissingResponse: Decodable {
            struct Entry: Decodable {
                let userId: String?
                let publicKeyJwk: String?
            }
            let missing: [Entry]?
        }
        guard let response = try? await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/e2ee/missing"),
            as: MissingResponse.self
        ), let missing = response.missing, !missing.isEmpty else { return }

        var shares: [[String: String]] = []
        for entry in missing {
            guard let userId = entry.userId, !userId.isEmpty,
                  let publicJwk = entry.publicKeyJwk, !publicJwk.isEmpty,
                  let wrapped = try? Self.wrapConversationKey(rawKey: rawKey, publicJwk: publicJwk) else { continue }
            shares.append(["userId": userId, "wrappedKeyB64": wrapped])
        }
        guard !shares.isEmpty else { return }
        struct ShareRequest: Encodable { let shares: [[String: String]] }
        try? await api.requestJSON("/api/messages/conversations/\(conversationId)/e2ee/share", body: ShareRequest(shares: shares))
    }

    func lockLocalKeys() async {
        await lockLocalKeys(expectedSession: LocalAccountScope.sessionSnapshot())
    }

    func lockLocalKeys(expectedSession: LocalAccountSession?) async {
        do {
            try LocalAccountScope.publishIfUnchanged(expectedSession) {
                LocalAccountScope.invalidateNotificationSession()
                UserDefaults.standard.set(true, forKey: Self.legacyLockedKey)
                privacyLock()
                stateLock.withLock { unlockedPrivateJwk = nil; conversationKeyCache.removeAll() }
                // Après l'invalidation de la session : plus aucune signature ne la recopie.
                if let expectedSession {
                    try? E2EEV2DeviceIdentityStore.removeLockedSigning(
                        store: tokenStore,
                        ownerNamespace: LocalAccountScope.storageNamespace(for: expectedSession.ownerScopeId)
                    )
                }
            }
        } catch { return }
        // Ces clés historiques n'ont pas de propriétaire fiable. Les préfixes v2 restent intacts.
        try? purgeLegacyKeys(session: nil)
    }

    private func purgeLegacyKeys(session: LocalAccountSession?) throws {
        for prefix in ["privateJwk:", "conversation:"] {
            for key in try tokenStore.keys(withPrefix: prefix) {
                try LocalAccountScope.publishIfUnchanged(session) { try tokenStore.remove(key) }
            }
        }
        try LocalAccountScope.publishIfUnchanged(session) { try tokenStore.remove("privateJwk:current") }
    }

    func wipeLocalKeys() async {
        let owner = LocalAccountScope.currentOwnerScopeId
        await lockLocalKeys()
        await eraseLocalVault(ownerScopeId: owner)
    }

    func eraseLocalVault(ownerScopeId: String) async {
        // Chaque effacement est tenté, même si un autre a échoué.
        let erasures: [() throws -> Void] = [
            { [tokenStore] in try E2EEV2VaultBoundary.purge(store: tokenStore, ownerScopeId: ownerScopeId) },
            { try E2EEV2MediaOutboxStore().purge(ownerScopeId: ownerScopeId) },
            { try E2EEV2MessageLedgerStore().purge(ownerScopeId: ownerScopeId) },
            { try E2EEV2MessageStoreV2().purge(ownerScopeId: ownerScopeId) },
        ]
        for erase in erasures {
            do {
                try erase()
            } catch {
                MessageSyncLog.logger.error("Owner-scoped E2EE erasure incomplete: \(String(describing: error), privacy: .private)")
            }
        }
    }

    func isConversationUnlocked(conversationId: String) async -> Bool {
        do {
            _ = try await conversationKey(conversationId: conversationId)
            return true
        } catch {
            MessageSyncLog.logger.error("conversationKey \(conversationId, privacy: .public) erreur: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    func encryptText(conversationId: String, text: String) async throws -> E2EEPayload {
        try await encryptText(
            conversationId: conversationId,
            text: text,
            contentType: .text,
            operationId: nil
        )
    }

    func encryptText(
        conversationId: String,
        text: String,
        contentType: EncryptedMessageContentType,
        operationId: String?
    ) async throws -> E2EEPayload {
        let aad = try EncryptedMessageEnvelopeV2AAD(
            conversationId: conversationId,
            contentType: contentType,
            senderDeviceId: senderDeviceId,
            operationId: operationId
        ).encoded()
        return try await encryptText(conversationId: conversationId, text: text, aad: aad)
    }

    func encryptText(conversationId: String, text: String, aad: Data) async throws -> E2EEPayload {
        let key = try await conversationKey(conversationId: conversationId)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key, nonce: nonce, authenticating: aad)
        var ciphertextAndTag = Data(sealed.ciphertext)
        ciphertextAndTag.append(sealed.tag)
        return E2EEPayload(
            v: 2,
            ivB64: nonce.data.base64EncodedNoPadding(),
            ciphertextB64: ciphertextAndTag.base64EncodedNoPadding(),
            aadB64: aad.base64EncodedNoPadding()
        )
    }

    func decryptText(conversationId: String, message: MessageItem) async throws -> String {
        // Never fall back to cleartext in an encrypted conversation: a message
        // flagged encrypted but missing IV/ciphertext is malformed, not plaintext.
        guard let ivB64 = message.e2eeIvB64, let ciphertextB64 = message.e2eeCiphertextB64 else {
            throw E2EEError.decryptFailed
        }
        let key = try await conversationKey(conversationId: conversationId)
        guard let ivData = Data(base64EncodedTolerant: ivB64), let combined = Data(base64EncodedTolerant: ciphertextB64), combined.count > 16 else {
            throw E2EEError.decryptFailed
        }
        let authenticatedData: Data
        if let aadB64 = message.e2eeAadB64, !aadB64.isEmpty {
            guard let decoded = Data(base64EncodedTolerant: aadB64) else { throw E2EEError.decryptFailed }
            authenticatedData = decoded
        } else {
            authenticatedData = Data()
        }
        let ciphertext = combined.prefix(combined.count - 16)
        let tag = combined.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: ivData), ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(box, using: key, authenticating: authenticatedData)
        return String(data: plain, encoding: .utf8) ?? ""
    }

    private func conversationKey(conversationId: String) async throws -> SymmetricKey {
        SymmetricKey(data: try await conversationKeyData(conversationId: conversationId))
    }

    private func conversationKeyData(conversationId: String) async throws -> Data {
        let session = LocalAccountScope.sessionSnapshot()
        guard !UserDefaults.standard.bool(forKey: Self.legacyLockedKey) else { throw E2EEError.locked }
        // Cache mémoire d'abord (PERF-KEY-01) — évite l'aller-retour Keychain par message.
        if let mem = stateLock.withLock({ conversationKeyCache[conversationId] }) {
            return mem
        }
        if let cached = try tokenStore.string(for: "conversation:\(conversationId)"),
           let data = Data(base64Encoded: cached),
           data.count == 32 {
            stateLock.withLock { conversationKeyCache[conversationId] = data }
            return data
        }

        guard let privateJwk = try knownPrivateJwk() else {
            throw E2EEError.locked
        }
        do {
            let response: ConversationKeyResponse = try await api.request(APIEndpoint(path: "/api/messages/conversations/\(conversationId)/key"), as: ConversationKeyResponse.self)
            let raw = try Self.unwrapConversationKey(wrappedKeyB64: response.wrappedKeyB64, privateJwk: privateJwk)
            try LocalAccountScope.publishIfUnchanged(session) {
                try tokenStore.set(raw.base64EncodedString(), for: "conversation:\(conversationId)", accessibility: .whenUnlocked)
                stateLock.withLock { conversationKeyCache[conversationId] = raw }
            }
            return raw
        } catch APIError.http(let status, _, _, _, _) where status == 409 {
            // Rotation de clé E2EE côté serveur : la clé wrappée est obsolète. On purge
            // le cache local (mémoire + Keychain) ; le prochain accès re-fetchera après
            // re-partage.
            try? tokenStore.remove("conversation:\(conversationId)")
            stateLock.withLock { _ = conversationKeyCache.removeValue(forKey: conversationId) }
            throw E2EEError.staleKey
        }
    }

    private func knownPrivateJwk() throws -> String? {
        guard !UserDefaults.standard.bool(forKey: Self.legacyLockedKey) else { throw E2EEError.locked }
        if let memory = stateLock.withLock({ unlockedPrivateJwk }) {
            return memory
        }
        return try tokenStore.string(for: "privateJwk:current")
    }

    static func decryptPrivateJWK(password: String, encryptedPrivateJwkB64: String, kdfSaltB64: String, iterations: Int) throws -> String {
        // Android encodes both fields via `Base64.getEncoder().withoutPadding()` —
        // the server stores them unpadded, so iOS must tolerate strings whose length
        // is not a multiple of 4. We try the strict decoder first, then fall back to
        // a padded variant, then to base64URL.
        guard let salt = Data(base64EncodedTolerant: kdfSaltB64),
              let combined = Data(base64EncodedTolerant: encryptedPrivateJwkB64),
              combined.count > 12 else {
            throw E2EEError.invalidKey
        }
        let keyBytes = pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: 32)
        let key = SymmetricKey(data: keyBytes)
        let nonceData = combined.prefix(12)
        let ciphertextAndTag = combined.dropFirst(12)
        guard ciphertextAndTag.count > 16 else { throw E2EEError.invalidKey }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertextAndTag.prefix(ciphertextAndTag.count - 16),
            tag: ciphertextAndTag.suffix(16)
        )
        // Un mot de passe erroné dérive une mauvaise clé PBKDF2 : le tag GCM ne
        // vérifie pas (authenticationFailure). On le traduit en wrongPassword
        // pour un message FR clair et actionnable (E2EE-UX-03).
        let plain: Data
        do {
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw E2EEError.wrongPassword
        }
        guard let jwk = String(data: plain, encoding: .utf8) else { throw E2EEError.invalidKey }
        return jwk
    }

    static func privateJwk(_ privateJwk: String, matchesPublicJwk publicJwk: String) -> Bool {
        guard let privateData = privateJwk.data(using: .utf8),
              let publicData = publicJwk.data(using: .utf8),
              let privateObj = try? JSONSerialization.jsonObject(with: privateData) as? [String: Any],
              let publicObj = try? JSONSerialization.jsonObject(with: publicData) as? [String: Any] else {
            return false
        }
        return privateObj["kty"] as? String == "RSA" &&
            publicObj["kty"] as? String == "RSA" &&
            privateObj["n"] as? String == publicObj["n"] as? String &&
            privateObj["e"] as? String == publicObj["e"] as? String
    }

    static func unwrapConversationKey(wrappedKeyB64: String, privateJwk: String) throws -> Data {
        guard let wrapped = Data(base64EncodedTolerant: wrappedKeyB64),
              let privateKey = try privateSecKey(from: privateJwk) else {
            throw E2EEError.invalidKey
        }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &error) as Data? else {
            throw E2EEError.decryptFailed
        }
        guard raw.count == 32 else { throw E2EEError.invalidKey }
        return raw
    }

    /// Clé de la conversation, chiffrée pour la seule équipe de modération et
    /// jointe à un signalement : sans elle, un message chiffré signalé reste
    /// illisible pour les modérateurs (SOC-12). Même format que le web
    /// (RSA-OAEP-SHA256, base64). `nil` quand le serveur n'a pas de clé de
    /// modération : le signalement part alors sans.
    func moderationWrappedConversationKey(conversationId: String) async throws -> String? {
        let raw = try await conversationKeyData(conversationId: conversationId)
        let response: ModerationPublicKeyResponse
        do {
            response = try await api.request(
                APIEndpoint(path: "/api/e2ee/moderation-public-key"),
                as: ModerationPublicKeyResponse.self
            )
        } catch APIError.http(let status, _, _, _, _) where status == 404 {
            return nil
        }
        return try Self.wrapForModeration(rawKey: raw, publicJwk: response.publicKeyJwk)
    }

    static func wrapForModeration(rawKey: Data, publicJwk: String) throws -> String {
        guard let publicKey = try publicSecKey(from: publicJwk) else { throw E2EEError.invalidKey }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, rawKey as CFData, &error) as Data? else {
            throw E2EEError.invalidKey
        }
        return wrapped.base64EncodedString()
    }

    /// Wrappe une clé de conversation (32 octets) avec la clé publique RSA d'un
    /// autre participant — RSA-OAEP-SHA256, sortie base64 sans padding (format
    /// Android `wrapConversationKey`).
    static func wrapConversationKey(rawKey: Data, publicJwk: String) throws -> String {
        guard rawKey.count == 32, let publicKey = try publicSecKey(from: publicJwk) else {
            throw E2EEError.invalidKey
        }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, rawKey as CFData, &error) as Data? else {
            throw E2EEError.invalidKey
        }
        return wrapped.base64EncodedNoPadding()
    }

    private static func publicSecKey(from jwk: String) throws -> SecKey? {
        guard let data = jwk.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = object["n"] as? String, let e = object["e"] as? String,
              let nData = Data(base64URLEncoded: n), let eData = Data(base64URLEncoded: e) else {
            throw E2EEError.invalidKey
        }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus, publicExponent }
        let der = ASN1.sequence([ASN1.integer(nData), ASN1.integer(eData)])
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: nData.count * 8
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
    }

    private static func privateSecKey(from jwk: String) throws -> SecKey? {
        guard let data = jwk.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw E2EEError.invalidKey
        }
        let fields = ["n", "e", "d", "p", "q", "dp", "dq", "qi"]
        let integers = try fields.map { key -> Data in
            guard let raw = object[key], let decoded = Data(base64URLEncoded: raw) else { throw E2EEError.invalidKey }
            return decoded
        }
        let der = ASN1.sequence([ASN1.integer(Data([0]))] + integers.map(ASN1.integer))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: integers.first.map { $0.count * 8 } ?? 2048
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
    }

    static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        // Canonical PBKDF2-HMAC-SHA256 via CommonCrypto — far faster than a hand
        // rolled CryptoKit loop for high iteration counts, and byte-identical, so
        // it stays interoperable with the Android/web key-derivation.
        let passwordData = Data(password.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, passwordData.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(max(1, iterations)),
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return status == kCCSuccess ? derived : Data()
    }
}

struct E2EEBootstrapInitRequest: Encodable {
    let publicKeyJwk: String
    let encryptedPrivateJwk: String
    let kdfSaltB64: String
    let kdfIterations: Int
}

struct E2EEBootstrapInitResponse: Decodable {
    let ok: Bool?
    let success: Bool?
    let hasKey: Bool?
}

private enum ASN1 {
    static func sequence(_ parts: [Data]) -> Data {
        wrap(tag: 0x30, body: parts.reduce(Data(), +))
    }

    /// Décode un SEQUENCE OF INTEGER DER (export PKCS#1 de SecKey) et renvoie
    /// les INTEGERs dans l'ordre, sans leur éventuel octet de signe initial.
    static func parseSequenceOfIntegers(der: Data) throws -> [Data] {
        var reader = Reader(data: der)
        let (tag, body) = try reader.readElement()
        guard tag == 0x30 else { throw E2EEError.keyGenerationFailed }
        var inner = Reader(data: body)
        var integers: [Data] = []
        while !inner.isAtEnd {
            let (innerTag, value) = try inner.readElement()
            guard innerTag == 0x02 else { throw E2EEError.keyGenerationFailed }
            var bytes = value
            while bytes.count > 1, bytes.first == 0 {
                bytes = bytes.dropFirst()
            }
            integers.append(Data(bytes))
        }
        return integers
    }

    private struct Reader {
        let data: Data
        var index: Data.Index

        init(data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        var isAtEnd: Bool { index >= data.endIndex }

        mutating func readElement() throws -> (tag: UInt8, body: Data) {
            guard index < data.endIndex else { throw E2EEError.keyGenerationFailed }
            let tag = data[index]
            index = data.index(after: index)
            let length = try readLength()
            guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else {
                throw E2EEError.keyGenerationFailed
            }
            let body = data[index..<end]
            index = end
            return (tag, Data(body))
        }

        private mutating func readLength() throws -> Int {
            guard index < data.endIndex else { throw E2EEError.keyGenerationFailed }
            let first = data[index]
            index = data.index(after: index)
            if first & 0x80 == 0 { return Int(first) }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 4 else { throw E2EEError.keyGenerationFailed }
            var value = 0
            for _ in 0..<byteCount {
                guard index < data.endIndex else { throw E2EEError.keyGenerationFailed }
                value = (value << 8) | Int(data[index])
                index = data.index(after: index)
            }
            return value
        }
    }

    static func integer(_ data: Data) -> Data {
        let value = data.drop { $0 == 0 }
        var body = value.isEmpty ? Data([0]) : Data(value)
        if let first = body.first, first & 0x80 != 0 {
            body.insert(0, at: 0)
        }
        return wrap(tag: 0x02, body: body)
    }

    private static func wrap(tag: UInt8, body: Data) -> Data {
        var data = Data([tag])
        data.append(length(body.count))
        data.append(body)
        return data
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: normalized)
    }

    /// Lenient base64 decoder that accepts:
    /// - Standard base64 with or without `=` padding (Android `withoutPadding()` encoder).
    /// - base64URL (`-` / `_` alphabet, with or without padding).
    /// Returns nil only when the payload is genuinely invalid.
    init?(base64EncodedTolerant value: String) {
        if let direct = Data(base64Encoded: value) {
            self = direct
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let padded: String = {
            let remainder = trimmed.count % 4
            guard remainder > 0 else { return trimmed }
            return trimmed + String(repeating: "=", count: 4 - remainder)
        }()
        if let padded = Data(base64Encoded: padded) {
            self = padded
            return
        }
        if let url = Data(base64URLEncoded: trimmed) {
            self = url
            return
        }
        return nil
    }
}

private extension AES.GCM.Nonce {
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}

// MARK: - E2EE v2 device identity preview

enum E2EEV2DeviceIdentityError: Error, Equatable {
    case unauthenticated
    case invalidRecord
    case randomGenerationFailed
    /// Clé illisible parce que l'appareil est verrouillé : on réessaie au
    /// déverrouillage, jamais de nouvel enrôlement (spec §2.6, v0.4.13).
    case locked
}

enum E2EEV2VaultBoundary {
    static func allows(_ namespace: String) -> Bool {
        LocalAccountScope.sessionSnapshot()?.ownerNamespace == namespace
    }

    /// Only an explicit, already acknowledged account erasure reaches this helper.
    static func purge(store: TokenStore, ownerScopeId: String) throws {
        guard ownerScopeId.hasPrefix("user:"), ownerScopeId.count > 5 else { return }
        let namespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        // Chaque effacement est tenté ; la première erreur est rendue à la fin.
        var firstError: Error?
        func attempt(_ erase: () throws -> Void) {
            do { try erase() } catch { if firstError == nil { firstError = error } }
        }
        // La copie lisible verrouillé d'abord, sous son verrou : une signature
        // en cours ne la réécrit pas après l'effacement.
        E2EEV2DeviceIdentityStore.signingCopyLock.withLock {
            for key in [E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: namespace),
                        "device-v2:\(namespace)", "device-v2-reset-candidate:\(namespace)"] {
                attempt { try store.remove(key) }
            }
        }
        for key in ["epoch-v2-owner-index:\(namespace)", "rotation-work-v1:\(namespace)",
                    E2EEV2AccountIdentityStore.key(ownerNamespace: namespace),
                    E2EEV2AccountIdentityStore.verifiedKey(ownerNamespace: namespace),
                    E2EEV2AccountIdentityStore.pendingBootstrapKey(ownerNamespace: namespace),
                    E2EEV2AccountIdentityStore.pendingApprovalKey(ownerNamespace: namespace),
                    E2EEV2AccountIdentityStore.pendingResetKey(ownerNamespace: namespace),
                    E2EEV2CapabilitiesPublicationStore.key(ownerNamespace: namespace)] {
            attempt { try store.remove(key) }
        }
        for prefix in ["epoch-v2:\(namespace):", "epoch-v2-history:\(namespace):", "epoch-v2-index:\(namespace):",
                       E2EEV2TrustPinStore.prefix(ownerNamespace: namespace),
                       E2EEV2ConversationStateStore.prefix(ownerNamespace: namespace)] {
            attempt { for key in try store.keys(withPrefix: prefix) { attempt { try store.remove(key) } } }
        }
        attempt {
            for key in try store.keys(withPrefix: "e2ee_v2_live_share_") {
                attempt {
                    guard let raw = try store.string(for: key), let data = raw.data(using: .utf8),
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          json["ownerScopeId"] as? String == ownerScopeId else { return }
                    try store.remove(key)
                }
            }
        }
        if let firstError { throw firstError }
    }
}

/// Preview-only device identity. Raw P-256 private material is stored in the
/// existing owner-scoped E2EE Keychain vault with `WhenUnlockedThisDeviceOnly`.
/// Logout locks access; only an explicit owner-targeted erasure removes it.
final class E2EEV2DeviceIdentityStore: @unchecked Sendable {
    static let identityKeyAlgorithm = E2EEV2DeviceAlgorithms.identityKeyAlgorithm
    static let signingKeyAlgorithm = E2EEV2DeviceAlgorithms.signingKeyAlgorithm

    private struct Record: Codable {
        let version: Int
        let descriptor: E2EEV2DeviceDescriptor
        let identityPrivateRawB64: String
        /// Clé brute, ou blob de la Secure Enclave selon `signingStorage`.
        let signingPrivateRawB64: String
        let createdAtMs: Int64
        /// Absent : clé logicielle (identités d'avant la v0.4.14, appareil sans Secure Enclave).
        var signingStorage: SigningStorage? = nil
        /// Date de la clé d'accord courante ; absente, celle de l'identité (§2.6).
        var identityKeyCreatedAtMs: Int64? = nil
        /// Nouvelle clé d'accord préparée, gardée jusqu'à la réponse du serveur.
        var pendingIdentityKey: PendingAgreementKey? = nil
        /// Anciennes clés d'accord, pour les enveloppes encore adressées à elles.
        var retiredIdentityKeys: [RetiredAgreementKey]? = nil
    }

    private struct PendingAgreementKey: Codable, Equatable {
        let privateRawB64: String
        let createdAtMs: Int64
    }

    private struct RetiredAgreementKey: Codable, Equatable {
        let keyVersion: Int
        let privateRawB64: String
        let retiredAtMs: Int64
    }

    /// Rotation de la clé d'accord en cours (§2.6) : la nouvelle clé publique,
    /// sa version et sa date, celle de son certificat.
    struct AgreementKeyRotation: Equatable, Sendable {
        let deviceId: String
        let keyVersion: Int
        let identityKeyB64: String
        let createdAtMs: Int64
    }

    /// §2.6 : la clé d'accord tourne tous les 30 jours.
    static let agreementKeyLifetimeMs: Int64 = 30 * 86_400_000
    /// Anciennes clés gardées : trois au plus, 90 jours au plus.
    static let retiredAgreementKeyLimit = 3
    static let retiredAgreementKeyRetentionMs: Int64 = 90 * 86_400_000

    /// Où vit la clé de signature (spec §2.6, v0.4.14).
    enum SigningStorage: String, Codable, Sendable {
        /// Secure Enclave : seul son blob, inutilisable hors de cet appareil, est gardé.
        case secureEnclave
    }

    /// Clé de signature de l'appareil, jamais extractable dans la Secure Enclave.
    /// Toute signature passe par la forme DER canonique et low-S (D.0) : la
    /// Secure Enclave, comme CryptoKit, produit environ une fois sur deux un s haut.
    private enum Signer {
        case software(P256.Signing.PrivateKey)
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)

        init(material: Data, storage: SigningStorage?) throws {
            switch storage {
            case nil: self = .software(try P256.Signing.PrivateKey(rawRepresentation: material))
            case .secureEnclave: self = .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material))
            }
        }

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .software(let key): return key.publicKey
            case .secureEnclave(let key): return key.publicKey
            }
        }

        func sign(_ message: Data) throws -> Data {
            switch self {
            case .software(let key): return try E2EEV2LowS.sign(message, with: key)
            case .secureEnclave(let key): return try E2EEV2LowS.normalize(der: key.signature(for: message).derRepresentation)
            }
        }
    }

    /// Dès qu'il y en a une (le simulateur d'un Mac Apple silicon en fournit une).
    static var createsSecureEnclaveKeys: Bool { SecureEnclave.isAvailable }

    private func signer(_ record: Record) throws -> Signer {
        try Signer(material: decoded(record.signingPrivateRawB64), storage: record.signingStorage)
    }

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool
    private let identityChanged: @Sendable (String) -> Void
    /// Faux dans les tests des identités logicielles d'avant la v0.4.14.
    private let usesSecureEnclave: Bool

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) },
         identityChanged: @escaping @Sendable (String) -> Void = { E2EEV2NotificationContextEvents.identityDidChange(ownerNamespace: $0) },
         usesSecureEnclave: Bool = E2EEV2DeviceIdentityStore.createsSecureEnclaveKeys) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
        self.identityChanged = identityChanged
        self.usesSecureEnclave = usesSecureEnclave
    }

    func loadOrCreate(label: String? = nil) throws -> E2EEV2DeviceDescriptor {
        guard LocalAccountScope.currentUserId != nil else {
            throw E2EEV2DeviceIdentityError.unauthenticated
        }
        return try loadOrCreate(ownerNamespace: LocalAccountScope.storageNamespace, label: label)
    }

    func load() throws -> E2EEV2DeviceDescriptor? {
        guard LocalAccountScope.currentUserId != nil else { return nil }
        return try loadRecord(ownerNamespace: LocalAccountScope.storageNamespace)?.descriptor
    }

    func load(ownerNamespace: String) throws -> E2EEV2DeviceDescriptor? {
        try loadRecord(ownerNamespace: ownerNamespace)?.descriptor
    }

    func sign(canonicalRequest: Data) throws -> Data {
        guard LocalAccountScope.currentUserId != nil else {
            throw E2EEV2DeviceIdentityError.unauthenticated
        }
        return try sign(canonicalRequest: canonicalRequest, ownerNamespace: LocalAccountScope.storageNamespace)
    }

    func reset() throws {
        guard LocalAccountScope.currentUserId != nil else {
            throw E2EEV2DeviceIdentityError.unauthenticated
        }
        let ownerNamespace = LocalAccountScope.storageNamespace
        try Self.signingCopyLock.withLock {
            try tokenStore.remove(Self.lockedSigningStorageKey(ownerNamespace: ownerNamespace))
            try tokenStore.remove(storageKey(ownerNamespace: ownerNamespace))
            try tokenStore.remove(resetCandidateStorageKey(ownerNamespace: ownerNamespace))
        }
    }

    @discardableResult
    func loadOrCreate(ownerNamespace: String, label: String? = nil) throws -> E2EEV2DeviceDescriptor {
        try loadOrCreateRecord(ownerNamespace: ownerNamespace, label: label).descriptor
    }

    private func loadOrCreateRecord(ownerNamespace: String, label: String? = nil) throws -> Record {
        if let record = try loadRecord(ownerNamespace: ownerNamespace) {
            // Identités créées avant la copie lisible verrouillé : elle s'écrit ici.
            try? syncLockedSigning(ownerNamespace: ownerNamespace)
            return record
        }

        let (_, value) = try makeRecord(label: label)
        let created = try Self.signingCopyLock.withLock { () throws -> (record: Record, isNew: Bool) in
            // Deux premières requêtes simultanées : une seule identité.
            if let existing = try loadRecord(ownerNamespace: ownerNamespace) { return (existing, false) }
            try tokenStore.set(
                value,
                for: storageKey(ownerNamespace: ownerNamespace),
                accessibility: .whenUnlocked
            )
            let record = try requiredRecord(ownerNamespace: ownerNamespace)
            try? writeLockedSigning(record, ownerNamespace: ownerNamespace)
            return (record, true)
        }
        if created.isNew { identityChanged(ownerNamespace) }
        return created.record
    }

    /// Prepares a replacement identity without touching the active identity.
    /// The candidate is durable so an email challenge can survive process death,
    /// but normal messaging never signs with it before server acknowledgement.
    @discardableResult
    func prepareResetCandidate(
        ownerNamespace: String,
        label: String? = nil
    ) throws -> E2EEV2DeviceDescriptor {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        // L'identité active peut être inutilisable (blob de Secure Enclave d'un
        // appareil effacé puis restauré) : la remplacer reste possible.
        let activeDeviceId = try activeDeviceIdForReset(ownerNamespace: ownerNamespace)
        if let existing = try loadResetCandidateRecord(ownerNamespace: ownerNamespace) {
            guard existing.descriptor.deviceId != activeDeviceId else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            return existing.descriptor
        }
        let (candidate, value) = try makeRecord(label: label)
        guard candidate.descriptor.deviceId != activeDeviceId else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        try tokenStore.set(
            value,
            for: resetCandidateStorageKey(ownerNamespace: ownerNamespace),
            accessibility: .whenUnlocked
        )
        let persisted = try requiredResetCandidateRecord(ownerNamespace: ownerNamespace)
        guard persisted.descriptor.deviceId != activeDeviceId else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return persisted.descriptor
    }

    /// Identifiant de l'identité active, lu sans en valider les clés.
    private func activeDeviceIdForReset(ownerNamespace: String) throws -> String? {
        guard let raw = try tokenStore.string(for: storageKey(ownerNamespace: ownerNamespace)),
              let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.descriptor.deviceId
    }

    func loadResetCandidate(ownerNamespace: String) throws -> E2EEV2DeviceDescriptor? {
        try loadResetCandidateRecord(ownerNamespace: ownerNamespace)?.descriptor
    }

    func signResetCandidate(
        canonicalRequest: Data,
        ownerNamespace: String
    ) throws -> Data {
        let record = try requiredResetCandidateRecord(ownerNamespace: ownerNamespace)
        // Forme low-S obligatoire (spec §4.1 et §15) : CryptoKit peut produire du high-S.
        return try signer(record).sign(canonicalRequest)
    }

    /// Restart-safe local commit after a strictly validated server response.
    /// Keychain has no multi-item transaction: writing and verifying the active
    /// candidate before deleting its staging copy keeps every intermediate state
    /// recoverable and makes a repeated activation idempotent.
    @discardableResult
    func activateResetCandidate(
        ownerNamespace: String,
        expectedDeviceId: String,
        expectedSession: LocalAccountSession? = nil
    ) throws -> LocalAccountSession? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        let candidateKey = resetCandidateStorageKey(ownerNamespace: ownerNamespace)
        guard let candidateRaw = try tokenStore.string(for: candidateKey),
              let candidateData = candidateRaw.data(using: .utf8),
              let candidate = try? JSONDecoder().decode(Record.self, from: candidateData) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        try validate(candidate)
        guard candidate.descriptor.deviceId == expectedDeviceId else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let activeKey = storageKey(ownerNamespace: ownerNamespace)
        let commit = { [self] () throws -> LocalAccountSession? in
            guard try tokenStore.string(for: candidateKey) == candidateRaw else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            // Jamais l'ancienne clé de signature dans la copie lisible verrouillé :
            // la copie part avant que la nouvelle identité ne s'écrive, et rien ne
            // s'écrit si elle ne part pas.
            let changed = try Self.signingCopyLock.withLock { () throws -> Bool in
                let changed = try tokenStore.string(for: activeKey) != candidateRaw
                if changed {
                    try tokenStore.remove(Self.lockedSigningStorageKey(ownerNamespace: ownerNamespace))
                    try tokenStore.set(candidateRaw, for: activeKey, accessibility: .whenUnlocked)
                    guard try tokenStore.string(for: activeKey) == candidateRaw else {
                        throw E2EEV2DeviceIdentityError.invalidRecord
                    }
                }
                try? writeLockedSigning(candidate, ownerNamespace: ownerNamespace)
                return changed
            }
            if changed { identityChanged(ownerNamespace) }
            try tokenStore.remove(candidateKey)
            return LocalAccountScope.sessionSnapshot()
        }
        // Validation P-256/JSON ci-dessus ; publication et renouvellement de bail atomiques.
        if let expectedSession { return try LocalAccountScope.publish(for: expectedSession, commit) }
        return try commit()
    }

    func discardResetCandidate(ownerNamespace: String) throws {
        try tokenStore.remove(resetCandidateStorageKey(ownerNamespace: ownerNamespace))
    }

    func sign(canonicalRequest: Data, ownerNamespace: String) throws -> Data {
        let signing = try signingKey(ownerNamespace: ownerNamespace, createsIdentity: false)
        // Forme low-S obligatoire (spec §4.1 et §15) : CryptoKit peut produire du high-S.
        return try signing.key.sign(canonicalRequest)
    }

    /// Appareil qui signe ici, lisible écran verrouillé comme sa clé de
    /// signature (§2.6) : la preuve de jonction d'un appel décroché verrouillé.
    func signingDeviceId(ownerNamespace: String) throws -> String {
        try signingKey(ownerNamespace: ownerNamespace, createsIdentity: false).deviceId
    }

    /// Requête signée, appareil verrouillé compris (spec §2.6, v0.4.13) :
    /// l'identifiant et la signature viennent de la même clé, lue une fois.
    func signWithDeviceId(canonicalRequest: Data, ownerNamespace: String) throws -> (deviceId: String, signature: Data) {
        let signing = try signingKey(ownerNamespace: ownerNamespace, createsIdentity: true)
        return (signing.deviceId, try signing.key.sign(canonicalRequest))
    }

    private func signingKey(
        ownerNamespace: String,
        createsIdentity: Bool
    ) throws -> (deviceId: String, key: Signer) {
        do {
            let record = createsIdentity
                ? try loadOrCreateRecord(ownerNamespace: ownerNamespace)
                : try requiredRecord(ownerNamespace: ownerNamespace)
            let key = try signer(record)
            if !createsIdentity { try? syncLockedSigning(ownerNamespace: ownerNamespace) }
            return (record.descriptor.deviceId, key)
        } catch where Self.isLocked(error) {
            return try lockedSigning(ownerNamespace: ownerNamespace)
        }
    }

    // MARK: Signature écran verrouillé (spec §2.6, v0.4.13)

    /// Copie de la seule clé de signature, lisible dès le premier déverrouillage
    /// après le démarrage, pour décrocher un appel chiffré écran verrouillé. La
    /// clé d'accord et l'UIK restent derrière le déverrouillage.
    /// L'enregistrement principal reste la référence : la copie est tenue à jour
    /// à chaque lecture réussie, et ne sert que si le trousseau le refuse parce
    /// que l'appareil est verrouillé.
    private struct LockedSigningRecord: Codable {
        let version: Int
        let deviceId: String
        let signingPrivateRawB64: String
        var signingStorage: SigningStorage? = nil
    }

    static func lockedSigningStorageKey(ownerNamespace: String) -> String {
        "device-v2-signing-afu:\(ownerNamespace)"
    }

    /// Partagé par toutes les instances, qui lisent le même trousseau : toute
    /// écriture de l'enregistrement principal ou de la copie se fait sous ce verrou.
    static let signingCopyLock = NSLock()

    /// « Verrouillé » n'est jamais « perdu » : le trousseau refuse l'accès, la clé existe.
    static func isLocked(_ error: Error) -> Bool {
        (error as? KeychainError) == .unexpectedStatus(errSecInteractionNotAllowed)
            || (error as? E2EEV2DeviceIdentityError) == .locked
    }

    /// Déconnexion : la clé de signature ne reste pas lisible verrouillé ; la
    /// prochaine lecture déverrouillée d'une session ouverte la recopie.
    static func removeLockedSigning(store: TokenStore, ownerNamespace: String) throws {
        try signingCopyLock.withLock { try store.remove(lockedSigningStorageKey(ownerNamespace: ownerNamespace)) }
    }

    /// Recopie l'enregistrement principal relu sous le verrou : une signature qui
    /// a lu l'ancienne clé juste avant un remplacement ne la recopie jamais, et un
    /// propriétaire qui n'a plus de session ne recopie rien.
    private func syncLockedSigning(ownerNamespace: String) throws {
        try Self.signingCopyLock.withLock {
            try writeLockedSigning(try requiredRecord(ownerNamespace: ownerNamespace), ownerNamespace: ownerNamespace)
        }
    }

    /// Sous `signingCopyLock`. Seule une clé de la Secure Enclave est recopiée
    /// (v0.4.14) : une clé logicielle d'avant reste derrière le déverrouillage,
    /// et une copie ancienne part.
    private func writeLockedSigning(_ record: Record, ownerNamespace: String) throws {
        let key = Self.lockedSigningStorageKey(ownerNamespace: ownerNamespace)
        guard record.signingStorage == .secureEnclave else {
            if try tokenStore.string(for: key) != nil { try tokenStore.remove(key) }
            return
        }
        if let raw = try tokenStore.string(for: key), let data = raw.data(using: .utf8),
           let current = try? JSONDecoder().decode(LockedSigningRecord.self, from: data),
           current.version == 1, current.deviceId == record.descriptor.deviceId,
           current.signingPrivateRawB64 == record.signingPrivateRawB64, current.signingStorage == record.signingStorage {
            return
        }
        let copy = LockedSigningRecord(
            version: 1, deviceId: record.descriptor.deviceId, signingPrivateRawB64: record.signingPrivateRawB64,
            signingStorage: record.signingStorage
        )
        try tokenStore.set(String(decoding: try JSONEncoder().encode(copy), as: UTF8.self), for: key, accessibility: .afterFirstUnlock)
    }

    private func lockedSigning(ownerNamespace: String) throws -> (deviceId: String, key: Signer) {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard let raw = try tokenStore.string(for: Self.lockedSigningStorageKey(ownerNamespace: ownerNamespace)) else {
            // Pas encore de copie : seul le déverrouillage permet de signer.
            throw E2EEV2DeviceIdentityError.locked
        }
        guard let data = raw.data(using: .utf8),
              let copy = try? JSONDecoder().decode(LockedSigningRecord.self, from: data),
              copy.version == 1, E2EEV2Canonical.isOpaque(copy.deviceId) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return (copy.deviceId, try Signer(material: decoded(copy.signingPrivateRawB64), storage: copy.signingStorage))
    }

    /// Unwraps an already authenticated epoch delivery without exporting the
    /// private ECDH key outside this Keychain-backed store.
    func unwrapEpochKey(
        delivery: E2EEV2EpochDelivery,
        ownerNamespace: String
    ) throws -> Data {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        guard record.descriptor.deviceId == delivery.envelope.recipientDeviceId else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        // Une enveloppe peut viser la clé d'avant la dernière rotation (§2.6).
        var lastError: Error = E2EEV2DeviceIdentityError.invalidRecord
        for privateKey in try agreementKeys(record) {
            do {
                return try E2EEV2EpochCrypto.unwrap(
                    envelope: delivery.envelope.cryptoEnvelope,
                    keyCommitmentB64: delivery.keyCommitmentB64,
                    recipientPrivateKey: privateKey,
                    context: delivery.epochContext
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Clé courante d'abord, puis la préparée, puis les anciennes, de la plus récente.
    private func agreementKeys(_ record: Record) throws -> [P256.KeyAgreement.PrivateKey] {
        let raws = [record.identityPrivateRawB64]
            + [record.pendingIdentityKey?.privateRawB64].compactMap { $0 }
            + (record.retiredIdentityKeys ?? []).reversed().map(\.privateRawB64)
        return try raws.map { try P256.KeyAgreement.PrivateKey(rawRepresentation: decoded($0)) }
    }

    // MARK: Rotation de la clé d'accord (§2.6, lot A1)

    /// La rotation à envoyer : celle déjà préparée, sinon une nouvelle clé si
    /// la courante a 30 jours. Préparée et gardée avant l'envoi, pour qu'une
    /// reprise renvoie le même certificat.
    func agreementKeyRotation(ownerNamespace: String, nowMs: Int64) throws -> AgreementKeyRotation? {
        try Self.signingCopyLock.withLock { () throws -> AgreementKeyRotation? in
            let record = try requiredRecord(ownerNamespace: ownerNamespace)
            if let pending = record.pendingIdentityKey { return try rotation(record, pending) }
            guard nowMs - (record.identityKeyCreatedAtMs ?? record.createdAtMs) >= Self.agreementKeyLifetimeMs else {
                return nil
            }
            var updated = record
            updated.pendingIdentityKey = PendingAgreementKey(
                privateRawB64: P256.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(), createdAtMs: nowMs
            )
            try writeActive(updated, replacing: record, ownerNamespace: ownerNamespace)
            return try rotation(updated, updated.pendingIdentityKey!)
        }
    }

    /// Le serveur a enregistré le certificat : la clé préparée devient la clé
    /// d'accord, l'ancienne est gardée pour les enveloppes encore en route.
    func activateAgreementKey(_ rotation: AgreementKeyRotation, ownerNamespace: String, nowMs: Int64) throws {
        let changed = try Self.signingCopyLock.withLock { () throws -> Bool in
            let record = try requiredRecord(ownerNamespace: ownerNamespace)
            if record.descriptor.keyVersion == rotation.keyVersion,
               record.descriptor.publicIdentityKeyB64 == rotation.identityKeyB64 { return false }
            guard let pending = record.pendingIdentityKey, try self.rotation(record, pending) == rotation else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            let old = record.descriptor
            let retired = ((record.retiredIdentityKeys ?? []) + [RetiredAgreementKey(
                keyVersion: old.keyVersion, privateRawB64: record.identityPrivateRawB64, retiredAtMs: nowMs
            )]).filter { nowMs - $0.retiredAtMs < Self.retiredAgreementKeyRetentionMs }.suffix(Self.retiredAgreementKeyLimit)
            let updated = Record(
                version: record.version,
                descriptor: E2EEV2DeviceDescriptor(
                    deviceId: old.deviceId, platform: old.platform, label: old.label,
                    publicIdentityKeyB64: rotation.identityKeyB64, publicSigningKeyB64: old.publicSigningKeyB64,
                    identityKeyAlgorithm: old.identityKeyAlgorithm, signingKeyAlgorithm: old.signingKeyAlgorithm,
                    keyVersion: rotation.keyVersion
                ),
                identityPrivateRawB64: pending.privateRawB64,
                signingPrivateRawB64: record.signingPrivateRawB64,
                createdAtMs: record.createdAtMs,
                signingStorage: record.signingStorage,
                identityKeyCreatedAtMs: pending.createdAtMs,
                pendingIdentityKey: nil,
                retiredIdentityKeys: Array(retired)
            )
            try writeActive(updated, replacing: record, ownerNamespace: ownerNamespace)
            return true
        }
        if changed { identityChanged(ownerNamespace) }
    }

    private func rotation(_ record: Record, _ pending: PendingAgreementKey) throws -> AgreementKeyRotation {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: decoded(pending.privateRawB64))
        return AgreementKeyRotation(
            deviceId: record.descriptor.deviceId, keyVersion: record.descriptor.keyVersion + 1,
            identityKeyB64: key.publicKey.x963Representation.base64EncodedString(), createdAtMs: pending.createdAtMs
        )
    }

    /// Sous `signingCopyLock` : réécrit l'identité active si elle n'a pas changé entre-temps.
    private func writeActive(_ record: Record, replacing previous: Record, ownerNamespace: String) throws {
        try validate(record)
        let key = storageKey(ownerNamespace: ownerNamespace)
        guard let raw = try tokenStore.string(for: key), let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Record.self, from: data),
              stored.descriptor == previous.descriptor, stored.identityPrivateRawB64 == previous.identityPrivateRawB64,
              stored.pendingIdentityKey == previous.pendingIdentityKey else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let encoded = try JSONEncoder().encode(record)
        guard let value = String(data: encoded, encoding: .utf8) else { throw E2EEV2DeviceIdentityError.invalidRecord }
        try tokenStore.set(value, for: key, accessibility: .whenUnlocked)
        guard try tokenStore.string(for: key) == value else { throw E2EEV2DeviceIdentityError.invalidRecord }
    }

    /// Opens the account identity key handed over at approval (D.1) without
    /// exporting the private ECDH key outside this Keychain-backed store.
    func unwrapAccountIdentityKey(
        _ wrap: E2EEV2UIKWrap,
        approverSigningKey: P256.Signing.PublicKey,
        expectedUIKB64: String,
        ownerNamespace: String
    ) throws -> P256.Signing.PrivateKey {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        guard record.descriptor.deviceId == wrap.newDeviceId else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return try E2EEV2UIKWrapCrypto.unwrap(
            wrap,
            newDeviceAgreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: decoded(record.identityPrivateRawB64)),
            approverSigningKey: approverSigningKey,
            expectedUIKB64: expectedUIKB64
        )
    }

    /// Creates and signs one epoch envelope without exporting the long-lived
    /// device private keys beyond this Keychain-backed store.
    func createSignedEpochEnvelope(
        context: E2EEV2EpochContext,
        epochKey: Data,
        recipientPublicIdentityKeyB64: String,
        ownerNamespace: String,
        nonce: Data? = nil
    ) throws -> E2EEV2SignedEpochEnvelope {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        guard record.descriptor.deviceId == context.senderDeviceId,
              let recipientData = Data(base64Encoded: recipientPublicIdentityKeyB64),
              recipientData.count == 65 else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let recipientPublic = try P256.KeyAgreement.PublicKey(x963Representation: recipientData)
        let envelope = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: recipientPublic,
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(),
            nonce: try nonce ?? randomBytes(count: 12),
            context: context
        )
        let signature = try signer(record).sign(
            E2EEV2EpochCrypto.signatureCanonical(
                context: context,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(epochKey),
                envelope: envelope
            )
        )
        return E2EEV2SignedEpochEnvelope(
            recipientDeviceId: envelope.recipientDeviceId,
            wrapAlgorithm: envelope.wrapAlgorithm,
            ephemeralPublicKeyB64: envelope.ephemeralPublicKeyB64,
            wrappedEpochKeyB64: envelope.wrappedEpochKeyB64,
            nonceB64: envelope.nonceB64,
            aadB64: envelope.aadB64,
            signatureB64: signature.base64EncodedString()
        )
    }

    /// Creates a recovery envelope for an historical epoch. The device that
    /// performs the backfill signs it with its own current signing identity;
    /// the original epoch creator is deliberately not impersonated.
    func createSignedRecoveryEpochEnvelope(
        context: E2EEV2RecoveryEpochContext,
        keyCommitmentB64: String,
        epochKey: Data,
        recipientPublicIdentityKeyB64: String,
        ownerNamespace: String,
        nonce: Data? = nil
    ) throws -> E2EEV2RecoveryEpochEnvelope {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        guard record.descriptor.deviceId == context.senderDeviceId,
              let recipientData = Data(base64Encoded: recipientPublicIdentityKeyB64),
              recipientData.count == 65,
              recipientData.first == 4 else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let recipientPublic = try P256.KeyAgreement.PublicKey(x963Representation: recipientData)
        let unsigned = try E2EEV2RecoveryEpochCrypto.wrap(
            epochKey: epochKey,
            keyCommitmentB64: keyCommitmentB64,
            recipientPublicKey: recipientPublic,
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(),
            nonce: try nonce ?? randomBytes(count: 12),
            context: context
        )
        let signature = try signer(record).sign(
            E2EEV2RecoveryEpochCrypto.signatureCanonical(
                context: context,
                keyCommitmentB64: keyCommitmentB64,
                envelope: unsigned
            )
        )
        return E2EEV2RecoveryEpochEnvelope(
            recipientUserId: unsigned.recipientUserId,
            recoveryBundleHash: unsigned.recoveryBundleHash,
            wrapAlgorithm: unsigned.wrapAlgorithm,
            ephemeralPublicKeyB64: unsigned.ephemeralPublicKeyB64,
            wrappedEpochKeyB64: unsigned.wrappedEpochKeyB64,
            nonceB64: unsigned.nonceB64,
            aadB64: unsigned.aadB64,
            signatureB64: signature.base64EncodedString()
        )
    }

    func storageKey(ownerNamespace: String) -> String {
        "device-v2:\(ownerNamespace)"
    }

    func resetCandidateStorageKey(ownerNamespace: String) -> String {
        "device-v2-reset-candidate:\(ownerNamespace)"
    }

    private func loadRecord(ownerNamespace: String) throws -> Record? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard let raw = try tokenStore.string(for: storageKey(ownerNamespace: ownerNamespace)) else {
            return nil
        }
        guard let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        try validate(record)
        return record
    }

    private func requiredRecord(ownerNamespace: String) throws -> Record {
        guard let record = try loadRecord(ownerNamespace: ownerNamespace) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return record
    }

    private func loadResetCandidateRecord(ownerNamespace: String) throws -> Record? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard let raw = try tokenStore.string(
            for: resetCandidateStorageKey(ownerNamespace: ownerNamespace)
        ) else { return nil }
        guard let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        try validate(record)
        return record
    }

    private func requiredResetCandidateRecord(ownerNamespace: String) throws -> Record {
        guard let record = try loadResetCandidateRecord(ownerNamespace: ownerNamespace) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return record
    }

    private func makeRecord(label: String?) throws -> (Record, String) {
        let identityPrivate = P256.KeyAgreement.PrivateKey()
        let signing = try newSigningKey()
        let descriptor = E2EEV2DeviceDescriptor(
            deviceId: "ios_\(try randomBytes(count: 24).base64URLEncodedNoPadding())",
            platform: "ios",
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).nonEmptyString,
            publicIdentityKeyB64: identityPrivate.publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: Self.identityKeyAlgorithm,
            signingKeyAlgorithm: Self.signingKeyAlgorithm,
            keyVersion: 1
        )
        let record = Record(
            version: 1,
            descriptor: descriptor,
            identityPrivateRawB64: identityPrivate.rawRepresentation.base64EncodedString(),
            signingPrivateRawB64: signing.material.base64EncodedString(),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            signingStorage: signing.storage
        )
        let encoded = try JSONEncoder().encode(record)
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return (record, value)
    }

    private func validate(_ record: Record) throws {
        guard record.version == 1,
              record.descriptor.platform == "ios",
              record.descriptor.identityKeyAlgorithm == Self.identityKeyAlgorithm,
              record.descriptor.signingKeyAlgorithm == Self.signingKeyAlgorithm,
              (1...1_000_000).contains(record.descriptor.keyVersion),
              record.descriptor.deviceId.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#,
                options: .regularExpression
              ) != nil else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }

        do {
            let identityPrivate = try P256.KeyAgreement.PrivateKey(
                rawRepresentation: decoded(record.identityPrivateRawB64)
            )
            let signingPublic = try signer(record).publicKey
            guard identityPrivate.publicKey.x963Representation.base64EncodedString()
                    == record.descriptor.publicIdentityKeyB64,
                  signingPublic.x963Representation.base64EncodedString()
                    == record.descriptor.publicSigningKeyB64,
                  identityPrivate.publicKey.x963Representation.count == 65,
                  signingPublic.x963Representation.count == 65 else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
        } catch let error as E2EEV2DeviceIdentityError {
            throw error
        } catch {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
    }

    /// Clé de signature d'une nouvelle identité : dans la Secure Enclave quand
    /// l'appareil en a une, utilisable dès le premier déverrouillage après le
    /// démarrage pour rejoindre un appel chiffré verrouillé (§2.6), jamais
    /// extractable ; sinon logicielle.
    private func newSigningKey() throws -> (publicKey: P256.Signing.PublicKey, material: Data, storage: SigningStorage?) {
        guard usesSecureEnclave else {
            let key = P256.Signing.PrivateKey()
            return (key.publicKey, key.rawRepresentation, nil)
        }
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil
        ) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        return (key.publicKey, key.dataRepresentation, .secureEnclave)
    }

    private func decoded(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return data
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw E2EEV2DeviceIdentityError.randomGenerationFailed
        }
        return data
    }
}

extension E2EEV2SignedRequest {
    static func sign(
        method: String,
        path: String,
        body: Data,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        nonce: String? = nil,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) throws -> E2EEV2SignedHeaders {
        try signBodyHash(
            method: method,
            path: path,
            bodySHA256Base64URL: bodySHA256Base64URL(body),
            timestampMs: timestampMs,
            nonce: nonce,
            identityStore: identityStore
        )
    }

    static func signBodyHash(
        method: String,
        path: String,
        bodySHA256Base64URL: String,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        nonce: String? = nil,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) throws -> E2EEV2SignedHeaders {
        let resolvedNonce = try nonce ?? newNonce()
        guard LocalAccountScope.currentUserId != nil else { throw E2EEV2DeviceIdentityError.unauthenticated }
        return try signBodyHash(
            method: method,
            path: path,
            bodySHA256Base64URL: bodySHA256Base64URL,
            ownerNamespace: LocalAccountScope.storageNamespace,
            timestampMs: timestampMs,
            nonce: resolvedNonce,
            identityStore: identityStore
        )
    }

    static func signBodyHash(
        method: String,
        path: String,
        bodySHA256Base64URL: String,
        ownerNamespace: String,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        nonce: String? = nil,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) throws -> E2EEV2SignedHeaders {
        let resolvedNonce = try nonce ?? newNonce()
        let canonical = try canonicalRequest(
            method: method,
            path: path,
            timestampMs: timestampMs,
            nonce: resolvedNonce,
            bodySHA256Base64URL: bodySHA256Base64URL
        )
        let signed = try identityStore.signWithDeviceId(canonicalRequest: canonical, ownerNamespace: ownerNamespace)
        return E2EEV2SignedHeaders(
            deviceId: signed.deviceId,
            timestampMs: timestampMs,
            nonce: resolvedNonce,
            signatureB64: signed.signature.base64EncodedString()
        )
    }

    static func signResetCandidateBodyHash(
        method: String,
        path: String,
        bodySHA256Base64URL: String,
        ownerNamespace: String,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        nonce: String? = nil,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) throws -> E2EEV2SignedHeaders {
        let resolvedNonce = try nonce ?? newNonce()
        guard let descriptor = try identityStore.loadResetCandidate(
            ownerNamespace: ownerNamespace
        ) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let canonical = try canonicalRequest(
            method: method,
            path: path,
            timestampMs: timestampMs,
            nonce: resolvedNonce,
            bodySHA256Base64URL: bodySHA256Base64URL
        )
        return E2EEV2SignedHeaders(
            deviceId: descriptor.deviceId,
            timestampMs: timestampMs,
            nonce: resolvedNonce,
            signatureB64: try identityStore.signResetCandidate(
                canonicalRequest: canonical,
                ownerNamespace: ownerNamespace
            ).base64EncodedString()
        )
    }
}

// MARK: - E2EE v2 signed transport (preview, fail-closed)

/// Cible d'une requête signée (A.2, v0.4.15) : tout ce qui n'est pas « non
/// réservé » (RFC 3986) est encodé en pourcentage, en majuscules, avant de
/// signer, et part tel quel sur le fil ; le serveur la lit sans la décoder.
enum E2EEV2SignedTarget {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func encodedQuery(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
    }

    /// Chemin déjà fait de segments non réservés (identifiants opaques).
    static func isEncodedPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { unreserved.contains($0) }
        }
    }
}

/// Version de clé d'un appareil : 1 au départ, +1 à chaque recertification
/// (`PUT …/certificate`, lot A1). Un nombre JSON entier et positif, jamais un booléen.
enum E2EEV2DeviceKeyVersion {
    static func parse(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = value as? Int, Double(version) == number.doubleValue,
              (1...1_000_000).contains(version) else { return nil }
        return version
    }
}

enum E2EEV2TransportFailureKind: Equatable, Sendable {
    case authentication
    case retryable
    case activationBlocked
    case permanent
    case localState
}

struct E2EEV2TransportFailure: Error, Equatable, Sendable {
    let kind: E2EEV2TransportFailureKind
    let statusCode: Int?
    let code: String?
    let message: String
    /// `details` de l'erreur (E.0), aujourd'hui seulement pour
    /// `E2EE_DEVICE_LIST_STALE` : les membres dont relire l'identité.
    let details: [String: JSONValue]?

    init(
        kind: E2EEV2TransportFailureKind,
        statusCode: Int? = nil,
        code: String? = nil,
        message: String,
        details: [String: JSONValue]? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.details = details
    }

    /// `E2EE_DEVICE_LIST_STALE` : `details.userIds`, à défaut `details.userId`.
    var staleUserIds: [String] {
        guard code == "E2EE_DEVICE_LIST_STALE", let details else { return [] }
        if case .array(let values)? = details["userIds"] {
            let ids = values.compactMap { value -> String? in
                if case .string(let id) = value, E2EEV2Canonical.isOpaque(id) { return id }
                return nil
            }
            if !ids.isEmpty { return ids }
        }
        if case .string(let id)? = details["userId"], E2EEV2Canonical.isOpaque(id) { return [id] }
        return []
    }
}

enum E2EEV2TransportResult<Value: Sendable>: Sendable {
    case success(value: Value, statusCode: Int, idempotentReplay: Bool)
    case failure(E2EEV2TransportFailure)
}

enum E2EEV2RequestCapabilitySet: Sendable {
    case preview
    case deviceLifecycle
    case message
    case media
    case history
    case calls

    var values: Set<String> {
        switch self {
        case .preview:
            return [E2EEV2ActivationPolicy.contractPreviewCapability]
        case .deviceLifecycle:
            return [
                E2EEV2ActivationPolicy.contractPreviewCapability,
                E2EEV2ActivationPolicy.deviceIdentityCapability,
            ]
        case .message:
            return [
                E2EEV2ActivationPolicy.contractPreviewCapability,
                E2EEV2ActivationPolicy.deviceIdentityCapability,
                E2EEV2ActivationPolicy.messageEnvelopeCapability,
            ]
        case .media:
            return [
                E2EEV2ActivationPolicy.contractPreviewCapability,
                E2EEV2ActivationPolicy.deviceIdentityCapability,
                E2EEV2ActivationPolicy.messageEnvelopeCapability,
                E2EEV2ActivationPolicy.encryptedMediaCapability,
            ]
        case .history:
            return [
                E2EEV2ActivationPolicy.contractPreviewCapability,
                E2EEV2ActivationPolicy.deviceIdentityCapability,
                E2EEV2ActivationPolicy.messageEnvelopeCapability,
                E2EEV2ActivationPolicy.historyMigrationCapability,
            ]
        case .calls:
            return [
                E2EEV2ActivationPolicy.contractPreviewCapability,
                E2EEV2ActivationPolicy.deviceIdentityCapability,
                E2EEV2ActivationPolicy.messageEnvelopeCapability,
                E2EEV2ActivationPolicy.verifiedCallsCapability,
            ]
        }
    }
}

enum E2EEV2TransportFailurePolicy {
    private static let activationCodes: Set<String> = [
        "E2EE_V2_PREVIEW_REQUIRED",
        "E2EE_V2_SECURITY_REVIEW_REQUIRED",
        "E2EE_STORAGE_NOT_CONFIGURED",
    ]
    private static let retryableConflictCodes: Set<String> = [
        "E2EE_REQUEST_REPLAYED",
        "E2EE_BLOB_INIT_RACE",
    ]

    static func classify(statusCode: Int, code: String?) -> E2EEV2TransportFailureKind {
        if statusCode == 426 || code.map(activationCodes.contains) == true { return .activationBlocked }
        if statusCode == 401 { return .authentication }
        if code.map(retryableConflictCodes.contains) == true { return .retryable }
        if [408, 425, 429].contains(statusCode) || (500...599).contains(statusCode) {
            return .retryable
        }
        return .permanent
    }
}

/// Transport à tentative unique. Chaque reprise est orchestrée au niveau de
/// l'outbox afin de produire un nouveau timestamp, nonce et signature.
final class E2EEV2APITransport: @unchecked Sendable {
    static let maxBinaryPartBytes: Int64 = 8 * 1_024 * 1_024
    static let maxJSONResponseBytes = E2EEV2WireLimits.maxJSONResponseBytes
    static let maxErrorResponseBytes = 32 * 1_024

    private let api: APIClient
    private let identityStore: E2EEV2DeviceIdentityStore
    private let expectedSession: LocalAccountSession?

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        expectedSession: LocalAccountSession? = nil
    ) {
        self.api = api
        self.identityStore = identityStore
        self.expectedSession = expectedSession
    }

    func bound(to session: LocalAccountSession) -> E2EEV2APITransport {
        E2EEV2APITransport(api: api, identityStore: identityStore, expectedSession: session)
    }

    func getJSON(
        path: String,
        query: [URLQueryItem] = [],
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> E2EEV2TransportResult<Data> {
        await execute(
            path: path,
            query: query,
            method: .get,
            body: nil,
            contentType: nil,
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet
        )
    }

    /// Lecture par session, sans signature (E.0 : la requête signée vaut pour
    /// les écritures) : lire le paquet de confiance d'un membre ne crée jamais
    /// d'identité d'appareil ici.
    func getSessionJSON(
        path: String,
        query: [URLQueryItem] = [],
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> E2EEV2TransportResult<Data> {
        await execute(
            path: path,
            query: query,
            method: .get,
            body: nil,
            contentType: nil,
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet,
            signs: false
        )
    }

    func postJSON(
        path: String,
        body: Data,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> E2EEV2TransportResult<Data> {
        guard body.count <= Self.maxJSONResponseBytes else {
            return localFailure("oversized-e2ee-json-request")
        }
        return await execute(
            path: path,
            method: .post,
            body: body,
            contentType: "application/json; charset=utf-8",
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet
        )
    }

    func postJSONWithResetCandidate(
        path: String,
        body: Data,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> E2EEV2TransportResult<Data> {
        guard body.count <= Self.maxJSONResponseBytes else {
            return localFailure("oversized-e2ee-json-request")
        }
        return await execute(
            path: path,
            method: .post,
            body: body,
            contentType: "application/json; charset=utf-8",
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet,
            useResetCandidate: true
        )
    }

    func putJSON(
        path: String,
        body: Data,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> E2EEV2TransportResult<Data> {
        guard body.count <= Self.maxJSONResponseBytes else {
            return localFailure("oversized-e2ee-json-request")
        }
        return await execute(
            path: path,
            method: .put,
            body: body,
            contentType: "application/json; charset=utf-8",
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet
        )
    }

    func putEncryptedFile(
        path: String,
        fileURL: URL,
        expectedOwnerScopeId: String
    ) async -> E2EEV2TransportResult<Data> {
        guard validPath(path), validOwner(expectedOwnerScopeId) else {
            return localFailure("invalid-e2ee-upload-scope")
        }
        guard let size = fileSize(fileURL), (1...Self.maxBinaryPartBytes).contains(size) else {
            return localFailure("missing-or-invalid-e2ee-ciphertext-part")
        }
        guard currentOwnerIs(expectedOwnerScopeId) else {
            return authenticationFailure("account-scope-changed")
        }

        do {
            let ownerNamespace = LocalAccountScope.storageNamespace(for: expectedOwnerScopeId)
            let bodyHash = try sha256Base64URL(fileURL)
            let proof = try E2EEV2SignedRequest.signBodyHash(
                method: HTTPMethod.put.rawValue,
                path: path,
                bodySHA256Base64URL: bodyHash,
                ownerNamespace: ownerNamespace,
                identityStore: identityStore
            )
            guard currentOwnerIs(expectedOwnerScopeId) else {
                return authenticationFailure("account-scope-changed")
            }
            let endpoint = APIEndpoint(
                path: path,
                method: .put,
                headers: requestHeaders(
                    contentType: "application/octet-stream",
                    capabilitySet: .media,
                    proof: proof
                ),
                authenticated: true,
                skipsAutoRefresh: true
            )
            let (data, response) = try await api.uploadFileSingleAttempt(endpoint, fromFile: fileURL)
            guard currentOwnerIs(expectedOwnerScopeId) else {
                return authenticationFailure("account-scope-changed")
            }
            return responseResult(data: data, response: response)
        } catch {
            return exceptionResult(error)
        }
    }

    /// Télécharge exactement une plage d'un blob E2EE déjà chiffré. La réponse
    /// reste bornée à un bloc cryptographique et chaque en-tête est vérifié
    /// avant que les octets ne soient confiés au déchiffreur portable.
    func postEncryptedBlobRange(
        path: String,
        body: Data,
        expectedOffset: Int64,
        expectedLength: Int,
        expectedTotalSize: Int64,
        expectedOwnerScopeId: String
    ) async -> E2EEV2TransportResult<Data> {
        guard validPath(path), validOwner(expectedOwnerScopeId),
              body.count <= Self.maxJSONResponseBytes,
              expectedOffset >= 0,
              expectedLength > 0,
              expectedLength <= E2EEV2BlobCrypto.cryptoChunkBytes + E2EEV2BlobCrypto.tagBytes,
              expectedTotalSize > 0,
              expectedOffset <= expectedTotalSize - Int64(expectedLength) else {
            return localFailure("invalid-e2ee-blob-range-request")
        }
        guard currentOwnerIs(expectedOwnerScopeId) else {
            return authenticationFailure("account-scope-changed")
        }

        do {
            let ownerNamespace = LocalAccountScope.storageNamespace(for: expectedOwnerScopeId)
            let bodyHash = E2EEV2SignedRequest.bodySHA256Base64URL(body)
            let proof = try E2EEV2SignedRequest.signBodyHash(
                method: HTTPMethod.post.rawValue,
                path: path,
                bodySHA256Base64URL: bodyHash,
                ownerNamespace: ownerNamespace,
                identityStore: identityStore
            )
            guard currentOwnerIs(expectedOwnerScopeId) else {
                return authenticationFailure("account-scope-changed")
            }
            var headers = requestHeaders(
                contentType: "application/json; charset=utf-8",
                capabilitySet: .media,
                proof: proof
            )
            headers["Accept"] = "application/octet-stream"
            let endpoint = APIEndpoint(
                path: path,
                method: .post,
                headers: headers,
                body: body,
                authenticated: true,
                skipsAutoRefresh: true
            )
            var (data, response) = try await api.performSingleAttempt(endpoint)
            guard currentOwnerIs(expectedOwnerScopeId) else {
                data.resetBytes(in: 0..<data.count)
                return authenticationFailure("account-scope-changed")
            }
            guard response.statusCode == 206 else {
                let bounded = data.prefix(Self.maxErrorResponseBytes)
                let decoded = try? JSONDecoder().decode(BackendErrorResponse.self, from: Data(bounded))
                let failure: E2EEV2TransportResult<Data> = .failure(.init(
                    kind: E2EEV2TransportFailurePolicy.classify(
                        statusCode: response.statusCode,
                        code: decoded?.code
                    ),
                    statusCode: response.statusCode,
                    code: decoded?.code,
                    message: decoded?.error?.isEmpty == false
                        ? decoded?.error ?? "e2ee-http-\(response.statusCode)"
                        : "e2ee-http-\(response.statusCode)"
                ))
                data.resetBytes(in: 0..<data.count)
                return failure
            }
            let expectedEnd = expectedOffset + Int64(expectedLength) - 1
            guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                == "application/octet-stream",
                  response.value(forHTTPHeaderField: "Content-Length") == String(expectedLength),
                  response.value(forHTTPHeaderField: "Content-Range")
                    == "bytes \(expectedOffset)-\(expectedEnd)/\(expectedTotalSize)",
                  data.count == expectedLength else {
                data.resetBytes(in: 0..<data.count)
                return localFailure("invalid-e2ee-blob-range-response")
            }
            return .success(value: data, statusCode: response.statusCode, idempotentReplay: false)
        } catch {
            return exceptionResult(error)
        }
    }

    private func execute(
        path: String,
        query: [URLQueryItem] = [],
        method: HTTPMethod,
        body: Data?,
        contentType: String?,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet,
        useResetCandidate: Bool = false,
        signs: Bool = true
    ) async -> E2EEV2TransportResult<Data> {
        guard validPath(path), validOwner(expectedOwnerScopeId), E2EEV2SignedTarget.isEncodedPath(path) else {
            return localFailure("invalid-e2ee-request-scope")
        }
        // A.2 (v0.4.15) : la requête part telle qu'elle est signée.
        let encodedQuery = E2EEV2SignedTarget.encodedQuery(query)
        let signedPath = path + (encodedQuery.map { "?\($0)" } ?? "")
        guard currentOwnerIs(expectedOwnerScopeId) else {
            return authenticationFailure("account-scope-changed")
        }
        do {
            let ownerNamespace = LocalAccountScope.storageNamespace(for: expectedOwnerScopeId)
            let bodyHash = E2EEV2SignedRequest.bodySHA256Base64URL(body ?? Data())
            let proof: E2EEV2SignedHeaders?
            if !signs {
                proof = nil
            } else if useResetCandidate {
                proof = try E2EEV2SignedRequest.signResetCandidateBodyHash(
                    method: method.rawValue,
                    path: signedPath,
                    bodySHA256Base64URL: bodyHash,
                    ownerNamespace: ownerNamespace,
                    identityStore: identityStore
                )
            } else {
                proof = try E2EEV2SignedRequest.signBodyHash(
                    method: method.rawValue,
                    path: signedPath,
                    bodySHA256Base64URL: bodyHash,
                    ownerNamespace: ownerNamespace,
                    identityStore: identityStore
                )
            }
            guard currentOwnerIs(expectedOwnerScopeId) else {
                return authenticationFailure("account-scope-changed")
            }
            var endpoint = APIEndpoint(
                path: path,
                method: method,
                headers: requestHeaders(
                    contentType: contentType,
                    capabilitySet: capabilitySet,
                    proof: proof
                ),
                body: body,
                authenticated: true,
                skipsAutoRefresh: true
            )
            endpoint.percentEncodedQuery = encodedQuery
            let token = expectedSession == nil ? nil : api.credentials.accessToken()
            guard expectedSession == nil || token != nil else { return authenticationFailure("e2ee-authentication-required") }
            if let expectedSession, let token, !expectedSession.matchesAuthToken(token) {
                return authenticationFailure("account-token-scope-mismatch")
            }
            let (data, response) = try await api.performSingleAttempt(
                endpoint, fixedAuthToken: token, expectedSession: expectedSession
            )
            guard currentOwnerIs(expectedOwnerScopeId) else {
                return authenticationFailure("account-scope-changed")
            }
            return responseResult(data: data, response: response)
        } catch {
            return exceptionResult(error)
        }
    }

    private func requestHeaders(
        contentType: String?,
        capabilitySet: E2EEV2RequestCapabilitySet,
        proof: E2EEV2SignedHeaders?
    ) -> [String: String] {
        var headers = proof?.values ?? [:]
        if let contentType { headers["Content-Type"] = contentType }
        headers[ClientProtocolContract.protocolVersionHeader] = String(E2EEV2ActivationPolicy.protocolVersion)
        headers[ClientProtocolContract.capabilitiesHeaderName] = capabilitySet.values.sorted().joined(separator: ",")
        return headers
    }

    private func responseResult(
        data: Data,
        response: HTTPURLResponse
    ) -> E2EEV2TransportResult<Data> {
        if (200..<300).contains(response.statusCode) {
            guard data.count <= Self.maxJSONResponseBytes else {
                return localFailure("oversized-e2ee-json-response")
            }
            let replay = response.value(forHTTPHeaderField: "X-SQ-Idempotent-Replay") == "1"
                || ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["idempotentReplay"] as? Bool == true
            return .success(value: data, statusCode: response.statusCode, idempotentReplay: replay)
        }
        let bounded = data.prefix(Self.maxErrorResponseBytes)
        let decoded = try? JSONDecoder().decode(BackendErrorResponse.self, from: Data(bounded))
        return .failure(
            E2EEV2TransportFailure(
                kind: E2EEV2TransportFailurePolicy.classify(
                    statusCode: response.statusCode,
                    code: decoded?.code
                ),
                statusCode: response.statusCode,
                code: decoded?.code,
                message: decoded?.error?.isEmpty == false
                    ? decoded?.error ?? "e2ee-http-\(response.statusCode)"
                    : "e2ee-http-\(response.statusCode)",
                details: decoded?.details
            )
        )
    }

    private func exceptionResult(_ error: Error) -> E2EEV2TransportResult<Data> {
        if let apiError = error as? APIError {
            switch apiError {
            case .missingAuthToken:
                return authenticationFailure("e2ee-authentication-required")
            case .transport, .cancelled:
                return .failure(.init(kind: .retryable, message: "e2ee-transport-unavailable"))
            default:
                return localFailure("invalid-e2ee-local-state")
            }
        }
        if error is URLError || error is CancellationError {
            return .failure(.init(kind: .retryable, message: "e2ee-transport-unavailable"))
        }
        // Verrouillé n'est pas un état local invalide : on réessaie au déverrouillage.
        if E2EEV2DeviceIdentityStore.isLocked(error) {
            return .failure(.init(kind: .retryable, message: "e2ee-device-locked"))
        }
        return localFailure("invalid-e2ee-local-state")
    }

    private func validPath(_ path: String) -> Bool {
        // Cible signée bornée (A.2) ; la requête est encodée à part.
        !path.isEmpty && path.utf8.count <= 512 && path.hasPrefix("/")
            && !path.contains("?") && !path.contains("#")
            && !path.contains("\n") && !path.contains("\r")
    }

    private func validOwner(_ ownerScopeId: String) -> Bool {
        ownerScopeId.hasPrefix("user:") && ownerScopeId.count > "user:".count
    }

    private func currentOwnerIs(_ expectedOwnerScopeId: String) -> Bool {
        expectedSession?.isCurrent != false
            && (expectedSession == nil || expectedSession?.ownerScopeId == expectedOwnerScopeId)
            && LocalAccountScope.currentUserId != nil
            && LocalAccountScope.currentOwnerScopeId == expectedOwnerScopeId
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func sha256Base64URL(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64URLEncodedNoPadding()
    }

    private func localFailure(_ message: String) -> E2EEV2TransportResult<Data> {
        .failure(.init(kind: .localState, message: message))
    }

    private func authenticationFailure(_ message: String) -> E2EEV2TransportResult<Data> {
        .failure(.init(kind: .authentication, message: message))
    }
}

/// L'écriture publique reste fermée tant que les critères de sortie du jalon A
/// (spec §17 : vecteurs, tests croisés, tests d'attaque, relectures
/// indépendantes) et les capacités serveur correspondantes ne sont pas réunis.
enum E2EEV2RuntimeWriteGate {
    static let enabled = false
}

/// Exception de recette strictement locale pour les appels uniquement. Elle ne
/// change pas `E2EEV2RuntimeWriteGate` et ne peut donc ouvrir ni messages, ni
/// médias, ni migration E2EE. En Release, le compilateur conserve toujours la
/// branche fermée, quels que soient les arguments ou URLs fournis.
enum E2EEV2CallRuntimeGate {
    static func allowsControlPlane(
        config: AppConfig = .current,
        qaArgumentEnabled: Bool = AppEnvironment.runsE2EEV2CallQA
    ) -> Bool {
        #if DEBUG
        guard qaArgumentEnabled, config.environment != .production else { return false }
        return isStrictLoopbackEndpoint(config.apiBaseURL, schemes: ["http", "https"])
        #else
        return false
        #endif
    }

    static func allowsMedia(
        liveKitURL: URL,
        config: AppConfig = .current,
        qaArgumentEnabled: Bool = AppEnvironment.runsE2EEV2CallQA
    ) -> Bool {
        #if DEBUG
        return allowsControlPlane(config: config, qaArgumentEnabled: qaArgumentEnabled)
            && isStrictLoopbackEndpoint(liveKitURL, schemes: ["ws", "wss"])
        #else
        return false
        #endif
    }

    private static func isStrictLoopbackEndpoint(_ url: URL, schemes: Set<String>) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        return true
    }
}

enum E2EEV2EnrollmentStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
}

enum E2EEV2EnrollmentResult: Sendable {
    case registered(
        descriptor: E2EEV2DeviceDescriptor,
        status: E2EEV2EnrollmentStatus,
        created: Bool
    )
    case failed(E2EEV2TransportFailure)
}

private struct E2EEV2RegisteredDeviceResponse: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        let deviceId: String
        let platform: String
        let label: String?
        let publicIdentityKeyB64: String
        let publicSigningKeyB64: String
        let identityKeyAlgorithm: String
        let signingKeyAlgorithm: String
        let keyVersion: Int
        let status: E2EEV2EnrollmentStatus
    }

    let device: Device
    let created: Bool
}

enum E2EEV2DeviceEnrollmentContract {
    static func publicDescriptorData(_ descriptor: E2EEV2DeviceDescriptor) throws -> Data {
        let object: [String: Any] = [
            "deviceId": descriptor.deviceId,
            "platform": descriptor.platform,
            "label": descriptor.label ?? NSNull(),
            "publicIdentityKeyB64": descriptor.publicIdentityKeyB64,
            "publicSigningKeyB64": descriptor.publicSigningKeyB64,
            "identityKeyAlgorithm": descriptor.identityKeyAlgorithm,
            "signingKeyAlgorithm": descriptor.signingKeyAlgorithm,
            "keyVersion": descriptor.keyVersion,
        ]
        guard !object.keys.contains(where: { key in
                let normalized = key.lowercased()
                return normalized.contains("private")
                    || normalized.contains("secret")
                    || normalized.contains("recovery")
              }) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func parseRegistration(
        _ data: Data,
        expected: E2EEV2DeviceDescriptor
    ) -> (status: E2EEV2EnrollmentStatus, created: Bool)? {
        guard let response = try? JSONDecoder().decode(E2EEV2RegisteredDeviceResponse.self, from: data),
              response.device.deviceId == expected.deviceId,
              response.device.platform == expected.platform,
              response.device.label == expected.label,
              response.device.publicIdentityKeyB64 == expected.publicIdentityKeyB64,
              response.device.publicSigningKeyB64 == expected.publicSigningKeyB64,
              response.device.identityKeyAlgorithm == expected.identityKeyAlgorithm,
              response.device.signingKeyAlgorithm == expected.signingKeyAlgorithm,
              response.device.keyVersion == expected.keyVersion else { return nil }
        return (response.device.status, response.created)
    }
}

/// Enrôlement de prévisualisation uniquement. Le serveur crée un appareil
/// `pending`; l'approbation distincte reste obligatoire avant tout contenu v2.
final class E2EEV2DeviceEnrollmentCoordinator: @unchecked Sendable {
    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) {
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        self.identityStore = identityStore
    }

    func registerPendingDevice(label: String?) async -> E2EEV2EnrollmentResult {
        guard LocalAccountScope.currentUserId != nil else {
            return localFailure("authenticated-account-required")
        }
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        let ownerNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        do {
            let descriptor = try identityStore.loadOrCreate(
                ownerNamespace: ownerNamespace,
                label: label
            )
            let body = try E2EEV2DeviceEnrollmentContract.publicDescriptorData(descriptor)
            let result = await transport.postJSON(
                path: "/api/e2ee/v2/devices",
                body: body,
                expectedOwnerScopeId: ownerScopeId,
                // Le serveur exige l'identité d'appareil v2 pour enrôler (essai local du 04/10).
                capabilitySet: .deviceLifecycle
            )
            switch result {
            case .failure(let failure):
                return .failed(failure)
            case .success(let response, _, _):
                guard let parsed = E2EEV2DeviceEnrollmentContract.parseRegistration(
                    response,
                    expected: descriptor
                ) else {
                    return localFailure("invalid-e2ee-device-registration-response")
                }
                return .registered(
                    descriptor: descriptor,
                    status: parsed.status,
                    created: parsed.created
                )
            }
        } catch {
            return localFailure("e2ee-device-identity-unavailable")
        }
    }

    private func localFailure(_ message: String) -> E2EEV2EnrollmentResult {
        .failed(.init(kind: .localState, message: message))
    }
}

// MARK: - E2EE v2 approved-device lifecycle (preview, fail-closed)

enum E2EEV2ApprovalMethod: String, Equatable, Sendable {
    case push = "PUSH"
    case qr = "QR"
    case proximityCode = "PROXIMITY_CODE"

    var wireValue: String { rawValue.lowercased() }

    static func fromWire(_ value: Any?) -> Self? {
        guard let raw = value as? String else { return nil }
        return Self(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

enum E2EEV2ApprovalStatus: String, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case expired
}

enum E2EEV2RemoteDeviceStatus: String, Equatable, Sendable {
    case pending
    case approved
    case revoked
}

struct E2EEV2RemoteDevice: Equatable, Sendable {
    let descriptor: E2EEV2DeviceDescriptor
    let status: E2EEV2RemoteDeviceStatus
    let approvedAt: String?
    let revokedAt: String?
    let lastSeenAt: String?
    let createdAt: String

    var signingKeyFingerprint: String {
        guard let bytes = Data(base64EncodedTolerant: descriptor.publicSigningKeyB64) else { return "" }
        return SHA256.hash(data: bytes).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

struct E2EEV2Approval: Equatable, Sendable {
    let id: String
    let pendingDeviceId: String
    let method: E2EEV2ApprovalMethod
    let challengeB64URL: String?
    let proximityCode: String?
    let status: E2EEV2ApprovalStatus
    let expiresAt: String
    let createdAt: String
}

struct E2EEV2ApprovalDetail: Equatable, Sendable {
    let approval: E2EEV2Approval
    let pendingDevice: E2EEV2RemoteDevice
    /// Dépôt de confiance (lot A1), lu par l'appareil en attente une fois
    /// approuvé ; nil avant, après consommation ou expiration, et pour un autre lecteur.
    var trust: E2EEV2ApprovalTrustDeposit? = nil
}

/// Ce que l'approbateur a déposé pour le nouvel appareil (E.1) : son
/// certificat et la liste qui le porte, et l'UIK enveloppée (jamais pour un navigateur).
struct E2EEV2ApprovalTrustDeposit: Equatable, Sendable {
    let certificate: E2EEV2SignedString
    let deviceList: E2EEV2SignedString
    let deviceEntries: [String]
    let uikWrap: E2EEV2UIKWrap?
}

/// QR v3 (D.13) lu par l'approbateur : la plateforme et l'empreinte de
/// l'appareil en attente font partie de ce que l'utilisateur compare.
struct E2EEV2QRApprovalPayload: Equatable, Sendable {
    let approvalId: String
    let pendingDeviceId: String
    let platform: String
    let fingerprint: String
    let challengeB64URL: String
    let expiresAtMs: Int64
}

/// Ce que le QR scanné dit du serveur (D.13).
enum E2EEV2QRComparison: Equatable, Sendable {
    case match
    /// Une autre demande que celle du QR.
    case approvalMismatch
    /// Les clés annoncées par le serveur ne sont pas celles du QR.
    case deviceMismatch
    /// « Plateforme différente de celle affichée, approbation refusée. »
    case platformMismatch
}

struct E2EEV2ApprovalCompletion: Equatable, Sendable {
    let deviceId: String
    let approvedByDeviceId: String
    let epochRotationRequired: Bool
    let affectedConversationIds: [String]
}

struct E2EEV2RevocationOutcome: Equatable, Sendable {
    let deviceId: String
    let alreadyRevoked: Bool
    let selfRevocation: Bool
    let rotationRequired: Bool
    let affectedConversationIds: [String]
}

enum E2EEV2BootstrapReauthentication: Equatable, Sendable {
    case password(String)
    case apple(identityToken: String)
    case email(challengeId: String, code: String)
}

struct E2EEV2BootstrapEmailChallenge: Equatable, Sendable {
    let challengeId: String
    let expiresAt: String
    let maskedEmail: String
}

struct E2EEV2InitialBootstrapOutcome: Equatable, Sendable {
    let deviceId: String
    let generation: Int
    let establishmentMethod: String
    let establishedAt: String
    let alreadyBootstrapped: Bool
    let epochRotationRequired: Bool
}

struct E2EEV2IdentitySnapshot: Equatable, Sendable {
    let generation: Int
    let establishedByDeviceId: String
    let establishmentMethod: String
    let establishedAt: String
    let lastResetAt: String?
}

struct E2EEV2DeviceInventory: Equatable, Sendable {
    let protocolVersion: Int
    let activationEnabled: Bool
    let activationBlockReason: String?
    let identity: E2EEV2IdentitySnapshot?
    let devices: [E2EEV2RemoteDevice]
}

struct E2EEV2IdentityResetEmailChallenge: Equatable, Sendable {
    let challengeId: String
    let expiresAt: String
    let maskedEmail: String
    let expectedGeneration: Int
    let replacementDeviceId: String
}

/// Lot A2 (D.14) : une réinitialisation demandée par un autre appareil du
/// compte, vérifiée (signature de la nouvelle UIK, compte, échéance à venir).
struct E2EEV2PendingIdentityResetReview: Equatable, Sendable {
    let resetId: String
    let document: E2EEV2IdentityReset
}

/// Lot A2 (§2.4, D.14) : l'état d'une réinitialisation, tel que servi par
/// `POST /identity/reset`, `GET …/{resetId}` et l'opposition. Rien ne bascule
/// à la demande : le serveur bascule à l'échéance, sauf opposition.
struct E2EEV2IdentityResetStatus: Equatable, Sendable {
    enum State: String, Sendable { case pending, completed, objected, aborted }

    /// `nil` avec `reset` : reçu perdu, bascule constatée dans le paquet de
    /// confiance du compte, vérifié sous la nouvelle UIK détenue ici.
    let resetId: String?
    let state: State
    let replacementDeviceId: String
    let reset: E2EEV2SignedString?
    let effectiveAtMs: Int64
    let objectingDeviceId: String?
    let abortReason: String?
}

enum E2EEV2DeviceApprovalContract {
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    private static let challengePattern = #"^[A-Za-z0-9_-]{43}\z"#
    private static let proximityPattern = #"^[0-9A-HJKMNP-TV-Z]{16}\z"#
    private static let challengeTTL: Int64 = 10 * 60 * 1_000
    private static let revocationReasons: Set<String> = ["LOST", "REPLACED", "COMPROMISED", "USER_REQUEST"]

    static func approvalRequestData(deviceId: String, method: E2EEV2ApprovalMethod) throws -> Data {
        guard validOpaqueId(deviceId) else { throw E2EEV2DeviceIdentityError.invalidRecord }
        return try JSONSerialization.data(
            withJSONObject: ["pendingDeviceId": deviceId, "method": method.rawValue],
            options: [.sortedKeys]
        )
    }

    /// `trust` : certificat, liste suivante et UIK chiffrée du nouvel appareil
    /// (E.1), ajoutés seulement quand le serveur les accepte.
    static func approvalCompletionData(
        _ detail: E2EEV2ApprovalDetail,
        trust: E2EEV2DeviceApprovalTrust.Artifacts? = nil
    ) throws -> Data {
        guard detail.approval.status == .pending else { throw E2EEV2DeviceIdentityError.invalidRecord }
        var object: [String: Any] = ["pendingDeviceId": detail.approval.pendingDeviceId]
        if let trust {
            guard trust.uikWrap.map({ $0.newDeviceId == detail.approval.pendingDeviceId }) ?? (detail.pendingDevice.descriptor.platform == "web") else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            object.merge(trust.approveFields) { current, _ in current }
        }
        switch detail.approval.method {
        case .proximityCode:
            guard let code = normalizeProximityCode(detail.approval.proximityCode) else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            object["proximityCode"] = code
        case .push, .qr:
            guard let challenge = detail.approval.challengeB64URL, validChallenge(challenge) else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            object["challengeB64Url"] = challenge
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func proximityResolveData(_ rawCode: String) throws -> Data {
        guard let code = normalizeProximityCode(rawCode) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return try JSONSerialization.data(withJSONObject: ["proximityCode": code], options: [.sortedKeys])
    }

    /// `trust` : la liste suivante sans l'appareil (E.1), ajoutée seulement
    /// quand le serveur l'accepte.
    static func revocationData(
        reason: String,
        trust: E2EEV2DeviceRevocationTrust.Artifacts? = nil
    ) throws -> Data {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard revocationReasons.contains(normalized) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        var object: [String: Any] = ["version": 1, "reason": normalized]
        if let trust {
            object.merge(trust.revokeFields) { current, _ in current }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func bootstrapEmailChallengeData(deviceId: String) throws -> Data {
        guard validOpaqueId(deviceId) else { throw E2EEV2DeviceIdentityError.invalidRecord }
        return try JSONSerialization.data(
            withJSONObject: ["version": 1, "deviceId": deviceId],
            options: [.sortedKeys]
        )
    }

    /// `trust` : UIK, certificat et liste v1 du premier appareil (E.1), ajoutés
    /// seulement quand le serveur les accepte ; sans eux, le corps est inchangé.
    static func initialBootstrapData(
        deviceId: String,
        reauthentication: E2EEV2BootstrapReauthentication,
        trust: E2EEV2InitialTrust.Artifacts? = nil
    ) throws -> Data {
        guard validOpaqueId(deviceId) else { throw E2EEV2DeviceIdentityError.invalidRecord }
        var body: [String: Any] = [
            "version": 1,
            "deviceId": deviceId,
            "reauthentication": try reauthenticationObject(reauthentication),
        ]
        if let trust {
            body.merge(trust.bootstrapFields) { current, _ in current }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func identityResetEmailChallengeData(
        expectedGeneration: Int,
        replacementDevice: E2EEV2DeviceDescriptor
    ) throws -> Data {
        guard (1..<Int(Int32.max)).contains(expectedGeneration) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "expectedGeneration": expectedGeneration,
                "replacementDevice": try publicDescriptorObject(replacementDevice),
            ],
            options: [.sortedKeys]
        )
    }

    static func identityResetData(
        expectedGeneration: Int,
        replacementDevice: E2EEV2DeviceDescriptor,
        reauthentication: E2EEV2BootstrapReauthentication,
        trust: E2EEV2IdentityResetTrust.Artifacts
    ) throws -> Data {
        guard (1..<Int(Int32.max)).contains(expectedGeneration) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "expectedGeneration": expectedGeneration,
                "replacementDevice": try publicDescriptorObject(replacementDevice),
                "confirmation": "RESET_E2EE_IDENTITY",
                "acknowledgements": [
                    "historicalContentUnrecoverable": true,
                    "otherDevicesWillBeRevoked": true,
                    "recoveryWillBeReplaced": true,
                ],
                "reauthentication": try reauthenticationObject(reauthentication),
                "reset": ["reset": trust.reset.canonical, "signatureB64": trust.reset.signatureB64],
                "certificate": ["certificate": trust.certificate.canonical, "signatureB64": trust.certificate.signatureB64],
                "deviceList": [
                    "list": trust.deviceList.canonical, "signatureB64": trust.deviceList.signatureB64,
                    "devices": trust.deviceEntries,
                ],
            ],
            options: [.sortedKeys]
        )
    }

    /// Corps exact de `POST /identity/reset/{resetId}/objection`.
    static func identityResetObjectionData(_ objection: E2EEV2SignedString) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["objection": objection.canonical, "signatureB64": objection.signatureB64],
            options: [.sortedKeys]
        )
    }

    private static func reauthenticationObject(
        _ reauthentication: E2EEV2BootstrapReauthentication
    ) throws -> [String: Any] {
        switch reauthentication {
        case .password(let password):
            guard !password.isEmpty, password.count <= 1_024 else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            return ["method": "password", "password": password]
        case .apple(let identityToken):
            let token = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (16...20_000).contains(token.count),
                  !token.contains("\n"),
                  !token.contains("\r") else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            return ["method": "apple", "identityToken": token]
        case .email(let challengeId, let code):
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validOpaqueId(challengeId), matches(normalizedCode, #"^\d{6}\z"#) else {
                throw E2EEV2DeviceIdentityError.invalidRecord
            }
            return ["method": "email", "challengeId": challengeId, "code": normalizedCode]
        }
    }

    private static func publicDescriptorObject(
        _ descriptor: E2EEV2DeviceDescriptor
    ) throws -> [String: Any] {
        let data = try E2EEV2DeviceEnrollmentContract.publicDescriptorData(descriptor)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        return value
    }

    static func normalizeProximityCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        return matches(normalized, proximityPattern) ? normalized : nil
    }

    /// QR v3 affiché par l'appareil en attente, avec sa plateforme et
    /// l'empreinte de ses deux clés (D.13).
    static func encodeQRPayload(_ approval: E2EEV2Approval, device: E2EEV2DeviceDescriptor) throws -> String {
        guard approval.method == .qr,
              approval.status == .pending,
              validOpaqueId(approval.id),
              validOpaqueId(approval.pendingDeviceId),
              approval.pendingDeviceId == device.deviceId,
              let challenge = approval.challengeB64URL,
              validChallenge(challenge),
              let expiresAt = parseISO8601(approval.expiresAt),
              let fingerprint = fingerprint(of: device) else {
            throw E2EEV2DeviceIdentityError.invalidRecord
        }
        let qr = E2EEV2ApprovalV2.QR(
            approvalId: approval.id,
            pendingDeviceId: approval.pendingDeviceId,
            platform: device.platform,
            fingerprint: fingerprint,
            challengeB64Url: challenge,
            expiresAtMs: Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded())
        )
        guard E2EEV2ApprovalV2.QR.parse(qr.payload) == qr else { throw E2EEV2DeviceIdentityError.invalidRecord }
        return qr.payload
    }

    /// Lecture stricte du QR v3 ; une autre version est refusée, jamais devinée.
    static func parseQRPayload(
        _ raw: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2QRApprovalPayload? {
        guard let qr = E2EEV2ApprovalV2.QR.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              validChallenge(qr.challengeB64Url),
              qr.expiresAtMs > nowMs,
              qr.expiresAtMs - nowMs <= challengeTTL else { return nil }
        return .init(
            approvalId: qr.approvalId,
            pendingDeviceId: qr.pendingDeviceId,
            platform: qr.platform,
            fingerprint: qr.fingerprint,
            challengeB64URL: qr.challengeB64Url,
            expiresAtMs: qr.expiresAtMs
        )
    }

    static func fingerprint(of device: E2EEV2DeviceDescriptor) -> String? {
        guard let identity = Data(base64Encoded: device.publicIdentityKeyB64),
              let signing = Data(base64Encoded: device.publicSigningKeyB64) else { return nil }
        return E2EEV2Canonical.deviceFingerprint(identityKeyX963: identity, signingKeyX963: signing)
    }

    static func parseApprovalCreation(_ data: Data) -> E2EEV2Approval? {
        guard let root = dictionary(data), let value = root["approval"] as? [String: Any] else { return nil }
        return parseApproval(value)
    }

    static func parseApprovalDetail(_ data: Data) -> E2EEV2ApprovalDetail? {
        guard let root = dictionary(data),
              let approvalObject = root["approval"] as? [String: Any],
              let deviceObject = root["pendingDevice"] as? [String: Any],
              let approval = parseApproval(approvalObject),
              let device = parseDevice(deviceObject),
              approval.pendingDeviceId == device.descriptor.deviceId else { return nil }
        // Lot A1 : les trois clés du dépôt sont toujours présentes, nulles ou
        // remplies ensemble ; l'UIK seule reste nulle pour un navigateur.
        let trustKeys = ["certificate", "deviceList", "uikWrap"]
        guard Set(root.keys) == Set(["approval", "pendingDevice"]) || Set(root.keys) == Set(["approval", "pendingDevice"] + trustKeys)
        else { return nil }
        guard Set(root.keys).isSuperset(of: trustKeys) else { return .init(approval: approval, pendingDevice: device) }
        let certificate = root["certificate"], list = root["deviceList"], wrap = root["uikWrap"]
        if certificate is NSNull, list is NSNull, wrap is NSNull {
            return .init(approval: approval, pendingDevice: device)
        }
        guard approval.status == .approved,
              let certificateObject = certificate as? [String: Any],
              Set(certificateObject.keys) == ["certificate", "signatureB64"],
              let certificateCanonical = certificateObject["certificate"] as? String,
              let certificateSignature = certificateObject["signatureB64"] as? String,
              let listObject = list as? [String: Any],
              Set(listObject.keys) == ["list", "signatureB64", "devices"],
              let listCanonical = listObject["list"] as? String,
              let listSignature = listObject["signatureB64"] as? String,
              let entries = listObject["devices"] as? [String], !entries.isEmpty, entries.count <= 500 else { return nil }
        let uikWrap: E2EEV2UIKWrap?
        if wrap is NSNull {
            guard device.descriptor.platform == "web" else { return nil }
            uikWrap = nil
        } else {
            guard device.descriptor.platform != "web", let wrapObject = wrap as? [String: Any],
                  let parsed = parseUIKWrap(wrapObject),
                  parsed.newDeviceId == device.descriptor.deviceId else { return nil }
            uikWrap = parsed
        }
        return .init(
            approval: approval, pendingDevice: device,
            trust: .init(
                certificate: .init(canonical: certificateCanonical, signatureB64: certificateSignature),
                deviceList: .init(canonical: listCanonical, signatureB64: listSignature),
                deviceEntries: entries, uikWrap: uikWrap
            )
        )
    }

    /// Exactement les neuf clés de D.5.
    static func parseUIKWrap(_ value: [String: Any]) -> E2EEV2UIKWrap? {
        let keys = ["userId", "approverDeviceId", "newDeviceId", "uikPublicKeyB64", "ephemeralPublicKeyB64",
                    "nonceB64", "aadB64", "wrappedUikB64", "signatureB64"]
        guard Set(value.keys) == Set(keys) else { return nil }
        let strings = keys.compactMap { value[$0] as? String }
        guard strings.count == keys.count, strings.allSatisfy({ !$0.isEmpty }),
              validOpaqueId(strings[1]), validOpaqueId(strings[2]) else { return nil }
        return .init(
            userId: strings[0], approverDeviceId: strings[1], newDeviceId: strings[2], uikPublicKeyB64: strings[3],
            ephemeralPublicKeyB64: strings[4], nonceB64: strings[5], aadB64: strings[6], wrappedUikB64: strings[7],
            signatureB64: strings[8]
        )
    }

    static func parseDevices(_ data: Data) -> [E2EEV2RemoteDevice]? {
        guard let root = dictionary(data),
              let values = root["devices"] as? [[String: Any]],
              values.count <= 50 else { return nil }
        let devices = values.compactMap(parseDevice)
        guard devices.count == values.count,
              Set(devices.map(\.descriptor.deviceId)).count == devices.count else { return nil }
        return devices
    }

    static func parseDeviceInventory(_ data: Data) -> E2EEV2DeviceInventory? {
        guard let root = dictionary(data),
              root["protocolVersion"] as? Int == 2,
              let activationEnabled = root["activationEnabled"] as? Bool,
              root.keys.contains("activationBlockReason"),
              root.keys.contains("identity"),
              let devices = parseDevices(data) else { return nil }
        let activationBlockReason = nullableString(root["activationBlockReason"])
        guard activationBlockReason.map({ !$0.isEmpty && $0.count <= 120 }) ?? activationEnabled else {
            return nil
        }
        let identity: E2EEV2IdentitySnapshot?
        if root["identity"] is NSNull {
            identity = nil
        } else {
            guard let value = root["identity"] as? [String: Any],
                  let generation = value["generation"] as? Int,
                  generation >= 1,
                  let establishedByDeviceId = value["establishedByDeviceId"] as? String,
                  validOpaqueId(establishedByDeviceId),
                  let method = value["establishmentMethod"] as? String,
                  ["account_reauth", "recovery_key", "identity_reset"].contains(method),
                  let establishedAt = value["establishedAt"] as? String,
                  parseISO8601(establishedAt) != nil,
                  value.keys.contains("lastResetAt"),
                  validOptionalISO(value["lastResetAt"]),
                  devices.contains(where: { $0.descriptor.deviceId == establishedByDeviceId }) else {
                return nil
            }
            identity = .init(
                generation: generation,
                establishedByDeviceId: establishedByDeviceId,
                establishmentMethod: method,
                establishedAt: establishedAt,
                lastResetAt: nullableString(value["lastResetAt"])
            )
        }
        return .init(
            protocolVersion: 2,
            activationEnabled: activationEnabled,
            activationBlockReason: activationBlockReason,
            identity: identity,
            devices: devices
        )
    }

    static func parseCompletion(_ data: Data) -> E2EEV2ApprovalCompletion? {
        guard let root = dictionary(data),
              let device = root["device"] as? [String: Any],
              let deviceId = device["deviceId"] as? String,
              let approvedByDeviceId = device["approvedByDeviceId"] as? String,
              validOpaqueId(deviceId),
              validOpaqueId(approvedByDeviceId),
              (device["status"] as? String)?.lowercased() == E2EEV2RemoteDeviceStatus.approved.rawValue,
              let rotation = root["epochRotationRequired"] as? Bool,
              let affected = root["affectedConversationIds"] as? [String],
              affected.allSatisfy(validOpaqueId),
              rotation == !affected.isEmpty else { return nil }
        return .init(
            deviceId: deviceId,
            approvedByDeviceId: approvedByDeviceId,
            epochRotationRequired: rotation,
            affectedConversationIds: affected
        )
    }

    /// `PUT …/certificate` (E.1) : `{deviceId, keyVersion, deviceListVersion}`,
    /// entiers en chaînes décimales (D.0).
    static func parseRecertification(_ data: Data, expected: E2EEV2DeviceIdentityStore.AgreementKeyRotation) -> Bool {
        guard let root = dictionary(data),
              Set(root.keys) == ["deviceId", "keyVersion", "deviceListVersion"],
              root["deviceId"] as? String == expected.deviceId,
              root["keyVersion"] as? String == String(expected.keyVersion),
              let listVersion = root["deviceListVersion"] as? String,
              E2EEV2Canonical.sequenceNumber(listVersion) != nil else { return false }
        return true
    }

    static func parseRevocation(_ data: Data) -> E2EEV2RevocationOutcome? {
        guard let root = dictionary(data),
              root["revoked"] as? Bool == true,
              let deviceId = root["deviceId"] as? String,
              validOpaqueId(deviceId),
              let alreadyRevoked = root["alreadyRevoked"] as? Bool,
              let selfRevocation = root["selfRevocation"] as? Bool,
              let rotationRequired = root["rotationRequired"] as? Bool,
              let affected = root["affectedConversationIds"] as? [String],
              affected.allSatisfy(validOpaqueId) else { return nil }
        return .init(
            deviceId: deviceId,
            alreadyRevoked: alreadyRevoked,
            selfRevocation: selfRevocation,
            rotationRequired: rotationRequired,
            affectedConversationIds: affected
        )
    }

    static func parseBootstrapEmailChallenge(
        _ data: Data,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2BootstrapEmailChallenge? {
        guard let root = dictionary(data),
              let challengeId = root["challengeId"] as? String,
              validOpaqueId(challengeId),
              let expiresAt = root["expiresAt"] as? String,
              let expiry = parseISO8601(expiresAt),
              let maskedEmail = root["maskedEmail"] as? String,
              (5...254).contains(maskedEmail.count),
              maskedEmail.contains("@"),
              !maskedEmail.contains("\n"),
              !maskedEmail.contains("\r") else { return nil }
        let expiryMs = Int64((expiry.timeIntervalSince1970 * 1_000).rounded())
        guard expiryMs > nowMs, expiryMs - nowMs <= challengeTTL else { return nil }
        return .init(challengeId: challengeId, expiresAt: expiresAt, maskedEmail: maskedEmail)
    }

    static func parseInitialBootstrap(
        _ data: Data,
        expectedDeviceId: String
    ) -> E2EEV2InitialBootstrapOutcome? {
        guard validOpaqueId(expectedDeviceId),
              let root = dictionary(data),
              let device = root["device"] as? [String: Any],
              device["deviceId"] as? String == expectedDeviceId,
              (device["status"] as? String)?.lowercased() == E2EEV2RemoteDeviceStatus.approved.rawValue,
              device["approvedByDeviceId"] is NSNull,
              let identity = root["identity"] as? [String: Any],
              let generation = identity["generation"] as? Int,
              generation >= 1,
              identity["establishmentMethod"] as? String == "account_reauth",
              let establishedAt = identity["establishedAt"] as? String,
              parseISO8601(establishedAt) != nil,
              let alreadyBootstrapped = root["alreadyBootstrapped"] as? Bool,
              root["epochRotationRequired"] as? Bool == false else { return nil }
        return .init(
            deviceId: expectedDeviceId,
            generation: generation,
            establishmentMethod: "account_reauth",
            establishedAt: establishedAt,
            alreadyBootstrapped: alreadyBootstrapped,
            epochRotationRequired: false
        )
    }

    static func parseIdentityResetEmailChallenge(
        _ data: Data,
        expectedGeneration: Int,
        expectedReplacementDeviceId: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2IdentityResetEmailChallenge? {
        guard expectedGeneration >= 1,
              validOpaqueId(expectedReplacementDeviceId),
              let root = dictionary(data),
              let challengeId = root["challengeId"] as? String,
              validOpaqueId(challengeId),
              let expiresAt = root["expiresAt"] as? String,
              let expiry = parseISO8601(expiresAt),
              let maskedEmail = root["maskedEmail"] as? String,
              (5...254).contains(maskedEmail.count),
              maskedEmail.contains("@"),
              !maskedEmail.contains("\n"),
              !maskedEmail.contains("\r"),
              root["expectedGeneration"] as? Int == expectedGeneration,
              root["replacementDeviceId"] as? String == expectedReplacementDeviceId else {
            return nil
        }
        let expiryMs = Int64((expiry.timeIntervalSince1970 * 1_000).rounded())
        guard expiryMs > nowMs, expiryMs - nowMs <= challengeTTL else { return nil }
        return .init(
            challengeId: challengeId,
            expiresAt: expiresAt,
            maskedEmail: maskedEmail,
            expectedGeneration: expectedGeneration,
            replacementDeviceId: expectedReplacementDeviceId
        )
    }

    /// La vue d'une réinitialisation, clés exactes (E.1). `expectedReplacementDeviceId`
    /// et `expectedResetId` : ce que cet appareil a demandé ou vise, quand il le sait.
    static func parseIdentityResetView(
        _ data: Data,
        expectedReplacementDeviceId: String? = nil,
        expectedResetId: String? = nil
    ) -> E2EEV2IdentityResetStatus? {
        let keys: Set<String> = [
            "resetId", "status", "replacementDeviceId", "reset", "effectiveAtMs", "objection",
            "objectingDeviceId", "resolvedAt", "abortReason",
        ]
        guard let root = dictionary(data), Set(root.keys) == keys,
              let resetId = root["resetId"] as? String, validOpaqueId(resetId),
              expectedResetId.map({ $0 == resetId }) ?? true,
              let state = (root["status"] as? String).flatMap(E2EEV2IdentityResetStatus.State.init(rawValue:)),
              let replacementDeviceId = root["replacementDeviceId"] as? String, validOpaqueId(replacementDeviceId),
              expectedReplacementDeviceId.map({ $0 == replacementDeviceId }) ?? true,
              let reset = root["reset"] as? [String: Any], Set(reset.keys) == ["reset", "signatureB64"],
              let resetText = reset["reset"] as? String, let resetSignature = reset["signatureB64"] as? String,
              let effectiveText = root["effectiveAtMs"] as? String, E2EEV2Canonical.isDecimal(effectiveText),
              let effectiveAtMs = Int64(effectiveText),
              root["objection"] is NSNull || (root["objection"] as? [String: Any]).map({ Set($0.keys) == ["objection", "signatureB64"] }) == true,
              root["objectingDeviceId"] is NSNull || (root["objectingDeviceId"] as? String).map(validOpaqueId) == true,
              root["resolvedAt"] is NSNull || (root["resolvedAt"] as? String).flatMap(parseISO8601) != nil,
              root["abortReason"] is NSNull || root["abortReason"] is String,
              (state == .pending) == (root["resolvedAt"] is NSNull),
              (state == .objected) == !(root["objectingDeviceId"] is NSNull) else { return nil }
        let signed = E2EEV2SignedString(canonical: resetText, signatureB64: resetSignature)
        // Le document doit se vérifier, et son échéance être celle servie.
        guard let document = try? E2EEV2IdentityReset.verify(signed), document.effectiveAtMs == effectiveAtMs else {
            return nil
        }
        return .init(
            resetId: resetId, state: state, replacementDeviceId: replacementDeviceId, reset: signed,
            effectiveAtMs: effectiveAtMs, objectingDeviceId: root["objectingDeviceId"] as? String,
            abortReason: root["abortReason"] as? String
        )
    }

    static func pushApprovalID(
        _ data: [String: String],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> String? {
        guard data["type"] == "e2ee_v2_device_approval",
              let id = data["approvalId"],
              validOpaqueId(id),
              let rawExpiry = data["expiresAt"],
              let expiry = parseISO8601(rawExpiry) else { return nil }
        let expiresAtMs = Int64((expiry.timeIntervalSince1970 * 1_000).rounded())
        return expiresAtMs > nowMs && expiresAtMs - nowMs <= challengeTTL ? id : nil
    }

    static func qrMatchesDetail(_ qr: E2EEV2QRApprovalPayload, _ detail: E2EEV2ApprovalDetail) -> Bool {
        compareQR(qr, detail) == .match
    }

    static func compareQR(_ qr: E2EEV2QRApprovalPayload, _ detail: E2EEV2ApprovalDetail) -> E2EEV2QRComparison {
        guard let expiry = parseISO8601(detail.approval.expiresAt),
              detail.approval.method == .qr,
              detail.approval.status == .pending,
              detail.approval.id == qr.approvalId,
              detail.approval.pendingDeviceId == qr.pendingDeviceId,
              detail.approval.challengeB64URL == qr.challengeB64URL,
              Int64((expiry.timeIntervalSince1970 * 1_000).rounded()) == qr.expiresAtMs else {
            return .approvalMismatch
        }
        let pending = detail.pendingDevice.descriptor
        guard pending.deviceId == qr.pendingDeviceId, fingerprint(of: pending) == qr.fingerprint else {
            return .deviceMismatch
        }
        // Comparaison octet à octet, sans normalisation (D.2).
        guard pending.platform == qr.platform else { return .platformMismatch }
        return .match
    }

    static func validOpaqueId(_ value: String) -> Bool { matches(value, opaquePattern) }

    private static func parseApproval(_ value: [String: Any]) -> E2EEV2Approval? {
        guard let id = value["id"] as? String,
              let pendingDeviceId = value["pendingDeviceId"] as? String,
              validOpaqueId(id),
              validOpaqueId(pendingDeviceId),
              let method = E2EEV2ApprovalMethod.fromWire(value["method"]),
              let expiresAt = value["expiresAt"] as? String,
              parseISO8601(expiresAt) != nil,
              let createdAt = value["createdAt"] as? String,
              parseISO8601(createdAt) != nil else { return nil }
        let statusRaw = (value["status"] as? String)?.lowercased() ?? "pending"
        guard let status = E2EEV2ApprovalStatus(rawValue: statusRaw) else { return nil }
        let challenge = nullableString(value["challengeB64Url"])
        let proximity = nullableString(value["proximityCode"]).flatMap(normalizeProximityCode)
        switch method {
        case .proximityCode:
            guard proximity != nil, challenge == nil else { return nil }
        case .push, .qr:
            // Une fois approuvée, le serveur efface le défi (lot A1).
            let challengeValid = challenge.map(validChallenge) ?? (status != .pending)
            guard challengeValid, proximity == nil else { return nil }
        }
        return .init(
            id: id,
            pendingDeviceId: pendingDeviceId,
            method: method,
            challengeB64URL: challenge,
            proximityCode: proximity,
            status: status,
            expiresAt: expiresAt,
            createdAt: createdAt
        )
    }

    private static func parseDevice(_ value: [String: Any]) -> E2EEV2RemoteDevice? {
        guard let deviceId = value["deviceId"] as? String,
              let platform = value["platform"] as? String,
              ["android", "ios", "web"].contains(platform),
              validOpaqueId(deviceId),
              let publicIdentity = value["publicIdentityKeyB64"] as? String,
              let publicSigning = value["publicSigningKeyB64"] as? String,
              validP256(publicIdentity),
              validP256(publicSigning),
              value["identityKeyAlgorithm"] as? String == E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
              value["signingKeyAlgorithm"] as? String == E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
              let keyVersion = E2EEV2DeviceKeyVersion.parse(value["keyVersion"]),
              let statusRaw = (value["status"] as? String)?.lowercased(),
              let status = E2EEV2RemoteDeviceStatus(rawValue: statusRaw),
              let createdAt = value["createdAt"] as? String,
              parseISO8601(createdAt) != nil,
              validOptionalISO(value["approvedAt"]),
              validOptionalISO(value["revokedAt"]),
              validOptionalISO(value["lastSeenAt"]) else { return nil }
        return .init(
            descriptor: .init(
                deviceId: deviceId,
                platform: platform,
                label: nullableString(value["label"]),
                publicIdentityKeyB64: publicIdentity,
                publicSigningKeyB64: publicSigning,
                identityKeyAlgorithm: E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
                signingKeyAlgorithm: E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
                keyVersion: keyVersion
            ),
            status: status,
            approvedAt: nullableString(value["approvedAt"]),
            revokedAt: nullableString(value["revokedAt"]),
            lastSeenAt: nullableString(value["lastSeenAt"]),
            createdAt: createdAt
        )
    }

    private static func dictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nullableString(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    private static func validOptionalISO(_ value: Any?) -> Bool {
        value == nil || value is NSNull || ((value as? String).flatMap(parseISO8601) != nil)
    }

    private static func validP256(_ value: String) -> Bool {
        guard let data = Data(base64EncodedTolerant: value) else { return false }
        return data.count == 65 && data.first == 0x04
    }

    private static func validChallenge(_ value: String) -> Bool {
        matches(value, challengePattern) && Data(base64URLEncoded: value)?.count == 32
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }
}

enum E2EEV2DeviceLifecycleResult<Value: Sendable>: Sendable {
    case success(Value)
    case failed(E2EEV2TransportFailure)
}

final class E2EEV2DeviceLifecycleCoordinator: @unchecked Sendable {
    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let epochKeyStore: E2EEV2EpochKeyStore
    private let conversationStateStore: E2EEV2ConversationStateStore
    private let mediaOutboxStore: E2EEV2MediaOutboxStore?
    private let accountIdentityStore: E2EEV2AccountIdentityStore
    private let trustPins: E2EEV2TrustPinStore
    private let capabilities: E2EEV2CapabilitiesPublicationStore
    private let appBuild: String
    private let nowMs: @Sendable () -> Int64
    private let rotationCommitted: @Sendable (LocalAccountSession, [String], Bool) -> Void
    /// Après une approbation ou une révocation réussie : le bundle de
    /// récupération est re-signé à la nouvelle liste (§2.8, v0.4.22).
    private let deviceListChanged: (@Sendable () async -> Void)?
    private let resetRefreshLock = NSLock()
    private var resetRefresh: Task<E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus>?, Never>?

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        epochKeyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        conversationStateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        mediaOutboxStore: E2EEV2MediaOutboxStore? = nil,
        accountIdentityStore: E2EEV2AccountIdentityStore = E2EEV2AccountIdentityStore(),
        trustPins: E2EEV2TrustPinStore = E2EEV2TrustPinStore(),
        capabilities: E2EEV2CapabilitiesPublicationStore = E2EEV2CapabilitiesPublicationStore(),
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        rotationCommitted: @escaping @Sendable (LocalAccountSession, [String], Bool) -> Void = {
            E2EEV2RotationEvents.recordCommitted(session: $0, conversations: $1, notify: $2)
        },
        deviceListChanged: (@Sendable () async -> Void)? = nil
    ) {
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        self.deviceListChanged = deviceListChanged
        self.identityStore = identityStore
        self.epochKeyStore = epochKeyStore
        self.conversationStateStore = conversationStateStore
        self.mediaOutboxStore = mediaOutboxStore ?? (try? E2EEV2MediaOutboxStore())
        self.accountIdentityStore = accountIdentityStore
        self.trustPins = trustPins
        self.capabilities = capabilities
        self.appBuild = appBuild
        self.nowMs = nowMs
        self.rotationCommitted = rotationCommitted
    }

    func listDevices() async -> E2EEV2DeviceLifecycleResult<[E2EEV2RemoteDevice]> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        return map(
            await transport.getJSON(
                path: "/api/e2ee/v2/devices",
                expectedOwnerScopeId: owner,
                capabilitySet: .deviceLifecycle
            ),
            parser: E2EEV2DeviceApprovalContract.parseDevices,
            invalidMessage: "invalid-e2ee-device-list"
        )
    }

    func listDeviceInventory() async -> E2EEV2DeviceLifecycleResult<E2EEV2DeviceInventory> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        return map(
            await transport.getJSON(
                path: "/api/e2ee/v2/devices",
                expectedOwnerScopeId: owner,
                capabilitySet: .deviceLifecycle
            ),
            parser: E2EEV2DeviceApprovalContract.parseDeviceInventory,
            invalidMessage: "invalid-e2ee-device-inventory"
        )
    }

    func prepareIdentityReset(label: String?) -> E2EEV2DeviceLifecycleResult<E2EEV2DeviceDescriptor> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        do {
            return .success(try identityStore.prepareResetCandidate(
                ownerNamespace: LocalAccountScope.storageNamespace(for: owner),
                label: label
            ))
        } catch {
            return localFailure("e2ee-reset-candidate-unavailable")
        }
    }

    func discardIdentityResetCandidate() -> Bool {
        guard let owner = ownerScope() else { return false }
        do {
            // Une demande envoyée (ou peut-être envoyée) nomme cet appareil : il
            // ne se jette qu'avec elle, quand elle est close.
            guard try accountIdentityStore.loadPendingReset(
                ownerNamespace: LocalAccountScope.storageNamespace(for: owner)
            ) == nil else { return false }
            try identityStore.discardResetCandidate(
                ownerNamespace: LocalAccountScope.storageNamespace(for: owner)
            )
            return true
        } catch {
            return false
        }
    }

    func requestIdentityResetEmailChallenge(
        expectedGeneration: Int
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetEmailChallenge> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        do {
            let namespace = LocalAccountScope.storageNamespace(for: owner)
            guard let candidate = try identityStore.loadResetCandidate(ownerNamespace: namespace) else {
                return localFailure("e2ee-reset-candidate-unavailable")
            }
            let body = try E2EEV2DeviceApprovalContract.identityResetEmailChallengeData(
                expectedGeneration: expectedGeneration,
                replacementDevice: candidate
            )
            return map(
                await transport.postJSONWithResetCandidate(
                    path: "/api/e2ee/v2/identity/reset/email-challenge",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: { data in
                    E2EEV2DeviceApprovalContract.parseIdentityResetEmailChallenge(
                        data,
                        expectedGeneration: expectedGeneration,
                        expectedReplacementDeviceId: candidate.deviceId
                    )
                },
                invalidMessage: "invalid-e2ee-identity-reset-email-response"
            )
        } catch {
            return localFailure("e2ee-reset-candidate-unavailable")
        }
    }

    /// Lot A2 (§2.4, D.14) : demande la réinitialisation. L'appareil de
    /// remplacement signe la requête ; la nouvelle UIK signe le document, son
    /// certificat et la liste v1. Rien ne bascule ici : la demande attend
    /// 72 heures, suivie par `refreshIdentityReset`. Une reprise renvoie
    /// toujours d'abord les mêmes textes, que le serveur rend comme un rejeu :
    /// la nouvelle UIK n'est jamais jetée tant qu'une demande peut la nommer.
    func resetIdentity(
        expectedGeneration: Int,
        reauthentication: E2EEV2BootstrapReauthentication
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let candidate = try identityStore.loadResetCandidate(ownerNamespace: namespace) else {
                return localFailure("e2ee-reset-candidate-unavailable")
            }
            var pending = try accountIdentityStore.pendingReset(ownerNamespace: namespace, nowMs: nowMs())
            if pending.resetId != nil {
                return await refreshIdentityReset() ?? localFailure("e2ee-identity-reset-unavailable")
            }
            // L'appareil de remplacement est lié à la demande avant tout envoi.
            func bindCandidate() throws -> Bool {
                if let named = pending.replacementDeviceId { return named == candidate.deviceId }
                pending.replacementDeviceId = candidate.deviceId
                try accountIdentityStore.savePendingReset(pending, ownerNamespace: namespace)
                return true
            }
            guard try bindCandidate() else { return localFailure("e2ee-reset-candidate-unavailable") }
            let previousUik = await previousAccountKey(owner: owner, userId: userId, transport: transport)
            for attempt in 0..<2 {
                guard let newUik = pending.uik else { return localFailure("e2ee-reset-candidate-unavailable") }
                let trust = try E2EEV2IdentityResetTrust.make(
                    userId: userId, device: candidate, newUik: newUik,
                    previousUikX963: previousUik, requestedAtMs: pending.requestedAtMs
                )
                let body = try E2EEV2DeviceApprovalContract.identityResetData(
                    expectedGeneration: expectedGeneration,
                    replacementDevice: candidate,
                    reauthentication: reauthentication,
                    trust: trust
                )
                switch await transport.postJSONWithResetCandidate(
                    path: "/api/e2ee/v2/identity/reset",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ) {
                case .failure(let failure):
                    // 422 : le serveur n'a rien en attente et refuse de créer à partir
                    // de ce document (trop ancien) ; un nouveau, une seule fois.
                    if attempt == 0, failure.code == "E2EE_IDENTITY_RESET_INVALID",
                       abs(nowMs() - pending.requestedAtMs) > Self.resetRetryWindowMs {
                        try accountIdentityStore.discardPendingReset(ownerNamespace: namespace)
                        pending = try accountIdentityStore.pendingReset(ownerNamespace: namespace, nowMs: nowMs())
                        guard try bindCandidate() else { return localFailure("e2ee-reset-candidate-unavailable") }
                        continue
                    }
                    return .failed(failure)
                case .success(let data, _, _):
                    guard let status = E2EEV2DeviceApprovalContract.parseIdentityResetView(
                        data, expectedReplacementDeviceId: candidate.deviceId
                    ), status.state == .pending, status.reset?.canonical == trust.reset.canonical else {
                        return localFailure("invalid-e2ee-identity-reset-response")
                    }
                    // Le reçu tient au compte, pas à la session : il est gardé même
                    // si la session a changé pendant la requête.
                    guard ownerScope() == owner else { return localFailure("e2ee-session-changed") }
                    pending.resetId = status.resetId
                    pending.effectiveAtMs = status.effectiveAtMs
                    pending.replacementDeviceId = candidate.deviceId
                    try accountIdentityStore.savePendingReset(pending, ownerNamespace: namespace)
                    return .success(status)
                }
            }
            return localFailure("e2ee-identity-reset-unavailable")
        } catch {
            return localFailure("e2ee-identity-reset-unavailable")
        }
    }

    /// Lot A2 : l'état de la réinitialisation demandée ici, `nil` s'il n'y en a
    /// pas. À la bascule (`completed`), l'appareil de remplacement et la nouvelle
    /// UIK deviennent ceux de ce téléphone ; après une opposition ou un abandon,
    /// la demande et son appareil de remplacement sont oubliés. Deux appels
    /// simultanés partagent la même lecture.
    func refreshIdentityReset() async -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus>? {
        let task: Task<E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus>?, Never> = resetRefreshLock.withLock {
            if let running = resetRefresh { return running }
            let started = Task { await self.performIdentityResetRefresh() }
            resetRefresh = started
            return started
        }
        let result = await task.value
        resetRefreshLock.withLock { if resetRefresh == task { resetRefresh = nil } }
        return result
    }

    private func performIdentityResetRefresh() async -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus>? {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else { return nil }
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        let transport = self.transport.bound(to: session)
        var pending: E2EEV2AccountIdentityStore.PendingReset
        do {
            guard let stored = try accountIdentityStore.loadPendingReset(ownerNamespace: namespace) else { return nil }
            pending = stored
        } catch {
            return localFailure("e2ee-identity-reset-unavailable")
        }
        guard let newUik = pending.uik else { return localFailure("e2ee-identity-reset-unavailable") }
        let newUikB64 = newUik.publicKey.x963Representation.base64EncodedString()
        if pending.resetId == nil {
            // Reçu perdu : le paquet de confiance du compte nomme la demande en
            // attente ; son document, signé par la nouvelle UIK détenue ici seule,
            // prouve qu'elle est la sienne.
            guard let data = try? await E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: owner)(userId, nil),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let bundle = E2EEV2IdentityBundle.parse(root, userId: userId) else {
                return localFailure("e2ee-identity-reset-unavailable")
            }
            if bundle.uikX963B64 == newUikB64 {
                // Bascule faite pendant que le reçu manquait : le paquet, vérifié sous
                // la nouvelle UIK, doit certifier l'appareil de remplacement.
                guard case .success(let outcome) = E2EEV2IdentityVerification.verify(
                          bundle, pinned: nil, expectedUIK: newUik.publicKey
                      ),
                      let replacementId = pending.replacementDeviceId,
                      outcome.devices.contains(where: { $0.deviceId == replacementId }) else {
                    return localFailure("invalid-e2ee-identity-reset-response")
                }
                let observed = E2EEV2IdentityResetStatus(
                    resetId: nil, state: .completed, replacementDeviceId: replacementId, reset: nil,
                    effectiveAtMs: pending.requestedAtMs + E2EEV2IdentityReset.delayMs,
                    objectingDeviceId: nil, abortReason: nil
                )
                return completeIdentityReset(observed, session: session, owner: owner, userId: userId, namespace: namespace)
            }
            guard let served = bundle.pendingIdentityReset,
                  let document = try? E2EEV2IdentityReset.verify(served.reset),
                  document.userId == userId, document.newUikB64 == newUikB64,
                  document.requestedAtMs == pending.requestedAtMs else {
                // Rien en attente pour cette UIK : passé le délai où le serveur pouvait
                // encore créer la demande à partir de ces textes, elle est oubliée.
                if abs(nowMs() - pending.requestedAtMs) > Self.resetClockSkewMs + Self.resetRetryWindowMs {
                    forgetIdentityReset(namespace: namespace, resetId: nil)
                }
                return nil
            }
            pending.resetId = served.resetId
            pending.effectiveAtMs = document.effectiveAtMs
            guard ownerScope() == owner else { return localFailure("e2ee-session-changed") }
            do { try accountIdentityStore.savePendingReset(pending, ownerNamespace: namespace) } catch {
                return localFailure("e2ee-identity-reset-unavailable")
            }
        }
        guard let resetId = pending.resetId else { return nil }
        let response = await transport.getSessionJSON(
            path: "/api/e2ee/v2/identity/reset/\(resetId)",
            expectedOwnerScopeId: owner,
            capabilitySet: .deviceLifecycle
        )
        let status: E2EEV2IdentityResetStatus
        switch response {
        case .failure(let failure) where failure.statusCode == 404 && failure.code == "E2EE_IDENTITY_RESET_NOT_FOUND":
            guard let served = await servedAccountKey(owner: owner, userId: userId, transport: transport),
                  served != newUikB64 else {
                return localFailure("invalid-e2ee-identity-reset-response")
            }
            forgetIdentityReset(namespace: namespace, resetId: resetId)
            return .failed(failure)
        case .failure(let failure):
            return .failed(failure)
        case .success(let data, _, _):
            guard let parsed = E2EEV2DeviceApprovalContract.parseIdentityResetView(data, expectedResetId: resetId),
                  let signed = parsed.reset, let document = try? E2EEV2IdentityReset.verify(signed),
                  document.userId == userId,
                  document.requestedAtMs == pending.requestedAtMs,
                  document.newUikB64 == newUikB64,
                  pending.replacementDeviceId.map({ $0 == parsed.replacementDeviceId }) ?? true else {
                return localFailure("invalid-e2ee-identity-reset-response")
            }
            status = parsed
        }
        switch status.state {
        case .pending:
            return .success(status)
        case .objected, .aborted:
            // Jamais oublier une UIK que le compte porte déjà, ni sur une lecture manquée.
            guard let served = await servedAccountKey(owner: owner, userId: userId, transport: transport),
                  served != newUikB64 else {
                return localFailure("invalid-e2ee-identity-reset-response")
            }
            forgetIdentityReset(namespace: namespace, resetId: resetId)
            return .success(status)
        case .completed:
            // Pas avant l'échéance (à l'écart d'horloge près), et seulement si le
            // compte porte bien la nouvelle UIK.
            guard nowMs() >= status.effectiveAtMs - Self.resetClockSkewMs,
                  await servedAccountKey(owner: owner, userId: userId, transport: transport) == newUikB64 else {
                return localFailure("invalid-e2ee-identity-reset-response")
            }
            return completeIdentityReset(status, session: session, owner: owner, userId: userId, namespace: namespace)
        }
    }

    /// La bascule côté appareil. Rejouable : chaque étape relit l'état laissé
    /// par une reprise interrompue.
    private func completeIdentityReset(
        _ status: E2EEV2IdentityResetStatus,
        session: LocalAccountSession,
        owner: String,
        userId: String,
        namespace: String
    ) -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus> {
        guard session.isCurrent else { return localFailure("e2ee-session-changed") }
        do {
            // Relu après l'attente réseau : un autre appel a pu finir la bascule.
            guard let pending = try accountIdentityStore.loadPendingReset(ownerNamespace: namespace) else {
                return .success(status)
            }
            guard pending.resetId == status.resetId else { return localFailure("e2ee-identity-reset-unavailable") }
            let replacementId = pending.replacementDeviceId ?? status.replacementDeviceId
            let candidate = try identityStore.loadResetCandidate(ownerNamespace: namespace)
            let current = try identityStore.load(ownerNamespace: namespace)
            if candidate?.deviceId == replacementId {
                // Le serveur demande une rotation de chaque conversation chiffrée :
                // la reprise relit la liste à jour (`epoch-rotation-requirements`).
                rotationCommitted(session, [], false)
                guard let mediaOutboxStore else {
                    return localFailure("e2ee-identity-reset-local-activation-pending")
                }
                try mediaOutboxStore.purge(ownerScopeId: owner, expectedSession: session)
                try epochKeyStore.removeAll(ownerNamespace: namespace, expectedSession: session)
                // Sans ses clés, une époque courante n'est plus « à jour » : la
                // prochaine époque, créée pour la nouvelle identité, sera reçue.
                try conversationStateStore.removeCurrentEpochs(ownerNamespace: namespace)
                let renewed = try identityStore.activateResetCandidate(
                    ownerNamespace: namespace,
                    expectedDeviceId: replacementId,
                    expectedSession: session
                )
                if let renewed, renewed.ownerScopeId == owner {
                    rotationCommitted(renewed, [], true)
                }
            } else if current?.deviceId != replacementId {
                return localFailure("e2ee-identity-reset-local-activation-pending")
            }
            // L'ancien pin nomme l'UIK remplacée ; retiré avant que la nouvelle ne
            // soit installée, il est refait à la prochaine lecture, contre elle.
            try trustPins.remove(userId: userId, ownerNamespace: namespace)
            try accountIdentityStore.completePendingReset(ownerNamespace: namespace)
            return .success(status)
        } catch {
            return localFailure("e2ee-identity-reset-local-activation-pending")
        }
    }

    /// Lot A2 (D.14) : la réinitialisation en attente sur ce compte, si un autre
    /// appareil l'a demandée et qu'elle se vérifie. `nil` : rien à signaler.
    func pendingIdentityResetToReview() async -> E2EEV2PendingIdentityResetReview? {
        guard let owner = ownerScope(), let userId = Self.userId(owner) else { return nil }
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        let uik = try? accountIdentityStore.load(ownerNamespace: namespace)
        guard let trust = try? await accountTrust(owner: owner, transport: transport, uik: uik),
              let served = trust.pendingIdentityReset,
              let document = try? E2EEV2IdentityReset.verify(served.reset),
              document.userId == userId, nowMs() < document.effectiveAtMs,
              // Elle doit remplacer l'UIK vérifiée de ce compte, sinon le serveur l'abandonnera.
              let current = Data(base64Encoded: trust.outcome.pin.uikX963B64),
              document.previousUikFingerprint == E2EEV2IdentityReset.previousFingerprint(of: current) else { return nil }
        // La sienne se suit par `refreshIdentityReset`, jamais comme une alerte.
        if let own = try? accountIdentityStore.loadPendingReset(ownerNamespace: namespace),
           own.uik?.publicKey.x963Representation.base64EncodedString() == document.newUikB64 {
            return nil
        }
        return .init(resetId: served.resetId, document: document)
    }

    /// Lot A2 (D.14) : un appareil certifié de l'identité actuelle s'oppose,
    /// avant l'échéance. Le serveur annule la demande et révoque l'appareil
    /// de remplacement encore en attente.
    func objectIdentityReset(
        _ review: E2EEV2PendingIdentityResetReview
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2IdentityResetStatus> {
        guard let owner = ownerScope(), let userId = Self.userId(owner), review.document.userId == userId else {
            return localFailure("authenticated-account-required")
        }
        let objectedAtMs = nowMs()
        guard objectedAtMs < review.document.effectiveAtMs else { return localFailure("e2ee-identity-reset-due") }
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let descriptor = try identityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            let canonical = E2EEV2IdentityReset.objectionCanonical(
                userId: userId, newUikB64: review.document.newUikB64,
                objectingDeviceId: descriptor.deviceId, objectedAtMs: objectedAtMs
            )
            let signed = try identityStore.signWithDeviceId(canonicalRequest: Data(canonical.utf8), ownerNamespace: namespace)
            guard signed.deviceId == descriptor.deviceId else { return localFailure("e2ee-device-identity-unavailable") }
            let body = try E2EEV2DeviceApprovalContract.identityResetObjectionData(
                E2EEV2SignedString(canonical: canonical, signatureB64: signed.signature.base64EncodedString())
            )
            return map(
                await transport.postJSON(
                    path: "/api/e2ee/v2/identity/reset/\(review.resetId)/objection",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: { data in
                    E2EEV2DeviceApprovalContract.parseIdentityResetView(data, expectedResetId: review.resetId)
                        .flatMap { $0.state == .objected && $0.objectingDeviceId == descriptor.deviceId ? $0 : nil }
                },
                invalidMessage: "invalid-e2ee-identity-reset-response"
            )
        } catch {
            return localFailure("e2ee-device-identity-unavailable")
        }
    }

    /// Cinq minutes : sous l'écart de 10 minutes que le serveur tolère.
    private static let resetRetryWindowMs: Int64 = 5 * 60 * 1_000
    private static let resetClockSkewMs: Int64 = 10 * 60 * 1_000

    /// Oublie une demande close, seulement si c'est encore celle-là.
    private func forgetIdentityReset(namespace: String, resetId: String?) {
        guard let stored = try? accountIdentityStore.loadPendingReset(ownerNamespace: namespace),
              stored.resetId == resetId else { return }
        try? accountIdentityStore.discardPendingReset(ownerNamespace: namespace)
        try? identityStore.discardResetCandidate(ownerNamespace: namespace)
    }

    /// L'UIK que la réinitialisation remplace : celle détenue ici, sinon celle
    /// épinglée, sinon celle servie. Le serveur refuse un document qui ne nomme
    /// pas l'UIK enregistrée ; `nil` vaut « compte sans UIK ».
    private func previousAccountKey(owner: String, userId: String, transport: E2EEV2APITransport) async -> Data? {
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        if let held = try? accountIdentityStore.load(ownerNamespace: namespace) {
            return held.publicKey.x963Representation
        }
        if let pinned = try? trustPins.pin(userId: userId, ownerNamespace: namespace) {
            return Data(base64Encoded: pinned.uikX963B64)
        }
        return await servedAccountKey(owner: owner, userId: userId, transport: transport).flatMap { Data(base64Encoded: $0) }
    }

    func requestApproval(_ method: E2EEV2ApprovalMethod) async -> E2EEV2DeviceLifecycleResult<E2EEV2Approval> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        do {
            let namespace = LocalAccountScope.storageNamespace(for: owner)
            guard let descriptor = try identityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            let body = try E2EEV2DeviceApprovalContract.approvalRequestData(
                deviceId: descriptor.deviceId,
                method: method
            )
            let result = map(
                await transport.postJSON(
                    path: "/api/e2ee/v2/device-approvals",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: E2EEV2DeviceApprovalContract.parseApprovalCreation,
                invalidMessage: "invalid-e2ee-approval-response"
            )
            if case .success(let approval) = result, approval.method == .qr {
                try? accountIdentityStore.setPendingApprovalId(approval.id, ownerNamespace: namespace)
            }
            return result
        } catch {
            return localFailure("e2ee-device-identity-unavailable")
        }
    }

    /// Lot A1 : reprend la réception de l'UIK d'une demande par QR restée en
    /// cours (écran ou app fermés). `nil` : aucune demande en cours.
    func resumePendingApproval() async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalStatus>? {
        guard let owner = ownerScope(),
              let approvalId = try? accountIdentityStore.pendingApprovalId(ownerNamespace: LocalAccountScope.storageNamespace(for: owner))
        else { return nil }
        return await receiveApprovedTrust(approvalId: approvalId)
    }

    func requestBootstrapEmailChallenge() async -> E2EEV2DeviceLifecycleResult<E2EEV2BootstrapEmailChallenge> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        do {
            let namespace = LocalAccountScope.storageNamespace(for: owner)
            guard let descriptor = try identityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            let body = try E2EEV2DeviceApprovalContract.bootstrapEmailChallengeData(
                deviceId: descriptor.deviceId
            )
            return map(
                await transport.postJSON(
                    path: "/api/e2ee/v2/bootstrap/email-challenge",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: { data in
                    E2EEV2DeviceApprovalContract.parseBootstrapEmailChallenge(data)
                },
                invalidMessage: "invalid-e2ee-bootstrap-email-response"
            )
        } catch {
            return localFailure("e2ee-device-identity-unavailable")
        }
    }

    func bootstrapInitialDevice(
        _ reauthentication: E2EEV2BootstrapReauthentication
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2InitialBootstrapOutcome> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        do {
            let namespace = LocalAccountScope.storageNamespace(for: owner)
            guard let descriptor = try identityStore.load(ownerNamespace: namespace),
                  let userId = Self.userId(owner) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            // Lot A1 (E.1) : le premier appareil apporte l'UIK du compte, son
            // certificat et la liste v1. Le document de capacités, signé avec,
            // part plus tard par sa propre route.
            let pending = try accountIdentityStore.pendingBootstrap(ownerNamespace: namespace, nowMs: nowMs())
            let trust = try E2EEV2InitialTrust.make(
                userId: userId,
                device: descriptor,
                uik: pending.uik,
                signWithDevice: { [identityStore] in
                    try identityStore.signWithDeviceId(canonicalRequest: $0, ownerNamespace: namespace).signature
                },
                kinds: E2EEV2CapabilitiesPublicationStore.kinds,
                features: E2EEV2CapabilitiesPublicationStore.features,
                nowMs: pending.issuedAtMs
            )
            let body = try E2EEV2DeviceApprovalContract.initialBootstrapData(
                deviceId: descriptor.deviceId,
                reauthentication: reauthentication,
                trust: trust
            )
            let result = map(
                await transport.postJSON(
                    path: "/api/e2ee/v2/bootstrap",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: { data in
                    E2EEV2DeviceApprovalContract.parseInitialBootstrap(
                        data,
                        expectedDeviceId: descriptor.deviceId
                    )
                },
                invalidMessage: "invalid-e2ee-bootstrap-response"
            )
            switch result {
            case .success:
                if (try? accountIdentityStore.confirmBootstrap(ownerNamespace: namespace)) == nil {
                    try? accountIdentityStore.confirmBootstrap(ownerNamespace: namespace)
                }
                rotationCommitted(session, [], true)
                // §12 : sans document de capacités, l'appareil reste à l'écart.
                _ = await publishCapabilitiesIfNeeded()
            case .failed(let failure) where failure.code == "E2EE_IDENTITY_ALREADY_ESTABLISHED":
                // Le même code répond à notre propre UIK portée par d'autres textes :
                // elle n'est retirée que si le compte en porte une autre, dont la
                // clé arrivera à l'approbation.
                let local = pending.uik.publicKey.x963Representation.base64EncodedString()
                switch await servedAccountKey(owner: owner, userId: userId, transport: transport) {
                case local?:
                    try? accountIdentityStore.confirmBootstrap(ownerNamespace: namespace)
                case .some:
                    try? accountIdentityStore.discardPendingBootstrap(ownerNamespace: namespace)
                case nil:
                    break
                }
            case .failed:
                break
            }
            return result
        } catch {
            return localFailure("invalid-e2ee-bootstrap-proof")
        }
    }

    func loadApproval(_ approvalId: String) async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalDetail> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        guard E2EEV2DeviceApprovalContract.validOpaqueId(approvalId) else {
            return localFailure("invalid-e2ee-approval-id")
        }
        return map(
            await transport.getJSON(
                path: "/api/e2ee/v2/device-approvals/\(approvalId)",
                expectedOwnerScopeId: owner,
                capabilitySet: .deviceLifecycle
            ),
            parser: E2EEV2DeviceApprovalContract.parseApprovalDetail,
            invalidMessage: "invalid-e2ee-approval-detail"
        )
    }

    func loadQRApproval(_ payload: String) async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalDetail> {
        guard let qr = E2EEV2DeviceApprovalContract.parseQRPayload(payload) else {
            return localFailure("invalid-or-expired-e2ee-qr")
        }
        switch await loadApproval(qr.approvalId) {
        case .failed(let failure):
            return .failed(failure)
        case .success(let detail):
            switch E2EEV2DeviceApprovalContract.compareQR(qr, detail) {
            case .match: return .success(detail)
            case .approvalMismatch: return localFailure("e2ee-qr-server-mismatch")
            case .deviceMismatch: return localFailure("e2ee-qr-device-mismatch")
            case .platformMismatch: return localFailure("e2ee-qr-platform-mismatch")
            }
        }
    }

    func resolveProximityCode(_ code: String) async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalDetail> {
        guard let owner = ownerScope() else { return localFailure("authenticated-account-required") }
        do {
            let body = try E2EEV2DeviceApprovalContract.proximityResolveData(code)
            return map(
                await transport.postJSON(
                    path: "/api/e2ee/v2/device-approvals/resolve",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: E2EEV2DeviceApprovalContract.parseApprovalDetail,
                invalidMessage: "invalid-e2ee-proximity-response"
            )
        } catch {
            return localFailure("invalid-e2ee-proximity-code")
        }
    }

    /// Lot A1 : seulement par QR v3 (décision du 1er octobre). Le certificat,
    /// la liste suivante et l'UIK chiffrée sont signés contre l'empreinte et la
    /// plateforme lues dans le QR, jamais contre ce que déclare le serveur. Une
    /// liste périmée (`E2EE_DEVICE_LIST_STALE`) est relue une fois.
    func approve(
        _ detail: E2EEV2ApprovalDetail,
        comparedQR qr: E2EEV2QRApprovalPayload
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalCompletion> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else {
            return localFailure("authenticated-account-required")
        }
        guard detail.approval.method == .qr, E2EEV2DeviceApprovalContract.compareQR(qr, detail) == .match else {
            return localFailure("e2ee-approval-method-unsupported")
        }
        let transport = self.transport.bound(to: session)
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let uik = try accountIdentityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-account-key-unavailable")
            }
            guard let approver = try identityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            for attempt in 0..<2 {
                let account = try await accountTrust(owner: owner, transport: transport, uik: uik)
                let trust = try E2EEV2DeviceApprovalTrust.make(
                    userId: userId,
                    currentList: account.deviceList,
                    currentEntries: account.deviceEntries,
                    newDevice: detail.pendingDevice.descriptor,
                    expectedFingerprint: qr.fingerprint,
                    comparedPlatform: qr.platform,
                    uik: uik,
                    approverDeviceId: approver.deviceId,
                    signWithApprover: { [identityStore] in
                        try identityStore.signWithDeviceId(canonicalRequest: $0, ownerNamespace: namespace).signature
                    },
                    nonce: Data(AES.GCM.Nonce()),
                    nowMs: nowMs()
                )
                let body = try E2EEV2DeviceApprovalContract.approvalCompletionData(detail, trust: trust)
                let response = await transport.postJSON(
                    path: "/api/e2ee/v2/device-approvals/\(detail.approval.id)/approve",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                )
                if case .failure(let failure) = response, failure.code == "E2EE_DEVICE_LIST_STALE", attempt == 0 { continue }
                let result = map(
                    response,
                    parser: E2EEV2DeviceApprovalContract.parseCompletion,
                    invalidMessage: "invalid-e2ee-approval-completion"
                )
                if case .success(let value) = result {
                    rotationCommitted(session, value.affectedConversationIds, true)
                    await deviceListChanged?()
                }
                return result
            }
            return localFailure("e2ee-device-list-stale")
        } catch {
            return trustFailure(error, fallback: "invalid-e2ee-approval-proof")
        }
    }

    /// Lot A1 : l'appareil en attente, une fois approuvé, lit le dépôt de
    /// confiance (E.1) et installe l'UIK du compte. L'UIK n'est acceptée que
    /// d'un approbateur certifié par le compte, pour cet appareil tel que le
    /// compte le certifie. Rend l'état de la demande.
    func receiveApprovedTrust(approvalId: String) async -> E2EEV2DeviceLifecycleResult<E2EEV2ApprovalStatus> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else {
            return localFailure("authenticated-account-required")
        }
        guard E2EEV2DeviceApprovalContract.validOpaqueId(approvalId) else { return localFailure("invalid-e2ee-approval-id") }
        let transport = self.transport.bound(to: session)
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let descriptor = try identityStore.load(ownerNamespace: namespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            let detail: E2EEV2ApprovalDetail
            switch map(
                await transport.getJSON(
                    path: "/api/e2ee/v2/device-approvals/\(approvalId)",
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                ),
                parser: E2EEV2DeviceApprovalContract.parseApprovalDetail,
                invalidMessage: "invalid-e2ee-approval-detail"
            ) {
            case .failed(let failure): return .failed(failure)
            case .success(let value): detail = value
            }
            guard detail.pendingDevice.descriptor.deviceId == descriptor.deviceId else {
                try? accountIdentityStore.setPendingApprovalId(nil, ownerNamespace: namespace)
                return localFailure("e2ee-approval-other-device")
            }
            guard detail.approval.status == .approved else {
                if detail.approval.status != .pending { try? accountIdentityStore.setPendingApprovalId(nil, ownerNamespace: namespace) }
                return .success(detail.approval.status)
            }
            guard let wrap = detail.trust?.uikWrap else {
                // Dépôt déjà consommé ou expiré : l'UIK est ici seulement si elle
                // n'est pas celle d'un bootstrap jamais confirmé.
                try? accountIdentityStore.setPendingApprovalId(nil, ownerNamespace: namespace)
                return try accountIdentityStore.load(ownerNamespace: namespace) != nil
                    && !accountIdentityStore.hasPendingBootstrap(ownerNamespace: namespace)
                    ? .success(.approved)
                    : localFailure("e2ee-account-key-not-delivered")
            }
            let account = try await accountTrust(owner: owner, transport: transport, uik: nil)
            let uik = try E2EEV2DeviceApprovalTrust.accept(
                wrap, account: account.outcome, userId: userId, device: descriptor
            ) { [identityStore] wrap, approverKey, expectedUIK in
                try identityStore.unwrapAccountIdentityKey(
                    wrap, approverSigningKey: approverKey, expectedUIKB64: expectedUIK, ownerNamespace: namespace
                )
            }
            guard session.isCurrent else { return localFailure("e2ee-session-changed") }
            try accountIdentityStore.discardPendingBootstrap(ownerNamespace: namespace)
            try accountIdentityStore.install(uik, ownerNamespace: namespace)
            try? accountIdentityStore.setPendingApprovalId(nil, ownerNamespace: namespace)
            _ = await publishCapabilitiesIfNeeded()
            return .success(.approved)
        } catch {
            return trustFailure(error, fallback: "e2ee-account-key-not-delivered")
        }
    }

    func revoke(
        deviceId: String,
        reason: String
    ) async -> E2EEV2DeviceLifecycleResult<E2EEV2RevocationOutcome> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        guard E2EEV2DeviceApprovalContract.validOpaqueId(deviceId) else {
            return localFailure("invalid-e2ee-device-id")
        }
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            // Lot A1 : la liste suivante, sans l'appareil, seulement s'il est
            // dans la liste courante (un appareil en attente n'y est pas).
            let uik = try accountIdentityStore.load(ownerNamespace: namespace)
            for attempt in 0..<2 {
                var trust: E2EEV2DeviceRevocationTrust.Artifacts?
                if let uik, let userId = Self.userId(owner) {
                    let account = try await accountTrust(owner: owner, transport: transport, uik: uik)
                    if account.deviceEntries.contains(where: { $0.components(separatedBy: "\n").first == deviceId }) {
                        trust = try E2EEV2DeviceRevocationTrust.make(
                            userId: userId, revokedDeviceId: deviceId, currentList: account.deviceList,
                            currentEntries: account.deviceEntries, uik: uik, nowMs: nowMs()
                        )
                    }
                }
                let body = try E2EEV2DeviceApprovalContract.revocationData(reason: reason, trust: trust)
                let response = await transport.postJSON(
                    path: "/api/e2ee/v2/devices/\(deviceId)/revoke",
                    body: body,
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                )
                if case .failure(let failure) = response, failure.code == "E2EE_DEVICE_LIST_STALE", attempt == 0 { continue }
                let result = map(
                    response,
                    parser: E2EEV2DeviceApprovalContract.parseRevocation,
                    invalidMessage: "invalid-e2ee-revocation-response"
                )
                if case .success(let value) = result {
                    rotationCommitted(session, value.affectedConversationIds, true)
                    await deviceListChanged?()
                }
                return result
            }
            return localFailure("e2ee-device-list-stale")
        } catch {
            return trustFailure(error, fallback: "invalid-e2ee-revocation-reason")
        }
    }

    /// §12 et E.1 : publie le document de capacités de cet appareil, signé par
    /// lui, quand il n'en a pas encore, à chaque nouveau build et au moins tous
    /// les 30 jours. Le document est gardé avant l'envoi : une reprise renvoie
    /// le même. Une séquence dépassée (`E2EE_CAPABILITIES_STALE`) repart une
    /// fois au-dessus de celle du serveur. Rend vrai quand un document a été publié.
    func publishCapabilitiesIfNeeded() async -> E2EEV2DeviceLifecycleResult<Bool> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let device = try identityStore.load(ownerNamespace: namespace) else { return .success(false) }
            let stored = try capabilities.load(ownerNamespace: namespace)
            if let stored, E2EEV2CapabilitiesPublicationStore.isCurrent(
                stored, deviceId: device.deviceId, appBuild: appBuild, nowMs: nowMs()
            ) {
                return .success(false)
            }
            var pending: E2EEV2CapabilitiesPublicationStore.State
            if let stored, E2EEV2CapabilitiesPublicationStore.isReplayable(
                stored, deviceId: device.deviceId, appBuild: appBuild, nowMs: nowMs()
            ) {
                // Envoi récent resté sans réponse : le même document repart.
                pending = stored
            } else {
                let previous = stored?.deviceId == device.deviceId ? stored?.sequence ?? 0 : 0
                pending = try makeCapabilities(
                    userId: userId, device: device, sequence: previous + 1, nowMs: nowMs(), namespace: namespace
                )
            }
            for attempt in 0..<2 {
                let response = await transport.putJSON(
                    path: "/api/e2ee/v2/devices/\(device.deviceId)/capabilities",
                    body: try JSONSerialization.data(
                        withJSONObject: ["document": pending.document, "signatureB64": pending.signatureB64],
                        options: [.sortedKeys]
                    ),
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                )
                switch response {
                case .failure(let failure) where failure.code == "E2EE_CAPABILITIES_STALE" && attempt == 0:
                    var serverSequence = 0
                    if case .string(let text)? = failure.details?["currentSequence"] {
                        serverSequence = E2EEV2Canonical.sequenceNumber(text) ?? 0
                    }
                    // Une séquence très en avance ne se croit pas : la signer
                    // bloquerait toute publication suivante (épinglée chez les autres).
                    guard serverSequence <= pending.sequence + E2EEV2CapabilitiesPublicationStore.maxServerSequenceLead else {
                        return localFailure("e2ee-capabilities-sequence-implausible")
                    }
                    pending = try makeCapabilities(
                        userId: userId, device: device, sequence: max(serverSequence, pending.sequence) + 1,
                        nowMs: nowMs(), namespace: namespace
                    )
                case .failure(let failure):
                    // Refus définitif (document invalide, horloge en avance…) : il
                    // ne repart pas ; la prochaine fois, un document neuf.
                    if failure.kind == .permanent { try? capabilities.remove(ownerNamespace: namespace) }
                    return .failed(failure)
                case .success(let data, _, _):
                    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          root["deviceId"] as? String == device.deviceId,
                          root["sequence"] as? String == String(pending.sequence) else {
                        return localFailure("invalid-e2ee-capabilities-response")
                    }
                    guard session.isCurrent else { return localFailure("e2ee-session-changed") }
                    pending.publishedAtMs = nowMs()
                    try capabilities.save(pending, ownerNamespace: namespace)
                    return .success(true)
                }
            }
            return localFailure("e2ee-capabilities-stale")
        } catch {
            return trustFailure(error, fallback: "e2ee-capabilities-unavailable")
        }
    }

    /// Document signé par l'appareil, gardé (non publié) avant l'envoi.
    private func makeCapabilities(
        userId: String, device: E2EEV2DeviceDescriptor, sequence: Int, nowMs: Int64, namespace: String
    ) throws -> E2EEV2CapabilitiesPublicationStore.State {
        let document = E2EEV2CapabilitiesDocument(
            userId: userId, deviceId: device.deviceId, sequence: sequence, issuedAtMs: nowMs,
            envelopeVersions: ["2"], payloadVersions: ["2"],
            kinds: E2EEV2CapabilitiesPublicationStore.kinds, features: E2EEV2CapabilitiesPublicationStore.features
        ).document
        guard (try? E2EEV2CapabilitiesDocument.parse(document: document)) != nil else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let signature = try identityStore.signWithDeviceId(
            canonicalRequest: Data(E2EEV2CapabilitiesDocument.signatureCanonical(document: document).utf8),
            ownerNamespace: namespace
        ).signature
        let state = E2EEV2CapabilitiesPublicationStore.State(
            deviceId: device.deviceId, sequence: sequence, document: document,
            signatureB64: signature.base64EncodedString(), appBuild: appBuild, publishedAtMs: nil
        )
        try capabilities.save(state, ownerNamespace: namespace)
        return state
    }

    /// §2.6 : la clé d'accord tourne tous les 30 jours. Son certificat
    /// (`keyVersion` + 1) et la liste qui le porte sont signés par l'UIK détenue
    /// ici. Rend vrai quand la nouvelle clé est en service.
    func recertifyIfDue() async -> E2EEV2DeviceLifecycleResult<Bool> {
        guard let owner = ownerScope(), let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == owner,
              let userId = Self.userId(owner) else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        do {
            guard let uik = try accountIdentityStore.load(ownerNamespace: namespace),
                  let device = try identityStore.load(ownerNamespace: namespace),
                  let rotation = try identityStore.agreementKeyRotation(ownerNamespace: namespace, nowMs: nowMs()) else {
                return .success(false)
            }
            for attempt in 0..<2 {
                let account = try await accountTrust(owner: owner, transport: transport, uik: uik)
                guard session.isCurrent else { return localFailure("e2ee-session-changed") }
                // Réponse perdue d'une rotation déjà enregistrée : la liste porte la nouvelle clé.
                if E2EEV2DeviceRecertificationTrust.isListed(rotation, device: device, in: account.deviceEntries) {
                    try identityStore.activateAgreementKey(rotation, ownerNamespace: namespace, nowMs: nowMs())
                    return .success(true)
                }
                // Un appareil absent de la liste ne se recertifie pas (le serveur demanderait une réparation).
                guard account.deviceEntries.contains(where: { $0.components(separatedBy: "\n").first == device.deviceId }) else {
                    return .success(false)
                }
                let trust = try E2EEV2DeviceRecertificationTrust.make(
                    userId: userId, device: device, rotation: rotation, currentList: account.deviceList,
                    currentEntries: account.deviceEntries, uik: uik, nowMs: nowMs()
                )
                let response = await transport.putJSON(
                    path: "/api/e2ee/v2/devices/\(device.deviceId)/certificate",
                    body: try JSONSerialization.data(withJSONObject: trust.body, options: [.sortedKeys]),
                    expectedOwnerScopeId: owner,
                    capabilitySet: .deviceLifecycle
                )
                switch response {
                case .failure(let failure) where failure.code == "E2EE_DEVICE_LIST_STALE" && attempt == 0:
                    continue
                case .failure(let failure):
                    return .failed(failure)
                case .success(let data, _, _):
                    guard E2EEV2DeviceApprovalContract.parseRecertification(data, expected: rotation) else {
                        return localFailure("invalid-e2ee-certificate-response")
                    }
                    guard session.isCurrent else { return localFailure("e2ee-session-changed") }
                    try identityStore.activateAgreementKey(rotation, ownerNamespace: namespace, nowMs: nowMs())
                    return .success(true)
                }
            }
            return localFailure("e2ee-device-list-stale")
        } catch {
            return trustFailure(error, fallback: "e2ee-recertification-unavailable")
        }
    }

    private func ownerScope() -> String? {
        LocalAccountScope.currentUserId == nil ? nil : LocalAccountScope.currentOwnerScopeId
    }

    private static func userId(_ ownerScopeId: String) -> String? {
        guard ownerScopeId.hasPrefix("user:") else { return nil }
        let userId = String(ownerScopeId.dropFirst(5))
        return E2EEV2Canonical.isOpaque(userId) ? userId : nil
    }

    /// UIK que le serveur sert pour son propre compte, sans la croire : seulement
    /// pour décider de garder la sienne après un bootstrap refusé.
    private func servedAccountKey(owner: String, userId: String, transport: E2EEV2APITransport) async -> String? {
        guard let data = try? await E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: owner)(userId, nil),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["accountIdentityKeyB64"] as? String
    }

    /// Son propre compte relu par l'annuaire de confiance (E.1), vérifié contre
    /// l'UIK détenue ici quand il y en a une.
    private func accountTrust(
        owner: String,
        transport: E2EEV2APITransport,
        uik: P256.Signing.PrivateKey?
    ) async throws -> E2EEV2TrustDirectory.AccountTrust {
        let publicKey = uik?.publicKey
        return try await E2EEV2TrustDirectory(
            ownerNamespace: LocalAccountScope.storageNamespace(for: owner),
            pins: trustPins,
            ownUserId: Self.userId(owner),
            ownAccountKey: { publicKey },
            fetch: E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: owner)
        ).ownAccountTrust()
    }

    /// Une erreur réseau garde sa forme serveur ; un compte refusé ou illisible
    /// devient un état local.
    private func trustFailure<Value: Sendable>(_ error: Error, fallback: String) -> E2EEV2DeviceLifecycleResult<Value> {
        switch error {
        case let failure as E2EEV2TransportFailure: return .failed(failure)
        case is E2EEV2TrustDirectory.IdentityNotFound: return localFailure("e2ee-account-identity-unavailable")
        case is E2EEV2IdentityVerification.Failure, is E2EEV2DeviceApprovalTrust.Failure:
            return localFailure("e2ee-account-trust-refused")
        default: return localFailure(fallback)
        }
    }

    private func map<Value: Sendable>(
        _ result: E2EEV2TransportResult<Data>,
        parser: (Data) -> Value?,
        invalidMessage: String
    ) -> E2EEV2DeviceLifecycleResult<Value> {
        switch result {
        case .failure(let failure):
            return .failed(failure)
        case .success(let data, _, _):
            guard let value = parser(data) else { return localFailure(invalidMessage) }
            return .success(value)
        }
    }

    private func localFailure<Value: Sendable>(_ message: String) -> E2EEV2DeviceLifecycleResult<Value> {
        .failed(.init(kind: .localState, message: message))
    }
}

enum E2EEV2RecoveryCryptoError: Error, Equatable {
    case invalidOwnerNamespace
    case invalidRecoveryKey
    case invalidIdentityRootKey
    case invalidSalt
    case invalidNonce
    case invalidWrappedRoot
}

/// Preview-only HKDF-SHA256 + AES-256-GCM recovery primitive. It is deliberately
/// not connected to account recovery until the external v2 review is approved.
enum E2EEV2RecoveryCrypto {
    static let kdfAlgorithm = "HKDF_SHA256"
    static let wrapAlgorithm = "AES_256_GCM"
    static let kdfInfo = "signalquest-e2ee-v2-recovery-root-v1"

    static func aad(ownerNamespace: String) throws -> Data {
        guard ownerNamespace.range(
            of: #"^[A-Za-z0-9._:-]{1,128}\z"#,
            options: .regularExpression
        ) != nil else {
            throw E2EEV2RecoveryCryptoError.invalidOwnerNamespace
        }
        return Data("SQ-E2EE-V2-RECOVERY\n1\n\(ownerNamespace)".utf8)
    }

    static func deriveWrappingKey(recoveryKey: Data, salt: Data) throws -> Data {
        guard recoveryKey.count == 32 else {
            throw E2EEV2RecoveryCryptoError.invalidRecoveryKey
        }
        guard salt.count == 32 else { throw E2EEV2RecoveryCryptoError.invalidSalt }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey),
            salt: salt,
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func wrapIdentityRootKey(
        _ identityRootKey: Data,
        recoveryKey: Data,
        salt: Data,
        nonce: Data,
        ownerNamespace: String
    ) throws -> Data {
        guard identityRootKey.count == 32 else {
            throw E2EEV2RecoveryCryptoError.invalidIdentityRootKey
        }
        guard nonce.count == 12 else { throw E2EEV2RecoveryCryptoError.invalidNonce }
        let sealed = try AES.GCM.seal(
            identityRootKey,
            using: SymmetricKey(data: deriveWrappingKey(recoveryKey: recoveryKey, salt: salt)),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: aad(ownerNamespace: ownerNamespace)
        )
        return sealed.ciphertext + sealed.tag
    }

    static func unwrapIdentityRootKey(
        _ wrappedIdentityRootKey: Data,
        recoveryKey: Data,
        salt: Data,
        nonce: Data,
        ownerNamespace: String
    ) throws -> Data {
        guard wrappedIdentityRootKey.count == 48 else {
            throw E2EEV2RecoveryCryptoError.invalidWrappedRoot
        }
        guard nonce.count == 12 else { throw E2EEV2RecoveryCryptoError.invalidNonce }
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: wrappedIdentityRootKey.prefix(32),
            tag: wrappedIdentityRootKey.suffix(16)
        )
        return try AES.GCM.open(
            sealed,
            using: SymmetricKey(data: deriveWrappingKey(recoveryKey: recoveryKey, salt: salt)),
            authenticating: aad(ownerNamespace: ownerNamespace)
        )
    }

    static func recoveryKeyVerifierHash(_ recoveryKey: Data) throws -> String {
        guard recoveryKey.count == 32 else {
            throw E2EEV2RecoveryCryptoError.invalidRecoveryKey
        }
        var input = Data("SQ-E2EE-V2-RECOVERY-VERIFY".utf8)
        input.append(0)
        input.append(recoveryKey)
        return Data(SHA256.hash(data: input))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum E2EEV2RecoveryV2Error: Error, Equatable {
    case invalidOwner
    case invalidRecoveryKey
    case invalidBundle
    case invalidWrappedKey
    case keyMismatch
    case randomGenerationFailed
}

struct E2EEV2WrappedRecoveryPrivateKey: Codable, Equatable, Sendable {
    let saltB64: String
    let nonceB64: String
    let wrappedPrivateJwkB64: String
    let aadB64: String
    /// Bundle v3, clé du compte seulement : l'UIK en X9.63 (§2.8, v0.4.21).
    var publicKeyB64: String? = nil
}

private struct E2EEV2RecoveryV2KDFParameters: Codable, Equatable, Sendable {
    let hash: String
    let outputBytes: Int
    let identityInfo: String
    let signingInfo: String
    /// Bundle v3 seulement.
    var accountInfo: String? = nil
}

struct E2EEV2RecoveryBundleV2: Codable, Equatable, Sendable {
    let version: Int
    let kdfAlgorithm: String
    private let kdfParameters: E2EEV2RecoveryV2KDFParameters
    let wrapAlgorithm: String
    let recoveryPublicIdentityKeyB64: String
    let recoveryPublicSigningKeyB64: String
    let identityPrivateKey: E2EEV2WrappedRecoveryPrivateKey
    let signingPrivateKey: E2EEV2WrappedRecoveryPrivateKey
    /// Bundle v3 (§2.8, v0.4.21) : l'UIK enveloppée sous la clé de
    /// récupération, qui permet à un appareil récupéré de se certifier.
    let accountPrivateKey: E2EEV2WrappedRecoveryPrivateKey?

    init(
        recoveryPublicIdentityKeyB64: String,
        recoveryPublicSigningKeyB64: String,
        identityPrivateKey: E2EEV2WrappedRecoveryPrivateKey,
        signingPrivateKey: E2EEV2WrappedRecoveryPrivateKey,
        accountPrivateKey: E2EEV2WrappedRecoveryPrivateKey? = nil
    ) {
        version = accountPrivateKey == nil ? 2 : 3
        kdfAlgorithm = E2EEV2RecoveryV2Crypto.kdfAlgorithm
        kdfParameters = .init(
            hash: "SHA-256",
            outputBytes: 32,
            identityInfo: E2EEV2RecoveryV2Crypto.identityInfo,
            signingInfo: E2EEV2RecoveryV2Crypto.signingInfo,
            accountInfo: accountPrivateKey == nil ? nil : E2EEV2RecoveryV2Crypto.accountInfo
        )
        wrapAlgorithm = E2EEV2RecoveryV2Crypto.wrapAlgorithm
        self.recoveryPublicIdentityKeyB64 = recoveryPublicIdentityKeyB64
        self.recoveryPublicSigningKeyB64 = recoveryPublicSigningKeyB64
        self.identityPrivateKey = identityPrivateKey
        self.signingPrivateKey = signingPrivateKey
        self.accountPrivateKey = accountPrivateKey
    }

    fileprivate var validSuite: Bool {
        let v3 = version == 3
        guard version == 2 || v3,
              kdfAlgorithm == E2EEV2RecoveryV2Crypto.kdfAlgorithm,
              kdfParameters == .init(
                  hash: "SHA-256",
                  outputBytes: 32,
                  identityInfo: E2EEV2RecoveryV2Crypto.identityInfo,
                  signingInfo: E2EEV2RecoveryV2Crypto.signingInfo,
                  accountInfo: v3 ? E2EEV2RecoveryV2Crypto.accountInfo : nil
              ),
              wrapAlgorithm == E2EEV2RecoveryV2Crypto.wrapAlgorithm,
              identityPrivateKey.publicKeyB64 == nil, signingPrivateKey.publicKeyB64 == nil else { return false }
        // Une v2 n'a pas de neuvième clé ; une v3 l'a, avec l'UIK.
        guard let account = accountPrivateKey else { return !v3 }
        return v3 && account.publicKeyB64 != nil
    }
}

struct E2EEV2RecoveryMaterialV2: Equatable, Sendable {
    let bundle: E2EEV2RecoveryBundleV2
    /// Secret détenu par l'appelant, à afficher une fois puis à effacer.
    var recoveryKey: Data

    mutating func zeroize() {
        recoveryKey.resetBytes(in: 0..<recoveryKey.count)
    }
}

struct E2EEV2RecoveryChallengeV2: Equatable, Sendable {
    let challengeId: String
    let pendingDeviceId: String
    let bundleHash: String
    let challengeB64URL: String
    let expiresAtMs: Int64
    let bundle: E2EEV2RecoveryBundleV2
    /// Signature de l'UIK sur le texte v2 du bundle, et la version de liste
    /// qu'elle couvre : le plancher de la récupération (§2.8, v0.4.22).
    var signatureB64: String? = nil
    var deviceListVersion: Int? = nil
}

struct E2EEV2RecoveryCompletionV2: Equatable, Sendable {
    let deviceId: String
    let approvedAt: String
    let epochRotationRequired: Bool
    let affectedConversationIds: [String]
}

/// Bundle interopérable : les deux JWK P-256 privées ne quittent le client que
/// chiffrées sous une clé de récupération aléatoire de 256 bits.
enum E2EEV2RecoveryV2Crypto {
    static let kdfAlgorithm = "HKDF_SHA256"
    static let wrapAlgorithm = "AES_256_GCM"
    static let identityInfo = "signalquest-e2ee-v2-recovery-identity-v2"
    static let signingInfo = "signalquest-e2ee-v2-recovery-signing-v2"
    static let accountInfo = "signalquest-e2ee-v2-recovery-account-v3"

    enum Role: String {
        case identity = "IDENTITY"
        case signing = "SIGNING"
        case account = "ACCOUNT"

        var info: String {
            switch self {
            case .identity: return identityInfo
            case .signing: return signingInfo
            case .account: return accountInfo
            }
        }
    }

    private struct PortableJWK {
        var d: Data
        let x: Data
        let y: Data
    }

    /// `accountKey` : l'UIK du compte, enveloppée en v3 (§2.8, v0.4.21) ; sans
    /// elle, un bundle v2 qui ne sert qu'à restaurer l'historique.
    static func generateMaterial(
        ownerBinding: String,
        accountKey: P256.Signing.PrivateKey? = nil
    ) throws -> E2EEV2RecoveryMaterialV2 {
        let recoveryKey = try randomBytes(count: 32)
        let identity = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        do {
            let identityWrapped = try wrap(
                privateRaw: identity.rawRepresentation,
                publicX963: identity.publicKey.x963Representation,
                recoveryKey: recoveryKey,
                ownerBinding: ownerBinding,
                role: .identity
            )
            let signingWrapped = try wrap(
                privateRaw: signing.rawRepresentation,
                publicX963: signing.publicKey.x963Representation,
                recoveryKey: recoveryKey,
                ownerBinding: ownerBinding,
                role: .signing
            )
            let accountWrapped = try accountKey.map {
                try wrapAccountKey($0, recoveryKey: recoveryKey, ownerBinding: ownerBinding)
            }
            let nonces = [identityWrapped.nonceB64, signingWrapped.nonceB64] + (accountWrapped.map { [$0.nonceB64] } ?? [])
            guard Set(nonces).count == nonces.count else {
                throw E2EEV2RecoveryV2Error.invalidBundle
            }
            return E2EEV2RecoveryMaterialV2(
                bundle: .init(
                    recoveryPublicIdentityKeyB64: identity.publicKey.x963Representation.base64EncodedString(),
                    recoveryPublicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                    identityPrivateKey: identityWrapped,
                    signingPrivateKey: signingWrapped,
                    accountPrivateKey: accountWrapped
                ),
                recoveryKey: recoveryKey
            )
        } catch {
            var clear = recoveryKey
            clear.resetBytes(in: 0..<clear.count)
            throw error
        }
    }

    /// L'UIK du compte, rôle `ACCOUNT` (v0.4.21). `salt` et `nonce` fixés
    /// seulement pour le vecteur.
    static func wrapAccountKey(
        _ key: P256.Signing.PrivateKey,
        recoveryKey: Data,
        ownerBinding: String,
        salt: Data? = nil,
        nonce: Data? = nil
    ) throws -> E2EEV2WrappedRecoveryPrivateKey {
        var raw = key.rawRepresentation
        defer { raw.resetBytes(in: 0..<raw.count) }
        var wrapped = try wrap(
            privateRaw: raw, publicX963: key.publicKey.x963Representation,
            recoveryKey: recoveryKey, ownerBinding: ownerBinding, role: .account, salt: salt, nonce: nonce
        )
        wrapped.publicKeyB64 = key.publicKey.x963Representation.base64EncodedString()
        return wrapped
    }

    /// Bundle v3 : déballe l'UIK, puis vérifie que son scalaire redonne les
    /// `x`/`y` du JWK et que ce sont ceux de `publicKeyB64` (§2.8). Reste à
    /// la comparer à l'UIK servie par le paquet de confiance du compte.
    static func unwrapAccountPrivateKey(
        bundle: E2EEV2RecoveryBundleV2,
        recoveryKey: Data,
        ownerBinding: String
    ) throws -> P256.Signing.PrivateKey {
        guard bundle.version == 3, let wrapped = bundle.accountPrivateKey, let publicKeyB64 = wrapped.publicKeyB64 else {
            throw E2EEV2RecoveryV2Error.invalidBundle
        }
        var jwk = try unwrap(
            wrapped: wrapped, expectedPublicB64: publicKeyB64, recoveryKey: recoveryKey,
            ownerBinding: ownerBinding, role: .account
        )
        defer { jwk.d.resetBytes(in: 0..<jwk.d.count) }
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: jwk.d)
        guard privateKey.publicKey.x963Representation.base64EncodedString() == publicKeyB64 else {
            throw E2EEV2RecoveryV2Error.keyMismatch
        }
        return privateKey
    }

    /// §2.8 : la chaîne que l'UIK signe pour le bundle.
    /// Texte v2 (v0.4.22) : la version de liste courante à la signature, le
    /// plancher sous lequel une récupération refuse toute liste servie.
    static func bundleSignatureCanonical(userId: String, bundle: E2EEV2RecoveryBundleV2, deviceListVersion: Int) -> Data {
        Data([
            "SQ-E2EE-V2-RECOVERY-BUNDLE", "2", userId, bundleHash(bundle), bundle.recoveryPublicIdentityKeyB64,
            String(deviceListVersion),
        ].joined(separator: "\n").utf8)
    }

    static func unwrapSigningPrivateKey(
        bundle: E2EEV2RecoveryBundleV2,
        recoveryKey: Data,
        ownerBinding: String
    ) throws -> P256.Signing.PrivateKey {
        var jwk = try unwrap(
            wrapped: bundle.signingPrivateKey,
            expectedPublicB64: bundle.recoveryPublicSigningKeyB64,
            recoveryKey: recoveryKey,
            ownerBinding: ownerBinding,
            role: .signing
        )
        defer { jwk.d.resetBytes(in: 0..<jwk.d.count) }
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: jwk.d)
        guard privateKey.publicKey.x963Representation.base64EncodedString()
                == bundle.recoveryPublicSigningKeyB64 else {
            throw E2EEV2RecoveryV2Error.keyMismatch
        }
        return privateKey
    }

    static func unwrapIdentityPrivateKey(
        bundle: E2EEV2RecoveryBundleV2,
        recoveryKey: Data,
        ownerBinding: String
    ) throws -> P256.KeyAgreement.PrivateKey {
        var jwk = try unwrap(
            wrapped: bundle.identityPrivateKey,
            expectedPublicB64: bundle.recoveryPublicIdentityKeyB64,
            recoveryKey: recoveryKey,
            ownerBinding: ownerBinding,
            role: .identity
        )
        defer { jwk.d.resetBytes(in: 0..<jwk.d.count) }
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: jwk.d)
        guard privateKey.publicKey.x963Representation.base64EncodedString()
                == bundle.recoveryPublicIdentityKeyB64 else {
            throw E2EEV2RecoveryV2Error.keyMismatch
        }
        return privateKey
    }

    static func proofCanonical(_ challenge: E2EEV2RecoveryChallengeV2) throws -> Data {
        guard validOpaqueId(challenge.challengeId),
              validOpaqueId(challenge.pendingDeviceId),
              challenge.bundleHash.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              challenge.challengeB64URL.range(of: #"^[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil,
              Data(base64URLEncoded: challenge.challengeB64URL)?.count == 32,
              challenge.expiresAtMs >= 0 else {
            throw E2EEV2RecoveryV2Error.invalidBundle
        }
        return Data([
            "SQ-E2EE-V2-RECOVERY-PROOF",
            "2",
            challenge.challengeId,
            challenge.pendingDeviceId,
            challenge.bundleHash,
            challenge.challengeB64URL,
            String(challenge.expiresAtMs),
        ].joined(separator: "\n").utf8)
    }

    static func signProof(
        privateSigningKey: P256.Signing.PrivateKey,
        challenge: E2EEV2RecoveryChallengeV2
    ) throws -> String {
        try E2EEV2LowS.sign(proofCanonical(challenge), with: privateSigningKey).base64EncodedString()
    }

    static func bundleHash(_ bundle: E2EEV2RecoveryBundleV2) -> String {
        Data(SHA256.hash(data: Data(E2EEV2RecoveryV2Contract.canonicalBundleJSON(bundle).utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Interne pour les vecteurs (cas négatifs) ; ailleurs, `generateMaterial`.
    static func wrap(
        privateRaw: Data,
        publicX963: Data,
        recoveryKey: Data,
        ownerBinding: String,
        role: Role,
        salt fixedSalt: Data? = nil,
        nonce fixedNonce: Data? = nil
    ) throws -> E2EEV2WrappedRecoveryPrivateKey {
        guard privateRaw.count == 32, publicX963.count == 65, publicX963.first == 4 else {
            throw E2EEV2RecoveryV2Error.invalidBundle
        }
        var clear = Data(portableJWKJSON(privateRaw: privateRaw, publicX963: publicX963).utf8)
        defer { clear.resetBytes(in: 0..<clear.count) }
        let salt = try fixedSalt ?? randomBytes(count: 32)
        let nonce = try fixedNonce ?? randomBytes(count: 12)
        guard salt.count == 32, nonce.count == 12 else { throw E2EEV2RecoveryV2Error.invalidBundle }
        let additionalData = try aad(ownerBinding: ownerBinding, role: role)
        let sealed = try AES.GCM.seal(
            clear,
            using: try wrappingKey(recoveryKey: recoveryKey, salt: salt, role: role),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: additionalData
        )
        return .init(
            saltB64: salt.base64EncodedString(),
            nonceB64: nonce.base64EncodedString(),
            wrappedPrivateJwkB64: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            aadB64: additionalData.base64EncodedString()
        )
    }

    private static func unwrap(
        wrapped: E2EEV2WrappedRecoveryPrivateKey,
        expectedPublicB64: String,
        recoveryKey: Data,
        ownerBinding: String,
        role: Role
    ) throws -> PortableJWK {
        guard recoveryKey.count == 32,
              let salt = Data(base64Encoded: wrapped.saltB64), salt.count == 32,
              let nonce = Data(base64Encoded: wrapped.nonceB64), nonce.count == 12,
              let encrypted = Data(base64Encoded: wrapped.wrappedPrivateJwkB64),
              encrypted.count >= 144, encrypted.count <= 784,
              let additionalData = Data(base64Encoded: wrapped.aadB64),
              additionalData == (try aad(ownerBinding: ownerBinding, role: role)),
              let expectedPublic = Data(base64Encoded: expectedPublicB64), expectedPublic.count == 65 else {
            throw E2EEV2RecoveryV2Error.invalidWrappedKey
        }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: encrypted.dropLast(16),
            tag: encrypted.suffix(16)
        )
        var clear = try AES.GCM.open(
            box,
            using: try wrappingKey(recoveryKey: recoveryKey, salt: salt, role: role),
            authenticating: additionalData
        )
        defer { clear.resetBytes(in: 0..<clear.count) }
        let jwk = try parsePortableJWK(clear)
        guard Data([4]) + jwk.x + jwk.y == expectedPublic else {
            throw E2EEV2RecoveryV2Error.keyMismatch
        }
        return jwk
    }

    private static func portableJWKJSON(privateRaw: Data, publicX963: Data) -> String {
        "{\"crv\":\"P-256\",\"d\":\"\(privateRaw.base64URLEncodedNoPadding())\",\"kty\":\"EC\",\"x\":\"\(publicX963[1..<33].base64URLEncodedNoPadding())\",\"y\":\"\(publicX963[33..<65].base64URLEncodedNoPadding())\"}"
    }

    private static func parsePortableJWK(_ clear: Data) throws -> PortableJWK {
        guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any],
              Set(object.keys) == Set(["crv", "d", "kty", "x", "y"]),
              object["crv"] as? String == "P-256",
              object["kty"] as? String == "EC",
              let dRaw = object["d"] as? String, let d = Data(base64URLEncoded: dRaw), d.count == 32,
              let xRaw = object["x"] as? String, let x = Data(base64URLEncoded: xRaw), x.count == 32,
              let yRaw = object["y"] as? String, let y = Data(base64URLEncoded: yRaw), y.count == 32 else {
            throw E2EEV2RecoveryV2Error.invalidWrappedKey
        }
        return PortableJWK(d: d, x: x, y: y)
    }

    private static func wrappingKey(
        recoveryKey: Data,
        salt: Data,
        role: Role
    ) throws -> SymmetricKey {
        guard recoveryKey.count == 32, salt.count == 32 else {
            throw E2EEV2RecoveryV2Error.invalidRecoveryKey
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey),
            salt: salt,
            info: Data(role.info.utf8),
            outputByteCount: 32
        )
    }

    private static func aad(ownerBinding: String, role: Role) throws -> Data {
        guard ownerBinding.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}\z"#,
            options: .regularExpression
        ) != nil else { throw E2EEV2RecoveryV2Error.invalidOwner }
        return Data("SQ-E2EE-V2-RECOVERY\n2\n\(ownerBinding)\n\(role.rawValue)".utf8)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw E2EEV2RecoveryV2Error.randomGenerationFailed }
        return data
    }

    fileprivate static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#, options: .regularExpression) != nil
    }
}

enum E2EEV2RecoveryV2Contract {
    static func bundleData(_ bundle: E2EEV2RecoveryBundleV2) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bundle)
    }

    /// `PUT /recovery-bundle` (E.1) : les clés du bundle plus `signatureB64`,
    /// la signature de l'UIK sur sa forme hachée (§2.8).
    static func uploadData(_ bundle: E2EEV2RecoveryBundleV2, signatureB64: String, deviceListVersion: Int) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: bundleData(bundle)) as? [String: Any] else {
            throw E2EEV2RecoveryV2Error.invalidBundle
        }
        object["signatureB64"] = signatureB64
        object["deviceListVersion"] = String(deviceListVersion)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Forme hachée (`bundleHash`) : ordre de clés fixe, non trié ; en v3,
    /// `accountInfo` après `signingInfo` et `accountPrivateKey` en dernier.
    static func canonicalBundleJSON(_ bundle: E2EEV2RecoveryBundleV2) -> String {
        let v3 = bundle.version == 3
        let accountInfo = v3 ? ",\"accountInfo\":\"\(E2EEV2RecoveryV2Crypto.accountInfo)\"" : ""
        let accountKey = v3 ? (bundle.accountPrivateKey.map { ",\"accountPrivateKey\":\(wrappedJSON($0))" } ?? "") : ""
        return "{\"version\":\(v3 ? 3 : 2),\"kdfAlgorithm\":\"\(E2EEV2RecoveryV2Crypto.kdfAlgorithm)\",\"kdfParameters\":{\"hash\":\"SHA-256\",\"outputBytes\":32,\"identityInfo\":\"\(E2EEV2RecoveryV2Crypto.identityInfo)\",\"signingInfo\":\"\(E2EEV2RecoveryV2Crypto.signingInfo)\"\(accountInfo)},\"wrapAlgorithm\":\"\(E2EEV2RecoveryV2Crypto.wrapAlgorithm)\",\"recoveryPublicIdentityKeyB64\":\"\(bundle.recoveryPublicIdentityKeyB64)\",\"recoveryPublicSigningKeyB64\":\"\(bundle.recoveryPublicSigningKeyB64)\",\"identityPrivateKey\":\(wrappedJSON(bundle.identityPrivateKey)),\"signingPrivateKey\":\(wrappedJSON(bundle.signingPrivateKey))\(accountKey)}"
    }

    static func parseChallenge(
        _ data: Data,
        expectedPendingDeviceId: String,
        expectedOwnerBinding: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2RecoveryChallengeV2? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["challenge", "bundle"]),
              let challenge = root["challenge"] as? [String: Any],
              Set(challenge.keys) == Set([
                "challengeId", "pendingDeviceId", "bundleHash", "challengeB64Url", "expiresAt", "expiresAtMs",
              ]),
              let bundleObject = root["bundle"] as? [String: Any],
              let challengeId = challenge["challengeId"] as? String,
              E2EEV2RecoveryV2Crypto.validOpaqueId(challengeId),
              challenge["pendingDeviceId"] as? String == expectedPendingDeviceId,
              E2EEV2RecoveryV2Crypto.validOpaqueId(expectedPendingDeviceId),
              let bundleHash = challenge["bundleHash"] as? String,
              bundleHash.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              let challengeB64URL = challenge["challengeB64Url"] as? String,
              challengeB64URL.range(of: #"^[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil,
              Data(base64URLEncoded: challengeB64URL)?.count == 32,
              let expiresAt = challenge["expiresAt"] as? String,
              let expiresDate = parseTimestamp(expiresAt) else { return nil }
        // `expiresAtMs`, en chaîne (D.0), est ce que signe la preuve ; il doit
        // désigner le même instant que `expiresAt`.
        guard let rawMs = challenge["expiresAtMs"] as? String,
              rawMs.range(of: #"^(0|[1-9][0-9]{0,15})\z"#, options: .regularExpression) != nil,
              let expiresAtMs = Int64(rawMs),
              abs(expiresAtMs - Int64(expiresDate.timeIntervalSince1970 * 1_000)) < 1_000,
              expiresAtMs > nowMs else { return nil }
        guard let bundle = parsePublicBundle(bundleObject, expectedOwnerBinding: expectedOwnerBinding),
              E2EEV2RecoveryV2Crypto.bundleHash(bundle) == bundleHash else { return nil }
        return .init(
            challengeId: challengeId,
            pendingDeviceId: expectedPendingDeviceId,
            bundleHash: bundleHash,
            challengeB64URL: challengeB64URL,
            expiresAtMs: expiresAtMs,
            bundle: bundle,
            signatureB64: (bundleObject["signatureB64"] as? String).flatMap { Data(base64Encoded: $0) == nil ? nil : $0 },
            deviceListVersion: listVersion(bundleObject["deviceListVersion"])
        )
    }

    /// `deviceListVersion` servi avec le bundle (D.0, chaîne canonique).
    static func listVersion(_ value: Any?) -> Int? {
        guard let raw = value as? String,
              raw.range(of: #"^[1-9][0-9]{0,9}\z"#, options: .regularExpression) != nil else { return nil }
        return Int(raw)
    }

    /// Version de liste que couvre la signature du bundle actif servi.
    static func activeBundleListVersion(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundle = root["bundle"] as? [String: Any] else { return nil }
        return listVersion(bundle["deviceListVersion"])
    }

    /// `{challengeB64Url, recoverySignatureB64, certificate, deviceList}` :
    /// l'appareil récupéré se certifie avec l'UIK déballée (§2.3, §2.8).
    static func completionData(
        challenge: E2EEV2RecoveryChallengeV2,
        recoverySignatureB64: String,
        trust: E2EEV2RecoveryTrust.Artifacts
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "challengeB64Url": challenge.challengeB64URL,
            "recoverySignatureB64": recoverySignatureB64,
            "certificate": ["certificate": trust.certificate.canonical, "signatureB64": trust.certificate.signatureB64],
            "deviceList": ["list": trust.deviceList.canonical, "signatureB64": trust.deviceList.signatureB64, "devices": trust.deviceEntries],
        ] as [String: Any], options: [.sortedKeys])
    }

    static func parseBundleReceipt(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["stored", "unchanged", "createdAt", "rotatedAt"]),
              root["stored"] as? Bool == true,
              root["unchanged"] is Bool,
              validISO(root["createdAt"]),
              root["rotatedAt"] is NSNull || validISO(root["rotatedAt"]) else { return false }
        return true
    }

    /// Recharges le bundle public actif sans jamais assouplir sa liaison au
    /// compte. Cela permet de reprendre une restauration après relance sans
    /// conserver le secret de récupération dans l'application.
    static func parseActiveBundle(
        _ data: Data,
        expectedOwnerBinding: String
    ) -> E2EEV2RecoveryBundleV2? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["bundle", "state"]),
              root["state"] as? String == "AVAILABLE",
              let bundleObject = root["bundle"] as? [String: Any] else { return nil }
        return parsePublicBundle(bundleObject, expectedOwnerBinding: expectedOwnerBinding)
    }

    static func parseCompletion(
        _ data: Data,
        expectedDeviceId: String
    ) -> E2EEV2RecoveryCompletionV2? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set([
                "recovered", "device", "epochRotationRequired", "affectedConversationIds",
              ]),
              root["recovered"] as? Bool == true,
              let device = root["device"] as? [String: Any],
              Set(device.keys) == Set(["deviceId", "status", "approvedAt"]),
              device["deviceId"] as? String == expectedDeviceId,
              device["status"] as? String == "approved",
              let approvedAt = device["approvedAt"] as? String,
              parseTimestamp(approvedAt) != nil,
              let rotationRequired = root["epochRotationRequired"] as? Bool,
              let rawIds = root["affectedConversationIds"] as? [Any],
              rawIds.count <= 500 else { return nil }
        let ids = rawIds.compactMap { $0 as? String }
        guard ids.count == rawIds.count,
              ids.allSatisfy(E2EEV2RecoveryV2Crypto.validOpaqueId),
              Set(ids).count == ids.count,
              rotationRequired == !ids.isEmpty else { return nil }
        return .init(
            deviceId: expectedDeviceId,
            approvedAt: approvedAt,
            epochRotationRequired: rotationRequired,
            affectedConversationIds: ids
        )
    }

    static func validate(_ bundle: E2EEV2RecoveryBundleV2, ownerBinding: String) -> Bool {
        let nonces = [bundle.identityPrivateKey.nonceB64, bundle.signingPrivateKey.nonceB64]
            + (bundle.accountPrivateKey.map { [$0.nonceB64] } ?? [])
        guard bundle.validSuite,
              bundle.recoveryPublicIdentityKeyB64 != bundle.recoveryPublicSigningKeyB64,
              validP256(bundle.recoveryPublicIdentityKeyB64),
              validP256(bundle.recoveryPublicSigningKeyB64),
              Set(nonces).count == nonces.count else { return false }
        if let account = bundle.accountPrivateKey {
            guard let publicKey = account.publicKeyB64, validP256(publicKey),
                  validWrapped(account, ownerBinding: ownerBinding, role: "ACCOUNT") else { return false }
        }
        return validWrapped(bundle.identityPrivateKey, ownerBinding: ownerBinding, role: "IDENTITY")
            && validWrapped(bundle.signingPrivateKey, ownerBinding: ownerBinding, role: "SIGNING")
    }

    private static func parsePublicBundle(
        _ bundleObject: [String: Any],
        expectedOwnerBinding: String
    ) -> E2EEV2RecoveryBundleV2? {
        var base: Set<String> = [
            "version", "kdfAlgorithm", "kdfParameters", "wrapAlgorithm",
            "recoveryPublicIdentityKeyB64", "recoveryPublicSigningKeyB64",
            "identityPrivateKey", "signingPrivateKey", "createdAt", "rotatedAt", "revokedAt",
        ]
        // A2 : le bundle servi porte la signature de l'UIK (§2.8).
        if bundleObject["signatureB64"] != nil { base.insert("signatureB64") }
        if bundleObject["deviceListVersion"] != nil { base.insert("deviceListVersion") }
        // Version : un entier JSON, jamais 3.0 ; chaque objet avec exactement ses clés.
        guard let versionNumber = bundleObject["version"] as? NSNumber,
              !CFNumberIsFloatType(versionNumber), CFGetTypeID(versionNumber) != CFBooleanGetTypeID() else { return nil }
        let v3 = versionNumber.intValue == 3
        let wrappedKeys: Set<String> = ["saltB64", "nonceB64", "wrappedPrivateJwkB64", "aadB64"]
        let kdfKeys: Set<String> = ["hash", "outputBytes", "identityInfo", "signingInfo"]
        let keys = { (name: String) in (bundleObject[name] as? [String: Any]).map { Set($0.keys) } }
        guard Set(bundleObject.keys) == (v3 ? base.union(["accountPrivateKey"]) : base),
              keys("kdfParameters") == (v3 ? kdfKeys.union(["accountInfo"]) : kdfKeys),
              keys("identityPrivateKey") == wrappedKeys, keys("signingPrivateKey") == wrappedKeys,
              !v3 || keys("accountPrivateKey") == wrappedKeys.union(["publicKeyB64"]),
        bundleObject["revokedAt"] is NSNull,
        validISO(bundleObject["createdAt"]),
        bundleObject["rotatedAt"] is NSNull || validISO(bundleObject["rotatedAt"]) else {
            return nil
        }
        var payload = bundleObject
        payload.removeValue(forKey: "createdAt")
        payload.removeValue(forKey: "rotatedAt")
        payload.removeValue(forKey: "revokedAt")
        payload.removeValue(forKey: "signatureB64")
        payload.removeValue(forKey: "deviceListVersion")
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let bundle = try? JSONDecoder().decode(E2EEV2RecoveryBundleV2.self, from: payloadData),
              validate(bundle, ownerBinding: expectedOwnerBinding) else { return nil }
        return bundle
    }

    private static func validWrapped(
        _ wrapped: E2EEV2WrappedRecoveryPrivateKey,
        ownerBinding: String,
        role: String
    ) -> Bool {
        guard Data(base64Encoded: wrapped.saltB64)?.count == 32,
              Data(base64Encoded: wrapped.nonceB64)?.count == 12,
              let encrypted = Data(base64Encoded: wrapped.wrappedPrivateJwkB64),
              (144...784).contains(encrypted.count),
              let additionalData = Data(base64Encoded: wrapped.aadB64) else { return false }
        return additionalData == Data("SQ-E2EE-V2-RECOVERY\n2\n\(ownerBinding)\n\(role)".utf8)
    }

    private static func validP256(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count == 65 && data.first == 4
    }

    private static func validISO(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return parseTimestamp(value) != nil
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: value)
    }

    private static func wrappedJSON(_ value: E2EEV2WrappedRecoveryPrivateKey) -> String {
        let publicKey = value.publicKeyB64.map { ",\"publicKeyB64\":\"\($0)\"" } ?? ""
        return "{\"saltB64\":\"\(value.saltB64)\",\"nonceB64\":\"\(value.nonceB64)\",\"wrappedPrivateJwkB64\":\"\(value.wrappedPrivateJwkB64)\",\"aadB64\":\"\(value.aadB64)\"\(publicKey)}"
    }
}

enum E2EEV2RecoveryResultV2: Sendable {
    case success(E2EEV2RecoveryCompletionV2)
    case failed(E2EEV2TransportFailure)
}

enum E2EEV2RecoveryBundleCreationResultV2: Sendable {
    case success(E2EEV2RecoveryMaterialV2)
    case failed(E2EEV2TransportFailure)
}

enum E2EEV2RecoveryBundleLoadResultV2: Sendable {
    case success(E2EEV2RecoveryBundleV2)
    case failed(E2EEV2TransportFailure)
}

/// Couche runtime fail-closed : l'interface peut présenter les parcours, mais
/// le serveur et `activationEnabled` gardent toute écriture verrouillée avant revue.
final class E2EEV2RecoveryCoordinatorV2: @unchecked Sendable {
    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let accountIdentityStore: E2EEV2AccountIdentityStore
    private let trustPins: E2EEV2TrustPinStore
    private let rotationCommitted: @Sendable (LocalAccountSession, [String], Bool) -> Void

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        accountIdentityStore: E2EEV2AccountIdentityStore = E2EEV2AccountIdentityStore(),
        trustPins: E2EEV2TrustPinStore = E2EEV2TrustPinStore(),
        rotationCommitted: @escaping @Sendable (LocalAccountSession, [String], Bool) -> Void = {
            E2EEV2RotationEvents.recordCommitted(session: $0, conversations: $1, notify: $2)
        }
    ) {
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        self.identityStore = identityStore
        self.accountIdentityStore = accountIdentityStore
        self.trustPins = trustPins
        self.rotationCommitted = rotationCommitted
    }

    /// La version de la liste signée courante du compte, vérifiée contre l'UIK
    /// détenue ici : celle que le texte v2 du bundle signe (§2.8, v0.4.22).
    private func currentListVersion(
        uik: P256.Signing.PrivateKey,
        session: LocalAccountSession,
        transport: E2EEV2APITransport
    ) async throws -> Int {
        let publicKey = uik.publicKey
        return try await E2EEV2TrustDirectory(
            ownerNamespace: session.ownerNamespace, pins: trustPins,
            ownUserId: String(session.ownerScopeId.dropFirst("user:".count)), ownAccountKey: { publicKey },
            fetch: E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: session.ownerScopeId)
        ).ownAccountTrust().outcome.pin.listVersion
    }

    /// Signe le bundle à la version de liste courante et l'envoie ; une liste
    /// changée entre-temps (`E2EE_RECOVERY_BUNDLE_LIST_STALE`) est relue une fois.
    private func upload(
        _ bundle: E2EEV2RecoveryBundleV2,
        uik: P256.Signing.PrivateKey,
        session: LocalAccountSession,
        transport: E2EEV2APITransport
    ) async -> E2EEV2TransportResult<Data> {
        let userId = String(session.ownerScopeId.dropFirst("user:".count))
        var last = E2EEV2TransportResult<Data>.failure(.init(kind: .localState, message: "e2ee-recovery-upload-not-attempted"))
        for _ in 0..<2 {
            do {
                let version = try await currentListVersion(uik: uik, session: session, transport: transport)
                let signature = try E2EEV2LowS.sign(
                    E2EEV2RecoveryV2Crypto.bundleSignatureCanonical(userId: userId, bundle: bundle, deviceListVersion: version),
                    with: uik
                ).base64EncodedString()
                last = await transport.putJSON(
                    path: "/api/e2ee/v2/recovery-bundle",
                    body: try E2EEV2RecoveryV2Contract.uploadData(bundle, signatureB64: signature, deviceListVersion: version),
                    expectedOwnerScopeId: session.ownerScopeId,
                    capabilitySet: .deviceLifecycle
                )
            } catch let failure as E2EEV2TransportFailure {
                return .failure(failure)
            } catch {
                return .failure(.init(kind: .localState, message: "e2ee-recovery-signature-failed"))
            }
            if case .failure(let failure) = last, failure.code == "E2EE_RECOVERY_BUNDLE_LIST_STALE" { continue }
            return last
        }
        return last
    }

    /// Après une approbation ou une révocation, le bundle actif est re-signé à
    /// la nouvelle version de liste : son plancher suit les révocations (§2.8,
    /// DEVRAIT, v0.4.22). Sans UIK ici ou sans bundle, rien.
    func resignActiveBundleIfStale() async {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent,
              let uik = try? accountIdentityStore.load(ownerNamespace: session.ownerNamespace) else { return }
        let transport = self.transport.bound(to: session)
        guard case .success(let data, _, _) = await transport.getJSON(
            path: "/api/e2ee/v2/recovery-bundle", expectedOwnerScopeId: session.ownerScopeId, capabilitySet: .deviceLifecycle
        ), let bundle = E2EEV2RecoveryV2Contract.parseActiveBundle(data, expectedOwnerBinding: session.ownerScopeId),
           bundle.version == 3,
           let current = try? await currentListVersion(uik: uik, session: session, transport: transport),
           (E2EEV2RecoveryV2Contract.activeBundleListVersion(data) ?? 0) < current else { return }
        _ = await upload(bundle, uik: uik, session: session, transport: transport)
    }

    func createAndUploadBundle() async -> E2EEV2RecoveryBundleCreationResultV2 {
        guard LocalAccountScope.currentUserId != nil else { return localBundleFailure("authenticated-account-required") }
        guard let session = LocalAccountScope.sessionSnapshot() else { return localBundleFailure("authenticated-account-required") }
        let transport = self.transport.bound(to: session)
        let ownerScope = LocalAccountScope.currentOwnerScopeId
        // Bundle v3 (§2.8) : l'UIK y est enveloppée, et elle signe le bundle.
        guard let uik = try? accountIdentityStore.load(ownerNamespace: session.ownerNamespace) else {
            return localBundleFailure("e2ee-account-key-unavailable")
        }
        var material: E2EEV2RecoveryMaterialV2
        do {
            material = try E2EEV2RecoveryV2Crypto.generateMaterial(ownerBinding: ownerScope, accountKey: uik)
        } catch {
            return localBundleFailure("e2ee-recovery-generation-failed")
        }
        let result = await upload(material.bundle, uik: uik, session: session, transport: transport)
        switch result {
        case .failure(let failure):
            material.zeroize()
            return .failed(failure)
        case .success(let data, _, _):
            guard E2EEV2RecoveryV2Contract.parseBundleReceipt(data) else {
                material.zeroize()
                return localBundleFailure("invalid-e2ee-recovery-bundle-response")
            }
            rotationCommitted(session, [], true)
            return .success(material)
        }
    }

    func loadActiveBundle() async -> E2EEV2RecoveryBundleLoadResultV2 {
        guard LocalAccountScope.currentUserId != nil else {
            return localBundleLoadFailure("authenticated-account-required")
        }
        let ownerScope = LocalAccountScope.currentOwnerScopeId
        switch await transport.getJSON(
            path: "/api/e2ee/v2/recovery-bundle",
            expectedOwnerScopeId: ownerScope,
            capabilitySet: .deviceLifecycle
        ) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let data, _, _):
            guard let bundle = E2EEV2RecoveryV2Contract.parseActiveBundle(
                data,
                expectedOwnerBinding: ownerScope
            ) else {
                return localBundleLoadFailure("invalid-e2ee-recovery-bundle-response")
            }
            return .success(bundle)
        }
    }

    func recover(recoveryKey: Data) async -> E2EEV2RecoveryResultV2 {
        guard recoveryKey.count == 32, LocalAccountScope.currentUserId != nil else {
            return localFailure("invalid-e2ee-recovery-key")
        }
        let ownerScope = LocalAccountScope.currentOwnerScopeId
        guard let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == ownerScope else {
            return localFailure("authenticated-account-required")
        }
        let transport = self.transport.bound(to: session)
        let ownerNamespace = LocalAccountScope.storageNamespace(for: ownerScope)
        guard let device = try? identityStore.load(ownerNamespace: ownerNamespace) else {
            return localFailure("e2ee-device-identity-unavailable")
        }
        let started = await transport.postJSON(
            path: "/api/e2ee/v2/recovery-challenges",
            body: Data("{}".utf8),
            expectedOwnerScopeId: ownerScope,
            capabilitySet: .deviceLifecycle
        )
        let challenge: E2EEV2RecoveryChallengeV2
        switch started {
        case .failure(let failure): return .failed(failure)
        case .success(let data, _, _):
            guard let parsed = E2EEV2RecoveryV2Contract.parseChallenge(
                data,
                expectedPendingDeviceId: device.deviceId,
                expectedOwnerBinding: ownerScope
            ) else { return localFailure("invalid-e2ee-recovery-challenge") }
            challenge = parsed
        }
        // Seul un bundle v3 porte l'UIK qui permet de se certifier (§2.8).
        guard challenge.bundle.version == 3 else { return localFailure("e2ee-recovery-bundle-version-unsupported") }
        let signature: String
        let uik: P256.Signing.PrivateKey
        do {
            let privateKey = try E2EEV2RecoveryV2Crypto.unwrapSigningPrivateKey(
                bundle: challenge.bundle,
                recoveryKey: recoveryKey,
                ownerBinding: ownerScope
            )
            signature = try E2EEV2RecoveryV2Crypto.signProof(
                privateSigningKey: privateKey,
                challenge: challenge
            )
            uik = try E2EEV2RecoveryV2Crypto.unwrapAccountPrivateKey(
                bundle: challenge.bundle, recoveryKey: recoveryKey, ownerBinding: ownerScope
            )
        } catch {
            return localFailure("e2ee-recovery-key-mismatch")
        }
        // Le plancher : la signature du bundle par l'UIK déballée, sur le texte
        // v2 et la version de liste servie (§2.8, v0.4.22). Sans elle, un
        // serveur pourrait servir un plancher plus bas.
        guard let bundleSignature = challenge.signatureB64, let floor = challenge.deviceListVersion,
              E2EEV2SignedString(
                  canonical: String(decoding: E2EEV2RecoveryV2Crypto.bundleSignatureCanonical(
                      userId: String(ownerScope.dropFirst("user:".count)), bundle: challenge.bundle, deviceListVersion: floor
                  ), as: UTF8.self),
                  signatureB64: bundleSignature
              ).verify(with: uik.publicKey) else {
            return localFailure("e2ee-recovery-bundle-signature-invalid")
        }
        // Jamais rien de signé si ce coffre garde déjà une autre UIK : sinon le
        // serveur certifierait un appareil qui ne pourrait plus la garder.
        do {
            if let existing = try accountIdentityStore.load(ownerNamespace: session.ownerNamespace),
               existing.rawRepresentation != uik.rawRepresentation {
                return localFailure("e2ee-account-key-conflict")
            }
        } catch {
            return localFailure("e2ee-account-key-unavailable")
        }
        // L'UIK déballée doit être celle que sert le paquet de confiance du
        // compte, dont la liste courante porte la suivante.
        let userId = String(ownerScope.dropFirst("user:".count))
        let trust: E2EEV2RecoveryTrust.Artifacts
        do {
            let publicKey = uik.publicKey
            let account = try await E2EEV2TrustDirectory(
                ownerNamespace: session.ownerNamespace, pins: trustPins, ownUserId: userId,
                ownAccountKey: { publicKey },
                fetch: E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: ownerScope)
            ).ownAccountTrust()
            // Une liste plus ancienne que celle que le bundle signe : recul servi.
            guard account.outcome.pin.listVersion >= floor else { return localFailure("e2ee-recovery-device-list-rollback") }
            trust = try E2EEV2RecoveryTrust.make(
                userId: userId, currentList: account.deviceList, currentEntries: account.deviceEntries,
                device: device, uik: uik, nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        } catch let failure as E2EEV2TransportFailure {
            return .failed(failure)
        } catch {
            return localFailure("e2ee-account-trust-refused")
        }
        let completionBody: Data
        do {
            completionBody = try E2EEV2RecoveryV2Contract.completionData(
                challenge: challenge,
                recoverySignatureB64: signature,
                trust: trust
            )
        } catch {
            return localFailure("e2ee-recovery-serialization-failed")
        }
        let completed = await transport.postJSON(
            path: "/api/e2ee/v2/recovery-challenges/\(challenge.challengeId)/complete",
            body: completionBody,
            expectedOwnerScopeId: ownerScope,
            capabilitySet: .deviceLifecycle
        )
        switch completed {
        case .failure(let failure): return .failed(failure)
        case .success(let data, _, _):
            guard let parsed = E2EEV2RecoveryV2Contract.parseCompletion(
                data,
                expectedDeviceId: device.deviceId
            ) else { return localFailure("invalid-e2ee-recovery-completion") }
            // L'UIK prouvée par la clé de récupération est celle du compte :
            // gardée ici, et tenue pour vérifiée.
            do {
                try accountIdentityStore.install(uik, ownerNamespace: session.ownerNamespace)
                try accountIdentityStore.markVerified(ownerNamespace: session.ownerNamespace)
            } catch {
                return localFailure("e2ee-account-key-storage-failed")
            }
            rotationCommitted(session, parsed.affectedConversationIds, true)
            return .success(parsed)
        }
    }

    private func localFailure(_ message: String) -> E2EEV2RecoveryResultV2 {
        .failed(.init(kind: .localState, message: message))
    }

    private func localBundleFailure(_ message: String) -> E2EEV2RecoveryBundleCreationResultV2 {
        .failed(.init(kind: .localState, message: message))
    }

    private func localBundleLoadFailure(_ message: String) -> E2EEV2RecoveryBundleLoadResultV2 {
        .failed(.init(kind: .localState, message: message))
    }
}

// MARK: - E2EE v2 recovery envelopes for historical epochs (preview, fail-closed)

struct E2EEV2RecoveryEpochRecipient: Equatable, Sendable {
    let recipientUserId: String
    let recoveryBundleHash: String
    let recoveryPublicIdentityKeyB64: String
}

struct E2EEV2RecoveryEpochContext: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let senderDeviceId: String
    let recipientUserId: String
    let recoveryBundleHash: String
}

struct E2EEV2RecoveryEpochEnvelope: Codable, Equatable, Sendable {
    let recipientUserId: String
    let recoveryBundleHash: String
    let wrapAlgorithm: String
    let ephemeralPublicKeyB64: String
    let wrappedEpochKeyB64: String
    let nonceB64: String
    let aadB64: String
    let signatureB64: String
}

struct E2EEV2RecoveryEpochMetadata: Equatable, Sendable {
    let conversationId: String
    let epochId: String
    let epochNumber: Int
    let algorithm: String
    let keyCommitmentB64: String
    let reason: String
    let status: String
    let createdAt: String
    let senderDeviceId: String

    var keyRecord: E2EEV2EpochKeyRecordInput {
        .init(
            conversationId: conversationId,
            epochId: epochId,
            epochNumber: epochNumber,
            keyCommitmentB64: keyCommitmentB64
        )
    }
}

struct E2EEV2RecoveryEpochDelivery: Equatable, Sendable {
    let recoveryEnvelopeId: String
    let metadata: E2EEV2RecoveryEpochMetadata
    let senderPublicSigningKeyB64: String
    let envelope: E2EEV2RecoveryEpochEnvelope
}

enum E2EEV2RecoveryEpochCryptoError: Error, Equatable {
    case invalidContext
    case invalidEpochKey
    case invalidNonce
    case invalidEnvelope
    case commitmentMismatch
}

enum E2EEV2RecoveryEpochCrypto {
    static let wrapAlgorithm = "P256_X963_ECDH_HKDF_SHA256_AES_256_GCM"
    static let kdfInfo = "signalquest-e2ee-v2-recovery-epoch-wrap-v1"

    static func saltCanonical(_ context: E2EEV2RecoveryEpochContext) throws -> Data {
        try validate(context)
        return Data([
            "SQ-E2EE-V2-RECOVERY-EPOCH-SALT",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientUserId,
            context.recoveryBundleHash,
        ].joined(separator: "\n").utf8)
    }

    static func salt(_ context: E2EEV2RecoveryEpochContext) throws -> Data {
        Data(SHA256.hash(data: try saltCanonical(context)))
    }

    static func deriveWrappingKey(
        sharedSecret: SharedSecret,
        context: E2EEV2RecoveryEpochContext
    ) throws -> Data {
        let material = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: try salt(context),
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func aad(
        context: E2EEV2RecoveryEpochContext,
        keyCommitmentB64: String,
        ephemeralPublicKeyB64: String
    ) throws -> Data {
        try validate(context)
        guard let commitment = Data(base64Encoded: keyCommitmentB64),
              commitment.count == 32,
              let ephemeral = Data(base64Encoded: ephemeralPublicKeyB64),
              ephemeral.count == 65,
              ephemeral.first == 4 else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEnvelope
        }
        return Data([
            "SQ-E2EE-V2-RECOVERY-EPOCH-ENVELOPE",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientUserId,
            context.recoveryBundleHash,
            keyCommitmentB64,
            ephemeralPublicKeyB64,
        ].joined(separator: "\n").utf8)
    }

    static func signatureCanonical(
        context: E2EEV2RecoveryEpochContext,
        keyCommitmentB64: String,
        envelope: E2EEV2RecoveryEpochEnvelope
    ) throws -> Data {
        try validate(context)
        guard envelope.recipientUserId == context.recipientUserId,
              envelope.recoveryBundleHash == context.recoveryBundleHash,
              envelope.wrapAlgorithm == wrapAlgorithm,
              Data(base64Encoded: keyCommitmentB64)?.count == 32,
              Data(base64Encoded: envelope.ephemeralPublicKeyB64)?.count == 65,
              Data(base64Encoded: envelope.nonceB64)?.count == 12,
              Data(base64Encoded: envelope.wrappedEpochKeyB64)?.count == 48,
              Data(base64Encoded: envelope.aadB64) != nil else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEnvelope
        }
        return Data([
            "SQ-E2EE-V2-RECOVERY-EPOCH-ENVELOPE-SIGNATURE",
            "1",
            context.conversationId,
            String(context.epochNumber),
            context.senderDeviceId,
            context.recipientUserId,
            context.recoveryBundleHash,
            envelope.wrapAlgorithm,
            keyCommitmentB64,
            envelope.ephemeralPublicKeyB64,
            envelope.nonceB64,
            envelope.aadB64,
            envelope.wrappedEpochKeyB64,
        ].joined(separator: "\n").utf8)
    }

    static func wrap(
        epochKey: Data,
        keyCommitmentB64: String,
        recipientPublicKey: P256.KeyAgreement.PublicKey,
        ephemeralPrivateKey: P256.KeyAgreement.PrivateKey,
        nonce: Data,
        context: E2EEV2RecoveryEpochContext
    ) throws -> E2EEV2RecoveryEpochEnvelope {
        guard epochKey.count == 32,
              try E2EEV2EpochCrypto.keyCommitment(epochKey) == keyCommitmentB64 else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEpochKey
        }
        guard nonce.count == 12 else { throw E2EEV2RecoveryEpochCryptoError.invalidNonce }
        let ephemeralB64 = ephemeralPrivateKey.publicKey.x963Representation.base64EncodedString()
        let additionalData = try aad(
            context: context,
            keyCommitmentB64: keyCommitmentB64,
            ephemeralPublicKeyB64: ephemeralB64
        )
        let shared = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let sealed = try AES.GCM.seal(
            epochKey,
            using: SymmetricKey(data: try deriveWrappingKey(sharedSecret: shared, context: context)),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: additionalData
        )
        return .init(
            recipientUserId: context.recipientUserId,
            recoveryBundleHash: context.recoveryBundleHash,
            wrapAlgorithm: wrapAlgorithm,
            ephemeralPublicKeyB64: ephemeralB64,
            wrappedEpochKeyB64: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            nonceB64: nonce.base64EncodedString(),
            aadB64: additionalData.base64EncodedString(),
            signatureB64: ""
        )
    }

    static func unwrap(
        delivery: E2EEV2RecoveryEpochDelivery,
        recoveryPrivateIdentityKey: P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let context = E2EEV2RecoveryEpochContext(
            conversationId: delivery.metadata.conversationId,
            epochNumber: delivery.metadata.epochNumber,
            senderDeviceId: delivery.metadata.senderDeviceId,
            recipientUserId: delivery.envelope.recipientUserId,
            recoveryBundleHash: delivery.envelope.recoveryBundleHash
        )
        guard delivery.envelope.wrapAlgorithm == wrapAlgorithm,
              let ephemeralData = Data(base64Encoded: delivery.envelope.ephemeralPublicKeyB64),
              ephemeralData.count == 65,
              ephemeralData.first == 4,
              let wrapped = Data(base64Encoded: delivery.envelope.wrappedEpochKeyB64),
              wrapped.count == 48,
              let nonce = Data(base64Encoded: delivery.envelope.nonceB64),
              nonce.count == 12,
              let suppliedAAD = Data(base64Encoded: delivery.envelope.aadB64) else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEnvelope
        }
        let expectedAAD = try aad(
            context: context,
            keyCommitmentB64: delivery.metadata.keyCommitmentB64,
            ephemeralPublicKeyB64: delivery.envelope.ephemeralPublicKeyB64
        )
        guard suppliedAAD == expectedAAD else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEnvelope
        }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        let shared = try recoveryPrivateIdentityKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: wrapped.prefix(32),
            tag: wrapped.suffix(16)
        )
        let clear = try AES.GCM.open(
            box,
            using: SymmetricKey(data: try deriveWrappingKey(sharedSecret: shared, context: context)),
            authenticating: suppliedAAD
        )
        guard clear.count == 32,
              try E2EEV2EpochCrypto.keyCommitment(clear) == delivery.metadata.keyCommitmentB64 else {
            throw E2EEV2RecoveryEpochCryptoError.commitmentMismatch
        }
        return clear
    }

    private static func validate(_ context: E2EEV2RecoveryEpochContext) throws {
        let opaque = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
        guard context.conversationId.range(of: opaque, options: .regularExpression) != nil,
              context.senderDeviceId.range(of: opaque, options: .regularExpression) != nil,
              context.recipientUserId.range(of: opaque, options: .regularExpression) != nil,
              context.recoveryBundleHash.range(
                of: #"^[a-f0-9]{64}\z"#,
                options: .regularExpression
              ) != nil,
              context.epochNumber > 0 else {
            throw E2EEV2RecoveryEpochCryptoError.invalidContext
        }
    }
}

// MARK: - E2EE v2 current epoch delivery (preview, fail-closed)

struct E2EEV2EpochKeyRecordInput: Equatable, Sendable {
    let conversationId: String
    let epochId: String
    let epochNumber: Int
    let keyCommitmentB64: String
}

enum E2EEV2EpochKeyStoreError: Error, Equatable {
    case invalidIndex
}

/// Keychain cache scoped by account and conversation. The current pointer only
/// advances, while authenticated historical epochs remain addressable for
/// history decryption. A same-number substitution is always rejected.
final class E2EEV2EpochKeyStore: @unchecked Sendable {
    private struct Record: Codable {
        let version: Int
        let conversationId: String
        let epochId: String
        let epochNumber: Int
        let keyCommitmentB64: String
        let epochKeyB64: String
        let storedAtMs: Int64
    }

    private struct Index: Codable {
        let version: Int
        let epochNumbers: [Int]
    }

    private struct OwnerIndex: Codable {
        let version: Int
        let conversationIds: [String]
    }

    private let tokenStore: TokenStore
    private static let sharedLock = NSLock()
    private var lock: NSLock { Self.sharedLock }
    private let allowsOwner: @Sendable (String) -> Bool
    private static let maxHistoryCount = 10_000
    private static let maxConversationCount = 10_000

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    @discardableResult
    func put(
        delivery: E2EEV2EpochDelivery,
        epochKey: Data,
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws -> Bool {
        try put(
            recordInput: .init(
                conversationId: delivery.conversationId,
                epochId: delivery.epochId,
                epochNumber: delivery.epochNumber,
                keyCommitmentB64: delivery.keyCommitmentB64
            ),
            epochKey: epochKey,
            ownerNamespace: ownerNamespace,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func put(
        recordInput: E2EEV2EpochKeyRecordInput,
        epochKey: Data,
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws -> Bool {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard expectedSession == nil || (expectedSession?.isCurrent == true && expectedSession?.ownerNamespace == ownerNamespace) else {
            throw CancellationError()
        }
        guard epochKey.count == 32,
              validOpaqueId(recordInput.conversationId),
              validOpaqueId(recordInput.epochId),
              recordInput.epochNumber > 0,
              try E2EEV2EpochCrypto.keyCommitment(epochKey) == recordInput.keyCommitmentB64 else {
            return false
        }
        // Annoncé une fois le verrou rendu : un observateur peut relire le coffre.
        var advanced = false
        defer {
            if advanced {
                E2EEV2EpochEvents.postAdvance(
                    conversationId: recordInput.conversationId,
                    epochNumber: recordInput.epochNumber,
                    ownerNamespace: ownerNamespace
                )
            }
        }
        lock.lock()
        defer { lock.unlock() }

        try registerConversationLocked(
            recordInput.conversationId,
            ownerNamespace: ownerNamespace,
            expectedSession: expectedSession
        )

        let currentKey = storageKey(
            ownerNamespace: ownerNamespace,
            conversationId: recordInput.conversationId
        )
        let current: E2EEV2StoredEpochKey?
        if let raw = try tokenStore.string(for: currentKey) {
            guard let parsed = parse(raw), parsed.conversationId == recordInput.conversationId else {
                return false
            }
            current = parsed
            if parsed.epochNumber == recordInput.epochNumber,
               !matches(parsed, recordInput: recordInput, epochKey: epochKey) {
                return false
            }
        } else {
            current = nil
        }

        let historicalKey = historyStorageKey(
            ownerNamespace: ownerNamespace,
            conversationId: recordInput.conversationId,
            epochNumber: recordInput.epochNumber
        )
        if let raw = try tokenStore.string(for: historicalKey) {
            guard let historical = parse(raw),
                  historical.conversationId == recordInput.conversationId,
                  matches(historical, recordInput: recordInput, epochKey: epochKey) else {
                return false
            }
        }

        var index = try loadIndexLocked(
            ownerNamespace: ownerNamespace,
            conversationId: recordInput.conversationId
        )
        if !index.contains(recordInput.epochNumber) {
            guard index.count < Self.maxHistoryCount else { return false }
            index.append(recordInput.epochNumber)
            index.sort()
            try writeIndexLocked(
                index,
                ownerNamespace: ownerNamespace,
                conversationId: recordInput.conversationId,
                expectedSession: expectedSession
            )
        }

        let record = Record(
            version: 1,
            conversationId: recordInput.conversationId,
            epochId: recordInput.epochId,
            epochNumber: recordInput.epochNumber,
            keyCommitmentB64: recordInput.keyCommitmentB64,
            epochKeyB64: epochKey.base64EncodedString(),
            storedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let encoded = try JSONEncoder().encode(record)
        guard let value = String(data: encoded, encoding: .utf8) else { return false }
        try publish(value, key: historicalKey, expectedSession: expectedSession)
        if current == nil || recordInput.epochNumber > current!.epochNumber {
            try publish(value, key: currentKey, expectedSession: expectedSession)
            advanced = true
        }
        return true
    }

    func load(conversationId: String, ownerNamespace: String) throws -> E2EEV2StoredEpochKey? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        lock.lock()
        defer { lock.unlock() }
        let key = storageKey(ownerNamespace: ownerNamespace, conversationId: conversationId)
        guard let raw = try tokenStore.string(for: key),
              let stored = parse(raw),
              stored.conversationId == conversationId else { return nil }
        return stored
    }

    func loadEpoch(
        conversationId: String,
        epochNumber: Int,
        ownerNamespace: String
    ) throws -> E2EEV2StoredEpochKey? {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard epochNumber > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let historyKey = historyStorageKey(
            ownerNamespace: ownerNamespace,
            conversationId: conversationId,
            epochNumber: epochNumber
        )
        if let raw = try tokenStore.string(for: historyKey) {
            guard let stored = parse(raw),
                  stored.conversationId == conversationId,
                  stored.epochNumber == epochNumber else { return nil }
            return stored
        }

        // Compatibility with the pre-history format: the old current record
        // remains readable until a subsequent put indexes it.
        let currentKey = storageKey(ownerNamespace: ownerNamespace, conversationId: conversationId)
        guard let raw = try tokenStore.string(for: currentKey),
              let current = parse(raw),
              current.conversationId == conversationId,
              current.epochNumber == epochNumber else { return nil }
        return current
    }

    func remove(conversationId: String, ownerNamespace: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeConversationLocked(conversationId: conversationId, ownerNamespace: ownerNamespace)
        var ownerIndex = try loadOwnerIndexLocked(ownerNamespace: ownerNamespace)
        ownerIndex.removeAll { $0 == conversationId }
        try writeOwnerIndexLocked(ownerIndex, ownerNamespace: ownerNamespace)
    }

    /// Removes only this account's v2 conversation epochs. The owner index is
    /// maintained before every epoch write, so identity reset never needs to
    /// wipe the shared Keychain service or another account's secrets.
    func removeAll(ownerNamespace: String, expectedSession: LocalAccountSession? = nil) throws {
        guard expectedSession == nil || (expectedSession?.isCurrent == true && expectedSession?.ownerNamespace == ownerNamespace) else {
            throw CancellationError()
        }
        lock.lock()
        defer { lock.unlock() }
        let conversations = try loadOwnerIndexLocked(ownerNamespace: ownerNamespace)
        for conversationId in conversations {
            try removeConversationLocked(
                conversationId: conversationId,
                ownerNamespace: ownerNamespace,
                expectedSession: expectedSession
            )
        }
        let legacyPrefixes = [
            "epoch-v2:\(ownerNamespace):",
            "epoch-v2-history:\(ownerNamespace):",
            "epoch-v2-index:\(ownerNamespace):",
        ]
        for prefix in legacyPrefixes {
            for key in try tokenStore.keys(withPrefix: prefix) {
                try erase(key, expectedSession: expectedSession)
            }
        }
        try erase(ownerIndexStorageKey(ownerNamespace: ownerNamespace), expectedSession: expectedSession)
    }

    private func removeConversationLocked(
        conversationId: String,
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws {
        let indexKey = indexStorageKey(ownerNamespace: ownerNamespace, conversationId: conversationId)
        let epochNumbers: [Int]
        if let raw = try tokenStore.string(for: indexKey) {
            guard let parsed = parseIndex(raw) else { throw E2EEV2EpochKeyStoreError.invalidIndex }
            epochNumbers = parsed
        } else {
            epochNumbers = []
        }
        for epochNumber in epochNumbers {
            try erase(historyStorageKey(
                ownerNamespace: ownerNamespace,
                conversationId: conversationId,
                epochNumber: epochNumber
            ), expectedSession: expectedSession)
        }
        try erase(indexKey, expectedSession: expectedSession)
        try erase(storageKey(ownerNamespace: ownerNamespace, conversationId: conversationId), expectedSession: expectedSession)
    }

    private func erase(_ key: String, expectedSession: LocalAccountSession?) throws {
        if let expectedSession {
            try LocalAccountScope.publish(for: expectedSession) { try tokenStore.remove(key) }
        } else { try tokenStore.remove(key) }
    }

    private func parse(_ raw: String) -> E2EEV2StoredEpochKey? {
        guard let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1,
              record.epochNumber > 0,
              let epochKey = Data(base64Encoded: record.epochKeyB64),
              epochKey.count == 32,
              (try? E2EEV2EpochCrypto.keyCommitment(epochKey)) == record.keyCommitmentB64 else {
            return nil
        }
        return E2EEV2StoredEpochKey(
            conversationId: record.conversationId,
            epochId: record.epochId,
            epochNumber: record.epochNumber,
            keyCommitmentB64: record.keyCommitmentB64,
            epochKey: epochKey
        )
    }

    private func storageKey(ownerNamespace: String, conversationId: String) -> String {
        "epoch-v2:\(ownerNamespace):\(conversationDigest(conversationId))"
    }

    private func historyStorageKey(
        ownerNamespace: String,
        conversationId: String,
        epochNumber: Int
    ) -> String {
        "epoch-v2-history:\(ownerNamespace):\(conversationDigest(conversationId)):\(epochNumber)"
    }

    private func indexStorageKey(ownerNamespace: String, conversationId: String) -> String {
        "epoch-v2-index:\(ownerNamespace):\(conversationDigest(conversationId))"
    }

    func ownerIndexStorageKey(ownerNamespace: String) -> String {
        "epoch-v2-owner-index:\(ownerNamespace)"
    }

    private func conversationDigest(_ conversationId: String) -> String {
        SHA256.hash(data: Data(conversationId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadIndexLocked(ownerNamespace: String, conversationId: String) throws -> [Int] {
        let key = indexStorageKey(ownerNamespace: ownerNamespace, conversationId: conversationId)
        guard let raw = try tokenStore.string(for: key) else { return [] }
        guard let index = parseIndex(raw) else { throw E2EEV2EpochKeyStoreError.invalidIndex }
        return index
    }

    private func writeIndexLocked(
        _ epochNumbers: [Int],
        ownerNamespace: String,
        conversationId: String,
        expectedSession: LocalAccountSession? = nil
    ) throws {
        let encoded = try JSONEncoder().encode(Index(version: 1, epochNumbers: epochNumbers))
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw E2EEV2EpochKeyStoreError.invalidIndex
        }
        try publish(value, key: indexStorageKey(ownerNamespace: ownerNamespace, conversationId: conversationId), expectedSession: expectedSession)
    }

    private func registerConversationLocked(
        _ conversationId: String,
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws {
        var conversations = try loadOwnerIndexLocked(ownerNamespace: ownerNamespace)
        guard !conversations.contains(conversationId) else { return }
        guard conversations.count < Self.maxConversationCount else {
            throw E2EEV2EpochKeyStoreError.invalidIndex
        }
        conversations.append(conversationId)
        conversations.sort()
        try writeOwnerIndexLocked(conversations, ownerNamespace: ownerNamespace, expectedSession: expectedSession)
    }

    private func loadOwnerIndexLocked(ownerNamespace: String) throws -> [String] {
        let key = ownerIndexStorageKey(ownerNamespace: ownerNamespace)
        guard let raw = try tokenStore.string(for: key) else { return [] }
        guard let index = parseOwnerIndex(raw) else {
            throw E2EEV2EpochKeyStoreError.invalidIndex
        }
        return index
    }

    private func writeOwnerIndexLocked(
        _ conversationIds: [String],
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws {
        let key = ownerIndexStorageKey(ownerNamespace: ownerNamespace)
        if conversationIds.isEmpty {
            try tokenStore.remove(key)
            return
        }
        let encoded = try JSONEncoder().encode(
            OwnerIndex(version: 1, conversationIds: conversationIds)
        )
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw E2EEV2EpochKeyStoreError.invalidIndex
        }
        try publish(value, key: key, expectedSession: expectedSession)
    }

    private func publish(_ value: String, key: String, expectedSession: LocalAccountSession?) throws {
        // Encodage et crypto sont déjà terminés ; un seul enregistrement Keychain par publication.
        if let expectedSession {
            try LocalAccountScope.publish(for: expectedSession) {
                try tokenStore.set(value, for: key, accessibility: .whenUnlocked)
            }
        } else {
            try tokenStore.set(value, for: key, accessibility: .whenUnlocked)
        }
    }

    private func parseIndex(_ raw: String) -> [Int]? {
        guard let data = raw.data(using: .utf8),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.version == 1,
              index.epochNumbers.count <= Self.maxHistoryCount,
              index.epochNumbers.allSatisfy({ $0 > 0 }),
              index.epochNumbers == Array(Set(index.epochNumbers)).sorted() else { return nil }
        return index.epochNumbers
    }

    private func parseOwnerIndex(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let index = try? JSONDecoder().decode(OwnerIndex.self, from: data),
              index.version == 1,
              index.conversationIds.count <= Self.maxConversationCount,
              index.conversationIds.allSatisfy(validOpaqueId),
              index.conversationIds == Array(Set(index.conversationIds)).sorted() else {
            return nil
        }
        return index.conversationIds
    }

    private func matches(
        _ stored: E2EEV2StoredEpochKey,
        recordInput: E2EEV2EpochKeyRecordInput,
        epochKey: Data
    ) -> Bool {
        stored.epochId == recordInput.epochId
            && stored.epochNumber == recordInput.epochNumber
            && stored.keyCommitmentB64 == recordInput.keyCommitmentB64
            && stored.epochKey == epochKey
    }

    private func validOpaqueId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#, options: .regularExpression) != nil
    }
}

// MARK: - E2EE v2 historical epoch recovery (preview, fail-closed)

enum E2EEV2RecoveryEpochParser {
    private struct Response: Decodable {
        struct Epoch: Decodable {
            let epochId: String
            let epochNumber: Int
            let algorithm: String
            let keyCommitmentB64: String
            let reason: String
            let status: String
            let createdAt: String
        }

        struct SenderDevice: Decodable {
            let deviceId: String
            let publicSigningKeyB64: String
        }

        let recoveryEnvelopeId: String
        let conversationId: String
        let epoch: Epoch
        let senderDevice: SenderDevice
        let envelope: E2EEV2RecoveryEpochEnvelope
    }

    private static let reasons: Set<String> = [
        "INITIAL", "DEVICE_ADDED", "DEVICE_REVOKED", "MEMBER_ADDED",
        "MEMBER_REMOVED", "RECOVERY", "IDENTITY_RESET", "MANUAL",
    ]
    private static let statuses: Set<String> = ["active", "retired", "compromised"]

    static func parseAndVerify(
        _ data: Data,
        expectedRecipientUserId: String,
        expectedRecoveryBundleHash: String
    ) -> E2EEV2RecoveryEpochDelivery? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              validOpaqueId(expectedRecipientUserId),
              validBundleHash(expectedRecoveryBundleHash),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["recoveryEnvelopeId", "conversationId", "epoch", "senderDevice", "envelope"]),
              let epoch = root["epoch"] as? [String: Any],
              exactKeys(
                epoch,
                ["epochId", "epochNumber", "algorithm", "keyCommitmentB64", "reason", "status", "createdAt"]
              ),
              let sender = root["senderDevice"] as? [String: Any],
              exactKeys(sender, ["deviceId", "publicSigningKeyB64"]),
              let envelope = root["envelope"] as? [String: Any],
              exactKeys(
                envelope,
                [
                    "recipientUserId", "recoveryBundleHash", "wrapAlgorithm",
                    "ephemeralPublicKeyB64", "wrappedEpochKeyB64", "nonceB64",
                    "aadB64", "signatureB64",
                ]
              ),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              validOpaqueId(response.recoveryEnvelopeId),
              validOpaqueId(response.conversationId),
              validOpaqueId(response.epoch.epochId),
              response.epoch.epochNumber > 0,
              response.epoch.algorithm == "AES_256_GCM_HKDF_SHA256",
              validBase64(response.epoch.keyCommitmentB64, bytes: 32),
              reasons.contains(response.epoch.reason),
              statuses.contains(response.epoch.status),
              validISO8601(response.epoch.createdAt),
              validOpaqueId(response.senderDevice.deviceId),
              validBase64(response.senderDevice.publicSigningKeyB64, bytes: 65, x963: true),
              response.envelope.recipientUserId == expectedRecipientUserId,
              response.envelope.recoveryBundleHash == expectedRecoveryBundleHash,
              response.envelope.wrapAlgorithm == E2EEV2RecoveryEpochCrypto.wrapAlgorithm,
              validBase64(response.envelope.ephemeralPublicKeyB64, bytes: 65, x963: true),
              validBase64(response.envelope.wrappedEpochKeyB64, bytes: 48),
              validBase64(response.envelope.nonceB64, bytes: 12),
              let suppliedAAD = Data(base64Encoded: response.envelope.aadB64),
              let signingPublicData = Data(base64Encoded: response.senderDevice.publicSigningKeyB64),
              let signatureData = Data(base64Encoded: response.envelope.signatureB64) else {
            return nil
        }

        let metadata = E2EEV2RecoveryEpochMetadata(
            conversationId: response.conversationId,
            epochId: response.epoch.epochId,
            epochNumber: response.epoch.epochNumber,
            algorithm: response.epoch.algorithm,
            keyCommitmentB64: response.epoch.keyCommitmentB64,
            reason: response.epoch.reason,
            status: response.epoch.status,
            createdAt: response.epoch.createdAt,
            senderDeviceId: response.senderDevice.deviceId
        )
        let delivery = E2EEV2RecoveryEpochDelivery(
            recoveryEnvelopeId: response.recoveryEnvelopeId,
            metadata: metadata,
            senderPublicSigningKeyB64: response.senderDevice.publicSigningKeyB64,
            envelope: response.envelope
        )
        let context = E2EEV2RecoveryEpochContext(
            conversationId: metadata.conversationId,
            epochNumber: metadata.epochNumber,
            senderDeviceId: metadata.senderDeviceId,
            recipientUserId: response.envelope.recipientUserId,
            recoveryBundleHash: response.envelope.recoveryBundleHash
        )
        do {
            let expectedAAD = try E2EEV2RecoveryEpochCrypto.aad(
                context: context,
                keyCommitmentB64: metadata.keyCommitmentB64,
                ephemeralPublicKeyB64: response.envelope.ephemeralPublicKeyB64
            )
            guard suppliedAAD == expectedAAD else { return nil }
            let signingPublic = try P256.Signing.PublicKey(x963Representation: signingPublicData)
            let canonical = try E2EEV2RecoveryEpochCrypto.signatureCanonical(
                context: context,
                keyCommitmentB64: metadata.keyCommitmentB64,
                envelope: response.envelope
            )
            return E2EEV2LowS.verify(derSignature: signatureData, message: canonical, publicKey: signingPublic) ? delivery : nil
        } catch {
            return nil
        }
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    fileprivate static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#, options: .regularExpression) != nil
    }

    fileprivate static func validBundleHash(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil
    }

    fileprivate static func validBase64(_ value: String, bytes: Int, x963: Bool = false) -> Bool {
        guard value.count <= 2_048,
              let decoded = Data(base64Encoded: value),
              decoded.count == bytes else { return false }
        return !x963 || decoded.first == 4
    }

    fileprivate static func validISO8601(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value) != nil
    }
}

struct E2EEV2RecoveryEpochPage: Equatable, Sendable {
    let deliveries: [E2EEV2RecoveryEpochDelivery]
    let missingEpochCount: Int
    let nextCursor: String?
}

struct E2EEV2RecoveryEpochBackfillItem: Equatable, Sendable {
    let deviceDelivery: E2EEV2EpochDelivery
    let recoveryRecipients: [E2EEV2RecoveryEpochRecipient]
    let missingParticipantUserIds: [String]
}

struct E2EEV2RecoveryEpochBackfillPage: Equatable, Sendable {
    let items: [E2EEV2RecoveryEpochBackfillItem]
    let nextCursor: String?
}

enum E2EEV2RecoveryEpochContract {
    private static let maxRestoreItems = 50
    private static let maxBackfillItems = 5
    private static let maxRecipients = 500

    static func parseRestorePage(
        _ data: Data,
        expectedRecipientUserId: String,
        expectedRecoveryBundleHash: String
    ) -> E2EEV2RecoveryEpochPage? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let response = dictionary(data),
              exactKeys(
                response,
                ["protocolVersion", "recoveryBundleHash", "missingEpochCount", "nextCursor", "items"]
              ),
              integer(response["protocolVersion"]) == 2,
              response["recoveryBundleHash"] as? String == expectedRecoveryBundleHash,
              E2EEV2RecoveryEpochParser.validBundleHash(expectedRecoveryBundleHash),
              E2EEV2RecoveryEpochParser.validOpaqueId(expectedRecipientUserId),
              let missingEpochCount = integer(response["missingEpochCount"]),
              missingEpochCount >= 0,
              let rawItems = response["items"] as? [Any],
              rawItems.count <= maxRestoreItems,
              let nextCursor = nullableOpaqueId(response["nextCursor"]) else { return nil }

        var deliveries: [E2EEV2RecoveryEpochDelivery] = []
        var seen = Set<String>()
        for raw in rawItems {
            guard let normalized = withIntegerEpochNumber(raw),
                  JSONSerialization.isValidJSONObject(normalized),
                  let itemData = try? JSONSerialization.data(withJSONObject: normalized),
                  let delivery = E2EEV2RecoveryEpochParser.parseAndVerify(
                    itemData,
                    expectedRecipientUserId: expectedRecipientUserId,
                    expectedRecoveryBundleHash: expectedRecoveryBundleHash
                  ),
                  seen.insert(delivery.recoveryEnvelopeId).inserted else { return nil }
            deliveries.append(delivery)
        }
        return .init(
            deliveries: deliveries,
            missingEpochCount: missingEpochCount,
            nextCursor: nextCursor
        )
    }

    static func parseBackfillPage(
        _ data: Data,
        expectedRecipientDeviceId: String
    ) -> E2EEV2RecoveryEpochBackfillPage? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              E2EEV2RecoveryEpochParser.validOpaqueId(expectedRecipientDeviceId),
              let response = dictionary(data),
              exactKeys(response, ["protocolVersion", "items", "nextCursor"]),
              integer(response["protocolVersion"]) == 2,
              let rawItems = response["items"] as? [Any],
              rawItems.count <= maxBackfillItems,
              let nextCursor = nullableOpaqueId(response["nextCursor"]) else { return nil }

        var items: [E2EEV2RecoveryEpochBackfillItem] = []
        var seenEpochIds = Set<String>()
        for raw in rawItems {
            guard let item = raw as? [String: Any],
                  exactKeys(
                    item,
                    [
                        "conversationId", "epoch", "senderDevice", "deviceEnvelope",
                        "recoveryRecipients", "missingParticipantUserIds",
                    ]
                  ),
                  let conversationId = item["conversationId"] as? String,
                  E2EEV2RecoveryEpochParser.validOpaqueId(conversationId),
                  let epoch = (withIntegerEpochNumber(["epoch": item["epoch"] as Any]) as? [String: Any])?["epoch"] as? [String: Any],
                  let sender = item["senderDevice"] as? [String: Any] else { return nil }
            // Époque dont cet appareil n'a pas l'enveloppe : il ne peut pas la
            // recopier, un autre appareil du compte le fera.
            if item["deviceEnvelope"] is NSNull { continue }
            guard let deviceEnvelope = item["deviceEnvelope"] as? [String: Any],
                  let deliveryData = try? JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 2,
                    "conversationId": conversationId,
                    "epoch": epoch,
                    "senderDevice": sender,
                    "envelope": deviceEnvelope,
                  ]),
                  let delivery = E2EEV2EpochDeliveryContract.parseAndVerify(
                    deliveryData,
                    expectedConversationId: conversationId,
                    expectedRecipientDeviceId: expectedRecipientDeviceId,
                    allowedStatuses: ["active", "retired", "compromised"]
                  ),
                  seenEpochIds.insert(delivery.epochId).inserted,
                  let rawRecipients = item["recoveryRecipients"] as? [Any],
                  (1...maxRecipients).contains(rawRecipients.count),
                  let rawMissing = item["missingParticipantUserIds"] as? [Any],
                  rawMissing.count <= maxRecipients else { return nil }

            var recipients: [E2EEV2RecoveryEpochRecipient] = []
            var recipientIds = Set<String>()
            for rawRecipient in rawRecipients {
                guard let recipient = rawRecipient as? [String: Any],
                      exactKeys(
                        recipient,
                        ["recipientUserId", "recoveryBundleHash", "recoveryPublicIdentityKeyB64", "signatureB64", "deviceListVersion"]
                      ),
                      E2EEV2RecoveryV2Contract.listVersion(recipient["deviceListVersion"]) != nil,
                      // Signature de l'UIK sur ce bundle (§2.8) : seul le bundle que
                      // cet appareil connaît est enveloppé (`ownRecipients`).
                      (recipient["signatureB64"] as? String).flatMap({ Data(base64Encoded: $0) }) != nil,
                      let recipientUserId = recipient["recipientUserId"] as? String,
                      E2EEV2RecoveryEpochParser.validOpaqueId(recipientUserId),
                      recipientIds.insert(recipientUserId).inserted,
                      let recoveryBundleHash = recipient["recoveryBundleHash"] as? String,
                      E2EEV2RecoveryEpochParser.validBundleHash(recoveryBundleHash),
                      let publicKey = recipient["recoveryPublicIdentityKeyB64"] as? String,
                      E2EEV2RecoveryEpochParser.validBase64(publicKey, bytes: 65, x963: true) else {
                    return nil
                }
                recipients.append(.init(
                    recipientUserId: recipientUserId,
                    recoveryBundleHash: recoveryBundleHash,
                    recoveryPublicIdentityKeyB64: publicKey
                ))
            }

            var missingIds: [String] = []
            var seenMissing = Set<String>()
            for rawId in rawMissing {
                guard let id = rawId as? String,
                      E2EEV2RecoveryEpochParser.validOpaqueId(id),
                      !recipientIds.contains(id),
                      seenMissing.insert(id).inserted else { return nil }
                missingIds.append(id)
            }
            items.append(.init(
                deviceDelivery: delivery,
                recoveryRecipients: recipients,
                missingParticipantUserIds: missingIds
            ))
        }
        return .init(items: items, nextCursor: nextCursor)
    }

    /// `epoch.epochNumber` en chaîne (D.0) ramené à l'entier qu'attendent les
    /// lecteurs stricts ; nil pour toute autre forme.
    private static func withIntegerEpochNumber(_ raw: Any) -> Any? {
        guard var item = raw as? [String: Any], var epoch = item["epoch"] as? [String: Any] else { return raw }
        guard let number = integer(epoch["epochNumber"]) else { return nil }
        epoch["epochNumber"] = number
        item["epoch"] = epoch
        return item
    }

    /// §2.8 : un appareil n'enveloppe une clé d'époque que vers la clé de
    /// récupération de son propre compte, jamais vers celle d'un autre membre.
    /// Le serveur ne choisit pas non plus cette clé : seul le bundle que
    /// l'appareil connaît (empreinte et clé publique) est accepté.
    static func ownRecipients(
        _ recipients: [E2EEV2RecoveryEpochRecipient],
        userId: String,
        ownBundle: E2EEV2RecoveryBundleV2
    ) -> [E2EEV2RecoveryEpochRecipient] {
        let hash = E2EEV2RecoveryV2Crypto.bundleHash(ownBundle)
        return recipients.filter {
            $0.recipientUserId == userId && $0.recoveryBundleHash == hash
                && $0.recoveryPublicIdentityKeyB64 == ownBundle.recoveryPublicIdentityKeyB64
        }
    }

    static func uploadData(_ envelopes: [E2EEV2RecoveryEpochEnvelope]) throws -> Data {
        guard (1...maxRecipients).contains(envelopes.count),
              Set(envelopes.map(\.recipientUserId)).count == envelopes.count,
              envelopes.allSatisfy(validEnvelope) else {
            throw E2EEV2RecoveryEpochCryptoError.invalidEnvelope
        }
        let objects: [[String: Any]] = envelopes.map { envelope in
            [
                "recipientUserId": envelope.recipientUserId,
                "recoveryBundleHash": envelope.recoveryBundleHash,
                "wrapAlgorithm": envelope.wrapAlgorithm,
                "ephemeralPublicKeyB64": envelope.ephemeralPublicKeyB64,
                "wrappedEpochKeyB64": envelope.wrappedEpochKeyB64,
                "nonceB64": envelope.nonceB64,
                "aadB64": envelope.aadB64,
                "signatureB64": envelope.signatureB64,
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["recoveryEnvelopes": objects],
            options: [.sortedKeys]
        )
    }

    static func parseUploadReceipt(
        _ data: Data,
        expectedConversationId: String,
        expectedEpochId: String,
        expectedRecipientCount: Int,
        expectedMissingParticipantUserIds: [String]
    ) -> Bool {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              E2EEV2RecoveryEpochParser.validOpaqueId(expectedConversationId),
              E2EEV2RecoveryEpochParser.validOpaqueId(expectedEpochId),
              (1...maxRecipients).contains(expectedRecipientCount),
              expectedMissingParticipantUserIds.count <= maxRecipients,
              Set(expectedMissingParticipantUserIds).count == expectedMissingParticipantUserIds.count,
              expectedMissingParticipantUserIds.allSatisfy(
                E2EEV2RecoveryEpochParser.validOpaqueId
              ),
              let response = dictionary(data),
              exactKeys(
                response,
                ["stored", "conversationId", "epochId", "recipientCount", "missingParticipantUserIds"]
              ),
              response["stored"] as? Bool == true,
              response["conversationId"] as? String == expectedConversationId,
              response["epochId"] as? String == expectedEpochId,
              integer(response["recipientCount"]) == expectedRecipientCount,
              let rawMissing = response["missingParticipantUserIds"] as? [Any],
              rawMissing.count <= maxRecipients else { return false }
        var missing: [String] = []
        var seen = Set<String>()
        for rawId in rawMissing {
            guard let id = rawId as? String,
                  E2EEV2RecoveryEpochParser.validOpaqueId(id),
                  seen.insert(id).inserted else { return false }
            missing.append(id)
        }
        return missing.sorted() == expectedMissingParticipantUserIds.sorted()
    }

    private static func validEnvelope(_ envelope: E2EEV2RecoveryEpochEnvelope) -> Bool {
        guard E2EEV2RecoveryEpochParser.validOpaqueId(envelope.recipientUserId),
              E2EEV2RecoveryEpochParser.validBundleHash(envelope.recoveryBundleHash),
              envelope.wrapAlgorithm == E2EEV2RecoveryEpochCrypto.wrapAlgorithm,
              E2EEV2RecoveryEpochParser.validBase64(
                envelope.ephemeralPublicKeyB64,
                bytes: 65,
                x963: true
              ),
              E2EEV2RecoveryEpochParser.validBase64(envelope.wrappedEpochKeyB64, bytes: 48),
              E2EEV2RecoveryEpochParser.validBase64(envelope.nonceB64, bytes: 12),
              let aad = Data(base64Encoded: envelope.aadB64),
              !aad.isEmpty,
              aad.count <= 2_048,
              let signatureData = Data(base64Encoded: envelope.signatureB64),
              signatureData.count <= 80,
              (try? P256.Signing.ECDSASignature(derRepresentation: signatureData)) != nil else {
            return false
        }
        return true
    }

    private static func dictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    private static func integer(_ value: Any?) -> Int? {
        // D.0 : entiers en chaînes décimales canoniques ; un nombre JSON reste lu.
        if let string = value as? String {
            guard string.range(of: #"^(0|[1-9][0-9]{0,15})\z"#, options: .regularExpression) != nil else { return nil }
            return Int(string)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    /// Optional cursor parser whose outer optional distinguishes malformed
    /// values from the valid JSON null cursor.
    private static func nullableOpaqueId(_ value: Any?) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let string = value as? String,
              E2EEV2RecoveryEpochParser.validOpaqueId(string) else { return nil }
        return .some(string)
    }
}

struct E2EEV2RecoveryEpochRestoreSummary: Equatable, Sendable {
    let restoredEpochCount: Int
    let missingEpochCount: Int
}

struct E2EEV2RecoveryEpochBackfillSummary: Equatable, Sendable {
    let backedUpEpochCount: Int
    let missingParticipantUserIds: [String]
}

enum E2EEV2RecoveryEpochResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(E2EEV2TransportFailure)
}

/// Paginated and idempotent historical key recovery/backfill. No runtime
/// caller is enabled while the traceable external cryptographic review gate is
/// closed.
final class E2EEV2RecoveryEpochCoordinator: @unchecked Sendable {
    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let keyStore: E2EEV2EpochKeyStore
    private static let maxPages = 10_000

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore()
    ) {
        self.identityStore = identityStore
        self.keyStore = keyStore
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    func restoreAll(
        bundle: E2EEV2RecoveryBundleV2,
        recoveryKey: Data
    ) async -> E2EEV2RecoveryEpochResult<E2EEV2RecoveryEpochRestoreSummary> {
        guard let account = currentAccount(), recoveryKey.count == 32 else {
            return localFailure("authenticated-account-and-valid-recovery-key-required")
        }
        let expectedBundleHash = E2EEV2RecoveryV2Crypto.bundleHash(bundle)
        guard E2EEV2RecoveryEpochParser.validBundleHash(expectedBundleHash) else {
            return localFailure("invalid-e2ee-recovery-bundle")
        }
        let recoveryPrivateIdentityKey: P256.KeyAgreement.PrivateKey
        do {
            recoveryPrivateIdentityKey = try E2EEV2RecoveryV2Crypto.unwrapIdentityPrivateKey(
                bundle: bundle,
                recoveryKey: recoveryKey,
                ownerBinding: account.ownerScopeId
            )
        } catch {
            return localFailure("e2ee-recovery-key-mismatch")
        }

        var cursor: String?
        var seenCursors = Set<String>()
        var seenEnvelopeIds = Set<String>()
        var restored = 0
        var missing = 0
        for _ in 0..<Self.maxPages {
            guard accountIsCurrent(account) else { return authenticationFailure() }
            let response = await transport.getJSON(
                path: "/api/e2ee/v2/recovery-epochs",
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [],
                expectedOwnerScopeId: account.ownerScopeId,
                capabilitySet: .history
            )
            let data: Data
            switch response {
            case .failure(let error): return .failure(error)
            case .success(let value, _, _): data = value
            }
            guard accountIsCurrent(account),
                  let page = E2EEV2RecoveryEpochContract.parseRestorePage(
                    data,
                    expectedRecipientUserId: account.userId,
                    expectedRecoveryBundleHash: expectedBundleHash
                  ) else { return localFailure("invalid-e2ee-recovery-epoch-page") }
            missing = page.missingEpochCount
            for delivery in page.deliveries {
                guard seenEnvelopeIds.insert(delivery.recoveryEnvelopeId).inserted else {
                    return localFailure("duplicate-e2ee-recovery-epoch")
                }
                var epochKey: Data
                do {
                    epochKey = try E2EEV2RecoveryEpochCrypto.unwrap(
                        delivery: delivery,
                        recoveryPrivateIdentityKey: recoveryPrivateIdentityKey
                    )
                } catch {
                    return localFailure("e2ee-recovery-epoch-unwrapping-failed")
                }
                defer { epochKey.resetBytes(in: 0..<epochKey.count) }
                do {
                    guard accountIsCurrent(account),
                          try keyStore.put(
                            recordInput: delivery.metadata.keyRecord,
                            epochKey: epochKey,
                            ownerNamespace: account.ownerNamespace
                          ),
                          let stored = try keyStore.loadEpoch(
                            conversationId: delivery.metadata.conversationId,
                            epochNumber: delivery.metadata.epochNumber,
                            ownerNamespace: account.ownerNamespace
                          ),
                          stored.epochId == delivery.metadata.epochId,
                          stored.keyCommitmentB64 == delivery.metadata.keyCommitmentB64,
                          stored.epochKey == epochKey else {
                        return localFailure("e2ee-recovery-epoch-storage-or-verification-failed")
                    }
                } catch {
                    return localFailure("e2ee-recovery-epoch-storage-or-verification-failed")
                }
                restored += 1
            }
            guard let next = page.nextCursor else {
                return .success(.init(restoredEpochCount: restored, missingEpochCount: missing))
            }
            guard seenCursors.insert(next).inserted else {
                return localFailure("invalid-e2ee-recovery-cursor")
            }
            cursor = next
        }
        return localFailure("e2ee-recovery-pagination-limit-exceeded")
    }

    /// `ownBundle` : le bundle de récupération que cet appareil vient de créer ;
    /// les clés d'époque ne sont enveloppées que vers lui.
    func backfillAll(ownBundle: E2EEV2RecoveryBundleV2) async -> E2EEV2RecoveryEpochResult<E2EEV2RecoveryEpochBackfillSummary> {
        guard let account = currentAccount() else {
            return localFailure("authenticated-account-required")
        }
        let identity: E2EEV2DeviceDescriptor
        do {
            guard let loaded = try identityStore.load(ownerNamespace: account.ownerNamespace) else {
                return localFailure("e2ee-device-identity-unavailable")
            }
            identity = loaded
        } catch {
            return localFailure("e2ee-device-identity-unavailable")
        }

        var cursor: String?
        var seenCursors = Set<String>()
        var seenEpochIds = Set<String>()
        var backedUp = 0
        var missingUsers = Set<String>()
        for _ in 0..<Self.maxPages {
            guard accountIsCurrent(account) else { return authenticationFailure() }
            let response = await transport.getJSON(
                path: "/api/e2ee/v2/recovery-epochs/backfill",
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [],
                expectedOwnerScopeId: account.ownerScopeId,
                capabilitySet: .history
            )
            let data: Data
            switch response {
            case .failure(let error): return .failure(error)
            case .success(let value, _, _): data = value
            }
            guard accountIsCurrent(account),
                  let page = E2EEV2RecoveryEpochContract.parseBackfillPage(
                    data,
                    expectedRecipientDeviceId: identity.deviceId
                  ) else { return localFailure("invalid-e2ee-recovery-backfill-page") }

            for item in page.items {
                guard seenEpochIds.insert(item.deviceDelivery.epochId).inserted else {
                    return localFailure("duplicate-e2ee-recovery-backfill-epoch")
                }
                missingUsers.formUnion(item.missingParticipantUserIds)
                var epochKey: Data
                do {
                    epochKey = try identityStore.unwrapEpochKey(
                        delivery: item.deviceDelivery,
                        ownerNamespace: account.ownerNamespace
                    )
                } catch {
                    return localFailure("e2ee-backfill-epoch-unwrapping-failed")
                }
                defer { epochKey.resetBytes(in: 0..<epochKey.count) }
                do {
                    guard accountIsCurrent(account),
                          try keyStore.put(
                            delivery: item.deviceDelivery,
                            epochKey: epochKey,
                            ownerNamespace: account.ownerNamespace
                          ) else { return localFailure("e2ee-backfill-epoch-storage-failed") }

                    // §2.8 : seulement vers la clé de récupération de son propre compte.
                    let recipients = E2EEV2RecoveryEpochContract.ownRecipients(
                        item.recoveryRecipients, userId: account.userId, ownBundle: ownBundle
                    )
                    guard !recipients.isEmpty else { continue }
                    let envelopes = try recipients.map { recipient in
                        try identityStore.createSignedRecoveryEpochEnvelope(
                            context: .init(
                                conversationId: item.deviceDelivery.conversationId,
                                epochNumber: item.deviceDelivery.epochNumber,
                                senderDeviceId: identity.deviceId,
                                recipientUserId: recipient.recipientUserId,
                                recoveryBundleHash: recipient.recoveryBundleHash
                            ),
                            keyCommitmentB64: item.deviceDelivery.keyCommitmentB64,
                            epochKey: epochKey,
                            recipientPublicIdentityKeyB64: recipient.recoveryPublicIdentityKeyB64,
                            ownerNamespace: account.ownerNamespace
                        )
                    }
                    let uploadPath = "/api/e2ee/v2/conversations/\(item.deviceDelivery.conversationId)"
                        + "/epochs/\(item.deviceDelivery.epochNumber)/recovery-envelopes"
                    let receiptResponse = await transport.postJSON(
                        path: uploadPath,
                        body: try E2EEV2RecoveryEpochContract.uploadData(envelopes),
                        expectedOwnerScopeId: account.ownerScopeId,
                        capabilitySet: .history
                    )
                    let receiptData: Data
                    switch receiptResponse {
                    case .failure(let error): return .failure(error)
                    case .success(let value, _, _): receiptData = value
                    }
                    guard accountIsCurrent(account),
                          E2EEV2RecoveryEpochContract.parseUploadReceipt(
                            receiptData,
                            expectedConversationId: item.deviceDelivery.conversationId,
                            expectedEpochId: item.deviceDelivery.epochId,
                            expectedRecipientCount: envelopes.count,
                            expectedMissingParticipantUserIds: item.missingParticipantUserIds
                          ) else { return localFailure("invalid-e2ee-recovery-backfill-receipt") }
                    backedUp += 1
                } catch {
                    return localFailure("e2ee-recovery-envelope-generation-or-storage-failed")
                }
            }
            guard let next = page.nextCursor else {
                return .success(.init(
                    backedUpEpochCount: backedUp,
                    missingParticipantUserIds: missingUsers.sorted()
                ))
            }
            guard seenCursors.insert(next).inserted else {
                return localFailure("invalid-e2ee-recovery-cursor")
            }
            cursor = next
        }
        return localFailure("e2ee-recovery-pagination-limit-exceeded")
    }

    private struct Account: Equatable {
        let ownerScopeId: String
        let ownerNamespace: String
        let userId: String
    }

    private func currentAccount() -> Account? {
        guard let rawUserId = LocalAccountScope.currentUserId?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        E2EEV2RecoveryEpochParser.validOpaqueId(rawUserId) else { return nil }
        let ownerScopeId = "user:\(rawUserId)"
        guard LocalAccountScope.currentOwnerScopeId == ownerScopeId else { return nil }
        return .init(
            ownerScopeId: ownerScopeId,
            ownerNamespace: LocalAccountScope.storageNamespace(for: ownerScopeId),
            userId: rawUserId
        )
    }

    private func accountIsCurrent(_ account: Account) -> Bool {
        currentAccount() == account
    }

    private func localFailure<T: Sendable>(_ message: String) -> E2EEV2RecoveryEpochResult<T> {
        .failure(.init(kind: .localState, message: message))
    }

    private func authenticationFailure<T: Sendable>() -> E2EEV2RecoveryEpochResult<T> {
        .failure(.init(kind: .authentication, message: "account-scope-changed"))
    }
}

// MARK: - E2EE v2 runtime rotation backlog (gate remains closed)

enum E2EEV2RotationPhase: String, Codable, Sendable {
    case idle, pending, running, waitingAuthorization, retryPending, needsAttention, complete
}

struct E2EEV2RotationState: Codable, Equatable, Sendable {
    var revision: Int64 = 0
    var pending: [String: Int64] = [:]
    var scanRequired = false
    var phase: E2EEV2RotationPhase = .idle
    var attempts = 0
    var notBeforeMs: Int64 = 0
    var completedAtMs: Int64 = 0
    var hasWork: Bool { scanRequired || !pending.isEmpty }
}

/// Durable hints only; no epoch key or request token is serialized in this queue.
final class E2EEV2RotationBacklog: @unchecked Sendable {
    static let shared = E2EEV2RotationBacklog()
    static let maxAttempts = 5
    private static let lock = NSRecursiveLock()
    private let store: TokenStore
    private let now: @Sendable () -> Int64
    private let current: @Sendable (LocalAccountSession) -> Bool
    private let publish: @Sendable (LocalAccountSession, @Sendable () throws -> Void) throws -> Void

    init(
        store: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        current: @escaping @Sendable (LocalAccountSession) -> Bool = { $0.isCurrent },
        publish: @escaping @Sendable (LocalAccountSession, @Sendable () throws -> Void) throws -> Void = {
            session, write in try LocalAccountScope.publish(for: session, write)
        }
    ) {
        self.store = store; self.now = now; self.current = current; self.publish = publish
    }

    func snapshot(_ session: LocalAccountSession) throws -> E2EEV2RotationState {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard current(session) else { throw CancellationError() }
        guard let raw = try store.string(for: key(session)), let data = raw.data(using: .utf8) else {
            return .init()
        }
        let value = try JSONDecoder().decode(E2EEV2RotationState.self, from: data)
        guard value.pending.count <= 10_000, value.pending.keys.allSatisfy(E2EEV2DeviceApprovalContract.validOpaqueId) else {
            throw E2EEError.invalidKey
        }
        return value
    }

    func request(_ session: LocalAccountSession, conversations: [String], scan: Bool = true, resetRetry: Bool = false) throws {
        try change(session) { state in
            guard conversations.allSatisfy(E2EEV2DeviceApprovalContract.validOpaqueId) else { throw E2EEError.invalidKey }
            state.revision += 1
            for id in conversations { state.pending[id] = state.revision }
            guard state.pending.count <= 10_000 else { throw E2EEError.invalidKey }
            state.scanRequired = state.scanRequired || scan
            if resetRetry { state.notBeforeMs = 0 }
            if state.notBeforeMs <= now() { state.phase = .pending; state.attempts = 0 }
        }
    }

    func merge(_ session: LocalAccountSession, conversations: [String], scannedRevision: Int64) throws {
        try change(session) { state in
            let changedWhileReading = state.revision != scannedRevision
            for id in conversations where state.pending[id] == nil {
                guard E2EEV2DeviceApprovalContract.validOpaqueId(id) else { throw E2EEError.invalidKey }
                state.revision += 1; state.pending[id] = state.revision
            }
            guard state.pending.count <= 10_000 else { throw E2EEError.invalidKey }
            state.scanRequired = state.scanRequired && changedWhileReading
        }
    }

    func acknowledge(_ session: LocalAccountSession, conversation: String, ticket: Int64) throws {
        try change(session) { state in
            if state.pending[conversation] == ticket { state.pending.removeValue(forKey: conversation) }
        }
    }

    func phase(_ value: E2EEV2RotationPhase, for session: LocalAccountSession) throws {
        try change(session) { $0.phase = value }
    }

    func complete(_ session: LocalAccountSession) throws {
        try change(session) { state in
            guard !state.hasWork else { return }
            state.phase = .complete; state.attempts = 0; state.notBeforeMs = 0; state.completedAtMs = now()
        }
    }

    func failed(_ session: LocalAccountSession, kind: E2EEV2TransportFailureKind) throws -> Bool {
        var retry = false
        try change(session) { state in
            switch kind {
            case .activationBlocked: state.phase = .waitingAuthorization
            case .retryable:
                state.attempts += 1
                retry = state.attempts < Self.maxAttempts
                let delay: Int64 = retry ? 30_000 * (1 << (state.attempts - 1)) : 3_600_000
                state.notBeforeMs = now() + delay
                state.phase = retry ? .retryPending : .needsAttention
            default: state.phase = .needsAttention
            }
        }
        return retry
    }

    private func change(_ session: LocalAccountSession, _ update: (inout E2EEV2RotationState) throws -> Void) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let before = try snapshot(session)
        var state = before
        try update(&state)
        guard state != before else { return }
        let data = try JSONEncoder().encode(state)
        guard let raw = String(data: data, encoding: .utf8) else { throw E2EEError.invalidKey }
        let target = key(session)
        try publish(session) { [store] in try store.set(raw, for: target, accessibility: .whenUnlocked) }
    }

    private func key(_ session: LocalAccountSession) -> String { "rotation-work-v1:\(session.ownerNamespace)" }
}

struct E2EEV2RotationDrainDependencies: Sendable {
    let isCurrent: @Sendable () -> Bool
    let activationEnabled: @Sendable () -> Bool
    let pending: @Sendable () async -> Result<[E2EEV2EpochRotationRequirement], E2EEV2TransportFailure>
    let rotate: @Sendable (String) async -> E2EEV2EpochRotationResult
    var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
}

actor E2EEV2RotationDrain {
    private var running = false

    func run(session: LocalAccountSession, backlog: E2EEV2RotationBacklog,
             dependencies d: E2EEV2RotationDrainDependencies, limit: Int = 20) async throws -> Bool {
        guard !running else { return false }
        guard (1...100).contains(limit), d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
        running = true; defer { running = false }
        let initial = try backlog.snapshot(session)
        guard d.activationEnabled() else {
            if initial.hasWork { try backlog.phase(.waitingAuthorization, for: session) }
            return false
        }
        if initial.notBeforeMs > d.now() { return initial.phase == .retryPending }
        try backlog.phase(.running, for: session)
        let discovered = await d.pending()
        guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
        switch discovered {
        case .failure(let failure): return try backlog.failed(session, kind: failure.kind)
        case .success(let values):
            try backlog.merge(session, conversations: values.map(\.conversationId), scannedRevision: initial.revision)
        }
        let tickets = try backlog.snapshot(session).pending.sorted { $0.key < $1.key }.prefix(limit)
        var failure: E2EEV2TransportFailureKind?
        for (id, ticket) in tickets {
            guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
            let result = await d.rotate(id)
            switch result {
            case .noAction:
                guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
                try backlog.acknowledge(session, conversation: id, ticket: ticket)
            case .rotated(let followUp):
                guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
                if !followUp { try backlog.acknowledge(session, conversation: id, ticket: ticket) }
            case .failure(let error): failure = error.kind
            }
            if failure == .authentication || failure == .activationBlocked { break }
        }
        guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if let failure { return try backlog.failed(session, kind: failure) }
        if try backlog.snapshot(session).hasWork { return try backlog.failed(session, kind: .retryable) }
        try backlog.complete(session)
        return false
    }

    func snapshot(session: LocalAccountSession, backlog: E2EEV2RotationBacklog) throws -> E2EEV2RotationState {
        try backlog.snapshot(session)
    }

    func request(session: LocalAccountSession, backlog: E2EEV2RotationBacklog, resetRetry: Bool = false) throws {
        try backlog.request(session, conversations: [], resetRetry: resetRetry)
    }
}

/// L'époque courante d'une conversation a avancé dans le coffre de ce compte.
/// Un appel chiffré garde l'époque de son descripteur (spec §10.3) : il prend
/// fin quand la conversation change de clé.
enum E2EEV2EpochEvents {
    static let didAdvance = Notification.Name("SignalQuest.E2EEV2.EpochDidAdvance.v1")

    struct Advance: Equatable, Sendable {
        let conversationId: String
        let epochNumber: Int
        let ownerNamespace: String
    }

    static func postAdvance(conversationId: String, epochNumber: Int, ownerNamespace: String) {
        NotificationCenter.default.post(name: didAdvance, object: nil, userInfo: [
            "conversationId": conversationId,
            "epochNumber": epochNumber,
            "ownerNamespace": ownerNamespace,
        ])
    }

    static func advance(from notification: Notification) -> Advance? {
        guard let info = notification.userInfo,
              let conversationId = info["conversationId"] as? String,
              let epochNumber = info["epochNumber"] as? Int,
              let ownerNamespace = info["ownerNamespace"] as? String else { return nil }
        return Advance(conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace)
    }
}

enum E2EEV2RotationEvents {
    static let resume = Notification.Name("SignalQuest.E2EEV2.RotationResume.v1")

    static func recordCommitted(session: LocalAccountSession, conversations: [String], notify: Bool = true) {
        // L'action serveur reste acquise si Keychain est momentanément indisponible.
        try? E2EEV2RotationBacklog.shared.request(session, conversations: conversations)
        if notify { requestResume(session) }
    }

    static func requestResume(_ session: LocalAccountSession) {
        NotificationCenter.default.post(name: resume, object: nil,
            userInfo: ["owner": session.ownerScopeId, "session": session.sessionId])
    }
}

@MainActor
final class E2EEV2EpochRotationRuntime: ObservableObject {
    @Published private(set) var state = E2EEV2RotationState()
    private let api: APIClient
    /// Décide et crée chaque époque (§3.3), avec les appareils certifiés.
    private let messaging: E2EEV2MessagingRuntime
    private let backlog: E2EEV2RotationBacklog
    private let drain = E2EEV2RotationDrain()
    private var session: LocalAccountSession?
    private var task: Task<Void, Never>?

    init(api: APIClient, messaging: E2EEV2MessagingRuntime, backlog: E2EEV2RotationBacklog = .shared) {
        self.api = api; self.messaging = messaging; self.backlog = backlog
    }

    func stop() { task?.cancel(); task = nil; session = nil; state = .init() }

    func resume(expected: LocalAccountSession? = nil, manualRetry: Bool = false) {
        if let expected, !expected.isCurrent { return }
        guard let current = expected ?? LocalAccountScope.sessionSnapshot(), current.isCurrent else { stop(); return }
        if task != nil, session == current, !manualRetry { return }
        let previous = task
        stop(); session = current
        let requirements = E2EEV2RotationRequirementsClient(api: api, expectedSession: current)
        let messaging = messaging
        task = Task { [weak self, backlog, drain] in
            guard let self else { return }
            // Une nouvelle session attend la fin de l'ancien appel annulé ; aucun poll de verrou.
            await previous?.value
            guard current.isCurrent, self.session == current, !Task.isCancelled else { return }
            do {
                let existing = try await drain.snapshot(session: current, backlog: backlog)
                guard current.isCurrent, self.session == current else { return }
                if !messaging.writesEnabled && !existing.hasWork { self.task = nil; return }
                self.state = existing
                self.state.phase = messaging.writesEnabled ? .running : .waitingAuthorization
                try await drain.request(session: current, backlog: backlog, resetRetry: manualRetry)
                // Ses propres appareils ont pu changer (approbation, révocation) : relus.
                await messaging.invalidateDevices([String(current.ownerScopeId.dropFirst("user:".count))])
                repeat {
                    let retry = try await drain.run(session: current, backlog: backlog, dependencies: .init(
                        isCurrent: { current.isCurrent }, activationEnabled: { messaging.writesEnabled },
                        pending: { await requirements.pending(expectedOwnerScopeId: current.ownerScopeId) },
                        rotate: { await messaging.rotate(conversationId: $0) }
                    ))
                    let updated = try await drain.snapshot(session: current, backlog: backlog)
                    guard current.isCurrent, self.session == current, !Task.isCancelled else { return }
                    self.state = updated
                    if !retry { break }
                    let delay = max(1_000, updated.notBeforeMs - Int64(Date().timeIntervalSince1970 * 1_000))
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                } while !Task.isCancelled
            } catch {
                if current.isCurrent, self.session == current, !Task.isCancelled {
                    self.state.phase = .needsAttention
                }
            }
            if self.session == current { self.task = nil }
        }
    }
}

// MARK: - E2EE v2 durable epoch rotation (preview, fail-closed)

struct E2EEV2EpochRotationRequirement: Equatable, Sendable {
    let conversationId: String
    let reason: String
    let revision: Int
    let triggeredAt: String
    let currentEpochNumber: Int
    let currentEpochStatus: String?
}

enum E2EEV2EpochRotationContract {
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    /// Le motif n'est qu'indicatif (la décision est à l'appareil) : un motif
    /// encore inconnu ne doit pas figer la file des rotations.
    private static let reasonPattern = #"^[A-Z][A-Z_]{0,39}\z"#
    private static let statuses: Set<String> = ["active", "compromised", "retired"]

    static func parseRequirements(_ data: Data) -> [E2EEV2EpochRotationRequirement]? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = dictionary(data),
              integer(root["protocolVersion"]) == 2,
              let values = root["requirements"] as? [[String: Any]],
              values.count <= 500 else { return nil }
        var seen = Set<String>()
        var requirements: [E2EEV2EpochRotationRequirement] = []
        for value in values {
            guard exactKeys(
                value,
                [
                    "conversationId",
                    "reason",
                    "revision",
                    "triggeredAt",
                    "currentEpochNumber",
                    "currentEpochStatus",
                ]
            ),
            let conversationId = value["conversationId"] as? String,
            validOpaqueId(conversationId),
            seen.insert(conversationId).inserted,
            let reason = value["reason"] as? String,
            reason.range(of: reasonPattern, options: .regularExpression) != nil,
            let revision = integer(value["revision"]),
            revision > 0,
            let triggeredAt = value["triggeredAt"] as? String,
            validISO8601(triggeredAt),
            // 0 : conversation encore v1, sans époque.
            let epochNumber = integer(value["currentEpochNumber"]),
            epochNumber >= 0 else { return nil }
            let status = nullableString(value["currentEpochStatus"])
            guard status.valid, status.value.map(statuses.contains) ?? true else { return nil }
            requirements.append(.init(
                conversationId: conversationId,
                reason: reason,
                revision: revision,
                triggeredAt: triggeredAt,
                currentEpochNumber: epochNumber,
                currentEpochStatus: status.value
            ))
        }
        return requirements
    }

    private static func dictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    private static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: opaquePattern, options: .regularExpression) != nil
    }

    private static func validISO8601(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value) != nil
    }

    private static func nullableString(_ value: Any?) -> (valid: Bool, value: String?) {
        if value == nil || value is NSNull { return (true, nil) }
        guard let string = value as? String, !string.isEmpty else { return (false, nil) }
        return (true, string)
    }

    /// Entier JSON, ou chaîne décimale canonique (D.0) : la route passe aux
    /// entiers en chaînes, les deux formes sont lues pendant la transition.
    private static func integer(_ value: Any?) -> Int? {
        if let string = value as? String {
            guard string.range(of: #"^(0|[1-9][0-9]{0,9})\z"#, options: .regularExpression) != nil else { return nil }
            return Int(string)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }
}

enum E2EEV2EpochRotationResult: Sendable, Equatable {
    case noAction
    case rotated(followUpRequired: Bool)
    case failure(E2EEV2TransportFailure)
}

/// Exigences de rotation publiées par le serveur (§3.3, confort), relues
/// après une mort du processus ou une notification manquée. Elles ne font que
/// désigner des conversations : la décision et l'époque restent à l'appareil
/// (`E2EEV2MessagingRuntime.rotate`), vers ses appareils certifiés.
final class E2EEV2RotationRequirementsClient: @unchecked Sendable {
    private let expectedSession: LocalAccountSession?
    private let transport: E2EEV2APITransport

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        expectedSession: LocalAccountSession? = nil
    ) {
        self.expectedSession = expectedSession
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    func pending(expectedOwnerScopeId: String) async -> Result<[E2EEV2EpochRotationRequirement], E2EEV2TransportFailure> {
        guard validScope(expectedOwnerScopeId), let session = requestSession(expectedOwnerScopeId) else {
            return .failure(localError("invalid-e2ee-rotation-scope"))
        }
        switch await transport.bound(to: session).getJSON(
            path: "/api/e2ee/v2/epoch-rotation-requirements",
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let error): return .failure(error)
        case .success(let data, _, _):
            guard let requirements = E2EEV2EpochRotationContract.parseRequirements(data) else {
                return .failure(localError("invalid-e2ee-rotation-requirements"))
            }
            return .success(requirements)
        }
    }

    private func validScope(_ ownerScopeId: String) -> Bool {
        ownerScopeId.hasPrefix("user:")
            && ownerScopeId.count > "user:".count
            && LocalAccountScope.currentOwnerScopeId == ownerScopeId
            && LocalAccountScope.currentUserId != nil
    }

    private func requestSession(_ owner: String) -> LocalAccountSession? {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(),
              session.isCurrent, session.ownerScopeId == owner else { return nil }
        return session
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}

struct E2EEV2CallFrameKeyContext: Equatable, Sendable {
    let conversationId: String
    let epochNumber: Int
    let callId: String
}

/// Clé de l'époque désignée par un descripteur d'appel (§10.2), jamais une
/// autre : l'appel garde son époque (§10.3).
enum E2EEV2CallBridge {
    /// Clé de l'époque d'un appel : celle du coffre de l'app ; s'il est fermé
    /// parce que l'appareil est verrouillé, celle du miroir des aperçus (§2.6,
    /// v0.4.13). `locked` : ni l'un ni l'autre ne l'a donnée, verrouillé.
    static func callEpoch(
        conversationId: String,
        epochNumber: Int,
        ownerNamespace: String,
        keyStore: E2EEV2EpochKeyStore,
        stateStore: E2EEV2ConversationStateStore,
        contextStore: E2EEV2NotificationContextStore?,
        locked: inout Bool
    ) -> E2EEV2StoredEpochKey? {
        do {
            return try E2EEV2VerifiedEpochKeys.exact(
                conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: ownerNamespace,
                keyStore: keyStore, stateStore: stateStore
            )
        } catch where E2EEV2DeviceIdentityStore.isLocked(error) {
            if let session = LocalAccountScope.sessionSnapshot(), session.ownerNamespace == ownerNamespace,
               let mirrored = E2EEV2VerifiedEpochKeys.exactWhileLocked(
                   conversationId: conversationId, epochNumber: epochNumber, session: session,
                   stateStore: stateStore, contextStore: contextStore
               ) {
                return mirrored
            }
            locked = true
            return nil
        } catch {
            return nil
        }
    }
}

enum E2EEV2CallFrameKeyError: Error, Equatable {
    case invalidContext
    case invalidEpochKey
}

/// Per-call media key consumed by LiveKit's external E2EE key provider. The
/// runtime remains disabled until frame cryptor state can be verified.
enum E2EEV2CallFrameKey {
    static let version = 1
    static let kdfInfo = "signalquest-e2ee-v2-call-frame-key-v1"

    static func saltCanonical(_ context: E2EEV2CallFrameKeyContext) throws -> Data {
        try validate(context)
        return Data([
            "SQ-E2EE-V2-CALL-FRAME-SALT",
            String(version),
            context.conversationId,
            String(context.epochNumber),
            context.callId,
        ].joined(separator: "\n").utf8)
    }

    static func salt(_ context: E2EEV2CallFrameKeyContext) throws -> Data {
        Data(SHA256.hash(data: try saltCanonical(context)))
    }

    static func derive(epochKey: Data, context: E2EEV2CallFrameKeyContext) throws -> Data {
        guard epochKey.count == 32 else { throw E2EEV2CallFrameKeyError.invalidEpochKey }
        try validate(context)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: epochKey),
            salt: try salt(context),
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func liveKitSharedPassphrase(frameKey: Data) throws -> String {
        guard frameKey.count == 32 else { throw E2EEV2CallFrameKeyError.invalidEpochKey }
        return frameKey.base64EncodedString()
    }

    private static func validate(_ context: E2EEV2CallFrameKeyContext) throws {
        let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
        guard context.conversationId.range(of: opaquePattern, options: .regularExpression) != nil,
              context.epochNumber > 0,
              context.callId.range(of: opaquePattern, options: .regularExpression) != nil else {
            throw E2EEV2CallFrameKeyError.invalidContext
        }
    }
}

struct E2EEV2BlobEncryptionManifest: Codable, Equatable, Sendable {
    let blobId: String
    let algorithm: String
    let mediaKeyB64: String
    let noncePrefixB64: String
    let cryptoChunkSize: Int
    let plaintextSize: Int64
    let ciphertextSize: Int64
    let plaintextSha256: String
    let ciphertextSha256: String
}

struct E2EEV2PreparedBlob: Equatable, Sendable {
    let ciphertextURL: URL
    let manifest: E2EEV2BlobEncryptionManifest
}

enum E2EEV2BlobFileEncryptor {
    static func encryptFile(
        sourceURL: URL,
        ciphertextURL: URL,
        blobId: String
    ) throws -> E2EEV2PreparedBlob {
        var mediaKey = try randomData(count: E2EEV2BlobCrypto.mediaKeyBytes)
        var noncePrefix = try randomData(count: E2EEV2BlobCrypto.noncePrefixBytes)
        defer {
            mediaKey.resetBytes(in: 0..<mediaKey.count)
            noncePrefix.resetBytes(in: 0..<noncePrefix.count)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: ciphertextURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = ciphertextURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        fileManager.createFile(atPath: partial.path, contents: nil)
        var plaintextHasher = SHA256()
        var ciphertextHasher = SHA256()
        var plaintextSize: Int64 = 0
        var ciphertextSize: Int64 = 0

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: partial)
            defer {
                try? input.close()
                try? output.close()
            }
            var chunkIndex: UInt32 = 0
            var current = try input.read(upToCount: E2EEV2BlobCrypto.cryptoChunkBytes) ?? Data()
            while true {
                let next = try input.read(upToCount: E2EEV2BlobCrypto.cryptoChunkBytes) ?? Data()
                let finalChunk = next.isEmpty
                guard plaintextSize <= E2EEV2BlobCrypto.maxPlaintextBytes - Int64(current.count) else {
                    throw E2EEV2BlobCryptoError.invalidChunk
                }
                plaintextHasher.update(data: current)
                plaintextSize += Int64(current.count)
                let ciphertext = try E2EEV2BlobCrypto.encryptChunk(
                    current,
                    blobID: blobId,
                    mediaKey: mediaKey,
                    noncePrefix: noncePrefix,
                    chunkIndex: chunkIndex,
                    finalChunk: finalChunk
                )
                try output.write(contentsOf: ciphertext)
                ciphertextHasher.update(data: ciphertext)
                ciphertextSize += Int64(ciphertext.count)
                if finalChunk { break }
                current = next
                let incremented = chunkIndex.addingReportingOverflow(1)
                guard !incremented.overflow else { throw E2EEV2BlobCryptoError.invalidChunk }
                chunkIndex = incremented.partialValue
            }
            try output.synchronize()
            if fileManager.fileExists(atPath: ciphertextURL.path) {
                try fileManager.removeItem(at: ciphertextURL)
            }
            try fileManager.moveItem(at: partial, to: ciphertextURL)
            return E2EEV2PreparedBlob(
                ciphertextURL: ciphertextURL,
                manifest: E2EEV2BlobEncryptionManifest(
                    blobId: blobId,
                    algorithm: E2EEV2BlobCrypto.algorithm,
                    mediaKeyB64: mediaKey.base64EncodedString(),
                    noncePrefixB64: noncePrefix.base64EncodedString(),
                    cryptoChunkSize: E2EEV2BlobCrypto.cryptoChunkBytes,
                    plaintextSize: plaintextSize,
                    ciphertextSize: ciphertextSize,
                    plaintextSha256: Data(plaintextHasher.finalize())
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    ciphertextSha256: Data(ciphertextHasher.finalize())
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            )
        } catch {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: ciphertextURL)
            throw error
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard result == errSecSuccess else { throw E2EEV2BlobCryptoError.invalidChunk }
        return data
    }
}

// MARK: - E2EE v2 durable encrypted-media outbox

struct E2EEV2OutboxBlobManifest: Codable, Equatable, Sendable {
    let blobId: String
    let algorithm: String
    let ciphertextSha256: String
    let ciphertextSize: Int64
    let uploadChunkSize: Int
}

enum E2EEV2MediaOutboxDeliveryState: String, Codable, Equatable, Sendable {
    case pending
    case serverAcknowledged
}

enum E2EEV2MediaOutboxOperation: String, Codable, Equatable, Sendable {
    case message = "MESSAGE"
    case history = "HISTORY"
}

struct E2EEV2MediaOutboxRecord: Codable, Equatable, Sendable {
    let version: Int
    let requireAuth: Bool
    let conversationId: String
    let clientRequestId: String
    let operation: E2EEV2MediaOutboxOperation
    let sourceMessageId: String
    let sourceHash: String
    let envelope: E2EEV2SignedMessageEnvelope
    let blobs: [E2EEV2OutboxBlobManifest]
    let createdAtMs: Int64
    let deliveryState: E2EEV2MediaOutboxDeliveryState

    init(
        conversationId: String,
        envelope: E2EEV2SignedMessageEnvelope,
        blobs: [E2EEV2OutboxBlobManifest],
        operation: E2EEV2MediaOutboxOperation = .message,
        sourceMessageId: String = "",
        sourceHash: String = "",
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        deliveryState: E2EEV2MediaOutboxDeliveryState = .pending
    ) {
        version = 2
        requireAuth = true
        self.conversationId = conversationId
        clientRequestId = envelope.clientRequestId
        self.operation = operation
        self.sourceMessageId = sourceMessageId
        self.sourceHash = sourceHash
        self.envelope = envelope
        self.blobs = blobs
        self.createdAtMs = createdAtMs
        self.deliveryState = deliveryState
    }
}

enum E2EEV2MediaOutboxError: Error, Equatable {
    case unauthenticated
    case activationBlocked
    case invalidRecord
    case invalidCiphertext
    case storageUnavailable
}

/// Persistance locale sans secret : un record JSON opaque et des fichiers de
/// ciphertext. Aucun nom de média, MIME, URI source, clé ou chemin absolu n'est
/// encodé dans le manifeste.
final class E2EEV2MediaOutboxStore: @unchecked Sendable {
    static let uploadChunkBytes = 5 * 1_024 * 1_024
    static let maxCiphertextBytes: Int64 = 512 * 1_024 * 1_024
    static let maxBlobs = 20

    private let fileManager: FileManager
    private let baseDirectory: URL

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) throws {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.baseDirectory = applicationSupport
                .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
                .appendingPathComponent("e2ee-v2-outbox", isDirectory: true)
        } else {
            throw E2EEV2MediaOutboxError.storageUnavailable
        }
    }

    static func purgeCurrentOwner() {
        guard LocalAccountScope.currentUserId != nil,
              let store = try? E2EEV2MediaOutboxStore() else { return }
        try? store.purge(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
    }

    func stage(
        record: E2EEV2MediaOutboxRecord,
        ownerScopeId: String,
        ciphertextSources: [String: URL]
    ) throws {
        try Self.validate(record)
        guard record.deliveryState == .pending,
              validOwner(ownerScopeId),
              Set(ciphertextSources.keys) == Set(record.blobs.map(\.blobId)) else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        let directory = try ownerDirectory(ownerScopeId: ownerScopeId, create: true)
        let blobsDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        let recordsDirectory = directory.appendingPathComponent("records", isDirectory: true)
        try createProtectedDirectory(blobsDirectory)
        try createProtectedDirectory(recordsDirectory)

        var newlyStaged: [URL] = []
        do {
            for manifest in record.blobs {
                guard let source = ciphertextSources[manifest.blobId] else {
                    throw E2EEV2MediaOutboxError.invalidCiphertext
                }
                let destination = try ciphertextURL(
                    ownerScopeId: ownerScopeId,
                    blobId: manifest.blobId,
                    createDirectory: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try verifyCiphertext(at: destination, manifest: manifest)
                    continue
                }
                try verifyCiphertext(at: source, manifest: manifest)
                let temporary = blobsDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
                do {
                    defer {
                        if fileManager.fileExists(atPath: temporary.path) {
                            try? fileManager.removeItem(at: temporary)
                        }
                    }
                    try fileManager.copyItem(at: source, to: temporary)
                    try applyProtection(to: temporary)
                    try verifyCiphertext(at: temporary, manifest: manifest)
                    try fileManager.moveItem(at: temporary, to: destination)
                }
                newlyStaged.append(destination)
            }

            let encoded = try Self.encode(record)
            try encoded.write(
                to: recordURL(ownerScopeId: ownerScopeId, clientRequestId: record.clientRequestId),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            newlyStaged.forEach { try? fileManager.removeItem(at: $0) }
            if let typed = error as? E2EEV2MediaOutboxError { throw typed }
            throw E2EEV2MediaOutboxError.storageUnavailable
        }
    }

    func load(ownerScopeId: String, clientRequestId: String) throws -> E2EEV2MediaOutboxRecord {
        guard validOwner(ownerScopeId), Self.validRequestId(clientRequestId) else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        do {
            let data = try Data(contentsOf: recordURL(
                ownerScopeId: ownerScopeId,
                clientRequestId: clientRequestId
            ), options: [.mappedIfSafe])
            return try Self.decode(data)
        } catch let error as E2EEV2MediaOutboxError {
            throw error
        } catch {
            throw E2EEV2MediaOutboxError.storageUnavailable
        }
    }

    func ciphertextURL(ownerScopeId: String, blobId: String) throws -> URL {
        try ciphertextURL(ownerScopeId: ownerScopeId, blobId: blobId, createDirectory: false)
    }

    func makePartFile(
        ownerScopeId: String,
        blobId: String,
        offset: Int64,
        length: Int
    ) throws -> URL {
        guard offset >= 0, length > 0, Int64(length) <= E2EEV2APITransport.maxBinaryPartBytes else {
            throw E2EEV2MediaOutboxError.invalidCiphertext
        }
        let sourceURL = try ciphertextURL(ownerScopeId: ownerScopeId, blobId: blobId)
        let partDirectory = try ownerDirectory(ownerScopeId: ownerScopeId, create: true)
            .appendingPathComponent("parts", isDirectory: true)
        try createProtectedDirectory(partDirectory)
        let partURL = partDirectory.appendingPathComponent("\(blobId)-\(UUID().uuidString).part")
        fileManager.createFile(atPath: partURL.path, contents: nil)
        do {
            let source = try FileHandle(forReadingFrom: sourceURL)
            let destination = try FileHandle(forWritingTo: partURL)
            defer {
                try? source.close()
                try? destination.close()
            }
            try source.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                let chunk = try source.read(upToCount: min(64 * 1_024, remaining)) ?? Data()
                guard !chunk.isEmpty else { throw E2EEV2MediaOutboxError.invalidCiphertext }
                try destination.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try destination.synchronize()
            try applyProtection(to: partURL)
            return partURL
        } catch {
            try? fileManager.removeItem(at: partURL)
            if let typed = error as? E2EEV2MediaOutboxError { throw typed }
            throw E2EEV2MediaOutboxError.storageUnavailable
        }
    }

    func removePartFile(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func complete(record: E2EEV2MediaOutboxRecord, ownerScopeId: String) throws {
        guard record.deliveryState == .serverAcknowledged else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        for blob in record.blobs {
            let url = try ciphertextURL(ownerScopeId: ownerScopeId, blobId: blob.blobId)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        let recordURL = recordURL(ownerScopeId: ownerScopeId, clientRequestId: record.clientRequestId)
        if fileManager.fileExists(atPath: recordURL.path) {
            try fileManager.removeItem(at: recordURL)
        }
    }

    func markServerAcknowledged(
        record: E2EEV2MediaOutboxRecord,
        ownerScopeId: String
    ) throws -> E2EEV2MediaOutboxRecord {
        guard record.deliveryState == .pending, validOwner(ownerScopeId) else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        let acknowledged = E2EEV2MediaOutboxRecord(
            conversationId: record.conversationId,
            envelope: record.envelope,
            blobs: record.blobs,
            operation: record.operation,
            sourceMessageId: record.sourceMessageId,
            sourceHash: record.sourceHash,
            createdAtMs: record.createdAtMs,
            deliveryState: .serverAcknowledged
        )
        let encoded = try Self.encode(acknowledged)
        try encoded.write(
            to: recordURL(ownerScopeId: ownerScopeId, clientRequestId: record.clientRequestId),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return acknowledged
    }

    func purge(ownerScopeId: String, expectedSession: LocalAccountSession? = nil) throws {
        guard validOwner(ownerScopeId) else { return }
        let target = try ownerDirectory(ownerScopeId: ownerScopeId, create: false)
        if let expectedSession {
            guard expectedSession.ownerScopeId == ownerScopeId else { throw CancellationError() }
            let retired = baseDirectory.appendingPathComponent(".reset-purge-\(UUID().uuidString)", isDirectory: true)
            try LocalAccountScope.publish(for: expectedSession) {
                if fileManager.fileExists(atPath: target.path) { try fileManager.moveItem(at: target, to: retired) }
            }
            // La suppression potentiellement longue ne tient aucun verrou Auth.
            if fileManager.fileExists(atPath: retired.path) { try fileManager.removeItem(at: retired) }
            return
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    static func encode(_ record: E2EEV2MediaOutboxRecord) throws -> Data {
        try validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> E2EEV2MediaOutboxRecord {
        guard data.count <= 512 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                "version", "requireAuth", "conversationId", "clientRequestId",
                "operation", "sourceMessageId", "sourceHash", "envelope", "blobs",
                "createdAtMs", "deliveryState",
              ],
              let envelope = root["envelope"] as? [String: Any],
              Set(envelope.keys) == [
                "envelopeVersion", "epochNumber", "clientRequestId", "algorithm",
                "contentType", "keyCommitmentB64", "ttlSeconds", "encryptedBlobIds",
                "nonceB64", "aadB64", "ciphertextB64", "senderSignatureB64",
              ],
              let blobs = root["blobs"] as? [[String: Any]],
              blobs.allSatisfy({ Set($0.keys) == [
                "blobId", "algorithm", "ciphertextSha256", "ciphertextSize", "uploadChunkSize",
              ] }) else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        do {
            let record = try JSONDecoder().decode(E2EEV2MediaOutboxRecord.self, from: data)
            try validate(record)
            return record
        } catch let error as E2EEV2MediaOutboxError {
            throw error
        } catch {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
    }

    static func validate(_ record: E2EEV2MediaOutboxRecord) throws {
        let envelope = record.envelope
        let validTarget = switch record.operation {
        case .message:
            record.sourceMessageId.isEmpty && record.sourceHash.isEmpty
        case .history:
            validOpaqueId(record.sourceMessageId)
                && record.sourceHash.range(
                    of: #"^[a-f0-9]{64}\z"#,
                    options: .regularExpression
                ) != nil
                && record.clientRequestId == (try? E2EEV2HistoryMigrationContract.clientRequestId(
                    messageId: record.sourceMessageId,
                    sourceHash: record.sourceHash
                ))
        }
        guard record.version == 2,
              record.requireAuth,
              validTarget,
              validOpaqueId(record.conversationId),
              validRequestId(record.clientRequestId),
              record.clientRequestId == envelope.clientRequestId,
              record.createdAtMs >= 0,
              record.blobs.count <= maxBlobs,
              envelope.envelopeVersion == E2EEV2MessageCrypto.envelopeVersion,
              envelope.epochNumber > 0,
              envelope.algorithm == E2EEV2MessageCrypto.algorithm,
              envelope.contentType == E2EEV2MessageCrypto.contentType,
              (0...(30 * 24 * 60 * 60)).contains(envelope.ttlSeconds),
              envelope.encryptedBlobIds == record.blobs.map(\.blobId),
              Set(envelope.encryptedBlobIds).count == envelope.encryptedBlobIds.count,
              validBase64(envelope.keyCommitmentB64, max: 128),
              validBase64(envelope.nonceB64, max: 64),
              validBase64(envelope.aadB64, max: 4_096),
              validBase64(envelope.ciphertextB64, max: 400_000),
              validBase64(envelope.senderSignatureB64, max: 256) else {
            throw E2EEV2MediaOutboxError.invalidRecord
        }
        for blob in record.blobs {
            guard validOpaqueId(blob.blobId),
                  blob.algorithm == E2EEV2BlobCrypto.algorithm,
                  blob.ciphertextSha256.range(
                    of: #"^[a-f0-9]{64}\z"#,
                    options: .regularExpression
                  ) != nil,
                  (1...maxCiphertextBytes).contains(blob.ciphertextSize),
                  blob.uploadChunkSize == uploadChunkBytes else {
                throw E2EEV2MediaOutboxError.invalidRecord
            }
        }
    }

    private func ownerDirectory(ownerScopeId: String, create: Bool) throws -> URL {
        guard validOwner(ownerScopeId) else { throw E2EEV2MediaOutboxError.invalidRecord }
        let namespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        let directory = baseDirectory.appendingPathComponent(namespace, isDirectory: true)
        if create { try createProtectedDirectory(directory) }
        return directory
    }

    private func ciphertextURL(
        ownerScopeId: String,
        blobId: String,
        createDirectory: Bool
    ) throws -> URL {
        guard Self.validOpaqueId(blobId) else { throw E2EEV2MediaOutboxError.invalidRecord }
        let directory = try ownerDirectory(ownerScopeId: ownerScopeId, create: createDirectory)
            .appendingPathComponent("blobs", isDirectory: true)
        if createDirectory { try createProtectedDirectory(directory) }
        return directory.appendingPathComponent("\(blobId).bin", isDirectory: false)
    }

    private func recordURL(ownerScopeId: String, clientRequestId: String) -> URL {
        let namespace = LocalAccountScope.storageNamespace(for: clientRequestId)
        return baseDirectory
            .appendingPathComponent(LocalAccountScope.storageNamespace(for: ownerScopeId), isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(namespace).json", isDirectory: false)
    }

    private func verifyCiphertext(at url: URL, manifest: E2EEV2OutboxBlobManifest) throws {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == manifest.ciphertextSize,
              (try? Self.sha256Hex(url)) == manifest.ciphertextSha256 else {
            throw E2EEV2MediaOutboxError.invalidCiphertext
        }
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func applyProtection(to url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func validOwner(_ ownerScopeId: String) -> Bool {
        ownerScopeId.hasPrefix("user:") && ownerScopeId.count > "user:".count
    }

    private static func validOpaqueId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#, options: .regularExpression) != nil
    }

    private static func validRequestId(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z"#, options: .regularExpression) != nil
    }

    private static func validBase64(_ value: String, max: Int) -> Bool {
        (4...max).contains(value.count)
            && value.range(of: #"^[A-Za-z0-9+/_-]+={0,2}\z"#, options: .regularExpression) != nil
    }

    static func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum E2EEV2MediaOutboxDisposition: Equatable, Sendable {
    case success
    case retry
    case authenticationRequired
    case blocked
    case terminal
}

struct E2EEV2MediaOutboxExecution: Error, Equatable, Sendable {
    let disposition: E2EEV2MediaOutboxDisposition
    let reason: String?
}

actor E2EEV2MediaOutbox {
    private let transport: E2EEV2APITransport
    private let store: E2EEV2MediaOutboxStore

    init(api: APIClient, store: E2EEV2MediaOutboxStore? = nil) throws {
        transport = E2EEV2APITransport(api: api)
        self.store = try store ?? E2EEV2MediaOutboxStore()
    }

    func enqueue(
        record: E2EEV2MediaOutboxRecord,
        ciphertextSources: [String: URL]
    ) throws {
        guard E2EEV2RuntimeWriteGate.enabled else {
            throw E2EEV2MediaOutboxError.activationBlocked
        }
        guard LocalAccountScope.currentUserId != nil else {
            throw E2EEV2MediaOutboxError.unauthenticated
        }
        try store.stage(
            record: record,
            ownerScopeId: LocalAccountScope.currentOwnerScopeId,
            ciphertextSources: ciphertextSources
        )
    }

    func execute(clientRequestId: String, ownerScopeId: String) async -> E2EEV2MediaOutboxExecution {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .init(disposition: .blocked, reason: "e2ee-v2-security-review-required")
        }
        guard LocalAccountScope.currentOwnerScopeId == ownerScopeId,
              LocalAccountScope.currentUserId != nil else {
            return .init(disposition: .authenticationRequired, reason: "account-scope-changed")
        }
        let record: E2EEV2MediaOutboxRecord
        do {
            record = try store.load(ownerScopeId: ownerScopeId, clientRequestId: clientRequestId)
        } catch {
            return .init(disposition: .terminal, reason: "invalid-e2ee-v2-outbox-record")
        }

        if record.deliveryState == .serverAcknowledged {
            do {
                try store.complete(record: record, ownerScopeId: ownerScopeId)
                return .init(disposition: .success, reason: nil)
            } catch {
                return .init(disposition: .retry, reason: "e2ee-v2-local-cleanup-pending")
            }
        }

        for blob in record.blobs {
            let ciphertextURL: URL
            do {
                ciphertextURL = try store.ciphertextURL(ownerScopeId: ownerScopeId, blobId: blob.blobId)
                guard try E2EEV2MediaOutboxStore.sha256Hex(ciphertextURL) == blob.ciphertextSha256 else {
                    return .init(disposition: .terminal, reason: "e2ee-v2-ciphertext-integrity-failed")
                }
            } catch {
                return .init(disposition: .terminal, reason: "e2ee-v2-ciphertext-unavailable")
            }

            let declaration = E2EEV2BlobDeclaration(
                version: 1,
                blobId: blob.blobId,
                algorithm: blob.algorithm,
                ciphertextSha256: blob.ciphertextSha256,
                ciphertextSize: String(blob.ciphertextSize),
                chunkSize: blob.uploadChunkSize
            )
            guard let declarationData = try? JSONEncoder().encode(declaration) else {
                return .init(disposition: .terminal, reason: "invalid-e2ee-v2-blob-declaration")
            }
            let initialized = await transport.postJSON(
                path: "/api/e2ee/v2/blobs",
                body: declarationData,
                expectedOwnerScopeId: ownerScopeId,
                capabilitySet: .media
            )
            let state: E2EEV2BlobState
            switch decode(initialized, as: E2EEV2BlobInitResponse.self) {
            case .success(let response): state = response.blob
            case .failure(let execution): return execution
            }
            let partCount = Int((blob.ciphertextSize + Int64(blob.uploadChunkSize) - 1) / Int64(blob.uploadChunkSize))
            guard state.blobId == blob.blobId,
                  state.ciphertextSha256 == blob.ciphertextSha256,
                  state.ciphertextSize == String(blob.ciphertextSize),
                  state.partCount == partCount else {
                return .init(disposition: .terminal, reason: "e2ee-v2-blob-init-mismatch")
            }

            if state.status != "complete" {
                guard state.status == "pending",
                      Set(state.uploadedParts).count == state.uploadedParts.count,
                      state.uploadedParts.allSatisfy({ (1...partCount).contains($0) }) else {
                    return .init(disposition: .terminal, reason: "invalid-e2ee-v2-blob-state")
                }
                let uploaded = Set(state.uploadedParts)
                for partNumber in 1...partCount where !uploaded.contains(partNumber) {
                    let offset = Int64(partNumber - 1) * Int64(blob.uploadChunkSize)
                    let length = Int(min(Int64(blob.uploadChunkSize), blob.ciphertextSize - offset))
                    let partURL: URL
                    do {
                        partURL = try store.makePartFile(
                            ownerScopeId: ownerScopeId,
                            blobId: blob.blobId,
                            offset: offset,
                            length: length
                        )
                    } catch {
                        return .init(disposition: .terminal, reason: "e2ee-v2-part-staging-failed")
                    }
                    let upload = await transport.putEncryptedFile(
                        path: "/api/e2ee/v2/blobs/\(blob.blobId)/parts/\(partNumber)",
                        fileURL: partURL,
                        expectedOwnerScopeId: ownerScopeId
                    )
                    store.removePartFile(partURL)
                    if case .failure(let failure) = upload {
                        return execution(for: failure)
                    }
                }

                let completionBody = Data(#"{"version":1}"#.utf8)
                let completion = await transport.postJSON(
                    path: "/api/e2ee/v2/blobs/\(blob.blobId)/complete",
                    body: completionBody,
                    expectedOwnerScopeId: ownerScopeId,
                    capabilitySet: .media
                )
                switch decode(completion, as: E2EEV2BlobCompleteResponse.self) {
                case .success(let response):
                    guard response.blobId == blob.blobId, response.status == "complete" else {
                        return .init(disposition: .terminal, reason: "invalid-e2ee-v2-blob-complete-response")
                    }
                case .failure(let execution): return execution
                }
            }
        }

        let delivery: E2EEV2TransportResult<Data>
        switch record.operation {
        case .message:
            guard let messageBody = try? JSONEncoder().encode(record.envelope) else {
                return .init(disposition: .terminal, reason: "invalid-e2ee-v2-message-envelope")
            }
            delivery = await transport.postJSON(
                path: "/api/e2ee/v2/conversations/\(record.conversationId)/messages",
                body: messageBody,
                expectedOwnerScopeId: ownerScopeId,
                capabilitySet: .message
            )
        case .history:
            guard let historyBody = try? JSONEncoder().encode(E2EEV2HistoryOutboxCommit(
                version: E2EEV2HistoryMigrationContract.version,
                sourceMessageId: record.sourceMessageId,
                sourceHash: record.sourceHash,
                envelope: record.envelope
            )) else {
                return .init(disposition: .terminal, reason: "invalid-e2ee-v2-history-envelope")
            }
            delivery = await transport.putJSON(
                path: "/api/e2ee/v2/conversations/\(record.conversationId)/history/messages/\(record.sourceMessageId)",
                body: historyBody,
                expectedOwnerScopeId: ownerScopeId,
                capabilitySet: .history
            )
        }
        switch record.operation {
        case .message:
            switch decode(delivery, as: E2EEV2MessageWriteResponse.self) {
            case .success(let response):
                guard response.message.clientRequestId == record.clientRequestId else {
                    return .init(disposition: .terminal, reason: "invalid-e2ee-v2-message-response")
                }
            case .failure(let execution): return execution
            }
        case .history:
            switch decode(delivery, as: E2EEV2HistoryOutboxCommitResponse.self) {
            case .success(let response):
                guard response.sourceMessageId == record.sourceMessageId,
                      response.envelopeId == record.sourceMessageId,
                      response.clearSourceDeleted || response.legacyCleanupPending else {
                    return .init(disposition: .terminal, reason: "invalid-e2ee-v2-history-response")
                }
            case .failure(let execution): return execution
            }
        }
        do {
            let acknowledged = try store.markServerAcknowledged(
                record: record,
                ownerScopeId: ownerScopeId
            )
            try store.complete(record: acknowledged, ownerScopeId: ownerScopeId)
            return .init(disposition: .success, reason: nil)
        } catch {
            return .init(disposition: .retry, reason: "e2ee-v2-local-cleanup-pending")
        }
    }

    private func decode<Value: Decodable & Sendable>(
        _ result: E2EEV2TransportResult<Data>,
        as type: Value.Type
    ) -> Result<Value, E2EEV2MediaOutboxExecution> {
        switch result {
        case .success(let data, _, _):
            guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
                return .failure(.init(disposition: .terminal, reason: "invalid-e2ee-v2-server-response"))
            }
            return .success(value)
        case .failure(let failure):
            return .failure(execution(for: failure))
        }
    }

    private func execution(for failure: E2EEV2TransportFailure) -> E2EEV2MediaOutboxExecution {
        switch failure.kind {
        case .authentication:
            return .init(disposition: .authenticationRequired, reason: failure.code ?? failure.message)
        case .retryable:
            return .init(disposition: .retry, reason: failure.code ?? failure.message)
        case .activationBlocked:
            return .init(disposition: .blocked, reason: failure.code ?? failure.message)
        case .permanent, .localState:
            return .init(disposition: .terminal, reason: failure.code ?? failure.message)
        }
    }
}

struct E2EEV2MessagePreparationInput {
    let conversationId: String
    let clientRequestId: String
    let ttlSeconds: Int
    let encryptedBlobIds: [String]
    let content: [String: Any]
}

struct E2EEV2MessageLocalState {
    let device: E2EEV2DeviceDescriptor
    let epoch: E2EEV2StoredEpochKey
    let sign: (Data) throws -> Data
}

enum E2EEV2MessagePreparationResult: Equatable {
    case prepared(E2EEV2SignedMessageEnvelope)
    case blocked(reason: String)
}

/// Assemble une enveloppe opaque sans effectuer d'appel réseau ni écrire dans
/// l'outbox. Le runtime reste fermé jusqu'aux critères de sortie du jalon A (spec §17).
enum E2EEV2MessageComposer {
    static func prepareRuntime(
        input: E2EEV2MessagePreparationInput,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        epochStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore()
    ) -> E2EEV2MessagePreparationResult {
        prepareRuntimeWithStateLoader(input: input, nonceProvider: randomNonce) {
            guard LocalAccountScope.currentUserId != nil else { return nil }
            let ownerNamespace = LocalAccountScope.storageNamespace
            guard let device = try identityStore.load(ownerNamespace: ownerNamespace),
                  let epoch = try E2EEV2VerifiedEpochKeys.current(
                      conversationId: input.conversationId, ownerNamespace: ownerNamespace,
                      keyStore: epochStore, stateStore: stateStore
                  ) else { return nil }
            return E2EEV2MessageLocalState(
                device: device,
                epoch: epoch,
                sign: { canonical in
                    try identityStore.sign(
                        canonicalRequest: canonical,
                        ownerNamespace: ownerNamespace
                    )
                }
            )
        }
    }

    static func prepareRuntimeWithStateLoader(
        input: E2EEV2MessagePreparationInput,
        nonceProvider: () throws -> Data,
        localStateLoader: () throws -> E2EEV2MessageLocalState?
    ) -> E2EEV2MessagePreparationResult {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .blocked(reason: "e2ee-v2-security-review-required")
        }
        do {
            guard let state = try localStateLoader() else {
                return .blocked(reason: "e2ee-v2-local-state-unavailable")
            }
            return .prepared(try prepareContractPreview(
                input: input,
                device: state.device,
                epoch: state.epoch,
                nonce: nonceProvider(),
                signer: state.sign
            ))
        } catch {
            return .blocked(reason: "invalid-e2ee-v2-local-state")
        }
    }

    /// Réservé aux tests de contrat tant que le verrou runtime est fermé.
    static func prepareContractPreview(
        input: E2EEV2MessagePreparationInput,
        device: E2EEV2DeviceDescriptor,
        epoch: E2EEV2StoredEpochKey,
        nonce: Data,
        signer: (Data) throws -> Data
    ) throws -> E2EEV2SignedMessageEnvelope {
        var cleartext = try E2EEV2ContentContract.encode(input.content)
        defer { cleartext.resetBytes(in: 0..<cleartext.count) }
        guard let canonicalContent = E2EEV2ContentContract.parse(cleartext),
              referencedPrivateBlobIds(canonicalContent) == input.encryptedBlobIds,
              epoch.conversationId == input.conversationId else {
            throw E2EEV2MessageCryptoError.invalidContext
        }

        var localEpochKey = epoch.epochKey
        var localNonce = nonce
        defer {
            localEpochKey.resetBytes(in: 0..<localEpochKey.count)
            localNonce.resetBytes(in: 0..<localNonce.count)
        }
        guard localNonce.count == 12,
              try E2EEV2EpochCrypto.keyCommitment(localEpochKey) == epoch.keyCommitmentB64 else {
            throw E2EEV2MessageCryptoError.commitmentMismatch
        }
        let context = E2EEV2MessageContext(
            conversationId: input.conversationId,
            epochNumber: epoch.epochNumber,
            senderDeviceId: device.deviceId,
            clientRequestId: input.clientRequestId,
            ttlSeconds: input.ttlSeconds,
            encryptedBlobIds: input.encryptedBlobIds
        )
        let envelope = try E2EEV2MessageCrypto.encrypt(
            cleartext: cleartext,
            epochKey: localEpochKey,
            nonce: localNonce,
            context: context
        )
        var canonicalSignature = try E2EEV2MessageCrypto.signatureCanonical(
            context: context,
            envelope: envelope
        )
        defer { canonicalSignature.resetBytes(in: 0..<canonicalSignature.count) }
        var signature = try signer(canonicalSignature)
        defer { signature.resetBytes(in: 0..<signature.count) }
        guard let publicKeyData = Data(base64Encoded: device.publicSigningKeyB64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              E2EEV2LowS.verify(derSignature: signature, message: canonicalSignature, publicKey: publicKey) else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        return E2EEV2SignedMessageEnvelope(
            envelope: envelope,
            senderSignatureB64: signature.base64EncodedString()
        )
    }

    private static func referencedPrivateBlobIds(_ content: [String: Any]) -> [String] {
        guard let kind = content["kind"] as? String,
              let body = content["body"] as? [String: Any] else { return [] }
        switch kind {
        case "MEDIA":
            return (body["attachments"] as? [[String: Any]])?
                .compactMap { $0["blobId"] as? String } ?? []
        case "AUDIO":
            guard let attachment = body["attachment"] as? [String: Any],
                  let blobId = attachment["blobId"] as? String else { return [] }
            return [blobId]
        default:
            return []
        }
    }

    private static func randomNonce() throws -> Data {
        let count = 12
        var nonce = Data(count: count)
        let status = nonce.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw E2EEV2MessageCryptoError.invalidNonce }
        return nonce
    }
}

extension E2EEV2MessageReceiver {
    static func decryptRuntime(
        input: E2EEV2IncomingMessageInput,
        epochStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore()
    ) -> E2EEV2MessageDecryptionResult {
        decryptRuntimeWithEpochLoader(input: input) { epochNumber in
            guard LocalAccountScope.currentUserId != nil,
                  LocalAccountScope.currentOwnerScopeId == input.ownerScopeId else { return nil }
            return try epochStore.loadEpoch(
                conversationId: input.conversationId,
                epochNumber: epochNumber,
                ownerNamespace: LocalAccountScope.storageNamespace(for: input.ownerScopeId)
            )
        }
    }
}

struct E2EEV2LegacyMessageSource: Codable, Equatable, Sendable {
    let version: Int
    let conversationId: String
    let messageId: String
    let senderId: String
    let kind: String
    let content: String
    let metadata: String?
    let createdAt: String
    let editedAt: String?
    let replyToId: String?
    let expiresAt: String?
}

struct E2EEV2LegacyAttachmentSource: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let url: String
    let fileName: String?
    let contentType: String?
    let size: Int64?
    let width: Int?
    let height: Int?
    let createdAt: String
}

struct E2EEV2HistoryBatchItem: Codable, Equatable, Sendable {
    let source: E2EEV2LegacyMessageSource
    let sourceHash: String
    let eligibility: String
    let legacyAttachments: [E2EEV2LegacyAttachmentSource]
}

struct E2EEV2HistoryBatch: Equatable, Sendable {
    let conversationId: String
    let messages: [E2EEV2HistoryBatchItem]
    let hasMore: Bool
    let blockedCount: Int
    let cursorStatus: String
}

enum E2EEV2HistoryMigrationContract {
    static let version = 1
    static let batchLimit = 5
    static let maxClearBytes = 80 * 1_024

    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    private static let hashPattern = #"^[a-f0-9]{64}\z"#
    private static let kinds: Set<String> = [
        "TEXT", "ATTACHMENT", "SPEEDTEST", "LINK", "SYSTEM", "LOCATION",
    ]
    private static let sourceKeys: Set<String> = [
        "version", "conversationId", "messageId", "senderId", "kind", "content",
        "metadata", "createdAt", "editedAt", "replyToId", "expiresAt",
    ]

    private struct BatchResponse: Decodable {
        struct Cursor: Decodable { let status: String }
        let version: Int
        let conversationId: String
        let messages: [E2EEV2HistoryBatchItem]
        let hasMore: Bool
        let blockedCount: Int
        let cursor: Cursor
    }

    static func parseBatch(_ data: Data, expectedConversationId: String) -> E2EEV2HistoryBatch? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["messages"] as? [[String: Any]],
              rawItems.count <= batchLimit,
              rawItems.allSatisfy({ item in
                  Set(item.keys) == ["source", "sourceHash", "eligibility", "legacyAttachments"]
                      && ((item["source"] as? [String: Any]).map { Set($0.keys) == sourceKeys } ?? false)
                      && ((item["legacyAttachments"] as? [[String: Any]])?.allSatisfy({ attachment in
                          Set(attachment.keys) == [
                              "id", "kind", "url", "fileName", "contentType", "size",
                              "width", "height", "createdAt",
                          ]
                      }) ?? false)
              }),
              let response = try? JSONDecoder().decode(BatchResponse.self, from: data),
              response.version == version,
              response.conversationId == expectedConversationId,
              validOpaque(expectedConversationId),
              response.blockedCount >= 0,
              ["NOT_STARTED", "RUNNING", "PAUSED", "COMPLETED", "FAILED"]
                .contains(response.cursor.status),
              response.messages.allSatisfy({ item in
                  item.eligibility == "READY"
                      && item.source.conversationId == expectedConversationId
                      && item.sourceHash.range(of: hashPattern, options: .regularExpression) != nil
                      && (try? sourceHash(item.source)) == item.sourceHash
                      && validateAttachments(item.legacyAttachments, source: item.source)
              }) else {
            return nil
        }
        return E2EEV2HistoryBatch(
            conversationId: response.conversationId,
            messages: response.messages,
            hasMore: response.hasMore,
            blockedCount: response.blockedCount,
            cursorStatus: response.cursor.status
        )
    }

    static func canonicalSource(_ source: E2EEV2LegacyMessageSource) throws -> Data {
        try validate(source)
        let fields = [
            #""version":1"#,
            #""conversationId":\#(try jsonString(source.conversationId))"#,
            #""messageId":\#(try jsonString(source.messageId))"#,
            #""senderId":\#(try jsonString(source.senderId))"#,
            #""kind":\#(try jsonString(source.kind))"#,
            #""content":\#(try jsonString(source.content))"#,
            #""metadata":\#(try nullableJSONString(source.metadata))"#,
            #""createdAt":\#(try jsonString(source.createdAt))"#,
            #""editedAt":\#(try nullableJSONString(source.editedAt))"#,
            #""replyToId":\#(try nullableJSONString(source.replyToId))"#,
            #""expiresAt":\#(try nullableJSONString(source.expiresAt))"#,
        ]
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        guard data.count <= maxClearBytes else { throw E2EEV2MessageCryptoError.invalidContext }
        return data
    }

    static func sourceHash(_ source: E2EEV2LegacyMessageSource) throws -> String {
        Data(SHA256.hash(data: try canonicalSource(source)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func clientRequestId(messageId: String, sourceHash: String) throws -> String {
        guard validOpaque(messageId),
              sourceHash.range(of: hashPattern, options: .regularExpression) != nil else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        return "history:\(messageId):\(sourceHash.prefix(16))"
    }

    static func encryptedCleartext(
        _ item: E2EEV2HistoryBatchItem,
        preparedBlobs: [E2EEV2PreparedBlob] = []
    ) throws -> Data {
        guard try sourceHash(item.source) == item.sourceHash else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        guard preparedBlobs.count == item.legacyAttachments.count else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        let encryptedAttachments: [[String: Any]] = zip(
            item.legacyAttachments,
            preparedBlobs
        ).map { attachment, prepared in
            let manifest = prepared.manifest
            return [
                "legacyAttachmentId": attachment.id,
                "blob": [
                    "blobId": manifest.blobId,
                    "algorithm": manifest.algorithm,
                    "mediaKeyB64": manifest.mediaKeyB64,
                    "noncePrefixB64": manifest.noncePrefixB64,
                    "cryptoChunkSize": manifest.cryptoChunkSize,
                    "plaintextSize": String(manifest.plaintextSize),
                    "ciphertextSize": String(manifest.ciphertextSize),
                    "plaintextSha256": manifest.plaintextSha256,
                    "ciphertextSha256": manifest.ciphertextSha256,
                ],
            ]
        }
        let encryptedAttachmentsData = try JSONSerialization.data(
            withJSONObject: encryptedAttachments,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        var data = Data(#"{"version":1,"sourceHash":"#.utf8)
        guard let encodedHash = try jsonString(item.sourceHash).data(using: .utf8) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        data.append(encodedHash)
        data.append(Data(#","source":"#.utf8))
        data.append(try canonicalSource(item.source))
        data.append(Data(#","encryptedAttachments":"#.utf8))
        data.append(encryptedAttachmentsData)
        data.append(Data("}".utf8))
        return data
    }

    static func historicalBlobId(sourceHash: String, attachmentId: String) throws -> String {
        guard sourceHash.range(of: hashPattern, options: .regularExpression) != nil,
              validOpaque(attachmentId) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        let canonical = Data(
            "SQ-E2EE-V2-HISTORY-BLOB\n1\n\(sourceHash)\n\(attachmentId)".utf8
        )
        return "hist_\(Data(SHA256.hash(data: canonical)).base64URLEncodedNoPadding())"
    }

    static func commitBody(
        item: E2EEV2HistoryBatchItem,
        envelope: E2EEV2SignedMessageEnvelope
    ) throws -> Data {
        struct Body: Encodable {
            let version: Int
            let sourceMessageId: String
            let sourceHash: String
            let envelope: E2EEV2SignedMessageEnvelope
        }
        return try JSONEncoder().encode(Body(
            version: version,
            sourceMessageId: item.source.messageId,
            sourceHash: item.sourceHash,
            envelope: envelope
        ))
    }

    private static func validate(_ source: E2EEV2LegacyMessageSource) throws {
        guard source.version == version,
              validOpaque(source.conversationId),
              validOpaque(source.messageId),
              validOpaque(source.senderId),
              kinds.contains(source.kind),
              source.content.count <= 256 * 1_024,
              source.metadata.map({ $0.count <= 256 * 1_024 }) ?? true,
              !source.createdAt.isEmpty,
              source.replyToId.map(validOpaque) ?? true else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
    }

    private struct RichMetadataAttachmentBinding: Decodable {
        let version: Int
        let attachments: [E2EEV2LegacyAttachmentSource]
    }

    private static func validateAttachments(
        _ attachments: [E2EEV2LegacyAttachmentSource],
        source: E2EEV2LegacyMessageSource
    ) -> Bool {
        guard attachments.count <= 20,
              Set(attachments.map(\.id)).count == attachments.count,
              zip(attachments, attachments.dropFirst()).allSatisfy({ $0.0.id < $0.1.id }),
              attachments.allSatisfy({ attachment in
                  guard validOpaque(attachment.id),
                        (1...32).contains(attachment.kind.count),
                        attachment.url.count <= 8_192,
                        let components = URLComponents(string: attachment.url),
                        ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                        attachment.fileName.map({ $0.count <= 512 }) ?? true,
                        attachment.contentType.map({ $0.count <= 255 }) ?? true,
                        attachment.size.map({ $0 >= 0 }) ?? true,
                        attachment.width.map({ $0 > 0 }) ?? true,
                        attachment.height.map({ $0 > 0 }) ?? true,
                        !attachment.createdAt.isEmpty else { return false }
                  return true
              }) else { return false }
        if attachments.isEmpty { return true }
        guard let metadata = source.metadata?.data(using: .utf8),
              let binding = try? JSONDecoder().decode(
                  RichMetadataAttachmentBinding.self,
                  from: metadata
              ) else { return false }
        return binding.version == version && binding.attachments == attachments
    }

    private static func validOpaque(_ value: String) -> Bool {
        value.range(of: opaquePattern, options: .regularExpression) != nil
    }

    private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        return encoded
    }

    private static func nullableJSONString(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try jsonString(value)
    }
}

enum E2EEV2HistoryMigrationResult: Equatable, Sendable {
    case progress(migrated: Int, hasMore: Bool, blockedCount: Int)
    case paused(blockedCount: Int)
    case completed
    case queued(Int)
    case blocked(reason: String)
    case failed(E2EEV2TransportFailure)
}

/// Le serveur garde le curseur signé. Aucun lot clair ni clé d'époque n'est
/// persisté ici : après un kill, le même message est renvoyé et réappliqué de
/// manière idempotente.
actor E2EEV2HistoryMigrationCoordinator {
    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let mediaOutboxStore: E2EEV2MediaOutboxStore?
    private let mediaOutbox: E2EEV2MediaOutbox?
    private let urlSession: URLSession

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        urlSession: URLSession = .shared
    ) {
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        self.identityStore = identityStore
        let store = try? E2EEV2MediaOutboxStore()
        mediaOutboxStore = store
        mediaOutbox = store.flatMap { try? E2EEV2MediaOutbox(api: api, store: $0) }
        self.urlSession = urlSession
    }

    func migrateNextBatch(
        conversationId: String,
        epochNumber: Int,
        epochKey: Data
    ) async -> E2EEV2HistoryMigrationResult {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .blocked(reason: "e2ee-v2-security-review-required")
        }
        guard LocalAccountScope.currentUserId != nil else {
            return .blocked(reason: "authentication-required")
        }
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        let device: E2EEV2DeviceDescriptor
        do {
            guard let loaded = try identityStore.load() else {
                return .blocked(reason: "e2ee-device-identity-unavailable")
            }
            device = loaded
        } catch {
            return .blocked(reason: "e2ee-device-identity-unavailable")
        }
        guard epochKey.count == 32, epochNumber > 0 else {
            return .blocked(reason: "e2ee-epoch-unavailable")
        }
        let batchBody = Data(#"{"version":1,"limit":5}"#.utf8)
        let fetched = await transport.postJSON(
            path: "/api/e2ee/v2/conversations/\(conversationId)/history/batch",
            body: batchBody,
            expectedOwnerScopeId: ownerScopeId,
            capabilitySet: .history
        )
        let batch: E2EEV2HistoryBatch
        switch fetched {
        case .failure(let failure): return .failed(failure)
        case .success(let data, _, _):
            guard let parsed = E2EEV2HistoryMigrationContract.parseBatch(
                data,
                expectedConversationId: conversationId
            ) else {
                return .blocked(reason: "invalid-e2ee-history-batch")
            }
            batch = parsed
        }
        if batch.messages.isEmpty {
            switch batch.cursorStatus {
            case "COMPLETED": return .completed
            case "PAUSED": return .paused(blockedCount: batch.blockedCount)
            default: return .progress(migrated: 0, hasMore: batch.hasMore, blockedCount: batch.blockedCount)
            }
        }

        var migrated = 0
        for item in batch.messages {
            do {
                let requestId = try E2EEV2HistoryMigrationContract.clientRequestId(
                    messageId: item.source.messageId,
                    sourceHash: item.sourceHash
                )
                if !item.legacyAttachments.isEmpty,
                   let store = mediaOutboxStore,
                   let outbox = mediaOutbox,
                   (try? store.load(
                       ownerScopeId: ownerScopeId,
                       clientRequestId: requestId
                   )) != nil {
                    let execution = await outbox.execute(
                        clientRequestId: requestId,
                        ownerScopeId: ownerScopeId
                    )
                    switch execution.disposition {
                    case .success:
                        migrated += 1
                        continue
                    case .retry, .authenticationRequired:
                        return .queued(1)
                    case .blocked:
                        return .blocked(reason: execution.reason ?? "e2ee-history-outbox-blocked")
                    case .terminal:
                        return .blocked(reason: execution.reason ?? "e2ee-history-outbox-invalid")
                    }
                }
                let preparedBlobs = try await prepareLegacyAttachments(item)
                defer {
                    preparedBlobs.forEach { try? FileManager.default.removeItem(at: $0.ciphertextURL) }
                }
                let context = E2EEV2MessageContext(
                    conversationId: conversationId,
                    epochNumber: epochNumber,
                    senderDeviceId: device.deviceId,
                    clientRequestId: requestId,
                    ttlSeconds: 0,
                    encryptedBlobIds: preparedBlobs.map(\.manifest.blobId)
                )
                var cleartext = try E2EEV2HistoryMigrationContract.encryptedCleartext(
                    item,
                    preparedBlobs: preparedBlobs
                )
                defer { cleartext.resetBytes(in: 0..<cleartext.count) }
                let envelope = try E2EEV2MessageCrypto.encrypt(
                    cleartext: cleartext,
                    epochKey: epochKey,
                    nonce: try randomNonce(),
                    context: context
                )
                let signature = try identityStore.sign(
                    canonicalRequest: E2EEV2MessageCrypto.signatureCanonical(
                        context: context,
                        envelope: envelope
                    )
                )
                let signed = E2EEV2SignedMessageEnvelope(
                    envelope: envelope,
                    senderSignatureB64: signature.base64EncodedString()
                )
                if !preparedBlobs.isEmpty {
                    guard let outbox = mediaOutbox else {
                        return .blocked(reason: "e2ee-history-outbox-unavailable")
                    }
                    let record = E2EEV2MediaOutboxRecord(
                        conversationId: conversationId,
                        envelope: signed,
                        blobs: preparedBlobs.map { prepared in
                            E2EEV2OutboxBlobManifest(
                                blobId: prepared.manifest.blobId,
                                algorithm: prepared.manifest.algorithm,
                                ciphertextSha256: prepared.manifest.ciphertextSha256,
                                ciphertextSize: prepared.manifest.ciphertextSize,
                                uploadChunkSize: E2EEV2MediaOutboxStore.uploadChunkBytes
                            )
                        },
                        operation: .history,
                        sourceMessageId: item.source.messageId,
                        sourceHash: item.sourceHash
                    )
                    try await outbox.enqueue(
                        record: record,
                        ciphertextSources: Dictionary(
                            uniqueKeysWithValues: preparedBlobs.map {
                                ($0.manifest.blobId, $0.ciphertextURL)
                            }
                        )
                    )
                    let execution = await outbox.execute(
                        clientRequestId: requestId,
                        ownerScopeId: ownerScopeId
                    )
                    switch execution.disposition {
                    case .success:
                        migrated += 1
                        continue
                    case .retry, .authenticationRequired:
                        return .queued(1)
                    case .blocked:
                        return .blocked(reason: execution.reason ?? "e2ee-history-outbox-blocked")
                    case .terminal:
                        return .blocked(reason: execution.reason ?? "e2ee-history-outbox-invalid")
                    }
                }
                let committed = await transport.putJSON(
                    path: "/api/e2ee/v2/conversations/\(conversationId)/history/messages/\(item.source.messageId)",
                    body: try E2EEV2HistoryMigrationContract.commitBody(item: item, envelope: signed),
                    expectedOwnerScopeId: ownerScopeId,
                    capabilitySet: .history
                )
                switch committed {
                case .failure(let failure): return .failed(failure)
                case .success(let data, _, _):
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["sourceMessageId"] as? String == item.source.messageId,
                          object["clearSourceDeleted"] as? Bool == true else {
                        return .blocked(reason: "invalid-e2ee-history-commit")
                    }
                    migrated += 1
                }
            } catch {
                return .blocked(reason: "invalid-e2ee-history-local-state")
            }
        }
        return .progress(
            migrated: migrated,
            hasMore: batch.hasMore,
            blockedCount: batch.blockedCount
        )
    }

    private func randomNonce() throws -> Data {
        var data = Data(count: 12)
        let result = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!)
        }
        guard result == errSecSuccess else { throw E2EEV2MessageCryptoError.invalidNonce }
        return data
    }

    private func prepareLegacyAttachments(
        _ item: E2EEV2HistoryBatchItem
    ) async throws -> [E2EEV2PreparedBlob] {
        var prepared: [E2EEV2PreparedBlob] = []
        do {
            for attachment in item.legacyAttachments {
                guard let sourceURL = URL(string: attachment.url),
                      allowedLegacyMediaURL(sourceURL) else {
                    throw E2EEV2MediaOutboxError.invalidRecord
                }
                let (downloadURL, response) = try await urlSession.download(from: sourceURL)
                defer { try? FileManager.default.removeItem(at: downloadURL) }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let finalURL = http.url,
                      allowedLegacyMediaURL(finalURL) else {
                    throw E2EEV2MediaOutboxError.invalidRecord
                }
                let values = try downloadURL.resourceValues(forKeys: [.fileSizeKey])
                guard Int64(values.fileSize ?? -1) >= 0,
                      Int64(values.fileSize ?? -1) <= E2EEV2BlobCrypto.maxPlaintextBytes else {
                    throw E2EEV2BlobCryptoError.invalidChunk
                }
                let blobId = try E2EEV2HistoryMigrationContract.historicalBlobId(
                    sourceHash: item.sourceHash,
                    attachmentId: attachment.id
                )
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sq-e2ee-history-\(blobId).bin")
                prepared.append(try E2EEV2BlobFileEncryptor.encryptFile(
                    sourceURL: downloadURL,
                    ciphertextURL: destination,
                    blobId: blobId
                ))
            }
            return prepared
        } catch {
            prepared.forEach { try? FileManager.default.removeItem(at: $0.ciphertextURL) }
            throw error
        }
    }

    private func allowedLegacyMediaURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
#if DEBUG
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1"].contains(url.host?.lowercased() ?? "")
#else
        return false
#endif
    }
}

private struct E2EEV2BlobDeclaration: Encodable, Sendable {
    let version: Int
    let blobId: String
    let algorithm: String
    let ciphertextSha256: String
    let ciphertextSize: String
    let chunkSize: Int
}

private struct E2EEV2BlobInitResponse: Decodable, Sendable {
    let blob: E2EEV2BlobState
}

private struct E2EEV2BlobState: Decodable, Sendable {
    let blobId: String
    let status: String
    let ciphertextSha256: String
    let ciphertextSize: String
    let partCount: Int
    let uploadedParts: [Int]
}

private struct E2EEV2BlobCompleteResponse: Decodable, Sendable {
    let blobId: String
    let status: String
}

private struct E2EEV2MessageWriteResponse: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let clientRequestId: String
    }
    let message: Message
}

private struct E2EEV2HistoryOutboxCommit: Encodable, Sendable {
    let version: Int
    let sourceMessageId: String
    let sourceHash: String
    let envelope: E2EEV2SignedMessageEnvelope
}

private struct E2EEV2HistoryOutboxCommitResponse: Decodable, Sendable {
    let sourceMessageId: String
    let envelopeId: String
    let clearSourceDeleted: Bool
    let legacyCleanupPending: Bool
}

// MARK: - E2EE v2 portable export (preview, fail-closed)

enum E2EEV2MessageDeliveryFailure: Error, Equatable {
    case transport(E2EEV2TransportFailure)
    case invalid(String)
}


// MARK: - E2EE v2 Live Share transport (dormant)

struct E2EEV2LiveSharePublishInput {
    let ownerScopeId: String
    let sessionId: String
    let preparation: E2EEV2MessagePreparationInput
}

struct E2EEV2LiveSharePublishedUpdate: Equatable, Sendable {
    let updateId: String
    let sessionId: String
    let clientRequestId: String
    let createdAt: String
    let expiresAt: String
    let idempotentReplay: Bool
}

enum E2EEV2LiveSharePublishResult {
    case success(E2EEV2LiveSharePublishedUpdate)
    case failure(E2EEV2TransportFailure)
}

struct E2EEV2LiveShareFetchInput: Equatable, Sendable {
    let ownerScopeId: String
    let conversationId: String
    let sessionId: String
}

struct E2EEV2ReceivedLiveShareUpdate {
    let updateId: String
    let sequence: Int
    let observedAt: String
    let expiresAt: String
    let content: [String: Any]
}

enum E2EEV2LiveShareFetchResult {
    case success(E2EEV2ReceivedLiveShareUpdate?)
    case failure(E2EEV2TransportFailure)
}

struct E2EEV2LiveShareLifecycleSession: Equatable, Sendable {
    let id: String
    let conversationId: String
    let requesterId: String
    let sharerId: String
    let status: String
    let expiresAt: String
    let valueData: Data
}

enum E2EEV2LiveShareLifecycleResult {
    case success(sessions: [E2EEV2LiveShareLifecycleSession], responseData: Data)
    case failure(E2EEV2TransportFailure)
}

struct E2EEV2LiveSharePendingEnvelope: Codable, Equatable, Sendable {
    let clientRequestId: String
    let sendDeadlineAtMs: Int64
    let envelope: E2EEV2SignedMessageEnvelope
}

private struct E2EEV2LiveShareStateRecord: Codable {
    let version: Int
    let ownerScopeId: String
    let conversationId: String
    let sessionId: String
    var nextSequence: Int
    var pending: E2EEV2LiveSharePendingEnvelope?
    var updatedAtMs: Int64
}

enum E2EEV2LiveShareStateError: Error, Equatable {
    case invalidScope
    case invalidRecord
    case sequenceExhausted
}

/// État minimal Keychain : compteur monotone et enveloppe opaque en attente.
/// Aucun payload, coordonnée, PLMN ou métrique radio n'est sérialisé ici.
final class E2EEV2LiveShareStateStore: @unchecked Sendable {
    private let tokenStore: TokenStore
    private let lock = NSLock()
    private static let ownerPattern = #"^user:[A-Za-z0-9_-]{8,150}\z"#
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")) {
        self.tokenStore = tokenStore
    }

    func claimSequence(
        ownerScopeId: String,
        conversationId: String,
        sessionId: String,
        nowMs: Int64
    ) throws -> Int {
        try lock.withLock {
            var record = try loadOrCreate(
                ownerScopeId: ownerScopeId,
                conversationId: conversationId,
                sessionId: sessionId,
                nowMs: nowMs
            )
            guard record.pending == nil else { throw E2EEV2LiveShareStateError.invalidRecord }
            guard record.nextSequence >= 0, record.nextSequence < Int.max else {
                throw E2EEV2LiveShareStateError.sequenceExhausted
            }
            let sequence = record.nextSequence
            record.nextSequence += 1
            record.updatedAtMs = max(0, nowMs)
            try save(record)
            return sequence
        }
    }

    func pending(
        ownerScopeId: String,
        conversationId: String,
        sessionId: String
    ) throws -> E2EEV2LiveSharePendingEnvelope? {
        try lock.withLock {
            guard let record = try load(ownerScopeId: ownerScopeId, sessionId: sessionId) else {
                return nil
            }
            guard record.ownerScopeId == ownerScopeId,
                  record.conversationId == conversationId,
                  record.sessionId == sessionId else {
                throw E2EEV2LiveShareStateError.invalidRecord
            }
            return record.pending
        }
    }

    func storePending(
        ownerScopeId: String,
        conversationId: String,
        sessionId: String,
        pending: E2EEV2LiveSharePendingEnvelope,
        nowMs: Int64
    ) throws {
        try lock.withLock {
            guard pending.sendDeadlineAtMs > nowMs,
                  pending.envelope.clientRequestId == pending.clientRequestId,
                  pending.envelope.ttlSeconds > 0,
                  pending.envelope.encryptedBlobIds.isEmpty,
                  var record = try load(ownerScopeId: ownerScopeId, sessionId: sessionId),
                  record.ownerScopeId == ownerScopeId,
                  record.conversationId == conversationId,
                  record.sessionId == sessionId,
                  record.pending == nil else {
                throw E2EEV2LiveShareStateError.invalidRecord
            }
            record.pending = pending
            record.updatedAtMs = max(0, nowMs)
            try save(record)
        }
    }

    func complete(
        ownerScopeId: String,
        sessionId: String,
        clientRequestId: String,
        nowMs: Int64
    ) throws {
        try lock.withLock {
            guard var record = try load(ownerScopeId: ownerScopeId, sessionId: sessionId),
                  record.ownerScopeId == ownerScopeId else { return }
            guard record.pending?.clientRequestId == clientRequestId else { return }
            record.pending = nil
            record.updatedAtMs = max(0, nowMs)
            try save(record)
        }
    }

    private func loadOrCreate(
        ownerScopeId: String,
        conversationId: String,
        sessionId: String,
        nowMs: Int64
    ) throws -> E2EEV2LiveShareStateRecord {
        try validate(ownerScopeId, conversationId, sessionId)
        if let existing = try load(ownerScopeId: ownerScopeId, sessionId: sessionId) {
            guard existing.ownerScopeId == ownerScopeId,
                  existing.conversationId == conversationId,
                  existing.sessionId == sessionId else {
                throw E2EEV2LiveShareStateError.invalidRecord
            }
            return existing
        }
        return .init(
            version: 1,
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            sessionId: sessionId,
            nextSequence: 0,
            pending: nil,
            updatedAtMs: max(0, nowMs)
        )
    }

    private func load(
        ownerScopeId: String,
        sessionId: String
    ) throws -> E2EEV2LiveShareStateRecord? {
        try validateOwnerAndSession(ownerScopeId, sessionId)
        guard let raw = try tokenStore.string(for: storageKey(ownerScopeId, sessionId)),
              let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(E2EEV2LiveShareStateRecord.self, from: data),
              record.version == 1,
              record.nextSequence >= 0 else {
            if try tokenStore.string(for: storageKey(ownerScopeId, sessionId)) == nil { return nil }
            throw E2EEV2LiveShareStateError.invalidRecord
        }
        return record
    }

    private func save(_ record: E2EEV2LiveShareStateRecord) throws {
        try validate(record.ownerScopeId, record.conversationId, record.sessionId)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 512 * 1_024,
              let value = String(data: data, encoding: .utf8) else {
            throw E2EEV2LiveShareStateError.invalidRecord
        }
        try tokenStore.set(
            value,
            for: storageKey(record.ownerScopeId, record.sessionId),
            accessibility: .whenUnlocked
        )
    }

    private func validate(_ owner: String, _ conversation: String, _ session: String) throws {
        try validateOwnerAndSession(owner, session)
        guard conversation.range(of: Self.opaquePattern, options: .regularExpression) != nil else {
            throw E2EEV2LiveShareStateError.invalidScope
        }
    }

    private func validateOwnerAndSession(_ owner: String, _ session: String) throws {
        guard owner.range(of: Self.ownerPattern, options: .regularExpression) != nil,
              session.range(of: Self.opaquePattern, options: .regularExpression) != nil else {
            throw E2EEV2LiveShareStateError.invalidScope
        }
    }

    private func storageKey(_ ownerScopeId: String, _ sessionId: String) -> String {
        let digest = SHA256.hash(data: Data("\(ownerScopeId)\n\(sessionId)".utf8))
        return "e2ee_v2_live_share_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct E2EEV2LiveSharePublishDependencies {
    let prepareEnvelope: () -> E2EEV2MessagePreparationResult
    let postJSON: (_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data>
}

struct E2EEV2LiveShareFetchDependencies {
    let loadIdentity: () throws -> E2EEV2DeviceDescriptor?
    let postJSON: (_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data>
    let loadEpoch: (_ conversationId: String, _ epochNumber: Int) throws -> E2EEV2StoredEpochKey?
    let unwrapEpoch: (_ delivery: E2EEV2EpochDelivery) throws -> Data
    let now: () -> Date
}

/// Transport Live Share v2 dormant. Les gates sont vérifiés avant validation,
/// Keychain, chiffrement ou réseau. Une époque reçue est déballée seulement en
/// mémoire et aucune position en clair n'est persistée par ce client.
final class E2EEV2LiveShareTransportClient: @unchecked Sendable {
    private static let ownerPattern = #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}\z"#
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    private static let requestPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z"#
    private static let maxClockSkew: TimeInterval = 5 * 60

    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let epochStore: E2EEV2EpochKeyStore

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        epochStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore()
    ) {
        self.identityStore = identityStore
        self.epochStore = epochStore
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    func createSessionRuntime(
        ownerScopeId: String,
        conversationId: String,
        body: Data
    ) async -> E2EEV2LiveShareLifecycleResult {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .failure(Self.activationFailure())
        }
        guard Self.matches(ownerScopeId, Self.ownerPattern),
              Self.matches(conversationId, Self.opaquePattern),
              body.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              request["conversationId"] as? String == conversationId else {
            return .failure(Self.localFailure("invalid-e2ee-v2-live-share-creation-scope"))
        }
        switch await transport.postJSON(
            path: "/api/live-share/requests",
            body: body,
            expectedOwnerScopeId: ownerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let data, _, _):
            guard let sessions = Self.parseCreateResponseContractPreview(
                data,
                expectedConversationId: conversationId
            ) else {
                return .failure(Self.localFailure("invalid-e2ee-v2-live-share-creation-response"))
            }
            return .success(sessions: sessions, responseData: data)
        }
    }

    func acceptSessionRuntime(
        ownerScopeId: String,
        sessionId: String
    ) async -> E2EEV2LiveShareLifecycleResult {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .failure(Self.activationFailure())
        }
        guard Self.matches(ownerScopeId, Self.ownerPattern),
              Self.matches(sessionId, Self.opaquePattern) else {
            return .failure(Self.localFailure("invalid-e2ee-v2-live-share-acceptance-scope"))
        }
        switch await transport.postJSON(
            path: "/api/live-share/sessions/\(sessionId)/accept",
            body: Data("{}".utf8),
            expectedOwnerScopeId: ownerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let data, _, _):
            guard let session = Self.parseAcceptResponseContractPreview(
                data,
                expectedSessionId: sessionId
            ) else {
                return .failure(Self.localFailure("invalid-e2ee-v2-live-share-acceptance-response"))
            }
            return .success(sessions: [session], responseData: data)
        }
    }

    func publishPreparedRuntime(
        ownerScopeId: String,
        sessionId: String,
        envelope: E2EEV2SignedMessageEnvelope
    ) async -> E2EEV2LiveSharePublishResult {
        guard E2EEV2RuntimeWriteGate.enabled else {
            return .failure(Self.activationFailure())
        }
        guard Self.matches(ownerScopeId, Self.ownerPattern),
              Self.matches(sessionId, Self.opaquePattern),
              Self.matches(envelope.clientRequestId, Self.requestPattern),
              envelope.ttlSeconds > 0,
              envelope.encryptedBlobIds.isEmpty,
              let body = try? JSONEncoder().encode(envelope) else {
            return .failure(Self.localFailure("invalid-e2ee-v2-live-share-envelope"))
        }
        let path = "/api/e2ee/v2/live-share/sessions/\(sessionId)/updates"
        switch await transport.postJSON(
            path: path,
            body: body,
            expectedOwnerScopeId: ownerScopeId,
            capabilitySet: .message
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let data, _, let replay):
            guard let update = Self.parsePublishResponseContractPreview(
                data,
                expectedSessionId: sessionId,
                expectedClientRequestId: envelope.clientRequestId,
                transportIdempotentReplay: replay
            ) else {
                return .failure(Self.localFailure("invalid-e2ee-v2-live-share-publish-response"))
            }
            return .success(update)
        }
    }

    func publishRuntime(
        _ input: E2EEV2LiveSharePublishInput
    ) async -> E2EEV2LiveSharePublishResult {
        await Self.publishRuntimeWithDependencies(
            input,
            dependencies: .init(
                prepareEnvelope: { [identityStore = self.identityStore, epochStore = self.epochStore] in
                    E2EEV2MessageComposer.prepareRuntime(
                        input: input.preparation,
                        identityStore: identityStore,
                        epochStore: epochStore
                    )
                },
                postJSON: { [transport = self.transport] path, body in
                    await transport.postJSON(
                        path: path,
                        body: body,
                        expectedOwnerScopeId: input.ownerScopeId,
                        capabilitySet: .message
                    )
                }
            )
        )
    }

    func fetchLatestRuntime(
        _ input: E2EEV2LiveShareFetchInput
    ) async -> E2EEV2LiveShareFetchResult {
        await Self.fetchLatestRuntimeWithDependencies(
            input,
            dependencies: .init(
                loadIdentity: { [identityStore = self.identityStore] in
                    guard LocalAccountScope.currentUserId != nil,
                          LocalAccountScope.currentOwnerScopeId == input.ownerScopeId else {
                        return nil
                    }
                    return try identityStore.load(
                        ownerNamespace: LocalAccountScope.storageNamespace(for: input.ownerScopeId)
                    )
                },
                postJSON: { [transport = self.transport] path, body in
                    await transport.postJSON(
                        path: path,
                        body: body,
                        expectedOwnerScopeId: input.ownerScopeId,
                        capabilitySet: .message
                    )
                },
                loadEpoch: { [epochStore = self.epochStore] conversationId, epochNumber in
                    guard LocalAccountScope.currentUserId != nil,
                          LocalAccountScope.currentOwnerScopeId == input.ownerScopeId else {
                        return nil
                    }
                    return try epochStore.loadEpoch(
                        conversationId: conversationId,
                        epochNumber: epochNumber,
                        ownerNamespace: LocalAccountScope.storageNamespace(for: input.ownerScopeId)
                    )
                },
                unwrapEpoch: { [identityStore = self.identityStore] delivery in
                    try identityStore.unwrapEpochKey(
                        delivery: delivery,
                        ownerNamespace: LocalAccountScope.storageNamespace(for: input.ownerScopeId)
                    )
                },
                now: Date.init
            )
        )
    }

    static func publishRuntimeWithDependencies(
        _ input: E2EEV2LiveSharePublishInput,
        dependencies: E2EEV2LiveSharePublishDependencies
    ) async -> E2EEV2LiveSharePublishResult {
        guard E2EEV2RuntimeWriteGate.enabled else { return .failure(activationFailure()) }
        guard matches(input.ownerScopeId, ownerPattern),
              validPrivatePublishScope(input) else {
            return .failure(localFailure("invalid-e2ee-v2-live-share-publish-scope"))
        }
        let prepared: E2EEV2SignedMessageEnvelope
        switch dependencies.prepareEnvelope() {
        case .blocked(let reason): return .failure(localFailure(reason))
        case .prepared(let envelope): prepared = envelope
        }
        guard let body = try? JSONEncoder().encode(prepared) else {
            return .failure(localFailure("invalid-e2ee-v2-live-share-envelope"))
        }
        let path = "/api/e2ee/v2/live-share/sessions/\(input.sessionId)/updates"
        switch await dependencies.postJSON(path, body) {
        case .failure(let failure): return .failure(failure)
        case .success(let data, _, let replay):
            guard let update = parsePublishResponseContractPreview(
                data,
                expectedSessionId: input.sessionId,
                expectedClientRequestId: input.preparation.clientRequestId,
                transportIdempotentReplay: replay
            ) else {
                return .failure(localFailure("invalid-e2ee-v2-live-share-publish-response"))
            }
            return .success(update)
        }
    }

    static func fetchLatestRuntimeWithDependencies(
        _ input: E2EEV2LiveShareFetchInput,
        dependencies: E2EEV2LiveShareFetchDependencies
    ) async -> E2EEV2LiveShareFetchResult {
        guard E2EEV2RuntimeReadGate.enabled else { return .failure(activationFailure()) }
        guard matches(input.ownerScopeId, ownerPattern),
              matches(input.conversationId, opaquePattern),
              matches(input.sessionId, opaquePattern) else {
            return .failure(localFailure("invalid-e2ee-v2-live-share-fetch-scope"))
        }
        do {
            guard let identity = try dependencies.loadIdentity(),
                  matches(identity.deviceId, opaquePattern) else {
                return .failure(localFailure("e2ee-v2-device-identity-unavailable"))
            }
            let path = "/api/e2ee/v2/live-share/sessions/\(input.sessionId)/updates/latest"
            switch await dependencies.postJSON(path, Data("{}".utf8)) {
            case .failure(let failure): return .failure(failure)
            case .success(let data, _, _):
                return decryptLatestContractPreview(
                    data,
                    input: input,
                    identity: identity,
                    loadEpoch: dependencies.loadEpoch,
                    unwrapEpoch: dependencies.unwrapEpoch,
                    now: dependencies.now()
                )
            }
        } catch {
            return .failure(localFailure("invalid-e2ee-v2-live-share-local-state"))
        }
    }

    /// Réservé aux tests de contrat tant que le runtime est fermé.
    static func parseCreateResponseContractPreview(
        _ data: Data,
        expectedConversationId: String
    ) -> [E2EEV2LiveShareLifecycleSession]? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["mode", "createdCount", "skippedCount", "sessions", "session"]),
              ["targeted", "broadcast"].contains(root["mode"] as? String ?? ""),
              let createdCount = integer(root["createdCount"]), createdCount >= 0,
              let skippedCount = integer(root["skippedCount"]), skippedCount >= 0,
              let values = root["sessions"] as? [Any], (1...100).contains(values.count) else {
            return nil
        }
        let sessions = values.compactMap {
            parseLifecycleSession($0, expectedConversationId: expectedConversationId)
        }
        guard sessions.count == values.count,
              Set(sessions.map(\.id)).count == sessions.count,
              createdCount + skippedCount == sessions.count,
              let primary = parseLifecycleSession(
                root["session"],
                expectedConversationId: expectedConversationId
              ),
              primary.id == sessions.first?.id else { return nil }
        return sessions
    }

    /// Réservé aux tests de contrat tant que le runtime est fermé.
    static func parseAcceptResponseContractPreview(
        _ data: Data,
        expectedSessionId: String
    ) -> E2EEV2LiveShareLifecycleSession? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (exactKeys(root, ["session"])
                || exactKeys(root, ["session", "alreadyProcessed"])),
              root["alreadyProcessed"] == nil
                || strictBoolean(root["alreadyProcessed"]) != nil,
              let session = parseLifecycleSession(
                root["session"],
                expectedSessionId: expectedSessionId
              ),
              session.status == "active" else { return nil }
        return session
    }

    private static func parseLifecycleSession(
        _ value: Any?,
        expectedConversationId: String? = nil,
        expectedSessionId: String? = nil
    ) -> E2EEV2LiveShareLifecycleSession? {
        guard let session = value as? [String: Any],
              let id = session["id"] as? String, matches(id, opaquePattern),
              expectedSessionId == nil || id == expectedSessionId,
              let conversationId = session["conversationId"] as? String,
              matches(conversationId, opaquePattern),
              expectedConversationId == nil || conversationId == expectedConversationId,
              let requesterId = session["requesterId"] as? String, matches(requesterId, opaquePattern),
              let sharerId = session["sharerId"] as? String, matches(sharerId, opaquePattern),
              let status = session["status"] as? String, ["pending", "active"].contains(status),
              let expiresAt = session["expiresAt"] as? String,
              E2EEV2PortableInventoryContract.parseInstant(expiresAt) != nil,
              strictBoolean(session["e2eeV2Required"]) == true,
              session["lastPayload"] is NSNull,
              session["lastLocation"] is NSNull,
              JSONSerialization.isValidJSONObject(session),
              let valueData = try? JSONSerialization.data(
                withJSONObject: session,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return .init(
            id: id,
            conversationId: conversationId,
            requesterId: requesterId,
            sharerId: sharerId,
            status: status,
            expiresAt: expiresAt,
            valueData: valueData
        )
    }

    /// Réservé aux tests de contrat tant que le runtime est fermé.
    static func parsePublishResponseContractPreview(
        _ data: Data,
        expectedSessionId: String,
        expectedClientRequestId: String,
        transportIdempotentReplay: Bool
    ) -> E2EEV2LiveSharePublishedUpdate? {
        guard data.count <= 64 * 1_024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["version", "update", "idempotentReplay"]),
              integer(root["version"]) == 1,
              strictBoolean(root["idempotentReplay"]) == transportIdempotentReplay,
              let update = root["update"] as? [String: Any],
              exactKeys(update, ["updateId", "sessionId", "clientRequestId", "createdAt", "expiresAt"]),
              let updateId = update["updateId"] as? String, matches(updateId, opaquePattern),
              let sessionId = update["sessionId"] as? String,
              sessionId == expectedSessionId, matches(sessionId, opaquePattern),
              let clientRequestId = update["clientRequestId"] as? String,
              clientRequestId == expectedClientRequestId, matches(clientRequestId, requestPattern),
              let createdAt = update["createdAt"] as? String,
              let createdDate = E2EEV2PortableInventoryContract.parseInstant(createdAt),
              let expiresAt = update["expiresAt"] as? String,
              let expiryDate = E2EEV2PortableInventoryContract.parseInstant(expiresAt),
              expiryDate > createdDate else { return nil }
        return .init(
            updateId: updateId,
            sessionId: sessionId,
            clientRequestId: clientRequestId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            idempotentReplay: transportIdempotentReplay
        )
    }

    /// Valide la portée privée après vérification des deux signatures et déchiffrement.
    static func validateDecryptedUpdateContractPreview(
        updateId: String,
        expectedSessionId: String,
        message: E2EEV2DecryptedMessage,
        publicExpiresAt: Date,
        now: Date
    ) -> E2EEV2ReceivedLiveShareUpdate? {
        guard matches(updateId, opaquePattern),
              matches(expectedSessionId, opaquePattern),
              message.ttlSeconds > 0,
              message.encryptedBlobIds.isEmpty,
              message.content["kind"] as? String == "LIVE_LOCATION",
              let body = message.content["body"] as? [String: Any],
              body["sessionId"] as? String == expectedSessionId,
              let sequence = integer(body["sequence"]), sequence >= 0,
              let observedAt = body["observedAt"] as? String,
              let observedDate = E2EEV2PortableInventoryContract.parseInstant(observedAt),
              let expiresAt = body["expiresAt"] as? String,
              let privateExpiry = E2EEV2PortableInventoryContract.parseInstant(expiresAt),
              privateExpiry > observedDate,
              privateExpiry > now,
              privateExpiry <= publicExpiresAt.addingTimeInterval(maxClockSkew) else { return nil }
        return .init(
            updateId: updateId,
            sequence: sequence,
            observedAt: observedAt,
            expiresAt: expiresAt,
            content: message.content
        )
    }

    private static func decryptLatestContractPreview(
        _ data: Data,
        input: E2EEV2LiveShareFetchInput,
        identity: E2EEV2DeviceDescriptor,
        loadEpoch: (_ conversationId: String, _ epochNumber: Int) throws -> E2EEV2StoredEpochKey?,
        unwrapEpoch: (_ delivery: E2EEV2EpochDelivery) throws -> Data,
        now: Date
    ) -> E2EEV2LiveShareFetchResult {
        guard data.count <= 768 * 1_024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              exactKeys(root, ["envelope"]) else {
            return .failure(localFailure("invalid-e2ee-v2-live-share-delivery"))
        }
        if root["envelope"] is NSNull { return .success(nil) }
        guard let envelope = root["envelope"] as? [String: Any],
              let updateId = envelope["id"] as? String, matches(updateId, opaquePattern),
              let delivery = E2EEV2MessageDeliveryContract.parseAndVerify(
                data,
                ownerScopeId: input.ownerScopeId,
                expectedEnvelopeId: updateId,
                expectedConversationId: input.conversationId,
                expectedRecipientDeviceId: identity.deviceId,
                allowServerBoundedExpiry: true
              ),
              delivery.encryptedBlobs.isEmpty,
              let publicExpiresAt = delivery.expiresAt,
              let publicExpiry = E2EEV2PortableInventoryContract.parseInstant(publicExpiresAt),
              publicExpiry > now else {
            return .failure(localFailure("invalid-or-untrusted-e2ee-v2-live-share-delivery"))
        }

        var ephemeralKey = Data()
        defer { ephemeralKey.resetBytes(in: 0..<ephemeralKey.count) }
        do {
            let epoch: E2EEV2StoredEpochKey
            if let stored = try loadEpoch(
                input.conversationId,
                delivery.epochDelivery.epochNumber
            ) {
                epoch = stored
            } else {
                ephemeralKey = try unwrapEpoch(delivery.epochDelivery)
                guard ephemeralKey.count == 32,
                      try E2EEV2EpochCrypto.keyCommitment(ephemeralKey)
                        == delivery.epochDelivery.keyCommitmentB64 else {
                    return .failure(localFailure("e2ee-v2-epoch-unwrapping-failed"))
                }
                epoch = .init(
                    conversationId: delivery.epochDelivery.conversationId,
                    epochId: delivery.epochDelivery.epochId,
                    epochNumber: delivery.epochDelivery.epochNumber,
                    keyCommitmentB64: delivery.epochDelivery.keyCommitmentB64,
                    epochKey: ephemeralKey
                )
            }
            guard epoch.epochId == delivery.epochDelivery.epochId,
                  epoch.epochNumber == delivery.epochDelivery.epochNumber,
                  epoch.keyCommitmentB64 == delivery.epochDelivery.keyCommitmentB64 else {
                return .failure(localFailure("e2ee-v2-delivered-epoch-mismatch"))
            }
            let message = try E2EEV2MessageReceiver.decryptContractPreview(
                input: delivery.incoming,
                epoch: epoch
            )
            guard let update = validateDecryptedUpdateContractPreview(
                updateId: updateId,
                expectedSessionId: input.sessionId,
                message: message,
                publicExpiresAt: publicExpiry,
                now: now
            ) else {
                return .failure(localFailure("invalid-e2ee-v2-live-share-private-content"))
            }
            return .success(update)
        } catch {
            return .failure(localFailure("invalid-or-undecryptable-e2ee-v2-live-share-delivery"))
        }
    }

    private static func validPrivatePublishScope(_ input: E2EEV2LiveSharePublishInput) -> Bool {
        guard matches(input.sessionId, opaquePattern),
              matches(input.preparation.conversationId, opaquePattern),
              matches(input.preparation.clientRequestId, requestPattern),
              input.preparation.ttlSeconds > 0,
              input.preparation.encryptedBlobIds.isEmpty,
              let data = try? E2EEV2ContentContract.encode(input.preparation.content),
              let content = E2EEV2ContentContract.parse(data),
              content["kind"] as? String == "LIVE_LOCATION",
              let body = content["body"] as? [String: Any],
              body["sessionId"] as? String == input.sessionId else { return false }
        return true
    }

    private static func activationFailure() -> E2EEV2TransportFailure {
        .init(
            kind: .activationBlocked,
            code: "E2EE_V2_SECURITY_REVIEW_REQUIRED",
            message: "e2ee-v2-security-review-required"
        )
    }

    private static func localFailure(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }

    private static func exactKeys(_ value: [String: Any], _ expected: Set<String>) -> Bool {
        Set(value.keys) == expected
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

enum E2EEV2LiveShareRuntimeError: Error, Equatable {
    case invalidSession
    case invalidPayload
    case preparationBlocked(String)
    case transport(E2EEV2TransportFailure)
}

struct E2EEV2FetchedLiveSharePayload: Sendable {
    let updateId: String
    let payload: LiveSharePayload
}

enum E2EEV2LiveShareEvent: Equatable, Sendable {
    case status(value: String, eventId: String?)
    case encryptedUpdate(updateId: String, createdAt: String, expiresAt: String, eventId: String?)
}

enum E2EEV2LiveShareEventContract {
    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#

    static func parse(event: String, data: String, eventId: String?) -> E2EEV2LiveShareEvent? {
        guard data.utf8.count <= 32 * 1_024,
              let raw = data.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return nil
        }
        if event == "status" {
            guard Set(value.keys) == ["status"],
                  let status = value["status"] as? String else { return nil }
            return .status(value: status, eventId: eventId)
        }
        guard event == "encrypted_update",
              Set(value.keys) == ["updateId", "createdAt", "expiresAt"],
              let updateId = value["updateId"] as? String,
              updateId.range(of: opaquePattern, options: .regularExpression) != nil,
              let createdAt = value["createdAt"] as? String,
              let created = E2EEV2PortableInventoryContract.parseInstant(createdAt),
              let expiresAt = value["expiresAt"] as? String,
              let expiry = E2EEV2PortableInventoryContract.parseInstant(expiresAt),
              expiry > created else { return nil }
        return .encryptedUpdate(
            updateId: updateId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            eventId: eventId
        )
    }
}

final class E2EEV2LiveShareEventClient: @unchecked Sendable {
    private let api: APIClient
    private let identityStore: E2EEV2DeviceIdentityStore
    private let session: URLSession

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        session: URLSession = URLSession(configuration: SSEClient.makeSessionConfiguration())
    ) {
        self.api = api
        self.identityStore = identityStore
        self.session = session
    }

    func eventsRuntime(
        ownerScopeId: String,
        sessionId: String,
        lastEventId: String? = nil
    ) -> AsyncThrowingStream<E2EEV2LiveShareEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [api, identityStore, session] in
                do {
                    guard E2EEV2RuntimeReadGate.enabled,
                          LocalAccountScope.currentUserId != nil,
                          LocalAccountScope.currentOwnerScopeId == ownerScopeId,
                          ownerScopeId.range(
                            of: #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}\z"#,
                            options: .regularExpression
                          ) != nil,
                          sessionId.range(
                            of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#,
                            options: .regularExpression
                          ) != nil else {
                        continuation.finish()
                        return
                    }
                    let path = "/api/e2ee/v2/live-share/sessions/\(sessionId)/events"
                    let ownerNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
                    guard let descriptor = try identityStore.load(ownerNamespace: ownerNamespace) else {
                        throw E2EEV2DeviceIdentityError.invalidRecord
                    }
                    let nonce = try E2EEV2SignedRequest.newNonce()
                    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
                    let bodyHash = E2EEV2SignedRequest.bodySHA256Base64URL(Data())
                    let canonical = try E2EEV2SignedRequest.canonicalRequest(
                        method: "GET",
                        path: path,
                        timestampMs: timestamp,
                        nonce: nonce,
                        bodySHA256Base64URL: bodyHash
                    )
                    let proof = E2EEV2SignedHeaders(
                        deviceId: descriptor.deviceId,
                        timestampMs: timestamp,
                        nonce: nonce,
                        signatureB64: try identityStore.sign(
                            canonicalRequest: canonical,
                            ownerNamespace: ownerNamespace
                        ).base64EncodedString()
                    )
                    var headers = proof.values
                    headers["Accept"] = "text/event-stream"
                    headers[ClientProtocolContract.protocolVersionHeader] = String(
                        E2EEV2ActivationPolicy.protocolVersion
                    )
                    headers[ClientProtocolContract.capabilitiesHeaderName] = E2EEV2RequestCapabilitySet
                        .message.values.sorted().joined(separator: ",")
                    if let lastEventId, !lastEventId.isEmpty {
                        headers["Last-Event-ID"] = lastEventId
                    }
                    var request = try api.makeURLRequest(APIEndpoint(
                        path: path,
                        headers: headers,
                        skipsAutoRefresh: true
                    ))
                    request.timeoutInterval = 90
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          http.value(forHTTPHeaderField: "Content-Type")?
                            .lowercased().hasPrefix("text/event-stream") == true else {
                        throw APIError.http(
                            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                            code: nil,
                            message: "Flux Live Share E2EE v2 refusé",
                            requestId: nil,
                            retryAfter: nil
                        )
                    }
                    var event = ""
                    var identifier: String?
                    var data = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix(":" ) { continue }
                        if line.hasPrefix("event:") {
                            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased()
                        } else if line.hasPrefix("id:") {
                            identifier = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            if identifier?.isEmpty == true { identifier = nil }
                        } else if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            data = data.isEmpty ? chunk : data + "\n" + chunk
                            guard data.utf8.count <= 32 * 1_024 else {
                                throw E2EEV2LiveShareStateError.invalidRecord
                            }
                        } else if line.isEmpty {
                            if let parsed = E2EEV2LiveShareEventContract.parse(
                                event: event,
                                data: data,
                                eventId: identifier
                            ) {
                                continuation.yield(parsed)
                            }
                            event = ""
                            identifier = nil
                            data = ""
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Coordinateur iOS actif uniquement au premier plan. Le Keychain conserve la
/// séquence et une enveloppe opaque en attente afin qu'un redémarrage ne force
/// ni réutilisation de séquence ni fallback clair.
final class E2EEV2LiveShareRuntimeCoordinator: @unchecked Sendable {
    private let client: E2EEV2LiveShareTransportClient
    private let stateStore: E2EEV2LiveShareStateStore

    init(
        client: E2EEV2LiveShareTransportClient,
        stateStore: E2EEV2LiveShareStateStore = E2EEV2LiveShareStateStore()
    ) {
        self.client = client
        self.stateStore = stateStore
    }

    func publish(
        session: LiveShareSession,
        payload: LiveSharePayload,
        ownerScopeId: String,
        now: Date = Date()
    ) async throws {
        guard E2EEV2RuntimeWriteGate.enabled,
              session.e2eeV2Required == true,
              session.status == "active",
              let expiresAt = session.expiresAt,
              expiresAt > now,
              payload.location != nil else {
            throw E2EEV2LiveShareRuntimeError.invalidSession
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        if let pending = try stateStore.pending(
            ownerScopeId: ownerScopeId,
            conversationId: session.conversationId,
            sessionId: session.id
        ) {
            if pending.sendDeadlineAtMs <= nowMs {
                try stateStore.complete(
                    ownerScopeId: ownerScopeId,
                    sessionId: session.id,
                    clientRequestId: pending.clientRequestId,
                    nowMs: nowMs
                )
            } else {
                try await sendPending(
                    pending,
                    ownerScopeId: ownerScopeId,
                    sessionId: session.id,
                    nowMs: nowMs
                )
            }
        }

        let sequence = try stateStore.claimSequence(
            ownerScopeId: ownerScopeId,
            conversationId: session.conversationId,
            sessionId: session.id,
            nowMs: nowMs
        )
        let clientRequestId = "live-\(UUID().uuidString.lowercased())"
        let content = try privateContent(
            session: session,
            payload: payload,
            sequence: sequence,
            now: now
        )
        let observedAt = try observedDate(payload.at) ?? now
        let ttlSeconds = Int(expiresAt.timeIntervalSince(observedAt).rounded(.down))
        guard (1...30 * 24 * 60 * 60).contains(ttlSeconds) else {
            throw E2EEV2LiveShareRuntimeError.invalidPayload
        }
        let preparation = E2EEV2MessagePreparationInput(
            conversationId: session.conversationId,
            clientRequestId: clientRequestId,
            ttlSeconds: ttlSeconds,
            encryptedBlobIds: [],
            content: content
        )
        let envelope: E2EEV2SignedMessageEnvelope
        switch E2EEV2MessageComposer.prepareRuntime(input: preparation) {
        case .blocked(let reason):
            throw E2EEV2LiveShareRuntimeError.preparationBlocked(reason)
        case .prepared(let value): envelope = value
        }
        let sessionExpiryMs = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        let sendDeadlineAtMs = min(sessionExpiryMs, nowMs + 60_000)
        let pending = E2EEV2LiveSharePendingEnvelope(
            clientRequestId: clientRequestId,
            sendDeadlineAtMs: sendDeadlineAtMs,
            envelope: envelope
        )
        try stateStore.storePending(
            ownerScopeId: ownerScopeId,
            conversationId: session.conversationId,
            sessionId: session.id,
            pending: pending,
            nowMs: nowMs
        )
        try await sendPending(
            pending,
            ownerScopeId: ownerScopeId,
            sessionId: session.id,
            nowMs: nowMs
        )
    }

    func fetchLatest(
        session: LiveShareSession,
        ownerScopeId: String
    ) async throws -> E2EEV2FetchedLiveSharePayload? {
        guard E2EEV2RuntimeReadGate.enabled,
              session.e2eeV2Required == true else {
            throw E2EEV2LiveShareRuntimeError.invalidSession
        }
        switch await client.fetchLatestRuntime(.init(
            ownerScopeId: ownerScopeId,
            conversationId: session.conversationId,
            sessionId: session.id
        )) {
        case .failure(let failure): throw E2EEV2LiveShareRuntimeError.transport(failure)
        case .success(nil): return nil
        case .success(let update?):
            guard let payload = Self.payload(from: update.content) else { return nil }
            return .init(updateId: update.updateId, payload: payload)
        }
    }

    private func sendPending(
        _ pending: E2EEV2LiveSharePendingEnvelope,
        ownerScopeId: String,
        sessionId: String,
        nowMs: Int64
    ) async throws {
        switch await client.publishPreparedRuntime(
            ownerScopeId: ownerScopeId,
            sessionId: sessionId,
            envelope: pending.envelope
        ) {
        case .failure(let failure): throw E2EEV2LiveShareRuntimeError.transport(failure)
        case .success:
            try stateStore.complete(
                ownerScopeId: ownerScopeId,
                sessionId: sessionId,
                clientRequestId: pending.clientRequestId,
                nowMs: nowMs
            )
        }
    }

    private func privateContent(
        session: LiveShareSession,
        payload: LiveSharePayload,
        sequence: Int,
        now: Date
    ) throws -> [String: Any] {
        guard let location = payload.location,
              let expiresAt = session.expiresAt else {
            throw E2EEV2LiveShareRuntimeError.invalidPayload
        }
        let observedAt = try observedDate(payload.at) ?? now
        guard expiresAt > observedAt else { throw E2EEV2LiveShareRuntimeError.invalidPayload }
        let body: [String: Any] = [
            "sessionId": session.id,
            "sequence": sequence,
            "latitude": location.latitude,
            "longitude": location.longitude,
            "accuracyMeters": location.accuracy ?? NSNull(),
            "altitudeMeters": location.altitude ?? NSNull(),
            "speedMetersPerSecond": location.speed ?? NSNull(),
            "headingDegrees": location.heading ?? NSNull(),
            "observedAt": Self.instant(observedAt),
            "expiresAt": Self.instant(expiresAt),
            "radio": payload.radio.map(Self.privateRadio) ?? NSNull(),
        ]
        let content: [String: Any] = [
            "schema": E2EEV2ContentContract.schema,
            "version": E2EEV2ContentContract.version,
            "kind": "LIVE_LOCATION",
            "replyToId": NSNull(),
            "mentions": [],
            "body": body,
        ]
        guard let data = try? E2EEV2ContentContract.encode(content) else {
            throw E2EEV2LiveShareRuntimeError.invalidPayload
        }
        var clear = data
        clear.resetBytes(in: 0..<clear.count)
        return content
    }

    private static func privateRadio(_ radio: LiveShareRadio) -> [String: Any] {
        [
            "connectionType": radio.connectionType ?? NSNull(),
            "technology": radio.technology ?? NSNull(),
            "operator": radio.operatorName ?? NSNull(),
            "observedPlmn": radio.observedPlmn ?? NSNull(),
            "simPlmn": radio.simPlmn ?? NSNull(),
            "simOperator": radio.simOperatorName ?? NSNull(),
            "isRoaming": radio.isRoaming ?? NSNull(),
            "enb": NSNull(), "gnb": NSNull(), "cellId": NSNull(), "ci": NSNull(),
            "pci": NSNull(), "band": radio.band ?? NSNull(), "bandwidth": NSNull(),
            "earfcn": NSNull(), "arfcn": NSNull(), "rsrp": radio.rsrp ?? NSNull(),
            "rsrq": radio.rsrq ?? NSNull(), "snr": radio.snr ?? NSNull(),
            "rssi": NSNull(), "tac": NSNull(), "is5GNSA": NSNull(),
            "is5GSA": NSNull(), "batterySaver": NSNull(),
        ]
    }

    private func observedDate(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw E2EEV2LiveShareRuntimeError.invalidPayload
        }
        return date
    }

    private static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func payload(from content: [String: Any]) -> LiveSharePayload? {
        guard content["kind"] as? String == "LIVE_LOCATION",
              let body = content["body"] as? [String: Any],
              let latitude = number(body["latitude"]),
              let longitude = number(body["longitude"]),
              let observedAt = body["observedAt"] as? String else { return nil }
        let radio = (body["radio"] as? [String: Any]).map { value in
            LiveShareRadio(
                connectionType: string(value["connectionType"]),
                technology: string(value["technology"]),
                operatorName: string(value["operator"]),
                observedPlmn: string(value["observedPlmn"]),
                simPlmn: string(value["simPlmn"]),
                simOperatorName: string(value["simOperator"]),
                isRoaming: boolean(value["isRoaming"]),
                band: integer(value["band"]),
                rsrp: integer(value["rsrp"]),
                rsrq: integer(value["rsrq"]),
                snr: integer(value["snr"])
            )
        }
        return LiveSharePayload(
            radio: radio,
            location: .init(
                latitude: latitude,
                longitude: longitude,
                accuracy: number(body["accuracyMeters"]),
                altitude: number(body["altitudeMeters"]),
                speed: number(body["speedMetersPerSecond"]),
                heading: number(body["headingDegrees"])
            ),
            at: observedAt
        )
    }

    private static func string(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    private static func number(_ value: Any?) -> Double? {
        guard !(value is NSNull), let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard !(value is NSNull), let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

struct E2EEV2PortableExportSummary: Equatable, Sendable {
    let messageCount: Int64
    let mediaCount: Int64
    let plaintextMediaBytes: Int64
}

enum E2EEV2PortableExportResult: Equatable, Sendable {
    case success(E2EEV2PortableExportSummary)
    case blocked(reason: String)
    case failure(reason: String)
}

private struct E2EEV2PortableExportError: Error {
    let reason: String
}

struct E2EEV2PortableDestination {
    let write: (Data) throws -> Void
    let commit: () throws -> Void
    let abort: () throws -> Void
}

/// Destination iOS transactionnelle : l'archive claire en cours reste dans un
/// fichier voisin protégé et exclu des sauvegardes. La cible choisie n'est
/// remplacée qu'après synchronisation complète ; tout échec supprime le partiel.
final class E2EEV2PortableAtomicFileDestination {
    let partialURL: URL

    private let targetURL: URL
    private let fileManager: FileManager
    private var handle: FileHandle?
    private var committed = false
    private var securityScopeActive = false

    init(targetURL: URL, fileManager: FileManager = .default) throws {
        guard targetURL.isFileURL, !targetURL.lastPathComponent.isEmpty else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-destination")
        }
        self.targetURL = targetURL
        self.fileManager = fileManager
        securityScopeActive = targetURL.startAccessingSecurityScopedResource()
        let parent = targetURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if securityScopeActive { targetURL.stopAccessingSecurityScopedResource() }
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-destination-directory-unavailable")
        }
        partialURL = parent.appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: false
        )
        do {
            guard fileManager.createFile(
                atPath: partialURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            ) else {
                throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-partial-create-failed")
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutablePartial = partialURL
            try mutablePartial.setResourceValues(values)
            handle = try FileHandle(forWritingTo: partialURL)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            if securityScopeActive { targetURL.stopAccessingSecurityScopedResource() }
            securityScopeActive = false
            throw error
        }
    }

    func destination() -> E2EEV2PortableDestination {
        .init(
            write: { [self] data in try write(data) },
            commit: { [self] in try commit() },
            abort: { [self] in try abort() }
        )
    }

    private func write(_ data: Data) throws {
        guard !committed, let handle else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-destination-closed")
        }
        if !data.isEmpty { try handle.write(contentsOf: data) }
    }

    private func commit() throws {
        guard !committed, let handle else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-destination-closed")
        }
        do {
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            if fileManager.fileExists(atPath: targetURL.path) {
                _ = try fileManager.replaceItemAt(
                    targetURL,
                    withItemAt: partialURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: partialURL, to: targetURL)
            }
            committed = true
            closeSecurityScope()
        } catch {
            try? self.handle?.close()
            self.handle = nil
            try? fileManager.removeItem(at: partialURL)
            closeSecurityScope()
            throw error
        }
    }

    private func abort() throws {
        if committed { return }
        try? handle?.close()
        handle = nil
        var cleanupFailed = false
        if fileManager.fileExists(atPath: partialURL.path) {
            do { try fileManager.removeItem(at: partialURL) } catch { cleanupFailed = true }
        }
        closeSecurityScope()
        if cleanupFailed {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-partial-delete-failed")
        }
    }

    private func closeSecurityScope() {
        if securityScopeActive {
            targetURL.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
    }

    deinit {
        try? handle?.close()
        if !committed { try? fileManager.removeItem(at: partialURL) }
        closeSecurityScope()
    }
}

private final class E2EEV2PortableCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1
        }
        return value
    }

    private var value = UInt32.max

    func update(_ data: Data) {
        for byte in data {
            value = (value >> 8) ^ Self.table[Int((value ^ UInt32(byte)) & 0xff)]
        }
    }

    var digest: UInt32 { value ^ UInt32.max }
}

private final class E2EEV2PortableStreamingZIPWriter {
    private struct Entry {
        let name: Data
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let destination: E2EEV2PortableDestination
    private let modifiedAt: Date
    private var entries: [Entry] = []
    private var names = Set<String>()
    private var offset: UInt64 = 0
    private var finished = false

    init(destination: E2EEV2PortableDestination, modifiedAt: Date) throws {
        guard modifiedAt.timeIntervalSince1970.isFinite else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-date")
        }
        self.destination = destination
        self.modifiedAt = modifiedAt
    }

    func writeTextEntry(_ name: String, _ text: String) async throws {
        try await writeEntry(name) { write in try write(Data(text.utf8)) }
    }

    func writeEntry(
        _ name: String,
        producer: (@escaping (Data) throws -> Void) async throws -> Void
    ) async throws {
        guard !finished, names.insert(name).inserted else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-zip-entry-invalid")
        }
        let encodedName = try validName(name)
        let (dosDate, dosTime) = dosDateTime(modifiedAt)
        let localOffset = offset
        var header = Data()
        header.appendLittleEndian(UInt32(0x04034b50))
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(UInt16(0x0808))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(dosTime)
        header.appendLittleEndian(dosDate)
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt16(encodedName.count))
        header.appendLittleEndian(UInt16(0))
        header.append(encodedName)
        try writeRaw(header)

        let crc = E2EEV2PortableCRC32()
        var size: UInt64 = 0
        try await producer { data in
            guard !self.finished else {
                throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-zip-closed")
            }
            if data.isEmpty { return }
            let added = size.addingReportingOverflow(UInt64(data.count))
            guard !added.overflow, added.partialValue <= UInt64(UInt32.max) else {
                throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-entry-too-large")
            }
            size = added.partialValue
            crc.update(data)
            try self.writeRaw(data)
        }
        var descriptor = Data()
        descriptor.appendLittleEndian(UInt32(0x08074b50))
        descriptor.appendLittleEndian(crc.digest)
        descriptor.appendLittleEndian(UInt32(size))
        descriptor.appendLittleEndian(UInt32(size))
        try writeRaw(descriptor)
        entries.append(.init(
            name: encodedName,
            crc32: crc.digest,
            size: size,
            localHeaderOffset: localOffset,
            dosTime: dosTime,
            dosDate: dosDate
        ))
    }

    func finish() throws {
        guard !finished else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-zip-closed")
        }
        let centralOffset = offset
        for entry in entries {
            var extra = Data()
            extra.appendLittleEndian(UInt16(0x0001))
            extra.appendLittleEndian(UInt16(24))
            extra.appendLittleEndian(entry.size)
            extra.appendLittleEndian(entry.size)
            extra.appendLittleEndian(entry.localHeaderOffset)

            var header = Data()
            header.appendLittleEndian(UInt32(0x02014b50))
            header.appendLittleEndian(UInt16(45))
            header.appendLittleEndian(UInt16(45))
            header.appendLittleEndian(UInt16(0x0808))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(entry.dosTime)
            header.appendLittleEndian(entry.dosDate)
            header.appendLittleEndian(entry.crc32)
            header.appendLittleEndian(UInt32.max)
            header.appendLittleEndian(UInt32.max)
            header.appendLittleEndian(UInt16(entry.name.count))
            header.appendLittleEndian(UInt16(extra.count))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt32(0))
            header.appendLittleEndian(UInt32.max)
            header.append(entry.name)
            header.append(extra)
            try writeRaw(header)
        }
        let centralSize = offset - centralOffset
        let zip64EndOffset = offset
        var end = Data()
        end.appendLittleEndian(UInt32(0x06064b50))
        end.appendLittleEndian(UInt64(44))
        end.appendLittleEndian(UInt16(45))
        end.appendLittleEndian(UInt16(45))
        end.appendLittleEndian(UInt32(0))
        end.appendLittleEndian(UInt32(0))
        end.appendLittleEndian(UInt64(entries.count))
        end.appendLittleEndian(UInt64(entries.count))
        end.appendLittleEndian(centralSize)
        end.appendLittleEndian(centralOffset)
        try writeRaw(end)

        var locator = Data()
        locator.appendLittleEndian(UInt32(0x07064b50))
        locator.appendLittleEndian(UInt32(0))
        locator.appendLittleEndian(zip64EndOffset)
        locator.appendLittleEndian(UInt32(1))
        try writeRaw(locator)

        var legacyEnd = Data()
        legacyEnd.appendLittleEndian(UInt32(0x06054b50))
        legacyEnd.appendLittleEndian(UInt16(0))
        legacyEnd.appendLittleEndian(UInt16(0))
        legacyEnd.appendLittleEndian(UInt16(min(entries.count, Int(UInt16.max))))
        legacyEnd.appendLittleEndian(UInt16(min(entries.count, Int(UInt16.max))))
        legacyEnd.appendLittleEndian(UInt32.max)
        legacyEnd.appendLittleEndian(UInt32.max)
        legacyEnd.appendLittleEndian(UInt16(0))
        try writeRaw(legacyEnd)
        finished = true
    }

    private func writeRaw(_ data: Data) throws {
        let advanced = offset.addingReportingOverflow(UInt64(data.count))
        guard !advanced.overflow else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-archive-too-large")
        }
        try destination.write(data)
        offset = advanced.partialValue
    }

    private func validName(_ value: String) throws -> Data {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-entry-name")
        }
        let data = Data(value.utf8)
        guard data.count <= Int(UInt16.max) else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-entry-name-too-long")
        }
        return data
    }

    private func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(2107, max(1980, components.year ?? 1980))
        let month = min(12, max(1, components.month ?? 1))
        let day = min(31, max(1, components.day ?? 1))
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        let second = min(59, max(0, components.second ?? 0))
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        return (dosDate, dosTime)
    }
}

private struct E2EEV2PortablePrivateBlobManifest: Equatable {
    let crypto: E2EEV2BlobEncryptionManifest
    let fileName: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let durationMs: Int?
}

private final class E2EEV2PortableArchiveWriter {
    private let ownerScopeId: String
    private let generatedAt: Date
    private let zip: E2EEV2PortableStreamingZIPWriter
    private var writtenBlobPaths: [String: String] = [:]
    private var writtenBlobFingerprints: [String: String] = [:]
    private var previousOrderKey: String?
    private var messageCount: Int64 = 0
    private var mediaCount: Int64 = 0
    private var plaintextMediaBytes: Int64 = 0
    private var finished = false

    init(
        destination: E2EEV2PortableDestination,
        ownerScopeId: String,
        generatedAt: Date
    ) async throws {
        guard ownerScopeId.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}\z"#,
            options: .regularExpression
        ) != nil else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-owner-scope")
        }
        self.ownerScopeId = ownerScopeId
        self.generatedAt = generatedAt
        zip = try E2EEV2PortableStreamingZIPWriter(destination: destination, modifiedAt: generatedAt)
        try await zip.writeTextEntry("LISEZMOI.txt", Self.readme)
    }

    func append(
        _ delivered: E2EEV2DeliveredMessage,
        downloadRange: (E2EEV2DeliveredBlob, Int64, Int) async throws -> Data
    ) async throws {
        guard !finished else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-archive-closed")
        }
        let delivery = delivered.delivery
        guard E2EEV2PortableInventoryContract.validOpaqueId(delivery.id),
              E2EEV2PortableInventoryContract.validOpaqueId(delivery.senderId),
              E2EEV2PortableInventoryContract.validOpaqueId(delivery.incoming.conversationId),
              E2EEV2PortableInventoryContract.validOpaqueId(delivery.incoming.senderDeviceId),
              delivery.incoming.ownerScopeId == ownerScopeId,
              delivery.epochDelivery.conversationId == delivery.incoming.conversationId,
              delivery.epochDelivery.epochNumber == delivered.message.epochNumber else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-message-scope")
        }
        let orderKey = "\(delivery.createdAt)\n\(delivery.id)"
        guard previousOrderKey == nil || orderKey > previousOrderKey! else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-message-order-invalid")
        }
        previousOrderKey = orderKey

        let contentData = try JSONSerialization.data(
            withJSONObject: delivered.message.content,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let canonicalContent = E2EEV2ContentContract.parse(contentData) else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-content")
        }
        let manifests = try privateManifests(canonicalContent)
        let manifestIds = manifests.map(\.crypto.blobId)
        guard manifestIds == delivery.encryptedBlobs.map(\.blobId),
              manifestIds == delivered.message.encryptedBlobIds else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-blob-routing-mismatch")
        }

        var portableManifests: [[String: Any]] = []
        for (index, manifest) in manifests.enumerated() {
            let descriptor = delivery.encryptedBlobs[index]
            try verify(descriptor: descriptor, manifest: manifest.crypto)
            let fingerprint = fingerprint(manifest.crypto)
            if let existing = writtenBlobFingerprints[manifest.crypto.blobId], existing != fingerprint {
                throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-blob-manifest-conflict")
            }
            let archivePath: String
            if let existing = writtenBlobPaths[manifest.crypto.blobId] {
                archivePath = existing
            } else {
                archivePath = "media/\(manifest.crypto.blobId)/\(safeFileName(manifest))"
                var written: Int64 = -1
                try await zip.writeEntry(archivePath) { write in
                    written = try await self.decryptBlob(
                        descriptor: descriptor,
                        manifest: manifest.crypto,
                        downloadRange: downloadRange,
                        write: write
                    )
                }
                guard written == manifest.crypto.plaintextSize else {
                    throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-media-size-mismatch")
                }
                writtenBlobPaths[manifest.crypto.blobId] = archivePath
                writtenBlobFingerprints[manifest.crypto.blobId] = fingerprint
                mediaCount = try checkedAdd(mediaCount, 1)
                plaintextMediaBytes = try checkedAdd(
                    plaintextMediaBytes,
                    manifest.crypto.plaintextSize
                )
            }
            portableManifests.append([
                "blobId": manifest.crypto.blobId,
                "archivePath": archivePath,
                "fileName": archivePath.split(separator: "/").last.map(String.init) ?? "media.bin",
                "mimeType": manifest.mimeType ?? NSNull(),
                "plaintextSize": String(manifest.crypto.plaintextSize),
                "plaintextSha256": manifest.crypto.plaintextSha256,
                "width": manifest.width ?? NSNull(),
                "height": manifest.height ?? NSNull(),
                "durationMs": manifest.durationMs ?? NSNull(),
            ])
        }

        var portableContent = try deepCopy(canonicalContent)
        guard var body = portableContent["body"] as? [String: Any],
              let kind = portableContent["kind"] as? String else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-content")
        }
        if kind == "MEDIA" { body["attachments"] = portableManifests }
        if kind == "AUDIO" {
            guard portableManifests.count == 1 else {
                throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-audio-manifest")
            }
            body["attachment"] = portableManifests[0]
        }
        portableContent["body"] = body
        let exported: [String: Any] = [
            "id": delivery.id,
            "conversationId": delivery.incoming.conversationId,
            "senderId": delivery.senderId,
            "senderDeviceId": delivery.incoming.senderDeviceId,
            "createdAt": delivery.createdAt,
            "expiresAt": delivery.expiresAt ?? NSNull(),
            "epochNumber": delivered.message.epochNumber,
            "clientRequestId": delivered.message.clientRequestId,
            "ttlSeconds": delivered.message.ttlSeconds,
            "content": portableContent,
        ]
        let messageData = try JSONSerialization.data(
            withJSONObject: exported,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try await zip.writeEntry(
            "messages/\(delivery.incoming.conversationId)/\(delivery.id).json"
        ) { write in try write(messageData) }
        messageCount = try checkedAdd(messageCount, 1)
    }

    func finish() async throws -> E2EEV2PortableExportSummary {
        guard !finished else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-archive-closed")
        }
        let manifest: [String: Any] = [
            "schema": "signalquest.e2ee-portable-export",
            "version": 1,
            "generatedAt": Self.instant(generatedAt),
            "accountScope": ownerScopeId,
            "messageCount": messageCount,
            "mediaCount": mediaCount,
            "plaintextMediaBytes": String(plaintextMediaBytes),
            "containsPrivateKeys": false,
            "containsCiphertextRoutingSecrets": false,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try await zip.writeEntry("manifest.json") { write in try write(data) }
        try zip.finish()
        finished = true
        return .init(
            messageCount: messageCount,
            mediaCount: mediaCount,
            plaintextMediaBytes: plaintextMediaBytes
        )
    }

    private func decryptBlob(
        descriptor: E2EEV2DeliveredBlob,
        manifest: E2EEV2BlobEncryptionManifest,
        downloadRange: (E2EEV2DeliveredBlob, Int64, Int) async throws -> Data,
        write: (Data) throws -> Void
    ) async throws -> Int64 {
        try verify(descriptor: descriptor, manifest: manifest)
        guard var mediaKey = Self.decodeBase64(manifest.mediaKeyB64),
              mediaKey.count == E2EEV2BlobCrypto.mediaKeyBytes,
              var noncePrefix = Self.decodeBase64(manifest.noncePrefixB64),
              noncePrefix.count == E2EEV2BlobCrypto.noncePrefixBytes else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-media-key")
        }
        defer {
            mediaKey.resetBytes(in: 0..<mediaKey.count)
            noncePrefix.resetBytes(in: 0..<noncePrefix.count)
        }
        let chunkCount = max(
            1,
            Int((manifest.plaintextSize + Int64(E2EEV2BlobCrypto.cryptoChunkBytes) - 1)
                / Int64(E2EEV2BlobCrypto.cryptoChunkBytes))
        )
        var plaintextHasher = SHA256()
        var ciphertextHasher = SHA256()
        var ciphertextOffset: Int64 = 0
        var plaintextWritten: Int64 = 0
        for chunkIndex in 0..<chunkCount {
            let finalChunk = chunkIndex == chunkCount - 1
            let cleartextBytes = finalChunk
                ? Int(manifest.plaintextSize - Int64(chunkIndex * E2EEV2BlobCrypto.cryptoChunkBytes))
                : E2EEV2BlobCrypto.cryptoChunkBytes
            let requested = cleartextBytes + E2EEV2BlobCrypto.tagBytes
            var ciphertext = try await downloadRange(
                descriptor,
                ciphertextOffset,
                requested
            )
            guard ciphertext.count == requested else {
                ciphertext.resetBytes(in: 0..<ciphertext.count)
                throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-range-size")
            }
            ciphertextHasher.update(data: ciphertext)
            var cleartext = Data()
            do {
                cleartext = try E2EEV2BlobCrypto.decryptChunk(
                    ciphertext,
                    blobID: manifest.blobId,
                    mediaKey: mediaKey,
                    noncePrefix: noncePrefix,
                    chunkIndex: UInt32(chunkIndex),
                    finalChunk: finalChunk,
                    cleartextBytes: cleartextBytes
                )
                guard cleartext.count == cleartextBytes else {
                    throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-cleartext-size")
                }
                plaintextHasher.update(data: cleartext)
                try write(cleartext)
                plaintextWritten = try checkedAdd(plaintextWritten, Int64(cleartext.count))
            } catch {
                cleartext.resetBytes(in: 0..<cleartext.count)
                ciphertext.resetBytes(in: 0..<ciphertext.count)
                throw error
            }
            cleartext.resetBytes(in: 0..<cleartext.count)
            ciphertext.resetBytes(in: 0..<ciphertext.count)
            ciphertextOffset = try checkedAdd(ciphertextOffset, Int64(requested))
        }
        let plaintextHash = Data(plaintextHasher.finalize()).hexLowercase
        let ciphertextHash = Data(ciphertextHasher.finalize()).hexLowercase
        guard ciphertextOffset == manifest.ciphertextSize,
              plaintextWritten == manifest.plaintextSize,
              constantTimeEqual(plaintextHash, manifest.plaintextSha256),
              constantTimeEqual(ciphertextHash, manifest.ciphertextSha256) else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-media-digest")
        }
        return plaintextWritten
    }

    private func privateManifests(
        _ content: [String: Any]
    ) throws -> [E2EEV2PortablePrivateBlobManifest] {
        guard let kind = content["kind"] as? String,
              let body = content["body"] as? [String: Any] else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-content")
        }
        let values: [[String: Any]]
        if kind == "MEDIA" {
            values = body["attachments"] as? [[String: Any]] ?? []
        } else if kind == "AUDIO", let attachment = body["attachment"] as? [String: Any] {
            values = [attachment]
        } else {
            values = []
        }
        return try values.map { value in
            guard let blobId = value["blobId"] as? String,
                  let algorithm = value["algorithm"] as? String,
                  let mediaKey = value["mediaKeyB64"] as? String,
                  let noncePrefix = value["noncePrefixB64"] as? String,
                  let chunkSize = Self.integer(value["cryptoChunkSize"]),
                  let plaintextRaw = value["plaintextSize"] as? String,
                  let plaintextSize = Int64(plaintextRaw),
                  let ciphertextRaw = value["ciphertextSize"] as? String,
                  let ciphertextSize = Int64(ciphertextRaw),
                  let plaintextHash = value["plaintextSha256"] as? String,
                  let ciphertextHash = value["ciphertextSha256"] as? String else {
                throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-media-manifest")
            }
            return .init(
                crypto: .init(
                    blobId: blobId,
                    algorithm: algorithm,
                    mediaKeyB64: mediaKey,
                    noncePrefixB64: noncePrefix,
                    cryptoChunkSize: chunkSize,
                    plaintextSize: plaintextSize,
                    ciphertextSize: ciphertextSize,
                    plaintextSha256: plaintextHash,
                    ciphertextSha256: ciphertextHash
                ),
                fileName: Self.nullableString(value["fileName"]),
                mimeType: Self.nullableString(value["mimeType"]),
                width: Self.nullableInteger(value["width"]),
                height: Self.nullableInteger(value["height"]),
                durationMs: Self.nullableInteger(value["durationMs"])
            )
        }
    }

    private func verify(
        descriptor: E2EEV2DeliveredBlob,
        manifest: E2EEV2BlobEncryptionManifest
    ) throws {
        let chunkCount = max(
            1,
            (manifest.plaintextSize + Int64(E2EEV2BlobCrypto.cryptoChunkBytes) - 1)
                / Int64(E2EEV2BlobCrypto.cryptoChunkBytes)
        )
        guard E2EEV2PortableInventoryContract.validOpaqueId(manifest.blobId),
              manifest.algorithm == E2EEV2BlobCrypto.algorithm,
              manifest.cryptoChunkSize == E2EEV2BlobCrypto.cryptoChunkBytes,
              manifest.plaintextSize >= 0,
              manifest.plaintextSize <= E2EEV2BlobCrypto.maxPlaintextBytes,
              manifest.ciphertextSize == manifest.plaintextSize
                + chunkCount * Int64(E2EEV2BlobCrypto.tagBytes),
              manifest.plaintextSha256.range(
                of: #"^[a-f0-9]{64}\z"#,
                options: .regularExpression
              ) != nil,
              manifest.ciphertextSha256.range(
                of: #"^[a-f0-9]{64}\z"#,
                options: .regularExpression
              ) != nil,
              descriptor.blobId == manifest.blobId,
              descriptor.algorithm == manifest.algorithm,
              descriptor.ciphertextSha256 == manifest.ciphertextSha256,
              descriptor.ciphertextSize == manifest.ciphertextSize else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-blob-descriptor-mismatch")
        }
    }

    private func fingerprint(_ manifest: E2EEV2BlobEncryptionManifest) -> String {
        [
            manifest.algorithm,
            manifest.mediaKeyB64,
            manifest.noncePrefixB64,
            String(manifest.cryptoChunkSize),
            String(manifest.plaintextSize),
            String(manifest.ciphertextSize),
            manifest.plaintextSha256,
            manifest.ciphertextSha256,
        ].joined(separator: "\n")
    }

    private func safeFileName(_ manifest: E2EEV2PortablePrivateBlobManifest) -> String {
        let leaf = manifest.fileName?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(leaf.prefix(120).map { character in
            character.isLetter || character.isNumber || ".-_ ".contains(character) ? character : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: "_") }
        return cleaned.isEmpty ? "\(manifest.crypto.blobId).bin" : cleaned
    }

    private func deepCopy(_ value: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let copy = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-content")
        }
        return copy
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-counter-overflow")
        }
        return result.partialValue
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        return Data(base64Encoded: normalized)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func nullableInteger(_ value: Any?) -> Int? {
        value is NSNull ? nil : integer(value)
    }

    private static func nullableString(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    private static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static let readme = """
    SignalQuest — export portable E2EE v2

    Cette archive contient le contenu que cet appareil approuvé a pu vérifier et déchiffrer.
    Les clés privées, clés de média, nonces et secrets de routage chiffré en sont exclus.
    Les médias sont placés sous media/ et les messages JSON sous messages/.

    This archive contains content verified and decrypted by this approved device.
    Private keys, media keys, nonces and encrypted routing secrets are excluded.
    """
}

struct E2EEV2PortableExportCoordinatorDependencies {
    let currentOwnerScope: () -> String?
    let isApprovedDevice: () -> Bool
    let recipientDeviceId: String
    let makeDestination: () throws -> E2EEV2PortableDestination
    let fetchInventory: (String?) async throws -> Data
    let fetchMessage: (E2EEV2PortableInventoryItem) async throws -> E2EEV2DeliveredMessage
    let downloadRange: (E2EEV2DeliveredBlob, Int64, Int) async throws -> Data
}

enum E2EEV2PortableExportCoordinator {
    static func exportContractPreview(
        ownerScopeId: String,
        generatedAt: Date,
        dependencies: E2EEV2PortableExportCoordinatorDependencies
    ) async -> E2EEV2PortableExportResult {
        var destination: E2EEV2PortableDestination?
        var committed = false
        do {
            try requireScope(ownerScopeId, dependencies)
            guard E2EEV2PortableInventoryContract.validOpaqueId(dependencies.recipientDeviceId) else {
                throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-recipient-device")
            }
            var page = try inventoryPage(
                try await dependencies.fetchInventory(nil),
                recipientDeviceId: dependencies.recipientDeviceId
            )
            try requireScope(ownerScopeId, dependencies)
            let opened = try dependencies.makeDestination()
            destination = opened
            let writer = try await E2EEV2PortableArchiveWriter(
                destination: opened,
                ownerScopeId: ownerScopeId,
                generatedAt: generatedAt
            )
            var seenCursors = Set<String>()
            var previousOrderKey: String?
            while true {
                try requireScope(ownerScopeId, dependencies)
                for item in page.envelopes {
                    let orderKey = "\(item.createdAt)\n\(item.envelopeId)"
                    guard previousOrderKey == nil || orderKey > previousOrderKey! else {
                        throw E2EEV2PortableExportError(
                            reason: "e2ee-v2-portable-inventory-order-invalid"
                        )
                    }
                    previousOrderKey = orderKey
                    try requireScope(ownerScopeId, dependencies)
                    let delivered = try await dependencies.fetchMessage(item)
                    guard delivered.delivery.id == item.envelopeId,
                          delivered.delivery.incoming.conversationId == item.conversationId,
                          delivered.delivery.createdAt == item.createdAt,
                          delivered.delivery.expiresAt == item.expiresAt else {
                        throw E2EEV2PortableExportError(
                            reason: "invalid-or-untrusted-e2ee-v2-portable-message"
                        )
                    }
                    try await writer.append(delivered) { blob, offset, length in
                        try requireScope(ownerScopeId, dependencies)
                        return try await dependencies.downloadRange(blob, offset, length)
                    }
                }
                guard page.hasMore else { break }
                guard let cursor = page.nextCursor, seenCursors.insert(cursor).inserted else {
                    throw E2EEV2PortableExportError(reason: "e2ee-v2-portable-cursor-loop")
                }
                try requireScope(ownerScopeId, dependencies)
                page = try inventoryPage(
                    try await dependencies.fetchInventory(cursor),
                    recipientDeviceId: dependencies.recipientDeviceId
                )
            }
            try requireScope(ownerScopeId, dependencies)
            let summary = try await writer.finish()
            try requireScope(ownerScopeId, dependencies)
            try opened.commit()
            committed = true
            return .success(summary)
        } catch {
            if !committed, let destination {
                do { try destination.abort() } catch {
                    return .failure(reason: "e2ee-v2-portable-partial-delete-failed")
                }
            }
            if let portable = error as? E2EEV2PortableExportError {
                if [
                    "e2ee-v2-account-scope-mismatch",
                    "e2ee-v2-approved-device-required",
                ].contains(portable.reason) {
                    return .blocked(reason: portable.reason)
                }
                return .failure(reason: portable.reason)
            }
            if let transport = error as? E2EEV2TransportFailure {
                let reason = transport.message
                return [.authentication, .activationBlocked].contains(transport.kind)
                    ? .blocked(reason: reason)
                    : .failure(reason: reason)
            }
            if let delivery = error as? E2EEV2MessageDeliveryFailure {
                switch delivery {
                case .transport(let failure):
                    return [.authentication, .activationBlocked].contains(failure.kind)
                        ? .blocked(reason: failure.message)
                        : .failure(reason: failure.message)
                case .invalid(let reason): return .failure(reason: reason)
                }
            }
            return .failure(reason: "e2ee-v2-portable-export-failed")
        }
    }

    private static func requireScope(
        _ ownerScopeId: String,
        _ dependencies: E2EEV2PortableExportCoordinatorDependencies
    ) throws {
        guard ownerScopeId.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}\z"#,
            options: .regularExpression
        ) != nil else {
            throw E2EEV2PortableExportError(reason: "invalid-e2ee-v2-portable-owner-scope")
        }
        guard dependencies.currentOwnerScope() == ownerScopeId else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-account-scope-mismatch")
        }
        guard dependencies.isApprovedDevice() else {
            throw E2EEV2PortableExportError(reason: "e2ee-v2-approved-device-required")
        }
    }

    private static func inventoryPage(
        _ data: Data,
        recipientDeviceId: String
    ) throws -> E2EEV2PortableInventoryPage {
        guard let page = E2EEV2PortableInventoryContract.parse(
            data,
            expectedRecipientDeviceId: recipientDeviceId
        ) else {
            throw E2EEV2PortableExportError(
                reason: "invalid-or-untrusted-e2ee-v2-portable-inventory"
            )
        }
        return page
    }
}


private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    var hexLowercase: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Substring {
    var nonEmptyString: String? {
        isEmpty ? nil : String(self)
    }
}
