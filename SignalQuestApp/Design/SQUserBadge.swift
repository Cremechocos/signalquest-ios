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
        case .premium: return Color(red: 0.96, green: 0.62, blue: 0.04)       // #F59E0B
        case .basic: return Color(red: 0.69, green: 0.48, blue: 0.24)         // #B07A3C
        case .creator: return Color(red: 0.98, green: 0.45, blue: 0.09)       // #F97316
        case .moderator: return Color(red: 0.06, green: 0.73, blue: 0.51)     // #10B981
        case .developer: return Color(red: 0.02, green: 0.71, blue: 0.83)     // #06B6D4
        case .earlySupporter: return Color(red: 0.93, green: 0.28, blue: 0.60) // #EC4899
        }
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
                    Image(systemName: style.systemImage)
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(style.color)
                        .accessibilityLabel(style.label)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
