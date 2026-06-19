import Foundation
import CallKit
import PushKit
import AVFAudio
import os

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
        /// Passe à true quand un appel ENTRANT a été décroché — distingue
        /// « jamais répondu » (reject) de « répondu puis raccroché » (end). CALL-BUG-02.
        var isAnswered: Bool = false
    }

    enum CallError: LocalizedError {
        case missingCredentials
        case connectionFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Identifiants d'appel manquants."
            case .connectionFailed(let m): return "Connexion à l'appel impossible : \(m)"
            }
        }
    }

    @Published private(set) var activeCall: ActiveCall?
    @Published var showCallScreen = false

    let liveKit = LiveKitClient()

    private let callsService: CallsServicing
    private let api: APIClient
    private let provider: CXProvider
    private let callController = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "CallKit")

    init(callsService: CallsServicing, api: APIClient) {
        self.callsService = callsService
        self.api = api
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

    func startOutgoingCall(conversationId: String, mode: String, displayName: String) {
        guard activeCall == nil else { return }
        let uuid = UUID()
        let hasVideo = mode.lowercased() == "video"
        activeCall = ActiveCall(id: uuid, callId: nil, conversationId: conversationId, handle: displayName, hasVideo: hasVideo, isOutgoing: true)
        showCallScreen = true
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: displayName))
        action.isVideo = hasVideo
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error { self?.logger.error("startCall request failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// User taps hang-up in the in-app call screen.
    func endActiveCall() {
        guard let call = activeCall else {
            showCallScreen = false
            return
        }
        let action = CXEndCallAction(call: call.id)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                self?.logger.error("endCall request failed: \(error.localizedDescription, privacy: .public)")
                // Force local teardown if CallKit refused the transaction.
                Task { @MainActor in await self?.tearDown() }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let call = activeCall else { return }
        let action = CXSetMutedCallAction(call: call.id, muted: muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    // MARK: Incoming

    func reportIncomingCall(uuid: UUID, callId: String?, conversationId: String?, handle: String, hasVideo: Bool, completion: (() -> Void)?) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)

        // CALL-RTC-04 : un appel est déjà actif → on NE touche PAS activeCall ni la
        // session LiveKit en cours. On satisfait quand même l'exigence PushKit (tout
        // push VoIP doit être suivi d'un reportNewIncomingCall, sinon l'app est tuée)
        // puis on décline immédiatement le nouvel UUID, sans impacter l'appel courant.
        if activeCall != nil {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                if let error {
                    self?.logger.error("2nd reportNewIncomingCall failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                }
                completionBox.value?()
            }
            return
        }

        activeCall = ActiveCall(id: uuid, callId: callId, conversationId: conversationId, handle: handle, hasVideo: hasVideo, isOutgoing: false)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                // Échec du report du SEUL nouvel appel : nettoyage local (aucun appel
                // n'était actif avant), pas de tearDown global.
                self?.logger.error("reportNewIncomingCall failed: \(error.localizedDescription, privacy: .public)")
                self?.activeCall = nil
                self?.showCallScreen = false
            }
            completionBox.value?()
        }
    }

    /// CALL-INCOMING-03 : filet anti-perte de push VoIP. À appeler au retour au premier
    /// plan (et après login) : demande au serveur les appels en attente et, si un appel
    /// « ringing »/« pending » n'est pas déjà actif, le présente via CallKit.
    func reconcilePendingIncomingCall() async {
        guard activeCall == nil else { return }
        guard let pending = try? await callsService.pending() else { return }
        guard let call = pending.first(where: { $0.status == "ringing" || $0.status == "pending" }) else { return }
        reportIncomingCall(
            uuid: UUID(),
            callId: call.id,
            conversationId: call.conversationId,
            handle: call.participants?.first ?? "Appel SignalQuest",
            hasVideo: call.mode == "video",
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
        await liveKit.connect(url: url, token: token, room: room, video: video, managesAudioSession: false)
        if case .failed(let message) = liveKit.state {
            logger.error("LiveKit connect failed: \(message, privacy: .public)")
            throw CallError.connectionFailed(message)
        }
    }

    private func tearDown() async {
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
        if call.isOutgoing == false && call.isAnswered == false {
            try? await callsService.reject(callId: callId)
        } else {
            try? await callsService.end(callId: callId)
        }
    }

    /// CALL-RTC-01/02 : le média s'est terminé côté distant (l'autre a raccroché,
    /// room fermée, réseau tombé). On clôt l'appel CallKit natif (reportCall) puis
    /// on nettoie. On NE rappelle PAS le backend : le distant a déjà clos la session.
    private func handleRemoteDisconnect() {
        guard let call = activeCall else { return }
        reportCallEnded(call.id, reason: .remoteEnded)
        Task { await tearDown() }
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
                body: ["voipToken": token, "platform": "ios"]
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
                body: ["voipToken": token, "platform": "ios"]
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
                let session = try await self.callsService.initiate(conversationId: conversationId, mode: call.hasVideo ? "video" : "audio")
                self.activeCall?.callId = session.id
                self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
                action.fulfill()
            } catch {
                self.logger.error("initiate failed: \(error.localizedDescription, privacy: .public)")
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
                let session = try await self.callsService.answer(callId: callId)
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.activeCall?.isAnswered = true
                self.showCallScreen = true
                action.fulfill()
            } catch {
                self.logger.error("answer failed: \(error.localizedDescription, privacy: .public)")
                // CALL-RTC-02 : l'appel a déjà été rapporté à CallKit (entrant) ;
                // action.fail() ne le retire pas → on le clôt explicitement pour ne
                // pas laisser une entrée d'appel fantôme côté système.
                if let id = self.activeCall?.id { self.reportCallEnded(id, reason: .failed) }
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
        let uuid = CallManager.string(dict, "uuid", "callUuid").flatMap(UUID.init(uuidString:)) ?? UUID()
        // CallKit requires reporting the incoming call before `completion` runs;
        // the provider delivers on the main queue so we report synchronously.
        let completionBox = UnsafeMainActorBox(value: completion)
        MainActor.assumeIsolated {
            self.reportIncomingCall(uuid: uuid, callId: callId, conversationId: conversationId, handle: handle, hasVideo: hasVideo, completion: completionBox.value)
        }
    }
}
