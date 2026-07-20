import SwiftUI
import PhotosUI
import UIKit

// MARK: - Image d'un message (distante ou embarquée)

/// Une image de message peut arriver du serveur en URL http(s) OU sous forme de
/// data-URL base64 (celles qu'on vient d'envoyer, avant recharge). On résout les
/// deux pour l'affichage (vignette + visionneuse).
enum AntennaReportImage: Identifiable {
    case remote(URL)
    case inline(UIImage)

    /// `id` stable : l'URL, ou un hash de l'image embarquée.
    var id: String {
        switch self {
        case .remote(let url): return url.absoluteString
        case .inline(let image): return "inline-\(ObjectIdentifier(image).hashValue)"
        }
    }

    /// Parse une chaîne d'image du backend en source affichable.
    static func parse(_ raw: String) -> AntennaReportImage? {
        if raw.hasPrefix("data:") {
            guard let comma = raw.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
                  let image = UIImage(data: data) else { return nil }
            return .inline(image)
        }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return .remote(url)
    }
}

// MARK: - Pièce jointe en attente d'envoi

struct PendingReportImage: Identifiable {
    let id = UUID()
    let image: UIImage
    /// data-URL base64 prête pour le corps JSON (`images: [String]`).
    let dataURL: String
}

// MARK: - ViewModel

@MainActor
final class AntennaReportThreadViewModel: ObservableObject {
    @Published var report: AntennaReport?
    @Published var comments: [AntennaReportComment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var draft: String = ""
    @Published var pendingImages: [PendingReportImage] = []
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var isSending = false
    @Published var attachmentError: String?

    let reportId: String
    private let service: AntennaReportsServicing

    /// Maximum de pièces jointes par message (contrat backend).
    static let maxImages = 3

    init(service: AntennaReportsServicing, report: AntennaReport?, reportId: String) {
        self.service = service
        self.report = report
        self.reportId = report?.id ?? reportId
    }

    var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await service.comments(reportId: reportId)
            comments = fetched.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        } catch {
            if error.isCancellation { return }
            errorMessage = "Impossible de charger la discussion."
        }
        // Deep link (aucune métadonnée de signalement) : on résout l'en-tête au
        // mieux depuis la liste « mes signalements ».
        if report == nil {
            report = try? await service.myReports().first { $0.id == reportId }
        }
    }

    func processPickedItems() async {
        let items = pickerItems
        pickerItems = []
        guard !items.isEmpty else { return }
        attachmentError = nil
        for item in items {
            guard pendingImages.count < Self.maxImages else {
                attachmentError = "3 images maximum par message."
                break
            }
            guard let prepared = await prepare(item) else {
                attachmentError = "Image illisible."
                continue
            }
            pendingImages.append(prepared)
        }
    }

    func removePending(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !text.isEmpty || !pendingImages.isEmpty else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let images = pendingImages.map(\.dataURL)
        do {
            let comment = try await service.addComment(reportId: reportId, content: text, images: images)
            withAnimation(SQMotion.bouncy) { comments.append(comment) }
            draft = ""
            pendingImages = []
            Haptics.success()
            // La réponse d'un signaleur rouvre un ticket clos côté serveur : on
            // rafraîchit le statut affiché pour rester cohérent.
            if let status = report?.status, status != .pending {
                report = try? await service.myReports().first { $0.id == reportId }
            }
        } catch {
            errorMessage = "Échec de l'envoi. Réessaie."
            Haptics.error()
        }
    }

    /// Décompresse + downscale hors du main thread, puis fabrique la data-URL base64.
    private func prepare(_ item: PhotosPickerItem) async -> PendingReportImage? {
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let jpeg = PhotoUploadPreparation.downscaledJPEG(from: raw, maxSide: 1400, quality: 0.8),
                  let image = UIImage(data: jpeg) else { return nil }
            let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            return PendingReportImage(image: image, dataURL: dataURL)
        }.value
    }
}

// MARK: - Vue

/// Fil de discussion d'un signalement d'antenne : en-tête (type + statut), bulles
/// (équipe à gauche, moi à droite en brique), réponse texte + images. Utilisable
/// poussée dans une pile de navigation OU présentée en sheet (deep link), auquel
/// cas `onClose` fournit le bouton « Fermer ».
struct AntennaReportThreadView: View {
    @StateObject private var model: AntennaReportThreadViewModel
    var onClose: (() -> Void)?

    @State private var viewerImage: AntennaReportImage?

