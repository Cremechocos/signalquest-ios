import CryptoKit
import Foundation

/// Appareils certifiés des membres d'une conversation, figés pour un appel ou
/// un envoi (spec §2.2, §10, §12). Les vérifications synchrones — preuve de
/// jonction, descripteur d'appel, destinataires d'une époque — s'y lisent
/// sans réseau.
struct E2EEV2CertifiedDeviceSet: Equatable, Sendable {
    let devicesByUser: [String: [E2EEV2CertifiedDevice]]
    /// Comptes dont le paquet de confiance a été refusé (UIK changée, liste
    /// invalide ou en recul) : aucun de leurs appareils n'est cru.
    let refusals: [String: E2EEV2IdentityVerification.Failure]

    func device(userId: String, deviceId: String) -> E2EEV2CertifiedDevice? {
        devicesByUser[userId]?.first { $0.deviceId == deviceId }
    }

    /// L'appareil appelant d'un descripteur n'est désigné que par son
    /// identifiant d'appareil.
    func device(deviceId: String) -> E2EEV2CertifiedDevice? {
        devicesByUser.values.lazy.flatMap { $0 }.first { $0.deviceId == deviceId }
    }

    func signingKey(userId: String, deviceId: String) -> P256.Signing.PublicKey? {
        device(userId: userId, deviceId: deviceId)?.signingKey
    }

    /// §10.0 et §12 : tous les appareils certifiés et non mis à l'écart des
    /// membres ont la capacité « appels vérifiés ». Un membre dont le paquet
    /// est refusé rend l'appel indisponible : ses appareils sont inconnus.
    func supportsVerifiedCalls(nowMs: Int64) -> Bool {
        guard refusals.isEmpty else { return false }
        let active = devicesByUser.values.flatMap { $0 }.filter { !$0.isSidelined(nowMs: nowMs) }
        return !active.isEmpty && active.allSatisfy { $0.supports("calls", nowMs: nowMs) }
    }
}

/// Ce que cet appareil a épinglé de chaque compte (§2.1, §2.2), dans le coffre
/// E2EE du compte courant. Rien de secret, mais son intégrité compte : une UIK
/// remplacée ici ferait croire un faux appareil.
final class E2EEV2TrustPinStore: @unchecked Sendable {
    static let keyPrefix = "trust-pin-v1"

    private let tokenStore: TokenStore

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")) {
        self.tokenStore = tokenStore
    }

    func pin(userId: String, ownerNamespace: String) throws -> E2EEV2TrustPin? {
        guard let raw = try tokenStore.string(for: key(userId: userId, ownerNamespace: ownerNamespace)),
              let data = raw.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(E2EEV2TrustPin.self, from: data)
    }

    func save(_ pin: E2EEV2TrustPin, userId: String, ownerNamespace: String) throws {
        let data = try JSONEncoder().encode(pin)
        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteUnknown) }
        try tokenStore.set(value, for: key(userId: userId, ownerNamespace: ownerNamespace), accessibility: .afterFirstUnlock)
    }

    static func prefix(ownerNamespace: String) -> String {
        "\(keyPrefix):\(ownerNamespace):"
    }

    private func key(userId: String, ownerNamespace: String) -> String {
        Self.prefix(ownerNamespace: ownerNamespace) + userId
    }
}

/// Lit, vérifie et épingle le paquet de confiance de chaque membre (E.1), puis
/// rend les appareils certifiés. Un paquet refusé retire ce membre sans faire
/// échouer les autres ; une erreur réseau fait échouer l'ensemble.
actor E2EEV2TrustDirectory {
    enum Failure: Error, Equatable {
        case malformedResponse(userId: String)
    }

    private let ownerNamespace: String
    private let pins: E2EEV2TrustPinStore
    private let ownUserId: String?
    private let ownAccountKey: @Sendable () -> P256.Signing.PublicKey?
    /// `sinceVersion` : la version épinglée, ou la page suivante de la chaîne (E.1).
    private let fetch: @Sendable (_ userId: String, _ sinceVersion: Int?) async throws -> Data
    /// 50 maillons par page : au-delà, la chaîne est trop longue pour être relue.
    static let maxChainPages = 20

    /// `ownAccountKey` : la clé de compte détenue ici. Son propre paquet doit la
    /// porter, sinon le serveur pourrait y glisser une autre clé au premier
    /// contact.
    init(
        ownerNamespace: String,
        pins: E2EEV2TrustPinStore = E2EEV2TrustPinStore(),
        ownUserId: String? = nil,
        ownAccountKey: @escaping @Sendable () -> P256.Signing.PublicKey? = { nil },
        fetch: @escaping @Sendable (_ userId: String, _ sinceVersion: Int?) async throws -> Data
    ) {
        self.ownerNamespace = ownerNamespace
        self.pins = pins
        self.ownUserId = ownUserId
        self.ownAccountKey = ownAccountKey
        self.fetch = fetch
    }

    func certifiedDevices(for userIds: [String]) async throws -> E2EEV2CertifiedDeviceSet {
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
        for userId in Set(userIds).sorted() {
            let pinned = try pins.pin(userId: userId, ownerNamespace: ownerNamespace)
            let bundle = try await bundle(userId: userId, sinceVersion: pinned?.listVersion)
            let expected = userId == ownUserId ? ownAccountKey() : nil
            switch E2EEV2IdentityVerification.verify(bundle, pinned: pinned, expectedUIK: expected) {
            case .success(let outcome):
                try pins.save(outcome.pin, userId: userId, ownerNamespace: ownerNamespace)
                devices[userId] = outcome.devices
            case .failure(let refusal):
                refusals[userId] = refusal
            }
        }
        // Un identifiant d'appareil certifié par deux comptes est ambigu : un
        // descripteur d'appel ne le désigne que par lui. Aucun des deux n'est cru.
        let owners = devices.values.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1.deviceId, default: 0] += 1 }
        let ambiguous = Set(owners.filter { $0.value > 1 }.keys)
        if !ambiguous.isEmpty {
            devices = devices.mapValues { $0.filter { !ambiguous.contains($0.deviceId) } }
        }
        return E2EEV2CertifiedDeviceSet(devicesByUser: devices, refusals: refusals)
    }

    /// Le paquet de confiance et toute la chaîne depuis la version épinglée,
    /// page après page (E.1).
    private func bundle(userId: String, sinceVersion pinned: Int?) async throws -> E2EEV2IdentityBundle {
        var chain: [E2EEV2SignedString] = []
        var since = pinned
        for _ in 0..<Self.maxChainPages {
            let data = try await fetch(userId, since)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var page = E2EEV2IdentityBundle.parse(object, userId: userId) else {
                throw Failure.malformedResponse(userId: userId)
            }
            chain += page.deviceListChain
            guard let next = page.nextSinceVersion else {
                page.deviceListChain = chain
                return page
            }
            // Une page suivante doit avancer, sinon la lecture boucle.
            guard next > (since ?? 0) else { throw Failure.malformedResponse(userId: userId) }
            since = next
        }
        throw Failure.malformedResponse(userId: userId)
    }
}
