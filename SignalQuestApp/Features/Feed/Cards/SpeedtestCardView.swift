import SwiftUI

/// Specialised feed card for `kind = speedtest`. Mirrors the Android layout:
/// Down / Up / Ping / RSRP in a 4-tile grid with the operator + tech badge.
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

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology) }

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
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }

                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    CardMetricTile(label: "Down", value: SignalFormatters.speed(signal?.downloadMbps), highlight: true, accent: accent)
                    CardMetricTile(label: "Up", value: SignalFormatters.speed(signal?.uploadMbps))
                    CardMetricTile(label: "Ping", value: SignalFormatters.ms(signal?.pingMs))
                    CardMetricTile(label: signal?.rsrp == nil ? "Tech" : "RSRP", value: signal?.rsrp == nil ? (signal?.technology ?? "—") : SignalFormatters.dbm(signal?.rsrp))
                }

                if let footer = footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelTertiary)
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
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
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 4)
    }

    private var subtitle: String {
        [signal?.operator, signal?.deviceModel]
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
