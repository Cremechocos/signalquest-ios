import SwiftUI

/// Ce que raconte un post automatique (quête, niveau, badge, série, site, récap
/// officiel), lu dans son `metadata` plutôt que dans le texte français du serveur
/// (lot F, F-09 à F-11). Les chiffres viennent du metadata : l'app les met en
/// forme dans sa langue ; le texte du serveur ne sert que de repli.
struct FeedActivity: Equatable {
    enum Family: Equatable {
        case quest, level, badge, streak, siteDiscovered, siteVisited, department
        case bugResolved, customSite, officialRecap, telecom, other
    }

    /// Où mène le post dans l'app, depuis son détail.
    enum Link: Equatable {
        case site(id: String, market: String?)
        case progression
        case bug(id: String)
        /// La feuille de la panne, sinon son site.
        case outage(id: String?, siteId: String?, market: String?)
        /// La carte principale, sur cette session seule (contrat #958).
        case session(id: String, title: String?)
    }

    /// Quête atteinte (#835) : ce que demandait la quête, lu dans le catalogue
    /// actuel du serveur, pas celui du jour de la réclamation.
    struct Quest: Equatable {
        let cadence: QuestCadenceGroup?
        /// Objectif mis en forme ; `nil` quand la mesure ne se nomme pas (`event_count`).
        let goal: String?
        /// Consigne du catalogue : elle n'existe qu'en français.
        let description: String?
    }

    let family: Family
    /// Points gagnés par l'activité, quand le serveur les donne.
    let points: Int?
    let title: String
    let subtitle: String?
    let link: Link?
    let quest: Quest?
    /// Niveau atteint et niveau quitté, pour un passage de niveau.
    let level: Int?
    let previousLevel: Int?
    /// Ce que récompense le badge. Le catalogue du serveur n'existe qu'en français :
    /// rien en anglais plutôt qu'une phrase dans une autre langue (revue q34, constat 6).
    let badgeDescription: String?

