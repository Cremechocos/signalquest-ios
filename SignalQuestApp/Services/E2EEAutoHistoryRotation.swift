import CryptoKit
import Foundation

/// Rotation de HK après un `REVOKE` vérifié (E2EE-AUTO §5.6, révision 11) : routes,
/// corps exacts et lecture stricte des réponses.
enum E2EEAutoHistoryRotationContract {
    static let proofsPath = "/api/e2ee/auto/history-key/rotation-proofs"
    static let transfersPath = "/api/e2ee/auto/history-key/transfers"

    /// `{hkPub}` : les 65 octets en `b64url` sans bourrage.
    static func pathParam(_ hkPubB64: String) -> String? {
        guard E2EEAutoLog.isPublicKey(hkPubB64), let bytes = Data(base64Encoded: hkPubB64) else { return nil }
        return bytes.base64URLEncodedNoPadding()
    }

    static func chainPath(_ hkPubB64: String) -> String? {
        pathParam(hkPubB64).map { "/api/e2ee/auto/history-key/chain/\($0)" }
    }

    static func proofsQueryPath(hkPubB64: String, revokeSeq: Int64) -> String? {
        guard revokeSeq >= 1, let param = pathParam(hkPubB64) else { return nil }
        return "\(proofsPath)?hkPub=\(param)&revokeSeq=\(revokeSeq)"
    }

    static func proofBody(hkPubB64: String, revokeSeq: Int64, signatureB64: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["hkPubB64": hkPubB64, "revokeSeq": String(revokeSeq), "signatureB64": signatureB64], options: [.sortedKeys]
        )
    }

    static func wrapBody(_ wrap: E2EEAutoHistory.Wrap) throws -> Data {
        try JSONSerialization.data(withJSONObject: wrap.jsonObject, options: [.sortedKeys])
    }

    /// `201 { deviceId, hkPubB64, revokeSeq, createdAtMs }` (ou `200` au rejeu).
    static func parseProofReceipt(_ data: Data, deviceId: String, hkPubB64: String, revokeSeq: Int64) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["deviceId", "hkPubB64", "revokeSeq", "createdAtMs"],
              decimal(object["createdAtMs"]) != nil else { return false }
        return object["deviceId"] as? String == deviceId && object["hkPubB64"] as? String == hkPubB64
            && decimal(object["revokeSeq"]) == revokeSeq
    }

    struct Proof: Equatable, Sendable {
        let deviceId: String
        let signatureB64: String
    }

    /// `{ proofs: [{ deviceId, hkPubB64, revokeSeq, signatureB64, createdAtMs }] }` pour cette
    /// HK et ce `revokeSeq` ; une ligne d'une autre clé rend toute la page invalide.
    static func parseProofs(_ data: Data, hkPubB64: String, revokeSeq: Int64) -> [Proof]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["proofs"], let rows = object["proofs"] as? [Any] else { return nil }
        var proofs: [Proof] = []
        for row in rows {
            guard let item = row as? [String: Any],
                  Set(item.keys) == ["deviceId", "hkPubB64", "revokeSeq", "signatureB64", "createdAtMs"],
                  let deviceId = item["deviceId"] as? String, E2EEV2Canonical.isOpaque(deviceId),
                  item["hkPubB64"] as? String == hkPubB64, decimal(item["revokeSeq"]) == revokeSeq,
                  let signatureB64 = item["signatureB64"] as? String, decimal(item["createdAtMs"]) != nil else { return nil }
            proofs.append(Proof(deviceId: deviceId, signatureB64: signatureB64))
        }
        return proofs
    }

    /// `{ <key>: [history-wrap-v1…] }` : `links` pour la chaîne, `transfers` pour les transferts.
    static func parseWraps(_ data: Data, key: String) -> [E2EEAutoHistory.Wrap]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [key], let rows = object[key] as? [Any] else { return nil }
        var wraps: [E2EEAutoHistory.Wrap] = []
        for row in rows {
            guard let raw = row as? [String: Any], let wrap = E2EEAutoHistory.parseWrap(raw) else { return nil }
            wraps.append(wrap)
        }
        return wraps
    }

    /// `201 { hkPubB64, nextHkPubB64 }`.
    static func parseChainReceipt(_ data: Data, hkPubB64: String, nextHkPubB64: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["hkPubB64", "nextHkPubB64"] else { return false }
        return object["hkPubB64"] as? String == hkPubB64 && object["nextHkPubB64"] as? String == nextHkPubB64
    }

    /// Maillon à preuve (révision 23, « Preuve exigée du maillon ») : un maillon vers HK′ qui
    /// passe les contrôles publics du §5.6 étape 2, déposé par un appareil qui a aussi prouvé
    /// détenir la HK précédente pour `afterRevokeSeq` de HK′. Le lecteur ne peut pas ouvrir le
    /// maillon ; la preuve, signée par la clé précédente elle-même, montre que son émetteur la
    /// détenait. Clé admissible : la précédente littérale (la base de r23 viendra ensuite).
    static func isVouched(
        userId: String, account: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord,
        links: [E2EEAutoHistory.Wrap], proofs: [Proof]
    ) -> Bool {
        guard let previous = rotation.previousHkPubB64, let revokeSeq = rotation.afterRevokeSeq else { return false }
        let reader = E2EEAutoHistory.Reader.history(hkPubB64: rotation.hkPubB64)
        let senders = Set(links.filter {
            E2EEAutoHistory.check(userId: userId, wrap: $0, account: account, reader: reader) == nil
        }.map(\.senderDeviceId))
        return proofs.contains {
            senders.contains($0.deviceId) && E2EEAutoHistoryKey.verifyProof(
                userId: userId, deviceId: $0.deviceId, hkPubB64: previous, revokeSeq: revokeSeq, signatureB64: $0.signatureB64
            )
        }
    }

    /// `201 { recipientDeviceId, requestId }`.
    static func parseTransferReceipt(_ data: Data, recipient: String, requestId: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["recipientDeviceId", "requestId"] else { return false }
        return object["recipientDeviceId"] as? String == recipient && object["requestId"] as? String == requestId
    }

    private static func decimal(_ value: Any?) -> Int64? {
        guard let text = value as? String else { return nil }
        return E2EEAutoLog.decimal(text, in: 0...E2EEV2Canonical.maxSafeInteger)
    }
}

