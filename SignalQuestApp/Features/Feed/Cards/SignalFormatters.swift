import Foundation
import SwiftUI

/// Centralised formatters shared by the specialised social cards.
enum SignalFormatters {
    /// Débit selon la langue (« 64,0 Mbit/s », « 64.0 Mbps ») : le fil
    /// affichait « 64.0 Mbps » en français (TRX-24).
    static func speed(_ value: Double?) -> String {
        guard let value else { return "—" }
        return SQUnits.throughput(mbps: value)
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
        // Abréviation selon la langue (« 1,2 k » en français, « 1.2K » en anglais).
        if value >= 1_000 { return value.formatted(.number.notation(.compactName)) }
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

    /// Libellé court de techno pour une pastille (« 5G », « 4G », « Wi-Fi »), ou
    /// nil si la valeur du serveur est trop brute pour être affichée.
    static func shortLabel(for tech: String?) -> String? {
        guard let tech, !tech.isEmpty else { return nil }
        let upper = tech.uppercased()
        if upper.contains("5G") || upper.contains("NR") { return "5G" }
        if upper.contains("4G") || upper.contains("LTE") { return "4G" }
        if upper.contains("3G") || upper.contains("UMTS") { return "3G" }
        if upper.contains("2G") || upper.contains("GSM") { return "2G" }
        if upper.contains("WIFI") || upper.contains("WI-FI") { return "Wi-Fi" }
        return nil
    }
}

/// Tag de carte (DA Crème) : capsule teintée douce, libellé Figtree SemiBold
/// 11,5 pt en casse normale (« Speedtest », « Photo »). Ni bordure, ni
/// majuscules.
struct SQEditorialTag: View {
    private let label: Text
    let color: Color

    /// Littéral ou clé du catalogue : le libellé est localisé.
    init(text: LocalizedStringKey, color: Color = SQColor.brandRed) {
        self.label = Text(text)
        self.color = color
    }

    /// `String` à l'exécution (technologie, opérateur, nom de site du serveur) :
    /// affichée telle quelle, sans consulter le catalogue.
    @_disfavoredOverload
    init<S: StringProtocol>(text: S, color: Color = SQColor.brandRed) {
        self.label = Text(verbatim: String(text))
        self.color = color
    }

    var body: some View {
        label
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, SQSpace.xs + 1)
            // La teinte reste portée par la capsule. Le texte utilise l'encre
            // sémantique : plusieurs couleurs opérateur/tech ne garantissent
            // pas 4,5:1 sur leur propre fond translucide.
            .foregroundStyle(SQColor.label)
            .background(color.opacity(0.13), in: Capsule(style: .continuous))
            .accessibilityIdentifier("feed.tag")
    }
}

