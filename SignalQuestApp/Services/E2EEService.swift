import Foundation
import CryptoKit
import CommonCrypto
import Security

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
            return "Conversation chiffrée non encore supportée/déverrouillée sur iOS"
        case .unsupported(let value):
            return value
        case .invalidKey:
            return "Clé E2EE invalide"
        case .wrongPassword:
            return "Mot de passe incorrect. Réessaie."
        case .decryptFailed:
            return "Déchiffrement impossible"
        case .keyGenerationFailed:
            return "Génération de la clé E2EE impossible"
        case .staleKey:
            return "Clé de conversation obsolète — re-partage nécessaire"
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
    /// Chiffre avec une AAD explicite (payload v2). Utilisé pour les messages
    /// planifiés E2EE (le backend exige `aadB64` non vide + un `nonce`). L'AAD est
    /// renvoyée dans le payload et utilisée telle quelle au déchiffrement.
    func encryptText(conversationId: String, text: String, aad: Data) async throws -> E2EEPayload
    func decryptText(conversationId: String, message: MessageItem) async throws -> String
    /// Erases all locally stored E2EE material (private key + cached conversation
    /// keys, in Keychain and in memory). Must be called on logout / account
    /// deletion so a different user on the same device can never reuse the keys.
    func wipeLocalKeys() async
}

final class E2EEService: E2EEServicing, @unchecked Sendable {
    private let api: APIClient
    private let tokenStore: TokenStore
    private let stateLock = NSLock()
    private var unlockedPrivateJwk: String?

    init(api: APIClient, tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")) {
        self.api = api
        self.tokenStore = tokenStore
    }

    func bootstrap() async throws -> E2EEBootstrapResponse {
        try await api.request(APIEndpoint(path: "/api/e2ee/bootstrap"), as: E2EEBootstrapResponse.self)
    }

    func unlock(userId: String, password: String, bootstrapKey: E2EEBootstrapKey) async throws {
        let privateJwk = try Self.decryptPrivateJWK(
            password: password,
            encryptedPrivateJwkB64: bootstrapKey.encryptedPrivateJwk,
            kdfSaltB64: bootstrapKey.kdfSaltB64,
            iterations: bootstrapKey.kdfIterations
        )
        guard Self.privateJwk(privateJwk, matchesPublicJwk: bootstrapKey.publicKeyJwk) else {
            throw E2EEError.invalidKey
        }
        try tokenStore.set(privateJwk, for: "privateJwk:\(userId)")
        try tokenStore.set(privateJwk, for: "privateJwk:current")
        stateLock.withLock {
            unlockedPrivateJwk = privateJwk
        }
    }

    func isUnlocked() async -> Bool {
        (try? knownPrivateJwk()) ?? nil != nil
    }

    func generateAndRegisterKey(userId: String, password: String) async throws {
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

        try tokenStore.set(privateJwk, for: "privateJwk:\(userId)")
        try tokenStore.set(privateJwk, for: "privateJwk:current")
        stateLock.withLock {
            unlockedPrivateJwk = privateJwk
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

    func wipeLocalKeys() async {
        stateLock.withLock { unlockedPrivateJwk = nil }
        try? tokenStore.removeAll()
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
        let key = try await conversationKey(conversationId: conversationId)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key, nonce: nonce)
        var ciphertextAndTag = Data(sealed.ciphertext)
        ciphertextAndTag.append(sealed.tag)
        return E2EEPayload(
            v: 1,
            ivB64: nonce.data.base64EncodedNoPadding(),
            ciphertextB64: ciphertextAndTag.base64EncodedNoPadding(),
            aadB64: nil
        )
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
        if let cached = try tokenStore.string(for: "conversation:\(conversationId)"),
           let data = Data(base64Encoded: cached),
           data.count == 32 {
            return data
        }

        guard let privateJwk = try knownPrivateJwk() else {
            throw E2EEError.locked
        }
        do {
            let response: ConversationKeyResponse = try await api.request(APIEndpoint(path: "/api/messages/conversations/\(conversationId)/key"), as: ConversationKeyResponse.self)
            let raw = try Self.unwrapConversationKey(wrappedKeyB64: response.wrappedKeyB64, privateJwk: privateJwk)
            try tokenStore.set(raw.base64EncodedString(), for: "conversation:\(conversationId)")
            return raw
        } catch APIError.http(let status, _, _, _, _) where status == 409 {
            // Rotation de clé E2EE côté serveur : la clé wrappée est obsolète.
            // On purge le cache local ; le prochain accès re-fetchera après re-partage.
            try? tokenStore.remove("conversation:\(conversationId)")
            throw E2EEError.staleKey
        }
    }

    private func knownPrivateJwk() throws -> String? {
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

extension Data {
    /// Base64 standard sans padding `=` — format d'encodage Android/web
    /// (`Base64.getEncoder().withoutPadding()`).
    func base64EncodedNoPadding() -> String {
        base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Base64URL sans padding — format des champs JWK (RFC 7517).
    func base64URLEncodedNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
