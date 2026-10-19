import AVFoundation
import Foundation

/// Session audio empruntée le temps d'une note vocale (lecture ou
/// enregistrement) : `begin` garde la configuration d'avant, `end` la rétablit
/// et désactive la session que la note avait activée. Pendant un appel, la
/// session appartient à CallKit/LiveKit : la note n'y touche ni au début ni à
/// la fin.
@MainActor
struct VoiceNoteAudioSession {
    private let category: AVAudioSession.Category
    private let mode: AVAudioSession.Mode
    private let options: AVAudioSession.CategoryOptions

    static func begin(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions = []
    ) throws -> VoiceNoteAudioSession {
        let session = AVAudioSession.sharedInstance()
        let previous = VoiceNoteAudioSession(category: session.category, mode: session.mode, options: session.categoryOptions)
        do {
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(true)
        } catch {
            previous.restoreCategory()
            throw error
        }
        return previous
    }

    func end() {
        guard !CallManager.isCallInProgress else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        restoreCategory()
    }

    private func restoreCategory() {
        try? AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
    }
}

/// Lecteur de note vocale.
///
/// iOS AFFICHAIT déjà les transcriptions sans savoir lire l'audio : on recevait
/// une note vocale et on n'en avait que le texte. Ce lecteur comble ce trou.
///
/// Instance UNIQUE partagée par toutes les bulles : deux notes qui jouent en
/// même temps est le défaut le plus courant d'une messagerie, et il ne se voit
/// qu'à l'usage.
@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject {
    static let shared = VoiceNotePlayer()

    /// Une note de la conversation affichée, dans l'ordre du fil : de quoi enchaîner
    /// la suivante sans que l'utilisateur ait à la toucher.
    struct SequenceItem: Equatable, Sendable {
        let key: String
        let remoteURL: URL
        /// Reçue d'un autre membre : seules les notes reçues s'enchaînent.
        let incoming: Bool
        /// Le message qui précède dans le fil est aussi une note : une note isolée
        /// au milieu de la conversation n'est pas jouée à la suite.
        let followsPrevious: Bool
    }

    /// Vitesses proposées, dans l'ordre où le bouton les parcourt.
    nonisolated static let rates: [Float] = [1, 1.5, 2]

    /// Identifiant de la note chargée (l'URL), en lecture OU en pause, pour que
    /// chaque bulle sache si c'est ELLE qui est au premier plan.
    @Published private(set) var playingURL: URL?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1

    /// Les notes du fil ouvert, posées par la conversation ; vide hors d'un fil.
    var sequence: [SequenceItem] = []
    private var playingKey: String?

    private var player: AVAudioPlayer?
    private var audioSession: VoiceNoteAudioSession?
    private var tickTask: Task<Void, Never>?
    private var chainTask: Task<Void, Never>?

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type: type, shouldResume: options?.contains(.shouldResume) == true) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }
        }
    }

    /// La note est au premier plan, qu'elle joue ou soit en pause.
    func isActive(_ url: URL) -> Bool { playingURL == url }

    /// La note joue réellement (au premier plan et pas en pause).
    func isPlaying(_ url: URL) -> Bool { playingURL == url && !isPaused }

    /// Position en secondes de la note au premier plan.
    var elapsed: TimeInterval { duration * progress }

    /// Touche sur une note : la lance, la met en pause ou la reprend où elle en était.
    /// Lancer une autre note arrête la précédente.
    func toggle(url: URL, key: String? = nil) {
        if playingURL == url {
            if isPaused { resume() } else { pause() }
            return
        }
        start(url: url, key: key)
    }

    private func start(url: URL, key: String?) {
        stop()
        do {
            // `.playback` : une note vocale doit s'entendre même en mode
            // silencieux, comme dans toutes les messageries. Pendant un appel,
            // la session est celle de l'appel : on joue dessus sans la changer.
            if !CallManager.isCallInProgress {
                audioSession = try VoiceNoteAudioSession.begin(category: .playback, mode: .spokenAudio)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            guard player.play() else {
                stop()
                return
            }
            self.player = player
            playingURL = url
            playingKey = key
            isPaused = false
            duration = player.duration
            progress = 0
            startTicking()
        } catch {
            stop()
        }
    }

    func pause() {
        guard let player, playingURL != nil, !isPaused else { return }
        player.pause()
        isPaused = true
        tickTask?.cancel()
        tickTask = nil
        syncProgress()
    }

    func resume() {
        guard let player, isPaused else { return }
        if audioSession != nil {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                stop()
                return
            }
        }
        player.enableRate = true
        player.rate = rate
        guard player.play() else {
            stop()
            return
        }
        isPaused = false
        startTicking()
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        chainTask?.cancel()
        chainTask = nil
        player?.stop()
        player = nil
        playingURL = nil
        playingKey = nil
        isPaused = false
        progress = 0
        // Seulement si cette lecture avait pris la session (jamais pendant un
        // appel, ni pour une musique qu'elle n'a pas interrompue).
        audioSession?.end()
        audioSession = nil
    }

    /// Déplace la lecture à `fraction` (0…1) de la note au premier plan.
    func seek(toFraction fraction: Double) {
        guard let player, player.duration > 0 else { return }
        player.currentTime = Self.clampedTime(fraction: fraction, duration: player.duration)
        syncProgress()
    }

    /// Avance ou recule de `seconds` (VoiceOver : ajustement par pas de 10 s).
    func skip(by seconds: TimeInterval) {
        guard let player, player.duration > 0 else { return }
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        syncProgress()
    }

    /// 1× → 1,5× → 2× → 1×.
    func cycleRate() {
        rate = Self.nextRate(after: rate)
        player?.enableRate = true
        player?.rate = rate
    }

    private func syncProgress() {
        guard let player else { return }
        // Division gardée : une durée nulle produirait `NaN`, qui
        // remonterait jusqu'à un `frame` SwiftUI et planterait le rendu.
        progress = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : 0
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player else { return }
                if !player.isPlaying {
                    // Interrompue par le système (appel, Siri) sans qu'on l'ait demandé :
                    // la note reste en pause à sa place, un toucher la reprend.
                    if !self.isPaused { self.isPaused = true }
                    self.syncProgress()
                    return
                }
                self.syncProgress()
            }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            if player != nil, !isPaused {
                isPaused = true
                tickTask?.cancel()
                tickTask = nil
                syncProgress()
            }
        case .ended:
            if shouldResume, isPaused { resume() }
        default:
            break
        }
    }

    /// Fin naturelle d'une note : enchaîne la suivante du fil quand il y en a une.
    fileprivate func didFinish() {
        let key = playingKey
        stop()
        guard let key, let next = Self.nextToChain(after: key, in: sequence) else { return }
        chainTask = Task { [weak self] in
            guard let file = try? await VoiceNoteCache.shared.file(for: next.remoteURL, key: next.key) else { return }
            guard let self, !Task.isCancelled, self.playingURL == nil else { return }
            self.start(url: file.url, key: next.key)
        }
    }

    /// Formate une durée en `m:ss` — le format attendu sur une note vocale.
    nonisolated static func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Vitesse suivante dans le cycle ; une valeur inconnue revient à 1×.
    nonisolated static func nextRate(after rate: Float) -> Float {
        guard let index = rates.firstIndex(of: rate) else { return rates[0] }
        return rates[(index + 1) % rates.count]
    }

    /// « 1× », « 1,5× », « 2× », sans décimale inutile.
    nonisolated static func rateLabel(_ rate: Float) -> String {
        let value = rate == rate.rounded() ? "\(Int(rate))" : rate.formatted(.number.precision(.fractionLength(1)))
        return "\(value)×"
    }

    /// Position visée, bornée à la durée de la note.
    nonisolated static func clampedTime(fraction: Double, duration: TimeInterval) -> TimeInterval {
        guard fraction.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, fraction), 1) * duration
    }

    /// La note à enchaîner après `key` : la suivante du fil, si elle est reçue et suit
    /// directement (aucun autre message entre les deux), et si la note jouée est reçue.
    nonisolated static func nextToChain(after key: String, in sequence: [SequenceItem]) -> SequenceItem? {
        guard let index = sequence.firstIndex(where: { $0.key == key }),
              sequence[index].incoming,
              index + 1 < sequence.count else { return nil }
        let next = sequence[index + 1]
        return next.incoming && next.followsPrevious ? next : nil
    }
}

extension VoiceNotePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if flag { self?.didFinish() } else { self?.stop() }
        }
    }
}
