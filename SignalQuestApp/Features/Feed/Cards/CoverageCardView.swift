import SwiftUI

/// Specialised feed card for `kind = coverage` (or `session`). Mirrors the
/// Android session card: Distance / Durée / Points / Signal moy.
struct CoverageCardView: View {
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
    private var accent: Color { TechAccent.color(for: signal?.technology ?? signal?.detectedTechs.first) }
    private var hasSessionAggregate: Bool {
        signal?.distanceMeters != nil || signal?.pointsCount != nil
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: hasSessionAggregate ? "Couverture" : "Mesure",
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap
                )

                HStack(alignment: .center, spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasSessionAggregate ? "Session de couverture" : "Mesure de couverture")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        Text(subtitle)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    SQEditorialTag(text: signal?.technology ?? signal?.detectedTechs.first ?? "—", color: accent)
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    if hasSessionAggregate {
                        CardMetricTile(label: "Distance", value: SignalFormatters.meters(signal?.distanceMeters), highlight: true)
                        CardMetricTile(label: "Durée", value: SignalFormatters.duration(signal?.durationSeconds))
                        CardMetricTile(label: "Points", value: signal?.pointsCount.map(String.init) ?? "—")
                        CardMetricTile(label: "Signal moy.", value: SignalFormatters.dbm(signal?.averageSignalDbm ?? signal?.rsrp))
                    } else {
                        CardMetricTile(label: "Tech", value: signal?.technology ?? "—", highlight: true)
                        CardMetricTile(label: "Signal", value: SignalFormatters.dbm(signal?.averageSignalDbm ?? signal?.rsrp))
                        CardMetricTile(label: "Cell", value: signal?.cellId ?? "—")
                        CardMetricTile(label: "PCI", value: signal?.pci.map(String.init) ?? "—")
                    }
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
                        .lineSpacing(3)
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
        var parts: [String] = []
        if let count = signal?.pointsCount, hasSessionAggregate { parts.append("\(count) pts") }
        if let distance = signal?.distanceMeters, hasSessionAggregate { parts.append(SignalFormatters.meters(distance)) }
        if !hasSessionAggregate {
            if let op = signal?.operator { parts.append(op) }
            if let tech = signal?.technology { parts.append(tech) }
        }
        let techs = signal?.detectedTechs.prefix(3).joined(separator: " / ") ?? ""
        if !techs.isEmpty && hasSessionAggregate { parts.append(techs) }
        return parts.joined(separator: " · ").nonEmpty ?? "Parcours radio"
    }

    private var footer: String? {
        var parts: [String] = []
        if let min = signal?.minSignalDbm, let max = signal?.maxSignalDbm {
            parts.append("Signal \(SignalFormatters.dbm(min)) / \(SignalFormatters.dbm(max))")
        } else if let avg = signal?.averageSignalDbm {
            parts.append("Signal \(SignalFormatters.dbm(avg))")
        }
        if let device = signal?.deviceModel { parts.append("Appareil \(device)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
