import Foundation
import CryptoKit
import CommonCrypto
import Security
import Combine
import os

private struct ModerationPublicKeyResponse: Decodable {
    let publicKeyJwk: String
}

enum E2EEError: Error, LocalizedError, Equatable {
    case locked
    case unsupported(String)
    case invalidKey
    case wrongPassword
    case decryptFailed
    case staleKey
    /// Écriture dans une conversation encore v1 : refusée sur l'appareil, comme le
    /// serveur la refuserait (409 E2EE_AUTO_REQUIRED). La conversation passe d'abord en auto.
    case autoEncryptionRequired

    var errorDescription: String? {
        switch self {
        case .autoEncryptionRequired:
            return String(localized: "Rien n’a été envoyé : cette conversation passe d’abord au nouveau chiffrement. Envoie un message depuis la conversation, puis réessaie.")
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
        case .staleKey:
            return String(localized: "La clé de cette conversation a changé. Elle sera mise à jour à la prochaine ouverture.")
        }
    }
}

protocol E2EEServicing: Sendable {
    func bootstrap() async throws -> E2EEBootstrapResponse
    func unlock(userId: String, password: String, bootstrapKey: E2EEBootstrapKey) async throws
    /// Re-partage la clé de conversation aux participants qui n'en ont pas encore
    /// (nouveau membre du groupe, clé créée après coup). Silencieux et idempotent —
    /// même comportement qu'Android `shareConversationKeyIfNeeded`.
    func shareConversationKeyIfNeeded(conversationId: String) async
    func isUnlocked() async -> Bool
    func isConversationUnlocked(conversationId: String) async -> Bool
    func decryptText(conversationId: String, message: MessageItem) async throws -> String
    /// Pièce jointe v1 chiffrée par le site (E2EE-AUTO §8) : AES-256-GCM par la clé de
    /// conversation, IV de 12 octets, sans AAD, étiquette en fin. `E2EEError.locked` si
    /// la clé n'est pas détenue, `decryptFailed` si elle l'est et que la pièce ne s'ouvre pas.
    func decryptLegacyAttachment(conversationId: String, iv: Data, ciphertext: Data) async throws -> Data
    func moderationWrappedConversationKey(conversationId: String) async throws -> String?
    /// Logout revokes access and clears RAM/legacy v1, but keeps owner-scoped v2 vaults.
    func lockLocalKeys() async
    func lockLocalKeys(expectedSession: LocalAccountSession?) async
    /// Explicit erasure only; never used for ordinary logout or an expired session.
    func wipeLocalKeys() async
    func eraseLocalVault(ownerScopeId: String) async
}

