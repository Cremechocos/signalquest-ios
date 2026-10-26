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

/// Date relative courte : « il y a 5 min », « il y a 3 j », puis « il y a 5 mois »
/// en toutes lettres — l'abréviation « m. » se lit minutes autant que mois.
struct SQRelativeDateFormatStyle: FormatStyle {
    var locale: Locale = .autoupdatingCurrent

    func format(_ value: Date) -> String {
        let style: Date.RelativeFormatStyle.UnitsStyle = abs(value.timeIntervalSinceNow) < 28 * 86_400 ? .abbreviated : .wide
        return Date.RelativeFormatStyle(presentation: .named, unitsStyle: style, locale: locale).format(value)
    }

    func locale(_ locale: Locale) -> SQRelativeDateFormatStyle {
        var copy = self
        copy.locale = locale
        return copy
    }
}

extension FormatStyle where Self == SQRelativeDateFormatStyle {
    static var sqRelative: SQRelativeDateFormatStyle { SQRelativeDateFormatStyle() }
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
    /// Publication épinglée sur le profil de son auteur : une pastille le dit.
    var isPinned: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.feedCardMenu) private var menu
    @Environment(\.feedCardShowsAuthor) private var showsAuthor

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            if isPinned { pinnedTag }
            headerRow
        }
    }

    private var pinnedTag: some View {
        Label("Épinglé", systemImage: "pin.fill")
            .font(SQType.caption(.semibold))
            .foregroundStyle(SQColor.chipInk)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.chip, in: Capsule(style: .continuous))
            .accessibilityIdentifier("feed.pinned")
    }

    private var headerRow: some View {
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
            } else if let kindBadge {
                // La pastille passe sous l'auteur plutôt que de repousser l'heure
                // sur une troisième ligne (lot F, F-22).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SQSpace.sm) {
                        authorContent
                        Spacer(minLength: SQSpace.xs)
                        SQEditorialTag(text: LocalizedStringKey(kindBadge), color: kindColor)
                        menuButton
                    }
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        HStack(alignment: .top) {
                            authorContent
                            Spacer(minLength: 0)
                            menuButton
                        }
                        SQEditorialTag(text: LocalizedStringKey(kindBadge), color: kindColor)
                    }
                }
            } else {
                HStack(spacing: SQSpace.sm) {
                    authorContent
                    Spacer(minLength: SQSpace.xs)
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
            // VoiceOver trouve ces choix parmi les actions de la carte, après
            // les siennes (CardActionsBar) : un ⋯ en tête les faisait passer
            // avant « J’aime » (F-50).
            .accessibilityHidden(true)
            .accessibilityIdentifier("feed.card.menu")
            .padding(.trailing, -SQSpace.sm2)
            .padding(.vertical, -SQSpace.sm)
        }
    }

    /// Un geste plutôt qu'un bouton : dans une carte, VoiceOver change un bouton
    /// imbriqué en action et tait son texte. La carte disait « Speedtest » sans
    /// son auteur ni son heure (lot F, F-47) ; le profil reste une action nommée.
    @ViewBuilder
    private var authorContent: some View {
            if !showsAuthor {
                // Le lieu et l'heure seuls ; VoiceOver garde le nom en tête,
                // comme sur toute autre carte.
                metadata
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenAuthorLine))
            } else if let onAuthorTap {
                authorBlock
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.light()
                        onAuthorTap()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: Text("Voir le profil de \(author.displayName)")) { onAuthorTap() }
            } else {
                authorBlock
                    .accessibilityElement(children: .combine)
            }
    }

    private var spokenAuthorLine: String {
        [author.displayName, place, createdAt?.formatted(.sqRelative)]
            .compactMap { $0 }
            .joined(separator: ", ")
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
            Text(createdAt, format: .sqRelative)
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

    /// Texte sous l'en-tête d'une carte. Celui qu'écrit le serveur pour un
    /// speedtest, une identification ou une session répète la fiche (« a partagé
    /// un speedtest », « Session de couverture terminée : 3.42 km… ») : il n'est
    /// pas affiché (lot F, F-16 à F-19). La légende d'une photo, écrite par son
    /// auteur, reste ; seuls les textes par défaut du serveur sont retirés.
    var cardText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard generated == true else { return trimmed }
        switch kind.lowercased() {
        // Un test d'expérience compose sa ligne depuis ses valeurs : le texte du
        // serveur n'est qu'un repli français pour les anciennes versions.
        case "speedtest", "validation", "coverage", "session", "drive_test", "experience": return nil
        case "photo", "antenna_photo":
            return Self.serverPhotoTexts.contains { trimmed.hasPrefix($0) } ? nil : trimmed
        // « A évalué ce signal · ★★★★ » : les étoiles sont déjà sur la carte.
        case "rating": return trimmed.hasPrefix("A évalué ce signal") ? nil : trimmed
        // La phrase du serveur dans la langue de l'app quand sa clé est connue (F8).
        default: return feedText ?? trimmed
        }
    }

    /// Textes par défaut d'un post photo (`photo-post.ts`, `materialize.ts`).
    private static let serverPhotoTexts = [
        "a partagé une photo terrain", "Photo terrain du site ", "Photo terrain partagée sur SignalQuest",
        "Photo partagée sur SignalQuest", "Photo uploadée pour le site", "Photo approuvée", "Photo terrain ajoutée pour « ",
    ]
}

