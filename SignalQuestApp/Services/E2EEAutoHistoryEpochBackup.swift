import Foundation

/// Sauvegarde des époques vers HK (E2EE-AUTO §5.2) : rattrapage des époques
/// reçues ici sans enveloppe déposée par cet appareil sous la dernière HK, et
/// restauration des enveloppes du compte sous toutes ses HK détenues.
enum E2EEAutoHistoryEpochContract {
    static let restorePath = "/api/e2ee/auto/history-epochs"
    static let backfillPath = "/api/e2ee/auto/history-epochs/backfill"
    static let maxRestoreItems = 50
    static let maxBackfillItems = 5

    static func depositPath(conversationId: String, epochNumber: Int) -> String {
        "/api/e2ee/auto/conversations/\(conversationId)/epochs/\(epochNumber)/history-envelopes"
    }

    /// Vue d'époque de la v2 (entiers en chaînes décimales), `e2eeAuto` présent seulement à `true`.
    struct Epoch: Equatable, Sendable {
        let epochId: String
        let epochNumber: Int
        let keyCommitmentB64: String
    }

    struct BackfillItem: Equatable, Sendable {
        let conversationId: String
        let epoch: Epoch
        /// Le serveur a encore l'enveloppe d'appareil complète ; sinon elle est accusée.
        let hasDeviceEnvelope: Bool
    }

    struct BackfillPage: Equatable, Sendable {
        let hkPubB64: String?
        let items: [BackfillItem]
        let nextCursor: String?
    }

    struct RestoreItem: Equatable, Sendable {
        let historyEnvelopeId: String
        let conversationId: String
        let epoch: Epoch
        let senderDeviceId: String
        let envelope: E2EEAutoHistory.EpochEnvelope
    }

    struct RestorePage: Equatable, Sendable {
        let missingEpochCount: Int
        let items: [RestoreItem]
        let nextCursor: String?
    }

    private static let epochKeys: Set<String> = ["epochId", "epochNumber", "algorithm", "keyCommitmentB64", "reason", "status", "createdAt"]
    private static let deviceEnvelopeKeys: Set<String> = [
        "recipientDeviceId", "senderDeviceId", "wrapAlgorithm", "ephemeralPublicKeyB64", "wrappedEpochKeyB64",
        "nonceB64", "aadB64", "signatureB64",
    ]

    static func epoch(_ value: Any?) -> Epoch? {
        guard let object = value as? [String: Any] else { return nil }
        var keys = Set(object.keys)
        if keys.contains("e2eeAuto") {
            // Jamais servi à `false` : refusé comme une clé inconnue (§7.2).
            guard let flag = object["e2eeAuto"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else { return nil }
            keys.remove("e2eeAuto")
        }
        guard keys == epochKeys,
              let epochId = object["epochId"] as? String, E2EEV2Canonical.isOpaque(epochId),
              let number = decimal(object["epochNumber"]), number >= 1,
              object["algorithm"] is String, object["reason"] is String, object["status"] is String, object["createdAt"] is String,
              let commitment = object["keyCommitmentB64"] as? String,
              E2EEAutoLog.canonicalBase64(commitment)?.count == 32 else { return nil }
        return Epoch(epochId: epochId, epochNumber: number, keyCommitmentB64: commitment)
    }

    static func parseBackfill(_ data: Data) -> BackfillPage? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["hkPubB64", "nextCursor", "items"],
              let rawItems = root["items"] as? [Any], rawItems.count <= maxBackfillItems,
              let nextCursor = nullableOpaque(root["nextCursor"]) else { return nil }
        let hkPubB64: String?
        if root["hkPubB64"] is NSNull {
            hkPubB64 = nil
            guard rawItems.isEmpty, nextCursor == .some(nil) else { return nil }
        } else {
            guard let value = root["hkPubB64"] as? String, E2EEAutoLog.isPublicKey(value) else { return nil }
            hkPubB64 = value
        }
        var items: [BackfillItem] = []
        var seen = Set<String>()
        for raw in rawItems {
            guard let item = raw as? [String: Any], Set(item.keys) == ["conversationId", "epoch", "deviceEnvelope"],
                  let conversationId = item["conversationId"] as? String, E2EEV2Canonical.isOpaque(conversationId),
                  let epoch = epoch(item["epoch"]), seen.insert(epoch.epochId).inserted else { return nil }
            let hasDeviceEnvelope: Bool
            if item["deviceEnvelope"] is NSNull {
                hasDeviceEnvelope = false
            } else {
                guard let envelope = item["deviceEnvelope"] as? [String: Any], Set(envelope.keys) == deviceEnvelopeKeys else { return nil }
                hasDeviceEnvelope = true
            }
            items.append(BackfillItem(conversationId: conversationId, epoch: epoch, hasDeviceEnvelope: hasDeviceEnvelope))
        }
        return BackfillPage(hkPubB64: hkPubB64, items: items, nextCursor: nextCursor ?? nil)
    }

