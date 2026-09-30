import CryptoKit
import Foundation

/// §2.1 : la clé d'identité de compte (UIK). Créée sur le premier appareil,
/// transmise chiffrée aux appareils approuvés (D.1), gardée seulement par les
/// appareils certifiés du compte. C'est une clé logicielle, puisqu'elle
/// circule : au repos, le trousseau la chiffre par la clé matérielle de
/// l'appareil (classe `WhenUnlockedThisDeviceOnly`, jamais synchronisée), comme
/// les clés d'appareil, dans le coffre E2EE du compte.
final class E2EEV2AccountIdentityStore: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case alreadyExists
        case invalidRecord
        case otherAccount
    }

    static func key(ownerNamespace: String) -> String { "uik-v1:\(ownerNamespace)" }

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    func load(ownerNamespace: String) throws -> P256.Signing.PrivateKey? {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard let raw = try tokenStore.string(for: Self.key(ownerNamespace: ownerNamespace)) else { return nil }
        guard let data = Data(base64Encoded: raw),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw Failure.invalidRecord
        }
        return key
    }

    /// Premier appareil du compte : une nouvelle UIK, jamais par-dessus une autre.
    func create(ownerNamespace: String) throws -> P256.Signing.PrivateKey {
        guard try load(ownerNamespace: ownerNamespace) == nil else { throw Failure.alreadyExists }
        let key = P256.Signing.PrivateKey()
        try install(key, ownerNamespace: ownerNamespace)
        return key
    }

    /// Appareil approuvé : l'UIK reçue chiffrée à l'approbation (D.1).
    func install(_ key: P256.Signing.PrivateKey, ownerNamespace: String) throws {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        try tokenStore.set(
            key.rawRepresentation.base64EncodedString(),
            for: Self.key(ownerNamespace: ownerNamespace),
            accessibility: .whenUnlocked
        )
    }
}

/// Objets signés qui accompagnent le bootstrap du premier appareil (E.1) :
/// certificat et liste v1 signés par l'UIK, document de capacités signé par
/// l'appareil. Ils se vérifient comme ceux de n'importe quel contact.
enum E2EEV2InitialTrust {
    struct Artifacts: Equatable, Sendable {
        let accountIdentityKeyB64: String
        let certificate: E2EEV2SignedString
        let deviceList: E2EEV2SignedString
        let deviceEntries: [String]
        let capabilities: E2EEV2SignedCapabilities

        /// E.1 : les trois clés ajoutées au corps de `POST /api/e2ee/v2/bootstrap`,
        /// aux formes de l'annexe D.
        var bootstrapFields: [String: Any] {
            [
                "accountIdentityKeyB64": accountIdentityKeyB64,
                "certificate": ["certificate": certificate.canonical, "signatureB64": certificate.signatureB64],
                "deviceList": ["list": deviceList.canonical, "signatureB64": deviceList.signatureB64, "devices": deviceEntries],
            ]
        }

        /// E.1 : corps de `PUT /api/e2ee/v2/devices/{deviceId}/capabilities`.
        var capabilitiesBody: [String: Any] {
            ["document": capabilities.document, "signatureB64": capabilities.signatureB64]
        }
    }

    static func make(
        userId: String,
        device: E2EEV2DeviceDescriptor,
        uik: P256.Signing.PrivateKey,
        signWithDevice: (Data) throws -> Data,
        kinds: [String],
        features: [String],
        nowMs: Int64
    ) throws -> Artifacts {
        guard let identityKey = Data(base64Encoded: device.publicIdentityKeyB64),
              let signingKey = Data(base64Encoded: device.publicSigningKeyB64) else {
            throw E2EEV2TrustFormatError.invalidKey
        }
        let certificate = E2EEV2DeviceCertificate(
            userId: userId,
            deviceId: device.deviceId,
            keyVersion: device.keyVersion,
            identityKeyB64: device.publicIdentityKeyB64,
            signingKeyB64: device.publicSigningKeyB64,
            platform: "ios",
            createdAtMs: nowMs
        )
        // Relu avant d'être signé : jamais un certificat que les autres refuseraient.
        guard (try? E2EEV2DeviceCertificate.parse(certificate.canonical)) == certificate else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let entry = E2EEV2DeviceList.entry(
            deviceId: device.deviceId,
            keyVersion: device.keyVersion,
            platform: "ios",
            fingerprint: E2EEV2Canonical.deviceFingerprint(identityKeyX963: identityKey, signingKeyX963: signingKey)
        )
        let list = E2EEV2DeviceList.make(
            userId: userId, version: 1, previousCanonical: nil, entries: [entry], issuedAtMs: nowMs
        )
        let document = E2EEV2CapabilitiesDocument(
            userId: userId,
            deviceId: device.deviceId,
            sequence: 1,
            issuedAtMs: nowMs,
            envelopeVersions: ["2"],
            payloadVersions: ["2"],
            kinds: sortedUnique(kinds),
            features: sortedUnique(features)
        ).document
        guard (try? E2EEV2CapabilitiesDocument.parse(document: document)) != nil else {
            throw E2EEV2TrustFormatError.invalidField
        }
        let capabilitiesSignature = try signWithDevice(
            Data(E2EEV2CapabilitiesDocument.signatureCanonical(document: document).utf8)
        )
        return Artifacts(
            accountIdentityKeyB64: uik.publicKey.x963Representation.base64EncodedString(),
            certificate: try E2EEV2SignedString.sign(certificate.canonical, with: uik),
            deviceList: try E2EEV2SignedString.sign(list.canonical, with: uik),
            deviceEntries: [entry],
            capabilities: E2EEV2SignedCapabilities(
                document: document, signatureB64: capabilitiesSignature.base64EncodedString()
            )
        )
    }

