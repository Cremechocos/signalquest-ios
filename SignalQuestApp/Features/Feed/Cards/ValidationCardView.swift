import SwiftUI

/// Specialised feed card for `kind = validation`. Mirrors Android layout:
/// Ident. / PCI / Cell / Band with the operator + tech badge.
struct ValidationCardView: View {
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
                    kindBadge: "Validation",
                    kindColor: SQColor.success,
                    onAuthorTap: onAuthorTap
                )

                HStack(alignment: .center, spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identification antenne")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        Text(subtitle)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    SQEditorialTag(text: signal?.technology ?? "—", color: accent)
                }

                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    CardMetricTile(
                        label: "Ident.",
                        value: signal?.identifierValue ?? signal?.cellId ?? "—",
                        highlight: true,
                        accent: accent
                    )
                    CardMetricTile(label: "PCI", value: signal?.pci.map(String.init) ?? "—")
                    CardMetricTile(label: "Cell", value: signal?.cellId ?? "—")
                    CardMetricTile(label: "Bande", value: signal?.band ?? "—")
                }

                if let footer = footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelTertiary)
                        .lineLimit(2)
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
        [signal?.siteLabel, signal?.operator, signal?.frequency]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var footer: String? {
        var parts: [String] = []
        if let type = signal?.identifierType { parts.append("Type \(type.uppercased())") }
        if let sectors = signal?.sectors, !sectors.isEmpty {
            parts.append("Secteurs " + sectors.prefix(3).map(String.init).joined(separator: " / "))
        }
        if let count = signal?.validationCount { parts.append("\(count) confirmations") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