    /// `nil` pour une publication ordinaire : elle garde sa carte de post.
    init?(item: UnifiedSocialFeedItem, appIsFrench: Bool = SQAddress.appIsFrench) {
        let metadata = item.metadata ?? [:]
        func string(_ key: String) -> String? {
            guard case .string(let value)? = metadata[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func int(_ key: String) -> Int? {
            switch metadata[key] {
            case .number(let value)? where value.isFinite && abs(value) < 1e9: return Int(value)
            case .string(let value)?: return Int(value)
            default: return nil
            }
        }
        let kind = item.kind.lowercased()
        let activity = string("activityType")
        let source = string("source")?.lowercased() ?? ""
        let family: Family
        switch (kind, activity) {
        case ("post", _) where source.hasPrefix("netmonster"): family = .officialRecap
        case ("telecom", _): family = .telecom
        // Un site communautaire arrive en `validation` : targetType le distingue
        // même quand activityType manque (revue q34, constat 5).
        case ("site", _), (_, "custom_site_created"): family = .customSite
        case ("validation", _) where item.targetType?.lowercased() == "custom_site": family = .customSite
        case ("badge", "quest_claim"): family = .quest
        case ("badge", "level_up"): family = .level
        case ("badge", "badge_earned"): family = .badge
        case ("badge", "streak_bonus"): family = .streak
        case ("badge", "new_site_visited"):
            family = metadata["firstDiscovery"] == .bool(true) ? .siteDiscovered : .siteVisited
        case ("badge", "new_department"): family = .department
        case ("badge", "bug_report_resolved"): family = .bugResolved
        case ("badge", _): family = .other
        default: return nil
        }
        self.family = family
        // Un récap officiel ne fait gagner de points à personne.
        self.points = family == .officialRecap ? nil : int("points").flatMap { $0 > 0 ? $0 : nil }
        // Une clé retirée du catalogue n'a aucun de ces champs : la carte garde son repli.
        self.badgeDescription = family == .badge && appIsFrench ? string("badgeDescription") : nil
        self.quest = family == .quest
            ? Self.quest(cadence: string("cadence"), metric: string("questMetric"), target: int("questTargetValue"),
                         description: appIsFrench ? string("questDescription") : nil)
            : nil

        // La phrase traduite remplace le français du serveur partout où il
        // servait de titre ou de repli (F8).
        let key = FeedTextKey(key: item.textKey, args: item.textArgs)
        self.level = family == .level ? (int("newLevel") ?? key?.integer("level").map { Int(clamping: $0) }) : nil
        self.previousLevel = family == .level ? int("oldLevel") : nil
        let text = (key?.text ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = Self.quotedName(in: item.text)
        let siteLink = string("siteId").map { Link.site(id: $0, market: string("marketCode")) }
        let isMine = item.isMine == true
        switch family {
        case .quest:
            title = String(localized: "Quête terminée")
            subtitle = string("questTitle") ?? key?.string("questTitle") ?? quoted
            link = isMine ? .progression : nil
        case .level:
            if let level = int("newLevel") ?? key?.integer("level").map({ Int(clamping: $0) }) {
                title = String(localized: "Niveau \(level) atteint")
            } else {
                title = text.isEmpty ? String(localized: "Nouveau niveau") : text
            }
            subtitle = nil
            link = isMine ? .progression : nil
        case .badge:
            title = String(localized: "Badge obtenu")
            subtitle = string("badgeName") ?? key?.string("badgeName") ?? quoted
            link = isMine ? .progression : nil
        case .streak:
            if let days = int("streak") ?? key?.integer("days").map({ Int(clamping: $0) }) {
                title = String(localized: "Série de \(days) jours")
            } else {
                title = text.isEmpty ? String(localized: "Série en cours") : text
            }
            subtitle = nil
            link = isMine ? .progression : nil
        case .siteDiscovered:
            title = String(localized: "Site découvert en premier")
            subtitle = nil
            link = siteLink
        case .siteVisited:
            title = String(localized: "Nouveau site exploré")
            subtitle = nil
            link = siteLink
        case .department:
            title = String(localized: "Nouveau département exploré")
            subtitle = key?.string("departmentCode") ?? string("dept")
            link = siteLink
        case .bugResolved:
            title = String(localized: "Signalement de bug validé")
            // Le titre du signalement suit les deux-points du texte serveur.
            subtitle = item.text.range(of: ": ").map { String(item.text[$0.upperBound...]) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            link = isMine ? string("bugId").map { Link.bug(id: $0) } : nil
        case .customSite:
            title = String(localized: "Site ajouté sur la carte")
            subtitle = string("customSiteName") ?? key?.string("siteName") ?? quoted
            // Un site communautaire ne se retrouve pas par la recherche de la carte.
            link = nil
        case .officialRecap:
            title = String(localized: "Récap officiel")
            subtitle = text.isEmpty ? nil : text
            link = nil
        case .telecom:
            // « a ajouté une activité telecom » n'apprenait rien (F-10).
            title = String(localized: "Activité réseau")
            subtitle = nil
            link = nil
        case .other:
            title = text.isEmpty ? String(localized: "Récompense obtenue") : text
            subtitle = nil
            link = isMine ? .progression : nil
        }
    }

    static func quest(cadence: String?, metric: String?, target: Int?, description: String?) -> Quest? {
        let goal = target.flatMap { $0 > 0 ? questGoal(metric: metric, target: $0) : nil }
        let cadenceGroup = cadence.map { QuestCadenceGroup(rawCadence: $0) }.flatMap { $0 == .other ? nil : $0 }
        guard goal != nil || cadenceGroup != nil || description != nil else { return nil }
        return Quest(cadence: cadenceGroup, goal: goal, description: description)
    }

    /// Ce que compte la cible, dans la langue de l'app (`QuestMetric` du serveur).
    /// `event_count` compte des actions différentes d'une quête à l'autre : la
    /// consigne seule les nomme.
    static func questGoal(metric: String?, target: Int) -> String? {
        switch metric {
        case "coverage_points": return String(localized: "\(target) points de couverture")
        case "coverage_distance_km": return String(localized: "\(target) km de sessions")
        case "multi_cell_points": return String(localized: "\(target) points multi-cellules")
        case "distinct_operators": return String(localized: "\(target) opérateurs différents")
        case "distinct_technologies": return String(localized: "\(target) technologies différentes")
        case "photo_uploads": return String(localized: "\(target) photos envoyées")
        case "speedtests": return String(localized: "\(target) tests de débit")
        case "validations": return String(localized: "\(target) validations de site")
        default: return nil
        }
    }

    /// Nom entre guillemets droits ou français du texte serveur
    /// (`Quête "Explorer le réseau" terminée`).
    static func quotedName(in text: String) -> String? {
        for (open, close) in [("\"", "\""), ("« ", " »"), ("“", "”")] {
            guard let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { continue }
            let name = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    var symbol: String {
        switch family {
        case .quest: return "flag.checkered"
        case .level: return "star.circle.fill"
        case .badge, .other: return "rosette"
        case .streak: return "flame.fill"
        case .siteDiscovered: return "binoculars.fill"
        case .siteVisited: return "mappin.circle.fill"
        case .department: return "map.fill"
        case .bugResolved: return "ladybug.fill"
        case .customSite: return "plus.circle.fill"
        case .officialRecap: return "checkmark.seal.fill"
        case .telecom: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Carte d'un post automatique : symbole de la famille, ce qui a été obtenu,
/// points gagnés. Le lien vers l'objet (site, progression, signalement) est
/// dans la feuille et le détail, pour ne pas imbriquer un bouton dans la carte.
struct ActivityCardView: View {
    let item: UnifiedSocialFeedItem
    let activity: FeedActivity
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: item.cardPlace,
                    createdAt: item.createdAt,
                    // Le compte SignalQuest se distingue d'un membre ordinaire (F-11).
                    kindBadge: activity.family == .officialRecap ? String(localized: "Officiel") : nil,
                    kindColor: SQColor.accentInk,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                switch activity.family {
                case .customSite:
                    CustomSiteActivityContent(item: item, activity: activity)
                case .quest, .level, .badge:
                    ProgressionActivityContent(activity: activity)
                    if let link = activity.link {
                        FeedOpenCapsule(title: link.title, destination: .link(link), prominent: false, onOpenPost: onTap)
                    }
                default:
                    ActivitySummaryRow(activity: activity)
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

/// Symbole de la famille, ce qui a été obtenu et les points : partagé par la
/// carte du fil et sa feuille de détail.
struct ActivitySummaryRow: View {
    let activity: FeedActivity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: (ink: Color, soft: Color) {
        switch activity.family {
        case .siteDiscovered, .siteVisited, .department, .customSite: return (SQColor.success, SQColor.successSoft)
        case .streak: return (SQColor.warning, SQColor.warningSoft)
        default: return (SQColor.accentInk, SQColor.accentSoft)
        }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    glyph
                    summary
                    pointsTag
                }
            } else {
                HStack(alignment: .center, spacing: SQSpace.md) {
                    glyph
                    summary
                    Spacer(minLength: 0)
                    pointsTag
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.activity")
    }

    private var glyph: some View {
        Image(systemName: activity.symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(tint.ink)
            .frame(width: 48, height: 48)
            .background(tint.soft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityHidden(true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: activity.title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = activity.subtitle {
                Text(verbatim: subtitle)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let description = activity.badgeDescription {
                Text(verbatim: description)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var pointsTag: some View {
        if let points = activity.points {
            SQEditorialTag(text: String(localized: "+\(points) pts"), color: tint.ink)
                .accessibilityLabel(String(localized: "\(points) points gagnés"))
        }
    }
}

extension FeedActivity.Link {
    var title: String {
        switch self {
        case .site: return String(localized: "Voir le site")
        case .progression: return String(localized: "Voir ma progression")
        case .bug: return String(localized: "Voir mon signalement")
        case .outage: return String(localized: "Voir la panne")
        case .session: return String(localized: "Voir le tracé")
        }
    }

    var symbol: String {
        switch self {
        case .site: return "mappin.and.ellipse"
        case .progression: return "chart.line.uptrend.xyaxis"
        case .bug: return "ladybug"
        case .outage: return "exclamationmark.triangle"
        case .session: return "map"
        }
    }

    @MainActor
    func open(with router: AppRouter) {
        switch self {
        case .site(let id, let market): router.route(toSite: id, market: market)
        case .progression: router.route(toProfileScreen: .progression)
        case .bug(let id): router.route(toBug: id)
        case .outage(let id, let siteId, let market): router.route(toCommunityOutageId: id, fallbackSiteId: siteId, market: market)
        case .session(let id, let title): router.route(toMapSession: id, title: title)
        }
    }
}

/// Site ajouté sur la carte : un plan avec son repère, son nom, la commune, qui
/// l'utilise et à qui il appartient (refonte du 04/11). Le plan est centré sur
/// la position servie, arrondie par le serveur.
private struct CustomSiteActivityContent: View {
    let item: UnifiedSocialFeedItem
    let activity: FeedActivity

    private var operators: String? {
        guard case .array(let values)? = item.metadata?["hostedOperators"] else {
            return item.metadataString("mobileOperator") ?? item.signal?.operator
        }
        let names = values.compactMap { value -> String? in
            guard case .string(let key) = value, !key.isEmpty else { return nil }
            return SQBrand.operatorName(key) ?? key
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var metrics: [FeedMetricGrid.Metric] {
        var metrics: [FeedMetricGrid.Metric] = []
        if let operators { metrics.append(.init(label: String(localized: "Opérateurs"), value: operators)) }
        if let owner = item.metadataString("infraOwnerOperator") {
            metrics.append(.init(label: String(localized: "Propriétaire"), value: SQBrand.operatorName(owner) ?? owner))
        }
        return metrics
    }

    var body: some View {
        FeedKindLine(symbol: "plus", title: String(localized: "A ajouté un site"), points: activity.points)

        if let coordinate = item.cardCoordinate {
            FeedPlaceSnapshot(cacheKey: item.id, coordinate: coordinate, aspect: 16 / 7,
                              marker: "antenna.radiowaves.left.and.right") { EmptyView() }
                .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: SQSpace.xxs) {
            Text(verbatim: activity.subtitle ?? activity.title)
                .font(SQFont.display(20, .bold, relativeTo: .title3))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            if let place = item.cardPlace ?? item.metadataString("placeLabel") {
                Text(verbatim: place)
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityElement(children: .combine)

        if !metrics.isEmpty {
            FeedMetricGrid(metrics: metrics)
        }

        if let description = item.metadataString("customSiteDescription") {
            Text(verbatim: description)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Quête, niveau et badge : une célébration sobre, olive et ambre (PRODUCT.md).
private struct ProgressionActivityContent: View {
    let activity: FeedActivity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch activity.family {
        case .level:
            FeedKindLine(symbol: "arrow.up", title: String(localized: "Nouveau niveau"), tint: .success, points: activity.points)
            levelLine
        case .quest:
            emblemRow { questRing } text: {
                // Sans nom de quête servi, la phrase d'accomplissement devient le titre.
                if let name = activity.subtitle {
                    Text(verbatim: questKicker).font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                    Text(verbatim: name)
                        .font(SQFont.display(20, .bold, relativeTo: .title3))
                        .foregroundStyle(SQColor.label)
                } else {
                    Text(verbatim: questKicker)
                        .font(SQFont.display(20, .bold, relativeTo: .title3))
                        .foregroundStyle(SQColor.label)
                }
                if let goal = activity.quest?.goal ?? activity.quest?.description {
                    Text(verbatim: goal).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                }
                if let chip = questChip {
                    SQEditorialTag(text: chip, color: SQColor.success).padding(.top, SQSpace.xxs)
                }
            }
        default:
            emblemRow { medal } text: {
                Text("Nouveau badge").font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                Text(verbatim: activity.subtitle ?? activity.title)
                    .font(SQFont.display(20, .bold, relativeTo: .title3))
                    .foregroundStyle(SQColor.label)
                if let description = activity.badgeDescription {
                    Text(verbatim: description).font(SQType.caption).foregroundStyle(SQColor.ink2)
                }
                if let points = activity.points {
                    SQEditorialTag(text: String(localized: "+\(points) pts"), color: SQColor.success)
                        .accessibilityLabel(String(localized: "\(points) points gagnés"))
                        .padding(.top, SQSpace.xxs)
                }
            }
        }
    }

    private func emblemRow<Emblem: View, Content: View>(@ViewBuilder _ emblem: () -> Emblem,
                                                        @ViewBuilder text: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.md))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.lg))
        return layout {
            emblem().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xxs) { text() }
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.activity")
    }

    /// « Quête du jour accomplie », selon la cadence quand le serveur la donne.
    private var questKicker: String {
        switch activity.quest?.cadence {
        case .daily?: return String(localized: "Quête du jour accomplie")
        case .weekly?: return String(localized: "Quête de la semaine accomplie")
        case .seasonal?: return String(localized: "Quête de saison accomplie")
        case .event?: return String(localized: "Quête d’événement accomplie")
        default: return String(localized: "Quête accomplie")
        }
    }

    private var questChip: String? {
        let cadence: String?
        switch activity.quest?.cadence {
        case .daily?: cadence = String(localized: "Quotidienne")
        case .weekly?: cadence = String(localized: "Hebdomadaire")
        case .seasonal?: cadence = String(localized: "Saisonnière")
        case .event?: cadence = String(localized: "Événement")
        default: cadence = nil
        }
        let parts = [cadence, activity.points.map { String(localized: "+\($0) pts") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var questRing: some View {
        ZStack {
            Circle().stroke(SQColor.successSoft, lineWidth: 7)
            Circle().stroke(SQColor.success, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(SQColor.success)
        }
        .frame(width: 64, height: 64)
        .padding(4)
    }

    private var medal: some View {
        Image(systemName: "medal.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(SQColor.warning)
            .frame(width: 72, height: 72)
            .background(SQColor.warningSoft, in: Circle())
    }

    /// « 11 › Niveau 12 », l'ancien niveau en retrait.
    @ViewBuilder
    private var levelLine: some View {
        if let level = activity.level {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                if let old = activity.previousLevel {
                    Text(verbatim: old.formatted())
                        .font(SQFont.display(26, .bold, relativeTo: .title))
                        .foregroundStyle(SQColor.labelSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
                Text(String(localized: "Niveau \(level)"))
                    .font(SQFont.display(36, .heavy, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: activity.title))
        } else {
            Text(verbatim: activity.title)
                .font(SQFont.display(20, .bold, relativeTo: .title3))
                .foregroundStyle(SQColor.label)
        }
    }
}
