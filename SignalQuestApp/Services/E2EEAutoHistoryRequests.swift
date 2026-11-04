import CryptoKit
import Foundation

/// Demandes « C'est moi » (E2EE-AUTO §5.3, routes de la révision 11) : un nouvel
/// appareil sans HK la demande, un appareil actif qui la détient l'enveloppe vers
/// lui (§5.4). Toutes les routes sont signées ; le serveur ne fait foi de rien :
/// l'écran « C'est moi » ne montre que le journal vérifié, et le demandeur vérifie
/// l'enveloppe face à ce même journal avant de ranger HK.
enum E2EEAutoHistoryRequestContract {
    static let requestsPath = "/api/e2ee/auto/history-requests"
    /// §5.3 : une demande expire 24 h après sa création.
    static let lifetimeMs: Int64 = 86_400_000

    static func requestPath(_ requestId: String) -> String { "\(requestsPath)/\(requestId)" }
    static func fulfilPath(_ requestId: String) -> String { "\(requestsPath)/\(requestId)/fulfil" }

    enum Status: String, Sendable, Equatable {
        case open, fulfilled, cancelled, expired
    }

    /// La vue d'une demande, aux six champs exacts, entiers en chaînes décimales.
    struct View: Equatable, Sendable {
        let requestId: String
        let deviceId: String
        let activate: Bool
        let status: Status
        let createdAtMs: Int64
        let expiresAtMs: Int64
    }

    private static let viewKeys: Set<String> = ["requestId", "deviceId", "activate", "status", "createdAtMs", "expiresAtMs"]

    /// Identifiant A.1 tiré par le serveur, jamais `rotation-…` (§5.4, révision 6).
    static func isRequestId(_ value: String) -> Bool {
        E2EEV2Canonical.isOpaque(value) && !value.hasPrefix("rotation-")
    }

    static func view(_ value: Any?) -> View? {
        guard let object = value as? [String: Any], Set(object.keys) == viewKeys,
              let requestId = object["requestId"] as? String, isRequestId(requestId),
              let deviceId = object["deviceId"] as? String, E2EEV2Canonical.isOpaque(deviceId),
              let flag = object["activate"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let rawStatus = object["status"] as? String, let status = Status(rawValue: rawStatus),
              let createdAtMs = decimal(object["createdAtMs"]), let expiresAtMs = decimal(object["expiresAtMs"]),
              expiresAtMs == createdAtMs + lifetimeMs else { return nil }
        return View(
            requestId: requestId, deviceId: deviceId, activate: flag.boolValue, status: status,
            createdAtMs: createdAtMs, expiresAtMs: expiresAtMs
        )
    }

    /// Créer et annuler rendent la vue seule.
    static func parseView(_ data: Data) -> View? {
        view(try? JSONSerialization.jsonObject(with: data))
    }

    /// Lire : `{ request, historyWrap }`, l'enveloppe nulle sauf pour le demandeur servi.
    static func parseRead(_ data: Data) -> (request: View, historyWrap: E2EEAutoHistory.Wrap?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["request", "historyWrap"], let request = view(object["request"]) else { return nil }
        if object["historyWrap"] is NSNull { return (request, nil) }
        guard let raw = object["historyWrap"] as? [String: Any], let wrap = E2EEAutoHistory.parseWrap(raw) else { return nil }
        return (request, wrap)
    }

    /// Lister : `{ requests: [vue…] }`, une vue mal formée refuse toute la page.
    static func parseList(_ data: Data) -> [View]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["requests"], let raw = object["requests"] as? [Any] else { return nil }
        let views = raw.compactMap(view)
        return views.count == raw.count ? views : nil
    }

    /// `{ request, activation }` : `activation` nul sans `ACTIVATE` ; sinon `{ entry, link, head }`
    /// que `writtenActivation` doit reconnaître comme l'`ACTIVATE` signé ici. La demande est close.
    static func parseFulfil(_ data: Data, requestId: String, writtenActivation: (([String: Any]) -> Bool)? = nil) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["request", "activation"], let request = view(object["request"]),
              request.requestId == requestId, request.status == .fulfilled else { return false }
        guard let writtenActivation else { return object["activation"] is NSNull }
        guard let written = object["activation"] as? [String: Any], Set(written.keys) == ["entry", "link", "head"] else { return false }
        return writtenActivation(written)
    }

    static func createBody(activate: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["activate": activate], options: [.sortedKeys])
    }

    /// Corps exact du `fulfil` : `activation` pour une demande `activate: true` (§6), où
    /// `historyWrap` est nul si l'approbateur ne détient pas HK.
    static func fulfilBody(_ wrap: E2EEAutoHistory.Wrap?, activation: [String: String]? = nil) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["historyWrap": wrap?.jsonObject ?? NSNull(), "activation": activation ?? NSNull()] as [String: Any],
            options: [.sortedKeys]
        )
    }

    private static func decimal(_ value: Any?) -> Int64? {
        guard let text = value as? String, text.range(of: #"^(0|[1-9][0-9]{0,15})\z"#, options: .regularExpression) != nil else { return nil }
        return Int64(text)
    }
}