/// Tuiles de mesure d'une carte du fil : sur une rangée quand la plus large y
/// tient sur une ligne, sinon deux par rangée, sinon une. Plus de « Distanc/e »
/// ni de « 3,4 / km » coupés, et les tuiles d'une rangée ont la même hauteur
/// (lot F, F-20, F-21, F-25).
struct FeedMetricGrid: View {
    struct Metric: Equatable {
        let label: String
        let value: String
        var highlight = false
    }

    let metrics: [Metric]

    var body: some View {
        FeedMetricLayout(spacing: SQSpace.sm) {
            ForEach(metrics, id: \.label) { metric in
                SQMetricTile(
                    label: metric.label, value: metric.value, highlight: metric.highlight,
                    fillsHeight: true, valueLineLimit: 3, identifierPrefix: "feed.metric"
                )
                .feedTileSpeech(label: metric.label, value: metric.value)
            }
        }
    }
}

extension View {
    /// « Distance : 3,4 km » d'un seul énoncé. Lue dans une carte, une tuile
    /// libellé + valeur se séparait : les libellés d'abord, toutes les valeurs à
    /// la fin (« Distance, Durée… 3,4 km, 21 min ») (lot F, F-49).
    func feedTileSpeech(label: String, value: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringKey(label)) + Text(verbatim: " : \(value)"))
    }
}

/// Colonnes de largeur égale : une rangée ne partage pas sa largeur selon le
/// contenu, c'est donc la tuile la plus large qui décide du nombre de colonnes.
private struct FeedMetricLayout: Layout {
    var spacing: CGFloat

    private func columns(for width: CGFloat, subviews: Subviews) -> Int {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        for columns in [subviews.count, 2] where columns >= 2 && columns <= subviews.count {
            if CGFloat(columns) * widest + CGFloat(columns - 1) * spacing <= width { return columns }
        }
        return 1
    }

    private func rows(width: CGFloat, columns: Int, subviews: Subviews) -> (columnWidth: CGFloat, heights: [CGFloat]) {
        let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
        return (columnWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            // Taille idéale : une rangée de tuiles aussi larges que la plus large.
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let widest = sizes.map(\.width).max() ?? 0
            return CGSize(
                width: CGFloat(sizes.count) * widest + CGFloat(sizes.count - 1) * spacing,
                height: sizes.map(\.height).max() ?? 0
            )
        }
        let layout = rows(width: width, columns: columns(for: width, subviews: subviews), subviews: subviews)
        return CGSize(width: width, height: layout.heights.reduce(0, +) + CGFloat(layout.heights.count - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: bounds.width, subviews: subviews)
        let layout = rows(width: bounds.width, columns: columns, subviews: subviews)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            // Une tuile seule sur la dernière ligne prend toute la largeur plutôt
            // que d'en laisser la moitié vide (cinq valeurs d'un test d'expérience).
            let isLoneTile = row * columns + 1 == subviews.count
            for column in 0..<columns where row * columns + column < subviews.count {
                subviews[row * columns + column].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: isLoneTile ? bounds.width : layout.columnWidth, height: height)
                )
            }
            y += height + spacing
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

