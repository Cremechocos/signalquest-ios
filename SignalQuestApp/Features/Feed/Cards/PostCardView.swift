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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                CardHeader(
                    author: item.author,
                    place: item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: "Post",
                    kindColor: SQColor.label,
                    onAuthorTap: onAuthorTap
                )

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                if let attachment = item.attachments.first,
                   let url = attachment.thumbnailUrl ?? attachment.url {
                    RemoteImage(url: url, maxDimension: 440, contentMode: .fill) {
                        Rectangle().fill(SQColor.fill)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1)
                    }
                    .onTapGesture(count: 2) {
                        Haptics.medium()
                        onLike()
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
                    onShare: onShare
                )
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
        }
        .buttonStyle(.plain)
    }
}