    static func parseRestore(_ data: Data) -> RestorePage? {
        guard data.count <= E2EEV2APITransport.maxJSONResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["missingEpochCount", "nextCursor", "items"],
              let missing = decimal(root["missingEpochCount"]), missing >= 0,
              let rawItems = root["items"] as? [Any], rawItems.count <= maxRestoreItems,
              let nextCursor = nullableOpaque(root["nextCursor"]) else { return nil }
        var items: [RestoreItem] = []
        var seen = Set<String>()
        for raw in rawItems {
            guard let item = raw as? [String: Any],
                  Set(item.keys) == ["historyEnvelopeId", "conversationId", "epoch", "senderDeviceId", "envelope"],
                  let id = item["historyEnvelopeId"] as? String, E2EEV2Canonical.isOpaque(id), seen.insert(id).inserted,
                  let conversationId = item["conversationId"] as? String, E2EEV2Canonical.isOpaque(conversationId),
                  let epoch = epoch(item["epoch"]),
                  let sender = item["senderDeviceId"] as? String, E2EEV2Canonical.isOpaque(sender),
                  let rawEnvelope = item["envelope"] as? [String: Any],
                  let envelope = E2EEAutoHistory.parseEpochEnvelope(rawEnvelope) else { return nil }
            items.append(RestoreItem(
                historyEnvelopeId: id, conversationId: conversationId, epoch: epoch, senderDeviceId: sender, envelope: envelope
            ))
        }
        return RestorePage(missingEpochCount: missing, items: items, nextCursor: nextCursor ?? nil)
    }

    /// Réponse `201` du dépôt : les trois identifiants, pour cette conversation et cette époque.
    static func depositAccepted(_ data: Data, conversationId: String, epochId: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["historyEnvelopeId", "conversationId", "epochId"],
              let id = root["historyEnvelopeId"] as? String, E2EEV2Canonical.isOpaque(id) else { return false }
        return root["conversationId"] as? String == conversationId && root["epochId"] as? String == epochId
    }

    /// Entier en chaîne décimale canonique.
    private static func decimal(_ value: Any?) -> Int? {
        guard let text = value as? String, text.range(of: #"^(0|[1-9][0-9]{0,15})\z"#, options: .regularExpression) != nil else { return nil }
        return Int(text)
    }

    /// `.some(nil)` pour `null`, `nil` pour une valeur mal formée.
    private static func nullableOpaque(_ value: Any?) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let text = value as? String, E2EEV2Canonical.isOpaque(text) else { return nil }
        return .some(text)
    }
}

