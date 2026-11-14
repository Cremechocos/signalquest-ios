import CryptoKit
import Foundation

/// Appareils certifiés des comptes d'une session (§2.2), gardés quelques
/// minutes. L'annuaire de confiance vérifie et épingle chaque paquet ; ce cache
/// évite seulement de le relire à chaque relève ou envoi. Il s'invalide après
/// une révocation ou un `E2EE_DEVICE_LIST_STALE` (E.0), qui nomme les comptes
/// à relire.
actor E2EEV2DeviceDirectoryCache {
    static let lifetime: TimeInterval = 5 * 60

    private struct Entry {
        let devices: [E2EEV2CertifiedDevice]?
        let refusal: E2EEV2IdentityVerification.Failure?
        let listVersion: Int?
        var logSeq: Int64? = nil
        var logAccount: E2EEAutoLog.AccountState? = nil
        var deleted = false
        let readAt: Date
    }

    let session: LocalAccountSession
    private let directory: E2EEV2TrustDirectory
    /// Source auto (E2EE-AUTO §4.2) : quand elle est là, les appareils viennent
    /// du journal vérifié ; l'annuaire v2 ne sert plus qu'aux signataires
    /// d'avant la bascule (`legacySigners`).
    private let autoRead: (@Sendable ([String]) async throws -> E2EEV2CertifiedDeviceSet)?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    /// Certificats v2 lus pour des signataires absents du journal, par compte.
    private var legacyEntries: [String: (devices: [E2EEV2CertifiedDevice], readAt: Date)] = [:]
    /// Dernier écart d'horloge mesuré par le journal (§7.1).
    private var logClockOffsetMs: Int64?
    /// Invalidations par compte : une lecture commencée avant une invalidation
    /// (révocation) n'écrit pas son résultat après elle, ce
    /// que la réentrance de l'acteur permettrait pendant l'`await`.
    private var generations: [String: Int] = [:]
    private var generation = 0

    init(
        session: LocalAccountSession,
        directory: E2EEV2TrustDirectory,
        autoRead: (@Sendable ([String]) async throws -> E2EEV2CertifiedDeviceSet)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.directory = directory
        self.autoRead = autoRead
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
        let autoRead = SQFeatures.e2eeAutoLogEnabled
            ? E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore).map(Self.autoRead)
            : nil
        return E2EEV2DeviceDirectoryCache(session: session, directory: directory, autoRead: autoRead)
    }

    /// Les maillons d'abord, puis chaque compte demandé. Un journal pas à jour
    /// sert encore (§3.4 : envoi sous l'époque adoptée) ; une alerte gardée ne
    /// rend plus aucun appareil.
    static func autoRead(_ reader: E2EEAutoLogReader) -> @Sendable ([String]) async throws -> E2EEV2CertifiedDeviceSet {
        { userIds in
            let status = try await reader.refreshLinks()
            // Comparaison avec la sonde, une fois par jour au plus (§3.7) : une fourche bloque comme une alerte.
            let blocked: Bool
            if case .alert = status { blocked = true } else { blocked = await reader.checkProbeIfDue() == .fork }
            if blocked {
                return E2EEV2CertifiedDeviceSet(
                    devicesByUser: [:], refusals: Dictionary(uniqueKeysWithValues: userIds.map { ($0, .invalidDeviceList) })
                )
            }
            var accounts: [String: Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>?] = [:]
            for userId in Set(userIds).sorted() { accounts[userId] = try await reader.account(userId) }
            var set = E2EEAutoDeviceDirectory.deviceSet(accounts: accounts)
            set.logClockOffsetMs = await reader.clockOffsetMs
            let added = await reader.takeAddedDevices()
            if !added.isEmpty { E2EEAutoDeviceEvents.post(ownerScopeId: reader.ownerScopeId, added: added) }
            return set
        }
    }

    /// Certificats v2 de comptes dont un signataire manque au journal : la
    /// vérification v2 d'avant la bascule, gardée jusqu'à l'étape 5
    /// (E2EE-AUTO §12). Sans source auto, `devices(for:)` les lit déjà.
    /// Gardés 5 minutes, comme les appareils.
    func legacySigners(for userIds: [String]) async -> E2EEV2CertifiedDeviceSet? {
        guard autoRead != nil, !userIds.isEmpty else { return nil }
        let current = now()
        let stale = Set(userIds).filter { user in
            guard let entry = legacyEntries[user] else { return true }
            return current.timeIntervalSince(entry.readAt) >= Self.lifetime || current < entry.readAt
        }.sorted()
        if !stale.isEmpty {
            guard let read = try? await directory.certifiedDevices(for: stale) else { return nil }
            let readAt = now()
            for user in stale { legacyEntries[user] = (read.devicesByUser[user] ?? [], readAt) }
        }
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        for user in userIds { devices[user] = legacyEntries[user]?.devices ?? [] }
        return E2EEV2CertifiedDeviceSet(devicesByUser: devices, refusals: [:])
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
        var fresh: E2EEV2CertifiedDeviceSet?
        if !stale.isEmpty {
            let users = stale.sorted()
            let before = (all: generation, users: users.map { generations[$0] ?? 0 })
            let read: E2EEV2CertifiedDeviceSet
            if let autoRead {
                read = try await autoRead(users)
            } else {
                read = try await directory.certifiedDevices(for: users)
            }
            fresh = read
            if let offset = read.logClockOffsetMs { logClockOffsetMs = offset }
            let readAt = now()
            for (user, seen) in zip(users, before.users)
            where before.all == generation && seen == (generations[user] ?? 0) {
                entries[user] = Entry(
                    devices: read.devicesByUser[user], refusal: read.refusals[user],
                    listVersion: read.listVersions[user], logSeq: read.logSeqs[user],
                    logAccount: read.logAccounts[user], deleted: read.deleted.contains(user), readAt: readAt
                )
            }
        }
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
        var versions: [String: Int] = [:]
        var logSeqs: [String: Int64] = [:]
        var logAccounts: [String: E2EEAutoLog.AccountState] = [:]
        var deleted: Set<String> = []
        for user in wanted {
            // Ce qui vient d'être lu sert à cet appel même si une invalidation
            // l'empêche d'entrer dans le cache : il est plus récent que lui.
            let devicesRead = fresh?.devicesByUser[user] ?? (stale.contains(user) ? nil : entries[user]?.devices)
            let refusalRead = fresh?.refusals[user] ?? (stale.contains(user) ? nil : entries[user]?.refusal)
            let versionRead = fresh?.listVersions[user] ?? (stale.contains(user) ? nil : entries[user]?.listVersion)
            if let refusalRead { refusals[user] = refusalRead }
            if let devicesRead { devices[user] = devicesRead }
            if let versionRead { versions[user] = versionRead }
            if let logSeqRead = fresh?.logSeqs[user] ?? (stale.contains(user) ? nil : entries[user]?.logSeq) {
                logSeqs[user] = logSeqRead
            }
            if let accountRead = fresh?.logAccounts[user] ?? (stale.contains(user) ? nil : entries[user]?.logAccount) {
                logAccounts[user] = accountRead
            }
            let isDeleted = stale.contains(user)
                ? fresh?.deleted.contains(user) == true
                : entries[user]?.deleted == true
            if isDeleted { deleted.insert(user) }
        }
        // v2 : un identifiant d'appareil certifié par deux comptes n'est cru pour
        // aucun. Le journal auto admet le couple (userId, deviceId) (§7.1).
        if autoRead == nil {
            let owners = devices.values.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1.deviceId, default: 0] += 1 }
            let ambiguous = Set(owners.filter { $0.value > 1 }.keys)
            if !ambiguous.isEmpty {
                devices = devices.mapValues { $0.filter { !ambiguous.contains($0.deviceId) } }
            }
        }
        return E2EEV2CertifiedDeviceSet(
            devicesByUser: devices, refusals: refusals, listVersions: versions, logSeqs: logSeqs,
            logAccounts: logAccounts, logClockOffsetMs: logClockOffsetMs, deleted: deleted
        )
    }

    /// Comptes à relire au prochain appel ; tous si `nil`.
    func invalidate(_ userIds: [String]? = nil) {
        guard let userIds else {
            entries.removeAll()
            generation += 1
            return
        }
        for user in userIds {
            entries[user] = nil
            generations[user, default: 0] += 1
        }
    }
}
