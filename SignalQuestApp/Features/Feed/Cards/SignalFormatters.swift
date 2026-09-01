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
        return SQUnits.distance(meters: value)
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

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    nonisolated(unsafe) private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Une date renvoyée par l'API, rendue lisible.
    ///
    /// Le backend émet de l'ISO 8601 brut (`2026-05-11T12:46:37.220Z`) : affiché
    /// tel quel, c'est illisible, et le parser sans `.withFractionalSeconds`
    /// échoue silencieusement sur les millisecondes. `SQDateParsing.parse` couvre
    /// déjà toutes les formes reçues (ISO avec/sans fraction, local, jour seul).
    ///
    /// `relative` donne « il y a 3 jours » — juste pour une mesure récente, mais
    /// trompeur pour une date de mise en service qui remonte à des années : au
    /// delà d'un mois, on retombe sur la date absolue.
    static func date(_ value: String?, includingTime: Bool = false, relative: Bool = false) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let date = SQDateParsing.parse(value) else { return value }
        return self.date(date, includingTime: includingTime, relative: relative)
    }

    /// Même rendu, pour les modèles qui décodent déjà une `Date` (tuiles carte)
    /// et n'ont donc pas de chaîne brute à reparser.
    static func date(_ date: Date, includingTime: Bool = false, relative: Bool = false) -> String {
        if relative, abs(date.timeIntervalSinceNow) < 30 * 24 * 60 * 60 {
            return relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return includingTime ? dayTimeFormatter.string(from: date) : dayFormatter.string(from: date)
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

/// Tag de carte (DA Crème) : capsule teintée douce, libellé Figtree SemiBold
/// 11,5 pt en casse normale (« Speedtest », « Photo »). Ni bordure, ni
/// majuscules.
struct SQEditorialTag: View {
    let text: String
    var color: Color = SQColor.brandRed

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.sm + 2)
            .padding(.vertical, SQSpace.xs + 1)
            // La teinte reste portée par la capsule. Le texte utilise l'encre
            // sémantique : plusieurs couleurs opérateur/tech ne garantissent
            // pas 4,5:1 sur leur propre fond translucide.
            .foregroundStyle(SQColor.label)
            .background(color.opacity(0.13), in: Capsule(style: .continuous))
            .accessibilityIdentifier("feed.tag")
    }
}

/// A simple "label / value" tile reused by every specialised card. Style
/// « Crème » : tuile `SurfaceMuted` rayon 14 sans bordure, label Figtree 11
/// secondaire en casse normale, valeur Bricolage Bold 15 (accent si highlight).
struct CardMetricTile: View {
    let label: String
    let value: String
    var highlight: Bool = false
    var accent: Color = SQColor.brandRed
    /// Une valeur COMPOSÉE peut demander deux lignes — « Internet, Voix · 4G, 5G » sur la carte de
    /// panne. Défaut à 1 : une mesure (« 240 Mbps ») tient sur une ligne, et l'autoriser à passer
    /// à la ligne désalignerait les tuiles voisines de la grille.
    var valueLineLimit: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("feed.metric.label")
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.primary)
                .lineLimit(max(2, valueLineLimit))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("feed.metric.value")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SQSpace.sm + 2)
        .padding(.horizontal, SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        // VoiceOver : « libellé : valeur » d'un bloc (Down 240 Mbps), pas 2 textes.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityValue(value)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    authorContent
                    SQEditorialTag(text: kindBadge, color: kindColor)
                }
            } else {
                HStack(spacing: SQSpace.md) {
                    authorContent
                    Spacer()
                    SQEditorialTag(text: kindBadge, color: kindColor)
                }
            }
        }
    }

    @ViewBuilder
    private var authorContent: some View {
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
    }

    private var authorBlock: some View {
        HStack(spacing: SQSpace.md) {
            SQAvatar(url: author.avatarUrl, name: author.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(author.displayName)
                        .font(SQFont.body(16, .semibold, relativeTo: .headline))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // Badges accolés au nom, comme sur le web et Android.
                    SQUserBadges(badges: author.badges)
                }
                HStack(spacing: 6) {
                    if let place {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(place)
                    }
                    if let createdAt {
                        Text("·")
                            .accessibilityHidden(true)
                        Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    }
                }
                .font(SQFont.body(12.5, relativeTo: .footnote))
                .foregroundStyle(SQColor.labelSecondary)
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
    /// Réaction emoji via l'appui long sur ❤️ (REACT-FEAT-01). Repli sur onLike.
    var onReact: ((String) -> Void)? = nil

    @State private var showReactionPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? SQSpace.sm : SQSpace.xl) {
            likeButton
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(item.favoritedByMe ? "Retirer des favoris" : "Ajouter aux favoris")
            .accessibilityAddTraits(item.favoritedByMe ? .isSelected : [])
            .sqLikePop(trigger: item.favoritedByMe)
            Button(action: onShare) {
                Image(systemName: "paperplane")
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Partager")
        }
        .buttonStyle(.plain)
        .font(SQFont.body(14, .semibold))
        .overlay(alignment: .topLeading) {
            if showReactionPicker {
                ReactionPicker { emoji in
                    (onReact ?? { _ in onLike() })(emoji)
                    dismissPicker()
                }
                .offset(y: -56)
                .transition(.scale(scale: 0.55, anchor: .bottomLeading).combined(with: .opacity))
                .zIndex(2)
            }
        }
    }

    /// Bouton ❤️ : tap = like ; appui long = sélecteur de réactions animé.
    /// Vue à gestes (pas un Button) pour que le tap court et l'appui long ne se
    /// déclenchent pas tous les deux.
    private var likeButton: some View {
        HStack(spacing: 5) {
            Image(systemName: item.likedByMe ? "heart.fill" : "heart")
            if reactionCount > 0 {
                Text(SignalFormatters.count(reactionCount))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(item.likedByMe ? SQColor.like : SQColor.labelSecondary)
        .sqLikePop(trigger: item.likedByMe)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            if showReactionPicker { dismissPicker() } else { onLike() }
        }
        .onLongPressGesture(minimumDuration: 0.3) {
            guard onReact != nil else { onLike(); return }
            Haptics.medium()
            withAnimation(SQMotion.resolve(SQMotion.bouncy, reduceMotion)) { showReactionPicker = true }
            scheduleAutoDismiss()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("J’aime")
        .accessibilityValue(reactionCount > 0 ? "\(reactionCount)" : "")
        .accessibilityAddTraits(item.likedByMe ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(onReact == nil ? "" : "Appui long pour choisir une réaction")
        .accessibilityAction { onLike() }
    }

    private func dismissPicker() {
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { showReactionPicker = false }
    }

    private func scheduleAutoDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            if showReactionPicker { dismissPicker() }
        }
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

// MARK: - Editorial card surface

extension View {
    /// Surface de carte douce (DA « Crème & Terre cuite ») : fond
    /// `SurfaceElevated`, rayon 22 continu, ombre carte chaude. Zéro bordure
    /// (règle No-Border). Passe `clip = true` pour rogner un média plein cadre
    /// (PhotoCard).
    func sqSoftCard(clip: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
        return self
            .background(SQColor.surface, in: shape)
            .modifier(ConditionalClip(shape: shape, clip: clip))
            .sqShadowCard()
    }

    /// Alias historique : les ~15 appels existants passent sur la carte douce.
    func sqEditorialCard(clip: Bool = false) -> some View {
        sqSoftCard(clip: clip)
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
