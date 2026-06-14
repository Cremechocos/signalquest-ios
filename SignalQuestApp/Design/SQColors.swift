import SwiftUI

/// Color tokens. All values resolve through the asset catalog so they adapt to
/// the system light/dark appearance set in iOS Settings.
enum SQColor {
    // MARK: Brand
    /// Rouge signature de la DA (landing --red). Accent primaire unique.
    static let brandRed = Color("BrandRed")
    /// Rouge foncé pour les états pressés/hover (landing --red-deep).
    static let brandRedDeep = Color("BrandRedDeep")
    /// Alias rétro-compat : l'ancien orange/rose pointe désormais sur le rouge,
    /// pour ne pas casser les vues existantes pendant le réalignement.
    static let brandOrange = Color("BrandOrange")
    static let brandPink = Color("BrandPink")
    static let brandBlue = Color("BrandBlue")
    static let brandGreen = Color("BrandGreen")

    // MARK: Surfaces
    static let bg = Color("BackgroundPrimary")
    static let bgSecondary = Color("BackgroundSecondary")
    static let surface = Color("SurfaceElevated")
    static let surfaceMuted = Color("SurfaceMuted")
    /// Cartes au-dessus d'une surface déjà élevée (web --card-elevated).
    static let surfaceRaised = Color("SurfaceRaised")

    // MARK: Labels
    static let label = Color("LabelPrimary")
    static let labelSecondary = Color("LabelSecondary")
    static let labelTertiary = Color("LabelTertiary")

    // MARK: Lines / fills
    static let separator = Color("Separator")
    static let fill = Color("Fill")

    // MARK: Semantic
    static let like = Color("Like")
    static let info = Color("Info")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
}
