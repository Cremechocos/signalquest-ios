import CryptoKit
import Foundation

/// Appareils certifiés des comptes d'une session (§2.2), gardés quelques
/// minutes. L'annuaire de confiance vérifie et épingle chaque paquet ; ce cache
/// évite seulement de le relire à chaque relève ou envoi. Il s'invalide après
/// une approbation, une révocation, un numéro de sécurité accepté ou un
/// `E2EE_DEVICE_LIST_STALE` (E.0), qui nomme les comptes à relire.
actor E2EEV2DeviceDirectoryCache {
    static let lifetime: TimeInterval = 5 * 60

    private struct Entry {
        let devices: [E2EEV2CertifiedDevice]?
        let refusal: E2EEV2IdentityVerification.Failure?
        let readAt: Date
    }

    let session: LocalAccountSession
    private let directory: E2EEV2TrustDirectory
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(session: LocalAccountSession, directory: E2EEV2TrustDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.directory = directory
        self.now = now
    }

    /// Annuaire de la session courante : paquets lus par session (E.1), épinglés
    /// dans le coffre du compte, son propre compte vérifié contre l'UIK détenue ici.
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        accountIdentityStore: E2EEV2AccountIdentityStore = E2EEV2AccountIdentityStore(),
        pins: E2EEV2TrustPinStore = E2EEV2TrustPinStore()
    ) -> E2EEV2DeviceDirectoryCache? {
        guard session.ownerScopeId.hasPrefix("user:") else { return nil }
        let ownUserId = String(session.ownerScopeId.dropFirst("user:".count))
        guard E2EEV2Canonical.isOpaque(ownUserId) else { return nil }
        let namespace = session.ownerNamespace
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: pins, ownUserId: ownUserId,
            ownAccountKey: { (try? accountIdentityStore.load(ownerNamespace: namespace))?.publicKey },
            fetch: E2EEV2TrustDirectory.identityFetch(transport: transport, ownerScopeId: session.ownerScopeId)
        )
        return E2EEV2DeviceDirectoryCache(session: session, directory: directory)
    }

    /// Les comptes demandés, relus s'ils manquent ou ont plus de 5 minutes. Un
    /// identifiant d'appareil certifié par deux comptes n'est cru pour aucun.
    func devices(for userIds: [String]) async throws -> E2EEV2CertifiedDeviceSet {
        let wanted = Set(userIds)
        let current = now()
        let stale = wanted.filter { user in
            guard let entry = entries[user] else { return true }
            return current.timeIntervalSince(entry.readAt) >= Self.lifetime || current < entry.readAt
        }
        if !stale.isEmpty {
            let fresh = try await directory.certifiedDevices(for: Array(stale))
            let readAt = now()
            for user in stale {
                entries[user] = Entry(devices: fresh.devicesByUser[user], refusal: fresh.refusals[user], readAt: readAt)
            }
        }
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
        for user in wanted {
            if let refusal = entries[user]?.refusal { refusals[user] = refusal }
            if let list = entries[user]?.devices { devices[user] = list }
        }
        let owners = devices.values.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1.deviceId, default: 0] += 1 }
        let ambiguous = Set(owners.filter { $0.value > 1 }.keys)
        if !ambiguous.isEmpty {
            devices = devices.mapValues { $0.filter { !ambiguous.contains($0.deviceId) } }
        }
        return E2EEV2CertifiedDeviceSet(devicesByUser: devices, refusals: refusals)
    }

    /// Comptes à relire au prochain appel ; tous si `nil`.
    func invalidate(_ userIds: [String]? = nil) {
        guard let userIds else { entries.removeAll(); return }
        for user in userIds { entries[user] = nil }
    }
}
