import SwiftUI

/// La DA éditoriale est à plat : l'accent est le rouge `--red`, pas un dégradé.
/// `signal` reste exposé (de nombreuses vues le consomment) mais devient un
/// rouge quasi plat (rouge → rouge profond), de sorte que tout le code existant
/// rende du rouge éditorial au lieu de l'ancien orange→rose.
enum SQGradient {
    static let signal = LinearGradient(
        colors: [SQColor.brandRed, SQColor.brandRedDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Cadran speedtest — déclinaison de rouges (du clair vers profond) pour le
    /// dégradé angulaire, sans réintroduire l'orange/rose.
    static let speed = AngularGradient(
        colors: [SQColor.brandRed, SQColor.brandRedDeep, SQColor.brandRed],
        center: .center
    )
}
