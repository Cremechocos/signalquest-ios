import SwiftUI

/// Ce que la carte d'un trajet montre (plan 3, vague 1). Par défaut, le
/// départ et l'arrivée sont retirés : ils disent souvent où l'on habite.
struct DriveShareOptions: Equatable, Hashable {
    var hidesEnds = true
    var showsRoute = true
    var showsOperator = true
}

enum DriveShareCardBuilder {
    /// Avant le rognage des bouts : assez fin pour mesurer les distances, sans
    /// comparer chaque mesure à des milliers de points.
    private static let workingRoutePoints = 2_000

    static func model(
        recap: DriveTestViewModel.SessionRecap,
        trace: DriveShareTrace?,
        options: DriveShareOptions,
        theme: SQShareCardTheme
    ) -> DriveShareCardModel {
        var shown = options.showsRoute ? trace?.thinned(to: workingRoutePoints) : nil
        if options.hidesEnds { shown = shown?.trimmingEnds() }
        let normalized = shown?.thinned().normalized()
        let route = normalized?.route ?? []
        let caption: String?
        if !options.showsRoute {
            caption = String(localized: "Tracé masqué")
        } else if (trace?.route.count ?? 0) < 2 {
            caption = String(localized: "Tracé indisponible")
        } else if route.count < 2 {
            caption = String(localized: "Trajet trop court pour montrer le tracé")
        } else {
            caption = nil
        }

        var stats = [DriveShareCardModel.Stat(label: String(localized: "Distance"),
                                              value: SQUnits.distance(meters: recap.distanceMeters))]
        if let startedAt = recap.startedAt, let duration = durationText(from: startedAt, to: recap.endedAt) {
            stats.append(.init(label: String(localized: "Durée"), value: duration))
        }
        if let average = recap.averageDownloadMbps {
            stats.append(.init(label: String(localized: "Réception moy."), value: mbps(average)))
        }
        if let peak = recap.maxDownloadMbps {
            stats.append(.init(label: String(localized: "Réception max"), value: mbps(peak)))
        }

        var footer = [String(localized: "\(recap.testCount) test")]
        if options.showsOperator, let label = recap.operatorLabel, !label.isEmpty { footer.insert(label, at: 0) }

        return DriveShareCardModel(
            theme: theme,
            title: String(localized: "Drive Test"),
            // Le jour seulement : l'heure n'apporte rien au trajet et situe la personne.
            dateText: recap.endedAt.formatted(date: .abbreviated, time: .omitted),
            route: route,
            measures: normalized?.measures ?? [],
            routeCaption: caption,
            stats: stats,
            footer: footer.joined(separator: " · ")
        )
    }

    static func renderImage(
        recap: DriveTestViewModel.SessionRecap, trace: DriveShareTrace?,
        options: DriveShareOptions, theme: SQShareCardTheme
    ) -> UIImage {
        DriveShareCardRenderer.render(model(recap: recap, trace: trace, options: options, theme: theme))
    }

    private static func mbps(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) Mbps")
    }

    private static func durationText(from start: Date, to end: Date) -> String? {
        let seconds = end.timeIntervalSince(start)
        guard seconds >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds)
    }
}

/// Aperçu et partage de la carte d'un trajet.
struct DriveShareSheet: View {
    let recap: DriveTestViewModel.SessionRecap
    let trace: DriveShareTrace?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var options = DriveShareOptions()
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                                .sqShadowCard()
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Aperçu de la carte du trajet")
                    .accessibilityIdentifier("driveShare.preview")

                    VStack(spacing: 0) {
                        Toggle("Masquer le départ et l’arrivée", isOn: $options.hidesEnds)
                            .disabled(!options.showsRoute)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("driveShare.hidesEnds")
                        Toggle("Montrer le tracé", isOn: $options.showsRoute)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("driveShare.showsRoute")
                        Toggle("Montrer l’opérateur", isOn: $options.showsOperator)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("driveShare.showsOperator")
                    }
                    .font(SQFont.body(15))
                    .tint(SQColor.brandRed)
                    .padding(.horizontal, SQSpace.md)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

                    Text("Le tracé est dessiné sans fond de carte. Retirer le départ et l’arrivée enlève 500 m à chaque bout.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SQSpace.lg)
                .sqReadableWidth()
            }
            .background(SQColor.bg)
            // Barre fixe, comme la carte de partage d'un speedtest : « Partager »
            // restait sous la ligne de flottaison, derrière l'aperçu et les options.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let image {
                    VStack(spacing: 0) {
                        Divider()
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview(Text("Drive Test"), image: Image(uiImage: image))
                        ) {
                            Label("Partager", systemImage: "square.and.arrow.up")
                                .font(SQType.button)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(SQColor.onAccent)
                                .background(SQColor.brandRed, in: Capsule(style: .continuous))
                        }
                        .accessibilityIdentifier("driveShare.share")
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.vertical, SQSpace.md)
                        .sqReadableWidth()
                    }
                    .background(SQColor.bg)
                }
            }
            .navigationTitle("Partager le trajet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task(id: RenderKey(options: options, dark: colorScheme == .dark)) {
            image = DriveShareCardBuilder.renderImage(
                recap: recap, trace: trace, options: options,
                theme: SQShareCardTheme.current(colorScheme: colorScheme)
            )
        }
    }

    private struct RenderKey: Hashable {
        let options: DriveShareOptions
        let dark: Bool
    }
}
