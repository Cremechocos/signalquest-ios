import Foundation
import AVFAudio
import Combine
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

    /// CALL-RTC-01 : appelé sur le MainActor quand la room se déconnecte en cours
    /// d'appel (l'autre participant part, room fermée, ou réseau tombé). Câblé par
    /// CallManager pour clôturer l'appel CallKit.
    var onRemoteDisconnect: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "LiveKit")
    private let session = AVAudioSession.sharedInstance()
    /// When false, the audio session lifecycle is owned by CallKit and we must
    /// not activate/deactivate it ourselves.
    private var managesAudioSession = true
    /// Observateur des interruptions audio (appel entrant, Siri, alarme…).
    private var interruptionObserver: NSObjectProtocol?
    /// CALL-RTC-05 : invalidé à chaque disconnect()/nouvelle connect() pour fermer
    /// une room devenue orpheline si un raccrochage survient pendant le connect.
    private var connectGeneration = 0
    /// CALL-RTC-01 : vrai pendant un disconnect() local, pour NE PAS traiter le
    /// didDisconnect provoqué par notre propre raccrochage comme une fin distante.
    private var isTearingDown = false
    private var mediaCancellables = Set<AnyCancellable>()
#if canImport(LiveKit)
    private var room: Room?
    private var localMedia: LocalMedia?
    private var roomObserver: RoomConnectionObserver?
#endif

    func connect(url: URL, token: String, room: String, video: Bool, managesAudioSession: Bool = true) async {
        // CALL-RTC-05 : marque cette tentative ; un disconnect() concurrent
        // incrémentera connectGeneration et on fermera la room au retour de l'await.
        connectGeneration &+= 1
        let myGeneration = connectGeneration
        isTearingDown = false
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
            let observer = RoomConnectionObserver { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isTearingDown, self.state == .connected else { return }
                    // Déconnexion subie en cours d'appel (raccrochage distant / chute
                    // réseau) — distincte de notre propre disconnect() (isTearingDown).
                    self.state = .ended
                    self.onRemoteDisconnect?()
                }
            }
            self.roomObserver = observer
            let liveRoom = Room(delegate: observer)
            try await liveRoom.connect(url: url.absoluteString, token: token)
            // Un raccrochage est survenu pendant le connect : fermer la room orpheline
            // au lieu de la marquer connectée (CALL-RTC-05).
            if myGeneration != connectGeneration {
                await liveRoom.disconnect()
                state = .ended
                return
            }
            let media = LocalMedia(room: liveRoom)
            if !media.isMicrophoneEnabled {
                await media.toggleMicrophone()
            }
            if video && !media.isCameraEnabled {
                await media.toggleCamera()
            }
            self.room = liveRoom
            self.localMedia = media
            // CALL-RTC-09 : isMicMuted / isCameraOn dérivent de l'état RÉEL du SDK
            // (et non d'un toggle optimiste) → l'UI et CallKit restent honnêtes même
            // si une bascule de track échoue.
            media.$isMicrophoneEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled in self?.isMicMuted = !enabled }
                .store(in: &mediaCancellables)
            media.$isCameraEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] on in self?.isCameraOn = on }
                .store(in: &mediaCancellables)
            state = .connected
#else
            throw LiveKitUnavailableError()
#endif
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        // CALL-RTC-05 : invalide toute connect() en vol. CALL-RTC-01 : isTearingDown
        // évite que le didDisconnect provoqué par CE disconnect soit traité comme
        // une fin distante (pas de double clôture).
        connectGeneration &+= 1
        isTearingDown = true
        mediaCancellables.removeAll()
        stopObservingInterruptions()
#if canImport(LiveKit)
        await room?.disconnect()
        room = nil
        localMedia = nil
        roomObserver = nil
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
        // CALL-RTC-09 : pas de bascule optimiste — isMicMuted est mis à jour par
        // l'abonnement Combine sur l'état réel du track.
        Task {
#if canImport(LiveKit)
            await localMedia?.toggleMicrophone()
#endif
        }
    }

    func toggleCamera() {
        Task {
#if canImport(LiveKit)
            await localMedia?.toggleCamera()
#endif
        }
    }
}

#if canImport(LiveKit)
/// Forwarder RoomDelegate : le SDK LiveKit livre ces callbacks hors du MainActor.
/// On ne retient QUE la déconnexion (raccrochage distant / chute réseau) et on
/// notifie LiveKitClient via le closure (qui hop sur le MainActor). CALL-RTC-01.
private final class RoomConnectionObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let onDisconnect: @Sendable () -> Void
    init(onDisconnect: @escaping @Sendable () -> Void) {
        self.onDisconnect = onDisconnect
        super.init()
    }
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) { onDisconnect() }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { onDisconnect() }
}
#endif

private struct LiveKitUnavailableError: LocalizedError {
    var errorDescription: String? {
        "LiveKit SDK indisponible dans ce build. Regenere le projet avec XcodeGen pour activer les appels."
    }
}
