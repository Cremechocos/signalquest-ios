import Foundation
import AVFAudio
import os
#if canImport(LiveKit)
import LiveKit
#endif
#if canImport(LiveKitWebRTC)
import LiveKitWebRTC
#endif

@MainActor
final class LiveKitClient: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String), ended }

    @Published private(set) var state: State = .idle
    @Published private(set) var isMicMuted = false
    @Published private(set) var isCameraOn = false

    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "LiveKit")
    private let session = AVAudioSession.sharedInstance()
    /// When false, the audio session lifecycle is owned by CallKit and we must
    /// not activate/deactivate it ourselves.
    private var managesAudioSession = true
    /// Observateur des interruptions audio (appel entrant, Siri, alarme…).
    private var interruptionObserver: NSObjectProtocol?
#if canImport(LiveKit)
    private var room: Room?
    private var localMedia: LocalMedia?
#endif

    func connect(url: URL, token: String, room: String, video: Bool, managesAudioSession: Bool = true) async {
        state = .connecting
        self.managesAudioSession = managesAudioSession
        startObservingInterruptions()
        do {
            if managesAudioSession {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try session.setActive(true, options: [])
            } else {
                #if canImport(LiveKit)
                AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
                #endif
            }
            logger.info("Connecting to room=\(room, privacy: .public) video=\(video)")
#if canImport(LiveKit)
            let liveRoom = Room()
            try await liveRoom.connect(url: url.absoluteString, token: token)
            let media = LocalMedia(room: liveRoom)
            if !media.isMicrophoneEnabled {
                await media.toggleMicrophone()
            }
            if video && !media.isCameraEnabled {
                await media.toggleCamera()
            }
            self.room = liveRoom
            self.localMedia = media
            isCameraOn = video
            state = .connected
#else
            throw LiveKitUnavailableError()
#endif
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        stopObservingInterruptions()
#if canImport(LiveKit)
        await room?.disconnect()
        room = nil
        localMedia = nil
#endif
        if managesAudioSession {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        state = .ended
    }

    // MARK: Interruptions audio

    private func startObservingInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            // `Notification` n'est pas Sendable : on extrait les valeurs Sendable
            // (UInt) avant de franchir l'isolation MainActor.
            let info = note.userInfo
            let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // Interruption (appel téléphonique, Siri, alarme) : couper le micro
            // proprement pour ne pas diffuser pendant la suspension.
            logger.info("Audio session interrupted")
            if !isMicMuted { toggleMic() }
        case .ended:
            let options = optionsRaw
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // On ne réactive la session que si on en a la responsabilité (sinon
            // c'est CallKit qui la gère) et que le système autorise la reprise.
            if managesAudioSession, options.contains(.shouldResume) {
                try? session.setActive(true, options: [])
            }
            logger.info("Audio session interruption ended (resume=\(options.contains(.shouldResume), privacy: .public))")
        @unknown default:
            break
        }
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMicMuted else { return }
        toggleMic()
    }

    /// Called by CallManager when CallKit (de)activates the shared audio session.
    /// LiveKit manages its own audio engine; these are hook/log points and the
    /// place to add AudioManager coordination after on-device validation.
    func audioSessionDidActivate(_ audioSession: AVAudioSession) {
        logger.info("CallKit audio session activated")
        #if canImport(LiveKit)
        LKRTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        #endif
    }

    func audioSessionDidDeactivate(_ audioSession: AVAudioSession) {
        logger.info("CallKit audio session deactivated")
        #if canImport(LiveKit)
        LKRTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        #endif
    }

    func toggleMic() {
        Task {
#if canImport(LiveKit)
            await localMedia?.toggleMicrophone()
#endif
            isMicMuted.toggle()
        }
    }

    func toggleCamera() {
        Task {
#if canImport(LiveKit)
            await localMedia?.toggleCamera()
#endif
            isCameraOn.toggle()
        }
    }
}

private struct LiveKitUnavailableError: LocalizedError {
    var errorDescription: String? {
        "LiveKit SDK indisponible dans ce build. Regenere le projet avec XcodeGen pour activer les appels."
    }
}
