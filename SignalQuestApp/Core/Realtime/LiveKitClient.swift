import CryptoKit
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

enum CallAudioRoutePolicy {
    static func wantsSpeaker(
        video: Bool,
        userOverride: Bool?,
        hasExternalRoute: Bool
    ) -> Bool {
        if let userOverride { return userOverride }
        return video && !hasExternalRoute
    }
}

enum CallBackgroundMediaPolicy {
    /// iOS cannot keep arbitrary camera capture alive in the background. Remote
    /// video remains available to the system PiP controller.
    static let suspendLocalVideoTracks = true
}

/// Pourquoi un appel chiffré a été coupé, pour le dire à l'écran.
enum E2EEV2CallTrustLoss: Equatable, Sendable {
    /// Clé, chiffrement ou déchiffrement en échec.
    case verification
    /// Preuve de jonction invalide, ou absente 10 secondes après une arrivée.
    case joinProof
    /// Reconnexion complète : le SDK y réarme le marqueur SIF et réintègre les
    /// participants sans événement. Un appel chiffré n'y survit pas.
    case reconnected
}

@MainActor
final class LiveKitClient: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String), ended }

    enum MediaSetupMode: Equatable {
        case standard
        #if DEBUG
        /// Évite uniquement le helper SwiftUI `LocalMedia` sur simulateur, où
        /// son changement synchrone de mute-mode WebRTC peut deadlocker
        /// RemoteIO. Les tracks restent créées/publiées par le SDK LiveKit réel.
        case localQADataOnly
        #endif
    }

    enum MediaControlError: LocalizedError {
        case screenSharingDisabled

        var errorDescription: String? {
            switch self {
            case .screenSharingDisabled:
                return String(localized: "Le partage d’écran n’est pas encore disponible sur iOS.")
            }
        }
    }

    enum DataChannelError: LocalizedError {
        case notConnected
        case invalidPayload
        case e2eeNotVerified

        var errorDescription: String? {
            switch self {
            case .notConnected: "L’appel n’est pas connecté."
            case .invalidPayload: "Les données de l’appel sont invalides ou trop volumineuses."
            case .e2eeNotVerified: "Le canal chiffré de l’appel n’est pas encore vérifié."
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
    /// Arrivée du premier participant distant : la sonnerie s'arrête et le
    /// minuteur de l'appel démarre. Une room connectée où personne n'a encore
    /// décroché affichait « En appel » (SOC-13).
    @Published private(set) var remoteJoinedAt: Date?
    @Published private(set) var isMicMuted = false
    @Published private(set) var isCameraOn = false
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var mediaErrorMessage: String?
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var canStartPictureInPicture = false
    /// True only after every expected LiveKit track cryptor reports `.ok`.
    @Published private(set) var isE2EEVerified = false
    /// Compteur de preuves négatives : incrémenté uniquement lorsque LiveKit
    /// signale qu'un paquet data chiffré n'a pas pu être déchiffré.
    @Published private(set) var e2eeDataDecryptionFailureCount = 0
#if canImport(LiveKit)
    struct RemoteVideo: Identifiable {
        let id: String
        let participantID: String
        let displayName: String
        let track: any VideoTrack
        let isScreenShare: Bool
    }

    struct RemoteAudio: Identifiable {
        let id: String
        let participantID: String
        let track: any AudioTrack
    }

    @Published private(set) var remoteVideos: [RemoteVideo] = []
    @Published private(set) var remoteAudios: [RemoteAudio] = []
    @Published private(set) var localVideoTrack: (any VideoTrack)?
#endif

    /// CALL-RTC-01 : appelé sur le MainActor quand la room se déconnecte en cours
    /// d'appel (l'autre participant part, room fermée, ou réseau tombé). Câblé par
    /// CallManager pour clôturer l'appel CallKit.
    var onRemoteDisconnect: (@MainActor () -> Void)?
    /// A verified E2EE call encountered a terminal cryptor/revocation failure.
    /// CallManager closes CallKit and queues the participant leave fail-closed.
    var onE2EETrustLost: (@MainActor (E2EEV2CallTrustLoss) -> Void)?
    /// Point d'extension minimal pour les données d'appel (réactions, radio QA).
    /// Le SDK a déjà déchiffré `data` avant cet appel ; les paquets non-GCM sont
    /// refusés lorsque la session exige E2EE v2.
    var onDataReceived: (@MainActor (_ senderIdentity: String?, _ data: Data, _ topic: String) -> Void)?
    /// Appel prouvé : nom d'un utilisateur prouvé, lu sur l'appareil. Le nom
    /// du jeton, choisi par le serveur, n'y sert jamais (§10.4).
    var participantName: (@MainActor (_ userId: String) -> String?)?

    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "LiveKit")
    private let session = AVAudioSession.sharedInstance()
    /// When false, the audio session lifecycle is owned by CallKit and we must
    /// not activate/deactivate it ourselves.
    private var managesAudioSession = true
    /// Observateur des interruptions audio (appel entrant, Siri, alarme…).
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
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
    private var didE2EEFailDuringConnect = false
    /// Heure de jonction de notre preuve, identique à chaque renvoi.
    private var localJoinedAtMs: Int64 = 0
    private var callHasVideo = false
    private var userSpeakerOverride: Bool?
    private var emptyRoomTask: Task<Void, Never>?
    private var mediaCancellables = Set<AnyCancellable>()
    private var allowsLocalQADataBootstrap = false
#if os(iOS) && canImport(LiveKit)
    private let pictureInPicture = LiveKitPictureInPictureController()
#endif
#if canImport(LiveKit)
    private var room: Room?
    #if DEBUG && canImport(LiveKit)
    private var debugFeeders: [Task<Void, Never>] = []
    #endif
    private var localMedia: LocalMedia?
    private var roomObserver: RoomConnectionObserver?
    private var activeE2eeSession: E2EEV2LiveKitSession?
    /// Appel chiffré : sources en cours de bascule. Une seconde bascule est
    /// ignorée au lieu de publier une seconde piste.
    private var encryptedSourcesInFlight = Set<Track.Source>()
    #if DEBUG
    private var disabledAudioEngineForLocalQA = false
    enum DebugLocalTrackEvent: Equatable { case publishedMuted, cryptorOK, unmuted }
    /// Banc local : étapes de la publication d'une piste locale chiffrée.
    private(set) var debugLocalTrackEvents: [DebugLocalTrackEvent] = []
    #endif
#endif

    func prepareForCall() {
        guard state != .connecting, state != .connected else { return }
        state = .idle
        mediaErrorMessage = nil
    }

    func connect(
        url: URL,
        token: String,
        room: String,
        video: Bool,
        managesAudioSession: Bool = true,
        e2eeSession: E2EEV2LiveKitSession? = nil,
        mediaSetupMode: MediaSetupMode = .standard
    ) async {
        // CALL-RTC-05 : marque cette tentative ; un disconnect() concurrent
        // incrémentera connectGeneration et on fermera la room au retour de l'await.
        connectGeneration &+= 1
        let myGeneration = connectGeneration
        isTearingDown = false
        didDisconnectDuringConnect = false
        didE2EEFailDuringConnect = false
        isReconnecting = false
        remoteJoinedAt = nil
        isE2EEVerified = false
        e2eeDataDecryptionFailureCount = 0
        emptyRoomTask?.cancel()
        emptyRoomTask = nil
        state = .connecting
        mediaErrorMessage = nil
#if canImport(LiveKit)
        remoteVideos = []
        remoteAudios = []
        localVideoTrack = nil
        #if DEBUG
        allowsLocalQADataBootstrap = mediaSetupMode == .localQADataOnly
        if allowsLocalQADataBootstrap {
            do {
                try AudioManager.shared.setEngineAvailability(.none)
                disabledAudioEngineForLocalQA = true
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        #endif
#endif
        mediaCancellables.removeAll()
        self.managesAudioSession = managesAudioSession
        callHasVideo = video
        userSpeakerOverride = nil
        isSpeakerOn = CallAudioRoutePolicy.wantsSpeaker(
            video: video,
            userOverride: nil,
            hasExternalRoute: hasExternalAudioRoute
        )
        if !allowsLocalQADataBootstrap {
            #if canImport(LiveKit)
            AudioManager.shared.isSpeakerOutputPreferred = isSpeakerOn
            #endif
            startObservingInterruptions()
        }
        do {
            // CallKit owns activation/deactivation, but the app still owns the
            // category and mode used once CallKit activates the session. Without
            // this configuration an audio call can inherit a playback-only
            // category and publish no microphone on a real device.
            if !allowsLocalQADataBootstrap {
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
            }
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
                    Task { @MainActor in
                        if reconnecting { self?.isE2EEVerified = false }
                        self?.setReconnecting(reconnecting)
                        guard !reconnecting else { return }
                        // Une reconnexion rapide garde les chiffreurs du SDK, qui
                        // ne réannoncent « OK » qu'après une erreur : leurs états
                        // restent valables. Une complète met fin à l'appel chiffré.
                        self?.isE2EEVerified = e2eeSession?.verification.isVerified ?? false
                        self?.refreshRemoteMedia()
                        // Des paquets ont pu se perdre : notre preuve repart.
                        self?.broadcastJoinProofOnSchedule()
                    }
                },
                onFullReconnectStarted: { [weak self] in
                    // Une reconnexion complète réarme le marqueur SIF et réintègre
                    // les participants sans événement : un appel chiffré prend fin.
                    guard e2eeSession != nil else { return }
                    e2eeSession?.verification.failGlobally()
                    Task { @MainActor in self?.handleE2EETrustLoss(.reconnected) }
                },
                onRemoteTrackPublished: { [weak self] _, encryptionType in
                    // Une piste annoncée en clair met fin à un appel chiffré dès sa
                    // publication : elle n'est jamais abonnée.
                    guard E2EEV2CallMediaPolicy.accepts(
                        requiresE2EE: e2eeSession != nil, encryptionType: encryptionType
                    ) else {
                        e2eeSession?.verification.failGlobally()
                        Task { @MainActor in self?.handleE2EETrustLoss() }
                        return
                    }
                    Task { @MainActor in await self?.enforceRemoteTracks() }
                },
                onMediaChanged: { [weak self] in
                    Task { @MainActor in self?.refreshRemoteMedia() }
                },
                onParticipantExpected: { [weak self] participantID in
                    e2eeSession?.verification.expectParticipant(participantID)
                    e2eeSession?.joinVerifier?.expect(participantID, at: Date())
                    let verified = e2eeSession?.verification.isVerified ?? false
                    Task { @MainActor in
                        self?.isE2EEVerified = verified
                        guard e2eeSession?.joinVerifier != nil else { return }
                        self?.scheduleJoinProofDeadline()
                        // Le nouvel arrivant n'a pas reçu notre preuve de jonction.
                        self?.broadcastJoinProofOnSchedule()
                    }
                },
                onParticipantRemoved: { [weak self] participantID in
                    e2eeSession?.joinVerifier?.remove(participantID)
                    e2eeSession?.verification.removeParticipant(participantID)
                    let verified = e2eeSession?.verification.isVerified ?? false
                    Task { @MainActor in self?.isE2EEVerified = verified }
                },
                onCryptorExpected: { [weak self] participantID, trackID, encryptionType in
                    // Une piste publiée ou reçue en clair dans un appel chiffré
                    // y met fin : le micro ne part pas, rien n'est rendu.
                    guard E2EEV2CallMediaPolicy.accepts(
                        requiresE2EE: e2eeSession != nil, encryptionType: encryptionType
                    ) else {
                        e2eeSession?.verification.failGlobally()
                        Task { @MainActor in self?.handleE2EETrustLoss() }
                        return
                    }
                    e2eeSession?.verification.expect(participantID: participantID, trackID: trackID)
                    let verified = e2eeSession?.verification.isVerified ?? false
                    Task { @MainActor in self?.isE2EEVerified = verified }
                },
                onCryptorRemoved: { [weak self] participantID, trackID in
                    e2eeSession?.verification.remove(participantID: participantID, trackID: trackID)
                    let verified = e2eeSession?.verification.isVerified ?? false
                    Task { @MainActor in self?.isE2EEVerified = verified }
                },
                onCryptorState: { [weak self] trackID, state in
                    e2eeSession?.verification.update(trackID, state: state)
                    let verified = e2eeSession?.verification.isVerified ?? false
                    let terminal = E2EEV2CallCryptorPolicy.isTerminalFailure(state)
                    Task { @MainActor in
                        self?.isE2EEVerified = verified
                        if terminal { self?.handleE2EETrustLoss() }
                        // Une piste n'est montrée qu'une fois déchiffrée (« OK »).
                        self?.refreshRemoteMedia()
                    }
                },
                onCryptorGlobalFailure: { [weak self] in
                    e2eeSession?.verification.failGlobally()
                    Task { @MainActor in self?.handleE2EETrustLoss() }
                },
                onDataDecryptionFailure: { [weak self] in
                    Task { @MainActor in
                        self?.e2eeDataDecryptionFailureCount += 1
                        self?.isE2EEVerified = false
                    }
                },
                onDataReceived: { [weak self] senderIdentity, data, topic, encryptionType in
                    switch E2EEV2CallDataPolicy.verdict(
                        requiresE2EE: e2eeSession != nil,
                        senderIdentity: senderIdentity,
                        encryptionType: encryptionType
                    ) {
                    case .endCall:
                        e2eeSession?.verification.failGlobally()
                        Task { @MainActor in
                            self?.logger.error("Data packet refused: not encrypted")
                            self?.handleE2EETrustLoss()
                        }
                        return
                    case .ignore:
                        return
                    case .accept:
                        break
                    }
                    if let joinVerifier = e2eeSession?.joinVerifier {
                        // Appel prouvé (§10.4) : seule une preuve de jonction
                        // valide atteste un participant, et rien d'un
                        // participant non prouvé n'atteint l'app.
                        guard let senderIdentity else { return }
                        if topic == E2EEV2CallJoinProof.topic {
                            let outcome = joinVerifier.receive(data, from: senderIdentity)
                            guard outcome != .rejected else {
                                e2eeSession?.verification.failGlobally()
                                Task { @MainActor in
                                    self?.logger.error("Join proof rejected: the call ends")
                                    self?.handleE2EETrustLoss(.joinProof)
                                }
                                return
                            }
                            e2eeSession?.verification.markJoinProven(senderIdentity)
                            let verified = e2eeSession?.verification.isVerified ?? false
                            Task { @MainActor in
                                self?.isE2EEVerified = verified
                                self?.refreshRemoteMedia()
                                await self?.enforceRemoteTracks()
                                // Réponse à sa première preuve : notre preuve lui
                                // parvient même s'il n'était pas prêt à son arrivée.
                                if outcome == .proven { await self?.sendJoinProof(to: senderIdentity) }
                            }
                            return
                        }
                        guard joinVerifier.isProven(senderIdentity) else { return }
                    } else if let senderIdentity {
                        e2eeSession?.verification.markDataVerified(senderIdentity)
                    }
                    let verified = e2eeSession?.verification.isVerified ?? false
                    Task { @MainActor in
                        self?.isE2EEVerified = verified
                        self?.onDataReceived?(senderIdentity, data, topic)
                    }
                }
            )
            self.roomObserver = observer
            self.activeE2eeSession = e2eeSession
            let liveRoom = Room(
                delegate: observer,
                roomOptions: RoomOptions(
                    suspendLocalVideoTracksInBackground: CallBackgroundMediaPolicy.suspendLocalVideoTracks,
                    encryptionOptions: e2eeSession?.encryptionOptions
                )
            )
            // Appel prouvé : pas d'abonnement automatique, rien d'un participant
            // non prouvé n'est reçu (voir `enforceRemoteTracks`).
            try await liveRoom.connect(
                url: url.absoluteString, token: token,
                connectOptions: ConnectOptions(autoSubscribe: e2eeSession?.joinVerifier == nil)
            )
            e2eeSession?.neutralizeServerInjectedFrames()
            await enforceRemoteTracks(in: liveRoom)
            if didE2EEFailDuringConnect {
                await liveRoom.disconnect()
                state = .failed("La vérification du chiffrement média a échoué.")
                return
            }
            // Un raccrochage est survenu pendant le connect : fermer la room orpheline
            // au lieu de la marquer connectée (CALL-RTC-05).
            if myGeneration != connectGeneration {
                await liveRoom.disconnect()
                state = .ended
                return
            }
            let media: LocalMedia?
            switch mediaSetupMode {
            case .standard:
                let standardMedia = LocalMedia(room: liveRoom)
                // Pas de nouvelle piste après un échec du chiffrement.
                if let e2eeSession {
                    if !didE2EEFailDuringConnect {
                        await setEncryptedLocalTrack(.microphone, enabled: true, in: liveRoom, session: e2eeSession, media: standardMedia)
                    }
                    if video, !didE2EEFailDuringConnect {
                        await setEncryptedLocalTrack(.camera, enabled: true, in: liveRoom, session: e2eeSession, media: standardMedia)
                    }
                } else {
                    if !standardMedia.isMicrophoneEnabled, !didE2EEFailDuringConnect {
                        await standardMedia.toggleMicrophone()
                    }
                    if video && !standardMedia.isCameraEnabled, !didE2EEFailDuringConnect {
                        await standardMedia.toggleCamera()
                    }
                }
                media = standardMedia
            #if DEBUG
            case .localQADataOnly:
                media = nil
            #endif
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
            if let localIdentity = liveRoom.localParticipant.identity?.stringValue {
                e2eeSession?.verification.expectParticipant(localIdentity)
            } else if e2eeSession != nil {
                e2eeSession?.verification.failGlobally()
            }
            let joinedAt = Date()
            liveRoom.remoteParticipants.values.forEach { participant in
                if let identity = participant.identity?.stringValue {
                    e2eeSession?.verification.expectParticipant(identity)
                    e2eeSession?.joinVerifier?.expect(identity, at: joinedAt)
                } else if e2eeSession != nil {
                    e2eeSession?.verification.failGlobally()
                }
            }
            localJoinedAtMs = Int64(joinedAt.timeIntervalSince1970 * 1_000)
            if e2eeSession?.joinVerifier != nil { scheduleJoinProofDeadline() }
            isE2EEVerified = e2eeSession?.verification.isVerified ?? false
            // CALL-RTC-09 : isMicMuted / isCameraOn dérivent de l'état RÉEL du SDK
            // (et non d'un toggle optimiste) → l'UI et CallKit restent honnêtes même
            // si une bascule de track échoue.
            if let media {
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
                media.$error
                    .receive(on: DispatchQueue.main)
                    .compactMap { $0?.localizedDescription }
                    .sink { [weak self] message in self?.mediaErrorMessage = message }
                    .store(in: &mediaCancellables)
            } else {
                isMicMuted = false
                isCameraOn = video
                localVideoTrack = liveRoom.localParticipant.firstCameraVideoTrack
            }
            refreshRemoteMedia()
            if didE2EEFailDuringConnect {
                await liveRoom.disconnect()
                state = .failed("La vérification du chiffrement média a échoué.")
                return
            }
            state = .connected
            // Notre preuve de jonction part dès que l'appel est établi (§10.4).
            if e2eeSession?.joinVerifier != nil {
                broadcastJoinProofOnSchedule()
            }
#else
            throw LiveKitUnavailableError()
#endif
        } catch {
            activeE2eeSession?.verification.reset()
            activeE2eeSession?.joinVerifier?.reset()
            activeE2eeSession = nil
            isE2EEVerified = false
            restoreLocalQAAudioEngineIfNeeded()
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
        #if DEBUG && canImport(LiveKit)
        debugFeeders.forEach { $0.cancel() }
        debugFeeders.removeAll()
        #endif
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
        activeE2eeSession?.verification.reset()
        activeE2eeSession?.joinVerifier?.reset()
        activeE2eeSession = nil
        localJoinedAtMs = 0
        remoteVideos = []
        remoteAudios = []
        localVideoTrack = nil
        allowsLocalQADataBootstrap = false
#endif
        restoreLocalQAAudioEngineIfNeeded()
        if managesAudioSession {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        state = .ended
        isReconnecting = false
        remoteJoinedAt = nil
        isMicMuted = false
        isCameraOn = false
        canSwitchCamera = false
        canStartPictureInPicture = false
        isPictureInPictureActive = false
        isE2EEVerified = false
        didE2EEFailDuringConnect = false
        callHasVideo = false
        userSpeakerOverride = nil
#if canImport(LiveKit)
        AudioManager.shared.isSpeakerOutputPreferred = false
        if !managesAudioSession {
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        }
#endif
    }

    private func restoreLocalQAAudioEngineIfNeeded() {
        #if DEBUG && canImport(LiveKit)
        guard disabledAudioEngineForLocalQA else { return }
        try? AudioManager.shared.setEngineAvailability(.default)
        disabledAudioEngineForLocalQA = false
        #endif
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

    #if canImport(LiveKit)
    /// Appel chiffré (§10.4) : une piste distante annoncée en clair met fin à
    /// l'appel, même déjà présente à la jonction. Appel prouvé : on ne s'abonne
    /// aux pistes d'un participant qu'une fois sa preuve de jonction vérifiée ;
    /// sans abonnement, WebRTC ne joue rien d'un participant non prouvé.
    private func enforceRemoteTracks(in room: Room) async {
        guard let session = activeE2eeSession else { return }
        let publications = room.remoteParticipants.values.flatMap { participant in
            participant.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }.map { (participant, $0) }
        }
        guard publications.allSatisfy({ $0.1.encryptionType == .gcm }) else {
            session.verification.failGlobally()
            handleE2EETrustLoss()
            return
        }
        guard let joinVerifier = session.joinVerifier else { return }
        for (participant, remote) in publications where !remote.isSubscribed {
            guard let identity = participant.identity?.stringValue, joinVerifier.isProven(identity) else { continue }
            try? await remote.set(subscribed: true)
        }
    }

    private func enforceRemoteTracks() async {
        guard let room else { return }
        await enforceRemoteTracks(in: room)
    }

    /// Micro ou caméra d'un appel chiffré : jamais par `LocalMedia`, qui
    /// publierait ou réactiverait la piste sans attendre son chiffreur (§10.4).
    private func setEncryptedLocalTrack(
        _ source: Track.Source,
        enabled: Bool,
        in room: Room,
        session: E2EEV2LiveKitSession,
        media: LocalMedia?
    ) async {
        guard encryptedSourcesInFlight.insert(source).inserted else { return }
        defer { encryptedSourcesInFlight.remove(source) }
        do {
            let existing = room.localParticipant.trackPublications.values
                .first { $0.source == source } as? LocalTrackPublication
            if !enabled {
                try await existing?.mute()
            } else if let existing {
                try await unmuteWhenEncrypting(existing, session: session)
            } else if source == .camera {
                // Même appareil que `LocalMedia.toggleCamera()`.
                let device = try await CameraCapturer.captureDevices().first { $0.uniqueID == media?.selectedVideoDeviceID }
                let track = await LocalVideoTrack.createCameraTrack(options: CameraCaptureOptions(device: device))
                try await publishEncrypted(track, in: room, session: session)
            } else {
                let track = await LocalAudioTrack.createTrack()
                try await publishEncrypted(track, in: room, session: session)
            }
        } catch {
            mediaErrorMessage = LocalMedia.Error.mediaDevice(error).localizedDescription
        }
    }

    /// Le SDK lance la capture et la négociation avant d'attacher le chiffreur,
    /// qui n'arrive qu'après la réponse du serveur à la publication : la piste
    /// est donc publiée muette (silence ou image noire, sans contenu).
    private func publishEncrypted(_ track: LocalTrack, in room: Room, session: E2EEV2LiveKitSession) async throws {
        try await track.mute()
        let publication: LocalTrackPublication
        if let video = track as? LocalVideoTrack {
            publication = try await room.localParticipant.publish(videoTrack: video)
        } else if let audio = track as? LocalAudioTrack {
            publication = try await room.localParticipant.publish(audioTrack: audio)
        } else {
            throw LiveKitError(.invalidState, message: "Piste locale inconnue")
        }
        #if DEBUG
        if publication.isMuted { debugLocalTrackEvents.append(.publishedMuted) }
        #endif
        try await unmuteWhenEncrypting(publication, session: session)
    }

    /// Réactive une piste locale une fois publiée en GCM et son chiffreur à
    /// « OK ». Sinon elle reste muette et l'appel prend fin.
    private func unmuteWhenEncrypting(_ publication: LocalTrackPublication, session: E2EEV2LiveKitSession) async throws {
        let deadline = ContinuousClock.now + Self.localCryptorTimeout
        while true {
            guard state == .connecting || state == .connected, !didE2EEFailDuringConnect else { return }
            let cryptorState = session.verification.state(of: publication.sid.stringValue)
            if E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: publication.encryptionType, cryptorState: cryptorState) {
                break
            }
            let failed = cryptorState.map(E2EEV2CallCryptorPolicy.isTerminalFailure) ?? false
            guard publication.encryptionType == .gcm, !failed, ContinuousClock.now < deadline else {
                session.verification.failGlobally()
                handleE2EETrustLoss()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #if DEBUG
        debugLocalTrackEvents.append(.cryptorOK)
        #endif
        try await publication.unmute()
        #if DEBUG
        debugLocalTrackEvents.append(.unmuted)
        #endif
    }

    /// Délai pour qu'une piste publiée muette soit chiffrée : silence et image
    /// noire passent par le chiffreur dès qu'il est attaché.
    private static let localCryptorTimeout: Duration = .seconds(10)
    #endif

    #if DEBUG && canImport(LiveKit)
    /// Banc local : provoque une reconnexion que le SDK sait simuler.
    func debugSimulate(_ scenario: SimulateScenario) async throws {
        try await room?.debug_simulate(scenario: scenario)
    }

    /// Banc local : publie une piste vidéo d'images synthétiques, alimentée
    /// tant que l'appel dure (le SDK attend une première image pour publier).
    func debugPublishSyntheticVideo(frame: CVPixelBuffer) async throws {
        guard let room else { throw LiveKitError(.invalidState, message: "room absente") }
        let track = await LocalVideoTrack.createBufferTrack(name: "sq-test-video", source: .camera)
        guard let capturer = track.capturer as? BufferCapturer else {
            throw LiveKitError(.invalidState, message: "capteur absent")
        }
        let feeder = Task { [weak room] in
            while !Task.isCancelled, room?.connectionState != .disconnected {
                capturer.capture(frame)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        debugFeeders.append(feeder)
        if let session = activeE2eeSession {
            try await publishEncrypted(track, in: room, session: session)
        } else {
            _ = try await room.localParticipant.publish(videoTrack: track)
        }
    }

    /// Banc local : pour chaque participant distant, s'il a une piste abonnée.
    func debugRemoteSubscriptions() -> [String: Bool] {
        guard let room else { return [:] }
        var result: [String: Bool] = [:]
        for participant in room.remoteParticipants.values {
            guard let identity = participant.identity?.stringValue else { continue }
            result[identity] = participant.trackPublications.values.contains { $0.isSubscribed }
        }
        return result
    }

    /// Banc local : participants distants ayant publié au moins une piste.
    func debugRemotePublishers() -> Set<String> {
        guard let room else { return [] }
        return Set(room.remoteParticipants.values.compactMap { participant in
            participant.trackPublications.isEmpty ? nil : participant.identity?.stringValue
        })
    }
    #endif

    private func handleE2EETrustLoss(_ reason: E2EEV2CallTrustLoss = .verification) {
#if canImport(LiveKit)
        guard activeE2eeSession != nil else { return }
        isE2EEVerified = false
        mediaErrorMessage = "La vérification du chiffrement média a échoué."
        switch state {
        case .connecting:
            didE2EEFailDuringConnect = true
        case .connected:
            #if DEBUG
            // The explicit loopback interop fixture must remain connected long
            // enough to report its deliberate wrong-key probe. Production calls
            // always install CallManager's trust-loss closure and fail closed.
            if allowsLocalQADataBootstrap, onE2EETrustLost == nil { break }
            #endif
            state = .ended
            // Le média s'arrête tout de suite, avant toute réponse du serveur.
            let room = self.room
            Task { await room?.disconnect() }
            onE2EETrustLost?(reason)
        default:
            break
        }
#endif
    }

    /// Envoie notre preuve de jonction sur le canal de données chiffré, à tous
    /// ou au seul `destination` (§10.4). Sans canal chiffré, ou si l'envoi
    /// échoue, l'appel prend fin : les autres le couperaient sous 10 secondes.
    private func sendJoinProof(to destination: String? = nil) async {
#if canImport(LiveKit)
        guard state == .connected, let room, let session = activeE2eeSession,
              let joinVerifier = session.joinVerifier else { return }
        guard room.e2eeManager?.dataChannelEncryptionType == .gcm,
              let identity = room.localParticipant.identity?.stringValue else {
            logger.error("Join proof not sent: data channel not encrypted")
            session.verification.failGlobally()
            handleE2EETrustLoss(.joinProof)
            return
        }
        do {
            let message = try joinVerifier.localProof(livekitIdentity: identity, joinedAtMs: localJoinedAtMs)
            try await room.localParticipant.publish(
                data: message,
                options: DataPublishOptions(
                    destinationIdentities: destination.map { [Participant.Identity(from: $0)] } ?? [],
                    topic: E2EEV2CallJoinProof.topic,
                    reliable: true
                )
            )
            session.verification.markJoinProven(identity)
            isE2EEVerified = session.verification.isVerified
        } catch {
            logger.error("Join proof not sent: \(String(describing: error), privacy: .public)")
            guard state == .connected else { return }
            session.verification.failGlobally()
            handleE2EETrustLoss(.joinProof)
        }
#endif
    }

    /// Diffuse notre preuve tout de suite, puis 1, 2, 4 et 7 secondes plus tard
    /// (§10.4) : le serveur perd un paquet envoyé avant d'avoir annoncé un
    /// participant, ce qui prend jusqu'à environ 3 secondes. Les doublons sont
    /// sans effet chez les autres.
    private func broadcastJoinProofOnSchedule() {
        let generation = connectGeneration
        Task { [weak self] in
            await self?.sendJoinProof()
            for pause in [1, 1, 2, 3] {
                try? await Task.sleep(for: .seconds(pause))
                guard let self, generation == self.connectGeneration else { return }
                await self.sendJoinProof()
            }
        }
    }

    /// Contrôle, 10 secondes après une arrivée, que chacun a prouvé son appareil.
    private func scheduleJoinProofDeadline() {
        let generation = connectGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(E2EEV2CallJoinVerifier.deadline) + .milliseconds(250))
            self?.enforceJoinProofDeadline(generation: generation)
        }
    }

    private func enforceJoinProofDeadline(generation: Int) {
#if canImport(LiveKit)
        guard generation == connectGeneration, let session = activeE2eeSession,
              let joinVerifier = session.joinVerifier,
              !joinVerifier.overdue(at: Date()).isEmpty else { return }
        session.verification.failGlobally()
        handleE2EETrustLoss(.joinProof)
#endif
    }

    // MARK: Interruptions audio

    private func startObservingInterruptions() {
        if interruptionObserver == nil {
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
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applySpeakerOutput() }
            }
        }
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
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
        // A user/CallKit mute choice supersedes automatic interruption recovery.
        micAutoMutedByInterruption = false
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
            if let room, let session = activeE2eeSession, let localMedia {
                await setEncryptedLocalTrack(
                    .microphone, enabled: !localMedia.isMicrophoneEnabled, in: room, session: session, media: localMedia
                )
                return
            }
            await localMedia?.toggleMicrophone()
#endif
        }
    }

    func toggleCamera() {
        Task {
#if canImport(LiveKit)
            if let room, let session = activeE2eeSession, let localMedia {
                await setEncryptedLocalTrack(
                    .camera, enabled: !localMedia.isCameraEnabled, in: room, session: session, media: localMedia
                )
                return
            }
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
        // Appel chiffré : le partage d'écran ne suit pas la publication muette (§10.4).
        guard activeE2eeSession == nil else { throw MediaControlError.screenSharingDisabled }
        await localMedia?.toggleScreenShare(disableCamera: false)
#endif
    }

    func publishData(_ data: Data, topic: String, reliable: Bool = true) async throws {
        guard !data.isEmpty, data.count <= 15_000,
              !topic.isEmpty, topic.count <= 160 else {
            throw DataChannelError.invalidPayload
        }
#if canImport(LiveKit)
        guard state == .connected, let room else { throw DataChannelError.notConnected }
        let verifiedForPublish = E2EEV2CallDataPolicy.canPublish(
            requiresE2EE: activeE2eeSession != nil,
            cryptorsVerified: isE2EEVerified
        )
        let localQABootstrap = allowsLocalQADataBootstrap && topic == "sq_e2ee_call_qa"
        guard verifiedForPublish || localQABootstrap else {
            throw DataChannelError.e2eeNotVerified
        }
        try await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: topic, reliable: reliable)
        )
        if localQABootstrap,
           let localIdentity = room.localParticipant.identity?.stringValue {
            activeE2eeSession?.verification.markDataVerified(localIdentity)
            isE2EEVerified = activeE2eeSession?.verification.isVerified ?? false
        }
#else
        throw LiveKitUnavailableError()
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
        userSpeakerOverride = enabled
        applySpeakerOutput()
    }

    private func applySpeakerOutput() {
        let desiredSpeaker = CallAudioRoutePolicy.wantsSpeaker(
            video: callHasVideo,
            userOverride: userSpeakerOverride,
            hasExternalRoute: hasExternalAudioRoute
        )
#if canImport(LiveKit)
        AudioManager.shared.isSpeakerOutputPreferred = desiredSpeaker
#endif
        do {
            let currentlyOnSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            if currentlyOnSpeaker != desiredSpeaker {
                try session.overrideOutputAudioPort(desiredSpeaker ? .speaker : .none)
            }
            isSpeakerOn = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        } catch {
            mediaErrorMessage = "Sortie audio indisponible : \(error.userFacingMessage)"
            logger.error("Speaker route failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var hasExternalAudioRoute: Bool {
        let ports = session.currentRoute.outputs.map(\.portType) +
            (session.availableInputs ?? []).map(\.portType)
        return ports.contains { port in
            switch port {
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE,
                 .headphones, .headsetMic, .usbAudio, .carAudio, .airPlay:
                return true
            default:
                return false
            }
        }
    }

#if canImport(LiveKit)
    private var pictureInPictureTrack: (any VideoTrack)? {
        remoteVideos.first(where: { !$0.isScreenShare })?.track
            ?? remoteVideos.first?.track
            ?? localVideoTrack
    }

    private func displayName(of participant: RemoteParticipant) -> String {
        guard let joinVerifier = activeE2eeSession?.joinVerifier else { return participant.name ?? "Participant" }
        let userId = participant.identity.flatMap { joinVerifier.provenUserId($0.stringValue) }
        return userId.flatMap { participantName?($0) } ?? "Participant"
    }

    private func refreshRemoteMedia() {
        guard let room else {
            remoteVideos = []
            remoteAudios = []
            refreshPictureInPictureTrack()
            return
        }
        // Appel chiffré : une piste n'est montrée qu'une fois déchiffrée avec la
        // clé de l'appel (spec §10.4) ; avant, elle n'existe pas pour l'interface.
        let verification = activeE2eeSession?.verification
        func shown(_ publication: TrackPublication?) -> Bool {
            guard let verification else { return true }
            guard let publication else { return false }
            return verification.isTrackVerified(publication.sid.stringValue)
        }
        remoteAudios = room.remoteParticipants.values.flatMap { participant -> [RemoteAudio] in
            let participantID = participant.identity?.stringValue
                ?? participant.sid?.stringValue
                ?? "participant"
            return participant.audioTracks.compactMap { publication in
                guard shown(publication), let track = publication.track as? any AudioTrack else { return nil }
                return RemoteAudio(
                    id: "\(participantID):\(publication.sid.stringValue)",
                    participantID: participantID,
                    track: track
                )
            }
        }
        let tracks = room.remoteParticipants.values
            .sorted { ($0.name ?? $0.identity?.stringValue ?? "") < ($1.name ?? $1.identity?.stringValue ?? "") }
            .flatMap { participant -> [RemoteVideo] in
                let participantID = participant.identity?.stringValue
                    ?? participant.sid?.stringValue
                    ?? "participant"
                let displayName = displayName(of: participant)
                var videos: [RemoteVideo] = []
                if SQFeatures.callScreenSharingEnabled,
                   shown(participant.firstScreenSharePublication),
                   let track = participant.firstScreenShareVideoTrack {
                    videos.append(RemoteVideo(
                        id: "\(participantID):screen",
                        participantID: participantID,
                        displayName: displayName,
                        track: track,
                        isScreenShare: true
                    ))
                }
                if shown(participant.firstCameraPublication), let track = participant.firstCameraVideoTrack {
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
            if remoteJoinedAt == nil { remoteJoinedAt = Date() }
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
    private let onFullReconnectStarted: @Sendable () -> Void
    private let onRemoteTrackPublished: @Sendable (String?, EncryptionType) -> Void
    private let onMediaChanged: @Sendable () -> Void
    private let onParticipantExpected: @Sendable (String) -> Void
    private let onParticipantRemoved: @Sendable (String) -> Void
    private let onCryptorExpected: @Sendable (String, String, EncryptionType) -> Void
    private let onCryptorRemoved: @Sendable (String, String) -> Void
    private let onCryptorState: @Sendable (String, E2EEState) -> Void
    private let onCryptorGlobalFailure: @Sendable () -> Void
    private let onDataDecryptionFailure: @Sendable () -> Void
    private let onDataReceived: @Sendable (String?, Data, String, EncryptionType) -> Void

    init(
        onDisconnect: @escaping @Sendable () -> Void,
        onReconnectingChanged: @escaping @Sendable (Bool) -> Void,
        onFullReconnectStarted: @escaping @Sendable () -> Void,
        onRemoteTrackPublished: @escaping @Sendable (String?, EncryptionType) -> Void,
        onMediaChanged: @escaping @Sendable () -> Void,
        onParticipantExpected: @escaping @Sendable (String) -> Void,
        onParticipantRemoved: @escaping @Sendable (String) -> Void,
        onCryptorExpected: @escaping @Sendable (String, String, EncryptionType) -> Void,
        onCryptorRemoved: @escaping @Sendable (String, String) -> Void,
        onCryptorState: @escaping @Sendable (String, E2EEState) -> Void,
        onCryptorGlobalFailure: @escaping @Sendable () -> Void,
        onDataDecryptionFailure: @escaping @Sendable () -> Void,
        onDataReceived: @escaping @Sendable (String?, Data, String, EncryptionType) -> Void
    ) {
        self.onDisconnect = onDisconnect
        self.onReconnectingChanged = onReconnectingChanged
        self.onFullReconnectStarted = onFullReconnectStarted
        self.onRemoteTrackPublished = onRemoteTrackPublished
        self.onMediaChanged = onMediaChanged
        self.onParticipantExpected = onParticipantExpected
        self.onParticipantRemoved = onParticipantRemoved
        self.onCryptorExpected = onCryptorExpected
        self.onCryptorRemoved = onCryptorRemoved
        self.onCryptorState = onCryptorState
        self.onCryptorGlobalFailure = onCryptorGlobalFailure
        self.onDataDecryptionFailure = onDataDecryptionFailure
        self.onDataReceived = onDataReceived
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
    // Une reconnexion peut commencer rapide puis passer en complète : seul
    // `didUpdateReconnectMode` l'annonce alors. La fin d'une reconnexion
    // complète sert de filet de sécurité.
    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        onReconnectingChanged(true)
        if reconnectMode == .full { onFullReconnectStarted() }
    }
    func room(_ room: Room, didUpdateReconnectMode reconnectMode: ReconnectMode) {
        if reconnectMode == .full { onFullReconnectStarted() }
    }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        onReconnectingChanged(false)
        if reconnectMode == .full { onFullReconnectStarted() }
    }
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        if let identity = participant.identity?.stringValue { onParticipantExpected(identity) }
        else { onCryptorGlobalFailure() }
        onMediaChanged()
    }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        if let identity = participant.identity?.stringValue { onParticipantRemoved(identity) }
        else { onCryptorGlobalFailure() }
        onMediaChanged()
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let identity = participant.identity?.stringValue else {
            onCryptorGlobalFailure()
            return
        }
        onCryptorExpected(identity, publication.sid.stringValue, publication.encryptionType)
        onMediaChanged()
    }
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard let identity = participant.identity?.stringValue else {
            onCryptorGlobalFailure()
            return
        }
        onCryptorRemoved(identity, publication.sid.stringValue)
        onMediaChanged()
    }
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        onRemoteTrackPublished(participant.identity?.stringValue, publication.encryptionType)
        onMediaChanged()
    }
    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let identity = participant.identity?.stringValue else {
            onCryptorGlobalFailure()
            return
        }
        onCryptorExpected(identity, publication.sid.stringValue, publication.encryptionType)
    }
    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard let identity = participant.identity?.stringValue else {
            onCryptorGlobalFailure()
            return
        }
        onCryptorRemoved(identity, publication.sid.stringValue)
    }
    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        onCryptorState(trackPublication.sid.stringValue, state)
    }
    func room(_ room: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        onDataDecryptionFailure()
        onCryptorGlobalFailure()
    }
    func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        onDataReceived(participant?.identity?.stringValue, data, topic, encryptionType)
    }
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { onMediaChanged() }
}

