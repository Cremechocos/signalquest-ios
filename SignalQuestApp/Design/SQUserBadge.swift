import SwiftUI

/// La coche affichée à côté d'un nom : officiel, vérifié, abonné…
///
/// Le catalogue fait autorité côté serveur (`packages/core/social/badges.ts`) ;
/// on n'en reprend ici que le rendu. Un genre inconnu n'est PAS affiché plutôt
/// que rendu par défaut : ajouter un badge au catalogue ne doit pas obliger à
/// mettre l'app à jour, et une pastille grise sans signification vaut moins que
/// pas de pastille.
enum SQUserBadgeStyle {
    case official, verified, premium, basic, creator, moderator, developer, earlySupporter

    init?(kind: String) {
        switch kind {
        case "official": self = .official
        case "verified": self = .verified
        case "premium": self = .premium
        case "basic": self = .basic
        case "creator": self = .creator
        case "moderator": self = .moderator
        case "developer": self = .developer
        case "early_supporter": self = .earlySupporter
        default: return nil
        }
    }

    /// Couleurs reprises du catalogue serveur, pour que les trois plateformes
    /// montrent la même chose. Ce sont des couleurs SÉMANTIQUES : elles ne
    /// suivent pas le thème, exactement comme l'orange d'hypothèse de la carte.
    var color: Color {
        switch self {
        case .official: return Color(red: 0.23, green: 0.51, blue: 0.96)      // #3B82F6
        case .verified: return Color(red: 0.55, green: 0.36, blue: 0.96)      // #8B5CF6
        // Premium et Basic ne passent plus par ici : ils ont leur propre
        // dessin (cf. `isTier` et `SQTierBadge`). Les valeurs restent pour les
        // rendus hérités qui liraient encore `color`.
        case .premium: return Color("SQBadgeArcPremium")
        case .basic: return Color("SQBadgeArcBasic")
        case .creator: return Color(red: 0.98, green: 0.45, blue: 0.09)       // #F97316
        case .moderator: return Color(red: 0.06, green: 0.73, blue: 0.51)     // #10B981
        case .developer: return Color(red: 0.02, green: 0.71, blue: 0.83)     // #06B6D4
        case .earlySupporter: return Color(red: 0.93, green: 0.28, blue: 0.60) // #EC4899
        }
    }

    /// Les paliers d'abonnement portent leur propre dessin plutôt qu'un
    /// SF Symbol teinté : un rang n'est pas une typologie, Premium et Basic
    /// doivent se lire l'un contre l'autre, ce qu'un glyphe couronne/étoile
    /// ne permet pas à 13 pt.
    var isTier: Bool {
        self == .premium || self == .basic
    }

    var systemImage: String {
        switch self {
        case .official: return "checkmark.seal.fill"
        case .verified: return "checkmark.shield.fill"
        case .premium: return "crown.fill"
        case .basic: return "star.fill"
        case .creator: return "bolt.fill"
        case .moderator: return "shield.lefthalf.filled"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .earlySupporter: return "heart.fill"
        }
    }

    var label: String {
        switch self {
        case .official: return String(localized: "Officiel")
        case .verified: return String(localized: "Vérifié")
        case .premium: return String(localized: "Premium")
        case .basic: return String(localized: "Basic")
        case .creator: return String(localized: "Créateur")
        case .moderator: return String(localized: "Modérateur")
        case .developer: return String(localized: "Équipe")
        case .earlySupporter: return String(localized: "Pionnier")
        }
    }
}

/// Le badge de palier : disque d'encre, coche, et un arc de secteur d'antenne
/// dont la couleur EST le rang.
///
/// Dessiné en `Path` plutôt qu'importé en asset : un SF Symbol custom aplatit
/// un glyphe tricolore en une seule teinte. La géométrie est reprise trait
/// pour trait de `packages/core/social/tier-badge.svg` (repère 24×24), source
/// de vérité partagée avec le web et Android — si elle y change, ce corps est
/// à resynchroniser.
struct SQTierBadge: View {
    let style: SQUserBadgeStyle
    var size: CGFloat = 17

    /// Facteur d'échelle depuis le repère 24×24 du fichier source.
    private var s: CGFloat { size / 24 }
    private var center: CGPoint { CGPoint(x: 12 * s, y: 12 * s) }

    var body: some View {
        ZStack {
            // Arc de secteur. `clockwise: false` — l'axe y descend, donc c'est
            // bien un arc horaire à l'écran, de -100° à -10° comme le SVG.
            Path { path in
                path.addArc(center: center,
                            radius: 10.6 * s,
                            startAngle: .degrees(-100),
                            endAngle: .degrees(-10),
                            clockwise: false)
            }
            .stroke(style.color, style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))

            Circle()
                .fill(Color("SQBadgeDisc"))
                .frame(width: 17 * s, height: 17 * s)

            Path { path in
                path.move(to: CGPoint(x: 8.35 * s, y: 12.2 * s))
                path.addLine(to: CGPoint(x: 10.85 * s, y: 14.7 * s))
                path.addLine(to: CGPoint(x: 15.65 * s, y: 9.35 * s))
            }
            .stroke(Color("SQBadgeTick"),
                    style: StrokeStyle(lineWidth: 2.25 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(style.label)
    }
}

/// Les badges d'un auteur, en ligne après son nom.
///
/// Plafonnés à deux : au-delà, la rangée pousse le nom hors de l'écran sur les
/// cartes étroites, et c'est le nom qui compte. L'ordre vient du serveur, qui
/// place déjà les badges les plus signifiants en tête.
struct SQUserBadges: View {
    let badges: [SocialUserBadge]
    var size: CGFloat = 13
    var limit: Int = 2

    private var styles: [SQUserBadgeStyle] {
        badges.compactMap { SQUserBadgeStyle(kind: $0.kind) }.prefix(limit).map { $0 }
    }

    var body: some View {
        if !styles.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                    if style.isTier {
                        // +4 pour que l'emprise du dessin égale celle d'un
                        // SF Symbol réglé à `size`, comme sur le web.
                        SQTierBadge(style: style, size: size + 4)
                    } else {
                        Image(systemName: style.systemImage)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(style.color)
                            .accessibilityLabel(style.label)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
