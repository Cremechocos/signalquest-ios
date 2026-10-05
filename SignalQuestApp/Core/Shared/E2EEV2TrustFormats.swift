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
        // Base64 canonique : `Data(base64Encoded:)` accepte des variantes.
        guard let der = Data(base64Encoded: signatureB64), der.base64EncodedString() == signatureB64 else { return false }
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

    /// Même contrôle sans le chaînage, que l'appelant vérifie à part : maillon
    /// par maillon depuis sa version épinglée (D.3, `verifyLink`), ou rien au
    /// premier contact.
    static func verifyWithoutChain(
        _ signed: E2EEV2SignedString,
        entries: [String],
        uik: P256.Signing.PublicKey
    ) throws -> E2EEV2DeviceList {
        try verify(signed, entries: entries, uik: uik, expectedPrevious: nil)
    }

    /// Maillon intermédiaire de la chaîne (D.3, E.1) : servi sans ses lignes,
    /// il ne prouve que sa signature, son numéro et son chaînage. Seule la
    /// liste courante, avec ses lignes, fait croire des appareils.
    static func verifyLink(
        _ signed: E2EEV2SignedString,
        uik: P256.Signing.PublicKey,
        previousCanonical: String
    ) throws -> E2EEV2DeviceList {
        guard signed.verify(with: uik) else { throw E2EEV2TrustFormatError.invalidSignature }
        guard let f = E2EEV2Canonical.split(signed.canonical, tag: tag, version: "1", fieldCount: 8),
              E2EEV2Canonical.isOpaque(f[2]),
              E2EEV2Canonical.isDecimal(f[3]), let version = Int(f[3]), (2..<Int(Int32.max)).contains(version),
              E2EEV2Canonical.isDecimal(f[5]), let count = Int(f[5]),
              E2EEV2ApprovalV2.isDigest(f[6]),
              E2EEV2Canonical.isDecimal(f[7]), let issuedAt = Int64(f[7]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard f[4] == digest(of: previousCanonical) else { throw E2EEV2TrustFormatError.digestMismatch }
        return E2EEV2DeviceList(
            userId: f[2], version: version, previousListDigest: f[4], deviceCount: count,
            devicesDigest: f[6], issuedAtMs: issuedAt
        )
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
              let number = E2EEV2Canonical.sequenceNumber(f[3]),
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

    /// `{"change": "<chaîne>", "signatureB64": "…"}` (D.4).
    static func json(_ signed: E2EEV2SignedString) -> E2EEV2JSON {
        .object(["change": .string(signed.canonical), "signatureB64": .string(signed.signatureB64)])
    }

    static func signed(from json: E2EEV2JSON) -> E2EEV2SignedString? {
        guard let object = json.objectValue, Set(object.keys) == ["change", "signatureB64"],
              let change = object["change"]?.stringValue,
              let signature = object["signatureB64"]?.stringValue else { return nil }
        return E2EEV2SignedString(canonical: change, signatureB64: signature)
    }
}

/// Ce que fixe la chaîne des changements signés d'une conversation (D.4).
struct E2EEV2MembershipState: Equatable, Sendable {
    var members: Set<String> = []
    var admins: Set<String> = []
    var excludesWeb = false
    /// Dernier changement accepté, auquel le suivant se chaîne.
    var lastCanonical: String?
    var changeNumber = 0
    /// Appareil qui a signé la genèse.
    var genesisActor: E2EEV2MembershipChain.Actor?
}

/// Genèse et relecture de la chaîne d'appartenance (D.4, §2.5, §14.2).
enum E2EEV2MembershipChain {
    struct Actor: Equatable, Sendable {
        let userId: String
        let deviceId: String
    }

    /// Un `ADD` par membre, auteur compris, dans l'ordre des `userId` (octets
    /// UTF-8) ; puis, dans un groupe, un `ROLE_ADMIN` par administrateur : le
    /// créateur, ou les administrateurs v1 d'une migration (§14.2) ; enfin,
    /// si les navigateurs sont exclus dès l'époque 1, `EXCLUDE_WEB_ON`.
    static func genesis(
        conversationId: String,
        memberIds: [String],
        adminIds: [String],
        isGroup: Bool,
        excludesWeb: Bool = false,
        actor: Actor,
        createdAtMs: Int64
    ) throws -> [E2EEV2MembershipChange] {
        let members = memberIds.sorted(by: precedes), admins = adminIds.sorted(by: precedes)
        guard Set(members).count == members.count, Set(admins).count == admins.count,
              members.contains(actor.userId), Set(admins).isSubset(of: Set(members)),
              isGroup ? !admins.isEmpty : (admins.isEmpty && members.count == 2),
              ([conversationId, actor.deviceId] + members).allSatisfy(E2EEV2Canonical.isOpaque) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        var changes: [E2EEV2MembershipChange] = []
        let steps = members.map { ("ADD", $0) } + admins.map { ("ROLE_ADMIN", $0) }
            + (excludesWeb ? [("EXCLUDE_WEB_ON", "-")] : [])
        for (action, target) in steps {
            changes.append(E2EEV2MembershipChange(
                conversationId: conversationId, changeNumber: changes.count + 1, action: action,
                targetUserId: target, actorUserId: actor.userId, actorDeviceId: actor.deviceId,
                previousChangeDigest: changes.last.map { E2EEV2MembershipChange.digest(of: $0.canonical) } ?? "-",
                createdAtMs: createdAtMs + Int64(changes.count)
            ))
        }
        return changes
    }

    /// Applique des changements signés, dans l'ordre, à l'état connu. La
    /// genèse (changements 1 à `genesisLength`, que fixe l'époque 1) vient d'un
    /// seul appareil et précède tout administrateur ; la suite respecte les
    /// autorisations de D.4. Les `verifiedCount` premiers changements, déjà
    /// vérifiés quand l'appareil les a gardés, ne sont pas revérifiés contre
    /// l'annuaire du jour : un auteur révoqué depuis ne casse pas la relecture.
    static func apply(
        _ signed: [E2EEV2SignedString],
        to state: E2EEV2MembershipState = E2EEV2MembershipState(),
        conversationId: String,
        isGroup: Bool,
        genesisLength: Int,
        verifiedCount: Int = 0,
        signingKey: (_ userId: String, _ deviceId: String) -> P256.Signing.PublicKey?
    ) throws -> E2EEV2MembershipState {
        guard genesisLength >= 1 else { throw E2EEV2TrustFormatError.invalidField }
        var state = state
        for item in signed {
            let change = try E2EEV2MembershipChange.parse(item.canonical, previousCanonical: state.lastCanonical)
            guard change.conversationId == conversationId, change.changeNumber == state.changeNumber + 1 else {
                throw E2EEV2TrustFormatError.invalidField
            }
            if change.changeNumber > verifiedCount {
                guard let key = signingKey(change.actorUserId, change.actorDeviceId), item.verify(with: key) else {
                    throw E2EEV2TrustFormatError.invalidSignature
                }
            }
            if change.changeNumber <= genesisLength {
                try applyGenesis(change, to: &state, isGroup: isGroup)
                if change.changeNumber == genesisLength { try checkGenesis(state, isGroup: isGroup) }
            } else {
                try applyRule(change, to: &state, isGroup: isGroup)
            }
            state.lastCanonical = item.canonical
            state.changeNumber = change.changeNumber
        }
        return state
    }

    private static func applyGenesis(
        _ change: E2EEV2MembershipChange,
        to state: inout E2EEV2MembershipState,
        isGroup: Bool
    ) throws {
        let actor = Actor(userId: change.actorUserId, deviceId: change.actorDeviceId)
        if change.changeNumber == 1 { state.genesisActor = actor }
        guard actor == state.genesisActor else { throw E2EEV2TrustFormatError.invalidField }
        let target = change.targetUserId
        switch change.action {
        case "ADD" where state.admins.isEmpty && !state.excludesWeb
            && state.members.allSatisfy({ precedes($0, target) }):
            state.members.insert(target)
        case "ROLE_ADMIN" where isGroup && !state.excludesWeb && state.members.contains(target)
            && state.admins.allSatisfy({ precedes($0, target) }):
            state.admins.insert(target)
        // Exclusion des navigateurs dès l'époque 1 : en dernier.
        case "EXCLUDE_WEB_ON" where !state.excludesWeb
            && (isGroup ? !state.admins.isEmpty : state.members.count == 2):
            state.excludesWeb = true
        default:
            throw E2EEV2TrustFormatError.invalidField
        }
    }

    private static func checkGenesis(_ state: E2EEV2MembershipState, isGroup: Bool) throws {
        guard let actor = state.genesisActor, state.members.contains(actor.userId),
              isGroup ? !state.admins.isEmpty : (state.admins.isEmpty && state.members.count == 2) else {
            throw E2EEV2TrustFormatError.invalidField
        }
    }

    private static func applyRule(
        _ change: E2EEV2MembershipChange,
        to state: inout E2EEV2MembershipState,
        isGroup: Bool
    ) throws {
        let actor = change.actorUserId, target = change.targetUserId
        let isAdmin = state.admins.contains(actor)
        guard state.members.contains(actor) else { throw E2EEV2TrustFormatError.invalidField }
        switch change.action {
        case "ADD" where isGroup && isAdmin && !state.members.contains(target):
            state.members.insert(target)
        case "REMOVE" where isGroup && isAdmin && target != actor && state.members.contains(target):
            state.members.remove(target)
            state.admins.remove(target)
        case "LEAVE":
            state.members.remove(actor)
            state.admins.remove(actor)
        case "ROLE_ADMIN" where isGroup && isAdmin && state.members.contains(target):
            state.admins.insert(target)
        case "ROLE_MEMBER" where isGroup && isAdmin && state.admins.contains(target):
            state.admins.remove(target)
        // En tête-à-tête, l'exclusion des navigateurs est ouverte aux deux membres.
        case "EXCLUDE_WEB_ON" where !isGroup || isAdmin, "EXCLUDE_WEB_OFF" where !isGroup || isAdmin:
            state.excludesWeb = change.action == "EXCLUDE_WEB_ON"
        default:
            throw E2EEV2TrustFormatError.invalidField
        }
    }

    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
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
              kinds.allSatisfy({ $0.range(of: #"^[A-Z][A-Z_]{0,31}\z"#, options: .regularExpression) != nil }),
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

/// Manifeste d'époque, format 2 (v0.4.7) : la liste des destinataires et
/// l'état d'appartenance sur lequel elle repose.
struct E2EEV2EpochManifest: Equatable, Sendable {
    static let tag = "SQ-E2EE-V2-EPOCH-MANIFEST"
    static let version = "2"
    static let recipientsTag = "SQ-E2EE-V2-EPOCH-RECIPIENTS"
    /// Une époque vise au plus 500 appareils (§3.1).
    static let maxRecipients = 500

    let conversationId: String
    let epochNumber: Int
    let creatorUserId: String
    let creatorDeviceId: String
    let keyCommitmentB64: String
    let recipientCount: Int
    let recipientsDigest: String
    let excludesWeb: Bool
    /// Dernier changement d'appartenance pris en compte ; pour l'époque 1, la
    /// fin de la genèse.
    let membershipChangeNumber: Int
    /// `previousChangeDigest` qu'aurait le changement suivant.
    let membershipDigest: String
    let createdAtMs: Int64

    /// Ligne de destinataire, lue strictement : quatre champs, plateforme de
    /// l'ensemble fermé (D.2), empreinte au format d'un condensat.
    struct Recipient: Hashable, Sendable {
        let userId: String
        let deviceId: String
        let platform: String
        let fingerprint: String

        var line: String { E2EEV2EpochManifest.recipient(userId: userId, deviceId: deviceId, platform: platform, fingerprint: fingerprint) }

        static func parse(_ line: String) -> Recipient? {
            let f = line.components(separatedBy: "\n")
            guard f.count == 4, E2EEV2Canonical.isOpaque(f[0]), E2EEV2Canonical.isOpaque(f[1]),
                  E2EEV2DeviceCertificate.platforms.contains(f[2]), E2EEV2ApprovalV2.isDigest(f[3]) else {
                return nil
            }
            return Recipient(userId: f[0], deviceId: f[1], platform: f[2], fingerprint: f[3])
        }
    }

    static func recipient(userId: String, deviceId: String, platform: String, fingerprint: String) -> String {
        [userId, deviceId, platform, fingerprint].joined(separator: "\n")
    }

    var canonical: String {
        [
            Self.tag, Self.version, conversationId, String(epochNumber), creatorUserId, creatorDeviceId,
            keyCommitmentB64, String(recipientCount), recipientsDigest, excludesWeb ? "1" : "0",
            String(membershipChangeNumber), membershipDigest, String(createdAtMs),
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
        membershipChangeNumber: Int,
        membershipDigest: String,
        createdAtMs: Int64
    ) -> E2EEV2EpochManifest {
        E2EEV2EpochManifest(
            conversationId: conversationId, epochNumber: epochNumber, creatorUserId: creatorUserId,
            creatorDeviceId: creatorDeviceId, keyCommitmentB64: keyCommitmentB64,
            recipientCount: recipients.count,
            recipientsDigest: E2EEV2Canonical.listDigest(tag: recipientsTag, lines: recipients),
            excludesWeb: excludesWeb, membershipChangeNumber: membershipChangeNumber,
            membershipDigest: membershipDigest, createdAtMs: createdAtMs
        )
    }

    /// Signature, 13 champs, lignes strictes, un appareil par ligne, condensat
    /// de la liste ; aucun navigateur quand ils sont exclus. Toute autre
    /// version du format est refusée.
    static func verify(
        _ signed: E2EEV2SignedString,
        recipients: [String],
        creatorSigningKey: P256.Signing.PublicKey
    ) throws -> E2EEV2EpochManifest {
        guard signed.verify(with: creatorSigningKey) else { throw E2EEV2TrustFormatError.invalidSignature }
        guard let f = E2EEV2Canonical.split(signed.canonical, tag: tag, version: version, fieldCount: 13),
              E2EEV2Canonical.isOpaque(f[2]),
              let epochNumber = E2EEV2Canonical.sequenceNumber(f[3]),
              E2EEV2Canonical.isOpaque(f[4]), E2EEV2Canonical.isOpaque(f[5]),
              let commitment = Data(base64Encoded: f[6]), commitment.count == 32,
              commitment.base64EncodedString() == f[6],
              E2EEV2Canonical.isDecimal(f[7]), let count = Int(f[7]), (1...maxRecipients).contains(count),
              f[9] == "0" || f[9] == "1",
              let membershipNumber = E2EEV2Canonical.sequenceNumber(f[10]),
              E2EEV2ApprovalV2.isDigest(f[11]),
              E2EEV2Canonical.isDecimal(f[12]), let createdAt = Int64(f[12]) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let excludesWeb = f[9] == "1"
        let lines = recipients.compactMap(Recipient.parse)
        guard lines.count == recipients.count, Set(lines.map(\.deviceId)).count == lines.count,
              !(excludesWeb && lines.contains { $0.platform == "web" }) else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard count == recipients.count,
              f[8] == E2EEV2Canonical.listDigest(tag: recipientsTag, lines: recipients) else {
            throw E2EEV2TrustFormatError.digestMismatch
        }
        return E2EEV2EpochManifest(
            conversationId: f[2], epochNumber: epochNumber, creatorUserId: f[4], creatorDeviceId: f[5],
            keyCommitmentB64: f[6], recipientCount: count, recipientsDigest: f[8],
            excludesWeb: excludesWeb, membershipChangeNumber: membershipNumber, membershipDigest: f[11],
            createdAtMs: createdAt
        )
    }

    /// `{"manifest": "<chaîne>", "signatureB64": "…", "recipients": ["<ligne>", …]}` (D.6).
    static func json(_ signed: E2EEV2SignedString, recipients: [String]) -> E2EEV2JSON {
        .object([
            "manifest": .string(signed.canonical),
            "signatureB64": .string(signed.signatureB64),
            "recipients": .array(recipients.map(E2EEV2JSON.string)),
        ])
    }

    static func signed(from json: E2EEV2JSON) -> (manifest: E2EEV2SignedString, recipients: [String])? {
        guard let object = json.objectValue, Set(object.keys) == ["manifest", "signatureB64", "recipients"],
              let manifest = object["manifest"]?.stringValue,
              let signature = object["signatureB64"]?.stringValue,
              let items = object["recipients"]?.arrayValue else { return nil }
        let recipients = items.compactMap(\.stringValue)
        guard recipients.count == items.count else { return nil }
        return (E2EEV2SignedString(canonical: manifest, signatureB64: signature), recipients)
    }
}

/// Ce qu'engage une époque (§3.5, v0.4.7) : l'état d'appartenance sur lequel
/// repose sa liste de destinataires et, pour l'époque 1, la genèse.
enum E2EEV2EpochBinding {
    enum Failure: Error, Equatable {
        /// N° ou condensat différent de la chaîne relue jusqu'à ce n°.
        case membershipMismatch
        /// N° inférieur à celui d'une époque déjà acceptée.
        case membershipRegressed
        /// Époque 1 signée par un autre appareil que celui de la genèse.
        case genesisMismatch
        case creatorNotMember
        case recipientNotMember
        case excludesWebMismatch
    }

    /// `state` : la chaîne relue jusqu'au n° `membershipChangeNumber` du
    /// manifeste. Une chaîne locale plus courte se synchronise d'abord ; un
    /// n° égal à celui de l'époque précédente reste permis.
    static func check(
        _ manifest: E2EEV2EpochManifest,
        recipients: [String],
        state: E2EEV2MembershipState,
        genesisLength: Int,
        previousMembershipChangeNumber: Int?
    ) throws {
        guard state.changeNumber == manifest.membershipChangeNumber, let last = state.lastCanonical,
              E2EEV2MembershipChange.digest(of: last) == manifest.membershipDigest else {
            throw Failure.membershipMismatch
        }
        // L'époque 1 repose sur toute la genèse, et rien ne repose sur une
        // genèse partielle (par exemple avant son EXCLUDE_WEB_ON final).
        guard manifest.epochNumber == 1
            ? manifest.membershipChangeNumber == genesisLength
            : manifest.membershipChangeNumber >= genesisLength else {
            throw Failure.membershipMismatch
        }
        if let previous = previousMembershipChangeNumber, manifest.membershipChangeNumber < previous {
            throw Failure.membershipRegressed
        }
        if manifest.epochNumber == 1,
           state.genesisActor != E2EEV2MembershipChain.Actor(userId: manifest.creatorUserId, deviceId: manifest.creatorDeviceId) {
            throw Failure.genesisMismatch
        }
        guard state.members.contains(manifest.creatorUserId) else { throw Failure.creatorNotMember }
        let lines = recipients.compactMap(E2EEV2EpochManifest.Recipient.parse)
        guard lines.count == recipients.count, lines.allSatisfy({ state.members.contains($0.userId) }) else {
            throw Failure.recipientNotMember
        }
        guard manifest.excludesWeb == state.excludesWeb else { throw Failure.excludesWebMismatch }
    }

    /// Époque 1 : la genèse est exactement les changements 1 à N du manifeste.
    static func verifyGenesis(
        _ manifest: E2EEV2EpochManifest,
        recipients: [String],
        chain: [E2EEV2SignedString],
        isGroup: Bool,
        signingKey: (_ userId: String, _ deviceId: String) -> P256.Signing.PublicKey?
    ) throws -> E2EEV2MembershipState {
        guard manifest.epochNumber == 1, chain.count == manifest.membershipChangeNumber else {
            throw Failure.membershipMismatch
        }
        let state = try E2EEV2MembershipChain.apply(
            chain, conversationId: manifest.conversationId, isGroup: isGroup,
            genesisLength: manifest.membershipChangeNumber, signingKey: signingKey
        )
        try check(
            manifest, recipients: recipients, state: state, genesisLength: manifest.membershipChangeNumber,
            previousMembershipChangeNumber: nil
        )
        return state
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

    /// SAS v3 (v0.4.6), première étape : l'appareil en attente met son aléa
    /// en gage avant de connaître celui de l'approbateur.
    static func sasCommitment(
        userId: String,
        approvalId: String,
        pendingDeviceId: String,
        platform: String,
        fingerprint: String,
        pendingNonceB64Url: String
    ) -> String {
        E2EEV2Canonical.sha256B64URL(E2EEV2Canonical.line([
            "SQ-E2EE-V2-SAS-COMMIT", "1", userId, approvalId, pendingDeviceId, platform, fingerprint,
            pendingNonceB64Url,
        ]))
    }

    /// Code de comparaison à 6 chiffres, calculé des deux côtés une fois les
    /// deux aléas connus et la mise en gage vérifiée. Il couvre la plateforme.
    static func sas(
        userId: String,
        pendingDeviceId: String,
        platform: String,
        fingerprint: String,
        approvalId: String,
        pendingNonceB64Url: String,
        approverNonceB64Url: String
    ) -> String {
        let hash = Data(SHA256.hash(data: E2EEV2Canonical.line([
            "SQ-E2EE-V2-APPROVAL-SAS", "3", userId, pendingDeviceId, platform, fingerprint, approvalId,
            pendingNonceB64Url, approverNonceB64Url,
        ])))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let text = String(value)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// Code de proximité v2 (v0.4.6) : 80 bits liés à l'empreinte et à la
    /// plateforme, en 16 caractères base32 Crockford.
    static func proximityCode(
        userId: String,
        approvalId: String,
        pendingDeviceId: String,
        platform: String,
        fingerprint: String,
        challengeB64Url: String
    ) -> String {
        let hash = Data(SHA256.hash(data: E2EEV2Canonical.line([
            "SQ-E2EE-V2-PROXIMITY", "1", userId, approvalId, pendingDeviceId, platform, fingerprint,
            challengeB64Url,
        ])))
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = hash.prefix(10).reduce(into: [UInt8]()) { result, byte in
            for shift in stride(from: 7, through: 0, by: -1) { result.append((byte >> UInt8(shift)) & 1) }
        }
        var code = ""
        while !bits.isEmpty {
            let chunk = bits.prefix(5).reduce(0) { ($0 << 1) | Int($1) }
            code.append(alphabet[chunk])
            bits.removeFirst(5)
        }
        return code
    }

    /// Comparaison d'une saisie au code attendu : majuscules, sans espaces ni
    /// tirets, en temps constant.
    static func proximityMatches(_ input: String, expected: String) -> Bool {
        let typed = Array(input.uppercased().filter { !$0.isWhitespace && $0 != "-" }.utf8)
        let reference = Array(expected.utf8)
        guard typed.count == reference.count else { return false }
        return zip(typed, reference).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// 32 octets en base64url canonique, sans bourrage.
    static func isDigest(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\z"#, options: .regularExpression) != nil
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
              f[4] == "-" || E2EEV2ApprovalV2.isDigest(f[4]),
              E2EEV2Canonical.isDecimal(f[5]), let requested = Int64(f[5]), requested < Int64(1) << 53,
              E2EEV2Canonical.isDecimal(f[6]), let effective = Int64(f[6]),
              effective == requested + delayMs else {
            throw E2EEV2TrustFormatError.invalidField
        }
        guard signed.verify(with: newUik) else { throw E2EEV2TrustFormatError.invalidSignature }
        return E2EEV2IdentityReset(userId: f[2], newUikB64: f[3], previousUikFingerprint: f[4], requestedAtMs: requested)
    }
}
