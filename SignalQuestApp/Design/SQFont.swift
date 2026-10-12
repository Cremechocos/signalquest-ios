import SwiftUI
import UIKit

/// Police Halo : **Sora** pour tout — titres, chiffres, UI et corps de texte
/// (`tokens.css`, planche P2-33). Fichier variable : un seul `Sora-Variable.ttf`
/// porte l'axe de graisse 100 à 800, que `Font.weight` règle directement.
/// Les noms d'API historiques (`display`/`archivo`/`body`) sont conservés pour
/// ne pas réécrire ~170 appels ; ils rendent tous du Sora.
/// Retombe sur San Francisco si la police n'est pas chargée.
enum SQFont {
    /// Nom PostScript de l'instance par défaut du fichier variable : `UIFont(name:)`
    /// renvoie `nil` sur le nom de famille (voir `SQShareFonts`).
    private static let soraName = "Sora-Regular"
    private static let soraAvailable = UIFont(name: soraName, size: 12) != nil

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

    // MARK: Graisse lisible

    /// Mode terrain ou « Texte en gras » d'iOS : les polices embarquées ne
    /// suivent pas `legibilityWeight` d'elles-mêmes, la graisse monte donc d'un
    /// cran ici. Les variantes `…Fixed` (rendus déterministes) n'en tiennent pas compte.
    private static var emboldens: Bool {
        if SQFieldMode.isEnabled { return true }
        // Le réglage système se lit sur le fil principal ; un rendu hors écran
        // en arrière-plan garde la graisse demandée.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIAccessibility.isBoldTextEnabled }
    }

    static func legible(_ weight: Font.Weight) -> Font.Weight {
        guard emboldens else { return weight }
        switch weight {
        case .ultraLight, .thin, .light, .regular: return .medium
        case .medium: return .semibold
        case .semibold: return .bold
        case .bold: return .heavy
        default: return weight
        }
    }

    private static func sora(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        guard soraAvailable else { return systemFallback(relativeTo: style, weight: weight) }
        return .custom(soraName, size: size, relativeTo: style).weight(weight)
    }

    // MARK: Display / chiffres

    /// Les titres Halo sont en 800 (`.h-h1`, `.h-title`, `.h-data`) : la graisse
    /// d'affichage monte d'un cran par rapport au corps.
    private static func displayWeight(_ weight: Font.Weight) -> Font.Weight {
        switch weight {
        case .bold, .heavy, .black: return .heavy
        default: return .bold
        }
    }

    /// Titre display. Suit Dynamic Type via un style inféré.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        sora(size, legible(displayWeight(weight)), relativeTo: inferredStyle(forSize: size))
    }

    /// Titre display à taille STRICTEMENT fixe (pour les rendus déterministes :
    /// images de partage, etc., qui ne doivent pas suivre l'accessibilité).
    static func displayFixed(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        guard soraAvailable else { return .system(size: size, weight: .bold, design: .default) }
        return .custom(soraName, fixedSize: size).weight(displayWeight(weight))
    }

    /// Titre display relatif à un style (suit Dynamic Type).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold, relativeTo style: Font.TextStyle) -> Font {
        sora(size, legible(displayWeight(weight)), relativeTo: style)
    }

    // MARK: UI / labels (ex-Archivo, nom d'API conservé)

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        sora(size, legible(weight), relativeTo: inferredStyle(forSize: size))
    }

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle) -> Font {
        sora(size, legible(weight), relativeTo: style)
    }

    // MARK: Corps

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        sora(size, legible(weight), relativeTo: inferredStyle(forSize: size))
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        sora(size, legible(weight), relativeTo: style)
    }

}
