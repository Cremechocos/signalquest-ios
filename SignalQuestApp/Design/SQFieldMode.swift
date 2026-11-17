import SwiftUI
import UIKit

/// Overlay de lisibilité terrain commun aux écrans iOS.
///
/// Il ne remplace ni le thème ni les couleurs métier : il demande au système
/// son contraste renforcé, une graisse plus lisible et des contrôles larges.
enum SQFieldMode {
    static let storageKey = "sq_fieldMode_enabled"

    /// Lu par les couleurs dynamiques UIKit. `@AppStorage` dans la racine
    /// provoque la recomposition ; le provider choisit alors les encres terrain.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}

// MARK: - Repeindre au changement de réglage

/// « Mode terrain » et « Noir intense » sont lus par les couleurs dynamiques au moment où
/// elles se résolvent. Observer ces réglages à la racine ne suffit pas : une vue déjà
/// affichée dont rien d'autre ne change garde ses couleurs résolues jusqu'à son prochain
/// rendu, d'où un changement visible seulement en changeant d'écran (retour du 17/11).
/// Mesuré au rendu (AppearanceRepaintTests) : ni l'observation à la racine, ni une
/// valeur d'environnement ordinaire, ni un trait UIKit seul ne repeignent ; un trait relié
/// à l'environnement SwiftUI, si (iOS 17+). Sous iOS 16, l'effet reste au prochain rendu.
struct SQAppearanceRepaint: ViewModifier {
    let fieldMode: Bool
    let pureBlack: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.environment(\.sqAppearanceVersion, (fieldMode ? 1 : 0) | (pureBlack ? 2 : 0))
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
private struct SQAppearanceTrait: UITraitDefinition {
    static let defaultValue = 0
    /// Les couleurs dynamiques UIKit (barres, contrôles) se résolvent de nouveau aussi.
    static let affectsColorAppearance = true
}

@available(iOS 17.0, *)
private struct SQAppearanceVersionKey: EnvironmentKey, UITraitBridgedEnvironmentKey {
    static let defaultValue = 0
    static func read(from traitCollection: UITraitCollection) -> Int { traitCollection[SQAppearanceTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: Int) { mutableTraits[SQAppearanceTrait.self] = value }
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    fileprivate var sqAppearanceVersion: Int {
        get { self[SQAppearanceVersionKey.self] }
        set { self[SQAppearanceVersionKey.self] = newValue }
    }
}