    init(service: AntennaReportsServicing, report: AntennaReport? = nil, reportId: String? = nil, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: AntennaReportThreadViewModel(
            service: service,
            report: report,
            reportId: report?.id ?? reportId ?? ""
        ))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if let error = model.errorMessage, !model.comments.isEmpty {
                errorBanner(error)
            }
            composer
        }
        .sqAnimation(SQMotion.snappy, value: model.errorMessage)
        .signalQuestBackground()
        .navigationTitle("Discussion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { onClose() }.tint(SQColor.brandRed)
                }
            }
        }
        .task { await model.load() }
        .onChangeCompat(of: model.pickerItems) { _, _ in
            Task { await model.processPickedItems() }
        }
        .fullScreenCover(item: $viewerImage) { image in
            AntennaReportImageViewer(image: image)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.comments.isEmpty {
            ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                        if let report = model.report {
                            AntennaReportHeaderCard(report: report)
                                .padding(.bottom, SQSpace.xs)
                        }
                        if model.comments.isEmpty {
                            emptyThread
                        } else {
                            ForEach(model.comments) { comment in
                                bubble(comment)
                                    .id(comment.id)
                                    .sqFadeUp()
                            }
                        }
                    }
                    .padding(SQSpace.lg)
                }
                .onChangeCompat(of: model.comments.count) { _, _ in
                    guard let last = model.comments.last else { return }
                    withAnimation(SQMotion.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyThread: some View {
        VStack(spacing: SQSpace.sm) {
            Text("Aucune réponse pour l'instant.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
            Text("L'équipe de modération te répondra ici. Tu peux ajouter des précisions ou des photos.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xl)
    }

    // MARK: Bulles

    /// Bulle : équipe (`isAdmin`) à gauche sur surface douce avec le nom réel,
    /// moi (le signaleur) à droite en brique (bulle sortante de la DA Crème).
    @ViewBuilder
    private func bubble(_ comment: AntennaReportComment) -> some View {
        let isTeam = comment.isAdmin
        HStack {
            if !isTeam { Spacer(minLength: SQSpace.xxl) }
            VStack(alignment: isTeam ? .leading : .trailing, spacing: SQSpace.xs) {
                if isTeam {
                    Label(comment.author?.name?.nonEmpty ?? "Équipe SignalQuest", systemImage: "shield.lefthalf.filled")
                        .font(SQFont.body(12, .semibold))
                        .foregroundStyle(SQColor.brandRed)
                }
                VStack(alignment: isTeam ? .leading : .trailing, spacing: SQSpace.sm) {
                    if !comment.content.isEmpty {
                        Text(comment.content)
                            .font(SQType.body)
                            .foregroundStyle(isTeam ? SQColor.label : SQColor.onAccent)
                            .multilineTextAlignment(isTeam ? .leading : .trailing)
                    }
                    let images = comment.images.compactMap(AntennaReportImage.parse)
                    if !images.isEmpty {
                        AntennaReportBubbleImages(images: images) { viewerImage = $0 }
                    }
                }
                .padding(SQSpace.md)
                .background(
                    isTeam ? AnyShapeStyle(SQColor.surfaceMuted) : AnyShapeStyle(SQColor.brandRed),
                    in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                )
                if let date = comment.createdAt {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelTertiary)
                }
            }
            if isTeam { Spacer(minLength: SQSpace.xxl) }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(SQType.caption)
            .foregroundStyle(SQColor.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.dangerSoft)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: SQSpace.sm) {
            if let error = model.attachmentError {
                Text(error)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SQSpace.sm) {
                        ForEach(model.pendingImages) { pending in
                            pendingThumbnail(pending)
                        }
                    }
                }
            }
            HStack(spacing: SQSpace.sm + 2) {
                PhotosPicker(
                    selection: $model.pickerItems,
                    maxSelectionCount: AntennaReportThreadViewModel.maxImages,
                    matching: .images
                ) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(width: 44, height: 44)
                        .background(SQColor.surfaceMuted, in: Circle())
                }
                .disabled(model.pendingImages.count >= AntennaReportThreadViewModel.maxImages)
                .accessibilityLabel("Ajouter des photos")

                TextField("Écris une réponse", text: $model.draft, axis: .vertical)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1...4)
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm + 2)
                    .frame(minHeight: 44)
                    .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))

                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "ellipsis" : "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.onAccent)
                        .frame(width: 44, height: 44)
                        .background(SQColor.brandRed, in: Circle())
                        .opacity(model.canSend ? 1 : 0.45)
                        .sqAnimation(SQMotion.fast, value: model.canSend)
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Envoyer")
                .disabled(!model.canSend)
            }
        }
        .padding(SQSpace.md)
        .background(SQColor.surface)
    }

    private func pendingThumbnail(_ pending: PendingReportImage) -> some View {
        Image(uiImage: pending.image)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    Haptics.light()
                    model.removePending(pending.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .padding(2)
                }
                .accessibilityLabel("Retirer la photo")
            }
    }
}

