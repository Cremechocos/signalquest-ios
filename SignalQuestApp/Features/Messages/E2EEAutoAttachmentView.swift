import AVFoundation
import QuickLook
import SwiftUI
import UIKit

/// Manifestes d'une pièce chiffrée et de sa miniature (E2EE-AUTO §7.7).
struct E2EEAutoMediaRef: Equatable {
    let file: E2EEAutoContentR17.Manifest
    let thumbnail: E2EEAutoContentR17.Manifest?
    /// Vocal : forme d'onde et transcription de l'émetteur, telles qu'envoyées.
    var waveformB64: String?
    var transcription: E2EEAutoContentR17.Transcription?

    static let scheme = "sq-e2ee-blob"

    /// Adresse d'une pièce chiffrée : son `blobId`, jamais une URL de stockage (§7.4).
    static func url(blobId: String) -> URL? { URL(string: "\(scheme):\(blobId)") }

    /// Les pièces d'un message révision 17, sous la forme commune `MessageAttachment`.
    static func attachments(of body: E2EEAutoContentR17.Body, into media: inout [String: E2EEAutoMediaRef]) -> [MessageAttachment] {
        func attachment(
            _ manifest: E2EEAutoContentR17.Manifest, thumbnail: E2EEAutoContentR17.Manifest?, kind: String,
            waveformB64: String? = nil, transcription: E2EEAutoContentR17.Transcription? = nil
        ) -> MessageAttachment {
            media[manifest.blobId] = .init(file: manifest, thumbnail: thumbnail, waveformB64: waveformB64, transcription: transcription)
            return MessageAttachment(
                id: manifest.blobId, kind: kind, url: url(blobId: manifest.blobId), fileName: manifest.fileName,
                contentType: manifest.mimeType, size: Int(manifest.plaintextSize), width: manifest.width, height: manifest.height
            )
        }
        switch body {
        case .media(_, let attachments):
            return attachments.map { item in
                let kind: String = switch E2EEAutoContentR17.presentation(mimeType: item.file.mimeType) {
                case .image: "IMAGE"
                case .video: "VIDEO"
                case .file: "FILE"
                }
                return attachment(item.file, thumbnail: item.thumbnail, kind: kind)
            }
        case .audio(_, let voice, let waveformB64, let transcription):
            return [attachment(voice, thumbnail: nil, kind: "AUDIO", waveformB64: waveformB64, transcription: transcription)]
        case .card(let card):
            return card.image.map { [attachment($0, thumbnail: nil, kind: "IMAGE")] } ?? []
        case .poll, .pollVote, .pollClose:
            return []
        }
    }
}

/// Une pièce jointe chiffrée dans le fil : déchiffrée sur l'appareil, jamais
/// exécutée. Une image se charge seule ; une vidéo montre sa miniature ; un
/// fichier attend qu'on le touche. Ouverture dans l'aperçu du système.
/// Une pièce locale (`file://`, en cours d'envoi) s'affiche telle quelle.
struct E2EEAutoAttachmentView: View {
    let attachment: MessageAttachment
    let media: E2EEAutoMediaRef?
    let mine: Bool
    var standalone = false
    let load: (E2EEAutoContentR17.Manifest) async -> E2EEAutoMediaCache.Result

    private enum Phase: Equatable {
        case idle, loading, ready(URL), deleted, unavailable
    }

    @State private var phase = Phase.idle
    @State private var image: UIImage?
    @State private var thumbnail: UIImage?
    @State private var preview: PreviewItem?

    private var presentation: E2EEAutoContentR17.Presentation {
        E2EEAutoContentR17.presentation(mimeType: attachment.contentType ?? "application/octet-stream")
    }

    var body: some View {
        Group {
            if phase == .deleted {
                notice(String(localized: "Pièce jointe supprimée"), systemImage: "trash.slash")
            } else {
                switch presentation {
                case .image, .video: visual
                case .file: fileRow
                }
            }
        }
        .task(id: attachment.id) { await prepare() }
        .sheet(item: $preview) { item in
            QuickLookPreview(url: item.url) { preview = nil }.ignoresSafeArea()
        }
    }

    private var displaySize: CGSize {
        guard let width = attachment.width, let height = attachment.height, width > 0, height > 0 else {
            return CGSize(width: 220, height: 220)
        }
        let scale = 240 / CGFloat(max(width, height))
        return CGSize(width: max(80, CGFloat(width) * scale), height: max(80, CGFloat(height) * scale))
    }