enum E2EEV2CallDataPolicy {
    enum Verdict: Equatable {
        case accept
        /// Émetteur pas encore annoncé par le serveur : rien n'est conclu.
        case ignore
        case endCall
    }

    static func canPublish(requiresE2EE: Bool, cryptorsVerified: Bool) -> Bool {
        !requiresE2EE || cryptorsVerified
    }

    /// Un paquet en clair dans un appel chiffré y met fin. Un paquet chiffré
    /// peut arriver avant que le serveur annonce son émetteur (jusqu'à environ
    /// 3 secondes après sa jonction) : il est ignoré, sans couper l'appel.
    static func verdict(
        requiresE2EE: Bool,
        senderIdentity: String?,
        encryptionType: EncryptionType
    ) -> Verdict {
        guard requiresE2EE else { return .accept }
        guard encryptionType == .gcm else { return .endCall }
        guard senderIdentity?.isEmpty == false else { return .ignore }
        return .accept
    }
}

enum E2EEV2CallCryptorPolicy {
    /// Seul « OK » prouve un déchiffrement avec la clé de l'appel. Personne ne
    /// fait de ratchet (fenêtre à 0, `ratchetKey` interdit, spec §10.3) :
    /// « key_ratcheted » signale une clé qui a bougé, donc un échec.
    static func isVerified(_ state: E2EEState) -> Bool {
        state == .ok
    }

