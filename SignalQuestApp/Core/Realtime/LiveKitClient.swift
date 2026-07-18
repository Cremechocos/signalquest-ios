import Foundation
import AVFAudio
import Combine
import os
#if os(iOS)
import AVKit
import UIKit
#endif
#if canImport(LiveKit)
import LiveKit
#endif
#if canImport(LiveKitWebRTC)
import LiveKitWebRTC
#endif

@MainActor
final class LiveKitClient: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String), ended }

    enum MediaControlError: LocalizedError {
        case screenSharingDisabled

        var errorDescription: String? {
            switch self {
            case .screenSharingDisabled:
                return "Le partage d’écran n’est pas encore disponible sur iOS."
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// CALL-RTC-C : vrai quand LiveKit a perdu la liaison d'un appel ÉTABLI et
    /// tente de la rétablir (reconnexion quick ou full). On garde volontairement
    /// `state == .connected` plutôt que d'ajouter un cas `.reconnecting` à `State` :
    /// cela évite de rompre la logique existante et les `switch` exhaustifs sur
    /// `State` hors de ce fichier (CallSessionView). L'UI superpose un indicateur
    /// « Reconnexion… » tant que ce drapeau est vrai ; il revient à false dès que la
    /// liaison est rétablie ou que l'appel se termine.
    @Published private(set) var isReconnecting = false
    @Published private(set) var isMicMuted = false
    @Published private(set) var isCameraOn = false
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var mediaErrorMessage: String?
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var canStartPictureInPicture = false
#if canImport(LiveKit)
    struct RemoteVideo: Identifiable {
        let id: String
        let participantID: String
        let displayName: String
        let track: any VideoTrack
        let isScreenShare: Bool
    }

    @Published private(set) var remoteVideos: [RemoteVideo] = []
    @Published private(set) var localVideoTrack: (any VideoTrack)?
#endif

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
    /// Vrai quand c'est NOUS qui avons coupé le micro à cause d'une interruption
    /// audio (appel GSM, Siri, alarme). Sert à le rétablir à la fin — sinon
    /// l'utilisateur reste muet pour le reste de l'appel sans le savoir (CALL-RTC-A).
    private var micAutoMutedByInterruption = false
    /// CALL-RTC-05 : invalidé à chaque disconnect()/nouvelle connect() pour fermer
    /// une room devenue orpheline si un raccrochage survient pendant le connect.
    private var connectGeneration = 0
    /// CALL-RTC-01 : vrai pendant un disconnect() local, pour NE PAS traiter le
    /// didDisconnect provoqué par notre propre raccrochage comme une fin distante.
    private var isTearingDown = false
    /// CALL-RTC-B : mis à vrai par onDisconnect si la room se déconnecte pendant la
    /// fenêtre `.connecting` — c.-à-d. une fin distante / chute réseau survenue
    /// AVANT que connect() ait pu passer à `.connected`, notamment aux points de
    /// suspension `await media.toggleMicrophone()` / `toggleCamera()`. connect() le
    /// consulte avant de marquer l'appel connecté pour NE PAS forcer `.connected`
    /// sur une room morte (« appel fantôme »). Réinitialisé à chaque connect().
    private var didDisconnectDuringConnect = false
    private var emptyRoomTask: Task<Void, Never>?
    private var mediaCancellables = Set<AnyCancellable>()
#if os(iOS) && canImport(LiveKit)
    private let pictureInPicture = LiveKitPictureInPictureController()
#endif
#if canImport(LiveKit)
    private var room: Room?
    private var localMedia: LocalMedia?
    private var roomObserver: RoomConnectionObserver?
#endif

    func prepareForCall() {
        guard state != .connecting, state != .connected else { return }
        state = .idle
        mediaErrorMessage = nil
    }

    func connect(url: URL, token: String, room: String, video: Bool, managesAudioSession: Bool = true) async {
        // CALL-RTC-05 : marque cette tentative ; un disconnect() concurrent
        // incrémentera connectGeneration et on fermera la room au retour de l'await.
        connectGeneration &+= 1
        let myGeneration = connectGeneration
        isTearingDown = false
        didDisconnectDuringConnect = false
        isReconnecting = false
        emptyRoomTask?.cancel()
        emptyRoomTask = nil
        state = .connecting
        mediaErrorMessage = nil
#if canImport(LiveKit)
        remoteVideos = []
        localVideoTrack = nil
#endif
        mediaCancellables.removeAll()
        self.managesAudioSession = managesAudioSession
        isSpeakerOn = video
#if canImport(LiveKit)
        AudioManager.shared.isSpeakerOutputPreferred = video
#endif
        startObservingInterruptions()
        do {
            // CallKit owns activation/deactivation, but the app still owns the
            // category and mode used once CallKit activates the session. Without
            // this configuration an audio call can inherit a playback-only
            // category and publish no microphone on a real device.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                // Ne pas utiliser `.defaultToSpeaker` : avec cette option,
                // `overrideOutputAudioPort(.none)` ne revient pas fiablement à
                // l'écouteur et le bouton haut-parleur mentirait à l'utilisateur.
                options: [.allowBluetoothHFP]
            )
            if managesAudioSession {
                try session.setActive(true, options: [])
            } else {
                #if canImport(LiveKit)
                AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
                #endif
            }
            applySpeakerOutput()
            // Le nom de room contient l'identifiant de conversation : ne jamais
            // l'émettre dans les journaux de production.
            logger.info("Connecting to LiveKit (video=\(video, privacy: .public))")
#if canImport(LiveKit)
            let observer = RoomConnectionObserver(
                onDisconnect: { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.isTearingDown else { return }
                        // CALL-RTC-B : la room est tombée pendant la fenêtre
                        // `.connecting` (avant que connect() ait pu passer à
                        // `.connected`, p.ex. aux await toggleMic/toggleCamera).
                        // La mémoriser pour que connect() termine proprement au lieu
                        // de forcer `.connected` sur une room morte.
                        if self.state == .connecting {
                            self.didDisconnectDuringConnect = true
                            return
                        }
                        guard self.state == .connected else { return }
                        // Déconnexion de LA ROOM (fin distante / chute réseau). Le
                        // départ d'un participant d'un groupe ne termine pas l'appel.
                        self.isReconnecting = false
                        self.state = .ended
                        self.onRemoteDisconnect?()
                    }
                },
                onReconnectingChanged: { [weak self] reconnecting in
                    Task { @MainActor in self?.setReconnecting(reconnecting) }
                },
                onMediaChanged: { [weak self] in
                    Task { @MainActor in self?.refreshRemoteMedia() }
                }
            )
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
            // CALL-RTC-B : une déconnexion de room (fin distante / chute réseau) a
            // pu survenir pendant la fenêtre `.connecting` — au retour de
            // liveRoom.connect() ou aux points de suspension toggleMicrophone/
            // toggleCamera ci-dessus. onDisconnect l'a alors signalée via
            // didDisconnectDuringConnect (et la room est retombée à .disconnected).
            // Marquer `.connected` créerait un « appel fantôme » sur une room morte,
            // nettoyé seulement par le filet de secours 45 s : terminer proprement
            // à la place. connectLiveKit() traite tout état != .connected comme un
            // échec et défait CallKit. (À partir d'ici plus aucun await ne précède
            // `state = .connected`, la fenêtre est donc close.)
            if didDisconnectDuringConnect || liveRoom.connectionState == .disconnected {
                await liveRoom.disconnect()
                state = .ended
                return
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
            media.$canSwitchCamera
                .receive(on: DispatchQueue.main)
                .sink { [weak self] canSwitch in self?.canSwitchCamera = canSwitch }
                .store(in: &mediaCancellables)
            media.$cameraTrack
                .receive(on: DispatchQueue.main)
                .sink { [weak self] track in
                    self?.localVideoTrack = track
                    self?.refreshPictureInPictureTrack()
                }
                .store(in: &mediaCancellables)
            refreshRemoteMedia()
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
        emptyRoomTask?.cancel()
        emptyRoomTask = nil
        mediaCancellables.removeAll()
        stopObservingInterruptions()
#if os(iOS) && canImport(LiveKit)
        pictureInPicture.stop()
#endif
#if canImport(LiveKit)
        await room?.disconnect()
        room = nil
        localMedia = nil
        roomObserver = nil
        remoteVideos = []
        localVideoTrack = nil
#endif
        if managesAudioSession {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        state = .ended
        isReconnecting = false
        isMicMuted = false
        isCameraOn = false
        canSwitchCamera = false
        canStartPictureInPicture = false
        isPictureInPictureActive = false
    }

    /// CALL-RTC-C : reflète l'état de reconnexion remonté par LiveKit
    /// (`didUpdateConnectionState` `.reconnecting`/`.connected`, ou
    /// `didStart`/`didCompleteReconnectWithMode` que le SDK émet pour le mode
    /// `quick` — non couvert par `didUpdateConnectionState`). On ne signale une
    /// reconnexion que pour un appel DÉJÀ établi (`state == .connected`) afin de ne
    /// pas confondre avec l'établissement initial (`.connecting`, piloté par
    /// connect()). `state` reste `.connected` : la liaison est rétablie sans
    /// repasser par `.connecting`, et un échec définitif suit le flux `onDisconnect`
    /// habituel (didDisconnectWithError).
    private func setReconnecting(_ reconnecting: Bool) {
        guard !isTearingDown else { return }
        if reconnecting {
            guard state == .connected else { return }
            isReconnecting = true
        } else {
            isReconnecting = false
        }
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
            Task { @MainActor in
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
            // proprement pour ne pas diffuser pendant la suspension. On mémorise que
            // c'est automatique afin de le rétablir à la fin.
            logger.info("Audio session interrupted")
            if !isMicMuted {
                micAutoMutedByInterruption = true
                toggleMic()
            }
        case .ended:
            let options = optionsRaw
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // On ne réactive la session que si on en a la responsabilité (sinon
            // c'est CallKit qui la gère) et que le système autorise la reprise.
            if managesAudioSession, options.contains(.shouldResume) {
                try? session.setActive(true, options: [])
            }
            // Rétablir le micro SI c'est nous qui l'avions coupé et qu'il l'est
            // toujours (l'utilisateur n'y a pas retouché entre-temps).
            if micAutoMutedByInterruption, isMicMuted {
                toggleMic()
            }
            micAutoMutedByInterruption = false
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
        applySpeakerOutput()
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

    func switchCamera() {
        guard canSwitchCamera else { return }
        Task {
#if canImport(LiveKit)
            await localMedia?.switchCamera()
#endif
        }
    }

    func toggleSpeaker() {
        setSpeakerOutput(!isSpeakerOn)
    }

    /// Présent pour préparer l'interopérabilité, mais rendu inatteignable par le
    /// feature flag tant que les tests Android↔iOS ne sont pas verts.
    func toggleScreenShare() async throws {
        guard SQFeatures.callScreenSharingEnabled else {
            throw MediaControlError.screenSharingDisabled
        }
#if canImport(LiveKit)
        await localMedia?.toggleScreenShare(disableCamera: false)
#endif
    }

#if os(iOS)
    func configurePictureInPicture(sourceView: UIView) {
#if canImport(LiveKit)
        pictureInPicture.onStateChanged = { [weak self] active, possible in
            self?.isPictureInPictureActive = active
            self?.canStartPictureInPicture = possible && self?.pictureInPictureTrack != nil
        }
        pictureInPicture.configure(sourceView: sourceView, track: pictureInPictureTrack)
        canStartPictureInPicture = pictureInPicture.isPossible && pictureInPictureTrack != nil
#endif
    }

    func togglePictureInPicture() {
#if canImport(LiveKit)
        guard pictureInPictureTrack != nil else { return }
        pictureInPicture.toggle()
#endif
    }
#endif

    private func setSpeakerOutput(_ enabled: Bool) {
        isSpeakerOn = enabled
#if canImport(LiveKit)
        AudioManager.shared.isSpeakerOutputPreferred = enabled
#endif
        applySpeakerOutput()
    }

    private func applySpeakerOutput() {
        do {
            try session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
            mediaErrorMessage = nil
        } catch {
            mediaErrorMessage = "Sortie audio indisponible : \(error.localizedDescription)"
            logger.error("Speaker route failed: \(error.localizedDescription, privacy: .public)")
        }
    }

#if canImport(LiveKit)
    private var pictureInPictureTrack: (any VideoTrack)? {
        remoteVideos.first(where: { !$0.isScreenShare })?.track
            ?? remoteVideos.first?.track
            ?? localVideoTrack
    }

    private func refreshRemoteMedia() {
        guard let room else {
            remoteVideos = []
            refreshPictureInPictureTrack()
            return
        }
        let tracks = room.remoteParticipants.values
            .sorted { ($0.name ?? $0.identity?.stringValue ?? "") < ($1.name ?? $1.identity?.stringValue ?? "") }
            .flatMap { participant -> [RemoteVideo] in
                let participantID = participant.identity?.stringValue
                    ?? participant.sid?.stringValue
                    ?? "participant"
                let displayName = participant.name ?? "Participant"
                var videos: [RemoteVideo] = []
                if SQFeatures.callScreenSharingEnabled,
                   let track = participant.firstScreenShareVideoTrack {
                    videos.append(RemoteVideo(
                        id: "\(participantID):screen",
                        participantID: participantID,
                        displayName: displayName,
                        track: track,
                        isScreenShare: true
                    ))
                }
                if let track = participant.firstCameraVideoTrack {
                    videos.append(RemoteVideo(
                        id: "\(participantID):camera",
                        participantID: participantID,
                        displayName: displayName,
                        track: track,
                        isScreenShare: false
                    ))
                }
                return videos
            }
        // Le produit limite un appel à huit personnes : sept vidéos distantes au
        // maximum, même face à une room backend mal configurée.
        remoteVideos = Array(tracks.prefix(7))
        reconcileRemoteParticipantPresence(in: room)
        refreshPictureInPictureTrack()
    }

    private func reconcileRemoteParticipantPresence(in room: Room) {
        if !room.remoteParticipants.isEmpty {
            emptyRoomTask?.cancel()
            emptyRoomTask = nil
            return
        }
        guard state == .connected || state == .connecting, emptyRoomTask == nil else { return }
        // En groupe, une première personne peut partir pendant que d'autres
        // destinataires sonnent encore. Conserver toute la fenêtre de sonnerie
        // évite de couper l'appelant après le départ du premier participant.
        // En 1:1, la suppression normale de la room termine immédiatement via
        // didDisconnect ; ces 45 s ne sont qu'un filet si le backend échoue.
        let delay: Duration = .seconds(45)
        emptyRoomTask = Task { [weak self, weak room] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let room,
                  !self.isTearingDown,
                  self.state == .connected,
                  room.remoteParticipants.isEmpty else { return }
            // Aucun participant distant après la sonnerie, ou tous les distants
            // sont partis sans que le backend ait fermé la room : terminer le
            // participant local évite un appel fantôme indéfini.
            self.state = .ended
            self.onRemoteDisconnect?()
        }
    }

    private func refreshPictureInPictureTrack() {
#if os(iOS)
        pictureInPicture.update(track: pictureInPictureTrack)
        canStartPictureInPicture = pictureInPicture.isPossible && pictureInPictureTrack != nil
#endif
    }
#endif
}

#if canImport(LiveKit)
/// Forwarder RoomDelegate : le SDK LiveKit livre ces callbacks hors du MainActor.
/// On ne retient QUE la déconnexion (raccrochage distant / chute réseau) et on
/// notifie LiveKitClient via le closure (qui hop sur le MainActor). CALL-RTC-01.
private final class RoomConnectionObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let onDisconnect: @Sendable () -> Void
    private let onReconnectingChanged: @Sendable (Bool) -> Void
    private let onMediaChanged: @Sendable () -> Void

    init(
        onDisconnect: @escaping @Sendable () -> Void,
        onReconnectingChanged: @escaping @Sendable (Bool) -> Void,
        onMediaChanged: @escaping @Sendable () -> Void
    ) {
        self.onDisconnect = onDisconnect
        self.onReconnectingChanged = onReconnectingChanged
        self.onMediaChanged = onMediaChanged
        super.init()
    }
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) { onDisconnect() }
    // CALL-RTC-C : état de connexion de la room. `.reconnecting`/`.connected`
    // pilotent l'indicateur de reconnexion ; `.disconnected` est déjà traité par
    // didDisconnectWithError. `ConnectionState` est Sendable, on n'en dérive qu'un
    // Bool avant le hop MainActor côté LiveKitClient.
    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        switch connectionState {
        case .reconnecting: onReconnectingChanged(true)
        case .connected: onReconnectingChanged(false)
        default: break
        }
    }
    // CALL-RTC-C : le SDK N'émet PAS didUpdateConnectionState pour le mode de
    // reconnexion `.quick` ; ces deux callbacks couvrent quick ET full.
    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) { onReconnectingChanged(true) }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) { onReconnectingChanged(false) }
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { onMediaChanged() }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { onMediaChanged() }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) { onMediaChanged() }
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { onMediaChanged() }
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { onMediaChanged() }
}
#endif

