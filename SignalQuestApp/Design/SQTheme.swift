import SwiftUI

/// Neutral, appearance-adaptive background. Replaces the previous always-dark
/// gradient and lets the iOS system light/dark setting drive the colorScheme.
struct SQBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            content
        }
        .tint(SQColor.brandRed)
    }
}

/// Hero background : depuis la DA « Crème & Terre cuite », les écrans marquants
/// (Auth, Speedtest) partagent le fond crème uni — plus de dégradé ni de halo.
struct SQHeroBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            content
        }
        .tint(SQColor.brandRed)
    }
}

extension View {
    func signalQuestBackground() -> some View {
        modifier(SQBackground())
    }

    func signalQuestHeroBackground() -> some View {
        modifier(SQHeroBackground())
    }
}

/// Typographie Halo : Sora partout, échelle « téléphone » de la planche P2-33
/// (`.is-mobile` de `halo.css`). Tailles relatives aux styles système pour
/// préserver Dynamic Type. Écarts iOS validés par Alexandre (12/10) : corps à 15 pt (14 sur le
/// web) et boutons à 15 pt, parce qu'iOS lit le texte courant plus grand.
enum SQType {
    // Calculés à chaque lecture : la graisse suit le mode terrain et « Texte en gras ».
    /// Gros titres de page (salutation, titres d'écran) — Sora ExtraBold 22 (`.h-h1`).
    static var display: Font { SQFont.display(22, .bold, relativeTo: .largeTitle) }
    /// Titres de sections majeures / sheets — Sora ExtraBold 18 (titre de feuille
    /// de la planche, plan « Fenêtres »).
    static var title: Font { SQFont.display(18, .bold, relativeTo: .title2) }
    /// Titres de cartes, tuiles — Sora ExtraBold 15 (`.h-title`).
    static var heading: Font { SQFont.display(15, .bold, relativeTo: .headline) }
    /// Corps de texte — Sora 15.
    static var body: Font { SQFont.body(15, relativeTo: .body) }
    static var callout: Font { SQFont.body(14, relativeTo: .callout) }
    /// Sous-titres, lignes clé-valeur — Sora Medium 13 (`.h-kv`).
    static var subhead: Font { SQFont.body(13, .medium, relativeTo: .subheadline) }
    /// Métadonnées, horodatages — Sora 12 (`.h-meta`, plancher de lisibilité).
    static var caption: Font { SQFont.body(12, relativeTo: .footnote) }
    /// Micro-labels (dock, badges, puces) — Sora SemiBold 12, casse normale (puce
    /// du kit : 11,5 px). Pas moins : à 11 pt, les étiquettes devenaient pénibles
    /// à lire (TRX-12), et 12 est le plancher Halo.
    static var micro: Font { SQFont.body(12, .semibold, relativeTo: .caption2) }
    /// Libellés de boutons — Sora ExtraBold 15 (`.h-pill`, 13 sur le web).
    static var button: Font { SQFont.display(15, .bold) }
    /// Chiffres héros d'une carte de stats ou d'un cadran (total, débit mesuré) —
    /// Sora ExtraBold 46. Ajouter `.monospacedDigit()` à l'appel si la valeur change.
    static var metricLarge: Font { SQFont.display(46, .bold) }
    /// Valeur chiffrée d'une rangée ou d'une carte (dernière mesure, RSRP) —
    /// Sora ExtraBold 26 (`.h-data`). Même remarque pour `.monospacedDigit()`.
    static var metricMedium: Font { SQFont.display(26, .bold) }
    /// Valeur chiffrée d'une carte partagée ou d'une tuile de récap — Sora ExtraBold 20.
    static var metricSmall: Font { SQFont.display(20, .bold) }
    /// Nom en tête d'une rangée (conversation, auteur) — Sora Bold 15.
    static var rowTitle: Font { SQFont.body(15, .bold, relativeTo: .headline) }

    // Mêmes tailles avec une autre graisse. Passer par ici plutôt que par
    // `.weight()` : la graisse reste ajustée au mode terrain et à « Texte en gras ».
    static func body(_ weight: Font.Weight) -> Font { SQFont.body(15, weight, relativeTo: .body) }
    static func callout(_ weight: Font.Weight) -> Font { SQFont.body(14, weight, relativeTo: .callout) }
    static func subhead(_ weight: Font.Weight) -> Font { SQFont.body(13, weight, relativeTo: .subheadline) }
    static func caption(_ weight: Font.Weight) -> Font { SQFont.body(12, weight, relativeTo: .footnote) }
    static func micro(_ weight: Font.Weight) -> Font { SQFont.body(12, weight, relativeTo: .caption2) }
}

/// Surtitre Halo (`.h-kicker`) : capitales, interlettrage 0,18 em, gris `muted`.
/// 11 pt sur iOS (10 px sur le web), décision du 12/10 : l'exception documentée au
/// plancher de 12 pt, réservée aux étiquettes de section qui ne portent jamais
/// une information absente ailleurs.
extension Text {
    func sqKicker() -> some View {
        self.font(SQFont.body(11, .bold, relativeTo: .caption2))
            .tracking(11 * 0.18)
            .textCase(.uppercase)
            .foregroundStyle(SQColor.labelSecondary)
    }
}
