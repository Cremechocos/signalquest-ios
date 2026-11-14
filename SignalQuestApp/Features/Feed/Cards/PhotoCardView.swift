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
                    place: item.cardPlace,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.success,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                FeedKindLine(symbol: "camera", title: String(localized: "Photo d’un support"), points: item.earnedPoints)

                if let text = item.cardText {
                    Text(text)
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

                FeedNetworkLine(operator: item.signal?.operator ?? item.metadataString("operator"), technology: nil)

                if let key = item.siteKey {
                    FeedOpenCapsule(title: String(localized: "Voir le site"),
                                    destination: .link(.site(id: key.siteId, market: key.market, operatorKey: key.operatorKey)),
                                    prominent: false, onOpenPost: onTap)
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

    /// Commune et prise de vue (« à 120 m, vers le nord-est ») sur la photo, chacune
    /// masquée sans valeur. L'opérateur passe sous la photo (refonte du 04/11).
    @ViewBuilder
    private var siteCaption: some View {
        let chips = [item.metadataString("siteCommune"), Self.shotLabel(
            meters: item.metadataNumber("photoDistanceMeters"), degrees: item.metadataNumber("photoDirectionDegrees")
        )].compactMap { $0 }
        if !chips.isEmpty {
            FlowRow(spacing: SQSpace.xs2) {
                ForEach(chips, id: \.self) { chip in
                    Text(verbatim: chip)
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.sm2)
                        .padding(.vertical, SQSpace.xs)
                        .background(SQColor.surface, in: Capsule(style: .continuous))
                }
            }
            .padding(SQSpace.sm2)
        }
    }

    /// « à 120 m, vers le nord-est », « à 120 m » ou « vers le nord-est ».
    static func shotLabel(meters: Double?, degrees: Double?) -> String? {
        let distance = meters.flatMap { $0 > 0 ? SignalFormatters.meters($0) : nil }
        let direction = degrees.flatMap { $0.isFinite ? compass($0) : nil }
        switch (distance, direction) {
        case let (distance?, direction?): return String(localized: "à \(distance), vers \(direction)")
        case let (distance?, nil): return String(localized: "à \(distance)")
        case let (nil, direction?): return String(localized: "vers \(direction)")
        default: return nil
        }
    }

    /// Huit points cardinaux, de 22,5° de part et d'autre.
    static func compass(_ degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch Int(((normalized + 22.5) / 45).rounded(.down)) % 8 {
        case 0: return String(localized: "le nord")
        case 1: return String(localized: "le nord-est")
        case 2: return String(localized: "l’est")
        case 3: return String(localized: "le sud-est")
        case 4: return String(localized: "le sud")
        case 5: return String(localized: "le sud-ouest")
        case 6: return String(localized: "l’ouest")
        default: return String(localized: "le nord-ouest")
        }
    }

    /// Décrit la photo pour VoiceOver à partir de la légende du post ou du lieu,
    /// au lieu d'un générique « Photo du site » (A11Y-12).
    private var photoAccessibilityLabel: String {
        // Le texte alternatif de l'auteur décrit mieux la photo que sa légende.
        if let alt = item.imageAttachments.first?.trimmedAltText { return alt }
        if let caption = item.cardText { return String(localized: "Photo. \(caption)") }
        if let place = (item.signal?.city ?? item.readablePlaceLabel), !place.isEmpty {
            return String(localized: "Photo à \(place)")
        }
        return String(localized: "Photo partagée")
    }
}
