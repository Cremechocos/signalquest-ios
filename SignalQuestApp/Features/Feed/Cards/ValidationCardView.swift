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
                    place: nil, // La commune est sous le titre, avec le secteur.
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.success,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                FeedKindLine(symbol: "checkmark", title: String(localized: "Antenne identifiée"), tint: .success,
                             points: item.earnedPoints)

                // Le support identifié en titre, sans identifiant brut : eNB, PCI et
                // Cell restent dans le détail (refonte du 04/11).
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text(verbatim: title)
                        .font(SQFont.display(20, .bold, relativeTo: .title3))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let placeLine {
                        Text(verbatim: placeLine)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                FeedNetworkLine(operator: signal?.operator, technology: signal?.technology, detail: frequency)

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

                if let key = item.siteKey {
                    FeedOpenCapsule(title: String(localized: "Voir sur la carte"), symbol: "map",
                                    destination: .link(.site(id: key.siteId, market: key.market, operatorKey: key.operatorKey)),
                                    onOpenPost: onTap)
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

    /// Le nom du support, sinon « Antenne Orange identifiée ».
    private var title: String {
        if let siteName { return siteName }
        if let op = signal?.operator.map({ SQBrand.operatorName($0) ?? $0 }) {
            return String(localized: "Antenne \(op) identifiée")
        }
        return String(localized: "Antenne identifiée")
    }

    /// Commune et secteur identifié : ce que l'identification a apporté.
    private var placeLine: String? {
        let sector = item.metadataString("sector") ?? signal?.sectors?.first.map(String.init)
        let parts = [signal?.city ?? item.readablePlaceLabel,
                     sector.map { String(localized: "secteur \($0) identifié") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var frequency: String? {
        guard let raw = signal?.frequency?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return Double(raw) != nil ? "\(raw) MHz" : raw
    }

    /// Nom du site identifié, s'il dit autre chose que la commune.
    private var siteName: String? {
        let city = signal?.city?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [signal?.siteName, signal?.siteLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != city }
    }
}
