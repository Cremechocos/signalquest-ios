import SwiftUI

/// Specialised feed card for `kind = coverage` (or `session`) : Distance /
/// Durée / Mesures / Signal moy. Une mesure isolée montre sa techno et son
/// signal ; Cell et PCI restent dans le détail (lot F).
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology ?? bestDetectedTech) }
    private var hasSessionAggregate: Bool {
        signal?.distanceMeters != nil || signal?.pointsCount != nil
    }

    /// Meilleure génération détectée (5G > 4G > 3G > 2G) plutôt que le premier élément
    /// du tableau (ordre arbitraire) : une session 5G NSA détecte « 4G » ET « 5G » — il ne
    /// faut pas afficher « 4G ». Sert de repli quand le backend n'expose pas `technology`.
    private var bestDetectedTech: String? {
        signal?.detectedTechs.max { Self.generationRank($0) < Self.generationRank($1) }
    }

    private static func generationRank(_ tech: String) -> Int {
        let t = tech.uppercased()
        if t.contains("5G") || t.contains("NR") { return 5 }
        if t.contains("4G") || t.contains("LTE") { return 4 }
        if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return 3 }
        if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return 2 }
        return 0
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            coverageHeading
                            techTag
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            coverageHeading
                            Spacer()
                            techTag
                        }
                    }
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                FeedMetricGrid(metrics: metrics)

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

    private var metrics: [FeedMetricGrid.Metric] {
        guard hasSessionAggregate else {
            return [
                .init(label: "Tech", value: signal?.technology ?? "—", highlight: true),
                .init(label: "Signal", value: SignalFormatters.dbm(signal?.averageSignalDbm ?? signal?.rsrp))
            ]
        }
        return [
            .init(label: "Distance", value: SignalFormatters.meters(signal?.distanceMeters), highlight: true),
            .init(label: "Durée", value: SignalFormatters.duration(signal?.durationSeconds)),
            // Des points de mesure, pas des points de jeu (F-18).
            .init(label: "Mesures", value: signal?.pointsCount.map(String.init) ?? "—"),
            // « moy. » ne reprend jamais un RSRP ponctuel : sans moyenne, le tiret.
            .init(label: "Signal moy.", value: SignalFormatters.dbm(signal?.averageSignalDbm))
        ]
    }

    /// Déjà dite par le sous-titre (« 4G / 5G NSA »), la technologie de la
    /// pastille n'est pas relue par VoiceOver (lot F, F-49).
    private var techTag: some View {
        let tech = signal?.technology ?? bestDetectedTech ?? "—"
        return SQEditorialTag(text: tech, color: accent)
            .accessibilityHidden(subtitle.contains(tech))
    }

    private var coverageHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasSessionAggregate ? "Session de couverture" : "Mesure de couverture")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(subtitle)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mesures et distance sont déjà dans les tuiles : le sous-titre dit les
    /// technologies rencontrées (F-18).
    private var subtitle: String {
        var parts: [String] = []
        if !hasSessionAggregate {
            if let op = signal?.operator { parts.append(op) }
            if let tech = signal?.technology { parts.append(tech) }
        }
        let techs = signal?.detectedTechs.prefix(3).joined(separator: " / ") ?? ""
        if !techs.isEmpty && hasSessionAggregate { parts.append(techs) }
        return parts.joined(separator: " · ").nonEmpty ?? String(localized: "Parcours radio")
    }

    private var footer: String? {
        var parts: [String] = []
        if let min = signal?.minSignalDbm, let max = signal?.maxSignalDbm {
            // « de -118 à -81 dBm » : le plus faible puis le plus fort (F-18).
            parts.append(String(localized: "Signal de \(Int(min.rounded())) à \(SignalFormatters.dbm(max))"))
        } else if let avg = signal?.averageSignalDbm {
            parts.append(String(localized: "Signal \(SignalFormatters.dbm(avg))"))
        }
        // Le modèle d'appareil n'apprend rien aux autres : il reste dans le
        // détail de ses propres publications (lot F, F-05).
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
