import Foundation

/// HK protégée par une passkey (E2EE-AUTO §5.5) : l'enveloppe `passkey-wrap-v1` est
/// scellée avec la sortie PRF de la passkey et gardée par le serveur. Le serveur ne
/// fait foi de rien : une HK ouverte n'est gardée que si le journal vérifié la connaît,
/// et elle n'est déclarée `present` que si c'est la dernière.
actor E2EEAutoPasskeyBackup {
    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var get: @Sendable (_ path: String) async -> E2EEV2TransportResult<Data>
        var put: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        var scalar: @Sendable (_ hkPubB64: String) -> Data?
        var keep: @Sendable (_ scalar: Data) throws -> String
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    enum ProtectOutcome: Equatable, Sendable {
        case protected
        /// Cet appareil ne détient pas la dernière HK du journal.
        case noHistoryKey
        /// Une HK plus récente est passée : relire, puis recommencer.
        case stale
        /// Dix passkeys déjà enregistrées pour le compte.
        case limit
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    enum RecoverOutcome: Equatable, Sendable {
        /// La dernière HK du journal : l'historique s'ouvre (l'appelant reprend la suite habituelle).
        case present(hkPubB64: String)
        /// Passkey périmée (§5.6) : une HK précédente seulement, l'ancien historique.
        case older(hkPubB64: String)
        case logRefused
        case retryLater
        case failed(String)
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Les enveloppes du compte (session seule côté serveur), sans jugement.
    func list() async -> [E2EEAutoPasskeyContract.Listed]? {
        guard case .success(let data, _, _) = await dependencies.get(E2EEAutoPasskeyContract.listPath) else { return nil }
        return E2EEAutoPasskeyContract.parseList(data)
    }

    /// Ce que l'app propose ici (§5.5) : créer, mettre à jour, ou rien.
    func offer(prfAvailable: Bool, creationDismissed: Bool) async -> E2EEAutoPasskeyContract.Offer {
        guard prfAvailable, let device = try? dependencies.device(),
              case .verified(let account) = await dependencies.readOwnAccount(), let listed = await list() else { return .none }
        let holdsLatest = account.historyKeyPubB64.map { dependencies.scalar($0) != nil } ?? false
        return E2EEAutoPasskeyContract.offer(
            account: account, deviceId: device.deviceId, holdsLatestHistoryKey: holdsLatest, prfAvailable: prfAvailable,
            listed: listed, creationDismissed: creationDismissed
        )
    }

    /// Les enveloppes qu'une passkey peut ouvrir ici : celles d'une HK du journal vérifié.
    func recoverable() async -> [E2EEAutoPasskeyContract.Listed] {
        guard case .verified(let account) = await dependencies.readOwnAccount(), let listed = await list() else { return [] }
        let known = Set(account.historyKeys.map(\.hkPubB64))
        return listed.filter { known.contains($0.wrap.hkPubB64) }
    }

    /// Scelle la dernière HK avec la sortie PRF et la dépose (ou remplace celle de ce `credentialId`).
    func protect(credentialId: String, prfSalt: Data, prfOutput: Data) async -> ProtectOutcome {
        guard let device = try? dependencies.device() else { return .failed("e2ee-auto-device-unavailable") }
        let account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater(afterSeconds: nil)
        }
        guard account.devices[device.deviceId]?.status == .active else { return .notActive }
        guard let latest = account.historyKeyPubB64, let scalar = dependencies.scalar(latest) else { return .noHistoryKey }
        guard let path = E2EEAutoPasskeyContract.path(credentialId: credentialId),
              let wrap = try? E2EEAutoHistory.sealPasskey(
                scalar: scalar, prfOutput: prfOutput, prfSalt: prfSalt, userId: dependencies.userId, credentialId: credentialId
              ),
              let body = try? E2EEAutoPasskeyContract.putBody(wrap) else { return .failed("e2ee-auto-passkey-seal") }
        switch await put(path, body) {
        case .success(let data, _, _):
            // Réponse : l'élément du `GET`, pour ce `credentialId` et cette HK.
            let item = (try? JSONSerialization.jsonObject(with: data)).map { ["wraps": [$0]] }
            guard let item, let reply = try? JSONSerialization.data(withJSONObject: item),
                  let parsed = E2EEAutoPasskeyContract.parseList(reply), parsed.count == 1,
                  parsed[0].credentialId == credentialId, parsed[0].wrap == wrap else { return .failed("invalid-e2ee-auto-passkey-response") }
            return .protected
        case .failure(let failure):
            switch failure.code {
            case "E2EE_HISTORY_KEY_STALE": return .stale
            case "E2EE_PASSKEY_WRAP_LIMIT": return .limit
            case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
            default:
                if failure.statusCode == 429 || failure.kind == .retryable || (failure.statusCode ?? 0) >= 500 {
                    return .retryLater(afterSeconds: failure.retryAfterSeconds)
                }
                return .failed("e2ee-auto-passkey-refused")
            }
        }
    }

    /// Ouvre une enveloppe avec la sortie PRF de sa passkey ; la HK obtenue doit être
    /// au journal vérifié (§5.5, comme au §5.4), sinon rien n'est gardé.
    func recover(_ listed: E2EEAutoPasskeyContract.Listed, prfOutput: Data) async -> RecoverOutcome {
        let account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater
        }
        guard account.historyKeys.contains(where: { $0.hkPubB64 == listed.wrap.hkPubB64 }) else { return .failed("e2ee-auto-passkey-unknown-key") }
        let kept: String
        do {
            let scalar = try E2EEAutoHistory.openPasskey(
                listed.wrap, prfOutput: prfOutput, userId: dependencies.userId, credentialId: listed.credentialId
            )
            kept = try dependencies.keep(scalar)
        } catch {
            return .failed("e2ee-auto-passkey-open")
        }
        guard kept == listed.wrap.hkPubB64 else { return .failed("e2ee-auto-passkey-open") }
        return kept == account.historyKeyPubB64 ? .present(hkPubB64: kept) : .older(hkPubB64: kept)
    }

    /// Un refus d'horodatage donne l'heure du serveur : une seule nouvelle signature (révision 8).
    private func put(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.put(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.put(path, body, clockOffsetMs)
    }
}

extension E2EEAutoPasskeyBackup {
    /// Passkey pour la session courante, derrière l'interrupteur du mode automatique
    /// et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        historyKeys: E2EEAutoHistoryKeyStore = E2EEAutoHistoryKeyStore()
    ) -> E2EEAutoPasskeyBackup? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        return E2EEAutoPasskeyBackup(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            get: { path in
                await transport.getJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            },
            put: { path, body, clockOffsetMs in
                await transport.putJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) },
            scalar: { hkPubB64 in try? historyKeys.scalar(userId: userId, hkPubB64: hkPubB64) },
            keep: { scalar in
                guard session.isCurrent else { throw E2EEV2DeviceIdentityError.unauthenticated }
                return try historyKeys.keep(scalar: scalar, userId: userId)
            }
        ))
    }
}
