import SwiftUI

/// Carte d'un test d'expérience (`kind = experience`) : vidéo, page web, jeu et
/// envoi, lus dans `metadata.experience.highlights` et mis en forme dans la
/// langue de l'app. Le texte français du post ne sert qu'aux anciennes versions.
struct ExperienceCardView: View {
    let item: UnifiedSocialFeedItem
    let experience: FeedExperience
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    var onReact: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                // Jamais de ville : le contrat ne la montre qu'à l'auteur, dans le détail.
                CardHeader(
                    author: item.author,
                    place: nil,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                FeedKindLine(symbol: "play.rectangle", title: String(localized: "Test d’expérience"), points: item.earnedPoints)

                // Ce que la connexion permet, une ligne par usage mesuré, sans score :
                // les notes restent dans le détail (refonte du 04/11).
                let rows = experience.highlights.feedRows
                if rows.isEmpty {
                    // Publié sans aucune des valeurs (lecture sans score, envoi vidéo seul).
                    Text("Les mesures de ce test sont dans son détail.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: SQSpace.sm) {
                        ForEach(rows, id: \.title) { row in
                            ExperienceFeedRowView(row: row)
                        }
                    }
                }

                if experience.connectionType == "wifi" {
                    FeedNetworkLine(operator: nil, technology: "WIFI")
                } else {
                    FeedNetworkLine(operator: experience.operatorKey, technology: experience.technology)
                }

                FeedOpenCapsule(title: String(localized: "Voir le détail"), onOpenPost: onTap)

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

}

extension FeedExperience {
    /// « Orange · 5G », « Wi-Fi », ou rien quand le réseau n'est pas connu.
    var networkContext: String? {
        switch connectionType {
        case "wifi":
            return String(localized: "Wi-Fi")
        case "cellular":
            let parts = [operatorKey.map { SQBrand.operatorName($0) ?? $0 }, technology].compactMap { $0 }
            return parts.isEmpty ? String(localized: "Réseau mobile") : parts.joined(separator: " · ")
        default:
            return nil
        }
    }
}

extension ExperienceHighlights {
    /// Une tuile par valeur mesurée, jamais de tiret : un test absent n'a pas de tuile.
    var feedMetrics: [FeedMetricGrid.Metric] {
        var metrics: [FeedMetricGrid.Metric] = []
        // Seulement la note servie : un post antérieur au barème n'en a pas, et le fil ne recalcule rien.
        if let overall = scores?.overall { metrics.append(.init(label: "Note globale", value: "\(overall)/100")) }
        if let videoMaxQualityLabel { metrics.append(.init(label: "Vidéo sans coupure", value: videoMaxQualityLabel)) }
        if let videoScore { metrics.append(.init(label: "Score vidéo", value: "\(videoScore)/100")) }
        if let pageMedianMs { metrics.append(.init(label: "Page web", value: Self.duration(pageMedianMs))) }
        // Une ouverture TCP (apps) et un aller-retour HTTP (web) ne se comparent pas :
        // la tuile dit de quelle mesure il s'agit (contrat, §4).
        if let gameMedianMs {
            let label = gameIsHTTPRoundTrip ? "Jeu et appels · navigateur" : "Jeu et appels · app"
            metrics.append(.init(label: label, value: ExperiencePresentation.format(.ms, .int(gameMedianMs), .current)))
        }
        if let uploadPhotoMs { metrics.append(.init(label: "Envoi photo", value: Self.duration(uploadPhotoMs))) }
        if !metrics.isEmpty { metrics[0].highlight = true }
        return metrics
    }

    /// La règle `duration` de presentation-v1, comme la carte du web : U+00A0 avant l'unité.
    private static func duration(_ ms: Int) -> String { ExperiencePresentation.format(.duration, .int(ms), .current) }

    /// 850 ms, puis 2,1 s au-delà d'une seconde, arrondi demi vers le haut en entiers
    /// comme l'image de partage (méthode §10) : 1 250 ms → 1,3 s.
    static func waitingTime(_ ms: Int) -> String {
        guard ms >= 1000 else { return "\(ms) ms" }
        let tenths = (ms + 50) / 100
        return "\((Double(tenths) / 10).formatted(.number.precision(.fractionLength(1)))) s"
    }
}

extension ExperienceTestKind {
    /// Clé de catalogue : `SQFactRow` traduit son libellé.
    var title: String {
        switch self {
        case .videoLadder: return "Vidéo par paliers"
        case .videoAdaptive: return "Vidéo adaptative"
        case .webPage: return "Ouverture de pages"
        case .gameAndCalls: return "Jeu et appels"
        case .upload: return "Envoi de fichiers"
        }
    }

    static func stateLabel(_ state: String) -> String {
        switch state {
        case "measured": return String(localized: "Mesuré")
        case "not_tested": return String(localized: "Non testé")
        case "interrupted": return String(localized: "Interrompu")
        default: return String(localized: "Échec")
        }
    }
}

/// Une ligne de la carte d'un test d'expérience : l'usage, ce qu'il dit, la valeur.
struct ExperienceFeedRow: Equatable {
    let symbol: String
    let title: String
    let caption: String
    let value: String
}

extension ExperienceHighlights {
    /// Ce que la connexion permet, sans score : une ligne par valeur mesurée.
    var feedRows: [ExperienceFeedRow] {
        var rows: [ExperienceFeedRow] = []
        if let videoMaxQualityLabel {
            rows.append(.init(symbol: "play.rectangle", title: String(localized: "Vidéo"),
                              caption: String(localized: "sans coupure jusqu’à"), value: videoMaxQualityLabel))
        }
        if let pageMedianMs {
            rows.append(.init(symbol: "globe", title: String(localized: "Pages web"),
                              caption: String(localized: "affichées en"), value: Self.feedDuration(pageMedianMs)))
        }
        if let gameMedianMs {
            // Une ouverture TCP (apps) et un aller-retour HTTP (web) ne se comparent pas (contrat, §4).
            rows.append(.init(symbol: "gamecontroller", title: String(localized: "Jeu et appels"),
                              caption: gameIsHTTPRoundTrip ? String(localized: "réponse, navigateur") : String(localized: "réponse, app"),
                              value: ExperiencePresentation.format(.ms, .int(gameMedianMs), .current)))
        }
        if let uploadPhotoMs {
            rows.append(.init(symbol: "arrow.up.circle", title: String(localized: "Envoi photo"),
                              caption: String(localized: "terminé en"), value: Self.feedDuration(uploadPhotoMs)))
        }
        return rows
    }

    private static func feedDuration(_ ms: Int) -> String { ExperiencePresentation.format(.duration, .int(ms), .current) }
}

struct ExperienceFeedRowView: View {
    let row: ExperienceFeedRow

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: row.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(width: 28, height: 28)
                .background(SQColor.surface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title)
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.label)
                Text(verbatim: row.caption)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SQSpace.sm)
            Text(verbatim: row.value)
                .font(SQFont.display(18, .bold, relativeTo: .headline))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm2)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.title), \(row.caption) \(row.value)"))
        .accessibilityIdentifier("feed.experience.row")
    }
}
