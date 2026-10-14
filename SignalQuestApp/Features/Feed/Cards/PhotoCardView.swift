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
            // En-tête, légende, puis la photo avec son opérateur et son support
            // en surimpression. Le double-tap sur le média like toujours.
            VStack(alignment: .leading, spacing: SQSpace.md) {
                CardHeader(
                    author: item.author,
                    place: item.signal?.city ?? item.placeLabel,
                    createdAt: item.createdAt,
                    kindBadge: "Photo d’antenne",
                    kindColor: SQColor.success,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(3)
                }

                if !item.hashtags.isEmpty {
                    CardHashtags(tags: item.hashtags)
                }

                heroImage
                    .overlay(alignment: .bottomLeading) { siteCaption }

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
    private var heroImage: some View {
        let first = item.imageAttachments.first
        let url = first?.url ?? first?.thumbnailUrl
        ZStack {
            RemoteImage(url: url, maxDimension: 460, contentMode: .fill, showsFailureUI: true) {
                Rectangle().fill(SQColor.surfaceMuted)
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
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .onTapGesture(count: 2) {
            Haptics.medium()
            // Le double-tap ne fait qu'aimer : sur une photo déjà aimée, il
            // retirait le like tout en jouant l'animation du cœur (SOC-16).
            if !item.likedByMe { onLike() }
            withAnimation(SQMotion.resolve(.snappy(duration: 0.35), reduceMotion)) { likeBurst = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(SQMotion.resolve(.snappy(duration: 0.25), reduceMotion)) { likeBurst = false }
            }
        }
        .accessibilityLabel(photoAccessibilityLabel)
    }

    /// « Orange · support 1552054 » sur un voile sombre, lisible sur toute photo.
    @ViewBuilder
    private var siteCaption: some View {
        let parts = [item.signal?.operator, item.signal?.siteLabel].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            HStack(spacing: SQSpace.xs) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: parts.joined(separator: " · "))
                    .font(SQType.caption(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, SQSpace.xs)
            .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
            .padding(SQSpace.sm2)
        }
    }

    /// Décrit la photo pour VoiceOver à partir de la légende du post ou du lieu,
    /// au lieu d'un générique « Photo du site » (A11Y-12).
    private var photoAccessibilityLabel: String {
        // Le texte alternatif de l'auteur décrit mieux la photo que sa légende.
        if let alt = item.imageAttachments.first?.trimmedAltText { return alt }
        let caption = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { return String(localized: "Photo. \(caption)") }
        if let place = (item.signal?.city ?? item.placeLabel), !place.isEmpty {
            return String(localized: "Photo à \(place)")
        }
        return String(localized: "Photo partagée")
    }
}
