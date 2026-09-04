import SwiftUI

/// Specialised feed card for `kind = speedtest`. Mirrors the Android layout:
/// Réception / Envoi / Ping / RSRP dans une grille 2×2 lisible avec unités.
struct SpeedtestCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signal: SocialSignalSummary? { item.signal }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: "Speedtest",
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap
                )

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("feed.speedtest.subtitle")
                }

                // Deux colonnes : quatre tuiles serrées rendaient les libellés
                // et unités illisibles sur iPhone. Une mesure reste toujours
                // compréhensible hors contexte et par VoiceOver.
                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    CardMetricTile(label: "Réception", value: SignalFormatters.speed(signal?.downloadMbps), highlight: true)
                    CardMetricTile(label: "Envoi", value: SignalFormatters.speed(signal?.uploadMbps))
                    CardMetricTile(label: "Ping", value: SignalFormatters.ms(signal?.pingMs))
                    CardMetricTile(
                        label: signal?.rsrp == nil ? "Technologie" : "RSRP",
                        value: signal?.rsrp == nil ? (signal?.technology ?? "—") : SignalFormatters.dbm(signal?.rsrp)
                    )
                }

                if let footer = footer {
                    Text(footer)
                        .font(SQFont.body(12.5, relativeTo: .footnote))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare,
                    onReact: onReact
                )
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var subtitle: String {
        [
            signal?.servingOperator ?? signal?.operator,
            signal?.isRoaming == true ? signal?.simOperator.map { "SIM \($0)" } : nil,
            signal?.deviceModel,
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var footer: String? {
        var parts: [String] = []
        if let jitter = signal?.jitterMs { parts.append("Jitter \(Int(jitter)) ms") }
        if let server = signal?.serverName { parts.append("Serveur \(server)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
