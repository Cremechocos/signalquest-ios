import Foundation
import CryptoKit

// Formats de la chaîne de confiance du jalon A (spec E2EE §2, §3.5 et annexe
// D.1 à D.6, D.12 à D.14). Chaque chaîne signée voyage telle quelle ; les
// analyseurs la découpent strictement et ne la reconstruisent jamais.

enum E2EEV2TrustFormatError: Error, Equatable {
    case invalidField
    case invalidSignature
    case digestMismatch
    case keyMismatch
    case invalidKey
}

/// Signature d'une chaîne canonique : chaîne telle quelle et signature DER low-S.
struct E2EEV2SignedString: Equatable, Sendable {
    let canonical: String
    let signatureB64: String

    static func sign(_ canonical: String, with key: P256.Signing.PrivateKey) throws -> E2EEV2SignedString {
        let der = try E2EEV2LowS.sign(Data(canonical.utf8), with: key)
        return E2EEV2SignedString(canonical: canonical, signatureB64: der.base64EncodedString())
    }

    func verify(with publicKey: P256.Signing.PublicKey) -> Bool {
        guard let der = Data(base64Encoded: signatureB64) else { return false }
        return E2EEV2LowS.verify(derSignature: der, message: Data(canonical.utf8), publicKey: publicKey)
    }
}

// MARK: D.1 Transport de l'UIK

struct E2EEV2UIKWrap: Equatable, Sendable {
    let userId: String
    let approverDeviceId: String
    let newDeviceId: String
    let uikPublicKeyB64: String
    let ephemeralPublicKeyB64: String
    let nonceB64: String
    let aadB64: String
    let wrappedUikB64: String
    let signatureB64: String
}

enum E2EEV2UIKWrapCrypto {
    static let kdfInfo = "signalquest-e2ee-v2-uik-wrap-v1"

    static func salt(userId: String, approverDeviceId: String, newDeviceId: String) -> Data {
        Data(SHA256.hash(data: E2EEV2Canonical.line([
            "SQ-E2EE-V2-UIK-WRAP-SALT", "1", userId, approverDeviceId, newDeviceId,
        ])))
    }

    static func aad(
        userId: String,
        approverDeviceId: String,
        newDeviceId: String,
        uikPublicKeyB64: String,
        ephemeralPublicKeyB64: String
    ) -> Data {
        E2EEV2Canonical.line([
            "SQ-E2EE-V2-UIK-WRAP", "1", userId, approverDeviceId, newDeviceId,
            uikPublicKeyB64, ephemeralPublicKeyB64,
        ])
    }

    static func signatureCanonical(_ wrap: E2EEV2UIKWrap) -> String {
        [
            "SQ-E2EE-V2-UIK-WRAP-SIGNATURE", "1", wrap.userId, wrap.approverDeviceId, wrap.newDeviceId,
            wrap.uikPublicKeyB64, wrap.ephemeralPublicKeyB64, wrap.nonceB64, wrap.aadB64, wrap.wrappedUikB64,
        ].joined(separator: "\n")
    }

    static func wrappingKey(sharedSecret: Data, salt: Data) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    static func wrap(
        uik: P256.Signing.PrivateKey,
        userId: String,
        approverDeviceId: String,
        newDeviceId: String,
        newDeviceAgreementKey: P256.KeyAgreement.PublicKey,
        approverSigningKey: P256.Signing.PrivateKey,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        nonce: Data
    ) throws -> E2EEV2UIKWrap {
        try wrap(
            uik: uik, userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDeviceId,
            newDeviceAgreementKey: newDeviceAgreementKey,
            signWithApprover: { try E2EEV2LowS.sign($0, with: approverSigningKey) },
            ephemeral: ephemeral, nonce: nonce
        )
    }

