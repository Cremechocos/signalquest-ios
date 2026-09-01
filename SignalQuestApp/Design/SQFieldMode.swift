import SwiftUI

/// Overlay de lisibilité terrain commun aux écrans iOS.
///
/// Il ne remplace ni le thème ni les couleurs métier : il demande au système
/// son contraste renforcé, une graisse plus lisible et des contrôles larges.
enum SQFieldMode {
    static let storageKey = "sq.fieldMode.enabled"

    /// Lu par les couleurs dynamiques UIKit. `@AppStorage` dans la racine
    /// provoque la recomposition ; le provider choisit alors les encres terrain.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}