    /// Ordre des octets UTF-8, sans doublon : ce qu'exige l'analyseur strict.
    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }
}

/// §2.3, D.1 et E.1 : ce que l'appareil approbateur, qui détient l'UIK, signe
/// pour un nouvel appareil du compte — son certificat, la liste suivante et
/// l'UIK chiffrée pour sa clé d'accord. Le serveur enregistre les trois
/// ensemble, ou rien.
enum E2EEV2DeviceApprovalTrust {
    enum Failure: Error, Equatable {
        /// La liste courante n'est pas signée par l'UIK de ce compte : rien
        /// n'est signé par-dessus.
        case foreignList
        /// L'approbateur ne figure pas parmi les appareils du compte.
        case approverNotListed
        case alreadyListed
        /// Les clés reçues ne sont pas celles que l'utilisateur a comparées
        /// (QR, code de proximité ou code SAS).
        case fingerprintMismatch
        case invalidDevice
        /// Le compte ne certifie pas cet appareil avec ses propres clés.
        case notCertified
    }

    struct Artifacts: Equatable, Sendable {
        let certificate: E2EEV2SignedString
        let deviceList: E2EEV2SignedString
        let deviceEntries: [String]
        let uikWrap: E2EEV2UIKWrap

        /// E.1 : les trois clés ajoutées au corps de
        /// `POST /api/e2ee/v2/device-approvals/{id}/approve`.
        var approveFields: [String: Any] {
            [
                "certificate": ["certificate": certificate.canonical, "signatureB64": certificate.signatureB64],
                "deviceList": ["list": deviceList.canonical, "signatureB64": deviceList.signatureB64, "devices": deviceEntries],
                "uikWrap": [
                    "userId": uikWrap.userId,
                    "approverDeviceId": uikWrap.approverDeviceId,
                    "newDeviceId": uikWrap.newDeviceId,
                    "uikPublicKeyB64": uikWrap.uikPublicKeyB64,
                    "ephemeralPublicKeyB64": uikWrap.ephemeralPublicKeyB64,
                    "nonceB64": uikWrap.nonceB64,
                    "aadB64": uikWrap.aadB64,
                    "wrappedUikB64": uikWrap.wrappedUikB64,
                    "signatureB64": uikWrap.signatureB64,
                ],
            ]
        }
    }