    /// Même transport, signé par l'approbateur sans que sa clé privée quitte
    /// son magasin : `signWithApprover` rend une signature DER low-S.
    static func wrap(
        uik: P256.Signing.PrivateKey,
        userId: String,
        approverDeviceId: String,
        newDeviceId: String,
        newDeviceAgreementKey: P256.KeyAgreement.PublicKey,
        signWithApprover: (Data) throws -> Data,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        nonce: Data
    ) throws -> E2EEV2UIKWrap {
        guard [userId, approverDeviceId, newDeviceId].allSatisfy(E2EEV2Canonical.isOpaque),
              nonce.count == 12 else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let uikB64 = uik.publicKey.x963Representation.base64EncodedString()
        let ephemeralB64 = ephemeral.publicKey.x963Representation.base64EncodedString()
        let wrapAAD = aad(
            userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDeviceId,
            uikPublicKeyB64: uikB64, ephemeralPublicKeyB64: ephemeralB64
        )
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: newDeviceAgreementKey).withUnsafeBytes { Data($0) }
        let key = wrappingKey(
            sharedSecret: secret,
            salt: salt(userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDeviceId)
        )
        let sealed = try AES.GCM.seal(
            uik.rawRepresentation,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: wrapAAD
        )
        let unsigned = E2EEV2UIKWrap(
            userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDeviceId,
            uikPublicKeyB64: uikB64, ephemeralPublicKeyB64: ephemeralB64,
            nonceB64: nonce.base64EncodedString(), aadB64: wrapAAD.base64EncodedString(),
            wrappedUikB64: (sealed.ciphertext + sealed.tag).base64EncodedString(), signatureB64: ""
        )
        let signature = try signWithApprover(Data(signatureCanonical(unsigned).utf8))
        return E2EEV2UIKWrap(
            userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDeviceId,
            uikPublicKeyB64: uikB64, ephemeralPublicKeyB64: ephemeralB64,
            nonceB64: unsigned.nonceB64, aadB64: unsigned.aadB64,
            wrappedUikB64: unsigned.wrappedUikB64, signatureB64: signature.base64EncodedString()
        )
    }

    /// Ouvre le transport et vérifie que le scalaire redonne l'UIK attendue.
    static func unwrap(
        _ wrap: E2EEV2UIKWrap,
        newDeviceAgreementKey: P256.KeyAgreement.PrivateKey,
        approverSigningKey: P256.Signing.PublicKey,
        expectedUIKB64: String
    ) throws -> P256.Signing.PrivateKey {
        guard let signature = Data(base64Encoded: wrap.signatureB64),
              E2EEV2LowS.verify(
                derSignature: signature,
                message: Data(signatureCanonical(wrap).utf8),
                publicKey: approverSigningKey
              ) else {
            throw E2EEV2TrustFormatError.invalidSignature
        }
        let expectedAAD = aad(
            userId: wrap.userId, approverDeviceId: wrap.approverDeviceId, newDeviceId: wrap.newDeviceId,
            uikPublicKeyB64: wrap.uikPublicKeyB64, ephemeralPublicKeyB64: wrap.ephemeralPublicKeyB64
        )
        guard wrap.uikPublicKeyB64 == expectedUIKB64,
              Data(base64Encoded: wrap.aadB64) == expectedAAD,
              let nonce = Data(base64Encoded: wrap.nonceB64), nonce.count == 12,
              let wrapped = Data(base64Encoded: wrap.wrappedUikB64), wrapped.count == 48,
              let ephemeralData = Data(base64Encoded: wrap.ephemeralPublicKeyB64),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralData) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let secret = try newDeviceAgreementKey.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
        let key = wrappingKey(
            sharedSecret: secret,
            salt: salt(userId: wrap.userId, approverDeviceId: wrap.approverDeviceId, newDeviceId: wrap.newDeviceId)
        )
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: wrapped.prefix(32),
            tag: wrapped.suffix(16)
        )
        let scalar = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: expectedAAD)
        let uik = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        guard uik.publicKey.x963Representation.base64EncodedString() == expectedUIKB64 else {
            throw E2EEV2TrustFormatError.keyMismatch
        }
        return uik
    }
}