/// Les deux rôles du §5.3, l'état venant toujours du journal vérifié du compte.
actor E2EEAutoHistoryRequests {
    /// Demande ouverte par cet appareil, gardée hors du trousseau synchronisé.
    struct OpenRequest: Codable, Equatable, Sendable {
        let requestId: String
        let expiresAtMs: Int64
        /// Demande d'un appareil en attente (mode renforcé, §6) : son service l'active.
        var activate: Bool? = nil
    }

    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var get: @Sendable (_ path: String) async -> E2EEV2TransportResult<Data>
        var post: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var delete: @Sendable (_ path: String, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var put: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        var scalar: @Sendable (_ hkPubB64: String) -> Data?
        var keep: @Sendable (_ scalar: Data) throws -> String
        var heldKeyVersions: @Sendable () throws -> [Int]
        var openWrap: @Sendable (_ wrap: E2EEAutoHistory.Wrap) throws -> Data
        var openRequest: @Sendable () -> OpenRequest?
        var recordOpenRequest: @Sendable (_ value: OpenRequest?) -> Void
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    /// Côté demandeur.
    enum RequestOutcome: Equatable, Sendable {
        /// HK détenue (synchro, passkey ou « C'est moi ») ; une demande ouverte est annulée.
        case present(hkPubB64: String)
        /// Le compte n'a pas de HK : l'appareil actif la publie (§5.1).
        case noHistoryKey
        case waiting(OpenRequest)
        /// La demande est close sans HK utilisable : en refaire une.
        case closed
        /// Appareil activé par « C'est moi » sans HK (approbateur qui ne l'avait pas) :
        /// la suite habituelle de HK reprend, avec une nouvelle demande si le compte en a une.
        case activated
        /// Appareil en attente (mode renforcé, §6) : sa demande porte `activate`.
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    /// Une demande d'un autre appareil, décrite par le journal vérifié seul (§5.3 point 4).
    struct Pending: Equatable, Sendable, Identifiable {
        let requestId: String
        let deviceId: String
        let platform: E2EEAutoLog.Platform
        /// `createdAtMs` de l'entrée `ADD` du demandeur.
        let addedAtMs: Int64
        /// 4 groupes de 5 chiffres (§7, `shortFingerprint`).
        let fingerprint: [String]
        let expiresAtMs: Int64
        /// Appareil en attente (mode renforcé, §6) : « C'est moi » l'active.
        var activate = false
        var id: String { requestId }
    }

    enum Listing: Equatable, Sendable {
        case requests([Pending])
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    /// Côté approbateur, à l'appui « C'est moi ».
    enum ApproveOutcome: Equatable, Sendable {
        case served
        /// Un autre appareil l'a servie : la notification se retire.
        case alreadyServed
        /// Annulée, expirée ou inconnue.
        case closed
        /// Cet appareil ne détient pas la HK du journal.
        case noHistoryKey
        /// Le demandeur n'est pas (ou plus) un appareil du journal vérifié.
        case unknownDevice
        /// Activer demande un approbateur inscrit depuis 24 h (§3.2).
        case tooRecent
        case notActive
        case retryLater(afterSeconds: Int?)
        case logRefused
        case failed(String)
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Demandeur

    /// Ouvre (ou retrouve) la demande de cet appareil, sauf s'il détient déjà HK.
    /// Un appareil en attente (mode renforcé, §6) demande aussitôt, avec `activate: true`,
    /// même s'il a déjà HK par la synchro : seul « C'est moi » l'active.
    func start() async -> RequestOutcome {
        let context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)
        switch await ownContext(allowPending: true) {
        case .success(let value): context = value
        case .failure(let failure): return failure.outcome
        }
        let activate = context.account.devices[context.device.deviceId]?.status == .pending
        if !activate, let settled = await settleIfHeld(context) { return settled }
        if let open = dependencies.openRequest(), open.expiresAtMs > dependencies.nowMs(), (open.activate ?? false) == activate {
            return .waiting(open)
        }
        guard let body = try? E2EEAutoHistoryRequestContract.createBody(activate: activate) else { return .failed("e2ee-auto-history-request-body") }
        switch await post(E2EEAutoHistoryRequestContract.requestsPath, body) {
        case .success(let data, _, _):
            // 201 nouvelle, 200 celle déjà ouverte (une seule par appareil).
            guard let view = E2EEAutoHistoryRequestContract.parseView(data), view.deviceId == context.device.deviceId,
                  view.activate == activate, view.status == .open else { return .failed("invalid-e2ee-auto-history-request-response") }
            let open = OpenRequest(requestId: view.requestId, expiresAtMs: view.expiresAtMs, activate: activate ? true : nil)
            dependencies.recordOpenRequest(open)
            return .waiting(open)
        case .failure(let failure):
            return requestFailure(failure)
        }
    }

    /// Relit la demande ouverte : l'enveloppe servie est vérifiée face au journal,
    /// ouverte, et HK rangée puis déclarée.
    func check() async -> RequestOutcome {
        var context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)
        switch await ownContext(allowPending: true) {
        case .success(let value): context = value
        case .failure(let failure): return failure.outcome
        }
        let pending = context.account.devices[context.device.deviceId]?.status == .pending
        if !pending, let settled = await settleIfHeld(context) { return settled }
        // Révision 11 : « ouverte » se juge ici ; une demande expirée ou oubliée n'accepte plus rien.
        guard let open = dependencies.openRequest() else { return .closed }
        guard open.expiresAtMs > dependencies.nowMs() else {
            dependencies.recordOpenRequest(nil)
            return .closed
        }
        switch await dependencies.get(E2EEAutoHistoryRequestContract.requestPath(open.requestId)) {
        case .success(let data, _, _):
            guard let (view, wrap) = E2EEAutoHistoryRequestContract.parseRead(data), view.requestId == open.requestId,
                  view.deviceId == context.device.deviceId else { return .failed("invalid-e2ee-auto-history-request-response") }
            switch view.status {
            case .open: return .waiting(open)
            case .cancelled, .expired:
                dependencies.recordOpenRequest(nil)
                return .closed
            case .fulfilled:
                // L'`ACTIVATE` est écrit avec le service (§5.3) : le journal relu le montre,
                // sinon la demande reste retenue pour la prochaine relecture.
                if pending {
                    switch await ownContext(allowPending: true) {
                    case .success(let value): context = value
                    case .failure(let failure): return failure.outcome
                    }
                    guard context.account.devices[context.device.deviceId]?.status == .active else { return .retryLater(afterSeconds: nil) }
                }
                dependencies.recordOpenRequest(nil)
                guard let wrap else { return open.activate == true ? .activated : .closed }
                return await receive(wrap, open: open, context: context)
            }
        case .failure(let failure):
            if failure.code == "E2EE_HISTORY_REQUEST_NOT_FOUND" {
                dependencies.recordOpenRequest(nil)
                return .closed
            }
            return requestFailure(failure)
        }
    }

    /// Une demande de cet appareil est gardée ouverte (sans la relire).
    var hasOpenRequest: Bool {
        dependencies.openRequest().map { $0.expiresAtMs > dependencies.nowMs() } ?? false
    }

    /// Empreinte courte de cet appareil, celle que l'approbateur lit au journal (§5.3 point 4).
    func ownFingerprint() -> [String]? {
        guard let device = try? dependencies.device() else { return nil }
        return E2EEAutoSafetyCode.shortFingerprint(E2EEAutoSafetyCode.deviceFingerprint(
            userId: dependencies.userId, deviceId: device.deviceId, signingKeyB64: device.publicSigningKeyB64
        ))
    }

    /// HK arrivée par la synchro ou la passkey pendant l'attente : la demande est annulée.
    func cancel() async {
        guard let open = dependencies.openRequest() else { return }
        switch await delete(E2EEAutoHistoryRequestContract.requestPath(open.requestId)) {
        case .success:
            dependencies.recordOpenRequest(nil)
        case .failure(let failure):
            if failure.code == "E2EE_HISTORY_REQUEST_NOT_FOUND" { dependencies.recordOpenRequest(nil) }
        }
    }

    private func receive(
        _ wrap: E2EEAutoHistory.Wrap, open: OpenRequest, context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)
    ) async -> RequestOutcome {
        guard let keyVersions = try? dependencies.heldKeyVersions() else { return .failed("e2ee-auto-device-unavailable") }
        let reader = E2EEAutoHistory.Reader.device(
            deviceId: context.device.deviceId, keyVersions: keyVersions, openRequestIds: [open.requestId], heldHkPubB64: nil
        )
        if let refusal = E2EEAutoHistory.check(userId: dependencies.userId, wrap: wrap, account: context.account, reader: reader) {
            // §5.4 : sinon, la demande est servie à nouveau — par une nouvelle demande.
            return .failed("e2ee-auto-history-wrap-\(refusal.rawValue.lowercased())")
        }
        let hkPubB64: String
        do {
            let scalar = try dependencies.openWrap(wrap)
            hkPubB64 = try dependencies.keep(scalar)
        } catch {
            return .failed("e2ee-auto-history-wrap-open")
        }
        guard hkPubB64 == wrap.hkPubB64 else { return .failed("e2ee-auto-history-wrap-open") }
        await reportPresent(device: context.device)
        return .present(hkPubB64: hkPubB64)
    }

    /// HK du journal déjà détenue : la demande ouverte tombe, `present` est déclaré.
    private func settleIfHeld(_ context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)) async -> RequestOutcome? {
        guard let current = context.account.historyKeyPubB64 else {
            return dependencies.openRequest() == nil ? .noHistoryKey : nil
        }
        guard dependencies.scalar(current) != nil else { return nil }
        await cancel()
        await reportPresent(device: context.device)
        return .present(hkPubB64: current)
    }

    private func reportPresent(device: E2EEV2DeviceDescriptor) async {
        guard let body = try? E2EEAutoHistoryKeyContract.statusBody(present: true) else { return }
        _ = await put(E2EEAutoHistoryKeyContract.historyStatusPath(deviceId: device.deviceId), body)
    }

    private func ownContext(allowPending: Bool = false) async -> Result<(device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState), Failure> {
        let device: E2EEV2DeviceDescriptor
        do { device = try dependencies.device() } catch { return .failure(Failure(.failed("e2ee-auto-device-unavailable"))) }
        let account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .failure(Failure(.logRefused))
        case .inconclusive: return .failure(Failure(.retryLater(afterSeconds: nil)))
        }
        guard let own = account.devices[device.deviceId], own.signingKeyB64 == device.publicSigningKeyB64 else {
            return .failure(Failure(.retryLater(afterSeconds: nil)))
        }
        switch own.status {
        case .active: return .success((device, account))
        case .pending: return allowPending ? .success((device, account)) : .failure(Failure(.notActive))
        case .revoked: return .failure(Failure(.failed("e2ee-auto-device-revoked")))
        }
    }

    private struct Failure: Error {
        let outcome: RequestOutcome
        init(_ outcome: RequestOutcome) { self.outcome = outcome }
    }

    private func requestFailure(_ failure: E2EEV2TransportFailure) -> RequestOutcome {
        switch failure.code {
        case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
        case "E2EE_HISTORY_REQUEST_RATE_LIMITED": return .retryLater(afterSeconds: failure.retryAfterSeconds)
        default:
            if failure.statusCode == 429 || failure.kind == .retryable { return .retryLater(afterSeconds: failure.retryAfterSeconds) }
            if let status = failure.statusCode, status >= 500 { return .retryLater(afterSeconds: failure.retryAfterSeconds) }
            return .failed("e2ee-auto-history-request-refused")
        }
    }

    // MARK: - Approbateur

    /// Les demandes ouvertes des autres appareils, chacune décrite par le journal
    /// vérifié ; une demande d'un appareil inconnu du journal n'est pas montrée.
    func openRequests() async -> Listing {
        let context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)
        switch await ownContext() {
        case .success(let value): context = value
        case .failure(let failure): return Self.listing(failure.outcome)
        }
        // Sans HK, rien à servir, sauf activer un appareil en attente (§6) si cet appareil
        // est inscrit depuis 24 h ; sinon l'écran « C'est moi » ne s'affiche pas ici.
        let holdsHistoryKey = context.account.historyKeyPubB64.map { dependencies.scalar($0) != nil } ?? false
        let canActivate = canActivate(context)
        guard holdsHistoryKey || canActivate else { return .requests([]) }
        let nowMs = dependencies.nowMs()
        switch await dependencies.get(E2EEAutoHistoryRequestContract.requestsPath) {
        case .success(let data, _, _):
            guard let views = E2EEAutoHistoryRequestContract.parseList(data) else { return .failed("invalid-e2ee-auto-history-requests-response") }
            let now = dependencies.nowMs()
            return .requests(views.compactMap { view -> Pending? in
                // `activate: true` vise un appareil en attente du journal, les autres un appareil actif.
                guard view.status == .open, view.expiresAtMs > now, view.deviceId != context.device.deviceId,
                      let requester = context.account.devices[view.deviceId],
                      view.activate
                        ? E2EEAutoActivationContract.refusal(
                            account: context.account, approverDeviceId: context.device.deviceId, deviceId: view.deviceId, nowMs: nowMs
                        ) == nil
                        : requester.status == .active && holdsHistoryKey
                else { return nil }
                return pending(view, requester: requester)
            })
        case .failure(let failure):
            switch requestFailure(failure) {
            case .notActive: return .notActive
            case .retryLater(let seconds): return .retryLater(afterSeconds: seconds)
            default: return .failed("e2ee-auto-history-requests-refused")
            }
        }
    }

    /// « C'est moi » : HK enveloppée vers la clé d'accord courante du demandeur, lue
    /// au journal vérifié. Une clé ou une HK périmée relit le compte une fois.
    func approve(requestId: String) async -> ApproveOutcome {
        guard E2EEAutoHistoryRequestContract.isRequestId(requestId) else { return .closed }
        for attempt in 0..<2 {
            let context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)
            switch await ownContext() {
            case .success(let value): context = value
            case .failure(let failure): return Self.approve(failure.outcome)
            }
            let view: E2EEAutoHistoryRequestContract.View
            switch await dependencies.get(E2EEAutoHistoryRequestContract.requestPath(requestId)) {
            case .success(let data, _, _):
                guard let (read, _) = E2EEAutoHistoryRequestContract.parseRead(data), read.requestId == requestId else {
                    return .failed("invalid-e2ee-auto-history-request-response")
                }
                view = read
            case .failure(let failure):
                return failure.code == "E2EE_HISTORY_REQUEST_NOT_FOUND" ? .closed : Self.approve(requestFailure(failure))
            }
            switch view.status {
            case .open: break
            case .fulfilled: return .alreadyServed
            case .cancelled, .expired: return .closed
            }
            guard view.deviceId != context.device.deviceId, let requester = context.account.devices[view.deviceId],
                  requester.status == (view.activate ? .pending : .active) else { return .unknownDevice }
            let scalar = context.account.historyKeyPubB64.flatMap { dependencies.scalar($0) }
            let activation: [String: String]?
            if view.activate {
                switch E2EEAutoActivationContract.refusal(
                    account: context.account, approverDeviceId: context.device.deviceId, deviceId: requester.deviceId, nowMs: dependencies.nowMs()
                ) {
                case nil: break
                case .approverTooRecent?: return .tooRecent
                case .approverNotActive?: return .notActive
                case .notPending?: return .unknownDevice
                }
                guard let signed = try? E2EEAutoActivationContract.activation(
                    account: context.account, approverDeviceId: context.device.deviceId, deviceId: requester.deviceId, sign: dependencies.sign
                ) else { return .failed("e2ee-auto-activation-signature") }
                activation = signed
            } else {
                guard scalar != nil else { return .noHistoryKey }
                activation = nil
            }
            let body: Data
            do {
                var wrap: E2EEAutoHistory.Wrap?
                if let scalar {
                    guard let keyData = Data(base64Encoded: requester.identityKeyB64) else { return .unknownDevice }
                    let recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: keyData)
                    wrap = try E2EEAutoHistory.seal(
                        scalar: scalar, userId: dependencies.userId, senderDeviceId: context.device.deviceId,
                        recipient: requester.deviceId, keyVersion: requester.keyVersion, requestId: requestId,
                        addHash: requester.addEntryHash, recipientAgreementKey: recipientKey, sign: dependencies.sign
                    )
                }
                body = try E2EEAutoHistoryRequestContract.fulfilBody(wrap, activation: activation)
            } catch {
                return .failed("e2ee-auto-history-wrap-seal")
            }
            switch await post(E2EEAutoHistoryRequestContract.fulfilPath(requestId), body) {
            case .success(let data, _, _):
                let account = context.account, approverId = context.device.deviceId, deviceId = requester.deviceId
                let check: (([String: Any]) -> Bool)? = activation.map { signed in
                    { written in
                        E2EEAutoActivationContract.parseWritten(
                            written, account: account, prevUserEntryHash: signed["prevUserEntryHash"] ?? "",
                            approverDeviceId: approverId, deviceId: deviceId
                        )
                    }
                }
                return E2EEAutoHistoryRequestContract.parseFulfil(data, requestId: requestId, writtenActivation: check)
                    ? .served : .failed("invalid-e2ee-auto-history-fulfil-response")
            case .failure(let failure):
                switch failure.code {
                case "E2EE_HISTORY_REQUEST_CLOSED":
                    if case .string("fulfilled")? = failure.details?["status"] { return .alreadyServed }
                    return .closed
                case "E2EE_HISTORY_REQUEST_NOT_FOUND": return .closed
                case "E2EE_DEVICE_TOO_RECENT": return .tooRecent
                case "E2EE_HISTORY_KEY_STALE", "E2EE_RECIPIENT_KEY_STALE", "E2EE_LOG_STALE":
                    // Relire le compte et ré-envelopper, une seule fois (§5.3 point 10).
                    guard attempt == 0 else { return .retryLater(afterSeconds: nil) }
                    continue
                default:
                    return Self.approve(requestFailure(failure))
                }
            }
        }
        return .retryLater(afterSeconds: nil)
    }

    /// Garde des 24 h de l'`ACTIVATE` (§3.2) : sans elle, aucune activation à lister.
    private func canActivate(_ context: (device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState)) -> Bool {
        guard let own = context.account.devices[context.device.deviceId] else { return false }
        return dependencies.nowMs() - own.addedAtMs >= E2EEAutoLog.signerMinAgeMs
    }

    private func pending(_ view: E2EEAutoHistoryRequestContract.View, requester: E2EEAutoLog.DeviceState) -> Pending? {
        let fingerprint = E2EEAutoSafetyCode.deviceFingerprint(
            userId: dependencies.userId, deviceId: requester.deviceId, signingKeyB64: requester.signingKeyB64
        )
        guard let groups = E2EEAutoSafetyCode.shortFingerprint(fingerprint) else { return nil }
        return Pending(
            requestId: view.requestId, deviceId: requester.deviceId, platform: requester.platform,
            addedAtMs: requester.addedAtMs, fingerprint: groups, expiresAtMs: view.expiresAtMs, activate: view.activate
        )
    }

    private static func listing(_ outcome: RequestOutcome) -> Listing {
        switch outcome {
        case .notActive: return .notActive
        case .retryLater(let seconds): return .retryLater(afterSeconds: seconds)
        case .logRefused: return .logRefused
        case .failed(let reason): return .failed(reason)
        default: return .failed("e2ee-auto-history-requests-state")
        }
    }

    private static func approve(_ outcome: RequestOutcome) -> ApproveOutcome {
        switch outcome {
        case .notActive: return .notActive
        case .retryLater(let seconds): return .retryLater(afterSeconds: seconds)
        case .logRefused: return .logRefused
        case .failed(let reason): return .failed(reason)
        default: return .failed("e2ee-auto-history-request-state")
        }
    }

    // MARK: - Transport

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

    private func delete(_ path: String) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.delete(path, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.delete(path, clockOffsetMs)
    }
}

extension E2EEAutoHistoryRequests {
    static func openRequestKey(ownerNamespace: String) -> String { "e2ee-auto-history-request-v1:\(ownerNamespace)" }

    /// Demandes pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
        historyKeys: E2EEAutoHistoryKeyStore = E2EEAutoHistoryKeyStore()
    ) -> E2EEAutoHistoryRequests? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let openKey = openRequestKey(ownerNamespace: namespace)
        return E2EEAutoHistoryRequests(Dependencies(
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
            delete: { path, clockOffsetMs in
                await transport.deleteJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs)
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
            openRequest: {
                guard let raw = try? markerStore.string(for: openKey) else { return nil }
                return try? JSONDecoder().decode(OpenRequest.self, from: Data(raw.utf8))
            },
            recordOpenRequest: { value in
                if let value, let data = try? JSONEncoder().encode(value) {
                    try? markerStore.set(String(decoding: data, as: UTF8.self), for: openKey, accessibility: .afterFirstUnlock)
                } else {
                    try? markerStore.remove(openKey)
                }
            }
        ))
    }
}
