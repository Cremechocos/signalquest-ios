import SwiftUI
import UIKit

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
    /// Clé de l'arc tracé une fois (badge Premium d'un auteur mis en valeur, dans le fil) :
    /// l'arc se dessine en 0,9 s la première fois que la clé paraît depuis l'ouverture de
    /// l'app, puis reste entier (planche « Badge Premium animé », comme Android).
    var arcAnimationKey: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arcProgress: CGFloat

    init(style: SQUserBadgeStyle, size: CGFloat = 17, arcAnimationKey: String? = nil) {
        self.style = style
        self.size = size
        self.arcAnimationKey = arcAnimationKey
        let pending = arcAnimationKey.map { !SQTierArcLedger.shared.hasPlayed($0) } ?? false
        _arcProgress = State(initialValue: pending ? 0 : 1)
    }

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
            .trim(from: 0, to: arcProgress)
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
        .onAppear {
            guard arcProgress < 1, let key = arcAnimationKey else { return }
            SQTierArcLedger.shared.markPlayed(key)
            // Réduire les animations : le badge est entier tout de suite.
            if reduceMotion {
                arcProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { arcProgress = 1 }
            }
        }
    }
}

/// Publications dont l'arc du badge Premium a déjà été tracé depuis l'ouverture de l'app :
/// « une fois par publication et par ouverture » (planche 8). Une carte recyclée au retour
/// dans le fil ne le rejoue pas.
@MainActor
final class SQTierArcLedger {
    static let shared = SQTierArcLedger()
    private var played = Set<String>()

    func hasPlayed(_ key: String) -> Bool { played.contains(key) }
    func markPlayed(_ key: String) { played.insert(key) }
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
    /// Voir `SQTierBadge.arcAnimationKey` : seul le badge Premium trace son arc.
    var premiumArcAnimationKey: String? = nil

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
                        SQTierBadge(style: style, size: size + 4,
                                    arcAnimationKey: style == .premium ? premiumArcAnimationKey : nil)
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

// MARK: - Profil mis en valeur (D13)

extension ProfileSpotlight.Accent {
    /// Les six encres (contrat Abonnements §3, planche 8), mêmes valeurs qu'Android. Une encre ne
    /// colore JAMAIS un texte (l'Or clair n'atteint que 3,5:1 sur le papier) : anneau d'avatar,
    /// bannière et courbe seulement. Les valeurs sombres servent au thème sombre comme au noir OLED.
    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .gold: return (0xA9761A, 0xE8B54A)
        case .slate: return (0x3E4A52, 0x9FB0BC)
        case .plum: return (0x6B3A55, 0xD29AB8)
        case .fir: return (0x2F5A4C, 0x84C1AC)
        case .brick: return (0x8E4A33, 0xE3A083)
        case .ink: return (0x1C201E, 0xE6EBE7)
        }
    }

    var ink: Color {
        let values = hex
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? values.dark : values.light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        })
    }

    var label: String {
        switch self {
        case .gold: return String(localized: "Or")
        case .slate: return String(localized: "Ardoise")
        case .plum: return String(localized: "Prune")
        case .fir: return String(localized: "Sapin")
        case .brick: return String(localized: "Brique")
        case .ink: return String(localized: "Encre")
        }
    }
}

/// Bannière d'un membre Premium : décorative, VoiceOver ne la lit pas.
/// « Mes mesures » : la courbe à l'encre sur un dégradé très léger de l'encre ; « photo » :
/// l'image servie (déjà taillée en 1200 × 630) ; « aucune » : rien, l'appelant ne la pose pas.
struct SQSpotlightBanner: View {
    let spotlight: ProfileSpotlight

    var body: some View {
        let ink = spotlight.accent.ink
        ZStack {
            switch spotlight.banner {
            case .photo(let url):
                RemoteImage(url: url, maxDimension: 600, contentMode: .fill) {
                    Rectangle().fill(SQColor.fill)
                }
            case .measures(let series):
                LinearGradient(colors: [ink.opacity(0.16), ink.opacity(0.03)], startPoint: .top, endPoint: .bottom)
                SQSpotlightCurve(series: series, ink: ink)
            case .empty:
                EmptyView()
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Courbe « Mes mesures » : lissée, elle passe par chaque point sans dépasser verticalement entre
/// deux valeurs (même calcul qu'Android : Catmull-Rom ramené en Bézier, points de contrôle bornés).
struct SQSpotlightCurve: View {
    let series: [Double]
    let ink: Color

    var body: some View {
        Canvas { context, size in
            let points = Self.points(series, in: size, padX: 12, padY: 10)
            guard points.count >= 2, let last = points.last, let first = points.first else { return }
            let line = Self.path(points)
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [ink.opacity(0.18), ink.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(ink.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            let r: CGFloat = 3.2
            context.fill(Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(ink))
        }
    }

    /// Abscisses réparties sur la largeur, 1,0 en haut.
    static func points(_ series: [Double], in size: CGSize, padX: CGFloat, padY: CGFloat) -> [CGPoint] {
        guard series.count >= 2 else { return [] }
        let usableW = size.width - 2 * padX
        let usableH = size.height - 2 * padY
        let step = usableW / CGFloat(series.count - 1)
        return series.enumerated().map { index, value in
            CGPoint(x: padX + step * CGFloat(index),
                    y: size.height - padY - CGFloat(min(max(value, 0), 1)) * usableH)
        }
    }

    struct Segment: Equatable {
        let c1: CGPoint
        let c2: CGPoint
        let end: CGPoint
    }

    static func segments(_ points: [CGPoint]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).map { i in
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let lo = min(p1.y, p2.y)
            let hi = max(p1.y, p2.y)
            return Segment(
                c1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, lo), hi)),
                c2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, lo), hi)),
                end: p2
            )
        }
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in segments(points) {
            path.addCurve(to: segment.end, control1: segment.c1, control2: segment.c2)
        }
        return path
    }
}