// MARK: D.2 Certificat d'appareil

struct E2EEV2DeviceCertificate: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-DEVICE-CERT"
    static let platforms: Set<String> = ["ios", "android", "web"]

    let userId: String
    let deviceId: String
    let keyVersion: Int
    let identityKeyB64: String
    let signingKeyB64: String
    let platform: String
    let createdAtMs: Int64

    var canonical: String {
        [
            Self.tag, "1", userId, deviceId, String(keyVersion), identityKeyB64, signingKeyB64,
            platform, String(createdAtMs),
        ].joined(separator: "\n")
    }

    var fingerprint: String? {
        guard let identity = Data(base64Encoded: identityKeyB64),
              let signing = Data(base64Encoded: signingKeyB64) else { return nil }
        return E2EEV2Canonical.deviceFingerprint(identityKeyX963: identity, signingKeyX963: signing)
    }

    static func parse(_ canonical: String) throws -> E2EEV2DeviceCertificate {
        guard let f = E2EEV2Canonical.split(canonical, tag: tag, version: "1", fieldCount: 9),
              E2EEV2Canonical.isOpaque(f[2]), E2EEV2Canonical.isOpaque(f[3]),
              E2EEV2Canonical.isDecimal(f[4]), let keyVersion = Int(f[4]), keyVersion >= 1,
              E2EEV2Canonical.isX963PublicKey(f[5]), E2EEV2Canonical.isX963PublicKey(f[6]),
              platforms.contains(f[7]),
              E2EEV2Canonical.isDecimal(f[8]), let createdAt = Int64(f[8]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        return E2EEV2DeviceCertificate(
            userId: f[2], deviceId: f[3], keyVersion: keyVersion, identityKeyB64: f[5],
            signingKeyB64: f[6], platform: f[7], createdAtMs: createdAt
        )
    }

    /// Vérifie la signature de l'UIK épinglée, puis analyse strictement.
    static func verify(_ signed: E2EEV2SignedString, uik: P256.Signing.PublicKey) throws -> E2EEV2DeviceCertificate {
        guard signed.verify(with: uik) else { throw E2EEV2TrustFormatError.invalidSignature }
        return try parse(signed.canonical)
    }
}

// MARK: D.3 Liste d'appareils signée

