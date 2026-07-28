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
/// **Valeurs reprises à l'identique d'Android** (`ReadableColorScheme.withOledSurfaces`) :
/// les deux apps doivent se ressembler, et cette échelle a déjà été éprouvée là-bas.
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
        case low          // #0A0A0A
        case container    // #121212 — cartes
        case high         // #181818
        case highest      // #1F1F1F — remplissages
        case variant      // #1A1A1A — surfaces atténuées
        case outline      // #2A2A2A — séparateurs

        var color: UIColor {
            switch self {
            case .background: return UIColor(white: 0, alpha: 1)
            case .low:        return UIColor(hex: 0x0A0A0A)
            // Les cartes passent au NOIR PUR, pas à un gris d'élévation : l'app
            // étant faite de cartes, un fond noir couvert de #121212 lisait « gris
            // très sombre » et pas « noir ». La hiérarchie passe donc du
            // remplissage au CONTOUR (voir `cardStroke`), comme le font la plupart
            // des vrais modes OLED.
            case .container:  return UIColor(white: 0, alpha: 1)
            case .high:       return UIColor(hex: 0x181818)
            case .highest:    return UIColor(hex: 0x1F1F1F)
            // Tuiles et surfaces atténuées : noires elles aussi. À #1A1A1A elles
            // ressortaient nettement grises sur le fond noir — c'est ce que
            // l'utilisateur voyait en premier en disant « ce n'est pas vraiment OLED ».
            case .variant:    return UIColor(white: 0, alpha: 1)
            case .outline:    return UIColor(hex: 0x2A2A2A)
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

    /// Liseré des cartes. Transparent hors OLED : la hiérarchie y vient du
    /// remplissage. En OLED, carte et fond étant tous deux noirs, c'est lui — et
    /// lui seul — qui empêche les tuiles de fusionner en un bloc unique.
    static var cardStroke: Color {
        Color(UIColor { traits in
            guard traits.userInterfaceStyle == .dark, isEnabled else { return .clear }
            return UIColor(hex: 0x1F1F1F)
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
