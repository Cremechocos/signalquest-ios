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
    }

    let family: Family
    /// Points gagnés par l'activité, quand le serveur les donne.
    let points: Int?
    let title: String
    let subtitle: String?
    let link: Link?

    /// `nil` pour une publication ordinaire : elle garde sa carte de post.
    init?(item: UnifiedSocialFeedItem) {
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
        case ("site", _), (_, "custom_site_created"): family = .customSite
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

        // La phrase traduite remplace le français du serveur partout où il
        // servait de titre ou de repli (F8).
        let key = FeedTextKey(key: item.textKey, args: item.textArgs)
        let text = (key?.text ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = Self.quotedName(in: item.text)
        let siteLink = string("siteId").map { Link.site(id: $0, market: string("marketCode")) }
        let isMine = item.isMine == true
        switch family {
        case .quest:
            title = String(localized: "Quête terminée")
            subtitle = key?.string("questTitle") ?? quoted
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
                    place: item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    // Le compte SignalQuest se distingue d'un membre ordinaire (F-11).
                    kindBadge: activity.family == .officialRecap ? String(localized: "Officiel") : nil,
                    kindColor: SQColor.accentInk,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                ActivitySummaryRow(activity: activity)

                if let technology = item.signal?.technology, activity.family == .customSite {
                    SQEditorialTag(text: [item.signal?.operator, technology].compactMap { $0 }.joined(separator: " · "),
                                   color: TechAccent.color(for: technology))
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
        }
    }

    var symbol: String {
        switch self {
        case .site: return "mappin.and.ellipse"
        case .progression: return "chart.line.uptrend.xyaxis"
        case .bug: return "ladybug"
        }
    }

    @MainActor
    func open(with router: AppRouter) {
        switch self {
        case .site(let id, let market): router.route(toSite: id, market: market)
        case .progression: router.route(toProfileScreen: .progression)
        case .bug(let id): router.route(toBug: id)
        }
    }
}