/// Rattrapage et restauration, l'état venant toujours du journal vérifié du compte.
actor E2EEAutoHistoryEpochBackup {
    /// Clé d'époque rangée ici par la synchro vérifiée ou une restauration.
    struct LocalEpoch: Equatable, Sendable {
        let epochId: String
        let keyCommitmentB64: String
        let epochKey: Data
    }

    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var get: @Sendable (_ path: String, _ query: [URLQueryItem]) async -> E2EEV2TransportResult<Data>
        var post: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        /// Scalaire d'une HK détenue.
        var scalar: @Sendable (_ hkPubB64: String) -> Data?
        var localEpoch: @Sendable (_ conversationId: String, _ epochNumber: Int) -> LocalEpoch?
        /// Range une clé restaurée, jamais à la place d'une clé reçue par la synchro.
        var storeRestored: @Sendable (_ conversationId: String, _ epoch: E2EEAutoHistoryEpochContract.Epoch, _ epochKey: Data) -> Bool
        /// Époques sans enveloppe d'appareil ni clé locale : terminées, le serveur les rend à chaque passage.
        var finishedEpochIds: @Sendable () -> Set<String>
        var recordFinished: @Sendable (_ epochId: String) -> Void
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
        /// Un maillon à preuve existe vers cette HK de rotation (r23) ; sans lecture : non.
        var vouched: @Sendable (_ account: E2EEAutoLog.AccountState, _ rotation: E2EEAutoLog.HistoryKeyRecord) async -> Bool = { _, _ in false }
    }

    enum Outcome: Equatable, Sendable {
        case backedUp(Int)
        case restored(Int, missingEpochCount: Int)
        /// Le compte n'a pas de HK, ou l'appareil ne détient pas la dernière.
        case noHistoryKey
        /// Un `REVOKE` attend sa rotation : l'appareil révoqué détient encore la dernière HK (§5.2 S3, condition 2).
        case rotationDue
        /// La dernière HK est une rotation publiée ailleurs, sans maillon à preuve (§5.2 S3 condition 3, r23).
        case unvouched
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0
    private static let maxPages = 2_000

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Enveloppe vers la dernière HK chaque époque reçue ici qui n'y est pas encore (§5.2).
    /// Les dépôts suivent la cadence partagée avec l'import des messages v1 (N1-6).
    func backfill(pacer: APIWritePacer? = .shared) async -> Outcome {
        await APIWritePacer.$current.withValue(pacer) { await backfillPages() }
    }

    private func backfillPages() async -> Outcome {
        let device: E2EEV2DeviceDescriptor
        do { device = try dependencies.device() } catch { return .failed("e2ee-auto-device-unavailable") }
        var account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater(afterSeconds: nil)
        }
        var cursor: String?
        var seenCursors = Set<String>()
        var backedUp = 0
        var reread = false
        for _ in 0..<Self.maxPages {
            guard let hk = account.historyKeyPubB64, dependencies.scalar(hk) != nil else { return .noHistoryKey }
            if let refusal = await depositRefusal(account, hk: hk, device: device) { return refusal }
            let response = await dependencies.get(
                E2EEAutoHistoryEpochContract.backfillPath, cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            )
            let page: E2EEAutoHistoryEpochContract.BackfillPage
            switch response {
            case .success(let data, _, _):
                guard let parsed = E2EEAutoHistoryEpochContract.parseBackfill(data) else {
                    return .failed("invalid-e2ee-auto-history-backfill-page")
                }
                page = parsed
            case .failure(let failure):
                return Self.outcome(failure)
            }
            // `hkPubB64` n'est qu'un indice : s'il diffère, le compte est relu une fois.
            if page.hkPubB64 != hk {
                guard !reread else { return .retryLater(afterSeconds: nil) }
                reread = true
                switch await dependencies.readOwnAccount() {
                case .verified(let state): account = state
                case .refused: return .logRefused
                case .inconclusive: return .retryLater(afterSeconds: nil)
                }
                cursor = nil
                seenCursors = []
                continue
            }
            let finished = dependencies.finishedEpochIds()
            for item in page.items where !finished.contains(item.epoch.epochId) {
                // On n'enveloppe que ce qu'on a reçu, vérifié par la synchro : une clé pas
                // encore rangée attend le prochain passage, une enveloppe accusée sans clé est perdue ici.
                guard let local = dependencies.localEpoch(item.conversationId, item.epoch.epochNumber),
                      local.epochId == item.epoch.epochId, local.keyCommitmentB64 == item.epoch.keyCommitmentB64 else {
                    if !item.hasDeviceEnvelope { dependencies.recordFinished(item.epoch.epochId) }
                    continue
                }
                switch await deposit(item, epochKey: local.epochKey, hk: hk, device: device) {
                case .written: backedUp += 1
                case .exists: break
                case .stop(let outcome): return outcome
                }
            }
            guard let next = page.nextCursor else { return .backedUp(backedUp) }
            guard seenCursors.insert(next).inserted else { return .failed("invalid-e2ee-auto-history-cursor") }
            cursor = next
        }
        return .failed("e2ee-auto-history-pagination-limit")
    }

    /// §5.2 amendement S3, conditions 2 et 3, pour un appareil qui détient la dernière HK :
    /// rien pendant une rotation due ; une rotation publiée par un autre appareil n'est
    /// utilisée qu'avec un maillon à preuve, puisqu'un transfert a pu la donner. La première
    /// HK et une HK hors rotation détenue (création, « C'est moi », passkey, synchro) suffisent.
    private func depositRefusal(_ account: E2EEAutoLog.AccountState, hk: String, device: E2EEV2DeviceDescriptor) async -> Outcome? {
        guard account.rotationDueRevokeSeq == nil else { return .rotationDue }
        guard let record = account.historyKeys.last, record.hkPubB64 == hk, record.afterRevokeSeq != nil,
              record.previousHkPubB64 != nil, record.signerDeviceId != device.deviceId else { return nil }
        return await dependencies.vouched(account, record) ? nil : .unvouched
    }

    private enum Deposit { case written, exists, stop(Outcome) }

    private func deposit(
        _ item: E2EEAutoHistoryEpochContract.BackfillItem, epochKey: Data, hk: String, device: E2EEV2DeviceDescriptor
    ) async -> Deposit {
        let body: Data
        do {
            let envelope = try E2EEAutoHistory.sealEpoch(
                epochKey: epochKey, keyCommitmentB64: item.epoch.keyCommitmentB64, userId: dependencies.userId,
                conversationId: item.conversationId, epochNumber: item.epoch.epochNumber, senderDeviceId: device.deviceId,
                hkPubB64: hk, sign: dependencies.sign
            )
            body = try E2EEAutoHistory.epochUploadBody(envelope)
        } catch {
            return .stop(.failed("e2ee-auto-history-envelope"))
        }
        let path = E2EEAutoHistoryEpochContract.depositPath(conversationId: item.conversationId, epochNumber: item.epoch.epochNumber)
        switch await post(path, body) {
        case .success(let data, _, _):
            guard E2EEAutoHistoryEpochContract.depositAccepted(data, conversationId: item.conversationId, epochId: item.epoch.epochId) else {
                return .stop(.failed("invalid-e2ee-auto-history-deposit-response"))
            }
            return .written
        case .failure(let failure):
            switch failure.code {
            case "E2EE_HISTORY_ENVELOPE_EXISTS": return .exists
            // L'époque n'est plus à cet appareil ou à ce compte : rien à sauver ici.
            case "E2EE_EPOCH_NOT_FOUND", "E2EE_EPOCH_ENVELOPE_NOT_FOUND": return .exists
            // La HK a changé : le prochain passage relit le compte.
            case "E2EE_HISTORY_KEY_STALE": return .stop(.retryLater(afterSeconds: nil))
            default: return .stop(Self.outcome(failure))
            }
        }
    }

    /// Restaure les époques enveloppées vers une HK détenue, chacune contrôlée face au journal (§5.2).
    func restore() async -> Outcome {
        var account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater(afterSeconds: nil)
        }
        let held = Set(account.historyKeys.map(\.hkPubB64).filter { dependencies.scalar($0) != nil })
        guard !held.isEmpty else { return .noHistoryKey }
        var cursor: String?
        var seenCursors = Set<String>()
        var restoredEpochIds = Set<String>()
        var missing = 0
        for _ in 0..<Self.maxPages {
            let response = await dependencies.get(
                E2EEAutoHistoryEpochContract.restorePath, cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            )
            let page: E2EEAutoHistoryEpochContract.RestorePage
            switch response {
            case .success(let data, _, _):
                guard let parsed = E2EEAutoHistoryEpochContract.parseRestore(data) else {
                    return .failed("invalid-e2ee-auto-history-restore-page")
                }
                page = parsed
            case .failure(let failure):
                return Self.outcome(failure)
            }
            missing = page.missingEpochCount
            for item in page.items where !restoredEpochIds.contains(item.epoch.epochId) {
                // Un élément refusé est ignoré, sans ligne de sécurité : l'époque reste illisible.
                guard E2EEAutoHistory.checkEpoch(
                    userId: dependencies.userId, conversationId: item.conversationId, epochNumber: item.epoch.epochNumber,
                    keyCommitmentB64: item.epoch.keyCommitmentB64, senderDeviceId: item.senderDeviceId,
                    envelope: item.envelope, account: account, heldHkPubB64s: held
                ) == nil, let scalar = dependencies.scalar(item.envelope.hkPubB64) else { continue }
                // Époque déjà connue : l'engagement signé doit être celui qu'on garde.
                if let local = dependencies.localEpoch(item.conversationId, item.epoch.epochNumber) {
                    if local.epochId == item.epoch.epochId, local.keyCommitmentB64 == item.epoch.keyCommitmentB64 {
                        restoredEpochIds.insert(item.epoch.epochId)
                    }
                    continue
                }
                guard var epochKey = try? E2EEAutoHistory.openEpoch(
                    item.envelope, scalar: scalar, userId: dependencies.userId, conversationId: item.conversationId,
                    epochNumber: item.epoch.epochNumber, senderDeviceId: item.senderDeviceId,
                    keyCommitmentB64: item.epoch.keyCommitmentB64
                ) else { continue }
                defer { epochKey.resetBytes(in: 0..<epochKey.count) }
                if dependencies.storeRestored(item.conversationId, item.epoch, epochKey) {
                    restoredEpochIds.insert(item.epoch.epochId)
                }
            }
            guard let next = page.nextCursor else { return .restored(restoredEpochIds.count, missingEpochCount: missing) }
            guard seenCursors.insert(next).inserted else { return .failed("invalid-e2ee-auto-history-cursor") }
            cursor = next
        }
        return .failed("e2ee-auto-history-pagination-limit")
    }

    private static func outcome(_ failure: E2EEV2TransportFailure) -> Outcome {
        switch failure.code {
        case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
        case "E2EE_HISTORY_ENVELOPE_RATE_LIMITED": return .retryLater(afterSeconds: failure.retryAfterSeconds)
        case "E2EE_HISTORY_ENVELOPE_REQUEST_INVALID", "E2EE_HISTORY_ENVELOPE_INVALID", "E2EE_HISTORY_EPOCH_QUERY_INVALID",
             "E2EE_HISTORY_RECIPIENT_FORBIDDEN":
            // Défaut de l'app : pas de nouvel essai.
            return .failed("e2ee-auto-history-refused")
        default:
            // `429`, journal fermé, réseau : on reprend plus tard là où on s'est arrêté.
            return .retryLater(afterSeconds: failure.retryAfterSeconds)
        }
    }

    /// Un refus d'horodatage donne l'heure du serveur : une seule nouvelle signature (révision 8).
    private func post(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.post(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.post(path, body, clockOffsetMs)
    }
}

