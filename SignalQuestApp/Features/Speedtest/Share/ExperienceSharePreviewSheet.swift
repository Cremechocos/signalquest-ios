import SwiftUI
import UIKit

/// Ce qu'il faut pour dessiner l'image d'un test d'expérience : le JSON du contrat, les notes
/// (servies d'abord) et le contexte affichable.
struct ExperienceShareInput: Identifiable {
    let id = UUID()
    let tests: [String: Any]
    let scores: ExperienceScores
    let measuredAt: Date
    let connectionType: String
    let technology: String?
    let operatorKey: String?
}

private struct ExperienceShareOptions: Equatable, Hashable {
    var includeNetwork = true
    var includeTimestamp = true
}

/// Prévisualisation fidèle du PNG d'un test d'expérience, sur le modèle du partage speedtest :
/// les notes et les phrases restent toujours visibles, le réseau et la date se retirent.
struct ExperienceSharePreviewSheet: View {
    let input: ExperienceShareInput

    @Environment(\.dismiss) private var dismiss
    @State private var options = ExperienceShareOptions()
    @State private var rendered: (options: ExperienceShareOptions, image: UIImage)?
    @State private var isPreparingShare = false
    @State private var shareError = false
    @State private var sharePayload: ExperienceSharePayload?
    @State private var temporaryShareURL: URL?

    private var currentImage: UIImage? {
        guard rendered?.options == options else { return nil }
        return rendered?.image
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    MessageSheetHeader(
                        title: "Vérifier le partage",
                        subtitle: String(localized: "Les notes et les résultats restent visibles. Désactive les détails que tu ne souhaites pas publier."),
                        closeIdentifier: "experience.share.close",
                        onClose: { dismiss() }
                    )
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
                            keyPath: \.includeNetwork
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
        .task(id: options) { await renderPreview(options) }
        .sheet(item: $sharePayload, onDismiss: removeTemporaryShareFile) { payload in
            ShareSheet(items: payload.items) {
                Task { @MainActor in
                    sharePayload = nil
                    removeTemporaryShareFile()
                }
            }
        }
        .onDisappear {
            if sharePayload == nil { removeTemporaryShareFile() }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .fill(SQColor.surfaceMuted)
            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Aperçu de l’image du test d’expérience à partager")
                    .accessibilityIdentifier("experience.share.preview.image")
            } else {
                ProgressView("Création de l’aperçu")
                    .tint(SQColor.brandRed)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .aspectRatio(1_200.0 / 630.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("experience.share.preview")
    }

    private func optionRow(
        title: String, description: String, systemImage: String,
        keyPath: WritableKeyPath<ExperienceShareOptions, Bool>
    ) -> some View {
        Toggle(isOn: Binding(get: { options[keyPath: keyPath] }, set: { options[keyPath: keyPath] = $0 })) {
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
            GradientButton("Partager", systemImage: "square.and.arrow.up", isBusy: isPreparingShare, style: .primary,
                           action: prepareSystemShare)
                .disabled(currentImage == nil)
                .accessibilityHint("Ouvre la feuille de partage avec l’image affichée.")
                .accessibilityIdentifier("experience.share.send")
            if shareError {
                Text("Impossible de préparer le partage.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.danger)
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md)
        .background(SQColor.bg)
        .sqReadableWidth()
    }

    @MainActor
    private func renderPreview(_ request: ExperienceShareOptions) async {
        shareError = false
        // Plusieurs interrupteurs basculés vite : un seul rendu 2400 × 1260.
        guard (try? await Task.sleep(nanoseconds: 120_000_000)) != nil, !Task.isCancelled else { return }
        let network = request.includeNetwork
            ? ExperienceShareCardBuilder.networkLine(
                connectionType: input.connectionType, technology: input.technology, operatorKey: input.operatorKey)
            : nil
        let model = ExperienceShareCardBuilder.model(
            tests: input.tests, scores: input.scores,
            measuredAt: request.includeTimestamp ? input.measuredAt : nil, network: network
        )
        let image = ExperienceShareCardBuilder.renderImage(model)
        guard !Task.isCancelled else { return }
        rendered = (request, image)
    }

    @MainActor
    private func prepareSystemShare() {
        guard !isPreparingShare, let image = currentImage else { return }
        isPreparingShare = true
        shareError = false
        do {
            removeTemporaryShareFile()
            let url = try SQShareCardBuilder.writePNG(image)
            temporaryShareURL = url
            let text = input.scores.overall.map { String(localized: "Test d’expérience SignalQuest · note globale \($0)/100") }
                ?? String(localized: "Test d’expérience SignalQuest")
            sharePayload = ExperienceSharePayload(items: [ImageAndTextShareItem(fileURL: url, text: text, title: text), text])
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

private struct ExperienceSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}
