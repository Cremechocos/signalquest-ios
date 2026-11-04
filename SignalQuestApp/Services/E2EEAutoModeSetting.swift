import Foundation

/// Mode renforcé du compte (E2EE-AUTO §6, route r3) : requête signée par un appareil
/// actif inscrit depuis 24 h, sur la charge `SQ-E2EE-AUTO-MODE` (`E2EEAutoStrictMode`).
/// Le serveur ne fait foi de rien : la réponse doit être le `MODE` signé ici, et l'app
/// n'adopte le mode qu'à la relecture vérifiée du journal.
actor E2EEAutoModeSetting {
    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var put: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    /// Ce que l'écran peut proposer, lu au journal vérifié.
    struct Status: Equatable, Sendable {
        let mode: E2EEAutoLog.Mode
        /// Inscrit depuis 24 h et actif : cet appareil peut changer le mode.
        let canChange: Bool
        let activeDevices: Int
    }

    enum Outcome: Equatable, Sendable {
        /// Le mode lu au journal vérifié après l'écriture (ou déjà en vigueur).
        case set(E2EEAutoLog.Mode)
        /// Garde des 24 h (§3.2).
        case tooRecent
        /// `STRICT` sans deux appareils actifs.
        case needsTwoDevices
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    /// Corps à trois champs exacts.
    static func body(prevUserEntryHash: String, mode: E2EEAutoLog.Mode, signatureB64: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["prevUserEntryHash": prevUserEntryHash, "mode": mode.rawValue, "signatureB64": signatureB64],
            options: [.sortedKeys]
        )
    }

    /// `200 { entry: null, link: null, head }` : mode déjà en vigueur, rien d'écrit.
    static func isUnchangedResponse(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["entry", "link", "head"], object["entry"] is NSNull, object["link"] is NSNull,
              let head = object["head"] as? [String: Any] else { return false }
        return head["text"] is String && head["signatureB64"] is String
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func status() async -> Status? {
        guard let device = try? dependencies.device(), case .verified(let account) = await dependencies.readOwnAccount(),
              let own = account.devices[device.deviceId], own.signingKeyB64 == device.publicSigningKeyB64 else { return nil }
        return Status(
            mode: account.mode,
            canChange: own.status == .active && dependencies.nowMs() - own.addedAtMs >= E2EEAutoLog.signerMinAgeMs,
            activeDevices: account.devices.values.filter { $0.status == .active }.count
        )
    }

    func set(_ mode: E2EEAutoLog.Mode) async -> Outcome {
        let device: E2EEV2DeviceDescriptor
        do { device = try dependencies.device() } catch { return .failed("e2ee-auto-device-unavailable") }
        for _ in 0..<2 {
            let account: E2EEAutoLog.AccountState
            switch await dependencies.readOwnAccount() {
            case .verified(let state): account = state
            case .refused: return .logRefused
            case .inconclusive: return .retryLater(afterSeconds: nil)
            }
            guard account.devices[device.deviceId]?.signingKeyB64 == device.publicSigningKeyB64 else { return .retryLater(afterSeconds: nil) }
            // Mêmes règles que le lecteur (§3.2) : rien ne part que le journal refuserait.
            switch E2EEAutoStrictMode.refusal(account: account, deviceId: device.deviceId, mode: mode, nowMs: dependencies.nowMs()) {
            case nil: break
            case .unchanged?: return .set(mode)
            case .notActive?: return .notActive
            case .tooRecent?: return .tooRecent
            case .needsTwoDevices?: return .needsTwoDevices
            }
            guard let previous = account.lastEntryHash else { return .failed("e2ee-auto-mode-state") }
            let body: Data
            do {
                let payload = E2EEAutoStrictMode.payload(
                    userId: dependencies.userId, prevUserEntryHash: previous, signerDeviceId: device.deviceId, mode: mode
                )
                let signature = try dependencies.sign(Data(payload.utf8)).base64EncodedString()
                body = try Self.body(prevUserEntryHash: previous, mode: mode, signatureB64: signature)
            } catch {
                return .failed("e2ee-auto-mode-signature")
            }
            switch await put(E2EEAutoStrictMode.path, body) {
            case .success(let data, let statusCode, _):
                let written = statusCode == 201 && E2EEAutoStrictMode.parse(
                    data, userId: dependencies.userId, prevUserEntryHash: previous,
                    signerDeviceId: device.deviceId, mode: mode, signingKeyB64: device.publicSigningKeyB64
                )
                guard written || (statusCode == 200 && Self.isUnchangedResponse(data)) else { return .failed("invalid-e2ee-auto-mode-response") }
                // La réponse ne vaut pas adoption : seul le journal relu dit le mode.
                switch await dependencies.readOwnAccount() {
                case .verified(let state): return state.mode == mode ? .set(mode) : .retryLater(afterSeconds: nil)
                case .refused: return .logRefused
                case .inconclusive: return .retryLater(afterSeconds: nil)
                }
            case .failure(let failure):
                switch failure.code {
                case "E2EE_DEVICE_TOO_RECENT": return .tooRecent
                case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
                case "E2EE_STRICT_NEEDS_TWO_DEVICES": return .needsTwoDevices
                // Une autre entrée est passée entre la lecture et l'écriture : relire, re-signer une fois.
                case "E2EE_LOG_STALE", "E2EE_REQUEST_REPLAYED": continue
                default:
                    if failure.statusCode == 429 || failure.kind == .retryable || (failure.statusCode ?? 0) >= 500 {
                        return .retryLater(afterSeconds: failure.retryAfterSeconds)
                    }
                    return .failed("e2ee-auto-mode-refused")
                }
            }
        }
        return .retryLater(afterSeconds: nil)
    }

    /// Un refus d'horodatage donne l'heure du serveur : une seule nouvelle signature (révision 8).
    private func put(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.put(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.put(path, body, clockOffsetMs)
    }
}

extension E2EEAutoModeSetting {
    /// Réglage pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) -> E2EEAutoModeSetting? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        return E2EEAutoModeSetting(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            put: { path, body, clockOffsetMs in
                await transport.putJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) }
        ))
    }
}
