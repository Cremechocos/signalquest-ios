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

    /// Images embarquées déjà décodées, par chaîne source : le fil est réévalué
    /// à chaque frappe, le décodage base64 et la réduction ne doivent pas l'être.
    /// La même instance garde aussi un `id` stable.
    @MainActor private static let inlineCache = NSCache<NSString, UIImage>()

    /// Parse une chaîne d'image du backend en source affichable.
    @MainActor
    static func parse(_ raw: String) -> AntennaReportImage? {
        if raw.hasPrefix("data:") {
            let key = raw as NSString
            if let cached = inlineCache.object(forKey: key) { return .inline(cached) }
            guard let comma = raw.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
                  let image = ImagePipeline.downsample(data: data, maxPixel: 1200) else { return nil }
            inlineCache.setObject(image, forKey: key)
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

/// Réponse partie du composeur : affichée tout de suite, elle reste dans le fil
/// avec « Réessayer » si l'envoi échoue, au lieu de revenir dans le champ.
struct OutgoingReportReply: Identifiable {
    let id = UUID()
    let text: String
    let images: [PendingReportImage]
    var failed = false
}

// MARK: - ViewModel

@MainActor
final class AntennaReportThreadViewModel: ObservableObject {
    @Published var report: AntennaReport?
    @Published var comments: [AntennaReportComment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// La discussion n'a pas pu être lue : ce n'est pas un fil vide.
    @Published var loadFailed = false
    @Published var draft: String = ""
    @Published var pendingImages: [PendingReportImage] = []
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var isSending = false
    @Published var attachmentError: String?
    @Published private(set) var outgoing: [OutgoingReportReply] = []

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
        loadFailed = false
        defer { isLoading = false }
        do {
            let fetched = try await service.comments(reportId: reportId)
            comments = fetched.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        } catch {
            if error.isCancellation { return }
            errorMessage = String(localized: "Impossible de charger la discussion.")
            loadFailed = true
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
                attachmentError = String(localized: "3 images maximum par message.")
                break
            }
            guard let prepared = await prepare(item) else {
                attachmentError = String(localized: "Image illisible.")
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
        let reply = OutgoingReportReply(text: text, images: pendingImages)
        outgoing.append(reply)
        draft = ""
        pendingImages = []
        await deliver(reply.id)
    }

    /// Renvoie une réponse restée « Non envoyé ».
    func retry(_ id: UUID) async {
        guard !isSending, let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].failed = false
        await deliver(id)
    }

    /// Abandonne une réponse non envoyée.
    func discard(_ id: UUID) {
        outgoing.removeAll { $0.id == id }
    }

    private func deliver(_ id: UUID) async {
        guard let reply = outgoing.first(where: { $0.id == id }) else { return }
        isSending = true
        defer { isSending = false }
        do {
            let comment = try await service.addComment(reportId: reportId, content: reply.text, images: reply.images.map(\.dataURL))
            withAnimation(SQMotion.resolve(SQMotion.bouncy, UIAccessibility.isReduceMotionEnabled)) {
                outgoing.removeAll { $0.id == id }
                comments.append(comment)
            }
            Haptics.success()
            // La réponse d'un signaleur rouvre un ticket clos côté serveur : on
            // rafraîchit le statut affiché pour rester cohérent.
            if let status = report?.status, status != .pending {
                // Un échec de relecture garde l'en-tête affiché plutôt que de l'effacer.
                if let fresh = try? await service.myReports().first(where: { $0.id == reportId }) {
                    report = fresh
                }
            }
        } catch {
            if let index = outgoing.firstIndex(where: { $0.id == id }) { outgoing[index].failed = true }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // L'échec de chargement prend la place d'un fil vide ; un fil déjà
            // affiché le signale ici. Un envoi raté, lui, reste sur son message.
            if let error = model.errorMessage, !(model.loadFailed && model.comments.isEmpty) {
                errorBanner(error)
            }
            composer
        }
        .sqAnimation(SQMotion.snappy, value: model.errorMessage)
        .signalQuestBackground()
        .navigationTitle(model.report?.reportType.label ?? String(localized: "Discussion"))
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                    header
                    if model.isLoading && model.comments.isEmpty {
                        SQSpinner().tint(SQColor.brandRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SQSpace.xl)
                    } else if model.comments.isEmpty, model.loadFailed, let error = model.errorMessage {
                        ErrorStateView(title: "Discussion indisponible", message: error) {
                            Task { await model.load() }
                        }
                    } else {
                        if model.comments.isEmpty, model.outgoing.isEmpty {
                            emptyThread
                        }
                        ForEach(model.comments) { comment in
                            bubble(comment)
                                .id(comment.id)
                                .sqFadeUp()
                        }
                        ForEach(model.outgoing) { reply in
                            outgoingBubble(reply)
                                .id(reply.id)
                        }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm)
                .sqReadableWidth()
            }
            // Tirer pour voir une réponse de la modération arrivée entre-temps.
            .refreshable { await model.load() }
            .onChangeCompat(of: model.comments.count + model.outgoing.count) { _, _ in
                let last = model.outgoing.last.map { AnyHashable($0.id) } ?? model.comments.last.map { AnyHashable($0.id) }
                guard let last else { return }
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: En-tête

    @Environment(\.dismiss) private var dismiss

    /// Retour (ou fermeture en feuille), puis le type et le site en titre.
    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if let onClose {
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "antennaReport.thread.close") { onClose() }
            } else {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "antennaReport.thread.back") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.report?.reportType.label ?? String(localized: "Discussion"))
                    .font(SQFont.display(24, .bold, relativeTo: .title))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("antennaReport.thread.title")
                if let report = model.report {
                    subtitle(report)
                        .font(SQType.subhead(.regular))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if let report = model.report {
                AntennaReportHeaderCard(report: report)
            }
        }
        .padding(.bottom, SQSpace.xs)
    }

    /// « Site 0381234 · signalé il y a 2 jours ».
    private func subtitle(_ report: AntennaReport) -> Text {
        let site = Text("Site \(report.siteId)").monospacedDigit()
        guard let date = report.createdAt else { return site }
        let when = date.formatted(.relative(presentation: .named))
        return site + Text(verbatim: " · ") + Text("signalé \(when)")
    }

    private var emptyThread: some View {
        VStack(spacing: SQSpace.sm) {
            Text("Aucune réponse pour l'instant.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
            Text("L'équipe de modération te répondra ici. Tu peux ajouter des précisions ou des photos.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xl)
    }

    // MARK: Bulles

    /// Bulle : équipe (`isAdmin`) à gauche sur surface douce avec le nom réel,
    /// moi (le signaleur) à droite en brique (bulle sortante de la DA Crème).
    private func bubble(_ comment: AntennaReportComment) -> some View {
        let isTeam = comment.isAdmin
        return HStack {
            if !isTeam { Spacer(minLength: SQSpace.xxl) }
            VStack(alignment: isTeam ? .leading : .trailing, spacing: SQSpace.xs) {
                if isTeam { teamAuthor(comment.author?.name?.nonEmpty) }
                bubbleBody(text: comment.content, images: comment.images.compactMap(AntennaReportImage.parse), isTeam: isTeam)
                if let date = comment.createdAt {
                    Text(date, format: .sqRelative)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.xs)
                }
            }
            if isTeam { Spacer(minLength: SQSpace.xxl) }
        }
    }

    /// Nom de l'auteur et pastille « Équipe », comme dans les bugs et idées.
    @ViewBuilder
    private func teamAuthor(_ name: String?) -> some View {
        HStack(spacing: 6) {
            if let name {
                Text(verbatim: name)
                Label("Équipe", systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(SQColor.accentSoft, in: Capsule())
            } else {
                Text("Équipe SignalQuest")
            }
        }
        .font(SQFont.body(11, .bold, relativeTo: .caption2))
        .foregroundStyle(SQColor.accentInk)
        .padding(.horizontal, SQSpace.xs)
    }

    private func bubbleBody(text: String, images: [AntennaReportImage], isTeam: Bool) -> some View {
        VStack(alignment: isTeam ? .leading : .trailing, spacing: SQSpace.sm) {
            if !text.isEmpty {
                Text(text)
                    .font(SQType.body)
                    .foregroundStyle(isTeam ? SQColor.label : SQColor.onAccent)
                    .multilineTextAlignment(.leading)
            }
            if !images.isEmpty {
                AntennaReportBubbleImages(images: images) { viewerImage = $0 }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm2)
        .background(
            isTeam ? AnyShapeStyle(SQColor.chip) : AnyShapeStyle(SQColor.brandRed),
            // Coin bas côté émetteur plus petit, comme les bulles de la messagerie.
            in: UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: isTeam ? 6 : 18,
                bottomTrailingRadius: isTeam ? 18 : 6,
                topTrailingRadius: 18,
                style: .continuous
            )
        )
    }

    /// Ma réponse en cours d'envoi, ou restée « Non envoyé » avec de quoi la
    /// renvoyer ou l'abandonner.
    private func outgoingBubble(_ reply: OutgoingReportReply) -> some View {
        HStack {
            Spacer(minLength: SQSpace.xxl)
            VStack(alignment: .trailing, spacing: SQSpace.xs) {
                bubbleBody(text: reply.text, images: reply.images.map { .inline($0.image) }, isTeam: false)
                    .opacity(reply.failed ? 0.75 : 0.6)
                if reply.failed {
                    HStack(spacing: SQSpace.sm) {
                        Text("Non envoyé")
                            .font(SQFont.body(12, .bold, relativeTo: .caption))
                            .foregroundStyle(SQColor.dangerInk)
                        Button {
                            Haptics.light()
                            model.discard(reply.id)
                        } label: {
                            Text("Supprimer")
                                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                                .foregroundStyle(SQColor.labelSecondary)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .accessibilityIdentifier("antennaReport.thread.discard")
                        Button {
                            Haptics.light()
                            Task { await model.retry(reply.id) }
                        } label: {
                            Label("Réessayer", systemImage: "arrow.clockwise")
                                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                                .foregroundStyle(SQColor.dangerInk)
                                .padding(.horizontal, SQSpace.sm2)
                                .frame(minHeight: 32)
                                .sqSurface(SQColor.chip, in: Capsule())
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .disabled(model.isSending)
                        .accessibilityIdentifier("antennaReport.thread.retry")
                    }
                } else {
                    Text("Envoi…")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.xs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antennaReport.thread.outgoing")
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(SQType.caption)
            .foregroundStyle(SQColor.dangerInk)
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
                    .foregroundStyle(SQColor.dangerInk)
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
            HStack(spacing: SQSpace.sm2) {
                PhotosPicker(
                    selection: $model.pickerItems,
                    maxSelectionCount: AntennaReportThreadViewModel.maxImages,
                    matching: .images
                ) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(width: 44, height: 44)
                        .sqSurface(SQColor.surfaceMuted, in: Circle())
                }
                .disabled(model.pendingImages.count >= AntennaReportThreadViewModel.maxImages)
                .accessibilityLabel("Ajouter des photos")
                .accessibilityIdentifier("antennaReport.thread.photos")

                TextField("Écris une réponse", text: $model.draft, axis: .vertical)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1...4)
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm2)
                    .frame(minHeight: 44)
                    .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))
                    .accessibilityIdentifier("antennaReport.thread.field")

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
                .accessibilityIdentifier("antennaReport.thread.send")
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
                        // Pastille visuelle inchangée dans le coin ; zone tactile de 44 pt.
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
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
        HStack(spacing: SQSpace.xs2) {
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
                    .accessibilityValue(scale > 1 ? Text("Zoom \(Int((scale * 100).rounded())) %") : Text("Taille adaptée"))
                    .accessibilityAction(named: Text("Agrandir")) { zoomIn() }
                    .accessibilityAction(named: Text("Réduire")) { zoomOut() }
                    .accessibilityAction(named: Text("Taille adaptée")) { resetZoom(animated: true) }
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
            RemoteImage(url: url, maxDimension: 1600, contentMode: .fit, showsFailureUI: true) {
                SQSpinner().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func zoomIn() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            scale = min(4, max(2, scale + 0.5))
            lastScale = scale
        }
    }

    private func zoomOut() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            scale = max(1, scale - 0.5)
            lastScale = scale
        }
    }

    private func resetZoom(animated: Bool) {
        let update = { scale = CGFloat(1); lastScale = CGFloat(1) }
        if animated {
            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion), update)
        } else {
            update()
        }
    }
}

// MARK: - En-tête du signalement

/// Carte d'en-tête d'un fil : statut, secteur, correction proposée, précisions
/// et note de modération éventuelle (le type et le site sont dans le titre).
struct AntennaReportHeaderCard: View {
    let report: AntennaReport

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(spacing: SQSpace.sm) {
                AntennaReportStatusChip(status: report.status)
                Spacer(minLength: SQSpace.sm)
                if let sector = report.sector {
                    Label("Secteur \(sector)°", systemImage: "safari")
                        .font(SQFont.body(12, .bold, relativeTo: .caption))
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 4)
                        .background(SQColor.chip, in: Capsule())
                }
            }
            if let current = report.currentValue?.nonEmpty, let suggested = report.suggestedValue?.nonEmpty {
                HStack(spacing: SQSpace.xs2) {
                    Text(current).strikethrough().foregroundStyle(SQColor.labelSecondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(SQColor.labelTertiary)
                        .accessibilityLabel(Text("remplacé par"))
                    Text(suggested).foregroundStyle(OutageTint.resolvedInk)
                }
                .font(SQFont.body(15, .bold, relativeTo: .body))
                .accessibilityElement(children: .combine)
            }
            if let reason = report.reason?.nonEmpty {
                Text(reason)
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let note = report.reviewComment?.nonEmpty {
                Label(note, systemImage: "text.bubble")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(SQSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityIdentifier("antennaReport.thread.header")
    }
}

/// Pastille d'état (en attente / résolu / rejeté) : un point de couleur et le
/// mot, écrit à l'encre lisible de la teinte.
struct AntennaReportStatusChip: View {
    let status: AntennaReportStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.label)
        }
        .font(SQFont.body(12, .bold, relativeTo: .caption))
        .foregroundStyle(ink)
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var tint: Color {
        switch status {
        case .pending: return SQColor.warning
        case .resolved: return SQColor.success
        case .dismissed: return SQColor.labelSecondary
        }
    }

    private var ink: Color {
        switch status {
        case .pending: return OutageTint.degradedInk
        case .resolved: return OutageTint.resolvedInk
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