struct E2EEV2DeviceList: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-DEVICE-LIST"
    static let entriesTag = "SQ-E2EE-V2-DEVICE-LIST-ENTRIES"

    let userId: String
    let version: Int
    let previousListDigest: String
    let deviceCount: Int
    let devicesDigest: String
    let issuedAtMs: Int64

    static func entry(deviceId: String, keyVersion: Int, platform: String, fingerprint: String) -> String {
        [deviceId, String(keyVersion), platform, fingerprint].joined(separator: "\n")
    }

    /// Analyse stricte d'une ligne d'appareil : quatre champs exacts. Les
    /// lignes contiennent elles-mêmes des retours à la ligne ; sans ce contrôle,
    /// deux découpages différents donneraient le même condensat.
    static func parseEntry(_ entry: String) -> (deviceId: String, keyVersion: Int, platform: String, fingerprint: String)? {
        let f = entry.components(separatedBy: "\n")
        guard f.count == 4, E2EEV2Canonical.isOpaque(f[0]),
              E2EEV2Canonical.isDecimal(f[1]), let keyVersion = Int(f[1]), (1..<Int(Int32.max)).contains(keyVersion),
              E2EEV2DeviceCertificate.platforms.contains(f[2]),
              E2EEV2ApprovalV2.isDigest(f[3]) else { return nil }
        return (f[0], keyVersion, f[2], f[3])
    }

    static func digest(of canonical: String) -> String {
        E2EEV2Canonical.sha256B64URL(Data(canonical.utf8))
    }

    var canonical: String {
        [
            Self.tag, "1", userId, String(version), previousListDigest, String(deviceCount),
            devicesDigest, String(issuedAtMs),
        ].joined(separator: "\n")
    }

    static func make(
        userId: String,
        version: Int,
        previousCanonical: String?,
        entries: [String],
        issuedAtMs: Int64
    ) -> E2EEV2DeviceList {
        E2EEV2DeviceList(
            userId: userId,
            version: version,
            previousListDigest: previousCanonical.map(digest(of:)) ?? "-",
            deviceCount: entries.count,
            devicesDigest: E2EEV2Canonical.listDigest(tag: entriesTag, lines: entries),
            issuedAtMs: issuedAtMs
        )
    }

    /// Vérifie la signature, le condensat des entrées et le chaînage.
    static func verify(
        _ signed: E2EEV2SignedString,
        entries: [String],
        uik: P256.Signing.PublicKey,
        previousCanonical: String?
    ) throws -> E2EEV2DeviceList {
        try verify(signed, entries: entries, uik: uik, expectedPrevious: previousCanonical.map(digest(of:)) ?? "-")
    }

    /// Même contrôle quand la liste précédente n'est pas connue ici (versions
    /// manquées) : le chaînage ne peut pas être vérifié ; la signature de
    /// l'UIK et la version croissante, contrôlée par l'appelant, suffisent.
    static func verifyWithoutChain(
        _ signed: E2EEV2SignedString,
        entries: [String],
        uik: P256.Signing.PublicKey
    ) throws -> E2EEV2DeviceList {
        try verify(signed, entries: entries, uik: uik, expectedPrevious: nil)
    }

    private static func verify(
        _ signed: E2EEV2SignedString,
        entries: [String],
        uik: P256.Signing.PublicKey,
        expectedPrevious: String?
    ) throws -> E2EEV2DeviceList {
        guard signed.verify(with: uik) else { throw E2EEV2TrustFormatError.invalidSignature }
        guard let f = E2EEV2Canonical.split(signed.canonical, tag: tag, version: "1", fieldCount: 8),
              E2EEV2Canonical.isOpaque(f[2]),
              E2EEV2Canonical.isDecimal(f[3]), let version = Int(f[3]), (1..<Int(Int32.max)).contains(version),
              E2EEV2Canonical.isDecimal(f[5]), let count = Int(f[5]),
              E2EEV2Canonical.isDecimal(f[7]), let issuedAt = Int64(f[7]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard expectedPrevious.map({ f[4] == $0 }) ?? true, (version == 1) == (f[4] == "-") else {
            throw E2EEV2TrustFormatError.digestMismatch
        }
        let parsed = entries.compactMap(parseEntry)
        guard parsed.count == entries.count,
              Set(parsed.map(\.deviceId)).count == entries.count else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard count == entries.count,
              Set(entries).count == entries.count,
              f[6] == E2EEV2Canonical.listDigest(tag: entriesTag, lines: entries) else {
            throw E2EEV2TrustFormatError.digestMismatch
        }
        return E2EEV2DeviceList(
            userId: f[2], version: version, previousListDigest: f[4], deviceCount: count,
            devicesDigest: f[6], issuedAtMs: issuedAt
        )
    }
}

// MARK: D.4 Changement de membre

