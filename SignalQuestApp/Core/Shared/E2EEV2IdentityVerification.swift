import Foundation
import CryptoKit

// Chaîne de confiance du jalon A (spec E2EE §2, §12 et annexe E.1) : du paquet
// servi par le serveur aux appareils certifiés d'un compte. Rien de ce paquet
// n'est cru avant d'avoir été vérifié jusqu'à l'UIK épinglée.

/// Document de capacités tel qu'il voyage : le JSON canonique et la signature
/// de l'appareil sur `E2EEV2CapabilitiesDocument.signatureCanonical`.
struct E2EEV2SignedCapabilities: Equatable, Sendable {
    let document: String
    let signatureB64: String
}

/// E.1 : `GET /api/e2ee/v2/users/{userId}/identity`.
struct E2EEV2IdentityBundle: Equatable, Sendable {
    let userId: String
    let uikX963B64: String
    let deviceList: E2EEV2SignedString
    /// Lignes `<deviceId>\n<keyVersion>\n<platform>\n<empreinte>` (D.3).
    let deviceEntries: [String]
    let certificates: [E2EEV2SignedString]
    let capabilities: [E2EEV2SignedCapabilities]
    let hasPendingIdentityReset: Bool
    /// Listes N+1 à M−1 depuis la version épinglée N (E.1), dans l'ordre.
    var deviceListChain: [E2EEV2SignedString] = []
    /// Page suivante de la chaîne, quand il en reste.
    var nextSinceVersion: Int?

    /// Lecture stricte des objets signés ; une clé de premier niveau inconnue
    /// est ignorée (ajout compatible), une clé attendue absente refuse tout.
    static func parse(_ object: [String: Any], userId: String) -> E2EEV2IdentityBundle? {
        guard E2EEV2Canonical.isOpaque(userId),
              let uik = object["accountIdentityKeyB64"] as? String,
              let list = object["deviceList"] as? [String: Any],
              Set(list.keys) == ["list", "signatureB64", "devices"],
              let listCanonical = list["list"] as? String,
              let listSignature = list["signatureB64"] as? String,
              let entries = list["devices"] as? [String],
              let certificates = object["certificates"] as? [[String: Any]],
              let capabilities = object["capabilities"] as? [[String: Any]],
              object.keys.contains("pendingIdentityReset") else { return nil }
        var signedCertificates: [E2EEV2SignedString] = []
        for item in certificates {
            guard Set(item.keys) == ["certificate", "signatureB64"],
                  let certificate = item["certificate"] as? String,
                  let signature = item["signatureB64"] as? String else { return nil }
            signedCertificates.append(E2EEV2SignedString(canonical: certificate, signatureB64: signature))
        }
        var signedCapabilities: [E2EEV2SignedCapabilities] = []
        for item in capabilities {
            guard Set(item.keys) == ["document", "signatureB64"],
                  let document = item["document"] as? String,
                  let signature = item["signatureB64"] as? String else { return nil }
            signedCapabilities.append(E2EEV2SignedCapabilities(document: document, signatureB64: signature))
        }
        let reset = object["pendingIdentityReset"]
        guard reset is NSNull || reset is [String: Any] else { return nil }
        // Chaîne des listes (E.1) : absente, elle est vide ; la vérification
        // refuse alors tout saut de version.
        var chain: [E2EEV2SignedString] = []
        if let links = object["deviceListChain"] {
            guard let items = links as? [[String: Any]], items.count <= 50 else { return nil }
            for item in items {
                guard Set(item.keys) == ["list", "signatureB64"],
                      let list = item["list"] as? String,
                      let signature = item["signatureB64"] as? String else { return nil }
                chain.append(E2EEV2SignedString(canonical: list, signatureB64: signature))
            }
        }
        var next: Int?
        if let value = object["nextSinceVersion"], !(value is NSNull) {
            guard let text = value as? String, let number = E2EEV2Canonical.sequenceNumber(text) else { return nil }
            next = number
        }
        return E2EEV2IdentityBundle(
            userId: userId,
            uikX963B64: uik,
            deviceList: E2EEV2SignedString(canonical: listCanonical, signatureB64: listSignature),
            deviceEntries: entries,
            certificates: signedCertificates,
            capabilities: signedCapabilities,
            hasPendingIdentityReset: reset is [String: Any],
            deviceListChain: chain,
            nextSinceVersion: next
        )
    }
}