    static func isTerminalFailure(_ state: E2EEState) -> Bool {
        switch state {
        case .missing_key, .encryption_failed, .decryption_failed, .internal_error, .key_ratcheted:
            return true
        case .new, .ok:
            return false
        @unknown default:
            return true
        }
    }
}

enum E2EEV2CallMediaPolicy {
    /// Dans un appel chiffré, une piste n'existe que chiffrée en GCM, publiée
    /// comme reçue (spec §10.4) : toute autre met fin à l'appel.
    static func accepts(requiresE2EE: Bool, encryptionType: EncryptionType) -> Bool {
        !requiresE2EE || encryptionType == .gcm
    }
}

enum E2EEV2CallLocalTrackPolicy {
    /// Une piste locale d'un appel chiffré, publiée muette, n'est réactivée
    /// qu'une fois publiée en GCM et son chiffreur à « OK » (§10.4) : avant,
    /// rien ne prouve qu'il est attaché.
    static func mayUnmute(encryptionType: EncryptionType, cryptorState: E2EEState?) -> Bool {
        encryptionType == .gcm && cryptorState.map(E2EEV2CallCryptorPolicy.isVerified) == true
    }
}

final class E2EEV2LiveKitVerification: @unchecked Sendable {
    /// Appel prouvé (§10.4) : chaque participant, nous compris, doit avoir
    /// prouvé son appareil par une preuve de jonction.
    let requiresJoinProof: Bool