    private var visual: some View {
        let shape = RoundedRectangle(cornerRadius: standalone ? SQRadius.lg : SQRadius.md, style: .continuous)
        return Button {
            Task { await open() }
        } label: {
            ZStack {
                if let shown = image ?? thumbnail {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    Rectangle().fill(SQColor.surfaceMuted).sqShimmer()
                }
                if presentation == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .accessibilityHidden(true)
                }
                if phase == .unavailable {
                    Label(String(localized: "Toucher pour réessayer"), systemImage: "arrow.clockwise")
                        .font(SQType.micro)
                        .padding(.horizontal, SQSpace.sm).padding(.vertical, SQSpace.xs)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if phase == .loading, presentation == .video {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation == .video
            ? (mine ? String(localized: "Ta vidéo chiffrée") : String(localized: "Vidéo chiffrée"))
            : (mine ? String(localized: "Ta photo chiffrée") : String(localized: "Photo chiffrée")))
        .accessibilityHint(String(localized: "Toucher pour ouvrir"))
    }

    private var fileRow: some View {
        Button {
            Task { await open() }
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: phase == .unavailable ? "exclamationmark.triangle.fill" : "doc.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(mine ? SQColor.onInk.opacity(0.16) : SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.fileName ?? String(localized: "Pièce jointe"))
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(phase == .unavailable ? String(localized: "Indisponible pour l’instant. Toucher pour réessayer.") : metaLine)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: SQSpace.sm)
                if phase == .loading {
                    ProgressView()
                } else {
                    Image(systemName: "lock.doc.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(mine ? SQColor.onInk.opacity(0.9) : SQColor.brandRed)
                        .accessibilityHidden(true)
                }
            }
            .padding(SQSpace.sm)
            .frame(minWidth: 200, minHeight: 44, alignment: .leading)
            .background(mine ? SQColor.onInk.opacity(0.10) : SQColor.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, SQSpace.xs)
        .accessibilityLabel(String(localized: "Fichier chiffré \(attachment.fileName ?? ""), \(metaLine)"))
        .accessibilityHint(String(localized: "Toucher pour ouvrir"))
    }

    private var metaLine: String {
        var parts: [String] = []
        if let size = attachment.size, size >= 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let ext = attachment.fileName?.split(separator: ".").last.map(String.init), ext.count <= 5,
           attachment.fileName?.contains(".") == true {
            parts.append(ext.uppercased())
        }
        return parts.isEmpty ? String(localized: "Fichier") : parts.joined(separator: " · ")
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(SQType.subhead)
            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
            .padding(SQSpace.sm)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
    }

    // MARK: Chargement

    private func prepare() async {
        if let url = attachment.url, url.isFileURL {
            phase = .ready(url)
            if presentation == .image { image = await Self.decode(url) }
            return
        }
        guard let media else { phase = .unavailable; return }
        if let thumb = media.thumbnail, case .file(let url) = await load(thumb) {
            thumbnail = await Self.decode(url)
        }
        // Une image se charge seule ; une vidéo ou un fichier attendent d'être touchés.
        if presentation == .image { await fetch() }
        if presentation == .video, thumbnail == nil, case .ready(let url) = phase {
            thumbnail = await Self.videoFrame(url)
        }
    }

    @discardableResult
    private func fetch() async -> URL? {
        if case .ready(let url) = phase { return url }
        guard let media else { return nil }
        phase = .loading
        switch await load(media.file) {
        case .file(let url):
            phase = .ready(url)
            if presentation == .image { image = await Self.decode(url) }
            return url
        case .deleted:
            phase = .deleted
        case .unavailable:
            phase = .unavailable
        }
        return nil
    }

    private func open() async {
        guard let url = await fetch() else { return }
        Haptics.selection()
        preview = PreviewItem(url: url)
    }

    private static func decode(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImagePipeline.downsample(data: data, maxPixel: 720)
        }.value
    }

    private static func videoFrame(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        return (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:))
    }

    private struct PreviewItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}

/// Vocal chiffré : déchiffré sur l'appareil puis lu dans l'app. La transcription de
/// l'émetteur s'affiche avec sa mention ; sans elle, « Transcrire » la fait ici, sur
/// l'appareil seulement, et l'affiche sans mention (§7.7).
struct E2EEAutoVoiceBubble: View {
    let attachment: MessageAttachment
    let media: E2EEAutoMediaRef?
    let mine: Bool
    let load: (E2EEAutoContentR17.Manifest) async -> E2EEAutoMediaCache.Result