extension E2EEAutoHistoryEpochBackup.Outcome {
    /// Étape pour la trace, sans identifiant.
    var traceStep: String {
        switch self {
        case .backedUp(let count): return "backed-up-\(count)"
        case .restored(let count, let missing): return "restored-\(count)-missing-\(missing)"
        case .noHistoryKey: return "no-history-key"
        case .rotationDue: return "rotation-due"
        case .unvouched: return "unvouched"
        case .notActive: return "not-active"
        case .retryLater: return "retry-later"
        case .logRefused: return "log-refused"
        case .failed(let reason): return reason
        }
    }
}

extension E2EEAutoHistoryEpochBackup {
    static func finishedKey(ownerNamespace: String) -> String { "e2ee-auto-history-finished-v1:\(ownerNamespace)" }

    /// Sauvegarde pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        historyKeys: E2EEAutoHistoryKeyStore = E2EEAutoHistoryKeyStore()
    ) -> E2EEAutoHistoryEpochBackup? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let finishedKey = finishedKey(ownerNamespace: namespace)
        let finished: @Sendable () -> Set<String> = {
            guard let raw = try? markerStore.string(for: finishedKey),
                  let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
            return Set(list)
        }
        return E2EEAutoHistoryEpochBackup(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            get: { path, query in
                await transport.getJSON(path: path, query: query, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            },
            post: { path, body, clockOffsetMs in
                await transport.postJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) },
            scalar: { try? historyKeys.scalar(userId: userId, hkPubB64: $0) },
            localEpoch: { conversationId, epochNumber in
                guard session.isCurrent,
                      let stored = try? keyStore.loadEpoch(
                          conversationId: conversationId, epochNumber: epochNumber, ownerNamespace: namespace, includeRestored: true
                      ) else { return nil }
                return LocalEpoch(epochId: stored.epochId, keyCommitmentB64: stored.keyCommitmentB64, epochKey: stored.epochKey)
            },
            storeRestored: { conversationId, epoch, epochKey in
                (try? keyStore.put(
                    recordInput: .init(
                        conversationId: conversationId, epochId: epoch.epochId, epochNumber: epoch.epochNumber,
                        keyCommitmentB64: epoch.keyCommitmentB64
                    ),
                    epochKey: epochKey, ownerNamespace: namespace, expectedSession: session, origin: .restored
                )) == true
            },
            finishedEpochIds: finished,
            recordFinished: { epochId in
                var list = finished()
                guard list.insert(epochId).inserted,
                      let data = try? JSONEncoder().encode(list.sorted()) else { return }
                try? markerStore.set(String(decoding: data, as: UTF8.self), for: finishedKey, accessibility: .afterFirstUnlock)
            },
            vouched: E2EEAutoHistoryRotation.liveVouching(session: session, api: api, identityStore: identityStore)
        ))
    }
}
