import SwiftUI

/// Default card for "free form" posts (kind=`post`). Renders text + optional
/// image attachment + a thin signal hint when the payload carries one.
struct PostCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onComment: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onShare: () -> Void = {}
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil
    /// Vote sur le sondage attaché, s'il y en a un.
    var onPollVote: ((FeedPoll.Option) -> Void)? = nil

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.label,
                    onAuthorTap: onAuthorTap
                )

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("feed.post.text")
                }

                // Le sondage se place APRÈS le texte et AVANT la pièce jointe :
                // c'est l'ordre de lecture naturel, le texte posant la question
                // que les options répondent.
                if let poll = item.poll, let onPollVote {
                    FeedPollView(poll: poll, onVote: onPollVote)
                }

                if let attachment = item.attachments.first,
                   let url = attachment.thumbnailUrl ?? attachment.url {
                    RemoteImage(url: url, maxDimension: 440, contentMode: .fill) {
                        Rectangle().fill(SQColor.surfaceMuted)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .onTapGesture(count: 2) {
                        Haptics.medium()
                        // Double-tap = aimer, jamais retirer un like (SOC-16).
                        if !item.likedByMe { onLike() }
                    }
                }

                if !item.hashtags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SQSpace.sm) {
                            ForEach(item.hashtags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(SQType.micro)
                                    .foregroundStyle(SQColor.brandRed)
                            }
                        }
                    }
                }

                if let signal = item.signal, signal.rsrp != nil || signal.technology != nil {
                    SignalBarsView(summary: signal)
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
}

struct SignalBarsView: View {
    let summary: SocialSignalSummary?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if summary?.rsrp == nil && summary?.technology == nil {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("Radio indisponible sur iOS")
                    .font(SQType.caption)
            } else {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index <= level ? AnyShapeStyle(SQColor.success) : AnyShapeStyle(SQColor.fill))
                        .frame(width: 6, height: CGFloat(8 + index * 5))
                }
                if let technology = summary?.technology {
                    Text(technology)
                        .font(SQType.micro)
                }
            }
        }
        .foregroundStyle(SQColor.labelSecondary)
        .accessibilityLabel("Résumé radio serveur")
    }

    private var level: Int {
        guard let rsrp = summary?.rsrp else { return summary?.technology == nil ? -1 : 2 }
        if rsrp > -85 { return 3 }
        if rsrp > -100 { return 2 }
        if rsrp > -112 { return 1 }
        return 0
    }
}
