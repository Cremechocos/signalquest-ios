import SwiftUI
import UIKit

/// Polices de la DA éditoriale SignalQuest (landing signalquest.fr) :
/// - **Archivo Expanded** pour les titres display (gras, large, tracé serré).
/// - **Archivo** pour l'UI, les labels, les boutons, les kickers.
/// - **Public Sans** pour le corps de texte.
/// Retombe sur San Francisco si une famille n'est pas chargée.
enum SQFont {
    private static let expandedAvailable = UIFont(name: "ArchivoExpanded-Bold", size: 12) != nil
    private static let archivoAvailable = UIFont(name: "Archivo-SemiBold", size: 12) != nil
    private static let publicAvailable = UIFont(name: "PublicSans-Regular", size: 12) != nil

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

    // MARK: Display — Archivo Expanded

    private static func expandedName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy: return "ArchivoExpanded-Black"
        case .bold: return "ArchivoExpanded-Bold"
        default: return "ArchivoExpanded-ExtraBold"
        }
    }

    /// Titre display (Archivo Expanded). Suit Dynamic Type via un style inféré.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        guard expandedAvailable else { return .system(size: size, weight: .black, design: .default) }
        return .custom(expandedName(weight), size: size, relativeTo: inferredStyle(forSize: size))
    }

    /// Titre display à taille STRICTEMENT fixe (pour les rendus déterministes :
    /// images de partage, etc., qui ne doivent pas suivre l'accessibilité).
    static func displayFixed(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        guard expandedAvailable else { return .system(size: size, weight: .black, design: .default) }
        return .custom(expandedName(weight), fixedSize: size)
    }

    /// Titre display relatif à un style (suit Dynamic Type).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy, relativeTo style: Font.TextStyle) -> Font {
        guard expandedAvailable else { return .system(size: size, weight: .black) }
        return .custom(expandedName(weight), size: size, relativeTo: style)
    }

    // MARK: UI / labels — Archivo

    private static func archivoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "Archivo-Bold"
        case .semibold: return "Archivo-SemiBold"
        default: return "Archivo-Medium"
        }
    }

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        guard archivoAvailable else { return .system(size: size, weight: weight) }
        return .custom(archivoName(weight), size: size, relativeTo: inferredStyle(forSize: size))
    }

    /// Variante Archivo à taille strictement fixe (rendus déterministes).
    static func archivoFixed(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        guard archivoAvailable else { return .system(size: size, weight: weight) }
        return .custom(archivoName(weight), fixedSize: size)
    }

    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle) -> Font {
        guard archivoAvailable else { return .system(size: size, weight: weight) }
        return .custom(archivoName(weight), size: size, relativeTo: style)
    }

    // MARK: Corps — Public Sans

    private static func publicName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "PublicSans-Bold"
        case .semibold: return "PublicSans-SemiBold"
        case .medium: return "PublicSans-Medium"
        default: return "PublicSans-Regular"
        }
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard publicAvailable else { return .system(size: size, weight: weight) }
        return .custom(publicName(weight), size: size, relativeTo: inferredStyle(forSize: size))
    }

    /// Variante corps à taille strictement fixe (rendus déterministes).
    static func bodyFixed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard publicAvailable else { return .system(size: size, weight: weight) }
        return .custom(publicName(weight), fixedSize: size)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        guard publicAvailable else { return .system(size: size, weight: weight) }
        return .custom(publicName(weight), size: size, relativeTo: style)
    }

    // MARK: Compat — ancien `dmSans`

    /// Pont rétro-compat depuis l'ancienne API DM Sans. Les grosses tailles
    /// (≥ 24) basculent sur Archivo Expanded (display de marque), les autres sur
    /// Archivo. À remplacer progressivement par `display`/`archivo`/`body`.
    static func dmSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        size >= 24 ? display(size, weight == .regular ? .bold : weight) : archivo(size, weight)
    }

    static func dmSans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        size >= 24
            ? display(size, weight == .regular ? .bold : weight, relativeTo: style)
            : archivo(size, weight, relativeTo: style)
    }
}
