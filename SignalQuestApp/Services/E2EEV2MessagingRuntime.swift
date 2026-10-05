import CryptoKit
import Foundation

/// Erreur lisible d'une action v2 depuis un écran.
struct E2EEV2MessagingError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Recette strictement locale de la messagerie v2, comme celle des appels :
/// Debug, argument explicite, environnement hors production, API en boucle
/// locale. Elle ne change pas les verrous globaux ; en Release, la branche
/// fermée est la seule compilée.
enum E2EEV2MessagingQAGate {
    static func allows(config: AppConfig = .current, qaArgumentEnabled: Bool = AppEnvironment.runsE2EEV2MessagingQA) -> Bool {
        #if DEBUG
        guard qaArgumentEnabled, config.environment != .production,
              let components = URLComponents(url: config.apiBaseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host),
              components.port != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return false }
        return true
        #else
        return false
        #endif
    }
}

/// Messagerie v2 de la session courante (§3, §4, E.2, E.3) : assemble la
/// façade, le créateur, l'annuaire des appareils certifiés en cache et
/// l'écriture du miroir de notification, et les rebâtit quand le compte ou la
/// session change. Lit les verrous : rien ne s'écrit ni ne se lit en v2 tant
/// qu'ils sont fermés, sauf en essai local explicite.
///
/// Les appareils demandés sont ceux des membres et de tous les auteurs de la
/// chaîne d'appartenance gardée (§3.5) : un ancien membre a pu signer un
/// changement que la synchronisation revérifie. Sur `E2EE_DEVICE_LIST_STALE`,
/// les comptes nommés sont relus, puis l'opération recommence une seule fois.
final class E2EEV2MessagingRuntime: @unchecked Sendable {
    struct Parts {
        let session: LocalAccountSession
        let messaging: E2EEV2ConversationMessagingV2
        let creator: E2EEV2ConversationCreator
        let directory: E2EEV2DeviceDirectoryCache
        let stateStore: E2EEV2ConversationStateStore
        let messageStore: E2EEV2MessageStoreV2
        let reporter: E2EEV2ReportSenderV2
    }

