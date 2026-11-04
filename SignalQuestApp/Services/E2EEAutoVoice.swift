import AVFoundation
import Foundation
import Speech

/// Vocal chiffré (E2EE-AUTO §7.7, `AUDIO`) : AAC-LC en MP4, forme d'onde de 64 octets.
enum E2EEAutoVoice {
    static let fileName = "voice.m4a"
    static let waveformBytes = 64

    /// Source d'un vocal enregistré, avec sa forme d'onde : une amplitude de 0 à 255 par
    /// tranche de 1/64 de la durée. `nil` si le fichier n'est pas de l'AAC lisible.
    static func source(at url: URL) -> (source: E2EEAutoMediaSource, waveformB64: String?)? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let analyzed = try? VoiceNoteCache.analyze(url, bars: waveformBytes) else { return nil }
        let durationMs = Int64((analyzed.duration * 1_000).rounded())
        guard durationMs >= 1 else { return nil }
        let source = E2EEAutoMediaSource(
            data: data, fileName: fileName, mimeType: E2EEAutoContentR17.voiceMimeType,
            width: nil, height: nil, durationMs: durationMs, thumbnail: nil
        )
        return (source, waveformB64(analyzed.levels))
    }

    static func waveformB64(_ levels: [Float]) -> String? {
        guard levels.count == waveformBytes else { return nil }
        let bytes = levels.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        return Data(bytes).base64EncodedString()
    }

    /// Amplitudes 0…1 d'une forme d'onde reçue ; vide si elle est absente.
    static func levels(fromWaveformB64 value: String?) -> [Float] {
        guard let value, let data = Data(base64Encoded: value), data.count == waveformBytes else { return [] }
        return data.map { Float($0) / 255 }
    }
}

/// Transcription sur l'appareil seulement : sans moteur local pour la langue, aucune
/// transcription, jamais un moteur qui enverrait le son à un serveur (§7.7).
enum E2EEAutoVoiceTranscriber {
    static let maxTextBytes = 65_536

    /// `askPermission` : demander l'autorisation si elle n'a jamais été donnée.
    static func transcribe(_ url: URL, locale: Locale = .current, askPermission: Bool, timeout: TimeInterval = 30) async -> E2EEAutoContentR17.Transcription? {
        guard await authorized(ask: askPermission),
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let text = await recognize(recognizer, request, timeout: timeout)
        guard let text = text.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), !text.isEmpty,
              let language = languageTag(recognizer.locale) else { return nil }
        return .init(language: language, text: bounded(text))
    }

    /// `fr_FR` → `fr-FR` ; les variantes que le contrat refuserait sont écartées.
    static func languageTag(_ locale: Locale) -> String? {
        let tag = locale.identifier.replacingOccurrences(of: "_", with: "-")
        guard (2...35).contains(tag.count),
              tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else { return nil }
        return tag
    }

    /// Coupe à 65 536 octets UTF-8 sans casser un caractère.
    static func bounded(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= maxTextBytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    private static func authorized(ask: Bool) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined where ask:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechURLRecognitionRequest, timeout: TimeInterval) async -> String? {
        /// Une seule reprise de la continuation ; l'annulation coupe la tâche du système,
        /// dont le rappel d'erreur rend alors la main.
        final class Running: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            private var task: SFSpeechRecognitionTask?
            private var cancelled = false
            func claim() -> Bool { lock.withLock { defer { resumed = true }; return !resumed } }
            func attach(_ task: SFSpeechRecognitionTask) {
                let cancel = lock.withLock { self.task = task; return cancelled }
                if cancel { task.cancel() }
            }
            func cancel() { lock.withLock { cancelled = true; return task }?.cancel() }
        }
        let running = Running()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            running.cancel()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        if running.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    } else if error != nil {
                        if running.claim() { continuation.resume(returning: nil) }
                    }
                }
                running.attach(task)
            }
        } onCancel: {
            running.cancel()
        }
    }
}