    private let lock = NSLock()
    private var expectedParticipants = Set<String>()
    private var trackOwners: [String: String] = [:]
    private var states: [String: E2EEState] = [:]
    private var dataVerifiedParticipants = Set<String>()
    /// Gardées à la reconnexion : l'appareil d'une identité ne change pas.
    private var provenParticipants = Set<String>()
    private var globalFailure = false

    init(requiresJoinProof: Bool = false) {
        self.requiresJoinProof = requiresJoinProof
    }

    func expectParticipant(_ participantID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard validIdentifier(participantID) else {
            globalFailure = true
            return
        }
        expectedParticipants.insert(participantID)
    }

    func removeParticipant(_ participantID: String) {
        lock.lock()
        defer { lock.unlock() }
        expectedParticipants.remove(participantID)
        dataVerifiedParticipants.remove(participantID)
        provenParticipants.remove(participantID)
        let removedTracks = trackOwners.compactMap { trackID, owner in
            owner == participantID ? trackID : nil
        }
        removedTracks.forEach {
            trackOwners.removeValue(forKey: $0)
            states.removeValue(forKey: $0)
        }
    }

    func expect(participantID: String, trackID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard validIdentifier(participantID), validIdentifier(trackID) else {
            globalFailure = true
            return
        }
        expectedParticipants.insert(participantID)
        if let existingOwner = trackOwners[trackID], existingOwner != participantID {
            globalFailure = true
            return
        }
        trackOwners[trackID] = participantID
        if states[trackID] == nil { states[trackID] = .new }
    }