struct E2EEV2MembershipChange: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-MEMBERSHIP"
    static let actions: Set<String> = [
        "ADD", "REMOVE", "LEAVE", "ROLE_ADMIN", "ROLE_MEMBER", "EXCLUDE_WEB_ON", "EXCLUDE_WEB_OFF",
    ]

    let conversationId: String
    let changeNumber: Int
    let action: String
    let targetUserId: String
    let actorUserId: String
    let actorDeviceId: String
    let previousChangeDigest: String
    let createdAtMs: Int64

    var canonical: String {
        [
            Self.tag, "1", conversationId, String(changeNumber), action, targetUserId, actorUserId,
            actorDeviceId, previousChangeDigest, String(createdAtMs),
        ].joined(separator: "\n")
    }

    static func digest(of canonical: String) -> String {
        E2EEV2Canonical.sha256B64URL(Data(canonical.utf8))
    }

    static func parse(_ canonical: String, previousCanonical: String?) throws -> E2EEV2MembershipChange {
        guard let f = E2EEV2Canonical.split(canonical, tag: tag, version: "1", fieldCount: 10),
              E2EEV2Canonical.isOpaque(f[2]),
              E2EEV2Canonical.isDecimal(f[3]), let number = Int(f[3]), number >= 1,
              actions.contains(f[4]),
              E2EEV2Canonical.isOpaque(f[6]), E2EEV2Canonical.isOpaque(f[7]),
              E2EEV2Canonical.isDecimal(f[9]), let createdAt = Int64(f[9]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let webToggle = f[4].hasPrefix("EXCLUDE_WEB_")
        guard webToggle ? f[5] == "-" : E2EEV2Canonical.isOpaque(f[5]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        if f[4] == "LEAVE", f[5] != f[6] { throw E2EEV2TrustFormatError.invalidField }
        let expectedPrevious = previousCanonical.map(digest(of:)) ?? "-"
        guard f[8] == expectedPrevious, (number == 1) == (f[8] == "-") else {
            throw E2EEV2TrustFormatError.digestMismatch
        }
        return E2EEV2MembershipChange(
            conversationId: f[2], changeNumber: number, action: f[4], targetUserId: f[5],
            actorUserId: f[6], actorDeviceId: f[7], previousChangeDigest: f[8], createdAtMs: createdAt
        )
    }
}

// MARK: D.5 Document de capacités

struct E2EEV2CapabilitiesDocument: Equatable, Sendable {
    static let schema = "signalquest.e2ee-capabilities"
    static let knownFeatures: Set<String> = ["blobs", "calls", "liveLocation", "polls", "reactions", "voice"]

    let userId: String
    let deviceId: String
    let sequence: Int
    let issuedAtMs: Int64
    let envelopeVersions: [String]
    let payloadVersions: [String]
    let kinds: [String]
    let features: [String]

    var json: E2EEV2JSON {
        .object([
            "schema": .string(Self.schema),
            "version": .string("1"),
            "userId": .string(userId),
            "deviceId": .string(deviceId),
            "sequence": .string(String(sequence)),
            "issuedAtMs": .string(String(issuedAtMs)),
            "envelopeVersions": .array(envelopeVersions.map(E2EEV2JSON.string)),
            "payloadVersions": .array(payloadVersions.map(E2EEV2JSON.string)),
            "kinds": .array(kinds.map(E2EEV2JSON.string)),
            "features": .array(features.map(E2EEV2JSON.string)),
        ])
    }

    var document: String { E2EEV2CanonicalJSON.encodeString(json) }

    static func signatureCanonical(document: String) -> String {
        ["SQ-E2EE-V2-DEVICE-CAPABILITIES", "1", E2EEV2Canonical.sha256B64URL(Data(document.utf8))]
            .joined(separator: "\n")
    }

    /// Analyse stricte : JSON canonique, clés exactes, listes triées sans doublon.
    static func parse(document: String) throws -> E2EEV2CapabilitiesDocument {
        guard let root = try E2EEV2CanonicalJSON.parseCanonical(document).objectValue,
              Set(root.keys) == [
                "schema", "version", "userId", "deviceId", "sequence", "issuedAtMs",
                "envelopeVersions", "payloadVersions", "kinds", "features",
              ],
              root["schema"]?.stringValue == schema, root["version"]?.stringValue == "1",
              let userId = root["userId"]?.stringValue, E2EEV2Canonical.isOpaque(userId),
              let deviceId = root["deviceId"]?.stringValue, E2EEV2Canonical.isOpaque(deviceId),
              let sequenceText = root["sequence"]?.stringValue, E2EEV2Canonical.isDecimal(sequenceText),
              let sequence = Int(sequenceText), sequence >= 1,
              let issuedText = root["issuedAtMs"]?.stringValue, E2EEV2Canonical.isDecimal(issuedText),
              let issuedAt = Int64(issuedText),
              let envelopes = sortedUniqueStrings(root["envelopeVersions"]),
              envelopes.allSatisfy(E2EEV2Canonical.isDecimal),
              let payloads = sortedUniqueStrings(root["payloadVersions"]),
              payloads.allSatisfy(E2EEV2Canonical.isDecimal),
              let kinds = sortedUniqueStrings(root["kinds"]),
              kinds.allSatisfy({ $0.range(of: #"^[A-Z][A-Z_]{0,31}$"#, options: .regularExpression) != nil }),
              let features = sortedUniqueStrings(root["features"]),
              Set(features).isSubset(of: knownFeatures) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        return E2EEV2CapabilitiesDocument(
            userId: userId, deviceId: deviceId, sequence: sequence, issuedAtMs: issuedAt,
            envelopeVersions: envelopes, payloadVersions: payloads, kinds: kinds, features: features
        )
    }

    private static func sortedUniqueStrings(_ value: E2EEV2JSON?) -> [String]? {
        guard let items = value?.arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        guard strings.count == items.count,
              strings == strings.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }),
              Set(strings).count == strings.count else {
            return nil
        }
        return strings
    }
}

// MARK: §3.5 et D.6 Manifeste d'époque

struct E2EEV2EpochManifest: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-EPOCH-MANIFEST"
    static let recipientsTag = "SQ-E2EE-V2-EPOCH-RECIPIENTS"

    let conversationId: String
    let epochNumber: Int
    let creatorUserId: String
    let creatorDeviceId: String
    let keyCommitmentB64: String
    let recipientCount: Int
    let recipientsDigest: String
    let excludesWeb: Bool
    let createdAtMs: Int64

    static func recipient(userId: String, deviceId: String, platform: String, fingerprint: String) -> String {
        [userId, deviceId, platform, fingerprint].joined(separator: "\n")
    }

    var canonical: String {
        [
            Self.tag, "1", conversationId, String(epochNumber), creatorUserId, creatorDeviceId,
            keyCommitmentB64, String(recipientCount), recipientsDigest, excludesWeb ? "1" : "0",
            String(createdAtMs),
        ].joined(separator: "\n")
    }

    static func make(
        conversationId: String,
        epochNumber: Int,
        creatorUserId: String,
        creatorDeviceId: String,
        keyCommitmentB64: String,
        recipients: [String],
        excludesWeb: Bool,
        createdAtMs: Int64
    ) -> E2EEV2EpochManifest {
        E2EEV2EpochManifest(
            conversationId: conversationId, epochNumber: epochNumber, creatorUserId: creatorUserId,
            creatorDeviceId: creatorDeviceId, keyCommitmentB64: keyCommitmentB64,
            recipientCount: recipients.count,
            recipientsDigest: E2EEV2Canonical.listDigest(tag: recipientsTag, lines: recipients),
            excludesWeb: excludesWeb, createdAtMs: createdAtMs
        )
    }

    static func verify(
        _ signed: E2EEV2SignedString,
        recipients: [String],
        creatorSigningKey: P256.Signing.PublicKey
    ) throws -> E2EEV2EpochManifest {
        guard signed.verify(with: creatorSigningKey) else { throw E2EEV2TrustFormatError.invalidSignature }
        guard let f = E2EEV2Canonical.split(signed.canonical, tag: tag, version: "1", fieldCount: 11),
              E2EEV2Canonical.isOpaque(f[2]),
              E2EEV2Canonical.isDecimal(f[3]), let epochNumber = Int(f[3]), epochNumber >= 1,
              E2EEV2Canonical.isOpaque(f[4]), E2EEV2Canonical.isOpaque(f[5]),
              Data(base64Encoded: f[6])?.count == 32,
              E2EEV2Canonical.isDecimal(f[7]), let count = Int(f[7]),
              f[9] == "0" || f[9] == "1",
              E2EEV2Canonical.isDecimal(f[10]), let createdAt = Int64(f[10]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let excludesWeb = f[9] == "1"
        guard count == recipients.count, Set(recipients).count == recipients.count,
              f[8] == E2EEV2Canonical.listDigest(tag: recipientsTag, lines: recipients) else {
            throw E2EEV2TrustFormatError.digestMismatch
        }
        // Un manifeste qui exclut les navigateurs ne peut pas en viser un.
        if excludesWeb, recipients.contains(where: { $0.components(separatedBy: "\n").dropFirst(2).first == "web" }) {
            throw E2EEV2TrustFormatError.invalidField
        }
        return E2EEV2EpochManifest(
            conversationId: f[2], epochNumber: epochNumber, creatorUserId: f[4], creatorDeviceId: f[5],
            keyCommitmentB64: f[6], recipientCount: count, recipientsDigest: f[8],
            excludesWeb: excludesWeb, createdAtMs: createdAt
        )
    }
}

// MARK: D.12 Numéro de sécurité

enum E2EEV2SafetyNumber {
    static let iterations = 5_200

    /// Les 30 chiffres d'une personne.
    static func digits(uikX963: Data, userId: String) -> String {
        var hash = Data(SHA512.hash(data: Data("SQ-E2EE-V2-SAFETY\n1\n".utf8) + uikX963 + Data(userId.utf8)))
        for _ in 0..<iterations {
            hash = Data(SHA512.hash(data: hash + uikX963))
        }
        let bytes = Array(hash.prefix(30))
        return stride(from: 0, to: 30, by: 5).map { start -> String in
            let chunk = bytes[start..<(start + 5)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let value = chunk % 100_000
            let text = String(value)
            return String(repeating: "0", count: 5 - text.count) + text
        }.joined()
    }

    /// Les 60 chiffres affichés pour deux personnes, dans l'ordre des `userId`.
    static func pair(
        userA: String, uikA: Data,
        userB: String, uikB: Data
    ) -> String {
        let first = (userId: userA, digits: digits(uikX963: uikA, userId: userA))
        let second = (userId: userB, digits: digits(uikX963: uikB, userId: userB))
        let ordered = Array(first.userId.utf8).lexicographicallyPrecedes(Array(second.userId.utf8))
            ? [first, second] : [second, first]
        return ordered.map(\.digits).joined()
    }

    static func grouped(_ sixtyDigits: String) -> [String] {
        stride(from: 0, to: sixtyDigits.count, by: 5).map { start in
            let begin = sixtyDigits.index(sixtyDigits.startIndex, offsetBy: start)
            let end = sixtyDigits.index(begin, offsetBy: 5)
            return String(sixtyDigits[begin..<end])
        }
    }

    static func qrPayload(_ sixtyDigits: String) -> String {
        "SQSN1|" + sixtyDigits
    }
}

// MARK: D.13 Approbation v2

enum E2EEV2ApprovalV2 {
    /// QR affiché par l'appareil en attente, version 3 (v0.4.5) : la plateforme
    /// fait partie de ce que l'approbateur compare, avec l'empreinte.
    struct QR: Equatable, Sendable {
        static let version = "3"

        let approvalId: String
        let pendingDeviceId: String
        let platform: String
        let fingerprint: String
        let challengeB64Url: String
        let expiresAtMs: Int64

        var payload: String {
            [
                "SQE2EE2", Self.version, approvalId, pendingDeviceId, platform, fingerprint, challengeB64Url,
                String(expiresAtMs),
            ].joined(separator: "|")
        }

        /// Lecture stricte : exactement 8 champs, version 3 seulement, plateforme
        /// de l'ensemble fermé (D.2), sans normalisation.
        static func parse(_ payload: String) -> QR? {
            let f = payload.components(separatedBy: "|")
            guard f.count == 8, f[0] == "SQE2EE2", f[1] == version,
                  E2EEV2Canonical.isOpaque(f[2]), E2EEV2Canonical.isOpaque(f[3]),
                  E2EEV2DeviceCertificate.platforms.contains(f[4]),
                  E2EEV2ApprovalV2.isDigest(f[5]), E2EEV2ApprovalV2.isDigest(f[6]),
                  E2EEV2Canonical.isDecimal(f[7]), let expiresAtMs = Int64(f[7]) else {
                return nil
            }
            return QR(
                approvalId: f[2], pendingDeviceId: f[3], platform: f[4], fingerprint: f[5],
                challengeB64Url: f[6], expiresAtMs: expiresAtMs
            )
        }
    }

    /// Code de comparaison à 6 chiffres, calculé des deux côtés. Il couvre la
    /// plateforme du nouvel appareil (v0.4.5).
    static func sas(
        userId: String,
        pendingDeviceId: String,
        platform: String,
        fingerprint: String,
        approvalId: String,
        challengeB64Url: String
    ) -> String {
        let hash = Data(SHA256.hash(data: E2EEV2Canonical.line([
            "SQ-E2EE-V2-APPROVAL-SAS", "2", userId, pendingDeviceId, platform, fingerprint, approvalId,
            challengeB64Url,
        ])))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let text = String(value)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// 32 octets en base64url canonique, sans bourrage.
    static func isDigest(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$"#, options: .regularExpression) != nil
    }
}

// MARK: D.14 Réinitialisation d'identité

struct E2EEV2IdentityReset: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-IDENTITY-RESET"
    static let objectionTag = "SQ-E2EE-V2-IDENTITY-RESET-OBJECTION"
    static let delayMs: Int64 = 72 * 60 * 60 * 1_000

    let userId: String
    let newUikB64: String
    let previousUikFingerprint: String
    let requestedAtMs: Int64

    var effectiveAtMs: Int64 { requestedAtMs + Self.delayMs }

    var canonical: String {
        [
            Self.tag, "1", userId, newUikB64, previousUikFingerprint, String(requestedAtMs),
            String(effectiveAtMs),
        ].joined(separator: "\n")
    }

    static func previousFingerprint(of previousUik: Data?) -> String {
        previousUik.map { E2EEV2Canonical.sha256B64URL($0) } ?? "-"
    }

    static func objectionCanonical(userId: String, newUikB64: String, objectingDeviceId: String, objectedAtMs: Int64) -> String {
        [objectionTag, "1", userId, newUikB64, objectingDeviceId, String(objectedAtMs)].joined(separator: "\n")
    }

    /// Vérifie la signature par la nouvelle UIK et l'écart de 72 heures.
    static func verify(_ signed: E2EEV2SignedString) throws -> E2EEV2IdentityReset {
        guard let f = E2EEV2Canonical.split(signed.canonical, tag: tag, version: "1", fieldCount: 7),
              E2EEV2Canonical.isOpaque(f[2]),
              E2EEV2Canonical.isX963PublicKey(f[3]),
              let keyData = Data(base64Encoded: f[3]),
              let newUik = try? P256.Signing.PublicKey(x963Representation: keyData),
              E2EEV2Canonical.isDecimal(f[5]), let requested = Int64(f[5]), requested < Int64(1) << 53,
              E2EEV2Canonical.isDecimal(f[6]), let effective = Int64(f[6]),
              effective == requested + delayMs else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard signed.verify(with: newUik) else { throw E2EEV2TrustFormatError.invalidSignature }
        return E2EEV2IdentityReset(userId: f[2], newUikB64: f[3], previousUikFingerprint: f[4], requestedAtMs: requested)
    }
}
