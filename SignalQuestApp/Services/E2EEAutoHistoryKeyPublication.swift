import Foundation

/// Publication de la clé d'historique HK (E2EE-AUTO §5.1) et état d'historique
/// de l'appareil (§5.3) : `POST /api/e2ee/auto/history-key`, signée par cet
/// appareil sur la charge `SQ-E2EE-AUTO-HISTORY-KEY`, avec comparaison-échange
/// sur la dernière HK du journal. Le serveur ne fait foi de rien : la réponse doit
/// être l'entrée signée ici, et seule la relecture du journal installe la clé.
enum E2EEAutoHistoryKeyContract {
    static let path = "/api/e2ee/auto/history-key"

    static func historyStatusPath(deviceId: String) -> String { "/api/e2ee/auto/devices/\(deviceId)/history-status" }

    static func payload(userId: String, prevUserEntryHash: String, signerDeviceId: String, previousHkPubB64: String?, hkPubB64: String) -> String {
        E2EEAutoLog.Payload.historyKey(
            userId: userId, prevUserEntryHash: prevUserEntryHash, signerDeviceId: signerDeviceId,
            previousHkPubB64: previousHkPubB64, hkPubB64: hkPubB64
        )
    }

    /// Corps aux quatre champs exacts ; sans HK au journal, `previousHkPubB64` vaut `-`.
    static func body(prevUserEntryHash: String, previousHkPubB64: String?, hkPubB64: String, signatureB64: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "prevUserEntryHash": prevUserEntryHash,
            "previousHkPubB64": previousHkPubB64 ?? "-",
            "hkPubB64": hkPubB64,
            "signatureB64": signatureB64,
        ], options: [.sortedKeys])
    }

    /// Réponse : la `HISTORY_KEY` de cette clé, signée par cet appareil sur la
    /// charge envoyée. Au rejeu (§5.1 point 5), c'est l'entrée déjà écrite, sur
    /// son propre `prevUserEntryHash`.
    static func parse(
        _ data: Data, userId: String, signerDeviceId: String, previousHkPubB64: String?, hkPubB64: String, signingKeyB64: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (entry, detail) = E2EEAutoEnrollmentContract.writtenEntry(object),
              case .historyKey(let writtenSigner, let writtenKey, let signatureB64) = detail,
              entry.op == .historyKey, entry.userId == userId, writtenSigner == signerDeviceId, writtenKey == hkPubB64 else { return false }
        return E2EEAutoLog.verify(
            publicKeyB64: signingKeyB64,
            payload: payload(
                userId: userId, prevUserEntryHash: entry.prevUserEntryHash, signerDeviceId: signerDeviceId,
                previousHkPubB64: previousHkPubB64, hkPubB64: hkPubB64
            ),
            signatureB64: signatureB64
        )
    }

    static func statusBody(present: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["historyKey": present ? "present" : "absent"], options: [.sortedKeys])
    }
}

