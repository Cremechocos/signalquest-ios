import AVFoundation
import Foundation

/// Enregistreur de note vocale.
///
/// Format **m4a/AAC** : c'est ce que le backend attend pour la transcription
/// (`audio/m4a` côté route Groq) et c'est le seul conteneur qu'iOS encode
/// nativement en AAC sans dépendance. Un WAV serait dix fois plus lourd pour un
/// message qui transite chiffré.
///
/// Les niveaux sont échantillonnés pendant l'enregistrement pour dessiner la
/// forme d'onde : les recalculer après coup demanderait de relire tout le
/// fichier, ce qui est exactement le travail qu'on veut éviter sur un appareil
/// mobile.
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject {

    /// Durée maximale. Au-delà, ce n'est plus une note vocale mais un fichier —
    /// et le coût de transcription grimpe avec la durée.
    static let maximumDuration: TimeInterval = 120
    /// Une note plus courte est un appui accidentel, pas un message.
    static let minimumDuration: TimeInterval = 0.6
    /// Nombre de barres de la forme d'onde. Fixé pour que l'affichage ne dépende
    /// pas de la durée : une note de 5 s et une de 90 s ont la même largeur.
    ///
    /// `nonisolated` : sert de valeur par défaut à `waveform(from:bars:)`, qui
    /// l'est aussi — une constante isolée MainActor y serait refusée.
    nonisolated static let waveformBars = 40

    enum State: Equatable {
        case idle
        case recording
        case finished(URL, duration: TimeInterval)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0
    /// Niveaux normalisés 0…1, échantillonnés pendant l'enregistrement.
    @Published private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var startedAt: Date?

    var isRecording: Bool { state == .recording }

    /// Demande l'autorisation micro. Séparé du démarrage : l'appel système
    /// affiche une alerte, et l'enchaîner avec l'enregistrement ferait perdre
    /// les premières secondes du message.
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    func start() async {
        guard state != .recording else { return }
        guard await Self.requestPermission() else {
            state = .failed(String(localized: "Autorise le micro dans les Réglages pour enregistrer."))
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // `.playAndRecord` et non `.record` : sans lui, réécouter la note
            // juste après l'avoir enregistrée resterait muet.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                // 22,05 kHz mono à 32 kbit/s : la voix n'a pas besoin de plus, et
                // une note d'une minute pèse ~240 Ko au lieu de plusieurs Mo.
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maximumDuration) else {
                state = .failed(String(localized: "Impossible de démarrer l'enregistrement."))
                return
            }
            self.recorder = recorder
            startedAt = Date()
            duration = 0
            levels = []
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Arrête et renvoie le fichier. `nil` si la note est trop courte — un appui
    /// accidentel ne doit pas produire un message.
    @discardableResult
    func stop() -> URL? {
        meterTask?.cancel()
        meterTask = nil
        guard let recorder else { return nil }
        let url = recorder.url
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard elapsed >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            return nil
        }
        duration = elapsed
        state = .finished(url, duration: elapsed)
        return url
    }

    /// Abandon explicite : le fichier est supprimé.
    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        if let recorder {
            let url = recorder.url
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        duration = 0
        levels = []
    }

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                self.levels.append(Self.normalizedLevel(recorder.averagePower(forChannel: 0)))
                if let startedAt = self.startedAt {
                    self.duration = Date().timeIntervalSince(startedAt)
                }
            }
        }
    }

    /// Convertit les décibels d'`AVAudioRecorder` (−160…0) en 0…1.
    ///
    /// L'échelle est logarithmique : une conversion linéaire écraserait toute la
    /// parole normale dans le bas de la forme d'onde, qui paraîtrait plate.
    /// Le plancher à −50 dB coupe le bruit de fond plutôt que de le dessiner.
    nonisolated static func normalizedLevel(_ decibels: Float) -> Float {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        guard decibels > floor else { return 0 }
        let clamped = min(0, decibels)
        return min(1, max(0, (clamped - floor) / -floor))
    }

    /// Réduit les niveaux bruts au nombre de barres affichées, en moyennant
    /// chaque tranche. Prendre un échantillon sur N perdrait les pics, qui sont
    /// justement ce qui rend une forme d'onde lisible.
    nonisolated static func waveform(from levels: [Float], bars: Int = waveformBars) -> [Float] {
        guard !levels.isEmpty, bars > 0 else { return [] }
        guard levels.count > bars else {
            return levels + Array(repeating: 0, count: bars - levels.count)
        }
        let size = Double(levels.count) / Double(bars)
        return (0..<bars).map { index in
            let start = Int(Double(index) * size)
            let end = min(levels.count, max(start + 1, Int(Double(index + 1) * size)))
            let slice = levels[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

extension VoiceNoteRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Atteinte de `maximumDuration` : le système arrête tout seul, il faut
        // refléter l'état sans quoi l'UI resterait en « enregistrement ».
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            _ = self.stop()
        }
    }
}