    private enum Phase: Equatable {
        case loading, ready(VoiceNoteFile), deleted, unavailable
    }

    private enum LocalTranscription: Equatable {
        case none, running, done(String), unavailable
    }

    @State private var phase = Phase.loading
    @State private var local = LocalTranscription.none

    private var foreground: Color { mine ? SQColor.onInk : SQColor.label }
    private var secondary: Color { mine ? SQColor.onInk.opacity(0.85) : SQColor.labelSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            switch phase {
            case .ready(let file):
                VoiceNoteBubble(url: file.url, levels: file.levels, duration: file.duration, mine: mine, sequenceKey: attachment.id)
            case .deleted:
                Label(String(localized: "Pièce jointe supprimée"), systemImage: "trash.slash")
                    .font(SQType.subhead)
                    .foregroundStyle(secondary)
                    .frame(minHeight: 44)
            case .loading, .unavailable:
                placeholder
            }
            transcriptionView
        }
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, SQSpace.xs)
        .task(id: attachment.id) { await prepare() }
    }

    private var placeholder: some View {
        Button {
            guard phase == .unavailable else { return }
            Task { await prepare() }
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    Circle().fill(mine ? SQColor.onInk : SQColor.brandRed).frame(width: 34, height: 34)
                    if phase == .unavailable {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(mine ? SQColor.label : SQColor.onAccent)
                    } else {
                        SQSpinner().controlSize(.small).tint(mine ? SQColor.label : SQColor.onAccent)
                    }
                }
                Text(phase == .unavailable ? String(localized: "Message vocal indisponible") : String(localized: "Message vocal chiffré"))
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(foreground)
            }
            .frame(minWidth: 180, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(phase == .unavailable ? String(localized: "Toucher pour réessayer") : "")
    }

    @ViewBuilder
    private var transcriptionView: some View {
        if let sender = media?.transcription {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Transcription de l’expéditeur"))
                    .font(SQType.micro)
                    .foregroundStyle(secondary)
                Text(sender.text)
                    .font(SQType.subhead)
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 260, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if case .ready(let file) = phase {
            switch local {
            case .none:
                Button {
                    Task { await transcribe(file.url) }
                } label: {
                    Label(String(localized: "Transcrire"), systemImage: "text.quote")
                        .font(SQType.micro)
                        .foregroundStyle(secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Sur cet appareil, sans envoyer le son"))
            case .running:
                HStack(spacing: SQSpace.xs) {
                    ProgressView().controlSize(.mini).tint(secondary)
                    Text(String(localized: "Transcription…")).font(SQType.micro).foregroundStyle(secondary)
                }
                .frame(minHeight: 44)
            case .done(let text):
                Text(text)
                    .font(SQType.subhead)
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: 260, alignment: .leading)
            case .unavailable:
                Text(String(localized: "Transcription indisponible sur cet appareil pour cette langue."))
                    .font(SQType.micro)
                    .foregroundStyle(secondary)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }

    private func prepare() async {
        if case .ready = phase { return }
        phase = .loading
        let url: URL
        if let local = attachment.url, local.isFileURL {
            url = local
        } else if let media {
            switch await load(media.file) {
            case .file(let file): url = file
            case .deleted: phase = .deleted; return
            case .unavailable: phase = .unavailable; return
            }
        } else {
            phase = .unavailable
            return
        }
        let sent = E2EEAutoVoice.levels(fromWaveformB64: media?.waveformB64)
        let duration = media?.file.durationMs.map { Double($0) / 1_000 }
        let analyzed = await Task.detached(priority: .userInitiated) { try? VoiceNoteCache.analyze(url) }.value
        guard let analyzed else { phase = .unavailable; return }
        phase = .ready(VoiceNoteFile(
            url: url,
            levels: sent.isEmpty ? analyzed.levels : VoiceNoteRecorder.waveform(from: sent, bars: 32),
            duration: duration ?? analyzed.duration
        ))
    }

    private func transcribe(_ url: URL) async {
        local = .running
        if let result = await E2EEAutoVoiceTranscriber.transcribe(url, askPermission: true) {
            local = .done(result.text)
        } else {
            local = .unavailable
        }
    }
}

/// Aperçu du système (images, vidéos, PDF…) d'un fichier local déjà déchiffré.
/// Dans une feuille SwiftUI, l'aperçu n'a pas de bouton « OK » à lui : on y met « Fermer ».
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let onClose = onClose
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { _ in onClose() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// Relecture au simulateur des états d'une pièce chiffrée (`--qa-auto-attachments`) :
/// photo reçue, photo envoyée en cours, vidéo, fichier, pièce supprimée, indisponible.
struct E2EEAutoAttachmentsQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    private struct Row: Identifiable {
        let id: String
        let attachment: MessageAttachment
        let media: E2EEAutoMediaRef?
        let mine: Bool
    }

    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-e2ee-attachments", isDirectory: true)

    private static func picture(_ name: String, hue: CGFloat, size: CGSize) -> URL {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.6, brightness: 0.55, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.2, y: size.height * 0.25, width: size.width * 0.6, height: size.height * 0.5))
        }
        try? image.jpegData(compressionQuality: 0.8)?.write(to: url)
        return url
    }

    private static func manifest(_ id: String, _ fileName: String, _ mimeType: String, size: Int64, width: Int? = nil, height: Int? = nil) -> E2EEAutoContentR17.Manifest {
        .init(blobId: id, mediaKeyB64: "", noncePrefixB64: "", plaintextSize: size, ciphertextSize: size,
              plaintextSha256: "", ciphertextSha256: "", fileName: fileName, mimeType: mimeType,
              width: width, height: height, durationMs: nil)
    }

    private static func row(_ manifest: E2EEAutoContentR17.Manifest, thumbnail: E2EEAutoContentR17.Manifest? = nil, kind: String, mine: Bool = false, local: URL? = nil) -> Row {
        Row(id: manifest.blobId, attachment: MessageAttachment(
            id: manifest.blobId, kind: kind, url: local ?? E2EEAutoMediaRef.url(blobId: manifest.blobId), fileName: manifest.fileName,
            contentType: manifest.mimeType, size: Int(manifest.plaintextSize), width: manifest.width, height: manifest.height
        ), media: local == nil ? .init(file: manifest, thumbnail: thumbnail) : nil, mine: mine)
    }

    /// Vocal AAC de 3 s, d'intensité croissante.
    private static func voice() -> URL {
        let url = folder.appendingPathComponent("voice.m4a")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return url }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * 3)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return url }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let position = Float(index) / Float(frames)
            channel[index] = (0.1 + 0.7 * position) * sin(Float(index) * 2 * .pi * 220 / Float(format.sampleRate))
        }
        try? file.write(from: buffer)
        return url
    }

    private let files: [String: URL] = [
        "blob_qa_photo": picture("photo.jpg", hue: 0.08, size: CGSize(width: 1280, height: 960)),
        "blob_qa_video_thumb": picture("video-thumb.jpg", hue: 0.55, size: CGSize(width: 480, height: 270)),
        "blob_qa_voice": voice(),
        "blob_qa_voice_bare": voice(),
        "blob_qa_card": picture("card.jpg", hue: 0.6, size: CGSize(width: 1280, height: 960)),
    ]

    private var voices: [Row] {
        let waveform = E2EEAutoVoice.waveformB64((0..<64).map { 0.15 + 0.85 * abs(sin(Float($0) / 5)) })
        func voice(_ id: String, transcription: E2EEAutoContentR17.Transcription?, mine: Bool) -> Row {
            let manifest = Self.manifest(id, "voice.m4a", "audio/mp4", size: 48_000)
            let file = E2EEAutoContentR17.Manifest(
                blobId: id, mediaKeyB64: "", noncePrefixB64: "", plaintextSize: 48_000, ciphertextSize: 48_000,
                plaintextSha256: "", ciphertextSha256: "", fileName: manifest.fileName, mimeType: manifest.mimeType,
                width: nil, height: nil, durationMs: 3_000
            )
            return Row(id: id, attachment: MessageAttachment(
                id: id, kind: "AUDIO", url: E2EEAutoMediaRef.url(blobId: id), fileName: "voice.m4a",
                contentType: "audio/mp4", size: 48_000, width: nil, height: nil
            ), media: .init(file: file, thumbnail: nil, waveformB64: waveform, transcription: transcription), mine: mine)
        }
        return [
            voice("blob_qa_voice", transcription: .init(language: "fr-FR", text: "Je suis devant le pylône, la 5G passe enfin."), mine: false),
            voice("blob_qa_voice_bare", transcription: nil, mine: true),
        ]
    }

    /// Cartes de publication chiffrées (`CARD` `POST`) : l'aperçu passe comme pièce, la carte sans URL.
    private var cards: [(id: String, card: E2EEAutoContentR17.PostCard, image: Row?, mine: Bool)] {
        let image = Self.manifest("blob_qa_card", "image.jpg", "image/jpeg", size: 120_000, width: 1280, height: 960)
        return [
            ("card_qa_speedtest", .init(
                postId: "cmh1post00000000000000001", authorId: "cmh1user00000000000000001", authorName: "Camille", authorHandle: "camille",
                postedAt: "2026-11-04T08:15:00.000Z", text: "Enfin la 5G au pied de la Bastille, ça dépote.", image: image,
                measure: .speedtest(downloadMbps: "842.5", uploadMbps: "95.12", pingMs: "18", technology: "5G", operator: "Free Mobile")
            ), Self.row(image, kind: "IMAGE"), false),
            ("card_qa_signal", .init(
                postId: "cmh1post00000000000000002", authorId: nil, authorName: nil, authorHandle: "lea",
                postedAt: "2026-11-03T18:02:00.000Z", text: nil, image: nil,
                measure: .signal(rsrp: -97, band: "n78", site: "Grenoble Bastille", operator: "Orange", technology: "5G")
            ), nil, true),
        ]
    }

    private var rows: [Row] {
        [
            Self.row(Self.manifest("blob_qa_photo", "photo.jpg", "image/jpeg", size: 412_000, width: 1280, height: 960), kind: "IMAGE"),
            Self.row(Self.manifest("blob_qa_mine", "IMG_0042.jpg", "image/jpeg", size: 380_000, width: 960, height: 1280), kind: "IMAGE", mine: true,
                     local: Self.picture("mine.jpg", hue: 0.33, size: CGSize(width: 960, height: 1280))),
            Self.row(Self.manifest("blob_qa_video", "video.mp4", "video/mp4", size: 18_400_000, width: 1920, height: 1080),
                     thumbnail: Self.manifest("blob_qa_video_thumb", "video.jpg", "image/jpeg", size: 40_000, width: 480, height: 270), kind: "VIDEO"),
            Self.row(Self.manifest("blob_qa_file", "Relevé antennes octobre.pdf", "application/pdf", size: 2_350_000), kind: "FILE"),
            Self.row(Self.manifest("blob_qa_deleted", "photo-2.jpg", "image/jpeg", size: 300_000, width: 800, height: 600), kind: "IMAGE"),
            Self.row(Self.manifest("blob_qa_offline", "Compte rendu.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 88_000), kind: "FILE"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.md) {
                    ForEach(cards, id: \.id) { item in
                        VStack(alignment: .leading, spacing: SQSpace.xs + 1) {
                            if let row = item.image {
                                E2EEAutoAttachmentView(attachment: row.attachment, media: row.media, mine: item.mine) { manifest in
                                    files[manifest.blobId].map { .file($0) } ?? .unavailable
                                }
                            }
                            SharedPostCardBubble(card: E2EEAutoPostShare.shareCardData(item.card), mine: item.mine, onOpenPost: {})
                        }
                        .padding(SQSpace.sm)
                        .background(item.mine ? SQColor.brandRed : SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: item.mine ? .trailing : .leading)
                    }
                    ForEach(voices) { row in
                        E2EEAutoVoiceBubble(attachment: row.attachment, media: row.media, mine: row.mine) { manifest in
                            files[manifest.blobId].map { .file($0) } ?? .unavailable
                        }
                        .background(row.mine ? SQColor.brandRed : SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: row.mine ? .trailing : .leading)
                    }
                    ForEach(rows) { row in
                        E2EEAutoAttachmentView(attachment: row.attachment, media: row.media, mine: row.mine, standalone: true) { manifest in
                            if manifest.blobId == "blob_qa_deleted" { return .deleted }
                            if let url = files[manifest.blobId] { return .file(url) }
                            return .unavailable
                        }
                        .padding(row.mine ? SQSpace.xs : 0)
                        .background(row.mine ? SQColor.brandRed : Color.clear, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: row.mine ? .trailing : .leading)
                    }
                }
                .padding(SQSpace.md)
            }
            .background(SQColor.bg)
            .navigationTitle(String(localized: "Pièces jointes chiffrées"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}
