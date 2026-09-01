import SwiftUI
import UIKit

/// Polices de la DA « Crème & Terre cuite » (SignalQuest Crème) :
/// - **Bricolage Grotesque** pour les titres display et les chiffres (rond, affirmé).
/// - **Figtree** pour l'UI, les labels, les boutons ET le corps de texte.
/// Les noms d'API historiques (`display`/`archivo`/`body`) sont conservés pour
/// ne pas réécrire ~170 appels : `archivo` rend désormais du Figtree.
/// Retombe sur San Francisco si une famille n'est pas chargée.
enum SQFont {
    private static let bricolageAvailable = UIFont(name: "BricolageGrotesque-Bold", size: 12) != nil
    private static let figtreeAvailable = UIFont(name: "Figtree-Regular", size: 12) != nil

    /// Style Dynamic Type inféré d'une taille en points. Permet aux helpers
    /// historiquement « à taille fixe » de suivre malgré tout l'accessibilité
    /// (audit UI-02) sans réécrire ~130 appels : on borne la croissance via le
    /// style le plus proche, qui scale modérément aux grandes tailles.
    static func inferredStyle(forSize size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case 11.5..<13: return .caption
        case 13..<15: return .footnote
        case 15..<16.5: return .subheadline
        case 16.5..<18: return .callout
        case 18..<20: return .body
        case 20..<23: return .title3
        case 23..<27: return .title2
        case 27..<33: return .title
        default: return .largeTitle
        }
    }

    /// Repli système qui conserve Dynamic Type. Un `.system(size:)` paraît
    /// correct à la taille par défaut mais reste figé si la police embarquée
    /// n'est pas encore enregistrée (notamment au démarrage des tests UI).
    private static func systemFallback(
        relativeTo style: Font.TextStyle,
        weight: Font.Weight,
        design: Font.Design = .default
    ) -> Font {
        .system(style, design: design, weight: weight)
    }

    // MARK: Display / chiffres — Bricolage Grotesque

    private static func bricolageName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "BricolageGrotesque-Bold"
        default: return "BricolageGrotesque-SemiBold"
        }
    }

    /// Titre display (Bricolage Grotesque). Suit Dynamic Type via un style inféré.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let style = inferredStyle(forSize: size)
        guard bricolageAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(bricolageName(weight), size: size, relativeTo: style)
    }

    /// Titre display à taille STRICTEMENT fixe (pour les rendus déterministes :
    /// images de partage, etc., qui ne doivent pas suivre l'accessibilité).
    static func displayFixed(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        guard bricolageAvailable else { return .system(size: size, weight: .bold, design: .default) }
        return .custom(bricolageName(weight), fixedSize: size)
    }

    /// Titre display relatif à un style (suit Dynamic Type).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold, relativeTo style: Font.TextStyle) -> Font {
        guard bricolageAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(bricolageName(weight), size: size, relativeTo: style)
    }

    // MARK: UI / labels — Figtree (ex-Archivo, nom d'API conservé)

    private static func figtreeName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "Figtree-Bold"
        case .semibold: return "Figtree-SemiBold"
        case .medium: return "Figtree-Medium"
        default: return "Figtree-Regular"
        }
    }

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let style = inferredStyle(forSize: size)
        guard figtreeAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(figtreeName(weight), size: size, relativeTo: style)
    }

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle) -> Font {
        guard figtreeAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(figtreeName(weight), size: size, relativeTo: style)
    }

    // MARK: Corps — Figtree

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let style = inferredStyle(forSize: size)
        guard figtreeAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(figtreeName(weight), size: size, relativeTo: style)
    }

    /// Variante corps à taille strictement fixe (rendus déterministes).
    static func bodyFixed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard figtreeAvailable else { return .system(size: size, weight: weight) }
        return .custom(figtreeName(weight), fixedSize: size)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        guard figtreeAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(figtreeName(weight), size: size, relativeTo: style)
    }

}
