import SwiftUI
import UIKit

/// Color tokens. All values resolve through the asset catalog so they adapt to
/// the system light/dark appearance set in iOS Settings.
enum SQColor {
    /// Alias utilisé par les actions partagées ; conserve l'accent Crème existant.
    static let accent = brandRed
    // MARK: Brand
    /// Brique signature de la DA « Crème & Terre cuite ». Accent primaire unique.
    static let brandRed = Color("BrandRed")
    /// Alias rétro-compat : l'ancien orange/rose pointe désormais sur le rouge,
    /// pour ne pas casser les vues existantes pendant le réalignement.
    static let brandOrange = Color("BrandOrange")
    static let brandPink = Color("BrandPink")
    static let brandBlue = Color("BrandBlue")
    static let brandGreen = Color("BrandGreen")
    /// Repère de recherche cartographique, distinct des palettes opérateur et du violet 5G.
    static let searchPin = dynamicTint(
        light: (0x5B, 0x5B, 0xD6, 1.0), dark: (0x8B, 0x83, 0xFF, 1.0)
    )

    // MARK: Surfaces
    /// Surfaces — DYNAMIQUES depuis l'ajout du mode « Noir intense (OLED) ».
    ///
    /// Le catalogue d'assets sait exprimer clair et sombre, pas un troisième mode :
    /// ces jetons ne peuvent donc plus être de simples `Color("…")`. Ils résolvent
    /// la couleur au moment du rendu, en croisant l'apparence système et le réglage
    /// OLED. Seules les SURFACES changent — les textes et les couleurs de marque
    /// gardent leurs valeurs, exactement comme la transformation `withOledSurfaces`
    /// d'Android, sinon le contraste dériverait.
    static var bg: Color { SQOledPalette.surface(asset: "BackgroundPrimary", oled: .background) }
    static var surface: Color { SQOledPalette.surface(asset: "SurfaceElevated", oled: .container) }
    static var surfaceMuted: Color { SQOledPalette.surface(asset: "SurfaceMuted", oled: .variant) }

    // MARK: Labels
    static let label = Color("LabelPrimary")
    static let labelSecondary = fieldAwareLabel(
        asset: "LabelSecondary",
        highLight: (0x4E, 0x40, 0x2E),
        highDark: (0xD8, 0xCD, 0xB8)
    )
    static let labelTertiary = fieldAwareLabel(
        asset: "LabelTertiary",
        highLight: (0x5C, 0x4C, 0x38),
        highDark: (0xC8, 0xBB, 0xA4)
    )

    // MARK: Lines / fills
    static var separator: Color { SQOledPalette.surface(asset: "Separator", oled: .outline) }
    static var fill: Color { SQOledPalette.surface(asset: "Fill", oled: .highest) }

    // MARK: Semantic
    static let like = Color("Like")
    static let info = Color("Info")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")

    // MARK: Texte sur aplats

