import SwiftUI

/// Specialised feed card for `kind = validation` : l'identifiant trouvé, la
/// méthode et le nombre de confirmations. PCI, Cell, bande et secteurs restent dans le
/// détail (lot F : résumé radio au fil, détail ailleurs).
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.success,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            validationHeading
                            SQEditorialTag(text: signal?.technology ?? "—", color: accent)
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            validationHeading
                            Spacer()
                            SQEditorialTag(text: signal?.technology ?? "—", color: accent)
                        }
                    }
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                FeedMetricGrid(metrics: metrics)

                if let count = signal?.validationCount, count > 0 {
                    Text("\(count) confirmations")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let text = item.cardText {
                    Text(text)
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

    private var validationHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Identification antenne")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(subtitle)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Libellé de la tuile identifiant selon le type d'identification.
    private var identifierTileLabel: String {
        switch signal?.identifierType?.lowercased() {
        case "enb": return "eNB"
        case "gnb": return "gNB"
        case "pci": return "PCI"
        case "cellid", "ci": return "Cell"
        default: return String(localized: "Ident.")
        }
    }

    /// Méthode d'identification lisible (Auto / Manuel / Import), nil si inconnue.
    private var identifierMethodLabel: String? {
        switch signal?.identifierSource?.lowercased() {
        case "auto": return "Auto"
        case "manual", "manuel": return String(localized: "Manuel")
        // Imports de logs externes (NetMonster, eNB Analytics…) : provenance honnête.
        case .some(let s) where s.contains("sync") || s.contains("import"): return "Import"
        default: return nil
        }
    }

    private var subtitle: String {
        [signal?.siteLabel, signal?.operator, signal?.frequency]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Identifiant, puis la méthode quand on la connaît.
    private var metrics: [FeedMetricGrid.Metric] {
        var metrics = [FeedMetricGrid.Metric(
            label: identifierTileLabel, value: signal?.identifierValue ?? signal?.cellId ?? "—", highlight: true
        )]
        if let method = identifierMethodLabel {
            metrics.append(.init(label: "Méthode", value: method))
        }
        return metrics
    }
}
