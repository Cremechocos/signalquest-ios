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
    @State private var isPreparingShare = false
    @State private var shareError = false
    @State private var sharePayload: PreviewSharePayload?
    @State private var temporaryShareURL: URL?

    private var currentImage: UIImage? {
        guard renderedPreview?.options == options else { return nil }
        return renderedPreview?.image
    }

    private var renderRequest: RenderRequest {
        RenderRequest(options: options)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    preview

                    Text("Détails inclus")
                        .font(SQFont.body(12, .bold, relativeTo: .caption))
                        .tracking(12 * 0.16)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.xs)
                        .padding(.bottom, -SQSpace.sm)
                        .sqHeader()

                    VStack(spacing: 0) {
                        optionRow(
                            title: "Réseau utilisé",
                            description: "Opérateur et technologie. Le nom du Wi-Fi n’est jamais partagé.",
                            systemImage: "antenna.radiowaves.left.and.right",
                            keyPath: \.includeNetworkContext
                        )
                        Divider().overlay(SQColor.separator).padding(.leading, 48)
                        optionRow(
                            title: "Ville approximative",
                            description: "La commune du test, jamais les coordonnées exactes.",
                            systemImage: "location.fill",
                            keyPath: \.includeApproximateLocation
                        )
                        Divider().overlay(SQColor.separator).padding(.leading, 48)
                        optionRow(
                            title: "Modèle du téléphone",
                            description: "Le nom commercial, jamais l’identifiant technique.",
                            systemImage: "iphone",
                            keyPath: \.includeDevice
                        )
                        Divider().overlay(SQColor.separator).padding(.leading, 48)
                        optionRow(
                            title: "Serveur de mesure",
                            description: "Le serveur réellement utilisé par le test.",
                            systemImage: "server.rack",
                            keyPath: \.includeServerDetails
                        )
                        Divider().overlay(SQColor.separator).padding(.leading, 48)
                        optionRow(
                            title: "Date et heure",
                            description: "L’horodatage local du test.",
                            systemImage: "calendar.badge.clock",
                            keyPath: \.includeTimestamp
                        )
                    }
                    .padding(.horizontal, SQSpace.cardPadding)
                    .sqCardBackground()
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
                .sqReadableWidth()
            }

            Divider()
            actionBar
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
        MessageSheetHeader(
            title: "Vérifier le partage",
            subtitle: String(localized: "Le résultat, les graphes et la latence restent visibles. Désactive les détails que tu ne souhaites pas publier."),
            closeIdentifier: "speedtest.share.close",
            onClose: { dismiss() }
        )
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
            } else {
                ProgressView("Création de l’aperçu")
                    .tint(SQColor.brandRed)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .aspectRatio(1_200.0 / 630.0, contentMode: .fit)
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
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: systemImage, size: 34, tint: SQColor.accentInk, fill: SQColor.accentSoft)
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
        .padding(.vertical, SQSpace.sm)
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
            .disabled(currentImage == nil)
            .accessibilityHint("Ouvre la feuille de partage avec l’image affichée.")

            if shareError {
                Text("Impossible de préparer le partage.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.danger)
                    .accessibilityLabel("Impossible de préparer le partage.")
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.md)
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
        } catch {
            // Seule l'annulation (changement d'option) peut interrompre le rendu.
            return
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
            let title = String(localized: "Speedtest SignalQuest — \(SQUnits.throughput(mbps: result.downloadAverageMbps))")
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
}

private struct RenderedPreview {
    let options: SpeedtestShareOptions
    let image: UIImage
}

private struct PreviewSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}
