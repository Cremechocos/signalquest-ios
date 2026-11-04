import AVFoundation
import QuickLook
import SwiftUI
import UIKit

/// Manifestes d'une pièce chiffrée et de sa miniature (E2EE-AUTO §7.7).
struct E2EEAutoMediaRef: Equatable {
    let file: E2EEAutoContentR17.Manifest
    let thumbnail: E2EEAutoContentR17.Manifest?

    static let scheme = "sq-e2ee-blob"

    /// Adresse d'une pièce chiffrée : son `blobId`, jamais une URL de stockage (§7.4).
    static func url(blobId: String) -> URL? { URL(string: "\(scheme):\(blobId)") }

    /// Les pièces d'un message révision 17, sous la forme commune `MessageAttachment`.
    static func attachments(of body: E2EEAutoContentR17.Body, into media: inout [String: E2EEAutoMediaRef]) -> [MessageAttachment] {
        func attachment(_ manifest: E2EEAutoContentR17.Manifest, thumbnail: E2EEAutoContentR17.Manifest?, kind: String) -> MessageAttachment {
            media[manifest.blobId] = .init(file: manifest, thumbnail: thumbnail)
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
        case .audio(_, let voice, _, _):
            return [attachment(voice, thumbnail: nil, kind: "AUDIO")]
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

    private let files: [String: URL] = [
        "blob_qa_photo": picture("photo.jpg", hue: 0.08, size: CGSize(width: 1280, height: 960)),
        "blob_qa_video_thumb": picture("video-thumb.jpg", hue: 0.55, size: CGSize(width: 480, height: 270)),
    ]

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