    func update(_ trackID: String, state: E2EEState) {
        lock.lock()
        defer { lock.unlock() }
        guard validIdentifier(trackID), trackOwners[trackID] != nil else {
            globalFailure = true
            return
        }
        states[trackID] = state
    }

    func remove(participantID: String, trackID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard trackOwners[trackID] == participantID else {
            globalFailure = true
            return
        }
        trackOwners.removeValue(forKey: trackID)
        states.removeValue(forKey: trackID)
    }

    func markDataVerified(_ participantID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard validIdentifier(participantID) else {
            globalFailure = true
            return
        }
        expectedParticipants.insert(participantID)
        dataVerifiedParticipants.insert(participantID)
    }

    /// Preuve de jonction valide de ce participant, ou envoi de la nôtre.
    func markJoinProven(_ participantID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard validIdentifier(participantID) else {
            globalFailure = true
            return
        }
        expectedParticipants.insert(participantID)
        provenParticipants.insert(participantID)
    }

    func failGlobally() {
        lock.lock()
        defer { lock.unlock() }
        globalFailure = true
    }

    /// Dernier état connu du chiffreur d'une piste, la nôtre comprise.
    func state(of trackID: String) -> E2EEState? {
        lock.lock()
        defer { lock.unlock() }
        return globalFailure ? nil : states[trackID]
    }

