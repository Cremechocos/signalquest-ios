import AVFoundation
import CryptoKit
import SwiftUI

/// Note vocale d'une conversation : téléchargée une fois dans le cache du
/// compte, puis lue dans l'app. Elle s'affichait comme un fichier « M4A » qui
/// s'ouvrait hors de l'app (SOC-06).
struct RemoteVoiceNoteBubble: View {
    let attachment: MessageAttachment
    let remoteURL: URL
    /// Bulle envoyée par l'utilisateur (fond brique).
    let mine: Bool

    @State private var prepared: VoiceNoteFile?
    @State private var failed = false

    var body: some View {
        Group {
            if let prepared {
                VoiceNoteBubble(url: prepared.url, levels: prepared.levels, duration: prepared.duration, mine: mine)
            } else {
                placeholder
            }
        }
        .task(id: remoteURL) { await prepare() }
    }

    private var placeholder: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 34, height: 34)
                if failed {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(mine ? SQColor.brandRed : SQColor.onAccent)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(mine ? SQColor.brandRed : SQColor.onAccent)
                }
            }
            Text(failed ? "Note vocale indisponible" : "Note vocale")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
        }
        .frame(minWidth: 180, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard failed else { return }
            failed = false
            Task { await prepare() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "Note vocale indisponible" : "Note vocale en cours de chargement")
        .accessibilityHint(failed ? "Toucher pour réessayer" : "")
    }

    private func prepare() async {
        guard prepared == nil else { return }
        do {
            prepared = try await VoiceNoteCache.shared.file(for: remoteURL, key: attachment.id)
        } catch {
            if !error.isCancellation { failed = true }
        }
    }
}

/// Note vocale prête à lire : fichier local, forme d'onde et durée.
struct VoiceNoteFile: Equatable, Sendable {
    let url: URL
    let levels: [Float]
    let duration: TimeInterval
}

/// Cache des notes vocales, rangé par compte : un autre compte du même
/// téléphone ne relit pas les notes du premier. Le système peut vider ce
/// dossier ; la note est alors retéléchargée.
actor VoiceNoteCache {
    static let shared = VoiceNoteCache()

    private var memory: [String: VoiceNoteFile] = [:]
    /// Même principe que les images des messages : ni cookie ni cache disque
    /// partagé pour une pièce jointe privée.
    private let session = URLSession(configuration: .ephemeral)

    func file(for remoteURL: URL, key: String?) async throws -> VoiceNoteFile {
        let directory = try Self.directory()
        let destination = directory.appendingPathComponent(Self.fileName(remoteURL: remoteURL, key: key))
        if let cached = memory[destination.path], FileManager.default.fileExists(atPath: destination.path) {
            return cached
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            let (temporary, response) = try await session.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        let file = try Self.analyze(destination)
        memory[destination.path] = file
        return file
    }

    private static func directory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches
            .appendingPathComponent("VoiceNotes", isDirectory: true)
            .appendingPathComponent(LocalAccountScope.storageNamespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Nom stable : l'identifiant de la pièce jointe, sinon une empreinte du
    /// chemin (l'adresse signée change de paramètres d'une réponse à l'autre).
    static func fileName(remoteURL: URL, key: String?) -> String {
        let pathExtension = remoteURL.pathExtension.isEmpty ? "m4a" : remoteURL.pathExtension
        let source = key.flatMap { $0.isEmpty ? nil : $0 } ?? remoteURL.path
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest.prefix(32)).\(pathExtension)"
    }

    /// Forme d'onde lue par morceaux, sans charger toute la note en mémoire.
    static func analyze(_ url: URL, bars: Int = 32) throws -> VoiceNoteFile {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        let duration = format.sampleRate > 0 ? Double(totalFrames) / format.sampleRate : 0
        let framesPerBar = AVAudioFrameCount(max(1, totalFrames / AVAudioFramePosition(bars)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBar) else {
            return VoiceNoteFile(url: url, levels: [], duration: duration)
        }
        var levels: [Float] = []
        for _ in 0..<bars {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: framesPerBar)) != nil,
                  buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            levels.append((sum / Float(buffer.frameLength)).squareRoot())
        }
        let peak = levels.max() ?? 0
        return VoiceNoteFile(url: url, levels: peak > 0 ? levels.map { $0 / peak } : levels, duration: duration)
    }
}