// MARK: - Grille d'images d'une bulle

private struct AntennaReportBubbleImages: View {
    let images: [AntennaReportImage]
    let onTap: (AntennaReportImage) -> Void

    var body: some View {
        let side: CGFloat = images.count == 1 ? 180 : 108
        FlexibleImageRow(images: images, side: side, onTap: onTap)
    }
}

private struct FlexibleImageRow: View {
    let images: [AntennaReportImage]
    let side: CGFloat
    let onTap: (AntennaReportImage) -> Void

    var body: some View {
        HStack(spacing: SQSpace.xs + 2) {
            ForEach(images) { image in
                Button { onTap(image) } label: {
                    thumbnail(image)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo jointe, toucher pour agrandir")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: AntennaReportImage) -> some View {
        switch image {
        case .remote(let url):
            RemoteImage(url: url, maxDimension: side, contentMode: .fill) { SQColor.surfaceMuted }
        case .inline(let uiImage):
            Image(uiImage: uiImage).resizable().scaledToFill()
        }
    }
}

// MARK: - Visionneuse plein écran (distante ou embarquée)

/// Visionneuse plein écran d'UNE image jointe : zoom pincé + double-tap, glisser
/// pour fermer. Calquée sur `MessageImageViewer`, mais accepte aussi les images
/// embarquées (data-URL décodée) que le pipeline distant ne sait pas charger.
struct AntennaReportImageViewer: View {
    let image: AntennaReportImage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var dismissOffset: CGFloat = 0

    private var backgroundOpacity: Double {
        1 - min(Double(abs(dismissOffset)) / 600, 0.55)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            GeometryReader { geo in
                imageContent
                    .scaleEffect(scale)
                    .offset(y: dismissOffset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(magnification)
                    .simultaneousGesture(dragGesture)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("Photo en plein écran")
                    .accessibilityAddTraits(.isImage)
            }

            closeButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
    }

    @ViewBuilder
    private var imageContent: some View {
        switch image {
        case .remote(let url):
            RemoteImage(url: url, maxDimension: 1600, contentMode: .fit) {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .inline(let uiImage):
            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fit)
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fermer")
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { scale = 1; lastScale = 1 }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale <= 1 { dismissOffset = value.translation.height }
            }
            .onEnded { value in
                if scale <= 1 {
                    if abs(value.translation.height) > 130 {
                        dismiss()
                    } else {
                        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { dismissOffset = 0 }
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            if scale > 1 { scale = 1; lastScale = 1 } else { scale = 2.5; lastScale = 2.5 }
        }
    }
}

// MARK: - En-tête du signalement

/// Carte d'en-tête d'un fil : type de problème, statut, site, précisions et note
/// de modération éventuelle.
struct AntennaReportHeaderCard: View {
    let report: AntennaReport

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            HStack(spacing: SQSpace.sm + 2) {
                Image(systemName: report.reportType.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(SQColor.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.reportType.label)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text("Site \(report.siteId)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                AntennaReportStatusChip(status: report.status)
            }
            if let reason = report.reason?.nonEmpty {
                Text(reason)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
            }
            if let current = report.currentValue?.nonEmpty, let suggested = report.suggestedValue?.nonEmpty {
                HStack(spacing: SQSpace.xs + 2) {
                    Text(current).strikethrough().foregroundStyle(SQColor.labelSecondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(SQColor.labelTertiary)
                    Text(suggested).foregroundStyle(SQColor.success)
                }
                .font(SQFont.body(13, .semibold))
            }
            if let sector = report.sector {
                Text("Secteur \(sector)°")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let note = report.reviewComment?.nonEmpty {
                Label(note, systemImage: "text.bubble")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(SQSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }
}

/// Capsule de statut (en attente / résolu / rejeté).
struct AntennaReportStatusChip: View {
    let status: AntennaReportStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(SQFont.body(12, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, SQSpace.sm + 2)
            .padding(.vertical, SQSpace.xs + 1)
            .background(color.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var color: Color {
        switch status {
        case .pending: return SQColor.warning
        case .resolved: return SQColor.success
        case .dismissed: return SQColor.labelSecondary
        }
    }
}

private extension String {
    /// `nil` si la chaîne est vide après trim (utilitaire d'affichage local).
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
