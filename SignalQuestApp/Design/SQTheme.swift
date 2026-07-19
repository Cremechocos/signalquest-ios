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
    /// Gros titres de page (salutation, titres d'écran) — Bricolage Bold 26.
    static let display = SQFont.display(26, .bold, relativeTo: .largeTitle)
    /// Titres de sections majeures / sheets — Bricolage Bold 24.
    static let title = SQFont.display(24, .bold, relativeTo: .title2)
    /// Titres de cartes, tuiles — Bricolage SemiBold 16.5.
    static let heading = SQFont.display(16.5, .semibold, relativeTo: .headline)
    /// Corps de texte — Figtree 15.
    static let body = SQFont.body(15, relativeTo: .body)
    static let callout = SQFont.body(14.5, relativeTo: .callout)
    /// Sous-titres — Figtree Medium 13.5.
    static let subhead = SQFont.body(13.5, .medium, relativeTo: .subheadline)
    /// Sous-titres, horodatages — Figtree 12.5.
    static let caption = SQFont.body(12.5, relativeTo: .footnote)
    /// Micro-labels (dock, badges) — Figtree SemiBold 11, casse normale.
    static let micro = SQFont.body(11, .semibold, relativeTo: .caption2)
    /// Libellés de boutons — Bricolage SemiBold 16.
    static let button = SQFont.display(16, .semibold)
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
