import SwiftUI

/// Specialised feed card for `kind = photo` (antenna photo). Hero image
/// taking the full card width, with site / operator metadata and the
/// standard action bar. Double-tap on the hero triggers a like.
struct PhotoCardView: View {
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

    @State private var likeBurst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                heroImage
                VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                    CardHeader(
                        author: item.author,
                        place: item.signal?.city ?? item.placeLabel,
                        createdAt: item.createdAt,
                        kindBadge: "Photo",
                        kindColor: SQColor.brandRed,
                        onAuthorTap: onAuthorTap
                    )

                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .lineLimit(3)
                    }

                    if let signal = item.signal, signal.siteLabel != nil || signal.operator != nil {
                        HStack(spacing: SQSpace.sm) {
                            if let site = signal.siteLabel {
                                SQEditorialTag(text: site, color: SQColor.label)
                            }
                            if let op = signal.operator {
                                SQEditorialTag(text: op, color: SQBrand.operatorColor(op))
                            }
                        }
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
            }
            .sqEditorialCard(clip: true)
        }
        .buttonStyle(SQPressButtonStyle())
    }

    @ViewBuilder
    private var heroImage: some View {
        let url = item.attachments.first?.url ?? item.attachments.first?.thumbnailUrl
        ZStack {
            RemoteImage(url: url, maxDimension: 460, contentMode: .fill) {
                Rectangle().fill(SQColor.fill)
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundStyle(SQColor.labelTertiary)
                    )
            }
            if likeBurst {
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(SQColor.like)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 260)
        .clipped()
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SQRadius.lg, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: SQRadius.lg))
        .onTapGesture(count: 2) {
            Haptics.medium()
            onLike()
            withAnimation(SQMotion.resolve(.snappy(duration: 0.35), reduceMotion)) { likeBurst = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(SQMotion.resolve(.snappy(duration: 0.25), reduceMotion)) { likeBurst = false }
            }
        }
    }
}