/// Les étapes du §5.6 vues d'un appareil, l'état venant toujours du journal vérifié :
/// preuve de possession à la vue d'un `REVOKE`, publication de HK′ si l'appareil est
/// éligible, maillon de chaîne vers HK′, service des preuves (règle de l'émetteur,
/// `servedDevices`), réception d'un transfert, et remontée de la chaîne pour ouvrir
/// l'historique d'avant les rotations. Chaque dépôt est idempotent côté serveur ; un
/// marqueur local évite seulement de le refaire à chaque passage.
actor E2EEAutoHistoryRotation {
    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var get: @Sendable (_ path: String) async -> E2EEV2TransportResult<Data>
        var post: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var put: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        var scalar: @Sendable (_ hkPubB64: String) -> Data?
        var keep: @Sendable (_ scalar: Data) throws -> String
        var heldKeyVersions: @Sendable () throws -> [Int]
        /// Ouvre une enveloppe vers cet appareil sans que sa clé d'accord quitte le magasin.
        var openWrap: @Sendable (_ wrap: E2EEAutoHistory.Wrap) throws -> Data
        /// Publication de HK′ (§5.1, CAS) ; mode rotation de `E2EEAutoHistoryKeyPublication`.
        var rotate: @Sendable () async -> E2EEAutoHistoryKeyPublication.Outcome
        /// HK reçue : `present` déclaré (publication, mode normal).
        var declarePresent: @Sendable () async -> Void
        var isDone: @Sendable (_ marker: String) -> Bool
        var recordDone: @Sendable (_ marker: String) -> Void
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    /// Ce qu'un passage a fait, pour la trace.
    struct Report: Equatable, Sendable {
        var proofDeposited = false
        var rotated = false
        var chainDeposited = false
        var served: [String] = []
        var received = false
        /// HK anciennes obtenues par la chaîne.
        var chained = 0
        var stopped: String?

        var traceStep: String {
            if let stopped { return stopped }
            var parts: [String] = []
            if proofDeposited { parts.append("proof") }
            if rotated { parts.append("rotated") }
            if chainDeposited { parts.append("chain") }
            if !served.isEmpty { parts.append("served-\(served.count)") }
            if received { parts.append("received") }
            if chained > 0 { parts.append("chained-\(chained)") }
            return parts.isEmpty ? "idle" : parts.joined(separator: "+")
        }
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func run() async -> Report {
        var report = Report()
        guard let device = try? dependencies.device() else { report.stopped = "e2ee-auto-device-unavailable"; return report }
        guard var account = await activeAccount(device: device, report: &report) else { return report }

        // Destinataire : HK′ par un transfert sur sa preuve (§5.6 étape 4).
        if let latest = account.historyKeys.last, latest.hkPubB64 == account.historyKeyPubB64,
           dependencies.scalar(latest.hkPubB64) == nil, latest.afterRevokeSeq != nil,
           let previous = latest.previousHkPubB64, dependencies.scalar(previous) != nil {
            report.received = await receiveTransfer(device: device, account: account, rotation: latest, held: previous)
            if report.received { await dependencies.declarePresent() }
        }

        // À la vue du REVOKE : preuve de possession, puis HK′ si l'appareil est éligible.
        if let revokeSeq = account.rotationDueRevokeSeq, let current = account.historyKeyPubB64,
           let scalar = dependencies.scalar(current) {
            report.proofDeposited = await depositProof(device: device, hkPubB64: current, revokeSeq: revokeSeq, scalar: scalar)
            if case .present(let published) = await dependencies.rotate(), published != current {
                report.rotated = true
                guard let reread = await activeAccount(device: device, report: &report) else { return report }
                account = reread
            }
        }

        // Détenteur de HK′ : maillon vers HK′ et service des preuves.
        if let rotation = account.historyKeys.last, rotation.hkPubB64 == account.historyKeyPubB64,
           let previous = rotation.previousHkPubB64, let revokeSeq = rotation.afterRevokeSeq,
           let nextScalar = dependencies.scalar(rotation.hkPubB64) {
            // Notre maillon rendrait HK′ vérifiée : jamais pour une HK′ d'un autre qui ne l'est pas
            // déjà (une clé reçue par une build sans la porte à preuve, par exemple).
            if let oldScalar = dependencies.scalar(previous), Self.eligibleForChain(account.devices[device.deviceId], rotation: rotation) {
                var trusted = rotation.signerDeviceId == device.deviceId
                if !trusted { trusted = await isVouched(account: account, rotation: rotation) }
                if trusted {
                    // La preuve suit `afterRevokeSeq` de HK′, même si un REVOKE est venu après la nôtre (r23, T5).
                    _ = await depositProof(device: device, hkPubB64: previous, revokeSeq: revokeSeq, scalar: oldScalar)
                    report.chainDeposited = await depositChain(device: device, rotation: rotation, previous: previous, oldScalar: oldScalar)
                }
            }
            report.served = await serveProofs(device: device, account: account, rotation: rotation, scalar: nextScalar)
        }

        report.chained = await followChain(account: account)
        return report
    }

    // MARK: Compte

    private func activeAccount(device: E2EEV2DeviceDescriptor, report: inout Report) async -> E2EEAutoLog.AccountState? {
        switch await dependencies.readOwnAccount() {
        case .verified(let state):
            guard let own = state.devices[device.deviceId], own.signingKeyB64 == device.publicSigningKeyB64,
                  own.status == .active else {
                report.stopped = "not-active"
                return nil
            }
            return state
        case .refused:
            report.stopped = "log-refused"
            return nil
        case .inconclusive:
            report.stopped = "retry-later"
            return nil
        }
    }

    /// Règle du lecteur de chaîne (§5.6 étape 2, révision 11), appliquée avant de déposer :
    /// actif à l'entrée de HK′, pas révoqué avant elle, inscrit depuis 24 h à ce moment.
    static func eligibleForChain(_ device: E2EEAutoLog.DeviceState?, rotation: E2EEAutoLog.HistoryKeyRecord) -> Bool {
        guard let device, let activatedAtMs = device.activatedAtMs, activatedAtMs <= rotation.createdAtMs,
              device.revokeSeq.map({ $0 > rotation.seq }) ?? true else { return false }
        return rotation.createdAtMs - device.addedAtMs >= E2EEAutoLog.signerMinAgeMs
    }

    // MARK: Étapes

    private func depositProof(device: E2EEV2DeviceDescriptor, hkPubB64: String, revokeSeq: Int64, scalar: Data) async -> Bool {
        let marker = "proof:\(device.deviceId):\(hkPubB64):\(revokeSeq)"
        guard !dependencies.isDone(marker) else { return false }
        guard let signature = E2EEAutoHistoryKey.signProof(
            userId: dependencies.userId, deviceId: device.deviceId, hkPubB64: hkPubB64, revokeSeq: revokeSeq, scalar: scalar
        ), let body = try? E2EEAutoHistoryRotationContract.proofBody(hkPubB64: hkPubB64, revokeSeq: revokeSeq, signatureB64: signature) else {
            return false
        }
        guard case .success(let data, _, _) = await post(E2EEAutoHistoryRotationContract.proofsPath, body),
              E2EEAutoHistoryRotationContract.parseProofReceipt(data, deviceId: device.deviceId, hkPubB64: hkPubB64, revokeSeq: revokeSeq) else {
            return false
        }
        dependencies.recordDone(marker)
        return true
    }

    /// L'ancienne HK enveloppée vers HK′ : `R` = `history:<HK′>`, `kv` = 1, `req` = `chain`.
    private func depositChain(
        device: E2EEV2DeviceDescriptor, rotation: E2EEAutoLog.HistoryKeyRecord, previous: String, oldScalar: Data
    ) async -> Bool {
        let marker = "chain:\(device.deviceId):\(previous)"
        guard !dependencies.isDone(marker), let path = E2EEAutoHistoryRotationContract.chainPath(previous),
              let nextKey = Data(base64Encoded: rotation.hkPubB64),
              let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: nextKey),
              let wrap = try? E2EEAutoHistory.seal(
                scalar: oldScalar, userId: dependencies.userId, senderDeviceId: device.deviceId,
                recipient: E2EEAutoHistory.historyRecipientPrefix + rotation.hkPubB64, keyVersion: 1,
                requestId: E2EEAutoHistory.chainRequest, addHash: rotation.entryHash,
                recipientAgreementKey: recipientKey, sign: dependencies.sign
              ),
              let body = try? E2EEAutoHistoryRotationContract.wrapBody(wrap) else { return false }
        switch await put(path, body) {
        case .success(let data, _, _):
            guard E2EEAutoHistoryRotationContract.parseChainReceipt(data, hkPubB64: previous, nextHkPubB64: rotation.hkPubB64) else { return false }
        case .failure(let failure):
            guard failure.code == "E2EE_HISTORY_CHAIN_EXISTS" else { return false }
        }
        dependencies.recordDone(marker)
        return true
    }

    /// HK′ seulement aux appareils actifs dont la preuve se vérifie avec l'ancienne HK
    /// et le `revokeSeq` de la rotation (règle de l'émetteur, révisions 7 et 9).
    private func serveProofs(
        device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord, scalar: Data
    ) async -> [String] {
        guard let previous = rotation.previousHkPubB64, let revokeSeq = rotation.afterRevokeSeq,
              let path = E2EEAutoHistoryRotationContract.proofsQueryPath(hkPubB64: previous, revokeSeq: revokeSeq),
              case .success(let data, _, _) = await dependencies.get(path),
              let proofs = E2EEAutoHistoryRotationContract.parseProofs(data, hkPubB64: previous, revokeSeq: revokeSeq) else { return [] }
        let eligible = E2EEAutoHistoryKey.servedDevices(
            state: account, rotation: rotation, proofs: proofs.map { ($0.deviceId, $0.signatureB64) }, selfDeviceId: device.deviceId
        )
        let requestId = "rotation-\(rotation.seq)"
        var served: [String] = []
        for deviceId in eligible {
            let marker = "transfer:\(device.deviceId):\(rotation.seq):\(deviceId)"
            guard !dependencies.isDone(marker), let recipient = account.devices[deviceId],
                  let keyData = Data(base64Encoded: recipient.identityKeyB64),
                  let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: keyData),
                  let wrap = try? E2EEAutoHistory.seal(
                    scalar: scalar, userId: dependencies.userId, senderDeviceId: device.deviceId, recipient: deviceId,
                    keyVersion: recipient.keyVersion, requestId: requestId, addHash: recipient.addEntryHash,
                    recipientAgreementKey: recipientKey, sign: dependencies.sign
                  ),
                  let body = try? E2EEAutoHistoryRotationContract.wrapBody(wrap) else { continue }
            switch await post(E2EEAutoHistoryRotationContract.transfersPath, body) {
            case .success(let data, _, _):
                guard E2EEAutoHistoryRotationContract.parseTransferReceipt(data, recipient: deviceId, requestId: requestId) else { continue }
            case .failure(let failure):
                switch failure.code {
                case "E2EE_HISTORY_TRANSFER_EXISTS": break
                // Une HK plus récente au journal : ce passage s'arrête, le suivant relit.
                case "E2EE_HISTORY_KEY_STALE": return served
                // Clé du destinataire changée : le prochain passage relit le journal.
                default: continue
                }
            }
            dependencies.recordDone(marker)
            served.append(deviceId)
        }
        return served
    }

    /// Le premier transfert de la dernière HK qui passe les vérifications du §5.6 étape 4.
    private func receiveTransfer(
        device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord, held: String
    ) async -> Bool {
        guard case .success(let data, _, _) = await dependencies.get(E2EEAutoHistoryRotationContract.transfersPath),
              let wraps = E2EEAutoHistoryRotationContract.parseWraps(data, key: "transfers"),
              let keyVersions = try? dependencies.heldKeyVersions() else { return false }
        let reader = E2EEAutoHistory.Reader.device(
            deviceId: device.deviceId, keyVersions: keyVersions, openRequestIds: [], heldHkPubB64: held
        )
        for wrap in wraps where wrap.requestId == "rotation-\(rotation.seq)" {
            guard E2EEAutoHistory.check(userId: dependencies.userId, wrap: wrap, account: account, reader: reader) == nil else { continue }
            // Sans maillon à preuve, HK′ n'est pas rangée : son émetteur peut ne pas avoir
            // détenu la HK précédente (r23, T1). Le passage suivant relit.
            guard await isVouched(account: account, rotation: rotation) else { return false }
            guard let scalar = try? dependencies.openWrap(wrap),
                  let kept = try? dependencies.keep(scalar), kept == rotation.hkPubB64 else { continue }
            return true
        }
        return false
    }

    /// Maillon à preuve vers HK′, retenu par un marqueur une fois vu : un maillon et une
    /// preuve déposés ne s'effacent pas.
    private func isVouched(account: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord) async -> Bool {
        let marker = Self.vouchedMarker(rotation.hkPubB64)
        if dependencies.isDone(marker) { return true }
        guard await Self.fetchVouched(userId: dependencies.userId, account: account, rotation: rotation, get: dependencies.get) else {
            return false
        }
        dependencies.recordDone(marker)
        return true
    }

    static func vouchedMarker(_ hkPubB64: String) -> String { "vouched:\(hkPubB64)" }

    /// Lit `chain/{précédente}` et les preuves de `(précédente, afterRevokeSeq)`, puis juge.
    static func fetchVouched(
        userId: String, account: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord,
        get: @Sendable (_ path: String) async -> E2EEV2TransportResult<Data>
    ) async -> Bool {
        guard let previous = rotation.previousHkPubB64, let revokeSeq = rotation.afterRevokeSeq,
              let chainPath = E2EEAutoHistoryRotationContract.chainPath(previous),
              let proofsPath = E2EEAutoHistoryRotationContract.proofsQueryPath(hkPubB64: previous, revokeSeq: revokeSeq),
              case .success(let linkData, _, _) = await get(chainPath),
              let links = E2EEAutoHistoryRotationContract.parseWraps(linkData, key: "links"), !links.isEmpty,
              case .success(let proofData, _, _) = await get(proofsPath),
              let proofs = E2EEAutoHistoryRotationContract.parseProofs(proofData, hkPubB64: previous, revokeSeq: revokeSeq) else {
            return false
        }
        return E2EEAutoHistoryRotationContract.isVouched(userId: userId, account: account, rotation: rotation, links: links, proofs: proofs)
    }

    /// De la plus récente HK détenue vers les plus anciennes : un `GET` par maillon, le
    /// premier qui passe les vérifications du §5.6 étape 2, ouvert avec le scalaire de HK′.
    private func followChain(account: E2EEAutoLog.AccountState) async -> Int {
        var obtained = 0
        for record in account.historyKeys.reversed() {
            guard let previous = record.previousHkPubB64, dependencies.scalar(previous) == nil,
                  let nextScalar = dependencies.scalar(record.hkPubB64) else { continue }
            guard let path = E2EEAutoHistoryRotationContract.chainPath(previous),
                  case .success(let data, _, _) = await dependencies.get(path),
                  let links = E2EEAutoHistoryRotationContract.parseWraps(data, key: "links"),
                  let agreementKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: nextScalar) else { break }
            let reader = E2EEAutoHistory.Reader.history(hkPubB64: record.hkPubB64)
            let opened = links.lazy.compactMap { link -> Data? in
                guard E2EEAutoHistory.check(userId: self.dependencies.userId, wrap: link, account: account, reader: reader) == nil else { return nil }
                return try? E2EEAutoHistory.open(link, userId: self.dependencies.userId, agreementKey: agreementKey)
            }.first
            guard let opened, (try? dependencies.keep(opened)) == previous else { break }
            obtained += 1
        }
        return obtained
    }

    // MARK: Transport

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

