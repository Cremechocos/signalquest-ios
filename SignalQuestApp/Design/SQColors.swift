import SwiftUI
import UIKit

/// Color tokens. All values resolve through the asset catalog so they adapt to
/// the system light/dark appearance set in iOS Settings.
enum SQColor {
    // MARK: Brand
    /// Brique signature de la DA « Crème & Terre cuite ». Accent primaire unique.
    static let brandRed = Color("BrandRed")
    /// Alias rétro-compat : l'ancien orange/rose pointe désormais sur le rouge,
    /// pour ne pas casser les vues existantes pendant le réalignement.
    static let brandOrange = Color("BrandOrange")
    static let brandPink = Color("BrandPink")
    static let brandBlue = Color("BrandBlue")
    static let brandGreen = Color("BrandGreen")

    // MARK: Surfaces
    static let bg = Color("BackgroundPrimary")
    static let surface = Color("SurfaceElevated")
    static let surfaceMuted = Color("SurfaceMuted")

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

    // MARK: Texte sur aplats

    /// Texte posé sur une surface accent (brique) : crème dans les deux modes.
    static let onAccent = Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255)
    /// Texte posé sur le bouton encre (`label`) : crème en clair, nuit en sombre.
    static let onInk = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 1.0), dark: (0x19, 0x14, 0x10, 1.0)
    )

    // MARK: Teintes translucides (calculées, pas de colorset)

    /// Brique à 12 % (18 % en sombre) : pastilles d'icônes, pilule active du
    /// dock, tags, fonds teintés.
    static let accentSoft = dynamicTint(
        light: (0xB0, 0x4A, 0x3C, 0.12), dark: (0xD9, 0x7A, 0x66, 0.18)
    )
    /// Olive à 14 % (18 % en sombre) : succès, badges « Stable », validations.
    static let successSoft = dynamicTint(
        light: (0x7E, 0x8C, 0x5C, 0.14), dark: (0xA3, 0xB3, 0x7A, 0.18)
    )
    /// Danger à 10 % (16 % en sombre) : fond du bouton destructif.
    static let dangerSoft = dynamicTint(
        light: (0xC1, 0x3B, 0x2C, 0.10), dark: (0xE3, 0x7E, 0x6B, 0.16)
    )
    /// Ambre à 14 % (18 % en sombre) : avertissements teintés.
    static let warningSoft = dynamicTint(
        light: (0xC0, 0x8A, 0x3E, 0.14), dark: (0xDC, 0xA9, 0x5E, 0.18)
    )

    // MARK: Surfaces spéciales

    /// Surface « verre » : SurfaceElevated à 92 % — à combiner avec un blur
    /// (barres de conversation, recherche carte, FABs).
    static let surfaceGlass = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 0.92), dark: (0x26, 0x20, 0x19, 0.92)
    )
    /// Fond du dock flottant : SurfaceElevated à 95 % (94 % en sombre).
    static let dockBackground = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 0.95), dark: (0x26, 0x20, 0x19, 0.94)
    )
    /// Items inactifs du dock : bruns discrets. Clair assombri à #8D7E68 (3,7:1 sur
    /// le fond du dock) pour rester lisible en basse vision / plein soleil (A11Y-10).
    static let dockInactive = dynamicTint(
        light: (0x8D, 0x7E, 0x68, 1.0), dark: (0x8A, 0x7A, 0x61, 1.0)
    )

    // MARK: Ombres (encre chaude en clair, noir en sombre)

    /// Ombre repos (chips, petites tuiles) : 5 % encre / 30 % noir.
    static let shadowSoft = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.05), dark: (0x00, 0x00, 0x00, 0.30)
    )
    /// Ombre carte : 6 % encre / 35 % noir.
    static let shadowCard = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.06), dark: (0x00, 0x00, 0x00, 0.35)
    )
    /// Ombre accent (28 %) : uniquement sous les surfaces brique.
    static let shadowAccent = dynamicTint(
        light: (0xB0, 0x4A, 0x3C, 0.28), dark: (0xD9, 0x7A, 0x66, 0.28)
    )
    /// Ombre du dock flottant : 14 % encre / 50 % noir.
    static let shadowDock = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.14), dark: (0x00, 0x00, 0x00, 0.50)
    )

    /// Couleur dynamique clair/sombre avec alpha, hors asset catalog.
    private static func dynamicTint(
        light: (UInt8, UInt8, UInt8, CGFloat),
        dark: (UInt8, UInt8, UInt8, CGFloat)
    ) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: c.3
            )
        })
    }
}