final class E2EEService: E2EEServicing, @unchecked Sendable {
    private static let legacyLockedKey = "SignalQuest.E2EE.LegacyCacheLocked.v1"
    private let api: APIClient
    private let tokenStore: TokenStore
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
        privacyLock: @escaping @Sendable () -> Void = {
            E2EEV2NotificationContextEvents.revoke()
            E2EEBiometric.clear()
        }
    ) {
        self.api = api
        self.tokenStore = tokenStore
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
        // Pièces jointes chiffrées en attente (sources, blobs, clés) et déchiffrées.
        try? await E2EEAutoMediaOutbox.shared.purge(ownerScopeId: ownerScopeId)
        E2EEAutoMediaCache.purge(ownerScopeId: ownerScopeId)
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

    func decryptLegacyAttachment(conversationId: String, iv: Data, ciphertext: Data) async throws -> Data {
        let key: SymmetricKey
        do { key = try await conversationKey(conversationId: conversationId) } catch { throw E2EEError.locked }
        guard iv.count == 12, ciphertext.count >= 16 else { throw E2EEError.decryptFailed }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext.prefix(ciphertext.count - 16), tag: ciphertext.suffix(16)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw E2EEError.decryptFailed
        }
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
              // Un JWK exporté par WebCrypto (site) porte aussi `ext` (booléen) et
              // `key_ops` (tableau) : seuls les entiers RSA sont lus.
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2EEError.invalidKey
        }
        let fields = ["n", "e", "d", "p", "q", "dp", "dq", "qi"]
        let integers = try fields.map { key -> Data in
            guard let raw = object[key] as? String, let decoded = Data(base64URLEncoded: raw) else { throw E2EEError.invalidKey }
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

private enum ASN1 {
    static func sequence(_ parts: [Data]) -> Data {
        wrap(tag: 0x30, body: parts.reduce(Data(), +))
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
    /// N'en crée jamais : seul l'enregistrement de l'appareil, demandé par
    /// l'utilisateur, crée l'identité.
    func signWithDeviceId(canonicalRequest: Data, ownerNamespace: String) throws -> (deviceId: String, signature: Data) {
        let signing = try signingKey(ownerNamespace: ownerNamespace, createsIdentity: false)
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

    /// Versions des clés d'accord dont l'appareil garde la clé privée : la courante,
    /// la préparée (version suivante, que le serveur peut déjà connaître) et les anciennes
    /// (E2EE-AUTO §5.4 : une rotation a pu passer entre la demande et l'envoi).
    func heldAgreementKeyVersions(ownerNamespace: String) throws -> [Int] {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        let current = record.descriptor.keyVersion
        return [current] + (record.pendingIdentityKey == nil ? [] : [current + 1])
            + (record.retiredIdentityKeys ?? []).map(\.keyVersion)
    }

    /// Ouvre une enveloppe d'historique (E2EE-AUTO §5.4) déjà acceptée par
    /// `E2EEAutoHistory.check`, avec la clé d'accord de sa version, sans l'exporter.
    func openHistoryWrap(_ wrap: E2EEAutoHistory.Wrap, userId: String, ownerNamespace: String) throws -> Data {
        let record = try requiredRecord(ownerNamespace: ownerNamespace)
        guard record.descriptor.deviceId == wrap.recipient else { throw E2EEV2DeviceIdentityError.invalidRecord }
        let raw: String?
        switch wrap.keyVersion {
        case record.descriptor.keyVersion: raw = record.identityPrivateRawB64
        case record.descriptor.keyVersion + 1: raw = record.pendingIdentityKey?.privateRawB64
        default: raw = record.retiredIdentityKeys?.last(where: { $0.keyVersion == wrap.keyVersion })?.privateRawB64
        }
        guard let raw else { throw E2EEV2DeviceIdentityError.invalidRecord }
        return try E2EEAutoHistory.open(
            wrap, userId: userId, agreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: decoded(raw))
        )
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
    /// Raison d'un `403 E2EE_DEVICE_REVOKED` (E2EE-AUTO §4.3).
    let reason: String?
    /// En-tête `Retry-After` en secondes (E2EE-AUTO §4 : journal fermé).
    let retryAfterSeconds: Int?

    init(
        kind: E2EEV2TransportFailureKind,
        statusCode: Int? = nil,
        code: String? = nil,
        message: String,
        details: [String: JSONValue]? = nil,
        reason: String? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.details = details
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// `details.serverTimeMs` d'un `403 E2EE_REQUEST_TIMESTAMP_INVALID` (E2EE-AUTO §4).
    var serverTimeMs: Int64? {
        guard code == "E2EE_REQUEST_TIMESTAMP_INVALID", case .number(let value)? = details?["serverTimeMs"],
              value.isFinite, value > 0, value < Double(E2EEV2Canonical.maxSafeInteger) else { return nil }
        return Int64(value)
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
                // DM-REQ-1 : création et envoi lisent le bloc `request` du reçu (E2EEV2MessageRequestBlock).
                ClientProtocolContract.messageRequestsCapability,
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
        // DM-REQ-1 : le plafond quotidien de demandes est une décision, pas une panne : jamais rejoué seul.
        if statusCode == 429, code == MessageRequestLimitError.code { return .permanent }
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

    /// Lecture par session, avec la date de l'en-tête `Date` de la réponse :
    /// l'écart d'horloge du journal auto (E2EE-AUTO §7.1) se mesure dessus.
    func getSessionJSONWithServerDate(
        path: String,
        query: [URLQueryItem] = [],
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet
    ) async -> (result: E2EEV2TransportResult<Data>, serverDate: Date?) {
        var serverDate: Date?
        let result = await execute(
            path: path, query: query, method: .get, body: nil, contentType: nil,
            expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: capabilitySet, signs: false,
            onResponse: { serverDate = Self.httpDate($0.value(forHTTPHeaderField: "Date")) }
        )
        return (result, serverDate)
    }

    /// Date HTTP (RFC 9110, IMF-fixdate), sinon nil.
    static func httpDate(_ header: String?) -> Date? {
        guard let header else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }

    /// `clockOffsetMs` : écart à ajouter à l'horloge locale pour l'horodatage
    /// signé, appris d'un `403 E2EE_REQUEST_TIMESTAMP_INVALID` (E2EE-AUTO §4).
    func postJSON(
        path: String,
        body: Data,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet,
        clockOffsetMs: Int64 = 0
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
            clockOffsetMs: clockOffsetMs
        )
    }

    func putJSON(
        path: String,
        body: Data,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet,
        clockOffsetMs: Int64 = 0
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
            capabilitySet: capabilitySet,
            clockOffsetMs: clockOffsetMs
        )
    }

    /// `DELETE` signé au corps vide (E2EE-AUTO §5.3 : annuler une demande d'historique).
    func deleteJSON(
        path: String,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet,
        clockOffsetMs: Int64 = 0
    ) async -> E2EEV2TransportResult<Data> {
        await execute(
            path: path,
            method: .delete,
            body: nil,
            contentType: nil,
            expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: capabilitySet,
            clockOffsetMs: clockOffsetMs
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

    /// Plage d'un blob chiffré (E2EE-AUTO §7.4, lecture) : `GET` signé, octets
    /// bruts de la longueur demandée, taille totale annoncée par
    /// `x-sq-e2ee-blob-size`. Tout écart est refusé avant d'aller plus loin.
    func getEncryptedBlobBytes(
        path: String,
        offset: Int64,
        length: Int,
        expectedTotalSize: Int64,
        expectedOwnerScopeId: String
    ) async -> E2EEV2TransportResult<Data> {
        guard offset >= 0, (1...Int(E2EEAutoBlobTransport.maxRangeBytes)).contains(length),
              offset + Int64(length) <= expectedTotalSize else {
            return localFailure("invalid-e2ee-blob-range-request")
        }
        var headersMatch = false
        let result = await execute(
            path: path,
            query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "length", value: String(length))],
            method: .get, body: nil, contentType: nil, expectedOwnerScopeId: expectedOwnerScopeId,
            capabilitySet: .media, maxSuccessBytes: length,
            onResponse: { response in
                headersMatch = response.value(forHTTPHeaderField: "x-sq-e2ee-blob-size") == String(expectedTotalSize)
                    && response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/octet-stream") == true
            }
        )
        if case .success(var data, let status, _) = result, status != 200 || !headersMatch || data.count != length {
            data.resetBytes(in: 0..<data.count)
            return localFailure("invalid-e2ee-blob-range-response")
        }
        return result
    }

    private func execute(
        path: String,
        query: [URLQueryItem] = [],
        method: HTTPMethod,
        body: Data?,
        contentType: String?,
        expectedOwnerScopeId: String,
        capabilitySet: E2EEV2RequestCapabilitySet,
        signs: Bool = true,
        clockOffsetMs: Int64 = 0,
        maxSuccessBytes: Int = E2EEV2APITransport.maxJSONResponseBytes,
        onResponse: ((HTTPURLResponse) -> Void)? = nil
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
            } else {
                proof = try E2EEV2SignedRequest.signBodyHash(
                    method: method.rawValue,
                    path: signedPath,
                    bodySHA256Base64URL: bodyHash,
                    ownerNamespace: ownerNamespace,
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1_000) + clockOffsetMs,
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
            onResponse?(response)
            return responseResult(data: data, response: response, maxSuccessBytes: maxSuccessBytes)
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
        response: HTTPURLResponse,
        maxSuccessBytes: Int = E2EEV2APITransport.maxJSONResponseBytes
    ) -> E2EEV2TransportResult<Data> {
        if (200..<300).contains(response.statusCode) {
            guard data.count <= maxSuccessBytes else {
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
                details: decoded?.details,
                reason: decoded?.reason,
                retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
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

/// Appels chiffrés : ouverts quand le serveur publie la capacité des appels
/// vérifiés, médias en `wss` seulement. En Debug, la recette strictement
/// locale les ouvre aussi, sans rien ouvrir d'autre.
enum E2EEV2CallRuntimeGate {
    static func allowsControlPlane(
        config: AppConfig = .current,
        qaArgumentEnabled: Bool = AppEnvironment.runsE2EEV2CallQA,
        serverOpen: Bool = E2EEV2ServerGate.callsOpen
    ) -> Bool {
        #if DEBUG
        if qaArgumentEnabled {
            guard config.environment != .production else { return false }
            return isStrictLoopbackEndpoint(config.apiBaseURL, schemes: ["http", "https"])
        }
        #endif
        return serverOpen
    }

    static func allowsMedia(
        liveKitURL: URL,
        config: AppConfig = .current,
        qaArgumentEnabled: Bool = AppEnvironment.runsE2EEV2CallQA,
        serverOpen: Bool = E2EEV2ServerGate.callsOpen
    ) -> Bool {
        #if DEBUG
        if qaArgumentEnabled {
            return allowsControlPlane(config: config, qaArgumentEnabled: true)
                && isStrictLoopbackEndpoint(liveKitURL, schemes: ["ws", "wss"])
        }
        #endif
        return serverOpen && liveKitURL.scheme?.lowercased() == "wss"
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

    /// Lien universel du QR (D.13, v0.4.34) : `https://<hôte SignalQuest>/e2ee/approve#<charge>`,
    /// la charge étant la chaîne v3 en base64url sans bourrage. Rend la chaîne
    /// v3 ; une chaîne v3 nue est rendue telle quelle. Rien d'autre n'est lu.
    static func rawQRPayload(fromScanned scanned: String, appHosts: Set<String> = E2EEV2DeviceApprovalContract.appHosts) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("SQE2EE2|") { return trimmed }
        guard let components = URLComponents(string: trimmed), components.scheme == "https",
              let host = components.host?.lowercased(), appHosts.contains(host),
              components.path == "/e2ee/approve", components.query == nil,
              let fragment = components.fragment, !fragment.isEmpty, fragment.count <= 2_048,
              fragment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = fragment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let raw = String(data: data, encoding: .utf8),
              raw.hasPrefix("SQE2EE2|") else { return nil }
        return raw
    }

    /// Hôtes qui portent le lien universel : la production et l'hôte web de ce build.
    static var appHosts: Set<String> {
        var hosts: Set<String> = ["signalquest.fr", "www.signalquest.fr"]
        if let host = AppConfig.current.appBaseURL.host?.lowercased() { hosts.insert(host) }
        return hosts
    }

    static func fingerprint(of device: E2EEV2DeviceDescriptor) -> String? {
        guard let identity = Data(base64Encoded: device.publicIdentityKeyB64),
              let signing = Data(base64Encoded: device.publicSigningKeyB64) else { return nil }
        return E2EEV2Canonical.deviceFingerprint(identityKeyX963: identity, signingKeyX963: signing)
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

    static func validOpaqueId(_ value: String) -> Bool { matches(value, opaquePattern) }

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
            // Sans la clé du compte, l'appareil attend son approbation : le
            // serveur refuserait le document (403 E2EE_DEVICE_NOT_APPROVED) à
            // chaque lancement. Il part dès l'approbation (premier appareil, QR).
            guard try accountIdentityStore.load(ownerNamespace: namespace) != nil,
                  try !accountIdentityStore.hasPendingBootstrap(ownerNamespace: namespace) else { return .success(false) }
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
            envelopeVersions: E2EEV2CapabilitiesPublicationStore.envelopeVersions, payloadVersions: ["2"],
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

    private func ownerScope() -> String? {
        LocalAccountScope.currentUserId == nil ? nil : LocalAccountScope.currentOwnerScopeId
    }

    private static func userId(_ ownerScopeId: String) -> String? {
        guard ownerScopeId.hasPrefix("user:") else { return nil }
        let userId = String(ownerScopeId.dropFirst(5))
        return E2EEV2Canonical.isOpaque(userId) ? userId : nil
    }

    /// Une erreur réseau garde sa forme serveur ; un compte refusé ou illisible
    /// devient un état local.
    private func trustFailure<Value: Sendable>(_ error: Error, fallback: String) -> E2EEV2DeviceLifecycleResult<Value> {
        switch error {
        case let failure as E2EEV2TransportFailure: return .failed(failure)
        case is E2EEV2TrustDirectory.IdentityNotFound: return localFailure("e2ee-account-identity-unavailable")
        case is E2EEV2IdentityVerification.Failure:
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
/// Provenance d'une clé d'époque rangée. Une clé restaurée depuis la
/// sauvegarde de récupération (§2.8) ne remplace jamais une clé reçue par la
/// synchro vérifiée ; une clé vérifiée, elle, remplace toujours une clé
/// restaurée au même numéro.
enum E2EEV2EpochKeyOrigin: String, Sendable {
    case verified
    case restored
}

final class E2EEV2EpochKeyStore: @unchecked Sendable {
    private struct Record: Codable {
        let version: Int
        let conversationId: String
        let epochId: String
        let epochNumber: Int
        let keyCommitmentB64: String
        let epochKeyB64: String
        let storedAtMs: Int64
        /// Absent des enregistrements antérieurs et des clés vérifiées.
        var origin: String? = nil
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
    private static let restoredCounter = OSAllocatedUnfairLock(initialState: 0)
    /// Change à chaque clé restaurée rangée : une confirmation en attente se retente.
    static var restoredGeneration: Int { restoredCounter.withLock { $0 } }
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
        expectedSession: LocalAccountSession? = nil,
        origin: E2EEV2EpochKeyOrigin = .verified
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
        var replacesCurrent = false
        if let raw = try tokenStore.string(for: currentKey) {
            guard let parsed = parse(raw), parsed.conversationId == recordInput.conversationId else {
                return false
            }
            current = parsed
            if parsed.epochNumber == recordInput.epochNumber,
               !matches(parsed, recordInput: recordInput, epochKey: epochKey) {
                guard origin == .verified, isRestored(raw) else { return false }
                replacesCurrent = true
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
            guard let historical = parse(raw), historical.conversationId == recordInput.conversationId else {
                return false
            }
            if matches(historical, recordInput: recordInput, epochKey: epochKey) {
                // Déjà rangée : une restauration ne rétrograde jamais une clé vérifiée.
                if origin == .restored { return true }
            } else if origin == .restored || !isRestored(raw) {
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
            storedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            origin: origin == .restored ? origin.rawValue : nil
        )
        let encoded = try JSONEncoder().encode(record)
        guard let value = String(data: encoded, encoding: .utf8) else { return false }
        try publish(value, key: historicalKey, expectedSession: expectedSession)
        if origin == .restored { Self.restoredCounter.withLock { $0 += 1 } }
        if replacesCurrent {
            try publish(value, key: currentKey, expectedSession: expectedSession)
        } else if origin == .restored {
            // Une clé restaurée ne devient jamais l'époque courante : elle sert à
            // relire l'historique, pas à envoyer ni à appeler (§2.8).
        } else if current == nil || recordInput.epochNumber > current!.epochNumber {
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

    /// Par défaut (lecteurs, §2.8), une clé restaurée depuis la sauvegarde ne
    /// sert qu'une fois confirmée par l'engagement du manifeste signé de son
    /// époque, ou remplacée par la clé vérifiée. `includeRestored: true` est
    /// réservé à la restauration et à la confirmation.
    func loadEpoch(
        conversationId: String,
        epochNumber: Int,
        ownerNamespace: String,
        includeRestored: Bool = false
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
            if !includeRestored, isRestored(raw) { return nil }
            guard let stored = parse(raw),
                  stored.conversationId == conversationId,
                  stored.epochNumber == epochNumber else { return nil }
            return stored
        }

        // Compatibility with the pre-history format: the old current record
        // remains readable until a subsequent put indexes it.
        let currentKey = storageKey(ownerNamespace: ownerNamespace, conversationId: conversationId)
        guard let raw = try tokenStore.string(for: currentKey),
              includeRestored || !isRestored(raw),
              let current = parse(raw),
              current.conversationId == conversationId,
              current.epochNumber == epochNumber else { return nil }
        return current
    }

    /// Époques dont la clé restaurée attend sa confirmation (§2.8).
    func restoredEpochNumbers(conversationId: String, ownerNamespace: String) throws -> [Int] {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        lock.lock()
        defer { lock.unlock() }
        // Coffre verrouillé : l'erreur remonte, rien n'est tenu pour confirmé.
        return try loadIndexLocked(ownerNamespace: ownerNamespace, conversationId: conversationId).filter { epochNumber in
            let key = historyStorageKey(ownerNamespace: ownerNamespace, conversationId: conversationId, epochNumber: epochNumber)
            return try tokenStore.string(for: key).map(isRestored) ?? false
        }
    }

    /// Clé restaurée face à l'engagement du manifeste signé de son époque
    /// (§2.8) : le même la rend vérifiée, un autre l'efface. Une clé vérifiée
    /// n'est jamais touchée. Rend `true` si la clé est confirmée.
    @discardableResult
    func settleRestored(
        conversationId: String,
        epochNumber: Int,
        keyCommitmentB64: String,
        ownerNamespace: String,
        expectedSession: LocalAccountSession? = nil
    ) throws -> Bool {
        guard allowsOwner(ownerNamespace) else { throw E2EEV2DeviceIdentityError.unauthenticated }
        guard expectedSession == nil || (expectedSession?.isCurrent == true && expectedSession?.ownerNamespace == ownerNamespace) else {
            throw CancellationError()
        }
        lock.lock()
        defer { lock.unlock() }
        let key = historyStorageKey(ownerNamespace: ownerNamespace, conversationId: conversationId, epochNumber: epochNumber)
        guard let raw = try tokenStore.string(for: key), isRestored(raw) else { return false }
        if let stored = parse(raw), stored.conversationId == conversationId, stored.epochNumber == epochNumber,
           stored.keyCommitmentB64 == keyCommitmentB64,
           let data = raw.data(using: .utf8), var record = try? JSONDecoder().decode(Record.self, from: data) {
            record.origin = nil
            let encoded = try JSONEncoder().encode(record)
            guard let value = String(data: encoded, encoding: .utf8) else { return false }
            try publish(value, key: key, expectedSession: expectedSession)
            return true
        }
        try erase(key, expectedSession: expectedSession)
        var index = try loadIndexLocked(ownerNamespace: ownerNamespace, conversationId: conversationId)
        index.removeAll { $0 == epochNumber }
        try writeIndexLocked(index, ownerNamespace: ownerNamespace, conversationId: conversationId, expectedSession: expectedSession)
        return false
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

    private func isRestored(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return record.origin == E2EEV2EpochKeyOrigin.restored.rawValue
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
    /// Le second argument vaut vrai quand le relevé du serveur liste une exigence
    /// ouverte pour cette conversation : elle suffit à tourner (E2EE-COMPROMISED-1 §6).
    let rotate: @Sendable (String, Bool) async -> E2EEV2EpochRotationResult
    var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
}

actor E2EEV2RotationDrain {
    private var running = false
    /// Exigence servie refusée de façon définitive (4xx : membre manquant, identité
    /// refusée…) : la même révision n'est plus forcée, seule une révision plus grande
    /// le sera (E2EE-COMPROMISED-1 §6). Gardée le temps du processus.
    private var refusedRevisions: [String: Int] = [:]

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
        // Le serveur ne clôt une exigence que par une nouvelle époque (§6) : une
        // conversation qu'il liste tourne même sans écart vu d'ici.
        var required: [String: Int] = [:]
        switch discovered {
        case .failure(let failure): return try backlog.failed(session, kind: failure.kind)
        case .success(let values):
            try backlog.merge(session, conversations: values.map(\.conversationId), scannedRevision: initial.revision)
            required = Dictionary(values.map { ($0.conversationId, $0.revision) }, uniquingKeysWith: max)
        }
        let tickets = try backlog.snapshot(session).pending.sorted { $0.key < $1.key }.prefix(limit)
        var failure: E2EEV2TransportFailureKind?
        for (id, ticket) in tickets {
            guard d.isCurrent(), !Task.isCancelled else { throw CancellationError() }
            let revision = required[id]
            var forced = false
            if let revision { forced = refusedRevisions[id].map { revision > $0 } ?? true }
            let result = await d.rotate(id, forced)
            if forced, let revision {
                switch result {
                case .failure(let error) where error.kind == .permanent || error.kind == .localState:
                    refusedRevisions[id] = revision
                case .rotated: refusedRevisions[id] = nil
                default: break
                }
            }
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
                // Sans identité d'appareil ici, rien à renouveler : aucune requête
                // signée, qui ne doit jamais en créer une en passant.
                if messaging.lacksV2Readiness(current) { self.task = nil; return }
                self.state = existing
                self.state.phase = messaging.writesEnabled ? .running : .waitingAuthorization
                try await drain.request(session: current, backlog: backlog, resetRetry: manualRetry)
                // Ses propres appareils ont pu changer (approbation, révocation) : relus.
                await messaging.invalidateDevices([String(current.ownerScopeId.dropFirst("user:".count))])
                repeat {
                    let retry = try await drain.run(session: current, backlog: backlog, dependencies: .init(
                        isCurrent: { current.isCurrent }, activationEnabled: { messaging.writesEnabled },
                        pending: { await requirements.pending(expectedOwnerScopeId: current.ownerScopeId) },
                        rotate: { await messaging.rotate(conversationId: $0, required: $1) }
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
            // `isGroup` est servi en champ additif depuis le 09/11 (8fe65a067) : lu
            // s'il est là et booléen, jamais exigé. Sans lui, tout le relevé était
            // refusé et aucune exigence ne faisait tourner.
            var keys = Set(value.keys)
            if let isGroup = value["isGroup"] {
                guard let flag = isGroup as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
                keys.remove("isGroup")
            }
            guard keys == [
                "conversationId",
                "reason",
                "revision",
                "triggeredAt",
                "currentEpochNumber",
                "currentEpochStatus",
            ],
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
        guard E2EEV2ServerGate.autoActive else {
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

enum E2EEV2HistoryMigrationContract {
    static let version = 1
    static let maxClearBytes = 80 * 1_024

    private static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    private static let hashPattern = #"^[a-f0-9]{64}\z"#
    private static let kinds: Set<String> = [
        "TEXT", "ATTACHMENT", "SPEEDTEST", "LINK", "SYSTEM", "LOCATION",
    ]

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

    private static func validate(_ source: E2EEV2LegacyMessageSource) throws {
        guard source.version == version,
              validOpaque(source.conversationId),
              validOpaque(source.messageId),
              validOpaque(source.senderId),
              kinds.contains(source.kind),
              // Longueurs en unités UTF-16, comme `length` côté serveur.
              source.content.utf16.count <= 256 * 1_024,
              source.metadata.map({ $0.utf16.count <= 256 * 1_024 }) ?? true,
              isDate(source.createdAt),
              source.editedAt.map(isDate) ?? true,
              source.replyToId.map(validOpaque) ?? true,
              source.expiresAt.map(isDate) ?? true else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
    }

    /// Date ISO 8601 de 20 à 40 caractères, comme `isIsoDate` du serveur
    /// (E2EE-AUTO §8, cas `sourceInvalid` de `history-import-v1`).
    private static func isDate(_ value: String) -> Bool { date(value) != nil }

    static func date(_ value: String) -> Date? {
        guard (20...40).contains(value.utf16.count) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// Pièces jointes que la source v1 décrit dans ses métadonnées riches.
    static func attachmentCount(_ source: E2EEV2LegacyMessageSource) -> Int {
        guard let metadata = source.metadata?.data(using: .utf8),
              let binding = try? JSONDecoder().decode(RichMetadataAttachmentBinding.self, from: metadata),
              binding.version == version else { return 0 }
        return binding.attachments.count
    }

    private struct RichMetadataAttachmentBinding: Decodable {
        let version: Int
        let attachments: [E2EEV2LegacyAttachmentSource]
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

// MARK: - E2EE v2 portable export (preview, fail-closed)

enum E2EEV2MessageDeliveryFailure: Error, Equatable {
    case transport(E2EEV2TransportFailure)
    case invalid(String)
}


// MARK: - E2EE v2 Live Share transport (dormant)

/// E2EE-AUTO §7.6 (révision 18) : sous une époque marquée, une position part en
/// enveloppe v3 `live_share`, sans personne à notifier. Le clair reste le contenu
/// v1 LIVE_LOCATION ; le compteur est celui de la session sur cet appareil, à part
/// des messages, et ne repart pas après une rotation.
enum E2EEV2LiveShareEnvelopeV3 {
    static func context(
        conversationId: String,
        epochNumber: Int,
        senderDeviceId: String,
        clientRequestId: String,
        counter: Int64,
        ttlSeconds: Int
    ) -> E2EEV2MessageContextV2 {
        .init(
            conversationId: conversationId, epochNumber: epochNumber, senderDeviceId: senderDeviceId,
            clientRequestId: clientRequestId, counter: counter, ttlSeconds: ttlSeconds, encryptedBlobIds: [],
            envelopeVersion: E2EEV2MessageCryptoV2.annotationEnvelopeVersion, delivery: .liveShare, notifyUserId: ""
        )
    }

    /// `payload` : le contenu v1 déjà encodé, tel qu'il sera chiffré.
    static func compose(
        payload: Data,
        conversationId: String,
        clientRequestId: String,
        counter: Int64,
        ttlSeconds: Int,
        epoch: E2EEV2StoredEpochKey,
        device: E2EEV2DeviceDescriptor,
        fk: Data,
        nonce: Data,
        sign: (Data) throws -> Data
    ) throws -> E2EEV2SignedMessageEnvelopeV2 {
        guard let content = E2EEV2ContentContract.parse(payload),
              content["kind"] as? String == "LIVE_LOCATION",
              epoch.conversationId == conversationId,
              try E2EEV2EpochCrypto.keyCommitment(epoch.epochKey) == epoch.keyCommitmentB64,
              let publicKeyData = Data(base64Encoded: device.publicSigningKeyB64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw E2EEV2MessageV2Error.invalidContext
        }
        let context = context(
            conversationId: conversationId, epochNumber: epoch.epochNumber, senderDeviceId: device.deviceId,
            clientRequestId: clientRequestId, counter: counter, ttlSeconds: ttlSeconds
        )
        let envelope = try E2EEV2MessageCryptoV2.encrypt(
            payload: payload, fk: fk, epochKey: epoch.epochKey, nonce: nonce, context: context
        )
        var canonical = try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope)
        defer { canonical.resetBytes(in: 0..<canonical.count) }
        let signatureB64 = try sign(canonical).base64EncodedString()
        try E2EEV2MessageCryptoV2.verifySignature(
            context: context, envelope: envelope, signatureDerB64: signatureB64, senderSigningKey: publicKey
        )
        return .init(envelope: envelope, senderSignatureB64: signatureB64)
    }

    /// Lecture : signature de l'appareil émetteur, puis déchiffrement et
    /// `frankTag`, puis le contenu v1 LIVE_LOCATION.
    static func open(
        _ signed: E2EEV2SignedMessageEnvelopeV2,
        conversationId: String,
        senderDeviceId: String,
        senderSigningKey: P256.Signing.PublicKey,
        epochKey: Data
    ) throws -> [String: Any] {
        let context = signed.context(conversationId: conversationId, senderDeviceId: senderDeviceId)
        guard context.envelopeVersion == E2EEV2MessageCryptoV2.annotationEnvelopeVersion,
              context.delivery == .liveShare, context.notifyUserId.isEmpty,
              context.encryptedBlobIds.isEmpty else {
            throw E2EEV2MessageV2Error.invalidEnvelope
        }
        try E2EEV2MessageCryptoV2.verifySignature(
            context: context, envelope: signed.envelope,
            signatureDerB64: signed.senderSignatureB64, senderSigningKey: senderSigningKey
        )
        var (fk, payload) = try E2EEV2MessageCryptoV2.openFranked(
            envelope: signed.envelope, epochKey: epochKey, context: context
        )
        defer {
            fk.resetBytes(in: 0..<fk.count)
            payload.resetBytes(in: 0..<payload.count)
        }
        guard let content = E2EEV2ContentContract.parse(payload),
              content["kind"] as? String == "LIVE_LOCATION" else {
            throw E2EEV2MessageV2Error.invalidEnvelope
        }
        return content
    }
}

/// Ce qui part sur la route du partage : v1 sous une époque non marquée, v3
/// `live_share` sous une époque marquée (§7.6).
enum E2EEV2LiveSharePreparedEnvelope: Equatable, Sendable {
    case v1(E2EEV2SignedMessageEnvelope)
    case v3(E2EEV2SignedMessageEnvelopeV2)

    var clientRequestId: String {
        switch self {
        case .v1(let envelope): envelope.clientRequestId
        case .v3(let envelope): envelope.envelope.clientRequestId
        }
    }
}

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
    /// Une enveloppe v1, ou (`envelopeV3`) le corps JCS d'une enveloppe v3.
    let envelope: E2EEV2SignedMessageEnvelope?
    let envelopeV3: Data?

    init(clientRequestId: String, sendDeadlineAtMs: Int64, envelope: E2EEV2SignedMessageEnvelope) {
        self.clientRequestId = clientRequestId
        self.sendDeadlineAtMs = sendDeadlineAtMs
        self.envelope = envelope
        envelopeV3 = nil
    }

    init(clientRequestId: String, sendDeadlineAtMs: Int64, prepared: E2EEV2LiveSharePreparedEnvelope) {
        self.clientRequestId = clientRequestId
        self.sendDeadlineAtMs = sendDeadlineAtMs
        switch prepared {
        case .v1(let value): (envelope, envelopeV3) = (value, nil)
        case .v3(let value): (envelope, envelopeV3) = (nil, value.encoded)
        }
    }

    var prepared: E2EEV2LiveSharePreparedEnvelope? {
        switch (envelope, envelopeV3) {
        case (let value?, nil): .v1(value)
        case (nil, let data?): E2EEV2SignedMessageEnvelopeV2.parse(data, allowLiveShare: true).map { .v3($0) }
        default: nil
        }
    }
}

private struct E2EEV2LiveShareStateRecord: Codable {
    let version: Int
    let ownerScopeId: String
    let conversationId: String
    let sessionId: String
    var nextSequence: Int
    /// Compteur v3 suivant (§7.6) ; absent d'un état antérieur, il vaut 1.
    var nextCounter: Int64?
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

    /// Compteur v3 de la session sur cet appareil : jamais réutilisé, les trous
    /// sont permis (§7.6). L'état existe déjà : `claimSequence` le crée.
    func claimCounter(
        ownerScopeId: String,
        conversationId: String,
        sessionId: String,
        nowMs: Int64
    ) throws -> Int64 {
        try lock.withLock {
            guard var record = try load(ownerScopeId: ownerScopeId, sessionId: sessionId),
                  record.ownerScopeId == ownerScopeId,
                  record.conversationId == conversationId,
                  record.sessionId == sessionId else {
                throw E2EEV2LiveShareStateError.invalidRecord
            }
            let counter = record.nextCounter ?? 1
            guard (1..<Int64(E2EEV2Canonical.maxSequenceNumber)).contains(counter) else {
                throw E2EEV2LiveShareStateError.sequenceExhausted
            }
            record.nextCounter = counter + 1
            record.updatedAtMs = max(0, nowMs)
            try save(record)
            return counter
        }
    }

    /// `409 E2EE_LIVE_SHARE_COUNTER_STALE` : le serveur a déjà vu `lastCounter`.
    func raiseCounter(
        ownerScopeId: String,
        sessionId: String,
        above lastCounter: Int64,
        nowMs: Int64
    ) throws {
        try lock.withLock {
            guard var record = try load(ownerScopeId: ownerScopeId, sessionId: sessionId),
                  record.ownerScopeId == ownerScopeId,
                  lastCounter >= 0, lastCounter < Int64(E2EEV2Canonical.maxSequenceNumber) else {
                throw E2EEV2LiveShareStateError.invalidRecord
            }
            guard (record.nextCounter ?? 1) <= lastCounter else { return }
            record.nextCounter = lastCounter + 1
            record.updatedAtMs = max(0, nowMs)
            try save(record)
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
                  let prepared = pending.prepared,
                  Self.isPublishable(prepared, clientRequestId: pending.clientRequestId),
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

    private static func isPublishable(_ prepared: E2EEV2LiveSharePreparedEnvelope, clientRequestId: String) -> Bool {
        switch prepared {
        case .v1(let value):
            value.clientRequestId == clientRequestId
                && value.ttlSeconds > 0 && value.encryptedBlobIds.isEmpty
        case .v3(let value):
            value.envelope.clientRequestId == clientRequestId
                && value.envelope.ttlSeconds > 0 && value.envelope.encryptedBlobIds.isEmpty
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
            nextCounter: nil,
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
    private let conversationStateStore: E2EEV2ConversationStateStore

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        epochStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        conversationStateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore()
    ) {
        self.identityStore = identityStore
        self.epochStore = epochStore
        self.conversationStateStore = conversationStateStore
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    func createSessionRuntime(
        ownerScopeId: String,
        conversationId: String,
        body: Data
    ) async -> E2EEV2LiveShareLifecycleResult {
        guard E2EEV2ServerGate.autoActive else {
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
        guard E2EEV2ServerGate.autoActive else {
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

    /// E2EE-AUTO §7.6 : la version suit le marquage de l'époque courante vérifiée,
    /// v3 `live_share` (avec le compteur de la session) sous une époque marquée,
    /// v1 sinon.
    func prepareRuntime(
        _ preparation: E2EEV2MessagePreparationInput,
        ownerScopeId: String,
        claimCounter: () throws -> Int64
    ) -> Result<E2EEV2LiveSharePreparedEnvelope, E2EEV2LiveShareRuntimeError> {
        guard E2EEV2ServerGate.autoActive else {
            return .failure(.preparationBlocked("e2ee-v2-security-review-required"))
        }
        guard LocalAccountScope.currentUserId != nil,
              LocalAccountScope.currentOwnerScopeId == ownerScopeId else {
            return .failure(.preparationBlocked("e2ee-v2-local-state-unavailable"))
        }
        let ownerNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        let current: E2EEV2ConversationStateStore.CurrentEpoch?
        do {
            current = try conversationStateStore.currentEpoch(
                conversationId: preparation.conversationId, ownerNamespace: ownerNamespace
            )
        } catch {
            return .failure(.preparationBlocked("invalid-e2ee-v2-local-state"))
        }
        guard let current, current.e2eeAuto == true else {
            switch E2EEV2MessageComposer.prepareRuntime(
                input: preparation, identityStore: identityStore, epochStore: epochStore,
                stateStore: conversationStateStore
            ) {
            case .blocked(let reason): return .failure(.preparationBlocked(reason))
            case .prepared(let envelope): return .success(.v1(envelope))
            }
        }
        do {
            guard let device = try identityStore.load(ownerNamespace: ownerNamespace),
                  var epoch = try E2EEV2VerifiedEpochKeys.exact(
                    conversationId: preparation.conversationId, epochNumber: current.epochNumber,
                    ownerNamespace: ownerNamespace, keyStore: epochStore, stateStore: conversationStateStore
                  ) else {
                return .failure(.preparationBlocked("e2ee-v2-local-state-unavailable"))
            }
            var payload = try E2EEV2ContentContract.encode(preparation.content)
            var fk = try E2EEV2MessageComposerV2.randomBytes(32)
            defer {
                epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count)
                payload.resetBytes(in: 0..<payload.count)
                fk.resetBytes(in: 0..<fk.count)
            }
            let envelope = try E2EEV2LiveShareEnvelopeV3.compose(
                payload: payload, conversationId: preparation.conversationId,
                clientRequestId: preparation.clientRequestId, counter: claimCounter(),
                ttlSeconds: preparation.ttlSeconds, epoch: epoch, device: device, fk: fk,
                nonce: E2EEV2MessageComposerV2.randomBytes(12)
            ) { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: ownerNamespace) }
            return .success(.v3(envelope))
        } catch {
            return .failure(.preparationBlocked("invalid-e2ee-v2-local-state"))
        }
    }

    func publishPreparedRuntime(
        ownerScopeId: String,
        sessionId: String,
        envelope prepared: E2EEV2LiveSharePreparedEnvelope
    ) async -> E2EEV2LiveSharePublishResult {
        guard E2EEV2ServerGate.autoActive else {
            return .failure(Self.activationFailure())
        }
        let body: Data?
        let isPublishable: Bool
        switch prepared {
        case .v1(let envelope):
            body = try? JSONEncoder().encode(envelope)
            isPublishable = envelope.ttlSeconds > 0 && envelope.encryptedBlobIds.isEmpty
        case .v3(let envelope):
            // Corps JCS, à l'octet de ce qui est signé (D.7).
            body = envelope.encoded
            isPublishable = envelope.envelope.ttlSeconds > 0 && envelope.envelope.encryptedBlobIds.isEmpty
                && envelope.envelope.delivery == .liveShare
        }
        guard Self.matches(ownerScopeId, Self.ownerPattern),
              Self.matches(sessionId, Self.opaquePattern),
              Self.matches(prepared.clientRequestId, Self.requestPattern),
              isPublishable,
              let body else {
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
                expectedClientRequestId: prepared.clientRequestId,
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
                        ownerNamespace: LocalAccountScope.storageNamespace(for: input.ownerScopeId),
                        includeRestored: false
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
        guard E2EEV2ServerGate.autoActive else { return .failure(activationFailure()) }
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
        guard E2EEV2ServerGate.autoActive else { return .failure(activationFailure()) }
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
        validateDecryptedContent(
            updateId: updateId,
            expectedSessionId: expectedSessionId,
            content: message.content,
            ttlSeconds: message.ttlSeconds,
            encryptedBlobIds: message.encryptedBlobIds,
            publicExpiresAt: publicExpiresAt,
            now: now
        )
    }

    /// Même portée privée pour un clair relu d'une enveloppe v1 ou v3.
    static func validateDecryptedContent(
        updateId: String,
        expectedSessionId: String,
        content: [String: Any],
        ttlSeconds: Int,
        encryptedBlobIds: [String],
        publicExpiresAt: Date,
        now: Date
    ) -> E2EEV2ReceivedLiveShareUpdate? {
        guard matches(updateId, opaquePattern),
              matches(expectedSessionId, opaquePattern),
              ttlSeconds > 0,
              encryptedBlobIds.isEmpty,
              content["kind"] as? String == "LIVE_LOCATION",
              let body = content["body"] as? [String: Any],
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
            content: content
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
                allowServerBoundedExpiry: true,
                allowsLiveShareV3: true
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
                delivery.epoch.epochNumber
            ) {
                epoch = stored
            } else if let epochDelivery = delivery.epochDelivery {
                ephemeralKey = try unwrapEpoch(epochDelivery)
                guard ephemeralKey.count == 32,
                      try E2EEV2EpochCrypto.keyCommitment(ephemeralKey)
                        == epochDelivery.keyCommitmentB64 else {
                    return .failure(localFailure("e2ee-v2-epoch-unwrapping-failed"))
                }
                epoch = .init(
                    conversationId: epochDelivery.conversationId,
                    epochId: epochDelivery.epochId,
                    epochNumber: epochDelivery.epochNumber,
                    keyCommitmentB64: epochDelivery.keyCommitmentB64,
                    epochKey: ephemeralKey
                )
            } else {
                // Époque accusée sans clé gardée : état local perdu, on attend la suivante (§7.6).
                return .failure(localFailure("e2ee-v2-acknowledged-epoch-key-missing"))
            }
            guard epoch.epochId == delivery.epoch.epochId,
                  epoch.epochNumber == delivery.epoch.epochNumber,
                  epoch.keyCommitmentB64 == delivery.epoch.keyCommitmentB64 else {
                return .failure(localFailure("e2ee-v2-delivered-epoch-mismatch"))
            }
            let received: E2EEV2ReceivedLiveShareUpdate?
            if envelope["envelopeVersion"] is String {
                // v3 `live_share` (§7.6) : relue par l'analyseur strict, jamais comme un message.
                guard let signed = E2EEV2SignedMessageEnvelopeV2.parse(
                        delivery.incoming.envelopeData, allowLiveShare: true
                      ),
                      signed.envelope.epochNumber == epoch.epochNumber,
                      signed.envelope.keyCommitmentB64 == epoch.keyCommitmentB64,
                      let keyData = Data(base64Encoded: delivery.incoming.senderPublicSigningKeyB64),
                      let senderKey = try? P256.Signing.PublicKey(x963Representation: keyData) else {
                    return .failure(localFailure("invalid-or-untrusted-e2ee-v2-live-share-delivery"))
                }
                let content = try E2EEV2LiveShareEnvelopeV3.open(
                    signed,
                    conversationId: input.conversationId,
                    senderDeviceId: delivery.incoming.senderDeviceId,
                    senderSigningKey: senderKey,
                    epochKey: epoch.epochKey
                )
                received = validateDecryptedContent(
                    updateId: updateId,
                    expectedSessionId: input.sessionId,
                    content: content,
                    ttlSeconds: signed.envelope.ttlSeconds,
                    encryptedBlobIds: signed.envelope.encryptedBlobIds,
                    publicExpiresAt: publicExpiry,
                    now: now
                )
            } else {
                let message = try E2EEV2MessageReceiver.decryptContractPreview(
                    input: delivery.incoming,
                    epoch: epoch
                )
                received = validateDecryptedUpdateContractPreview(
                    updateId: updateId,
                    expectedSessionId: input.sessionId,
                    message: message,
                    publicExpiresAt: publicExpiry,
                    now: now
                )
            }
            guard let update = received else {
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
    /// `409 E2EE_LIVE_SHARE_COUNTER_STALE` : compteur relevé, un renvoi (§7.6).
    case counterStale
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

    /// 32 Kio de `data`, plus les champs `event` et `id` de l'événement.
    static let maxFrameBytes = 34 * 1_024

    static func parse(frame: SSEFrameParser.Frame) -> E2EEV2LiveShareEvent? {
        parse(
            event: frame.event.trimmingCharacters(in: .whitespaces).lowercased(),
            data: frame.data,
            eventId: frame.id
        )
    }

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
                    guard E2EEV2ServerGate.autoActive,
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
                        // Le refus se juge à son `code` (E2EE-AUTO §7.6) : on lit le corps, borné.
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= E2EEV2LiveShareEventContract.maxFrameBytes { break }
                        }
                        let http = response as? HTTPURLResponse
                        throw APIError.http(
                            status: http?.statusCode ?? 0,
                            code: (try? JSONDecoder().decode(BackendErrorResponse.self, from: body))?.code,
                            message: "Flux Live Share E2EE v2 refusé",
                            requestId: nil,
                            retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                        )
                    }
                    // Octet par octet : `bytes.lines` omet les lignes vides qui ferment
                    // chaque événement, et aucun n'arrivait jamais.
                    var parser = SSEFrameParser(limit: E2EEV2LiveShareEventContract.maxFrameBytes)
                    do {
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            if let frame = try parser.append(byte),
                               let parsed = E2EEV2LiveShareEventContract.parse(frame: frame) {
                                continuation.yield(parsed)
                            }
                        }
                    } catch SSEFrameParser.Failure.oversizedFrame {
                        throw E2EEV2LiveShareStateError.invalidRecord
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
        guard E2EEV2ServerGate.autoActive,
              session.e2eeV2Required == true,
              session.status == "active",
              let expiresAt = session.expiresAt,
              expiresAt > now,
              payload.location != nil else {
            throw E2EEV2LiveShareRuntimeError.invalidSession
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        // §7.6 : après `E2EE_LIVE_SHARE_COUNTER_STALE`, un seul renvoi depuis
        // `lastCounter + 1` ; au second refus, fin du partage.
        var counterResends = 1
        // Le serveur ne sert que la dernière position et le compteur admet les
        // trous : une enveloppe restée en attente est dépassée par la position
        // courante. La renvoyer d'abord faisait partir la courante dans les 2 s
        // (429), gardée à son tour : le destinataire avait toujours la précédente.
        if let pending = try stateStore.pending(
            ownerScopeId: ownerScopeId,
            conversationId: session.conversationId,
            sessionId: session.id
        ) {
            try stateStore.complete(
                ownerScopeId: ownerScopeId,
                sessionId: session.id,
                clientRequestId: pending.clientRequestId,
                nowMs: nowMs
            )
        }

        while true {
            do {
                return try await publishCurrent(session: session, payload: payload, ownerScopeId: ownerScopeId, now: now)
            } catch E2EEV2LiveShareRuntimeError.counterStale {
                guard counterResends > 0 else {
                    throw E2EEV2LiveShareRuntimeError.transport(.init(
                        kind: .permanent, statusCode: 409, code: Self.counterStaleCode,
                        message: "e2ee-v2-live-share-counter-stale"
                    ))
                }
                counterResends -= 1
            }
        }
    }

    /// Chiffre la position courante sous un nouveau `clientRequestId`, la garde
    /// en attente, puis l'envoie.
    private func publishCurrent(
        session: LiveShareSession,
        payload: LiveSharePayload,
        ownerScopeId: String,
        now: Date
    ) async throws {
        guard let expiresAt = session.expiresAt else { throw E2EEV2LiveShareRuntimeError.invalidSession }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
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
        let envelope: E2EEV2LiveSharePreparedEnvelope
        switch client.prepareRuntime(preparation, ownerScopeId: ownerScopeId, claimCounter: { [stateStore] in
            try stateStore.claimCounter(
                ownerScopeId: ownerScopeId,
                conversationId: session.conversationId,
                sessionId: session.id,
                nowMs: nowMs
            )
        }) {
        case .failure(let error): throw error
        case .success(let value): envelope = value
        }
        let sessionExpiryMs = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        let sendDeadlineAtMs = min(sessionExpiryMs, nowMs + 60_000)
        let pending = E2EEV2LiveSharePendingEnvelope(
            clientRequestId: clientRequestId,
            sendDeadlineAtMs: sendDeadlineAtMs,
            prepared: envelope
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
        guard E2EEV2ServerGate.autoActive,
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

    private static let counterStaleCode = "E2EE_LIVE_SHARE_COUNTER_STALE"

    /// Un refus n'est pas retenu par le serveur (§7.6) : l'enveloppe est effacée
    /// tout de suite. Un réseau coupé, une cadence (429) ou une erreur du serveur
    /// la laissent jusqu'à la publication suivante, qui la remplace par la position courante.
    static func dropsPending(_ failure: E2EEV2TransportFailure) -> Bool {
        guard let status = failure.statusCode else { return false }
        return (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }

    private func sendPending(
        _ pending: E2EEV2LiveSharePendingEnvelope,
        ownerScopeId: String,
        sessionId: String,
        nowMs: Int64
    ) async throws {
        guard let prepared = pending.prepared else {
            try stateStore.complete(
                ownerScopeId: ownerScopeId, sessionId: sessionId, clientRequestId: pending.clientRequestId, nowMs: nowMs
            )
            throw E2EEV2LiveShareRuntimeError.invalidPayload
        }
        switch await client.publishPreparedRuntime(
            ownerScopeId: ownerScopeId,
            sessionId: sessionId,
            envelope: prepared
        ) {
        case .failure(let failure):
            if Self.dropsPending(failure) {
                try stateStore.complete(
                    ownerScopeId: ownerScopeId, sessionId: sessionId, clientRequestId: pending.clientRequestId, nowMs: nowMs
                )
            }
            if failure.statusCode == 409, failure.code == Self.counterStaleCode,
               case .string(let text)? = failure.details?["lastCounter"],
               E2EEV2Canonical.isDecimal(text), let lastCounter = Int64(text) {
                try stateStore.raiseCounter(ownerScopeId: ownerScopeId, sessionId: sessionId, above: lastCounter, nowMs: nowMs)
                throw E2EEV2LiveShareRuntimeError.counterStale
            }
            throw E2EEV2LiveShareRuntimeError.transport(failure)
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
              delivery.epochDelivery.map({ $0.conversationId == delivery.incoming.conversationId }) ?? true,
              delivery.epoch.epochNumber == delivered.message.epochNumber else {
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