/// Appareil dont le certificat se vérifie jusqu'à l'UIK épinglée de son
/// propriétaire et figure dans sa liste courante (§2.2, règle normative).
struct E2EEV2CertifiedDevice: Equatable, Sendable {
    let userId: String
    let deviceId: String
    let keyVersion: Int
    let platform: String
    let identityKeyB64: String
    let signingKeyB64: String
    let fingerprint: String
    /// Dernier document de capacités valide de l'appareil, s'il en a un.
    let capabilities: E2EEV2CapabilitiesDocument?

    var signingKey: P256.Signing.PublicKey? {
        Data(base64Encoded: signingKeyB64).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }

    /// Mis à l'écart (§12) : pas de document de capacités de moins de 90 jours
    /// (à 90 jours pile, il l'est déjà), ou un document daté de plus de 10 min
    /// dans le futur, qui ne vieillirait jamais (v0.4.16). Il sort de
    /// l'intersection et des nouvelles époques.
    func isSidelined(nowMs: Int64) -> Bool {
        guard let capabilities else { return true }
        return nowMs - capabilities.issuedAtMs >= E2EEV2IdentityVerification.capabilityFreshnessMs
            || capabilities.issuedAtMs - nowMs > E2EEV2IdentityVerification.capabilityFutureSkewMs
    }

    func supports(_ feature: String, nowMs: Int64) -> Bool {
        !isSidelined(nowMs: nowMs) && capabilities?.features.contains(feature) == true
    }
}

/// Ce que cet appareil retient d'un compte entre deux lectures : l'UIK
/// épinglée à la première rencontre, la dernière liste vue (jamais de retour
/// en arrière) et la dernière séquence de capacités de chaque appareil.
struct E2EEV2TrustPin: Codable, Equatable, Sendable {
    let uikX963B64: String
    let listVersion: Int
    let listCanonical: String
    let capabilitySequences: [String: Int]
    /// Numéro de sécurité comparé explicitement (§2.1) ; sinon, confiance à la
    /// première utilisation.
    let verified: Bool

    func with(verified: Bool) -> E2EEV2TrustPin {
        E2EEV2TrustPin(
            uikX963B64: uikX963B64, listVersion: listVersion, listCanonical: listCanonical,
            capabilitySequences: capabilitySequences, verified: verified
        )
    }
}

enum E2EEV2IdentityVerification {
    static let capabilityFreshnessMs: Int64 = 90 * 24 * 60 * 60 * 1_000
    /// Avance d'horloge tolérée sur `issuedAtMs` (v0.4.16, comme le serveur).
    static let capabilityFutureSkewMs: Int64 = 10 * 60 * 1_000

    enum Failure: Error, Equatable {
        case malformed
        /// L'UIK n'est plus celle épinglée : rien n'est cru tant que
        /// l'utilisateur n'a pas vu le changement (numéro de sécurité).
        case uikChanged
        case invalidDeviceList
        /// Liste plus ancienne que la dernière vue, ou une autre liste à la
        /// même version.
        case deviceListRollback
        /// Un maillon manque entre la version épinglée et la courante (D.3).
        case deviceListGap
        /// `E2EE_IDENTITY_NOT_FOUND` : pas d'identité v2, ou ce compte ne peut
        /// pas être lu d'ici ; le serveur ne dit pas lequel (E.1).
        case notFound
        /// `E2EE_IDENTITY_NOT_FOUND` pour un compte déjà épinglé ici : son v2
        /// a été vu, un serveur ne le fait pas disparaître pour forcer le v1
        /// (E.1, v0.4.19). Traité comme un paquet refusé.
        case identityWithdrawn
    }

    struct Outcome: Equatable, Sendable {
        /// Triés par `deviceId`.
        let devices: [E2EEV2CertifiedDevice]
        let pin: E2EEV2TrustPin
    }