#if os(iOS) && canImport(LiveKit)
@MainActor
private final class LiveKitPictureInPictureController: NSObject {
    var onStateChanged: ((Bool, Bool) -> Void)?
    private(set) var isPossible = false

    private weak var sourceView: UIView?
    private var controller: AVPictureInPictureController?
    private var possibilityObservation: AnyCancellable?
    private let contentController = AVPictureInPictureVideoCallViewController()
    private let videoView = VideoView()

    override init() {
        super.init()
        contentController.preferredContentSize = CGSize(width: 360, height: 640)
        contentController.view.backgroundColor = .black
        videoView.layoutMode = .fit
        videoView.translatesAutoresizingMaskIntoConstraints = false
        contentController.view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: contentController.view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: contentController.view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: contentController.view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: contentController.view.bottomAnchor),
        ])
    }

    func configure(sourceView: UIView, track: (any VideoTrack)?) {
        update(track: track)
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPossible = false
            onStateChanged?(false, false)
            return
        }
        guard self.sourceView !== sourceView || controller == nil else {
            updatePossibility()
            return
        }
        controller?.stopPictureInPicture()
        possibilityObservation = nil
        self.sourceView = sourceView
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        possibilityObservation = controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePossibility() }
        updatePossibility()
    }

    func update(track: (any VideoTrack)?) {
        videoView.track = track
        updatePossibility()
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
        possibilityObservation = nil
        videoView.track = nil
        isPossible = false
        onStateChanged?(false, false)
    }

    private func updatePossibility() {
        isPossible = controller?.isPictureInPicturePossible == true && videoView.track != nil
        onStateChanged?(controller?.isPictureInPictureActive == true, isPossible)
    }
}

extension LiveKitPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.onStateChanged?(true, self.isPossible) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.onStateChanged?(false, self.isPossible) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in self.onStateChanged?(false, self.isPossible) }
    }
}
#endif

private struct LiveKitUnavailableError: LocalizedError {
    var errorDescription: String? {
        "LiveKit SDK indisponible dans ce build. Regenere le projet avec XcodeGen pour activer les appels."
    }
}
