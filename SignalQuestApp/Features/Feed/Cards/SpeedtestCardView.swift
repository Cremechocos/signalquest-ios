import SwiftUI

/// Specialised feed card for `kind = speedtest` : texte, hashtags, puis le
/// bloc de mesure partagé avec la publication ouverte.
struct SpeedtestCardView: View {
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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                // Plus de badge « Speedtest » : le bloc de mesure le dit déjà.
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap
                )

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("feed.post.text")
                }

                if !item.hashtags.isEmpty {
                    CardHashtags(tags: item.hashtags)
                }

                // Un seul bloc : le débit de réception en grand, le reste sur
                // une ligne. Les détails (appareil, gigue, serveur) sont dans
                // la publication ouverte.
                FeedMeasureBlock(signal: signal)

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
