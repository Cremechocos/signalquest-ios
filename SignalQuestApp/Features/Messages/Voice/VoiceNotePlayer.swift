import AVFoundation
import Foundation

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

    /// Identifiant de la note en cours (l'URL), pour que chaque bulle sache si
    /// c'est ELLE qui joue.
    @Published private(set) var playingURL: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    private override init() { super.init() }

    func isPlaying(_ url: URL) -> Bool { playingURL == url }

    /// Bascule lecture/pause. Lancer une autre note arrête la précédente.
    func toggle(url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        do {
            // `.playback` : une note vocale doit s'entendre même en mode
            // silencieux, comme dans toutes les messageries.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else { return }
            self.player = player
            playingURL = url
            duration = player.duration
            progress = 0
            startTicking()
        } catch {
            stop()
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        player?.stop()
        player = nil
        playingURL = nil
        progress = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player, player.isPlaying else { return }
                // Division gardée : une durée nulle produirait `NaN`, qui
                // remonterait jusqu'à un `frame` SwiftUI et planterait le rendu.
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    /// Formate une durée en `m:ss` — le format attendu sur une note vocale.
    nonisolated static func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension VoiceNotePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