/// Création, publication et déclaration de HK, l'état venant toujours du journal
/// vérifié du compte (§5, réponses de la révision 11).
actor E2EEAutoHistoryKeyPublication {
    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var post: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var put: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        /// L'appareil détient le scalaire de cette HK.
        var holds: @Sendable (_ hkPubB64: String) -> Bool
        /// Tire et range une nouvelle HK avant toute publication ; rend sa clé publique.
        var create: @Sendable () throws -> String
        var discard: @Sendable (_ hkPubB64: String) throws -> Void
        /// HK tirée ici dont la publication n'est pas encore lue au journal.
        var pendingKey: @Sendable () -> String?
        var recordPendingKey: @Sendable (_ hkPubB64: String?) -> Void
        /// Dernière déclaration `present` faite au serveur, `<deviceId>:<hkPubB64>`.
        var reportedStatus: @Sendable () -> String?
        var recordReportedStatus: @Sendable (_ value: String) -> Void
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    enum Outcome: Equatable, Sendable {
        /// HK publiée ici, ou déjà publiée et détenue ; `present` déclaré.
        case present(hkPubB64: String)
        /// Le compte a une HK que l'appareil n'a pas : synchro, passkey ou « C'est moi » (§5.3).
        case missing(hkPubB64: String)
        /// Appareil en attente (mode renforcé) : rien avant son activation.
        case notActive
        /// Garde des 24 h (§3.2) : remplacer une HK perdue attend l'ancienneté.
        case tooRecent
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Premier appareil d'un compte sans HK : il la crée et la publie. Sinon,
    /// il déclare `present` dès qu'il détient la dernière.
    func run() async -> Outcome {
        await publish(replacingLostKey: false)
    }

    /// « Continuer sans l'historique » (§5.1, HK perdue) : nouvelle HK après
    /// celle du journal, que l'appareil n'a pas. L'ancien historique est perdu.
    func replaceLostKey() async -> Outcome {
        await publish(replacingLostKey: true)
    }

    private func publish(replacingLostKey: Bool) async -> Outcome {
        let device: E2EEV2DeviceDescriptor
        do { device = try dependencies.device() } catch { return .failed("e2ee-auto-device-unavailable") }
        var account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater(afterSeconds: nil)
        }
        for attempt in 0..<2 {
            guard let signer = account.devices[device.deviceId], signer.signingKeyB64 == device.publicSigningKeyB64 else {
                return .retryLater(afterSeconds: nil)
            }
            guard signer.status == .active else { return signer.status == .pending ? .notActive : .failed("e2ee-auto-device-revoked") }
            let current = account.historyKeyPubB64
            settlePendingKey(current: current)
            if let current {
                if dependencies.holds(current) { return await reportPresent(device: device, hkPubB64: current) }
                guard replacingLostKey else { return .missing(hkPubB64: current) }
                guard dependencies.nowMs() >= signer.addedAtMs + E2EEAutoLog.signerMinAgeMs else { return .tooRecent }
            }
            guard let previousEntry = account.lastEntryHash else { return .failed("e2ee-auto-history-key-state") }
            // Une HK déjà tirée et peut-être écrite (réponse perdue) repart telle quelle (§5.1 point 5).
            let hkPubB64: String
            do {
                if let pending = dependencies.pendingKey(), dependencies.holds(pending) {
                    hkPubB64 = pending
                } else {
                    hkPubB64 = try dependencies.create()
                    dependencies.recordPendingKey(hkPubB64)
                }
            } catch {
                return .failed("e2ee-auto-history-key-store")
            }
            let body: Data
            do {
                let payload = E2EEAutoHistoryKeyContract.payload(
                    userId: dependencies.userId, prevUserEntryHash: previousEntry, signerDeviceId: device.deviceId,
                    previousHkPubB64: current, hkPubB64: hkPubB64
                )
                let signature = try dependencies.sign(Data(payload.utf8)).base64EncodedString()
                body = try E2EEAutoHistoryKeyContract.body(
                    prevUserEntryHash: previousEntry, previousHkPubB64: current, hkPubB64: hkPubB64, signatureB64: signature
                )
            } catch {
                return .failed("e2ee-auto-history-key-signature")
            }
            switch await post(E2EEAutoHistoryKeyContract.path, body) {
            case .success(let data, _, _):
                guard E2EEAutoHistoryKeyContract.parse(
                    data, userId: dependencies.userId, signerDeviceId: device.deviceId, previousHkPubB64: current,
                    hkPubB64: hkPubB64, signingKeyB64: device.publicSigningKeyB64
                ) else { return .failed("invalid-e2ee-auto-history-key-response") }
                // La relecture du journal installe la clé ; la déclaration n'en dépend pas.
                return await reportPresent(device: device, hkPubB64: hkPubB64)
            case .failure(let failure):
                switch failure.code {
                case "E2EE_HISTORY_KEY_STALE":
                    // Comparaison-échange perdue : la gagnante arrivera par la synchro,
                    // la passkey ou « C'est moi ». La sienne ne sert plus à rien.
                    try? dependencies.discard(hkPubB64)
                    dependencies.recordPendingKey(nil)
                case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
                case "E2EE_DEVICE_TOO_RECENT": return .tooRecent
                case "E2EE_HISTORY_KEY_RATE_LIMITED": return .retryLater(afterSeconds: failure.retryAfterSeconds)
                case "E2EE_HISTORY_KEY_REQUEST_INVALID": return .failed("e2ee-auto-history-key-refused")
                default:
                    if failure.statusCode == 429 { return .retryLater(afterSeconds: failure.retryAfterSeconds) }
                    let action = E2EEAutoEnrollmentPolicy.action(for: failure, keyVersion: device.keyVersion)
                    guard action == .rereadAndResign || action == .signerNotFound else {
                        switch action {
                        case .retryLater, .logClosed: return .retryLater(afterSeconds: failure.retryAfterSeconds)
                        default: return .failed("e2ee-auto-history-key-refused")
                        }
                    }
                }
                // Un seul nouvel essai après relecture ; le second refus attend la prochaine occasion.
                guard attempt == 0 else { return .retryLater(afterSeconds: nil) }
                switch await dependencies.readOwnAccount() {
                case .verified(let state): account = state
                case .refused: return .logRefused
                case .inconclusive: return .retryLater(afterSeconds: nil)
                }
            }
        }
        return .retryLater(afterSeconds: nil)
    }

    /// La HK tirée ici est au journal, ou une autre a gagné : le marqueur tombe,
    /// et une clé jamais publiée quitte le trousseau. Sans HK au journal, elle
    /// reste pour être renvoyée telle quelle.
    private func settlePendingKey(current: String?) {
        guard let pending = dependencies.pendingKey(), let current else { return }
        if pending != current { try? dependencies.discard(pending) }
        dependencies.recordPendingKey(nil)
    }

    /// `PUT history-status` une fois par appareil et par HK : l'information ne
    /// choisit que les destinataires des notifications, jamais la sécurité.
    private func reportPresent(device: E2EEV2DeviceDescriptor, hkPubB64: String) async -> Outcome {
        let marker = "\(device.deviceId):\(hkPubB64)"
        guard dependencies.reportedStatus() != marker else { return .present(hkPubB64: hkPubB64) }
        guard let body = try? E2EEAutoHistoryKeyContract.statusBody(present: true) else { return .present(hkPubB64: hkPubB64) }
        if case .success = await put(E2EEAutoHistoryKeyContract.historyStatusPath(deviceId: device.deviceId), body) {
            dependencies.recordReportedStatus(marker)
        }
        return .present(hkPubB64: hkPubB64)
    }

    /// Un refus d'horodatage donne l'heure du serveur : une seule nouvelle signature (révision 8).
    private func post(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.post(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.post(path, body, clockOffsetMs)
    }

    private func put(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.put(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.put(path, body, clockOffsetMs)
    }
}

extension E2EEAutoHistoryKeyPublication {
    /// Marqueurs propres à l'appareil, hors du trousseau synchronisé : la HK tirée
    /// ici en attente de publication, et la dernière déclaration `present`.
    static func pendingKey(ownerNamespace: String) -> String { "e2ee-auto-hk-pending-v1:\(ownerNamespace)" }
    static func reportedStatusKey(ownerNamespace: String) -> String { "e2ee-auto-hk-status-v1:\(ownerNamespace)" }

    /// Publication pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        historyKeys: E2EEAutoHistoryKeyStore = E2EEAutoHistoryKeyStore()
    ) -> E2EEAutoHistoryKeyPublication? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let pendingKey = pendingKey(ownerNamespace: namespace), statusKey = reportedStatusKey(ownerNamespace: namespace)
        return E2EEAutoHistoryKeyPublication(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            post: { path, body, clockOffsetMs in
                await transport.postJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            put: { path, body, clockOffsetMs in
                await transport.putJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) },
            holds: { hkPubB64 in (try? historyKeys.scalar(userId: userId, hkPubB64: hkPubB64)) != nil },
            create: {
                guard session.isCurrent else { throw E2EEV2DeviceIdentityError.unauthenticated }
                return try historyKeys.create(userId: userId)
            },
            discard: { try historyKeys.discard(userId: userId, hkPubB64: $0) },
            pendingKey: { try? markerStore.string(for: pendingKey) },
            recordPendingKey: { value in
                if let value {
                    try? markerStore.set(value, for: pendingKey, accessibility: .afterFirstUnlock)
                } else {
                    try? markerStore.remove(pendingKey)
                }
            },
            reportedStatus: { try? markerStore.string(for: statusKey) },
            recordReportedStatus: { try? markerStore.set($0, for: statusKey, accessibility: .afterFirstUnlock) }
        ))
    }
}

extension E2EEAutoHistoryKeyPublication.Outcome {
    /// Étape pour la trace, sans clé ni identifiant.
    var traceStep: String {
        switch self {
        case .present: return "present"
        case .missing: return "missing"
        case .notActive: return "not-active"
        case .tooRecent: return "too-recent"
        case .retryLater: return "retry-later"
        case .logRefused: return "log-refused"
        case .failed(let reason): return reason
        }
    }
}
