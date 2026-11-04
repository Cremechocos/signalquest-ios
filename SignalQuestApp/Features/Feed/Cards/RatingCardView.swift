import SwiftUI

/// Feed card for `kind = rating` — une évaluation (note en étoiles) d'un signal.
/// Héro = étoiles + tendance, puis contexte antenne (identifiant, RSRP ; la
/// bande reste dans le détail, lot F). N'affiche JAMAIS les notes texte
/// (privées côté serveur).
struct RatingCardView: View {
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
    private var stars: Int { max(0, min(5, signal?.ratingStars ?? 0)) }
    private var accent: Color { TechAccent.color(for: signal?.technology) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.warning,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                // Héro : étoiles + tendance.
                HStack(alignment: .center, spacing: SQSpace.md) {
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { index in
                            Image(systemName: index <= stars ? "star.fill" : "star")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(index <= stars ? SQColor.warning : SQColor.labelTertiary)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Note \(stars) sur 5")
                    Spacer()
                    if let trend = trendTag {
                        SQEditorialTag(text: trend.label, color: trend.color)
                    }
                }

                // Le signal noté, en mots selon l'échelle commune ; la valeur brute
                // est en pied de carte (revue q34, constat 9).
                if let quality {
                    FeedMetricGrid(metrics: [.init(label: String(localized: "Signal"), value: quality, highlight: true)])
                }

                if let footer = footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let text = item.cardText {
                    Text(text)
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

    /// « Moyen » pour −95 dBm en 4G ; rien sans mesure.
    private var quality: String? {
        guard let rsrp = signal?.rsrp else { return nil }
        // Un avis porte toujours un RSRP (4G ou 5G) : la techno, souvent « 4G LTE »,
        // n'a pas à passer par les alias de l'échelle.
        let level = SQQualityScale.Signal(rsrp: rsrp)
        return level == .unknown ? nil : level.label
    }

    private var trendTag: (label: String, color: Color)? {
        switch signal?.ratingTrend?.lowercased() {
        case "improved": return (String(localized: "En hausse"), SQColor.success)
        case "degraded": return (String(localized: "En baisse"), SQColor.danger)
        case "same", "stable": return (String(localized: "Stable"), SQColor.labelSecondary)
        default: return nil
        }
    }

    private var footer: String? {
        var parts: [String] = []
        if let op = signal?.operator { parts.append(SQBrand.operatorName(op) ?? op) }
        if let tech = signal?.technology { parts.append(tech) }
        if let rsrp = signal?.rsrp, quality != nil { parts.append(SignalFormatters.dbm(rsrp)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
