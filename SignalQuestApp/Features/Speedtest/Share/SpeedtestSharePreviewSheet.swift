import SwiftUI
import UIKit

/// Prévisualisation fidèle du PNG Speedtest et choix des métadonnées publiées.
///
/// Les débits, graphes et latences restent toujours visibles. Seuls les groupes
/// contextuels peuvent être masqués. iOS n'expose pas de mesures RF fiables du
/// réseau servant : l'option radio commune au contrat n'est donc pas affichée et
/// aucune donnée SIM n'est présentée comme une mesure radio.
struct SpeedtestSharePreviewSheet: View {
    let result: SpeedtestRunResult
    let theme: SQShareCardTheme

    @Environment(\.dismiss) private var dismiss
    @State private var options = SpeedtestShareOptions()
    @State private var renderedPreview: RenderedPreview?
    @State private var renderFailedFor: SpeedtestShareOptions?
    @State private var renderAttempt = 0
    @State private var isPreparingShare = false
    @State private var shareError = false
    @State private var sharePayload: PreviewSharePayload?
    @State private var temporaryShareURL: URL?

    private var currentImage: UIImage? {
        guard renderedPreview?.options == options else { return nil }
        return renderedPreview?.image
    }

    private var renderingFailed: Bool {
        renderFailedFor == options
    }

    private var renderRequest: RenderRequest {
        RenderRequest(options: options, attempt: renderAttempt)
    }

    var body: some View {
        VStack(spacing: 0) {
            SQSheetHandle()

            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    preview

                    Text("Détails inclus")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 0) {
                        optionRow(
                            title: "Réseau utilisé",
                            description: "Opérateur et technologie. Le nom du Wi-Fi n’est jamais partagé.",
                            systemImage: "antenna.radiowaves.left.and.right",
                            keyPath: \.includeNetworkContext
                        )
                        Divider().padding(.leading, 48)
                        optionRow(
                            title: "Ville approximative",
                            description: "La commune du test, jamais les coordonnées exactes.",
                            systemImage: "location.fill",
                            keyPath: \.includeApproximateLocation
                        )
                        Divider().padding(.leading, 48)
                        optionRow(
                            title: "Modèle du téléphone",
                            description: "Le nom commercial, jamais l’identifiant technique.",
                            systemImage: "iphone",
                            keyPath: \.includeDevice
                        )
                        Divider().padding(.leading, 48)
                        optionRow(
                            title: "Serveur de mesure",
                            description: "Le serveur réellement utilisé par le test.",
                            systemImage: "server.rack",
                            keyPath: \.includeServerDetails
                        )
                        Divider().padding(.leading, 48)
                        optionRow(
                            title: "Date et heure",
                            description: "L’horodatage local du test.",
                            systemImage: "calendar.badge.clock",
                            keyPath: \.includeTimestamp
                        )
                    }
                    .padding(.horizontal, SQSpace.lg)
                    .background(
                        SQColor.surface,
                        in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    )
                }
                .padding(.horizontal, SQSpace.xl)
                .padding(.bottom, SQSpace.xl)
                .sqReadableWidth()
            }

            Divider()
            actionBar
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackgroundCompat(SQColor.bg)
        .task(id: renderRequest) {
            await renderPreview(for: renderRequest)
        }
        .sheet(item: $sharePayload, onDismiss: removeTemporaryShareFile) { payload in
            ShareSheet(items: payload.items) {
                Task { @MainActor in
                    sharePayload = nil
                    removeTemporaryShareFile()
                }
            }
        }
        .onDisappear {
            if sharePayload == nil {
                removeTemporaryShareFile()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Vérifier le partage")
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Text("Le résultat, les graphes et la latence restent visibles. Désactive les détails que tu ne souhaites pas publier.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .fill(SQColor.surfaceMuted)

            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Aperçu de l’image Speedtest à partager")
                    .accessibilityIdentifier("speedtest.share.preview.image")
            } else if renderingFailed {
                VStack(spacing: SQSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(SQColor.warning)
                        .accessibilityHidden(true)
                    Text("Impossible de créer l’aperçu.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                    Button("Réessayer") {
                        renderAttempt += 1
                    }
                    .font(SQType.button)
                    .frame(minHeight: 44)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView("Création de l’aperçu")
                    .tint(SQColor.brandRed)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .aspectRatio(1_080.0 / 650.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("speedtest.share.preview")
    }

    private func optionRow(
        title: String,
        description: String,
        systemImage: String,
        keyPath: WritableKeyPath<SpeedtestShareOptions, Bool>
    ) -> some View {
        Toggle(isOn: optionBinding(keyPath)) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(LocalizedStringKey(title))
                        .font(SQType.body.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                    Text(LocalizedStringKey(description))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(SQColor.brandRed)
        .frame(minHeight: 64)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityHint(LocalizedStringKey(description))
    }

    private var actionBar: some View {
        VStack(spacing: SQSpace.xs) {
            GradientButton(
                "Partager",
                systemImage: "square.and.arrow.up",
                isBusy: isPreparingShare,
                style: .primary,
                action: prepareSystemShare
            )
            .disabled(currentImage == nil || renderingFailed)
            .accessibilityHint("Ouvre la feuille de partage avec l’image affichée.")

            if shareError {
                Text("Impossible de préparer le partage.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.danger)
                    .accessibilityLabel("Impossible de préparer le partage.")
            }

            Button("Annuler") { dismiss() }
                .font(SQType.button)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.horizontal, SQSpace.xl)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.sm)
        .background(SQColor.bg)
        .sqReadableWidth()
    }

    private func optionBinding(
        _ keyPath: WritableKeyPath<SpeedtestShareOptions, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { options[keyPath: keyPath] = $0 }
        )
    }

    @MainActor
    private func renderPreview(for request: RenderRequest) async {
        renderedPreview = nil
        renderFailedFor = nil
        shareError = false
        do {
            // Un changement rapide de plusieurs interrupteurs ne doit pas lancer
            // autant de rendus 2160×1300. La tâche précédente est annulée avant
            // l'appel Core Graphics.
            try await Task.sleep(nanoseconds: 120_000_000)
            try Task.checkCancellation()
            let image = SQShareCardBuilder.renderImage(
                for: result,
                theme: theme,
                options: request.options
            )
            try Task.checkCancellation()
            renderedPreview = RenderedPreview(options: request.options, image: image)
        } catch is CancellationError {
            return
        } catch {
            renderFailedFor = request.options
        }
    }

    @MainActor
    private func prepareSystemShare() {
        guard !isPreparingShare,
              let preview = renderedPreview,
              preview.options == options else { return }
        isPreparingShare = true
        shareError = false
        do {
            removeTemporaryShareFile()
            let url = try SQShareCardBuilder.writePNG(preview.image)
            temporaryShareURL = url
            let text = SpeedtestShareImageRenderer.shareText(for: result, options: options)
            let title = "Speedtest SignalQuest — \(Int(result.downloadAverageMbps.rounded())) Mbps"
            sharePayload = PreviewSharePayload(
                items: [ImageAndTextShareItem(fileURL: url, text: text, title: title), text]
            )
        } catch {
            shareError = true
        }
        isPreparingShare = false
    }

    @MainActor
    private func removeTemporaryShareFile() {
        guard let url = temporaryShareURL else { return }
        try? FileManager.default.removeItem(at: url)
        temporaryShareURL = nil
    }
}

private struct RenderRequest: Hashable {
    let options: SpeedtestShareOptions
    let attempt: Int
}

private struct RenderedPreview {
    let options: SpeedtestShareOptions
    let image: UIImage
}

private struct PreviewSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}