    /// Texte posé sur une surface accent (brique).
    ///
    /// Était crème dans LES DEUX modes. Or `brandRed` s'éclaircit en sombre
    /// (`#D97A66`) : du crème dessus tombait à **2,84:1**, très en dessous du
    /// seuil AA — et c'est le bouton principal de l'app (`GradientButton`
    /// `.accent`). L'encre nuit y remonte à 6,03:1. Même bascule que `onInk`,
    /// qui traite déjà ce cas symétrique.
    ///
    /// **Ne pas l'atténuer par `.opacity()` sur du texte.** Mesuré sur
    /// `brandRed` en mode clair : α 0,7 → 3,30:1, α 0,85 → 4,11:1, et le seuil
    /// AA du petit texte (4,5:1) n'est franchi qu'à α ≈ 0,92, visuellement
    /// indiscernable du plein. Autrement dit, une hiérarchie de texte par
    /// l'alpha est impossible sur brique : la faire porter par la taille et la
    /// graisse. L'alpha reste légitime sur les objets graphiques (traits,
    /// icônes décoratives, `ProgressView`), au-dessus de **0,7** — seuil de
    /// WCAG 1.4.11. `DesignTokenContrastTests.testTranslucentOnAccentStaysReadable`
    /// verrouille ce plancher.
    /// Texte posé sur une surface accent : crème en clair, NUIT en sombre — parce
    /// qu'en sombre l'accent est un saumon clair.
    ///
    /// ⚠️ Ne pas assombrir `brandRed` en sombre sans traiter ce jeton : les deux
    /// forment un système. Un accent profond (carmin) exigerait un texte clair,
    /// or `brandRed` sert AUSSI de couleur de premier plan sur les surfaces, où il
    /// doit rester clair pour atteindre 3:1. Recherche exhaustive faite : aucune
    /// teinte ne satisfait les deux rôles à la fois. Changer d'accent en sombre
    /// suppose donc de SÉPARER les deux usages en deux jetons distincts.
    static let onAccent = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 1.0), dark: (0x19, 0x14, 0x10, 1.0)
    )
    /// Aplat brique portant plusieurs lignes de petit texte (héro du Feed).
    /// Le `brandRed` nominal atteint 5,05:1 en clair, mais l'anticrénelage des
    /// libellés 11-13 pt le fait passer sous AA. Cette surface plus profonde
    /// monte à 8,05:1 en clair, avec une marge réelle pour l'anticrénelage et
    /// les petites légendes denses ; le sombre conserve son couple spécifique.
    static let accentTextSurface = dynamicTint(
        light: (0x80, 0x34, 0x2A, 1.0), dark: (0xD9, 0x7A, 0x66, 1.0)
    )
    /// Texte posé sur le bouton encre (`label`) : crème en clair, nuit en sombre.
    static let onInk = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 1.0), dark: (0x19, 0x14, 0x10, 1.0)
    )

    // MARK: Teintes translucides (calculées, pas de colorset)

    /// Les assets continuent de répondre à clair/sombre. En mode terrain — ou
    /// lorsque « Augmenter le contraste » est actif dans iOS — les encres
    /// secondaires deviennent réellement plus contrastées au lieu de ne
    /// renforcer que leur graisse.
    private static func fieldAwareLabel(
        asset: String,
        highLight: (UInt8, UInt8, UInt8),
        highDark: (UInt8, UInt8, UInt8)
    ) -> Color {
        Color(UIColor { traits in
            let highContrast = SQFieldMode.isEnabled || traits.accessibilityContrast == .high
            guard highContrast else {
                return UIColor(named: asset, in: .main, compatibleWith: traits) ?? .label
            }
            let rgb = traits.userInterfaceStyle == .dark ? highDark : highLight
            return UIColor(
                red: CGFloat(rgb.0) / 255,
                green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255,
                alpha: 1
            )
        })
    }

    /// Variante sans asset : teintes de base calculées, mêmes encres renforcées.
    private static func fieldAwareLabel(
        light: (UInt8, UInt8, UInt8),
        dark: (UInt8, UInt8, UInt8),
        highLight: (UInt8, UInt8, UInt8),
        highDark: (UInt8, UInt8, UInt8)
    ) -> Color {
        Color(UIColor { traits in
            let highContrast = SQFieldMode.isEnabled || traits.accessibilityContrast == .high
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = highContrast ? (isDark ? highDark : highLight) : (isDark ? dark : light)
            return UIColor(
                red: CGFloat(rgb.0) / 255,
                green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255,
                alpha: 1
            )
        })
    }

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

    // MARK: Encres pour texte posé SUR une pastille teintée
    //
    // Poser `brandRed` sur `accentSoft` donne 4,28:1, et `danger` sur
    // `dangerSoft` 4,33:1 — juste sous le seuil AA de 4,5:1 pour du texte
    // courant. Ces deux encres, légèrement plus contrastées, sont à utiliser
    // À LA PLACE de la couleur pleine quand le texte est sur sa propre pastille.
    // `success` et `warning` n'en ont pas besoin : ils passent déjà AA (4,62 et
    // 4,68) depuis que leurs valeurs ont été assombries.
    //
    // Règle : `.foregroundStyle(SQColor.accentInk)` dès qu'on est sur
    // `SQColor.accentSoft` ; `SQColor.brandRed` sur un fond de surface normal.

    /// Brique lisible sur `accentSoft` (4,76:1 en clair, 4,72:1 en sombre).
    static let accentInk = dynamicTint(
        light: (0xA6, 0x44, 0x37, 1.0), dark: (0xE0, 0x8A, 0x78, 1.0)
    )
    /// Danger lisible sur `dangerSoft` (5,86:1 en clair, 5,08:1 en sombre).
    /// En clair, cette marge couvre aussi les erreurs de formulaire sur fond crème
    /// après rendu : l'ancienne encre tombait à 4,29:1 sur la feuille de reset.
    static let dangerInk = dynamicTint(
        light: (0xA2, 0x2B, 0x1F, 1.0), dark: (0xE8, 0x8D, 0x7C, 1.0)
    )

    // MARK: Surfaces spéciales

    /// Surface « verre » : SurfaceElevated à 92 % — à combiner avec un blur
    /// (barres de conversation, recherche carte, FABs).
    static let surfaceGlass = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 0.92), dark: (0x26, 0x20, 0x19, 0.92),
        oled: (0x0A, 0x0A, 0x0A, 0.92)
    )
    /// Fond du dock flottant : SurfaceElevated à 95 % (94 % en sombre).
    static let dockBackground = dynamicTint(
        light: (0xFB, 0xF7, 0xEF, 0.95), dark: (0x26, 0x20, 0x19, 0.94),
        oled: (0x0A, 0x0A, 0x0A, 0.94)
    )
    /// Items inactifs du dock : bruns discrets, au moins 4,5:1 sur le fond du dock
    /// (#76674F en clair, #A89A80 en sombre). En mode terrain ou avec « Augmenter
    /// le contraste », ils prennent les encres secondaires renforcées.
    static let dockInactive = fieldAwareLabel(
        light: (0x76, 0x67, 0x4F),
        dark: (0xA8, 0x9A, 0x80),
        highLight: (0x4E, 0x40, 0x2E),
        highDark: (0xD8, 0xCD, 0xB8)
    )

    // MARK: Ombres (encre chaude en clair, noir en sombre)

    /// Ombre repos (chips, petites tuiles) : 5 % encre / 30 % noir.
    static let shadowSoft = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.05), dark: (0x00, 0x00, 0x00, 0.30),
        oled: (0x00, 0x00, 0x00, 0)
    )
    /// Ombre carte : 6 % encre / 35 % noir.
    static let shadowCard = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.06), dark: (0x00, 0x00, 0x00, 0.35),
        oled: (0x00, 0x00, 0x00, 0)
    )
    /// Ombre accent (28 %) : uniquement sous les surfaces brique.
    /// ⚠️ En OLED, cette ombre est ANNULÉE : un saumon à 28 % posé sur du noir pur
    /// ne se lit pas comme une ombre mais comme un halo lumineux autour des
    /// surfaces brique — le défaut le plus voyant du mode sur appareil réel.
    static let shadowAccent = dynamicTint(
        light: (0xB0, 0x4A, 0x3C, 0.28), dark: (0xD9, 0x7A, 0x66, 0.28),
        oled: (0x00, 0x00, 0x00, 0)
    )
    /// Ombre du dock flottant : 14 % encre / 50 % noir.
    static let shadowDock = dynamicTint(
        light: (0x33, 0x28, 0x18, 0.14), dark: (0x00, 0x00, 0x00, 0.50),
        oled: (0x00, 0x00, 0x00, 0)
    )

    /// Couleur dynamique clair/sombre avec alpha, hors asset catalog.
    /// `oled` : teinte substituée en sombre quand le mode « Noir intense » est
    /// actif. Sans elle, les surfaces calculées — dock et verre en tête — gardaient
    /// leur brun chaud au milieu d'une app passée au noir. Le dock étant visible
    /// sur CHAQUE écran, c'était le défaut le plus voyant du mode.
    private static func dynamicTint(
        light: (UInt8, UInt8, UInt8, CGFloat),
        dark: (UInt8, UInt8, UInt8, CGFloat),
        oled: (UInt8, UInt8, UInt8, CGFloat)? = nil
    ) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let c = isDark ? ((oled != nil && SQOledPalette.isEnabled) ? oled! : dark) : light
            return UIColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: c.3
            )
        })
    }
}

