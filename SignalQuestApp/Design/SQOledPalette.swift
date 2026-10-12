import AuthenticationServices
import SwiftUI
import UIKit

/// Mode « Noir intense (OLED) ».
///
/// Sur une dalle OLED, un pixel noir pur est un pixel ÉTEINT : il ne consomme
/// rien. Le mode sombre classique de l'app utilise un gris très foncé, qui reste
/// allumé. Ce mode remplace donc les surfaces par du noir pur et une échelle de
/// gris très sombres pour l'élévation.
///
/// **Valeurs Halo** (`.dark[data-contrast="oled"]` de `tokens.css`) : noir pur, gris
/// à peine verdis pour l'élévation, et le filet à la place de l'ombre.
///
/// **Ce qui NE change pas** : les textes, les couleurs de marque et les couleurs
/// sémantiques. Passer les libellés au blanc pur sur fond noir pur produirait un
/// contraste de 21:1, éblouissant en usage nocturne — c'est justement le contexte
/// où l'on active ce mode.
enum SQOledPalette {

    /// Réglage utilisateur. Lu au moment du rendu : la clé est aussi observée en
    /// `@AppStorage` à la racine, ce qui provoque la ré-évaluation de l'arbre
    /// quand elle change.
    static let storageKey = "app_pure_black"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    /// Niveaux d'élévation, du fond à la surface la plus haute.
    enum Level {
        case background   // #000000 — fond de l'app
        case low          // #0A0D0C
        case container    // #121212 — cartes
        case high         // #171C1A
        case highest      // #171C1A — remplissages (`--h-chip`)
        case variant      // #0A0D0C — tuiles (`--h-tile`)
        case outline      // encre à 12 % — séparateurs (`--h-hair`)

        var color: UIColor {
            switch self {
            case .background: return UIColor(white: 0, alpha: 1)
            case .low:        return UIColor(hex: 0x0A0D0C)
            // Les cartes passent au NOIR PUR, pas à un gris d'élévation : l'app
            // étant faite de cartes, un fond noir couvert de #121212 lisait « gris
            // très sombre » et pas « noir ». La hiérarchie passe donc du
            // remplissage au CONTOUR (voir `cardStroke`), comme le font la plupart
            // des vrais modes OLED.
            case .container:  return UIColor(white: 0, alpha: 1)
            case .high:       return UIColor(hex: 0x171C1A)
            case .highest:    return UIColor(hex: 0x171C1A)
            // Tuiles et surfaces atténuées : à peine au-dessus du noir. À #1A1A1A elles
            // ressortaient nettement grises sur le fond noir — c'est ce que
            // l'utilisateur voyait en premier en disant « ce n'est pas vraiment OLED ».
            case .variant:    return UIColor(hex: 0x0A0D0C)
            case .outline:    return UIColor(red: 241 / 255, green: 244 / 255, blue: 241 / 255, alpha: 0.12)
            }
        }
    }

    /// Style du bouton « Continuer avec Apple ».
    ///
    /// Le blanc plein est le bon choix sur un gris foncé, mais sur du NOIR PUR il
    /// devient la surface la plus lumineuse de l'écran — exactement dans le
    /// contexte nocturne où l'on active ce mode. Le style à contour reste conforme
    /// aux règles d'Apple tout en s'y intégrant.
    static func appleButtonStyle(_ colorScheme: ColorScheme) -> SignInWithAppleButton.Style {
        guard colorScheme == .dark else { return .black }
        return isEnabled ? .whiteOutline : .white
    }

    /// Liseré des cartes. Transparent hors OLED et hors terrain : la hiérarchie y
    /// vient du remplissage et de l'ombre.
    /// - OLED : carte et fond étant tous deux noirs, c'est lui — et lui seul — qui
    ///   empêche les tuiles de fusionner en un bloc unique (`--h-card-line` à 14 %).
    /// - Terrain : les ombres disparaissent et la structure passe au filet d'encre,
    ///   lisible en plein soleil (`[data-field="on"]`).
    static var cardStroke: Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            if SQFieldMode.isEnabled {
                return UIColor(named: "LabelPrimary", in: .main, compatibleWith: traits) ?? .label
            }
            guard isDark, isEnabled else { return .clear }
            return UIColor(red: 241 / 255, green: 244 / 255, blue: 241 / 255, alpha: 0.14)
        })
    }

    /// Filet des champs de saisie. Le fond tuile a la couleur de la page : ce filet
    /// dessine le champ dans les quatre modes, comme l'Input du kit web
    /// (`border-hair`). En mode terrain, le liseré d'encre le remplace.
    static var fieldStroke: Color {
        Color(UIColor { traits in
            if SQFieldMode.isEnabled {
                return UIColor(named: "LabelPrimary", in: .main, compatibleWith: traits) ?? .label
            }
            if traits.userInterfaceStyle == .dark, isEnabled {
                return UIColor(red: 241 / 255, green: 244 / 255, blue: 241 / 255, alpha: 0.14)
            }
            return UIColor(named: "Separator", in: .main, compatibleWith: traits) ?? .separator
        })
    }

    /// Résout un jeton de surface : la valeur du catalogue en clair et en sombre
    /// classique, la valeur OLED en sombre + réglage actif.
    ///
    /// Le fournisseur dynamique est rappelé à chaque résolution, donc un
    /// changement d'apparence système est suivi sans rien faire ; le changement du
    /// RÉGLAGE, lui, a besoin que la vue se ré-évalue — d'où l'`@AppStorage` posé à
    /// la racine de l'app.
    static func surface(asset: String, oled level: Level) -> Color {
        Color(UIColor { traits in
            let base = UIColor(named: asset) ?? .clear
            guard traits.userInterfaceStyle == .dark, isEnabled else { return base }
            return level.color
        })
    }
}