extension E2EEAutoHistoryRotation {
    static func markersKey(ownerNamespace: String) -> String { "e2ee-auto-hk-rotation-v1:\(ownerNamespace)" }
    /// Au-delà, les plus anciens tombent : le serveur répond `EXISTS` à un dépôt refait.
    static let markerLimit = 200

    /// Rotation pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        historyKeys: E2EEAutoHistoryKeyStore = E2EEAutoHistoryKeyStore()
    ) -> E2EEAutoHistoryRotation? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore),
              let publication = E2EEAutoHistoryKeyPublication.live(session: session, api: api) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let markersKey = markersKey(ownerNamespace: namespace)
        return E2EEAutoHistoryRotation(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            get: { path in
                await transport.getJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            },
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
            scalar: { hkPubB64 in try? historyKeys.scalar(userId: userId, hkPubB64: hkPubB64) },
            keep: { scalar in
                guard session.isCurrent else { throw E2EEV2DeviceIdentityError.unauthenticated }
                return try historyKeys.keep(scalar: scalar, userId: userId)
            },
            heldKeyVersions: { try identityStore.heldAgreementKeyVersions(ownerNamespace: namespace) },
            openWrap: { wrap in try identityStore.openHistoryWrap(wrap, userId: userId, ownerNamespace: namespace) },
            rotate: { await publication.rotate() },
            declarePresent: { _ = await publication.run() },
            isDone: { hasMarker($0, markersKey: markersKey) },
            recordDone: { recordMarker($0, markersKey: markersKey) }
        ))
    }

    static func hasMarker(_ marker: String, markersKey: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: markersKey)?.contains(marker) ?? false
    }

    static func recordMarker(_ marker: String, markersKey: String) {
        let defaults = UserDefaults.standard, current = defaults.stringArray(forKey: markersKey) ?? []
        guard !current.contains(marker) else { return }
        defaults.set(Array((current + [marker]).suffix(markerLimit)), forKey: markersKey)
    }

    /// Porte à preuve pour la publication et la sauvegarde de la session : même marqueur
    /// que la rotation, donc un maillon vu une fois n'est plus relu.
    static func liveVouching(
        session: LocalAccountSession, api: APIClient, identityStore: E2EEV2DeviceIdentityStore
    ) -> @Sendable (E2EEAutoLog.AccountState, E2EEAutoLog.HistoryKeyRecord) async -> Bool {
        let owner = session.ownerScopeId, userId = String(owner.dropFirst(5))
        let markersKey = markersKey(ownerNamespace: session.ownerNamespace)
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        return { account, rotation in
            let marker = vouchedMarker(rotation.hkPubB64)
            if hasMarker(marker, markersKey: markersKey) { return true }
            guard await fetchVouched(userId: userId, account: account, rotation: rotation, get: { path in
                await transport.getJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            }) else { return false }
            recordMarker(marker, markersKey: markersKey)
            return true
        }
    }
}