/// Header shared by every card (avatar, name, place, kind badge).
/// `onAuthorTap` rend l'avatar + nom tappables (navigation vers le profil).
struct CardHeader: View {
    let author: SocialFeedAuthor
    let place: String?
    let createdAt: Date?
    /// `nil` pour un post simple : un badge « Post » sur chaque carte
    /// n'apprenait rien (UI-08).
    let kindBadge: String?
    let kindColor: Color
    var onAuthorTap: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.feedCardMenu) private var menu

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    HStack(alignment: .top) {
                        authorContent
                        Spacer(minLength: 0)
                        menuButton
                    }
                    if let kindBadge {
                        SQEditorialTag(text: LocalizedStringKey(kindBadge), color: kindColor)
                    }
                }
            } else {
                HStack(spacing: SQSpace.sm) {
                    authorContent
                    Spacer(minLength: SQSpace.xs)
                    if let kindBadge {
                        SQEditorialTag(text: LocalizedStringKey(kindBadge), color: kindColor)
                    }
                    menuButton
                }
            }
        }
    }

    /// ⋯ visible : le même menu que l'appui long, qu'on ne trouvait pas.
    @ViewBuilder
    private var menuButton: some View {
        if let menu {
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Plus d’actions")
            .accessibilityIdentifier("feed.card.menu")
            .padding(.trailing, -SQSpace.sm2)
            .padding(.vertical, -SQSpace.sm)
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
        HStack(alignment: .top, spacing: SQSpace.md) {
            SQAvatar(url: author.avatarUrl, name: author.displayName)
            VStack(alignment: .leading, spacing: SQSpace.xs + 1) {
                HStack(spacing: 5) {
                    Text(author.displayName)
                        .font(SQType.rowTitle)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // Badges accolés au nom, comme sur le web et Android.
                    SQUserBadges(badges: author.badges)
                }
                metadata
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    /// Lieu et date restent deux informations distinctes. La version
    /// précédente ajoutait des pictogrammes sans action, ce qui formait une
    /// ligne dense et mal alignée. Le texte suffit et se replie proprement.
    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                metadataItems(includeSeparator: true)
            }
            VStack(alignment: .leading, spacing: 3) { metadataItems() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.metadata")
    }

    @ViewBuilder
    private func metadataItems(includeSeparator: Bool = false) -> some View {
        if let place {
            Text(place)
                .sqSingleLine()
                .accessibilityIdentifier("feed.metadata.place")
        }
        if let createdAt {
            if includeSeparator, place != nil {
                Text("·")
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("feed.metadata.separator")
            }
            Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .sqSingleLine()
                .accessibilityIdentifier("feed.metadata.date")
        }
    }
}

extension UnifiedSocialFeedItem {
    /// L'utilisateur a-t-il déjà réagi avec CET emoji ? Le ❤️ retombe sur `likedByMe`
    /// quand la liste de réactions ne le porte pas.
    func hasReacted(with emoji: String) -> Bool {
        if let reacted = reactions.first(where: { $0.emoji == emoji })?.reactedByMe { return reacted }
        return emoji == "❤️" && likedByMe
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

    var body: some View {
        // J'aime, Commenter, Repartager à gauche ; Enregistrer et Partager à
        // droite. Plus de fond gris : la carte suffit à les regrouper.
        HStack(spacing: SQSpace.xs) {
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
                tint: item.repostedByMe ? SQColor.success : SQColor.chipInk,
                label: "Repartager",
                action: onRepost
            )
            .accessibilityAddTraits(item.repostedByMe ? .isSelected : [])
            Spacer(minLength: 0)
            Button(action: onFavorite) {
                Image(systemName: item.favoritedByMe ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(item.favoritedByMe ? SQColor.brandRed : SQColor.chipInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(item.favoritedByMe ? "Retirer des favoris" : "Ajouter aux favoris")
            .accessibilityAddTraits(item.favoritedByMe ? .isSelected : [])
            .sqLikePop(trigger: item.favoritedByMe)
            Button(action: onShare) {
                Image(systemName: "paperplane")
                    .foregroundStyle(SQColor.chipInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Partager")
        }
        .padding(.horizontal, -SQSpace.sm)
        .padding(.vertical, -SQSpace.xs)
        .buttonStyle(.plain)
        .font(SQType.subhead(.semibold))
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
                    .accessibilityIdentifier("feed.action.count")
            }
        }
        .foregroundStyle(item.likedByMe ? SQColor.like : SQColor.chipInk)
        .sqLikePop(trigger: item.likedByMe)
        .padding(.horizontal, SQSpace.sm)
        .frame(minWidth: 44, minHeight: 44)
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
        // Le sélecteur d'emojis se déclenche à l'appui long, introuvable au lecteur
        // d'écran : chaque réaction devient une action nommée (le ❤️ reste l'action par défaut).
        .accessibilityActions {
            if let onReact {
                ForEach(Array(ReactionPicker.defaultEmojis.dropFirst()), id: \.self) { emoji in
                    Button(String(localized: "Réagir avec \(emoji)")) { onReact(emoji) }
                }
            }
        }
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

    private func actionButton(count: Int, systemImage: String, tint: Color = SQColor.chipInk, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if count > 0 {
                    Text(SignalFormatters.count(count))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("feed.action.count")
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, SQSpace.sm)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

// MARK: - Contexte posé par l'écran du fil

private struct FeedCardMenuKey: EnvironmentKey {
    static var defaultValue: AnyView? { nil }
}

private struct FeedHashtagActionKey: EnvironmentKey {
    static var defaultValue: ((String) -> Void)? { nil }
}

private struct SignedInUserKey: EnvironmentKey {
    static var defaultValue: AuthUser? { nil }
}

extension EnvironmentValues {
    /// Contenu du menu ⋯ des cartes. Seul l'écran qui le pose sait quelles
    /// actions offrir ; ailleurs, la carte n'affiche pas de ⋯.
    var feedCardMenu: AnyView? {
        get { self[FeedCardMenuKey.self] }
        set { self[FeedCardMenuKey.self] = newValue }
    }

    /// Filtre le fil sur un hashtag touché dans une carte. Sans action, les
    /// hashtags restent du texte.
    var feedHashtagAction: ((String) -> Void)? {
        get { self[FeedHashtagActionKey.self] }
        set { self[FeedHashtagActionKey.self] = newValue }
    }

    /// Compte connecté, posé à la racine. Une feuille qui n'en montre que
    /// l'avatar le lit ici : sans session injectée (rendu isolé, invité),
    /// elle reçoit `nil` au lieu de s'arrêter.
    var signedInUser: AuthUser? {
        get { self[SignedInUserKey.self] }
        set { self[SignedInUserKey.self] = newValue }
    }
}

/// Hashtags d'une publication, touchables quand l'écran sait filtrer.
struct CardHashtags: View {
    let tags: [String]
    @Environment(\.feedHashtagAction) private var onTap

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.xs) {
                ForEach(tags, id: \.self) { tag in
                    if let onTap {
                        Button {
                            onTap(tag)
                        } label: {
                            label(tag)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Filtre le fil sur ce hashtag")
                        .accessibilityIdentifier("feed.hashtag.\(tag)")
                    } else {
                        label(tag)
                    }
                }
            }
        }
        .padding(.vertical, onTap == nil ? 0 : -SQSpace.sm2)
    }

    private func label(_ tag: String) -> some View {
        Text(verbatim: "#\(tag)")
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.accentInk)
            .padding(.trailing, SQSpace.xs)
    }
}

/// Bloc de mesure d'un speedtest : grand débit de réception, puis envoi,
/// latence, opérateur et technologie sur une ligne.
struct FeedMeasureBlock: View {
    private let download: Double?
    private let upload: Double?
    private let ping: Double?
    private let operatorAndTech: String?
    /// SIM d'origine, montrée seulement quand elle voyage.
    private let roamingSim: String?

    init(signal: SocialSignalSummary?) {
        download = signal?.downloadMbps
        upload = signal?.uploadMbps
        ping = signal?.pingMs
        let parts = [signal?.servingOperator ?? signal?.operator, signal?.technology].compactMap { $0 }
        operatorAndTech = parts.isEmpty ? nil : parts.joined(separator: " ")
        roamingSim = signal?.isRoaming == true ? signal?.simOperator : nil
    }

    /// Speedtest joint au compositeur : même bloc que dans le fil.
    init(speedtest: SocialShareableSpeedtest) {
        download = speedtest.averageSpeed ?? speedtest.downloadSpeed
        upload = speedtest.uploadSpeed
        ping = speedtest.ping
        let parts = [speedtest.mobileOperator, speedtest.networkType].compactMap { $0 }
        operatorAndTech = parts.isEmpty ? nil : parts.joined(separator: " ")
        roamingSim = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Surtitre à l'encre forte : le gris secondaire de `sqKicker` manque
            // de contraste en 11 pt sur la tuile.
            Text("Speedtest · réception")
                .font(SQFont.body(11, .bold, relativeTo: .caption2))
                .tracking(11 * 0.18)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.ink2)
                .accessibilityIdentifier("feed.measure.kicker")
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: download.map { SQUnits.throughputValue(mbps: $0) } ?? "—")
                    .font(SQFont.display(26, .heavy, relativeTo: .title))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Text(verbatim: SQUnits.throughputUnit(mbps: download ?? 0))
                    .font(SQType.subhead(.bold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if !details.isEmpty {
                Text(verbatim: details)
                    .font(SQType.subhead)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feed.measure.details")
            }
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Speedtest"))
        .accessibilityValue(Text(spoken))
        .accessibilityIdentifier("feed.speedtest.measure")
    }

    /// « ↑ 64 Mbit/s · 18 ms · SFR 5G », plus la SIM quand elle voyage.
    private var details: String {
        var parts: [String] = []
        if let upload { parts.append("↑ " + SignalFormatters.speed(upload)) }
        if let ping { parts.append(SignalFormatters.ms(ping)) }
        if let operatorAndTech { parts.append(operatorAndTech) }
        if let roamingSim {
            parts.append(String(localized: "SIM \(roamingSim)"))
        }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        var parts = [String(localized: "réception \(SignalFormatters.speed(download))")]
        if let upload { parts.append(String(localized: "envoi \(SignalFormatters.speed(upload))")) }
        if let ping { parts.append(String(localized: "latence \(SignalFormatters.ms(ping))")) }
        if let operatorAndTech { parts.append(operatorAndTech) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Editorial card surface

extension View {
    /// Surface de carte douce (DA « Crème & Terre cuite ») : la carte partagée
    /// (`sqCardBackground`, TRX-11), rayon 22, ombre carte chaude, et le
    /// liseré qui la détache du fond en noir intense (OLED). Passe
    /// `clip = true` pour rogner un média plein cadre (PhotoCard).
    func sqSoftCard(clip: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
        return self
            .modifier(ConditionalClip(shape: shape, clip: clip))
            .sqCardBackground(cornerRadius: SQRadius.xl)
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
