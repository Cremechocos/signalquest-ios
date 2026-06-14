import Foundation
import SwiftUI

/// Centralised formatters shared by the specialised social cards.
enum SignalFormatters {
    static func speed(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 100 { return "\(Int(value.rounded())) Mbps" }
        return String(format: "%.1f Mbps", value)
    }

    static func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) ms"
    }

    static func dbm(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) dBm"
    }

    static func db(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) dB"
    }

    static func meters(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1000 { return String(format: "%.1f km", value / 1000) }
        return "\(Int(value)) m"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 10_000 { return String(format: "%.1fk", Double(value) / 1000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }
}

/// A small accent palette indexed by network technology. Routed through the
/// editorial DA palette (`SQBrand.techColor`, web --color-5g/4g/3g/2g) so the
/// cards share the exact technology colours used elsewhere in the app.
enum TechAccent {
    static func color(for tech: String?) -> Color {
        guard let tech, !tech.isEmpty else { return SQColor.label }
        return SQBrand.techColor(tech)
    }
}

/// Tag éditorial (signature de la landing) : libellé MAJUSCULE Archivo Bold,
/// fond teinté léger, coin net `SQRadius.sm`, fin filet de la couleur. Remplace
/// les pilules molles des cartes par un « tag imprimé » à fort contraste.
struct SQEditorialTag: View {
    let text: String
    var color: Color = SQColor.brandRed

    var body: some View {
        Text(text)
            .font(SQType.micro)
            .tracking(0.8)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, SQSpace.xs + 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(color.opacity(0.45), lineWidth: 1)
            }
    }
}

/// A simple "label / value" tile reused by every specialised card. Style
/// éditorial : label MAJUSCULE tracé (Archivo), valeur en chiffres marqués,
/// surface mate à coin net `SQRadius.sm`.
struct CardMetricTile: View {
    let label: String
    let value: String
    var highlight: Bool = false
    var accent: Color = SQColor.brandRed

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(SQType.micro)
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelTertiary)
            Text(value)
                .font(SQFont.archivo(15, .bold))
                .foregroundStyle(highlight ? accent : SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.sm + 2)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
    }
}

/// Header shared by every card (avatar, name, place, kind badge).
/// `onAuthorTap` rend l'avatar + nom tappables (navigation vers le profil).
struct CardHeader: View {
    let author: SocialFeedAuthor
    let place: String?
    let createdAt: Date?
    let kindBadge: String
    let kindColor: Color
    var onAuthorTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: SQSpace.md) {
            if let onAuthorTap {
                Button {
                    Haptics.light()
                    onAuthorTap()
                } label: {
                    authorBlock
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir le profil de \(author.displayName)")
            } else {
                authorBlock
            }
            Spacer()
            SQEditorialTag(text: kindBadge, color: kindColor)
        }
    }

    private var authorBlock: some View {
        HStack(spacing: SQSpace.md) {
            SQAvatar(url: author.avatarUrl, name: author.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(author.displayName)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                HStack(spacing: 6) {
                    if let place {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(place)
                    }
                    if let createdAt {
                        Text("·")
                        Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelTertiary)
            }
        }
    }
}

/// Bottom toolbar with the reaction / repost / comment / share controls.
struct CardActionsBar: View {
    let item: UnifiedSocialFeedItem
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void

    var body: some View {
        HStack(spacing: SQSpace.xl) {
            actionButton(
                count: reactionCount,
                systemImage: item.likedByMe ? "heart.fill" : "heart",
                tint: item.likedByMe ? SQColor.like : SQColor.labelSecondary,
                label: "J’aime",
                action: onLike
            )
            .accessibilityAddTraits(item.likedByMe ? .isSelected : [])
            .sqLikePop(trigger: item.likedByMe)
            actionButton(
                count: item.commentsCount,
                systemImage: "bubble.right",
                label: "Commenter",
                action: onComment
            )
            actionButton(
                count: item.repostsCount,
                systemImage: item.repostedByMe ? "arrow.2.squarepath.circle.fill" : "arrow.2.squarepath",
                tint: item.repostedByMe ? SQColor.success : SQColor.labelSecondary,
                label: "Repartager",
                action: onRepost
            )
            .accessibilityAddTraits(item.repostedByMe ? .isSelected : [])
            Spacer()
            Button(action: onFavorite) {
                Image(systemName: item.favoritedByMe ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(item.favoritedByMe ? SQColor.brandRed : SQColor.labelSecondary)
            }
            .accessibilityLabel(item.favoritedByMe ? "Retirer des favoris" : "Ajouter aux favoris")
            .accessibilityAddTraits(item.favoritedByMe ? .isSelected : [])
            .sqLikePop(trigger: item.favoritedByMe)
            Button(action: onShare) {
                Image(systemName: "paperplane")
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityLabel("Partager")
        }
        .buttonStyle(.plain)
        .font(SQFont.archivo(15, .semibold))
    }

    private var reactionCount: Int { item.reactions.reduce(0) { $0 + $1.count } }

    private func actionButton(count: Int, systemImage: String, tint: Color = SQColor.labelSecondary, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if count > 0 {
                    Text(SignalFormatters.count(count))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(tint)
        }
        .accessibilityLabel(label)
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

// MARK: - Editorial card surface

extension View {
    /// Surface de carte éditoriale (DA landing) : fond `surface`, coin net
    /// `SQRadius.lg`, filet `separator` 1,5px pour l'aspect imprimé. Pas
    /// d'ombre ni de glassmorphism — le contraste vient de la bordure et de la
    /// typo. Passe `clip = true` pour rogner un média plein cadre (PhotoCard).
    func sqEditorialCard(clip: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
        return self
            .background(SQColor.surface, in: shape)
            .modifier(ConditionalClip(shape: shape, clip: clip))
            .overlay { shape.stroke(SQColor.separator, lineWidth: 1.5) }
    }
}

private struct ConditionalClip: ViewModifier {
    let shape: RoundedRectangle
    let clip: Bool
    func body(content: Content) -> some View {
        if clip {
            content.clipShape(shape)
        } else {
            content
        }
    }
}
