import Foundation
import CallKit
import PushKit
import AVFAudio
import CryptoKit
import os

enum CallTerminationAction: String, Codable, Equatable {
    case reject
    case leave
}

struct PendingCallTermination: Codable, Equatable {
    let ownerScopeId: String
    let callId: String
    let action: CallTerminationAction
    let createdAt: Date
}

/// Small account-scoped outbox for a hang-up performed while offline. Call IDs
/// are opaque and bounded; stale entries expire locally even if the server TTL
/// has already closed the room.
final class CallTerminationRetryStore {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumCount = 32

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "call-termination-outbox-v1") {
        self.defaults = defaults
        self.key = key
    }

    func enqueue(
        ownerScopeId: String,
        callId: String,
        action: CallTerminationAction,
        now: Date = Date()
    ) {
        guard validOwner(ownerScopeId), validCallId(callId) else { return }
        var records = validRecords(now: now)
        if let existing = records.first(where: {
            $0.ownerScopeId == ownerScopeId && $0.callId == callId
        }) {
            records.removeAll { $0.ownerScopeId == ownerScopeId && $0.callId == callId }
            records.append(.init(
                ownerScopeId: ownerScopeId,
                callId: callId,
                // Once a participant has joined, leave is the only safe replay.
                action: existing.action == .leave || action == .leave ? .leave : .reject,
                createdAt: min(existing.createdAt, now)
            ))
        } else {
            records.append(.init(
                ownerScopeId: ownerScopeId,
                callId: callId,
                action: action,
                createdAt: now
            ))
        }
        persist(Array(records.sorted { $0.createdAt < $1.createdAt }.suffix(Self.maximumCount)))
    }

    func pending(ownerScopeId: String, now: Date = Date()) -> [PendingCallTermination] {
        guard validOwner(ownerScopeId) else { return [] }
        let records = validRecords(now: now)
        persist(records)
        return records.filter { $0.ownerScopeId == ownerScopeId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(ownerScopeId: String, callId: String, now: Date = Date()) {
        persist(validRecords(now: now).filter {
            !($0.ownerScopeId == ownerScopeId && $0.callId == callId)
        })
    }

    private func validRecords(now: Date) -> [PendingCallTermination] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([PendingCallTermination].self, from: data) else {
            return []
        }
        return records.filter {
            validOwner($0.ownerScopeId) && validCallId($0.callId) &&
                $0.createdAt <= now.addingTimeInterval(5 * 60) &&
                now.timeIntervalSince($0.createdAt) <= Self.maximumAge
        }
    }

    private func persist(_ records: [PendingCallTermination]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    private func validOwner(_ value: String) -> Bool {
        value.hasPrefix("user:") && value.count > "user:".count
    }

    private func validCallId(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
    }
}

struct CallLifecyclePolicy {
    static let ringingStatuses: Set<String> = ["pending", "ringing"]
    static let maximumParticipants = 8

    static func isRinging(_ status: String?, pending: Bool? = nil) -> Bool {
        // Un transfert vers un nouveau participant garde l'appel global ACTIVE,
        // tout en renvoyant `pending: true` pour ce destinataire.
        if pending == true { return true }
        guard let status else { return false }
        return ringingStatuses.contains(status.lowercased())
    }

    static func terminationAction(
        isOutgoing: Bool,
        isAnswered: Bool,
        serverStatus: String? = nil
    ) -> CallTerminationAction {
        // Dans un groupe, l'appel global devient ACTIVE dès qu'une personne
        // répond, tandis que les autres destinataires peuvent encore sonner.
        // `/reject` n'accepte que RINGING ; un destinataire transféré/encore en
        // sonnerie sur un appel ACTIVE doit donc passer par `/end` (alias leave).
        isOutgoing || isAnswered || serverStatus?.lowercased() == "active" ? .leave : .reject
    }

    static func canStartCall(participantCount: Int) -> Bool {
        (2...maximumParticipants).contains(participantCount)
    }

    /// An E2EE conversation must never fall back silently to transport-only
    /// SRTP. This becomes true only after the audited v2 epoch/cryptor contract
    /// is negotiated on every participant device.
    static func canUseE2EECall(conversationE2EE: Bool, verifiedV2: Bool) -> Bool {
        !conversationE2EE || verifiedV2
    }

    /// Stable mapping so the same backend call cannot create several CallKit
    /// entries when PushKit delivery and foreground reconciliation race.
    static func callKitUUID(callId: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(callId.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // namespace-style UUID version
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum IncomingCallE2EEExpectation: Equatable {
    case unresolved
    case legacy
    case required(E2EEV2CallSessionDescriptor)
    case invalid
}

enum IncomingCallE2EEContract {
    /// PushKit must be handled synchronously, so the non-secret descriptor is
    /// validated directly from the APNs payload. Older payloads stay
    /// `unresolved` and are authenticated through `/pending` before answer.
    static func parse(_ payload: [AnyHashable: Any]) -> IncomingCallE2EEExpectation {
        let marker = payload["e2eeRequired"] as? Bool
        guard let rawDescriptor = payload["e2ee"] else {
            if marker == true { return .invalid }
            return marker == false ? .legacy : .unresolved
        }
        guard marker == true,
              JSONSerialization.isValidJSONObject(rawDescriptor),
              let data = try? JSONSerialization.data(withJSONObject: rawDescriptor),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let descriptor = E2EEV2CallBridge.parseDescriptor(value) else {
            return .invalid
        }
        return .required(descriptor)
    }
}

/// Bridges SignalQuest calls to the system via CallKit, and receives incoming
/// calls via PushKit VoIP pushes. CallKit gives us the native incoming-call
/// screen (even when the app is backgrounded or the device is locked) and the
/// proper audio-session lifecycle; LiveKit carries the media.
///
/// Backend contract required for end-to-end incoming calls:
///  - `POST /api/user/voip-token` `{ voipToken, platform: "ios" }` to store the
///    VoIP token (separate APNs topic `<bundleid>.voip`).
///  - On call initiation, the server sends a VoIP push whose payload contains at
///    least `callId`/`conversationId`/`caller`/`mode` so we can report it.
/// The outgoing path and the CallKit/LiveKit wiring work without that; only the
/// background incoming ring needs the server VoIP push.
@MainActor
final class CallManager: NSObject, ObservableObject {
    struct ActiveCall: Identifiable, Equatable {
        let id: UUID
        var callId: String?
        let conversationId: String?
        let handle: String
        let hasVideo: Bool
        var isOutgoing: Bool
        var serverStatus: String? = nil
        /// Passe à true quand un appel ENTRANT a été décroché — distingue
        /// « jamais répondu » (reject) de « répondu puis raccroché » (end). CALL-BUG-02.
        var isAnswered: Bool = false
        var isEnding: Bool = false
        /// `nil` means a PushKit wake-up has not yet been reconciled with the
        /// authenticated `/pending` contract. Such a call cannot be answered.
        var requiresE2EE: Bool? = nil
        var e2eeDescriptor: E2EEV2CallSessionDescriptor? = nil
    }

    enum CallError: LocalizedError {
        case missingCredentials
        case e2eeUnavailable
        case untrustedE2EESession
        case connectionFailed(String)
        case connectionEnded
        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Identifiants d'appel manquants."
            case .e2eeUnavailable: return "L’appel chiffré de bout en bout n’est pas disponible sur cet appareil."
            case .untrustedE2EESession: return "La vérification du chiffrement de l’appel a échoué."
            case .connectionFailed(let m): return String(localized: "Connexion à l'appel impossible : \(m)")
            case .connectionEnded: return String(localized: "L'appel s'est terminé pendant la connexion.")
            }
        }
    }

    @Published private(set) var activeCall: ActiveCall?
    @Published var showCallScreen = false

    let liveKit = LiveKitClient()

    private let callsService: CallsServicing
    private let api: APIClient
    private let terminationRetryStore: CallTerminationRetryStore
    private let provider: CXProvider
    private let callController = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private var incomingReconciliationTask: Task<Void, Never>?
    private var recentlyTerminatedCallIDs: [String: Date] = [:]
    private let deviceID = InstallationIdentity().deviceID()
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "CallKit")

    init(
        callsService: CallsServicing,
        api: APIClient,
        terminationRetryStore: CallTerminationRetryStore = CallTerminationRetryStore()
    ) {
        self.callsService = callsService
        self.api = api
        self.terminationRetryStore = terminationRetryStore
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // CALL-RTC-01 : quand le média se termine côté distant (l'autre raccroche,
        // room fermée, ou réseau tombé), LiveKit le signale → on clôt l'appel.
        liveKit.onRemoteDisconnect = { [weak self] in self?.handleRemoteDisconnect() }
        liveKit.onE2EETrustLost = { [weak self] in self?.handleE2EETrustLost() }
    }

    /// Registers for VoIP pushes. Safe to call multiple times.
    func registerForVoIPPushes() {
        guard voipRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    // MARK: Outgoing

    func startOutgoingCall(
        conversationId: String,
        mode: String,
        displayName: String,
        requiresE2EE: Bool = false
    ) {
        guard activeCall == nil else { return }
        liveKit.prepareForCall()
        let uuid = UUID()
        let hasVideo = mode.lowercased() == "video"
        activeCall = ActiveCall(
            id: uuid,
            callId: nil,
            conversationId: conversationId,
            handle: displayName,
            hasVideo: hasVideo,
            isOutgoing: true,
            requiresE2EE: requiresE2EE
        )
        showCallScreen = true
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: displayName))
        action.isVideo = hasVideo
        callController.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.activeCall?.id == uuid else { return }
                self.logger.error("startCall request failed: \(error.localizedDescription, privacy: .public)")
                await self.tearDown()
            }
        }
    }

    /// User taps hang-up in the in-app call screen.
    func endActiveCall() {
        guard let call = activeCall else {
            showCallScreen = false
            return
        }
        guard !call.isEnding else { return }
        activeCall?.isEnding = true
        let action = CXEndCallAction(call: call.id)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.error("endCall request failed: \(error.localizedDescription, privacy: .public)")
                    if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                    await self.tearDown()
                }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let call = activeCall else { return }
        let action = CXSetMutedCallAction(call: call.id, muted: muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    // MARK: Incoming

    private func reportInvalidIncomingPush(
        uuid: UUID,
        handle: String,
        hasVideo: Bool,
        completion: (() -> Void)?
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage {
                    self?.logger.error("invalid incoming payload report failed: \(errorMessage, privacy: .public)")
                } else {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                }
                completionBox.value?()
            }
        }
    }

    func reportIncomingCall(
        uuid: UUID,
        callId: String?,
        conversationId: String?,
        handle: String,
        hasVideo: Bool,
        serverStatus: String? = nil,
        requiresE2EE: Bool? = nil,
        e2eeDescriptor: E2EEV2CallSessionDescriptor? = nil,
        completion: (() -> Void)?
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)

        // Une push APNs peut arriver après un refus/raccrochage déjà traité.
        // Elle doit toujours être reportée à CallKit (contrat PushKit), puis
        // clôturée immédiatement sans recréer l'état applicatif ni une sonnerie.
        if let callId, wasRecentlyTerminated(callId) {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("stale incoming report failed: \(errorMessage, privacy: .public)")
                    } else {
                        self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                    }
                    completionBox.value?()
                }
            }
            return
        }

        // PushKit peut relivrer le même appel alors que la réconciliation HTTP l'a
        // déjà présenté. On réutilise le même UUID CallKit, sans créer un second
        // appel système ni remplacer l'état actif.
        if let current = activeCall, let callId, current.callId == callId {
            provider.reportNewIncomingCall(with: current.id, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("duplicate incoming report failed: \(errorMessage, privacy: .public)")
                    }
                    completionBox.value?()
                }
            }
            return
        }

        // CALL-RTC-04 : un appel est déjà actif → on NE touche PAS activeCall ni la
        // session LiveKit en cours. On satisfait quand même l'exigence PushKit (tout
        // push VoIP doit être suivi d'un reportNewIncomingCall, sinon l'app est tuée)
        // puis on décline immédiatement le nouvel UUID, sans impacter l'appel courant.
        if activeCall != nil {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("2nd reportNewIncomingCall failed: \(errorMessage, privacy: .public)")
                    } else {
                        self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                    }
                    // PushKit doit être libéré dès que le report CallKit est
                    // terminé. La requête HTTP de refus est best-effort et ne doit
                    // jamais retenir le watchdog système.
                    completionBox.value?()
                    if let self, let callId {
                        await self.notifyBackendCallTerminated(
                            callId: callId,
                            action: CallLifecyclePolicy.terminationAction(
                                isOutgoing: false,
                                isAnswered: false,
                                serverStatus: serverStatus
                            )
                        )
                    }
                }
            }
            return
        }

        activeCall = ActiveCall(
            id: uuid,
            callId: callId,
            conversationId: conversationId,
            handle: handle,
            hasVideo: hasVideo,
            isOutgoing: false,
            serverStatus: serverStatus?.lowercased(),
            requiresE2EE: requiresE2EE,
            e2eeDescriptor: e2eeDescriptor
        )
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage {
                    // Échec du report du SEUL nouvel appel : nettoyage local (aucun
                    // appel n'était actif avant), pas de teardown d'une autre room.
                    self?.logger.error("reportNewIncomingCall failed: \(errorMessage, privacy: .public)")
                    self?.activeCall = nil
                    self?.showCallScreen = false
                    completionBox.value?()
                    if let self, let callId {
                        await self.notifyBackendCallTerminated(
                            callId: callId,
                            action: CallLifecyclePolicy.terminationAction(
                                isOutgoing: false,
                                isAnswered: false,
                                serverStatus: serverStatus
                            )
                        )
                    }
                } else if let callId {
                    self?.startIncomingReconciliation(callId: callId)
                    completionBox.value?()
                } else {
                    completionBox.value?()
                }
            }
        }
    }

    /// CALL-INCOMING-03 : filet anti-perte de push VoIP. À appeler au retour au premier
    /// plan (et après login) : demande au serveur les appels en attente et, si un appel
    /// « ringing »/« pending » n'est pas déjà actif, le présente via CallKit.
    func reconcilePendingIncomingCall() async {
        await retryPendingCallTerminations()
        let pending: [CallSession]
        do {
            pending = try await callsService.pending()
        } catch {
            logger.error("pending call reconciliation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let call = pending.first(where: {
            CallLifecyclePolicy.isRinging($0.status, pending: $0.isPending)
        })

        if let active = activeCall {
            guard !active.isOutgoing, !active.isAnswered, !active.isEnding else { return }
            if let call {
                if call.id == active.callId {
                    // Un autre membre du groupe peut avoir répondu : l'appel global
                    // passe alors ACTIVE pendant que cet appareil sonne encore. On
                    // conserve ce statut pour choisir leave plutôt que reject.
                    activeCall?.serverStatus = call.status?.lowercased()
                    activeCall?.requiresE2EE = call.e2eeRequired
                    activeCall?.e2eeDescriptor = call.e2ee
                    return
                }
                // `/pending` ne renvoie qu'un appel (le plus récent). Si un second
                // appel arrive sans push pendant que CallKit sonne déjà, décliner
                // ce nouveau call plutôt que de supprimer arbitrairement l'appel
                // système courant. Le prochain poll retrouvera l'appel initial.
                await notifyBackendCallTerminated(
                    callId: call.id,
                    action: CallLifecyclePolicy.terminationAction(
                        isOutgoing: false,
                        isAnswered: false,
                        serverStatus: call.status
                    )
                )
                return
            }
            // L'appel n'est plus en attente côté serveur : annulé par l'appelant,
            // refusé/répondu sur un autre appareil ou expiré. Fermer CallKit évite
            // une sonnerie fantôme.
            reportCallEnded(active.id, reason: .remoteEnded)
            await tearDown()
            return
        }

        guard let call, !wasRecentlyTerminated(call.id) else { return }
        reportIncomingCall(
            uuid: CallLifecyclePolicy.callKitUUID(callId: call.id),
            callId: call.id,
            conversationId: call.conversationId,
            handle: call.displayName ?? call.participants?.first ?? "Appel SignalQuest",
            hasVideo: call.mode == "video",
            serverStatus: call.status,
            requiresE2EE: call.e2eeRequired,
            e2eeDescriptor: call.e2ee,
            completion: nil
        )
    }

    // MARK: Internals

    /// Se connecte au média LiveKit ET vérifie le succès. CALL-BUG-01 : on lève si les
    /// identifiants manquent ou si LiveKit termine en `.failed`, pour que l'appelant
    /// échoue proprement l'action CallKit au lieu de marquer l'appel « connecté ».
    private func connectLiveKit(for session: CallSession, video: Bool) async throws {
        guard let url = session.liveKitUrl, let token = session.liveKitToken, let room = session.liveKitRoom else {
            logger.error("Call session missing LiveKit credentials")
            throw CallError.missingCredentials
        }
        let e2eeSession: E2EEV2LiveKitSession?
        if session.e2eeRequired {
            guard let descriptor = session.e2ee,
                  let conversationId = activeCall?.conversationId else {
                throw CallError.untrustedE2EESession
            }
            switch E2EEV2CallBridge.resolveRuntimeSession(
                conversationId: conversationId,
                callId: session.id,
                liveKitURL: url,
                descriptor: descriptor
            ) {
            case .ready(let material):
                e2eeSession = try material.consume { epochKey, context in
                    try E2EEV2LiveKitSession.make(epochKey: epochKey, context: context)
                }
            case .blocked:
                throw CallError.untrustedE2EESession
            }
        } else {
            guard activeCall?.requiresE2EE != true else {
                throw CallError.untrustedE2EESession
            }
            e2eeSession = nil
        }
        await liveKit.connect(
            url: url,
            token: token,
            room: room,
            video: video,
            managesAudioSession: false,
            e2eeSession: e2eeSession
        )
        if case .failed(let message) = liveKit.state {
            logger.error("LiveKit connect failed: \(message, privacy: .public)")
            throw CallError.connectionFailed(message)
        }
        guard liveKit.state == .connected else { throw CallError.connectionEnded }
    }

    private func outgoingE2EEContext(for call: ActiveCall) throws -> E2EEV2CallEpochContext? {
        guard call.requiresE2EE == true else { return nil }
        guard let conversationId = call.conversationId else { throw CallError.e2eeUnavailable }
        switch E2EEV2CallBridge.prepareRuntimeRequest(conversationId: conversationId) {
        case .prepared(let context): return context
        case .runtimeClosed, .localEpochUnavailable: throw CallError.e2eeUnavailable
        }
    }

    private func reconcileE2EEForAnswer(_ call: ActiveCall) async throws -> ActiveCall {
        guard let callId = call.callId else { throw CallError.missingCredentials }
        let serverCall = try await callsService.pending().first(where: { $0.id == callId })
        guard let serverCall else { throw CallError.connectionEnded }
        var reconciled = call
        reconciled.serverStatus = serverCall.status?.lowercased()
        reconciled.requiresE2EE = serverCall.e2eeRequired
        reconciled.e2eeDescriptor = serverCall.e2ee
        activeCall = reconciled
        return reconciled
    }

    private func answerE2EEContext(for call: ActiveCall) throws -> E2EEV2CallEpochContext? {
        guard call.requiresE2EE == true else {
            guard call.requiresE2EE == false, call.e2eeDescriptor == nil else {
                throw CallError.untrustedE2EESession
            }
            return nil
        }
        guard let conversationId = call.conversationId,
              let descriptor = call.e2eeDescriptor else {
            throw CallError.untrustedE2EESession
        }
        switch E2EEV2CallBridge.prepareRuntimeAnswerRequest(
            conversationId: conversationId,
            descriptor: descriptor
        ) {
        case .prepared(let context): return context
        case .runtimeClosed, .localEpochUnavailable: throw CallError.e2eeUnavailable
        }
    }

    private func tearDown() async {
        incomingReconciliationTask?.cancel()
        incomingReconciliationTask = nil
        if let callId = activeCall?.callId { markRecentlyTerminated(callId) }
        await liveKit.disconnect()
        activeCall = nil
        showCallScreen = false
    }

    /// CALL-RTC-02 : retire de CallKit un appel déjà rapporté quand la fin n'est
    /// PAS pilotée par un CXEndCallAction (échec de connexion média, fin distante).
    /// À NE PAS appeler depuis providerDidReset (provider déjà purgé) ni après un
    /// CXEndCallAction (action.fulfill() suffit).
    private func reportCallEnded(_ id: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
    }

    /// Notifie le backend de la fin de l'appel — best-effort, sémantique reject vs
    /// end alignée sur CALL-BUG-02 (entrant jamais décroché = reject ; sortant ou
    /// décroché = end). Réutilisé par CXEndCallAction et providerDidReset.
    private func notifyBackendCallTerminated(_ call: ActiveCall) async {
        guard let callId = call.callId else { return }
        await notifyBackendCallTerminated(
            callId: callId,
            action: CallLifecyclePolicy.terminationAction(
                isOutgoing: call.isOutgoing,
                isAnswered: call.isAnswered,
                serverStatus: call.serverStatus
            )
        )
    }

    private func notifyBackendCallTerminated(
        callId: String,
        action: CallTerminationAction
    ) async {
        markRecentlyTerminated(callId)
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        do {
            try await performBackendCallTermination(callId: callId, action: action)
            terminationRetryStore.remove(ownerScopeId: ownerScopeId, callId: callId)
        } catch {
            terminationRetryStore.enqueue(
                ownerScopeId: ownerScopeId,
                callId: callId,
                action: action
            )
            logger.error("backend call termination failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performBackendCallTermination(
        callId: String,
        action: CallTerminationAction
    ) async throws {
        switch action {
        case .reject:
            do {
                try await callsService.reject(callId: callId)
            } catch {
                // The global call can race from RINGING to ACTIVE. `/end` is an
                // idempotent participant leave in both states.
                try await callsService.end(callId: callId)
            }
        case .leave:
            try await callsService.end(callId: callId)
        }
    }

    func retryPendingCallTerminations() async {
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        for record in terminationRetryStore.pending(ownerScopeId: ownerScopeId) {
            do {
                try await performBackendCallTermination(
                    callId: record.callId,
                    action: record.action
                )
                terminationRetryStore.remove(ownerScopeId: ownerScopeId, callId: record.callId)
            } catch {
                logger.error("call termination replay failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// CALL-RTC-01/02 : le média s'est terminé côté distant (l'autre a raccroché,
    /// room fermée, réseau tombé). On clôt l'appel CallKit natif (reportCall) puis
    /// on nettoie. On NE rappelle PAS le backend : le distant a déjà clos la session.
    private func handleRemoteDisconnect() {
        guard let call = activeCall else { return }
        reportCallEnded(call.id, reason: .remoteEnded)
        Task {
            await notifyBackendCallTerminated(call)
            await tearDown()
        }
    }

    private func handleE2EETrustLost() {
        guard let call = activeCall, !call.isEnding else { return }
        activeCall?.isEnding = true
        reportCallEnded(call.id, reason: .failed)
        Task {
            await notifyBackendCallTerminated(call)
            await tearDown()
        }
    }

    private func startIncomingReconciliation(callId: String) {
        incomingReconciliationTask?.cancel()
        incomingReconciliationTask = Task { [weak self] in
            // Le backend expire les sonneries à 45 s. Une vérification toutes les
            // trois secondes suffit à retirer rapidement une réponse autre appareil
            // sans polling agressif.
            for _ in 0..<15 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self,
                      self.activeCall?.callId == callId,
                      self.activeCall?.isAnswered == false else { return }
                await self.reconcilePendingIncomingCall()
            }

            // Même si `/pending` reste bloqué sur `ringing` (ou si son expiration
            // serveur dérive), CallKit ne doit jamais sonner indéfiniment. La
            // fenêtre produit/backend est de 45 s : on clôt localement et on
            // rejoue un reject best-effort, idempotent pour l'utilisateur.
            guard let self,
                  let call = self.activeCall,
                  call.callId == callId,
                  !call.isAnswered,
                  !call.isEnding else { return }
            self.reportCallEnded(call.id, reason: .unanswered)
            await self.notifyBackendCallTerminated(call)
            await self.tearDown()
        }
    }

    private func markRecentlyTerminated(_ callId: String) {
        let now = Date()
        recentlyTerminatedCallIDs = recentlyTerminatedCallIDs.filter { now.timeIntervalSince($0.value) < 90 }
        recentlyTerminatedCallIDs[callId] = now
    }

    private func wasRecentlyTerminated(_ callId: String) -> Bool {
        guard let date = recentlyTerminatedCallIDs[callId] else { return false }
        if Date().timeIntervalSince(date) < 90 { return true }
        recentlyTerminatedCallIDs[callId] = nil
        return false
    }

    private var lastVoipToken: String?
    /// CALL-VOIP-07 : vrai uniquement quand le dernier POST du token VoIP a
    /// échoué. On ne retente alors qu'au prochain foreground OU au retour réseau,
    /// au lieu de re-POSTer inutilement un token déjà synchronisé.
    private var voipTokenNeedsSync = false

    fileprivate func registerVoIPToken(_ token: String) async {
        lastVoipToken = token
        do {
            let _: SuccessResponse = try await api.requestJSON(
                "/api/user/voip-token",
                body: [
                    "voipToken": token,
                    "platform": "ios",
                    "deviceId": deviceID,
                    "environment": api.config.environment.rawValue,
                ]
            )
            voipTokenNeedsSync = false
        } catch {
            // CALL-VOIP-04 : ne plus avaler l'échec silencieusement ; on marque le
            // token à resynchroniser et on le garde pour le ré-enregistrer au
            // prochain passage authentifié / foreground / retour réseau.
            voipTokenNeedsSync = true
            logger.error("VoIP token registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ré-enregistre le dernier token VoIP UNIQUEMENT s'il reste à synchroniser
    /// (retour foreground / retour réseau). No-op si déjà à jour.
    func retryVoIPTokenRegistrationIfNeeded() async {
        guard voipTokenNeedsSync, let token = lastVoipToken else { return }
        await registerVoIPToken(token)
    }

    /// CALL-VOIP-04 : ré-associe le token VoIP à la SESSION authentifiée courante,
    /// SANS condition de needsSync. Indispensable car `registerForVoIPPushes` est
    /// gardé (registry déjà créé) → `didUpdate pushCredentials` n'est PAS re-livré
    /// à un 2e login dans le même process (install→1er login, ou changement de
    /// compte). No-op au tout premier login tant que le token n'a pas été livré
    /// (le `didUpdate` initial fera alors le POST).
    func registerVoIPTokenForSession() async {
        guard let token = lastVoipToken else { return }
        await registerVoIPToken(token)
    }

    /// CALL-VOIP-05 : révoque le token VoIP côté serveur au logout (best-effort)
    /// pour qu'un autre compte sur cet appareil ne reçoive pas les pushes VoIP de
    /// l'ancien utilisateur. On GARDE `lastVoipToken` en mémoire (c'est le token de
    /// l'APPAREIL, pas du compte) : il sera ré-associé au prochain login via
    /// `registerVoIPTokenForSession`, sans attendre un nouveau `didUpdate`.
    func unregisterVoIPToken() async {
        guard let token = lastVoipToken else { return }
        do {
            let _: SuccessResponse = try await api.requestJSON(
                "/api/user/voip-token",
                method: .delete,
                body: [
                    "voipToken": token,
                    "platform": "ios",
                    "deviceId": deviceID,
                    "environment": api.config.environment.rawValue,
                ]
            )
        } catch {
            // Best-effort : la route DELETE peut ne pas encore exister côté backend.
            logger.error("VoIP token unregister failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated fileprivate static func string(_ info: [AnyHashable: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = info[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - CXProviderDelegate
/// Confines a non-Sendable system object (a CXAction or a PushKit completion
/// handler) so it can be ferried into a MainActor task. Safe because CallKit and
/// PushKit deliver on the main queue and we only ever touch the value on the
/// MainActor.
private struct UnsafeMainActorBox<T>: @unchecked Sendable {
    let value: T
}

// CallKit/PushKit deliver these callbacks on the main queue; we hop onto the
// MainActor — boxing the non-Sendable action/completion — to touch our state.
extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            // CALL-RTC-06 : le système a réinitialisé le provider (crash CallKit,
            // changement d'état système) → on signale la fin au serveur AVANT le
            // teardown pour ne pas laisser de session fantôme, puis on nettoie.
            if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
            await self.tearDown()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            guard let call = self.activeCall, call.id == action.callUUID, let conversationId = call.conversationId else {
                action.fail(); return
            }
            do {
                let context = try self.outgoingE2EEContext(for: call)
                let session = try await self.callsService.initiate(
                    conversationId: conversationId,
                    mode: call.hasVideo ? "video" : "audio",
                    e2ee: context
                )
                self.activeCall?.callId = session.id
                self.activeCall?.requiresE2EE = session.e2eeRequired
                self.activeCall?.e2eeDescriptor = session.e2ee
                self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
                action.fulfill()
            } catch {
                self.logger.error("initiate failed: \(error.localizedDescription, privacy: .public)")
                if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                action.fail()
                await self.tearDown()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            guard let call = self.activeCall, let callId = call.callId else { action.fail(); return }
            do {
                let reconciled = try await self.reconcileE2EEForAnswer(call)
                let context = try self.answerE2EEContext(for: reconciled)
                let session = try await self.callsService.answer(callId: callId, e2ee: context)
                // L'autorisation serveur a déjà fait passer le participant à
                // `joined`; tout échec média ultérieur doit donc utiliser leave/end,
                // jamais reject (qui n'accepte que RINGING).
                self.activeCall?.isAnswered = true
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.showCallScreen = true
                action.fulfill()
            } catch {
                self.logger.error("answer failed: \(error.localizedDescription, privacy: .public)")
                // CALL-RTC-02 : l'appel a déjà été rapporté à CallKit (entrant) ;
                // action.fail() ne le retire pas → on le clôt explicitement pour ne
                // pas laisser une entrée d'appel fantôme côté système.
                if let id = self.activeCall?.id { self.reportCallEnded(id, reason: .failed) }
                if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                action.fail()
                await self.tearDown()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            let call = self.activeCall
            await self.liveKit.disconnect()
            // CALL-BUG-02 / CALL-RTC-06 : reject (entrant jamais décroché) vs end
            // (sortant ou décroché), factorisé dans notifyBackendCallTerminated.
            if let call { await self.notifyBackendCallTerminated(call) }
            self.activeCall = nil
            self.showCallScreen = false
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            self.liveKit.setMuted(box.value.isMuted)
            box.value.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.liveKit.audioSessionDidActivate(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.liveKit.audioSessionDidDeactivate(audioSession) }
    }
}

// MARK: - PKPushRegistryDelegate
extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await self.registerVoIPToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            // CALL-VOIP-06 : iOS a invalidé le token VoIP — on l'oublie pour ne pas
            // retenter d'enregistrer un token mort ; le prochain didUpdate en
            // fournira un neuf.
            self.lastVoipToken = nil
            self.voipTokenNeedsSync = false
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // Extract everything off the non-Sendable payload before crossing actors.
        let dict = payload.dictionaryPayload
        let callId = CallManager.string(dict, "callId", "call_id", "id")
        let conversationId = CallManager.string(dict, "conversationId", "conversation_id")
        let handle = CallManager.string(dict, "caller", "callerName", "handle", "title") ?? "Appel SignalQuest"
        let hasVideo = CallManager.string(dict, "mode", "type")?.lowercased() == "video"
        let e2eeExpectation = IncomingCallE2EEContract.parse(dict)
        // `callId` est l'identité canonique. Elle prime sur un UUID de push pour
        // qu'une relivraison APNs (ou un producteur qui régénère son UUID) ne
        // crée jamais une seconde entrée CallKit pour le même appel.
        let uuid = callId.map(CallLifecyclePolicy.callKitUUID(callId:))
            ?? CallManager.string(dict, "uuid", "callUuid").flatMap(UUID.init(uuidString:))
            ?? UUID()
        // CallKit exige de rapporter l'appel entrant DANS LE MÊME run loop, avant que
        // `completion` ne s'exécute — sinon iOS termine l'app et finit par cesser de
        // livrer les pushes VoIP. Le registre est créé avec `queue: .main` (l.132) et
        // ce delegate est `nonisolated` : on est donc déjà sur le MainActor, on rapporte
        // SYNCHRONEMENT via `assumeIsolated` au lieu d'un `Task` différé (ROB-06).
        let completionBox = UnsafeMainActorBox(value: completion)
        MainActor.assumeIsolated {
            guard let callId else {
                self.reportInvalidIncomingPush(uuid: uuid, handle: handle, hasVideo: hasVideo, completion: completionBox.value)
                return
            }
            if e2eeExpectation == .invalid {
                self.reportInvalidIncomingPush(
                    uuid: uuid,
                    handle: handle,
                    hasVideo: hasVideo,
                    completion: completionBox.value
                )
                return
            }
            let requirement: Bool?
            let descriptor: E2EEV2CallSessionDescriptor?
            switch e2eeExpectation {
            case .unresolved:
                requirement = nil
                descriptor = nil
            case .legacy:
                requirement = false
                descriptor = nil
            case .required(let value):
                requirement = true
                descriptor = value
            case .invalid:
                return
            }
            self.reportIncomingCall(
                uuid: uuid,
                callId: callId,
                conversationId: conversationId,
                handle: handle,
                hasVideo: hasVideo,
                requiresE2EE: requirement,
                e2eeDescriptor: descriptor,
                completion: completionBox.value
            )
        }
    }
}
