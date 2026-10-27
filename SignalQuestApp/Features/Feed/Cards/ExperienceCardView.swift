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

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            heading
                            techTag
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            heading
                            Spacer()
                            techTag
                        }
                    }
                }

                let metrics = experience.highlights.feedMetrics
                if metrics.isEmpty {
                    // Publié sans aucune des cinq valeurs (lecture sans score, envoi vidéo seul).
                    Text("Les mesures de ce test sont dans son détail.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FeedMetricGrid(metrics: metrics)
                }

                if let note = experience.highlights.gameMethodNote {
                    Text(note)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
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

    @ViewBuilder
    private var techTag: some View {
        if let tech = experience.technology {
            SQEditorialTag(text: tech, color: TechAccent.color(for: tech))
                .accessibilityHidden(true)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Test d’expérience")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            if let context = experience.networkContext {
                Text(verbatim: context)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        if let videoMaxQualityLabel { metrics.append(.init(label: "Vidéo sans coupure", value: videoMaxQualityLabel)) }
        if let videoScore { metrics.append(.init(label: "Score vidéo", value: "\(videoScore)/100")) }
        if let pageMedianMs { metrics.append(.init(label: "Page web", value: Self.waitingTime(pageMedianMs))) }
        if let gameMedianMs { metrics.append(.init(label: "Jeu et appels", value: "\(gameMedianMs) ms")) }
        if let uploadPhotoMs { metrics.append(.init(label: "Envoi photo", value: Self.waitingTime(uploadPhotoMs))) }
        if !metrics.isEmpty { metrics[0].highlight = true }
        return metrics
    }

    /// Une ouverture TCP (apps) et un aller-retour HTTP (web) ne se comparent pas :
    /// la carte dit toujours de quelle mesure il s'agit (contrat, §4).
    var gameMethodNote: String? {
        guard gameMedianMs != nil else { return nil }
        return gameIsHTTPRoundTrip
            ? String(localized: "Jeu et appels : aller-retour web depuis un navigateur, à ne pas comparer à une mesure d’app.")
            : String(localized: "Jeu et appels : temps d’ouverture d’une connexion vers un serveur de jeu.")
    }

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