    /// `expectedUIK` : la clé de compte détenue ici, pour son propre compte ;
    /// le serveur ne peut alors pas en substituer une autre, même au premier
    /// contact.
    static func verify(
        _ bundle: E2EEV2IdentityBundle,
        pinned: E2EEV2TrustPin?,
        expectedUIK: P256.Signing.PublicKey? = nil
    ) -> Result<Outcome, Failure> {
        guard E2EEV2Canonical.isX963PublicKey(bundle.uikX963B64),
              let uikData = Data(base64Encoded: bundle.uikX963B64),
              let uik = try? P256.Signing.PublicKey(x963Representation: uikData) else {
            return .failure(.malformed)
        }
        if let pinned, Data(base64Encoded: pinned.uikX963B64) != uikData { return .failure(.uikChanged) }
        if let expectedUIK, expectedUIK.x963Representation != uikData { return .failure(.uikChanged) }

        // Liste d'appareils : signature de l'UIK, entrées, version monotone.
        guard let list = try? E2EEV2DeviceList.verifyWithoutChain(
            bundle.deviceList, entries: bundle.deviceEntries, uik: uik
        ), list.userId == bundle.userId else {
            return .failure(.invalidDeviceList)
        }
        if let pinned {
            if list.version < pinned.listVersion { return .failure(.deviceListRollback) }
            if list.version == pinned.listVersion, bundle.deviceList.canonical != pinned.listCanonical {
                return .failure(.deviceListRollback)
            }
            if list.version > pinned.listVersion {
                // Chaque maillon de N+1 à M (D.3) : signé par l'UIK, numéro
                // suivant, condensat du précédent. Jamais de saut.
                guard bundle.deviceListChain.count == list.version - pinned.listVersion - 1 else {
                    return .failure(.deviceListGap)
                }
                var previous = pinned.listCanonical
                for (offset, link) in bundle.deviceListChain.enumerated() {
                    guard let verified = try? E2EEV2DeviceList.verifyLink(link, uik: uik, previousCanonical: previous),
                          verified.userId == bundle.userId,
                          verified.version == pinned.listVersion + offset + 1 else {
                        return .failure(.invalidDeviceList)
                    }
                    previous = link.canonical
                }
                guard list.previousListDigest == E2EEV2DeviceList.digest(of: previous) else {
                    return .failure(.invalidDeviceList)
                }
            }
        }
        var entries: [String: (keyVersion: Int, platform: String, fingerprint: String)] = [:]
        for entry in bundle.deviceEntries {
            guard let parsed = E2EEV2DeviceList.parseEntry(entry), entries[parsed.deviceId] == nil else {
                return .failure(.invalidDeviceList)
            }
            entries[parsed.deviceId] = (parsed.keyVersion, parsed.platform, parsed.fingerprint)
        }

        // Certificats : signés par l'UIK et identiques à une entrée de la liste.
        // Un certificat hors liste (appareil révoqué) ou mal signé est ignoré.
        var certified: [String: E2EEV2DeviceCertificate] = [:]
        for signed in bundle.certificates {
            guard let certificate = try? E2EEV2DeviceCertificate.verify(signed, uik: uik),
                  certificate.userId == bundle.userId,
                  let entry = entries[certificate.deviceId],
                  entry.keyVersion == certificate.keyVersion,
                  entry.platform == certificate.platform,
                  entry.fingerprint == certificate.fingerprint else { continue }
            certified[certificate.deviceId] = certificate
        }

        // Capacités : signées par l'appareil lui-même, jamais en recul.
        var capabilities: [String: E2EEV2CapabilitiesDocument] = [:]
        for signed in bundle.capabilities {
            guard let document = try? E2EEV2CapabilitiesDocument.parse(document: signed.document),
                  document.userId == bundle.userId,
                  let certificate = certified[document.deviceId],
                  let keyData = Data(base64Encoded: certificate.signingKeyB64),
                  let key = try? P256.Signing.PublicKey(x963Representation: keyData),
                  E2EEV2SignedString(
                    canonical: E2EEV2CapabilitiesDocument.signatureCanonical(document: signed.document),
                    signatureB64: signed.signatureB64
                  ).verify(with: key),
                  document.sequence >= pinned?.capabilitySequences[document.deviceId] ?? 0,
                  document.sequence > capabilities[document.deviceId]?.sequence ?? 0 else { continue }
            capabilities[document.deviceId] = document
        }

        let devices = certified.values
            .sorted { $0.deviceId < $1.deviceId }
            .compactMap { certificate -> E2EEV2CertifiedDevice? in
                guard let fingerprint = certificate.fingerprint else { return nil }
                return E2EEV2CertifiedDevice(
                    userId: certificate.userId,
                    deviceId: certificate.deviceId,
                    keyVersion: certificate.keyVersion,
                    platform: certificate.platform,
                    identityKeyB64: certificate.identityKeyB64,
                    signingKeyB64: certificate.signingKeyB64,
                    fingerprint: fingerprint,
                    capabilities: capabilities[certificate.deviceId]
                )
            }
        var sequences: [String: Int] = [:]
        for deviceId in entries.keys {
            let seen = max(pinned?.capabilitySequences[deviceId] ?? 0, capabilities[deviceId]?.sequence ?? 0)
            if seen > 0 { sequences[deviceId] = seen }
        }
        let pin = E2EEV2TrustPin(
            uikX963B64: bundle.uikX963B64,
            listVersion: list.version,
            listCanonical: bundle.deviceList.canonical,
            capabilitySequences: sequences,
            verified: pinned?.verified ?? false
        )
        return .success(Outcome(devices: devices, pin: pin))
    }
}