    /// Piste déchiffrée avec la clé de l'appel, d'un participant prouvé quand
    /// l'appel l'exige : la seule qu'on montre.
    func isTrackVerified(_ trackID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !globalFailure, let state = states[trackID] else { return false }
        if requiresJoinProof {
            guard let owner = trackOwners[trackID], provenParticipants.contains(owner) else { return false }
        }
        return E2EEV2CallCryptorPolicy.isVerified(state)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        expectedParticipants.removeAll()
        trackOwners.removeAll()
        states.removeAll()
        dataVerifiedParticipants.removeAll()
        provenParticipants.removeAll()
        globalFailure = false
    }

    var isVerified: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !globalFailure, expectedParticipants.count >= 2 else { return false }
        return expectedParticipants.allSatisfy { participantID in
            if requiresJoinProof, !provenParticipants.contains(participantID) { return false }
            let participantTracks = trackOwners.compactMap { trackID, owner in
                owner == participantID ? trackID : nil
            }
            if participantTracks.isEmpty {
                return requiresJoinProof || dataVerifiedParticipants.contains(participantID)
            }
            return participantTracks.allSatisfy { trackID in
                guard let state = states[trackID] else { return false }
                return E2EEV2CallCryptorPolicy.isVerified(state)
            }
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160
    }
}