    @Environment(\.feedCardMenu) private var menu

    var body: some View {
        // J'aime, Commenter, Repartager à gauche ; Enregistrer et Partager à
        // droite. Plus de fond gris : la carte suffit à les regrouper. Quand
        // tout ne tient pas sur une ligne (très grand texte), les deux groupes
        // passent sur deux rangées plutôt que de couper les compteurs (F-24).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.xs) {
                leadingActions
                Spacer(minLength: 0)
                trailingActions
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SQSpace.xs) { leadingActions }
                HStack(spacing: SQSpace.xs) {
                    Spacer(minLength: 0)
                    trailingActions
                }
            }
        }
        .padding(.horizontal, -SQSpace.sm)
        .padding(.vertical, -SQSpace.xs)
        .buttonStyle(.plain)
        .font(SQType.subhead(.semibold))
        // VoiceOver lit la carte d'un bloc : la barre y ajoute ses compteurs en
        // mots (« 4 réactions, 2 commentaires », pas « 4, 🔥 4, 2 ») et ses
        // actions dans l'ordre d'usage, puis celles du menu ⋯ : plus de
        // Signaler en tête ni de J'aime en 9e (lot F, F-49, F-50).
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: spokenCounts))
        // Déclarées À REBOURS : mesuré à la sonde, SwiftUI expose ces actions dans
        // l'ordre inverse de leur déclaration (pas l'intérieur d'un ForEach).
        // VoiceOver propose donc J'aime, Commenter, Repartager, Enregistrer,
        // Partager, les réactions, puis le menu.
        .accessibilityActions {
            let like: LocalizedStringKey = item.likedByMe ? "Ne plus aimer" : "J’aime"
            let repost: LocalizedStringKey = item.repostedByMe ? "Annuler le repartage" : "Repartager"
            let favorite: LocalizedStringKey = item.favoritedByMe ? "Retirer des enregistrés" : "Enregistrer la publication"
            if let menu { menu }
            // Le sélecteur d'emojis s'ouvre à l'appui long, introuvable au
            // lecteur d'écran : chaque réaction est une action nommée.
            if let onReact {
                // À rebours aussi : sur cette énumération, la sonde les lisait inversées.
                ForEach(Array(FeedReaction.allCases.dropFirst().reversed()), id: \.self) { reaction in
                    Button(String(localized: "Réagir : \(reaction.name)")) { onReact(reaction.rawValue) }
                }
            }
            Button("Partager", action: onShare)
            Button(favorite, action: onFavorite)
            Button(repost, action: onRepost)
            Button("Commenter", action: onComment)
            Button(like, action: onLike)
        }
    }

    /// « 4 réactions (Génial 3), 2 commentaires, 1 repartage » ; rien sans activité.
    private var spokenCounts: String {
        var parts: [String] = []
        if reactionCount > 0 {
            let others = item.reactions
                .filter { $0.count > 0 && FeedReaction(emoji: $0.emoji) != .like }
                .sorted { $0.count > $1.count }
                .map { "\(FeedReaction.name(for: $0.emoji)) \($0.count)" }
            let total = String(localized: "\(reactionCount) réactions")
            parts.append(others.isEmpty ? total : "\(total) (\(others.joined(separator: ", ")))")
        }
        if item.commentsCount > 0 { parts.append(String(localized: "\(item.commentsCount) commentaires")) }
        if item.repostsCount > 0 { parts.append(String(localized: "\(item.repostsCount) repartages")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var leadingActions: some View {
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
    }

    @ViewBuilder
    private var trailingActions: some View {
        Button(action: onFavorite) {
            Image(systemName: item.favoritedByMe ? "bookmark.fill" : "bookmark")
                .foregroundStyle(item.favoritedByMe ? SQColor.brandRed : SQColor.chipInk)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(item.favoritedByMe ? "Retirer des enregistrés" : "Enregistrer la publication")
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

    /// Bouton ❤️ : tap = like ; appui long = les six réactions.
    private var likeButton: some View {
        HStack(spacing: 5) {
            Image(systemName: item.likedByMe ? "heart.fill" : "heart")
            if reactionCount > 0 {
                Text(SignalFormatters.count(reactionCount))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("feed.action.count")
            }
            // Les autres réactions posées sur la publication, du plus fréquent au
            // moins fréquent : le total seul cachait les réactions non ❤️. Des
            // symboles SF, pas les emojis stockés (Halo, F-27).
            if !topOtherSymbols.isEmpty {
                HStack(spacing: 2) {
                    ForEach(topOtherSymbols, id: \.self) { Image(systemName: $0) }
                }
                .font(SQType.caption)
                .accessibilityIdentifier("feed.action.emojis")
            }
        }
        .foregroundStyle(item.likedByMe ? SQColor.like : (reactedByMe ? SQColor.accentInk : SQColor.chipInk))
        .sqLikePop(trigger: item.likedByMe)
        .padding(.horizontal, SQSpace.sm)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onLike)
        // Un menu propre au ❤️ : l'appui long de la carte ouvre son propre menu
        // contextuel, qui prenait le pas sur l'ancien sélecteur flottant, jamais
        // affiché dans le fil. Le menu le plus proche du doigt l'emporte.
        .contextMenu { reactionMenu }
    }

    /// Rangée de symboles sous iOS 17 ; liste de libellés avant.
    @ViewBuilder
    private var reactionMenu: some View {
        let react = onReact ?? { _ in onLike() }
        if #available(iOS 17.0, *) {
            ControlGroup {
                ForEach(FeedReaction.allCases, id: \.self) { reaction in
                    Button { react(reaction.rawValue) } label: { Label(reaction.name, systemImage: reaction.symbol) }
                }
            }
            .controlGroupStyle(.palette)
            // Une palette reste ouverte après un choix par défaut.
            .menuActionDismissBehavior(.enabled)
        } else {
            ForEach(FeedReaction.allCases, id: \.self) { reaction in
                Button { react(reaction.rawValue) } label: { Label(reaction.name, systemImage: reaction.symbol) }
            }
        }
    }

    /// Réaction quelconque posée par l'utilisateur (❤️ ou un autre emoji).
    private var reactedByMe: Bool {
        item.likedByMe || item.reactions.contains { $0.reactedByMe == true }
    }

    private var topOtherSymbols: [String] {
        var symbols: [String] = []
        for reaction in item.reactions.filter({ $0.count > 0 && FeedReaction(emoji: $0.emoji) != .like }).sorted(by: { $0.count > $1.count }) {
            let symbol = FeedReaction.symbol(for: reaction.emoji)
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        return Array(symbols.prefix(3))
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

private struct FeedCardShowsAuthorKey: EnvironmentKey {
    static var defaultValue: Bool { true }
}

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

    /// Faux sur le profil d'un membre : son nom et son avatar en tête de
    /// chaque carte ne disaient rien de plus que la page (lot F, F-35).
    var feedCardShowsAuthor: Bool {
        get { self[FeedCardShowsAuthorKey.self] }
        set { self[FeedCardShowsAuthorKey.self] = newValue }
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
            if let measured = measuredDownload {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(verbatim: SQUnits.throughputValue(mbps: measured))
                        .font(SQFont.display(26, .heavy, relativeTo: .title))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: SQUnits.throughputUnit(mbps: measured))
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            } else {
                // Anciens posts dont le speedtest a disparu : pas de « — Mb/s » (F-12).
                Text("Résultat indisponible")
                    .font(SQType.subhead(.bold))
                    .foregroundStyle(SQColor.ink2)
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

    /// Débit de réception réellement mesuré ; zéro ou absent ne s'affiche pas.
    private var measuredDownload: Double? {
        guard let download, download > 0 else { return nil }
        return download
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
        var parts = [measuredDownload.map { String(localized: "réception \(SignalFormatters.speed($0))") }
            ?? String(localized: "Résultat indisponible")]
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
