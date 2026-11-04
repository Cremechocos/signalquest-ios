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
                            technologyTag
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            validationHeading
                            Spacer()
                            technologyTag
                        }
                    }
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                if !metrics.isEmpty {
                    FeedMetricGrid(metrics: metrics)
                }

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

    /// Techno trouvée ; rien plutôt qu'un tiret quand le serveur ne la donne pas.
    @ViewBuilder
    private var technologyTag: some View {
        if let technology = signal?.technology?.trimmingCharacters(in: .whitespacesAndNewlines), !technology.isEmpty {
            SQEditorialTag(text: technology, color: accent)
        }
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

    /// Opérateur en toutes lettres et fréquence en MHz ; le lieu est dans l'en-tête.
    private var subtitle: String {
        let frequency = signal?.frequency.map { Double($0) != nil ? "\($0) MHz" : $0 }
        return [signal?.operator.map { SQBrand.operatorName($0) ?? $0 }, frequency]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Nom du site identifié, s'il dit autre chose que la commune de l'en-tête.
    private var siteName: String? {
        let city = signal?.city?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [signal?.siteName, signal?.siteLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != city }
    }

    /// Identifiant, puis la méthode quand on la connaît.
    private var metrics: [FeedMetricGrid.Metric] {
        // Le site plutôt que l'eNB brut ; l'identifiant reste dans le détail et ne
        // sert ici que faute de nom. Identifiant absent : pas de tuile « — » (revue q34, constats 4).
        var metrics: [FeedMetricGrid.Metric] = []
        if let siteName {
            metrics.append(.init(label: String(localized: "Site"), value: siteName, highlight: true))
        } else if let identifier = (signal?.identifierValue ?? signal?.cellId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            metrics.append(.init(label: identifierTileLabel, value: identifier, highlight: true))
        }
        if let method = identifierMethodLabel {
            metrics.append(.init(label: "Méthode", value: method))
        }
        return metrics
    }
}
