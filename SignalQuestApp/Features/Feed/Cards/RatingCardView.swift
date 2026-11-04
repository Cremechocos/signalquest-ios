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

                FeedKindLine(symbol: "star.fill", title: String(localized: "A noté son réseau"), tint: .warning,
                             points: item.earnedPoints)

                // Où l'avis a été donné, et ce qu'il dit, posé sur le point (refonte du 04/11).
                // Sans position servie, les étoiles reviennent en tête.
                if let coordinate = item.cardCoordinate {
                    FeedPlaceSnapshot(cacheKey: item.id, coordinate: coordinate) {
                        FeedMapBubble { verdict(starSize: 17) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: spokenVerdict))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("feed.rating.map")
                } else {
                    verdict(starSize: 22)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: spokenVerdict))
                }

                if !metrics.isEmpty {
                    FeedMetricGrid(metrics: metrics)
                }

                FeedNetworkLine(operator: signal?.operator, technology: signal?.technology, detail: frequency)

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

    /// Les étoiles et leur traduction en mots, de 1 « Très mal » à 5 « Très bien ».
    private func verdict(starSize: CGFloat) -> some View {
        VStack(spacing: SQSpace.xxs) {
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: index <= stars ? "star.fill" : "star")
                        .font(.system(size: starSize, weight: .semibold))
                        .foregroundStyle(index <= stars ? SQColor.warning : SQColor.labelTertiary)
                }
            }
            if let words = Self.starsWords(stars) {
                Text(verbatim: words)
                    .font(SQFont.display(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
            }
        }
    }

    private var spokenVerdict: String {
        [String(localized: "Note \(stars) sur 5"), Self.starsWords(stars)].compactMap { $0 }.joined(separator: ", ")
    }

    /// Les étoiles en mots, communs aux trois apps.
    static func starsWords(_ stars: Int) -> String? {
        switch stars {
        case 1: return String(localized: "Très mal")
        case 2: return String(localized: "Plutôt mal")
        case 3: return String(localized: "Correct")
        case 4: return String(localized: "Plutôt bien")
        case 5: return String(localized: "Très bien")
        default: return nil
        }
    }

    /// Le signal en mots et en dBm, puis la tendance ; rien sans valeur.
    private var metrics: [FeedMetricGrid.Metric] {
        var metrics: [FeedMetricGrid.Metric] = []
        if let quality, let rsrp = signal?.rsrp {
            // Le mot en valeur, le dBm dans le libellé : deux tuiles tiennent sur une rangée.
            metrics.append(.init(label: String(localized: "Signal · \(SignalFormatters.dbm(rsrp))"), value: quality, highlight: true))
        }
        if let trend = trendTag {
            metrics.append(.init(label: String(localized: "Tendance"), value: trend.label))
        }
        return metrics
    }

    /// « 1 800 MHz » quand le serveur la donne en MHz.
    private var frequency: String? {
        guard let raw = signal?.frequency?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return Double(raw) != nil ? "\(raw) MHz" : raw
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
}
