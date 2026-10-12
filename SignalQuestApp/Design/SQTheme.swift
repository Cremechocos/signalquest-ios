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

/// Typographie de la DA « Crème & Terre cuite ». Deux familles :
/// Bricolage Grotesque (titres, chiffres, boutons) et Figtree (corps, UI).
/// Tailles relatives aux styles système pour préserver Dynamic Type.
enum SQType {
    // Calculés à chaque lecture : la graisse suit le mode terrain et « Texte en gras ».
    /// Gros titres de page (salutation, titres d'écran) — Bricolage Bold 26.
    static var display: Font { SQFont.display(26, .bold, relativeTo: .largeTitle) }
    /// Titres de sections majeures / sheets — Bricolage Bold 24.
    static var title: Font { SQFont.display(24, .bold, relativeTo: .title2) }
    /// Titres de cartes, tuiles — Bricolage SemiBold 16.5.
    static var heading: Font { SQFont.display(16.5, .semibold, relativeTo: .headline) }
    /// Corps de texte — Figtree 15.
    static var body: Font { SQFont.body(15, relativeTo: .body) }
    static var callout: Font { SQFont.body(14.5, relativeTo: .callout) }
    /// Sous-titres — Figtree Medium 13.5.
    static var subhead: Font { SQFont.body(13.5, .medium, relativeTo: .subheadline) }
    /// Sous-titres, horodatages — Figtree 12.5.
    static var caption: Font { SQFont.body(12.5, relativeTo: .footnote) }
    /// Micro-labels (dock, badges) — Figtree SemiBold 12, casse normale. Pas
    /// moins : à 11 pt, les étiquettes devenaient pénibles à lire (TRX-12).
    static var micro: Font { SQFont.body(12, .semibold, relativeTo: .caption2) }
    /// Libellés de boutons — Bricolage SemiBold 16.
    static var button: Font { SQFont.display(16, .semibold) }
    /// Chiffres héros d'une carte de stats ou d'un cadran (total, débit mesuré) —
    /// Bricolage Bold 46. Ajouter `.monospacedDigit()` à l'appel si la valeur change.
    static var metricLarge: Font { SQFont.display(46, .bold) }
    /// Valeur chiffrée d'une rangée ou d'une carte (dernière mesure, RSRP) —
    /// Bricolage Bold 30 (DESIGN.md › Chiffres). Même remarque pour `.monospacedDigit()`.
    static var metricMedium: Font { SQFont.display(30, .bold) }
    /// Valeur chiffrée d'une carte partagée ou d'une tuile de récap — Bricolage Bold 20.
    static var metricSmall: Font { SQFont.display(20, .bold) }
    /// Nom en tête d'une rangée (conversation, auteur) — Figtree SemiBold 16.
    static var rowTitle: Font { SQFont.body(16, .semibold, relativeTo: .headline) }

    // Mêmes tailles avec une autre graisse. Passer par ici plutôt que par
    // `.weight()` : la graisse reste ajustée au mode terrain et à « Texte en gras ».
    static func body(_ weight: Font.Weight) -> Font { SQFont.body(15, weight, relativeTo: .body) }
    static func callout(_ weight: Font.Weight) -> Font { SQFont.body(14.5, weight, relativeTo: .callout) }
    static func subhead(_ weight: Font.Weight) -> Font { SQFont.body(13.5, weight, relativeTo: .subheadline) }
    static func caption(_ weight: Font.Weight) -> Font { SQFont.body(12.5, weight, relativeTo: .footnote) }
    static func micro(_ weight: Font.Weight) -> Font { SQFont.body(12, weight, relativeTo: .caption2) }
}

/// Ex-« kicker » éditorial. La DA Crème supprime les micro-labels MAJUSCULES
/// tracés : le style rend désormais un sous-titre Figtree en casse normale,
/// couleur secondaire — les appels existants sont adoucis d'office.
extension Text {
    func sqKicker() -> some View {
        self.font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
    }
}