    /// Côté approbateur. `currentList` et `currentEntries` viennent du paquet
    /// de confiance de son propre compte, déjà vérifié.
    static func make(
        userId: String,
        currentList: E2EEV2SignedString,
        currentEntries: [String],
        newDevice: E2EEV2DeviceDescriptor,
        expectedFingerprint: String,
        uik: P256.Signing.PrivateKey,
        approverDeviceId: String,
        signWithApprover: (Data) throws -> Data,
        nonce: Data,
        nowMs: Int64
    ) throws -> Artifacts {
        guard let current = try? E2EEV2DeviceList.verifyWithoutChain(currentList, entries: currentEntries, uik: uik.publicKey),
              current.userId == userId else {
            throw Failure.foreignList
        }
        let listed = Set(currentEntries.compactMap { $0.components(separatedBy: "\n").first })
        guard listed.contains(approverDeviceId) else { throw Failure.approverNotListed }
        guard !listed.contains(newDevice.deviceId) else { throw Failure.alreadyListed }
        guard let identityKey = Data(base64Encoded: newDevice.publicIdentityKeyB64),
              let signingKey = Data(base64Encoded: newDevice.publicSigningKeyB64),
              let agreementKey = try? P256.KeyAgreement.PublicKey(x963Representation: identityKey) else {
            throw Failure.invalidDevice
        }
        let fingerprint = E2EEV2Canonical.deviceFingerprint(identityKeyX963: identityKey, signingKeyX963: signingKey)
        guard fingerprint == expectedFingerprint else { throw Failure.fingerprintMismatch }
        let certificate = E2EEV2DeviceCertificate(
            userId: userId,
            deviceId: newDevice.deviceId,
            keyVersion: newDevice.keyVersion,
            identityKeyB64: newDevice.publicIdentityKeyB64,
            signingKeyB64: newDevice.publicSigningKeyB64,
            platform: newDevice.platform,
            createdAtMs: nowMs
        )
        guard (try? E2EEV2DeviceCertificate.parse(certificate.canonical)) == certificate else {
            throw Failure.invalidDevice
        }
        let entries = currentEntries + [E2EEV2DeviceList.entry(
            deviceId: newDevice.deviceId, keyVersion: newDevice.keyVersion,
            platform: newDevice.platform, fingerprint: fingerprint
        )]
        let next = E2EEV2DeviceList.make(
            userId: userId, version: current.version + 1, previousCanonical: currentList.canonical,
            entries: entries, issuedAtMs: nowMs
        )
        return Artifacts(
            certificate: try E2EEV2SignedString.sign(certificate.canonical, with: uik),
            deviceList: try E2EEV2SignedString.sign(next.canonical, with: uik),
            deviceEntries: entries,
            uikWrap: try E2EEV2UIKWrapCrypto.wrap(
                uik: uik, userId: userId, approverDeviceId: approverDeviceId, newDeviceId: newDevice.deviceId,
                newDeviceAgreementKey: agreementKey, signWithApprover: signWithApprover, nonce: nonce
            )
        )
    }

    /// Côté nouvel appareil, une fois approuvé. `account` est le paquet de
    /// confiance de son propre compte, vérifié : l'UIK n'est acceptée que d'un
    /// approbateur certifié, pour un appareil que le compte certifie avec ses
    /// propres clés, et seulement si c'est l'UIK de ce compte.
    static func accept(
        _ wrap: E2EEV2UIKWrap,
        account: E2EEV2IdentityVerification.Outcome,
        userId: String,
        device: E2EEV2DeviceDescriptor,
        unwrap: (_ wrap: E2EEV2UIKWrap, _ approverSigningKey: P256.Signing.PublicKey, _ expectedUIKB64: String) throws -> P256.Signing.PrivateKey
    ) throws -> P256.Signing.PrivateKey {
        guard wrap.userId == userId, wrap.newDeviceId == device.deviceId else { throw Failure.invalidDevice }
        guard wrap.approverDeviceId != device.deviceId,
              let approverKey = account.devices.first(where: { $0.deviceId == wrap.approverDeviceId })?.signingKey else {
            throw Failure.approverNotListed
        }
        guard account.devices.contains(where: {
            $0.deviceId == device.deviceId && $0.keyVersion == device.keyVersion
                && $0.identityKeyB64 == device.publicIdentityKeyB64 && $0.signingKeyB64 == device.publicSigningKeyB64
        }) else {
            throw Failure.notCertified
        }
        return try unwrap(wrap, approverKey, account.pin.uikX963B64)
    }
}

/// §2.2, D.3 et E.1 : la liste suivante, sans l'appareil révoqué, signée par
/// l'UIK. Le serveur ne l'accepte que si elle suit la courante.
enum E2EEV2DeviceRevocationTrust {
    struct Artifacts: Equatable, Sendable {
        let deviceList: E2EEV2SignedString
        let deviceEntries: [String]

        /// E.1 : clé ajoutée au corps de `POST /api/e2ee/v2/devices/{deviceId}/revoke`.
        var revokeFields: [String: Any] {
            ["deviceList": ["list": deviceList.canonical, "signatureB64": deviceList.signatureB64, "devices": deviceEntries]]
        }
    }

    static func make(
        userId: String,
        revokedDeviceId: String,
        currentList: E2EEV2SignedString,
        currentEntries: [String],
        uik: P256.Signing.PrivateKey,
        nowMs: Int64
    ) throws -> Artifacts {
        guard let current = try? E2EEV2DeviceList.verifyWithoutChain(currentList, entries: currentEntries, uik: uik.publicKey),
              current.userId == userId else {
            throw E2EEV2DeviceApprovalTrust.Failure.foreignList
        }
        let entries = currentEntries.filter { $0.components(separatedBy: "\n").first != revokedDeviceId }
        guard entries.count == currentEntries.count - 1 else { throw E2EEV2DeviceApprovalTrust.Failure.notCertified }
        let next = E2EEV2DeviceList.make(
            userId: userId, version: current.version + 1, previousCanonical: currentList.canonical,
            entries: entries, issuedAtMs: nowMs
        )
        return Artifacts(deviceList: try E2EEV2SignedString.sign(next.canonical, with: uik), deviceEntries: entries)
    }
}