struct E2EEV2LiveKitSession {
    let encryptionOptions: EncryptionOptions
    let keyProvider: BaseKeyProvider
    /// Preuves de jonction (§10.4) ; nil pour le contrat d'appel v1 et le banc QA.
    let joinVerifier: E2EEV2CallJoinVerifier?
    fileprivate let verification: E2EEV2LiveKitVerification

    init(
        encryptionOptions: EncryptionOptions,
        keyProvider: BaseKeyProvider,
        joinVerifier: E2EEV2CallJoinVerifier? = nil
    ) {
        self.encryptionOptions = encryptionOptions
        self.keyProvider = keyProvider
        self.joinVerifier = joinVerifier
        verification = E2EEV2LiveKitVerification(requiresJoinProof: joinVerifier != nil)
    }

    /// Réglages figés par la spec (§10.3), posés un par un sur les trois SDK :
    /// leurs défauts diffèrent. Pas de fenêtre de ratchet (une clé par appel),
    /// et aucune trame lue ni envoyée avant que la clé soit posée.
    static let keyProviderOptions = KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: Data("LKFrameEncryptionKey".utf8),
        ratchetWindowSize: 0,
        uncryptedMagicBytes: Data("LK-ROCKS".utf8),
        failureTolerance: failureTolerance,
        keyRingSize: 16,
        discardFrameWhenCryptorNotReady: true,
        keyDerivationAlgorithm: .pbkdf2
    )

    /// Échecs de déchiffrement consécutifs tolérés avant l'état d'échec ; même
    /// valeur sur les trois plateformes (COM-1).
    static let failureTolerance: Int32 = 10

    static func make(
        epochKey: Data,
        context: E2EEV2CallFrameKeyContext,
        join: E2EEV2CallJoinConfiguration? = nil
    ) throws -> E2EEV2LiveKitSession {
        var frameKey = try E2EEV2CallFrameKey.derive(epochKey: epochKey, context: context)
        defer { frameKey.resetBytes(in: 0..<frameKey.count) }
        let passphrase = try E2EEV2CallFrameKey.liveKitSharedPassphrase(frameKey: frameKey)
        return session(passphrase: passphrase, join: join)
    }

    /// Clé de trame v2 (§10.2) : dérivée de la clé de l'époque que le
    /// descripteur signé désigne, et de son `callNonce`.
    static func make(
        epochKey: Data,
        descriptor: E2EEV2CallDescriptor,
        join: E2EEV2CallJoinConfiguration?
    ) throws -> E2EEV2LiveKitSession {
        guard try E2EEV2EpochCrypto.keyCommitment(epochKey) == descriptor.keyCommitmentB64 else {
            throw E2EEV2CallFormatError.invalidField
        }
        var frameKey = try E2EEV2CallFrameKeyV2.derive(
            epochKey: epochKey,
            conversationId: descriptor.conversationId,
            epochNumber: descriptor.epochNumber,
            callId: descriptor.callId,
            callNonceB64: descriptor.callNonceB64
        )
        defer { frameKey.resetBytes(in: 0..<frameKey.count) }
        return session(passphrase: E2EEV2CallFrameKeyV2.livekitPassphrase(frameKey), join: join)
    }

    private static func session(passphrase: String, join: E2EEV2CallJoinConfiguration?) -> E2EEV2LiveKitSession {
        let keyProvider = BaseKeyProvider(options: keyProviderOptions)
        keyProvider.setKey(key: passphrase, index: 0)
        return E2EEV2LiveKitSession(
            encryptionOptions: EncryptionOptions(keyProvider: keyProvider, encryptionType: .gcm),
            keyProvider: keyProvider,
            joinVerifier: join.map(E2EEV2CallJoinVerifier.init(configuration:))
        )
    }

    /// Le SDK pose le marqueur SIF envoyé par le serveur à la jonction : une
    /// trame qui le porte passerait sans déchiffrement. Il est remplacé aussitôt
    /// par 32 octets aléatoires, inconnus du serveur : un marqueur vide n'est pas
    /// pris en compte par tous les SDK (le SDK JS l'ignore).
    func neutralizeServerInjectedFrames() {
        keyProvider.setSifTrailer(trailer: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }
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
        controller?.delegate = nil
        controller = nil
        possibilityObservation = nil
        sourceView = nil
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