    private let api: APIClient
    private let identityStore: E2EEV2DeviceIdentityStore
    private let keyStore: E2EEV2EpochKeyStore
    private let stateStore: E2EEV2ConversationStateStore
    private let accountIdentityStore: E2EEV2AccountIdentityStore
    private let pins: E2EEV2TrustPinStore
    private let messageStoreFactory: () throws -> (E2EEV2MessageStoreV2, E2EEV2MessageLedgerStore)
    private let notificationContext: () -> E2EEV2NotificationContextStore?
    private let directoryFactory: (LocalAccountSession) -> E2EEV2DeviceDirectoryCache?
    /// Essai local (harnais QA) : les verrous fermés ne bloquent pas.
    private let ignoresGates: Bool
    private let lock = NSLock()
    private var parts: Parts?

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        accountIdentityStore: E2EEV2AccountIdentityStore = E2EEV2AccountIdentityStore(),
        pins: E2EEV2TrustPinStore = E2EEV2TrustPinStore(),
        messageStores: @escaping () throws -> (E2EEV2MessageStoreV2, E2EEV2MessageLedgerStore) = {
            (E2EEV2MessageStoreV2(), try E2EEV2MessageLedgerStore())
        },
        notificationContext: @escaping () -> E2EEV2NotificationContextStore? = { E2EEV2NotificationContextStore.configured() },
        directory: ((LocalAccountSession) -> E2EEV2DeviceDirectoryCache?)? = nil,
        ignoresGates: Bool = false
    ) {
        directoryFactory = directory ?? { [api, identityStore, accountIdentityStore, pins] session in
            E2EEV2DeviceDirectoryCache.live(
                session: session, api: api, identityStore: identityStore,
                accountIdentityStore: accountIdentityStore, pins: pins
            )
        }
        self.api = api
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.stateStore = stateStore
        self.accountIdentityStore = accountIdentityStore
        self.pins = pins
        messageStoreFactory = messageStores
        self.notificationContext = notificationContext
        self.ignoresGates = ignoresGates
    }

    var writesEnabled: Bool { ignoresGates || E2EEV2RuntimeWriteGate.enabled }
    var readsEnabled: Bool { ignoresGates || E2EEV2RuntimeReadGate.enabled }

    /// Cet appareil n'est pas encore entré en v2 : pas d'identité d'appareil,
    /// ou pas de clé de compte, qui n'arrive qu'avec l'approbation (ou un
    /// premier appareil confirmé). Vrai seulement quand on le sait : un
    /// trousseau verrouillé ou illisible n'en dit rien.
    func lacksV2Readiness(_ session: LocalAccountSession) -> Bool {
        let namespace = session.ownerNamespace
        do {
            return try identityStore.load(ownerNamespace: namespace) == nil
                || accountIdentityStore.load(ownerNamespace: namespace) == nil
                || accountIdentityStore.hasPendingBootstrap(ownerNamespace: namespace)
        } catch {
            return false
        }
    }

    /// Les briques de la session courante, rebâties si elle a changé.
    func current() -> Parts? {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return nil }
        return lock.withLock { () -> Parts? in
            if let parts, parts.session == session { return parts }
            guard let directory = directoryFactory(session), let stores = try? messageStoreFactory() else { return nil }
            let mirror = notificationContext().map {
                E2EEV2NotificationMirrorWriter(keyStore: keyStore, stateStore: stateStore, ledgerStore: stores.1, contextStore: $0)
            }
            let built = Parts(
                session: session,
                messaging: E2EEV2ConversationMessagingV2(
                    api: api, identityStore: identityStore, keyStore: keyStore, stateStore: stateStore,
                    ledgerStore: stores.1, messageStore: stores.0, notificationMirror: mirror, expectedSession: session
                ),
                creator: E2EEV2ConversationCreator(
                    api: api, identityStore: identityStore, keyStore: keyStore, stateStore: stateStore, expectedSession: session
                ),
                directory: directory,
                stateStore: stateStore,
                messageStore: stores.0,
                reporter: E2EEV2ReportSenderV2(api: api, identityStore: identityStore, expectedSession: session)
            )
            parts = built
            return built
        }
    }

    /// Comptes à relire : après une approbation, une révocation, un numéro de
    /// sécurité accepté ; tous si `nil`.
    func invalidateDevices(_ userIds: [String]? = nil) async {
        await current()?.directory.invalidate(userIds)
    }

    /// Membres et auteurs de la chaîne gardée, plus les comptes donnés.
    func accounts(conversationId: String, participantIds: [String], parts: Parts) -> [String] {
        var accounts = Set(participantIds)
        accounts.insert(String(parts.session.ownerScopeId.dropFirst("user:".count)))
        let chain = (try? parts.stateStore.membershipChain(conversationId: conversationId, ownerNamespace: parts.session.ownerNamespace)) ?? []
        for change in chain {
            guard let fields = E2EEV2Canonical.split(change.canonical, tag: E2EEV2MembershipChange.tag, version: "1", fieldCount: 10)
            else { continue }
            for field in [fields[5], fields[6]] where E2EEV2Canonical.isOpaque(field) { accounts.insert(field) }
        }
        return accounts.sorted()
    }

    /// L'opération avec les appareils des comptes, relus une fois si le serveur
    /// répond `E2EE_DEVICE_LIST_STALE`.
    func withDevices<Result>(
        conversationId: String,
        participantIds: [String],
        parts: Parts,
        staleUserIds: (Result) -> [String]?,
        _ operation: (E2EEV2CertifiedDeviceSet) async -> Result
    ) async throws -> Result {
        let accounts = accounts(conversationId: conversationId, participantIds: participantIds, parts: parts)
        let first = await operation(try await parts.directory.devices(for: accounts))
        guard let stale = staleUserIds(first) else { return first }
        await parts.directory.invalidate(stale.isEmpty ? accounts : stale)
        // Relus après l'opération : une synchronisation a pu ajouter des membres
        // ou des auteurs à la chaîne gardée.
        let again = Set(self.accounts(conversationId: conversationId, participantIds: participantIds, parts: parts))
            .union(stale)
        return await operation(try await parts.directory.devices(for: again.sorted()))
    }

    private static func stale(_ failure: E2EEV2TransportFailure) -> [String]? {
        failure.code == "E2EE_DEVICE_LIST_STALE" ? failure.staleUserIds : nil
    }

    // MARK: Opérations

    func refresh(conversationId: String, isGroup: Bool, participantIds: [String]) async -> E2EEV2RefreshResultV2 {
        guard readsEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        do {
            return try await withDevices(conversationId: conversationId, participantIds: participantIds, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                await parts.messaging.refresh(
                    conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
    }

    func send(
        _ draft: E2EEV2MessageSenderV2.Draft,
        clientRequestId: String,
        conversationId: String,
        isGroup: Bool,
        participantIds: [String]
    ) async -> E2EEV2MessageSendResultV2 {
        guard writesEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        do {
            return try await withDevices(conversationId: conversationId, participantIds: participantIds, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                await parts.messaging.send(
                    draft, clientRequestId: clientRequestId, conversationId: conversationId, isGroup: isGroup,
                    devices: devices, expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
    }

    func change(
        _ change: E2EEV2MembershipWriterV2.Change,
        conversationId: String,
        isGroup: Bool,
        participantIds: [String]
    ) async -> E2EEV2MembershipWriteResultV2 {
        guard writesEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        var accounts = participantIds
        if case .add(let userId) = change { accounts.append(userId) }
        do {
            return try await withDevices(conversationId: conversationId, participantIds: accounts, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                await parts.messaging.change(
                    change, conversationId: conversationId, isGroup: isGroup, devices: devices,
                    expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
    }

    func create(participantIds: [String], isGroup: Bool, title: String?, excludesWeb: Bool) async -> E2EEV2ConversationCreationResult {
        guard writesEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        do {
            return try await withDevices(conversationId: "", participantIds: participantIds, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                await parts.creator.create(
                    participantIds: participantIds, isGroup: isGroup, title: title, excludesWeb: excludesWeb,
                    devices: devices, expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
    }

    /// Rotation demandée par la file durable (§3.3 : appareil ajouté ou
    /// révoqué, exigence publiée par le serveur). Rien à faire pour une
    /// conversation qui n'est pas v2 ici ; sinon la décision de l'appareil,
    /// avec les appareils certifiés des membres de la chaîne gardée.
    func rotate(conversationId: String) async -> E2EEV2EpochRotationResult {
        guard writesEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        let stored: (isGroup: Bool, members: [String])
        switch parts.messaging.storedMembership(conversationId: conversationId) {
        case .notV2: return .noAction
        case .unreadable: return .failure(.init(kind: .retryable, message: "e2ee-v2-conversation-state-unreadable"))
        case .v2(let isGroup, let members, _): stored = (isGroup, members)
        }
        // Une rotation demandée suit souvent un appareil ajouté ou révoqué chez
        // un membre : ses appareils sont relus, jamais pris dans le cache.
        await parts.directory.invalidate(accounts(conversationId: conversationId, participantIds: stored.members, parts: parts))
        let result: E2EEV2EpochRotationV2Result
        do {
            result = try await withDevices(conversationId: conversationId, participantIds: stored.members, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                await parts.messaging.rotate(
                    conversationId: conversationId, isGroup: stored.isGroup, devices: devices,
                    expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
        switch result {
        case .upToDate: return .noAction
        case .rotated: return .rotated(followUpRequired: false)
        // Encore une époque adoptée au dernier tour : la décision reste à refaire.
        case .adopted: return .rotated(followUpRequired: true)
        case .needsMembershipSync: return .failure(.init(kind: .retryable, message: "e2ee-v2-membership-sync-pending"))
        // Un numéro de sécurité à accepter : jamais d'époque qui exclut en silence (§2.4).
        case .membersNotTrusted: return .failure(.init(kind: .localState, message: "e2ee-v2-members-not-trusted"))
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: Pour les appels

    /// Membres d'une conversation v2 gardée et leurs appareils certifiés, pour
    /// un appel (§10) : ceux de la chaîne vérifiée, jamais la liste du
    /// serveur. Le verrou d'appels est lu par l'appelant. `synchronizing` :
    /// la conversation est relue d'abord (époque ou membres plus récents).
    struct CallMembers: Sendable {
        let devices: E2EEV2CertifiedDeviceSet
        let members: Set<String>
        let excludesWeb: Bool
        let ownUserId: String
        let ownerNamespace: String
    }

    func callMembers(conversationId: String, synchronizing: Bool) async -> CallMembers? {
        guard let parts = current() else { return nil }
        let stored = parts.messaging.storedMembership(conversationId: conversationId)
        let isGroup: Bool, members: [String]
        switch stored {
        case .v2(let group, let ids, _):
            (isGroup, members) = (group, ids)
        case .notV2 where synchronizing:
            // Appel d'une conversation v2 jamais ouverte ici : ses membres v1
            // servent à lire leurs appareils, puis la chaîne vérifiée fait foi.
            guard let conversation = await conversationDetail(conversationId) else { return nil }
            (isGroup, members) = (conversation.isGroup, conversation.migrationMemberIds)
        case .notV2, .unreadable:
            return nil
        }
        let devices: E2EEV2CertifiedDeviceSet
        do {
            if synchronizing {
                await parts.directory.invalidate(accounts(conversationId: conversationId, participantIds: members, parts: parts))
                _ = try await withDevices(conversationId: conversationId, participantIds: members, parts: parts, staleUserIds: {
                    if case .failure(let failure) = $0 { return Self.stale(failure) }
                    return nil
                }) { devices in
                    await parts.messaging.refresh(
                        conversationId: conversationId, isGroup: isGroup, devices: devices,
                        expectedOwnerScopeId: parts.session.ownerScopeId
                    )
                }
            }
            // Relus après une synchronisation : les membres ont pu changer.
            guard case .v2(_, let current, let excludesWeb) = parts.messaging.storedMembership(conversationId: conversationId)
            else { return nil }
            devices = try await parts.directory.devices(for: accounts(conversationId: conversationId, participantIds: current, parts: parts))
            return CallMembers(
                devices: devices, members: Set(current), excludesWeb: excludesWeb,
                ownUserId: String(parts.session.ownerScopeId.dropFirst("user:".count)),
                ownerNamespace: parts.session.ownerNamespace
            )
        } catch {
            return nil
        }
    }

    private func conversationDetail(_ conversationId: String) async -> MessageConversation? {
        // Identifiant venu d'une notification : jamais hors du format opaque dans un chemin.
        guard E2EEV2Canonical.isOpaque(conversationId) else { return nil }
        struct Response: Decodable { let conversation: MessageConversation }
        return try? await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)"), as: Response.self
        ).conversation
    }

    // MARK: Pour l'écran

    enum ThreadResult: Sendable {
        case thread(E2EEV2ThreadPresentation)
        case failure(E2EEV2TransportFailure)
    }

    /// Relève la conversation, puis la présente : messages sous la forme
    /// commune, avis à poser dans le fil (identité changée, messages manquants…).
    func thread(conversationId: String, isGroup: Bool, participants: [ConversationParticipant]) async -> ThreadResult {
        guard readsEnabled else { return .failure(Self.closed) }
        guard let parts = current() else { return .failure(Self.noSession) }
        let participantIds = participants.map(\.userId)
        var used = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: [:])
        let refreshed: E2EEV2RefreshResultV2
        do {
            refreshed = try await withDevices(conversationId: conversationId, participantIds: participantIds, parts: parts, staleUserIds: {
                if case .failure(let failure) = $0 { return Self.stale(failure) }
                return nil
            }) { devices in
                used = devices
                return await parts.messaging.refresh(
                    conversationId: conversationId, isGroup: isGroup, devices: devices, expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        } catch {
            return .failure(Self.directoryFailure(error))
        }
        switch refreshed {
        case .failure(let failure):
            return .failure(failure)
        case .refreshed(let result):
            let members = Dictionary(participants.map { ($0.userId, $0.user) }, uniquingKeysWith: { first, _ in first })
            let owners = Dictionary(
                used.devicesByUser.flatMap { user, devices in devices.map { ($0.deviceId, user) } },
                uniquingKeysWith: { first, _ in first }
            )
            return .thread(E2EEV2ThreadPresenter.present(
                result, conversationId: conversationId, members: members, deviceOwners: owners,
                refusals: used.refusals.filter { participantIds.contains($0.key) }
            ))
        }
    }

    /// Migration d'une conversation chiffrée v1 à son ouverture (§14.2), selon
    /// la règle commune : tous les membres certifiés et lisant le v2. Vrai si
    /// la conversation est v2 après l'appel.
    func migrateIfReady(_ conversation: MessageConversation) async -> Bool {
        guard writesEnabled, conversation.e2eeEnabled == true, let parts = current(),
              !lacksV2Readiness(parts.session) else { return false }
        let namespace = parts.session.ownerNamespace
        let isV2 = try? parts.stateStore.isV2(conversationId: conversation.id, ownerNamespace: namespace)
        if isV2 == true { return true }
        let participantIds = conversation.migrationMemberIds
        // Règle commune iOS et Android : une conversation peut déjà être v2,
        // créée par un autre membre. Elle est d'abord découverte (chaîne et
        // époque vérifiées puis gardées) ; la genèse n'est tentée que si le
        // serveur répond qu'elle est encore v1.
        guard isV2 == false else { return false }
        let discovered = try? await withDevices(
            conversationId: conversation.id, participantIds: participantIds, parts: parts,
            staleUserIds: { (result: E2EEV2RefreshResultV2) -> [String]? in
                if case .failure(let failure) = result { return Self.stale(failure) }
                return nil
            }, { devices in
                await parts.messaging.refresh(
                    conversationId: conversation.id, isGroup: conversation.isGroup, devices: devices,
                    expectedOwnerScopeId: parts.session.ownerScopeId
                )
            }
        )
        switch discovered {
        case .refreshed?:
            return (try? parts.stateStore.isV2(conversationId: conversation.id, ownerNamespace: namespace)) == true
        case .failure(let failure)? where failure.code == "E2EE_CONVERSATION_NOT_V2":
            break
        default:
            // Rien de sûr sur son état : jamais de genèse sur un doute.
            return false
        }
        guard let result = try? await withDevices(
            conversationId: conversation.id, participantIds: participantIds, parts: parts,
            staleUserIds: { (result: E2EEV2ConversationCreationResult?) -> [String]? in
                if case .failure(let failure)? = result { return Self.stale(failure) }
                return nil
            }, { devices -> E2EEV2ConversationCreationResult? in
                let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
                guard E2EEV2ConversationMigration.decide(conversation, isV2: isV2, devices: devices, nowMs: nowMs) == .migrate
                else { return nil }
                return await parts.creator.migrate(conversation, devices: devices, expectedOwnerScopeId: parts.session.ownerScopeId)
            }
        ) else { return false }
        if case .created = result { return true }
        return false
    }

    /// De quoi montrer le numéro de sécurité d'un membre (§2.4) : l'annuaire de
    /// la session, son propre compte et sa clé de compte détenue ici.
    struct SafetyNumberAccess {
        let trust: any E2EEV2SafetyNumberTrusting
        let ownUserId: String
        let ownAccountKey: () -> P256.Signing.PublicKey?
    }

    func safetyNumberAccess() -> SafetyNumberAccess? {
        guard readsEnabled, let parts = current() else { return nil }
        let namespace = parts.session.ownerNamespace
        return SafetyNumberAccess(
            trust: parts.directory,
            ownUserId: String(parts.session.ownerScopeId.dropFirst("user:".count)),
            ownAccountKey: { [accountIdentityStore] in (try? accountIdentityStore.load(ownerNamespace: namespace))?.publicKey }
        )
    }

    /// Dernier message lisible d'une conversation v2, déjà vérifié et gardé
    /// sur cet appareil : l'aperçu de la liste, sans aucune requête.
    func latestText(conversationId: String) -> String? {
        guard readsEnabled, let parts = current(),
              let snapshot = try? parts.messageStore.snapshot(
                  conversationId: conversationId, ownerScopeId: parts.session.ownerScopeId,
                  nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
              ) else { return nil }
        return snapshot.messages.last { !$0.deleted && $0.text != nil }?.text
    }

    /// Signalement en deux parties (§11, D.10) de messages gardés par cet
    /// appareil : jamais la clé de la conversation.
    func report(refs: [String], reason: ReportReason, conversationId: String) async throws {
        guard writesEnabled else { throw E2EEV2MessagingError(String(localized: "Le signalement chiffré n’est pas encore disponible.")) }
        guard let parts = current() else { throw E2EEV2MessagingError(String(localized: "Reconnecte-toi puis réessaie.")) }
        try await E2EEV2MessageReport.send(
            refs: refs, reason: reason, conversationId: conversationId, ownerScopeId: parts.session.ownerScopeId,
            store: parts.messageStore, sender: parts.reporter
        )
    }

    /// Un changement d'appartenance depuis l'écran : lève une erreur lisible
    /// si le changement n'est pas appliqué.
    func apply(_ membership: E2EEV2MembershipWriterV2.Change, to conversation: MessageConversation) async throws {
        let result = await change(
            membership, conversationId: conversation.id, isGroup: conversation.isGroup,
            participantIds: conversation.participants.map(\.userId)
        )
        switch result {
        case .applied: return
        case .notAllowed:
            throw E2EEV2MessagingError(String(localized: "Seul un administrateur peut faire ce changement."))
        case .needsSync:
            throw E2EEV2MessagingError(String(localized: "La conversation a changé entre-temps. Réessaie."))
        case .failure(let failure) where failure.code == "E2EE_LAST_ADMIN_MUST_PROMOTE":
            throw E2EEV2MessagingError(String(localized: "Nomme un autre admin avant de quitter le groupe."))
        case .failure(let failure) where failure.message == "e2ee-v2-capability-missing":
            throw E2EEV2MessagingError(String(localized: "Ce membre doit mettre à jour SignalQuest pour rejoindre ce groupe chiffré."))
        case .failure(let failure):
            throw E2EEV2MessagingError(failure.kind == .retryable
                ? String(localized: "Connexion instable. Réessaie.")
                : String(localized: "Ce changement n’a pas pu être fait dans la conversation chiffrée."))
        }
    }

    // MARK: Erreurs

    private static let closed = E2EEV2TransportFailure(kind: .activationBlocked, message: "e2ee-v2-runtime-gate-closed")
    private static let noSession = E2EEV2TransportFailure(kind: .authentication, message: "e2ee-v2-session-unavailable")

    private static func directoryFailure(_ error: Error) -> E2EEV2TransportFailure {
        if let failure = error as? E2EEV2TransportFailure { return failure }
        return .init(kind: .retryable, message: "e2ee-v2-device-directory-unavailable")
    }
}
