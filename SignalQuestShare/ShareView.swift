import SwiftUI
import UIKit

/// État de la feuille de partage : lecture du contenu, aperçu, dépôt, puis
/// « C'est prêt » ou une erreur.
@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case saving
        case done
        case failed(ShareFailure)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var draft: ShareDraft?

    private let items: [NSExtensionItem]
    private let onCancel: () -> Void
    private let onFinish: () -> Void

    init(items: [NSExtensionItem], onCancel: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.items = items
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    func load() async {
        guard draft == nil, phase == .loading else { return }
        do {
            draft = try await ShareContentLoader.load(from: items)
            phase = .ready
        } catch let failure as ShareFailure {
            phase = .failed(failure)
        } catch let failure as ShareInbox.Failure {
            phase = .failed(ShareFailure(failure))
        } catch {
            phase = .failed(.unreadable)
        }
    }

    /// Dépose le partage dans l'App Group. Rien ne part sur le réseau.
    func prepare() async {
        guard phase == .ready, let draft else { return }
        guard let inbox = ShareInbox.appGroup() else {
            phase = .failed(.storageUnavailable)
            return
        }
        phase = .saving
        let text = draft.text
        let url = draft.url
        let sources = draft.sources
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try inbox.write(text: text, url: url, sources: sources)
            }.value
            removeStaging()
            phase = .done
        } catch let failure as ShareInbox.Failure {
            phase = .failed(ShareFailure(failure))
        } catch {
            phase = .failed(.writeFailed)
        }
    }

    func cancel() {
        // Comme `tearDown` : pendant le dépôt, les copies de travail servent encore.
        if phase != .saving { removeStaging() }
        onCancel()
    }

    func finish() {
        removeStaging()
        onFinish()
    }

    /// Feuille fermée d'un geste : les copies de travail partent aussi, sauf
    /// pendant le dépôt, qui s'en sert encore.
    func tearDown() {
        if phase != .saving { removeStaging() }
    }

    /// Les copies de travail de l'extension ne survivent pas à la feuille.
    private func removeStaging() {
        if let directory = draft?.stagingDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    @ScaledMetric(relativeTo: .body) private var thumbnailSize = ShareMetrics.thumbnail

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(ShareColor.background.ignoresSafeArea())
        .tint(ShareColor.accent)
        .task { await model.load() }
        .onChange(of: model.phase) { _ in
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    // MARK: Barre du haut

    private var header: some View {
        ZStack {
            Text("Partager vers SignalQuest")
                .font(.headline)
                .foregroundStyle(ShareColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 96)
                .accessibilityAddTraits(.isHeader)
            HStack {
                if showsCancel {
                    Button("Annuler") { model.cancel() }
                        .font(.body)
                        .foregroundStyle(ShareColor.accent)
                        .frame(minWidth: ShareMetrics.touchTarget, minHeight: ShareMetrics.touchTarget)
                        .contentShape(Rectangle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(minHeight: 56)
    }

    /// Pas d'« Annuler » pendant le dépôt : l'écriture lit encore les copies de
    /// travail, qu'une annulation effacerait en route.
    private var showsCancel: Bool {
        switch model.phase {
        case .loading, .ready: return true
        case .saving, .done, .failed: return false
        }
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Lecture du contenu…")
                    .font(.subheadline)
                    .foregroundStyle(ShareColor.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .accessibilityElement(children: .combine)
        case .ready, .saving:
            if let draft = model.draft { preview(of: draft) }
        case .done:
            outcome(
                symbol: "checkmark", tint: ShareColor.success, soft: ShareColor.successSoft,
                title: Text("C’est prêt"),
                message: Text("Ouvre SignalQuest : ton partage t’attend pour choisir une conversation ou le fil.")
            )
        case .failed(let failure):
            outcome(
                symbol: "exclamationmark", tint: ShareColor.danger, soft: ShareColor.dangerSoft,
                title: Text("Impossible de partager"),
                message: Text(verbatim: failure.message)
            )
        }
    }

    private func outcome(symbol: String, tint: Color, soft: Color, title: Text, message: Text) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(soft, in: Circle())
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .foregroundStyle(ShareColor.label)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            message
                .font(.body)
                .foregroundStyle(ShareColor.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    /// Ce qui sera déposé : texte tronqué, domaine du lien, vignettes, fichier.
    private func preview(of draft: ShareDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let text = draft.text {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(ShareColor.label)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url = draft.url {
                let host = Self.displayHost(of: url)
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ShareColor.accent)
                        .frame(width: 36, height: 36)
                        .background(ShareColor.accentSoft, in: Circle())
                        .accessibilityHidden(true)
                    Text(verbatim: host)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ShareColor.label)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: ShareMetrics.touchTarget)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Lien web : \(host)"))
            }
            if draft.imageCount > 0 { images(of: draft) }
            if let file = draft.attachment { attachment(file) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShareColor.surface, in: RoundedRectangle(cornerRadius: ShareMetrics.cardRadius, style: .continuous))
    }

    private func images(of draft: ShareDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(draft.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbnailSize, height: thumbnailSize)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .accessibilityHidden(true)
            Text("\(draft.imageCount) image")
                .font(.subheadline)
                .foregroundStyle(ShareColor.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func attachment(_ source: ShareInbox.Source) -> some View {
        let size = (try? ShareInbox.byteCount(of: source.fileURL)).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        return HStack(spacing: 10) {
            Image(systemName: source.kind == .video ? "film" : "doc")
                .font(.body.weight(.semibold))
                .foregroundStyle(ShareColor.accent)
                .frame(width: 36, height: 36)
                .background(ShareColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: source.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ShareColor.label)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let size {
                    Text(verbatim: size)
                        .font(.subheadline)
                        .foregroundStyle(ShareColor.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: ShareMetrics.touchTarget)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bouton du bas

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .loading:
            EmptyView()
        case .ready, .saving:
            primaryButton(action: { Task { await model.prepare() } }) {
                if model.phase == .saving {
                    HStack(spacing: 8) {
                        ProgressView().tint(ShareColor.onInk)
                        Text("Préparation…")
                    }
                } else {
                    Text("Préparer dans SignalQuest")
                }
            }
            .disabled(model.phase == .saving)
        case .done, .failed:
            primaryButton(action: { model.finish() }) { Text("OK") }
        }
    }

    private func primaryButton<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.body.weight(.semibold))
                .foregroundStyle(ShareColor.onInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 16)
                .background(ShareColor.label, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Domaine du lien, sans « www. » ; le lien entier n'est pas montré.
    static func displayHost(of url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
