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
