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
        activeCall = ActiveCall(id: uuid, callId: callId, conversationId: conversationId, handle: handle, hasVideo: hasVideo, isOutgoing: false)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            completionBox.value?()
        }
    }

    // MARK: Internals

    private func connectLiveKit(for session: CallSession, video: Bool) async {
        guard let url = session.liveKitUrl, let token = session.liveKitToken, let room = session.liveKitRoom else {
            logger.error("Call session missing LiveKit credentials")
            return
        }
        await liveKit.connect(url: url, token: token, room: room, video: video, managesAudioSession: false)
    }

    private func tearDown() async {
        await liveKit.disconnect()
        activeCall = nil
        showCallScreen = false
    }

    fileprivate func registerVoIPToken(_ token: String) async {
        let _: SuccessResponse? = try? await api.requestJSON(
            "/api/user/voip-token",
            body: ["voipToken": token, "platform": "ios"]
        )
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
        Task { @MainActor in await self.tearDown() }
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
                await self.connectLiveKit(for: session, video: call.hasVideo)
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
                await self.connectLiveKit(for: session, video: call.hasVideo)
                self.showCallScreen = true
                action.fulfill()
            } catch {
                self.logger.error("answer failed: \(error.localizedDescription, privacy: .public)")
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
            if let callId = call?.callId {
                if call?.isOutgoing == false {
                    try? await self.callsService.reject(callId: callId)
                } else {
                    try? await self.callsService.end(callId: callId)
                }
            }
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