/// Couleurs de sévérité, identiques à Android et fixes en clair comme en sombre.
///
/// Sémantiques, donc jamais dérivées du thème : une panne qui changerait de couleur selon
/// l'apparence obligerait à réapprendre le code à chaque bascule. Les mêmes valeurs que la
/// couche carte Android, pour qu'un utilisateur des deux plateformes lise la même chose.
enum OutageTint {
    static let down = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    /// Ambre PROFOND. Le jaune-500 d'avant (#EAB308) tombait à 1,80:1 sur la crème : une pastille
    /// qu'on ne voyait pas, et un texte de gravité illisible. Même valeur qu'Android.
    static let degraded = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
    static let resolved = Color(red: 0x2E / 255, green: 0x7D / 255, blue: 0x5B / 255)

    static func of(_ severity: OutageSeverity) -> Color {
        severity == .degraded ? degraded : down
    }

    // MARK: Encres

    /// Les encres à poser quand la gravité doit ÉCRIRE, et non seulement signaler.
    ///
    /// Les trois teintes ci-dessus sont calibrées comme des APLATS — marqueur, pastille, jauge —
    /// où WCAG 1.4.11 ne demande que 3:1. Posées en texte sur une surface de carte elles tombent
    /// sous le 4,5:1 que réclame WCAG 1.4.3, et le rouge y échoue dans les deux apparences. Ces
    /// encres les remplacent partout où la couleur porte des mots.
    ///
    /// Dynamiques, et pas une constante choisie au moment de l'appel : la feuille et la liste ne
    /// sont pas ré-instanciées au basculement clair/sombre, une couleur figée y resterait celle de
    /// l'ancien thème. Mêmes valeurs qu'Android (`OutageColors.onLight` / `onDark`).
    static let downInk = ink(light: (0xB3, 0x26, 0x1E), dark: (0xE0, 0x7A, 0x7E))
    static let degradedInk = ink(light: (0x8A, 0x3F, 0x06), dark: (0xE3, 0xB6, 0x5E))
    static let resolvedInk = ink(light: (0x1F, 0x6B, 0x4A), dark: (0x7B, 0xD8, 0x9A))

    static func inkOf(_ severity: OutageSeverity) -> Color {
        severity == .degraded ? degradedInk : downInk
    }

    private static func ink(light: (UInt8, UInt8, UInt8), dark: (UInt8, UInt8, UInt8)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: 1
            )
        })
    }
}
