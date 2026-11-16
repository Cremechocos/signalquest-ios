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
        var delete: @Sendable (_ path: String, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data> = { _, _ in
            .failure(.init(kind: .permanent, statusCode: 404, message: "e2ee-auto-passkey-delete-unavailable"))
        }
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
        /// Remplacement par un appareil inscrit depuis moins de 24 h (H1) : « Réessaie demain ».
        case tooRecent
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
    func offer(prfAvailable: Bool, localPasskeyWanted: Bool) async -> E2EEAutoPasskeyContract.Offer {
        guard prfAvailable, let device = try? dependencies.device(),
              case .verified(let account) = await dependencies.readOwnAccount(), let listed = await list() else { return .none }
        let holdsLatest = account.historyKeyPubB64.map { dependencies.scalar($0) != nil } ?? false
        return E2EEAutoPasskeyContract.offer(
            account: account, deviceId: device.deviceId, holdsLatestHistoryKey: holdsLatest, prfAvailable: prfAvailable,
            listed: listed, localPasskeyWanted: localPasskeyWanted, nowMs: dependencies.nowMs()
        )
    }

    enum SlotOutcome: Equatable, Sendable {
        /// Moins de dix enveloppes : la création peut partir.
        case available
        /// La plus ancienne enveloppe périmée a été retirée.
        case freed
        /// Dix enveloppes, toutes à jour : aucune création.
        case allCurrent
        /// Retrait refusé à un appareil inscrit depuis moins de 24 h (H1) : « Réessaie demain ».
        case tooRecent
        case failed
    }

    /// Limite des dix enveloppes (§5.5, révision 22) : retire la plus ancienne qui n'est pas
    /// à jour, sans jamais toucher à une enveloppe de la dernière HK. `force` : le serveur a
    /// déjà répondu `409 E2EE_PASSKEY_WRAP_LIMIT`, même si la liste lue en montre moins.
    func freeSlot(force: Bool = false) async -> SlotOutcome {
        guard case .verified(let account) = await dependencies.readOwnAccount(), let listed = await list() else { return .failed }
        guard force || listed.count >= E2EEAutoPasskeyContract.maxWraps else { return .available }
        guard let oldest = E2EEAutoPasskeyContract.oldestStale(listed, latest: account.historyKeyPubB64),
              let path = E2EEAutoPasskeyContract.path(credentialId: oldest.credentialId) else { return .allCurrent }
        switch await delete(path) {
        case .success(let data, _, _):
            return E2EEAutoPasskeyContract.isDeleted(data) ? .freed : .failed
        case .failure(let failure):
            switch failure.code {
            case "E2EE_PASSKEY_WRAP_NOT_FOUND": return .freed
            case "E2EE_DEVICE_TOO_RECENT": return .tooRecent
            default: return .failed
            }
        }
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
            case "E2EE_DEVICE_TOO_RECENT": return .tooRecent
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

    private func delete(_ path: String) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.delete(path, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.delete(path, clockOffsetMs)
    }
}

/// Le geste « Retrouver mes messages partout » ou « Mettre à jour ma passkey » (§5.5) :
/// la feuille système, Face ID ou empreinte, puis le dépôt. Partagé par les réglages,
/// le bandeau de Messages et l'écran « Retrouver mes messages ».
enum E2EEAutoPasskeyGesture {
    enum Result: Equatable, Sendable {
        case done
        case cancelled
        /// Le gestionnaire de passkeys ne prend pas en charge `prf`.
        case unsupported
        /// Dix passkeys à jour : aucune n'est retirée.
        case limit
        /// Appareil inscrit depuis moins de 24 h (H1) : « Réessaie demain ».
        case tooRecent
        case failed
    }

    /// Création : la limite est libérée avant la feuille (sinon une passkey resterait orpheline
    /// dans le trousseau), nouvelle passkey et nouveau `prfSalt`. Mise à jour : une assertion sur
    /// les passkeys périmées, chacune avec un `prfSalt` neuf, puis l'enveloppe remplacée. Aucune
    /// clé d'enveloppe n'est gardée (décision du 14/11).
    @MainActor
    static func perform(_ offer: E2EEAutoPasskeyContract.Offer, backup: E2EEAutoPasskeyBackup, userId: String) async -> Result {
        let authenticator = E2EEAutoPasskeyAuthenticator()
        let output: E2EEAutoPasskeyAuthenticator.Output
        let salt: Data
        do {
            switch offer {
            case .none, .updateTomorrow:
                return offer == .updateTomorrow ? .tooRecent : .failed
            case .create:
                switch await backup.freeSlot() {
                case .available, .freed: break
                case .allCurrent: return .limit
                case .tooRecent: return .tooRecent
                case .failed: return .failed
                }
                guard let fresh = randomSalt() else { return .failed }
                salt = fresh
                output = try await authenticator.create(
                    userName: String(localized: "Historique chiffré SignalQuest"),
                    userHandle: E2EEAutoPasskeyAuthenticator.userHandle(userId: userId), salt: salt
                )
            case .update(let credentialIds):
                let listed = (await backup.list() ?? []).filter { credentialIds.contains($0.credentialId) }
                var candidates: [(raw: Data, salt: Data, credentialId: String)] = []
                for item in listed {
                    guard let raw = E2EEAutoPasskeyAuthenticator.rawCredentialId(item.credentialId), let fresh = randomSalt() else { continue }
                    candidates.append((raw, fresh, item.credentialId))
                }
                output = try await authenticator.assert(candidates.map { ($0.raw, $0.salt) })
                guard let chosen = candidates.first(where: { $0.credentialId == output.credentialId }) else { return .failed }
                salt = chosen.salt
            }
        } catch E2EEAutoPasskeyAuthenticator.Failure.cancelled {
            return .cancelled
        } catch E2EEAutoPasskeyAuthenticator.Failure.prfUnsupported {
            return .unsupported
        } catch {
            return .failed
        }
        var outcome = await backup.protect(credentialId: output.credentialId, prfSalt: salt, prfOutput: output.prfOutput)
        if outcome == .limit, offer == .create {
            // Une autre enveloppe est arrivée entre la lecture et le dépôt : un retrait, un seul nouvel essai.
            switch await backup.freeSlot(force: true) {
            case .freed: outcome = await backup.protect(credentialId: output.credentialId, prfSalt: salt, prfOutput: output.prfOutput)
            case .tooRecent: return .tooRecent
            case .available, .allCurrent, .failed: break
            }
        }
        switch outcome {
        case .protected: return .done
        case .limit: return .limit
        case .tooRecent: return .tooRecent
        default: return .failed
        }
    }

    private static func randomSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? Data(bytes) : nil
    }
}

/// Drapeaux locaux de la passkey, par compte (§5.5) : « déjà proposée » et « passkey locale
/// voulue » (HK venue par « C'est moi » ou par la passkey d'un autre appareil).
enum E2EEAutoPasskeyMarks {
    static func dismissedKey(_ namespace: String) -> String { "e2ee-auto-passkey-offer-dismissed-v1:\(namespace)" }
    static func wantedKey(_ namespace: String) -> String { "e2ee-auto-passkey-local-wanted-v1:\(namespace)" }

    static func creationDismissed(_ namespace: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissedKey(namespace))
    }

    static func dismissCreation(_ namespace: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedKey(namespace))
    }

    static func localPasskeyWanted(_ namespace: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: wantedKey(namespace))
    }

    static func setLocalPasskeyWanted(_ wanted: Bool, _ namespace: String, defaults: UserDefaults = .standard) {
        if wanted { defaults.set(true, forKey: wantedKey(namespace)) } else { defaults.removeObject(forKey: wantedKey(namespace)) }
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
            delete: { path, clockOffsetMs in
                await transport.deleteJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs)
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
