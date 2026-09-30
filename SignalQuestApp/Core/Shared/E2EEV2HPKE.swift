import Foundation
import CryptoKit

enum E2EEV2HPKEError: Error, Equatable {
    case invalidKey
    case invalidEncapsulation
    case deriveKeyPairFailed
    case openFailed
}

/// HPKE (RFC 9180), mode de base, KEM DHKEM(P-256, HKDF-SHA256) et KDF
/// HKDF-SHA256. Sert au signalement chiffré (spec §11, annexe D.10).
///
/// L'HPKE de CryptoKit exige iOS 17 ; la cible reste iOS 16. Cette version est
/// écrite sur les primitives de CryptoKit disponibles dès iOS 13 (ECDH P-256,
/// HKDF, AES-GCM), et vérifiée par les vecteurs de la RFC (A.3) et par une
/// contre-épreuve avec l'HPKE de CryptoKit quand il est disponible.
enum E2EEV2HPKE {
    enum AEAD: UInt16, Sendable {
        case aes128GCM = 0x0001
        case aes256GCM = 0x0002

        var keyLength: Int { self == .aes128GCM ? 16 : 32 }
    }

    static let kemId: UInt16 = 0x0010
    static let kdfId: UInt16 = 0x0001
    static let nonceLength = 12
    static let secretLength = 32

    // MARK: Fonctions étiquetées (RFC 9180 §4)

    static func labeledExtract(salt: Data, label: String, ikm: Data, suiteId: Data) -> Data {
        var input = Data("HPKE-v1".utf8)
        input.append(suiteId)
        input.append(Data(label.utf8))
        input.append(ikm)
        let prk = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: salt))
        return Data(prk)
    }

    static func labeledExpand(prk: Data, label: String, info: Data, length: Int, suiteId: Data) -> Data {
        var labeledInfo = i2osp(length, 2)
        labeledInfo.append(Data("HPKE-v1".utf8))
        labeledInfo.append(suiteId)
        labeledInfo.append(Data(label.utf8))
        labeledInfo.append(info)
        let key = HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: prk),
            info: labeledInfo,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static var kemSuiteId: Data {
        var id = Data("KEM".utf8)
        id.append(i2osp(Int(kemId), 2))
        return id
    }

    static func hpkeSuiteId(aead: AEAD) -> Data {
        var id = Data("HPKE".utf8)
        id.append(i2osp(Int(kemId), 2))
        id.append(i2osp(Int(kdfId), 2))
        id.append(i2osp(Int(aead.rawValue), 2))
        return id
    }

    // MARK: KEM DHKEM(P-256, HKDF-SHA256)

    /// Dérivation déterministe d'une paire (RFC 9180 §7.1.3) : sert aux vecteurs.
    static func deriveKeyPair(ikm: Data) throws -> P256.KeyAgreement.PrivateKey {
        let prk = labeledExtract(salt: Data(), label: "dkp_prk", ikm: ikm, suiteId: kemSuiteId)
        for counter in 0...255 {
            let candidate = labeledExpand(
                prk: prk,
                label: "candidate",
                info: i2osp(counter, 1),
                length: 32,
                suiteId: kemSuiteId
            )
            // Masque 0xFF pour P-256 : l'octet de tête reste entier. CryptoKit
            // refuse un scalaire nul ou supérieur ou égal à l'ordre.
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: candidate) {
                return key
            }
        }
        throw E2EEV2HPKEError.deriveKeyPairFailed
    }

    static func encapsulate(
        recipient: P256.KeyAgreement.PublicKey,
        ephemeral: P256.KeyAgreement.PrivateKey
    ) throws -> (sharedSecret: Data, enc: Data) {
        let dh = try ephemeral.sharedSecretFromKeyAgreement(with: recipient).withUnsafeBytes { Data($0) }
        let enc = ephemeral.publicKey.x963Representation
        let kemContext = enc + recipient.x963Representation
        return (extractAndExpand(dh: dh, kemContext: kemContext), enc)
    }

    static func decapsulate(enc: Data, recipient: P256.KeyAgreement.PrivateKey) throws -> Data {
        guard enc.count == 65,
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: enc) else {
            throw E2EEV2HPKEError.invalidEncapsulation
        }
        let dh = try recipient.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
        let kemContext = enc + recipient.publicKey.x963Representation
        return extractAndExpand(dh: dh, kemContext: kemContext)
    }

    private static func extractAndExpand(dh: Data, kemContext: Data) -> Data {
        let prk = labeledExtract(salt: Data(), label: "eae_prk", ikm: dh, suiteId: kemSuiteId)
        return labeledExpand(prk: prk, label: "shared_secret", info: kemContext, length: secretLength, suiteId: kemSuiteId)
    }

    // MARK: Calendrier de clés, mode de base (RFC 9180 §5.1)

    struct Context: Equatable {
        let key: Data
        let baseNonce: Data
        let keyScheduleContext: Data
        let secret: Data
    }

    static func keySchedule(sharedSecret: Data, info: Data, aead: AEAD) -> Context {
        let suiteId = hpkeSuiteId(aead: aead)
        let pskIdHash = labeledExtract(salt: Data(), label: "psk_id_hash", ikm: Data(), suiteId: suiteId)
        let infoHash = labeledExtract(salt: Data(), label: "info_hash", ikm: info, suiteId: suiteId)
        var keyScheduleContext = Data([0x00])
        keyScheduleContext.append(pskIdHash)
        keyScheduleContext.append(infoHash)
        let secret = labeledExtract(salt: sharedSecret, label: "secret", ikm: Data(), suiteId: suiteId)
        let key = labeledExpand(prk: secret, label: "key", info: keyScheduleContext, length: aead.keyLength, suiteId: suiteId)
        let baseNonce = labeledExpand(prk: secret, label: "base_nonce", info: keyScheduleContext, length: nonceLength, suiteId: suiteId)
        return Context(key: key, baseNonce: baseNonce, keyScheduleContext: keyScheduleContext, secret: secret)
    }

    // MARK: Chiffrement en un coup (séquence 0)

    static func seal(
        recipient: P256.KeyAgreement.PublicKey,
        info: Data,
        aad: Data,
        plaintext: Data,
        aead: AEAD = .aes256GCM,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> (enc: Data, ciphertext: Data) {
        let (sharedSecret, enc) = try encapsulate(recipient: recipient, ephemeral: ephemeral)
        let context = keySchedule(sharedSecret: sharedSecret, info: info, aead: aead)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: context.key),
            nonce: AES.GCM.Nonce(data: context.baseNonce),
            authenticating: aad
        )
        // `Data(...)` : la concaténation garderait l'index de départ d'une tranche.
        return (enc, Data(sealed.ciphertext + sealed.tag))
    }

    static func open(
        enc: Data,
        recipient: P256.KeyAgreement.PrivateKey,
        info: Data,
        aad: Data,
        ciphertext: Data,
        aead: AEAD = .aes256GCM
    ) throws -> Data {
        guard ciphertext.count >= 16 else { throw E2EEV2HPKEError.openFailed }
        let sharedSecret = try decapsulate(enc: enc, recipient: recipient)
        let context = keySchedule(sharedSecret: sharedSecret, info: info, aead: aead)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: context.baseNonce),
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: context.key), authenticating: aad)
        } catch {
            throw E2EEV2HPKEError.openFailed
        }
    }

    static func i2osp(_ value: Int, _ length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        var remaining = value
        for position in stride(from: length - 1, through: 0, by: -1) {
            bytes[position] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        return Data(bytes)
    }
}
