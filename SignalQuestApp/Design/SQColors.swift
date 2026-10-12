import SwiftUI
import UIKit

/// Color tokens. All values resolve through the asset catalog so they adapt to
/// the system light/dark appearance set in iOS Settings.
enum SQColor {
    /// Alias utilisé par les actions partagées.
    static let accent = brandRed
    // MARK: Brand
    /// Carmin Halo (`--h-brand`) : identité, sélection, focus et états.
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
        highLight: (0x3C, 0x44, 0x3F),
        highDark: (0xC9, 0xD2, 0xCC)
    )
    static let labelTertiary = fieldAwareLabel(
        asset: "LabelTertiary",
        highLight: (0x3C, 0x44, 0x3F),
        highDark: (0xC9, 0xD2, 0xCC)
    )
    /// Encre secondaire forte (`--h-ink-2`) : descriptions, boutons discrets,
    /// icônes des tuiles. Plus foncée que `labelSecondary` (`--h-muted`).
    static let ink2 = fieldAwareLabel(
        light: (0x3C, 0x44, 0x3F), dark: (0xC9, 0xD2, 0xCC),
        highLight: (0x3C, 0x44, 0x3F), highDark: (0xC9, 0xD2, 0xCC)
    )
    /// Texte des puces neutres (`--h-chip-ink`).
    static let chipInk = fieldAwareLabel(
        light: (0x4A, 0x52, 0x4D), dark: (0xC4, 0xCD, 0xC7),
        highLight: (0x3C, 0x44, 0x3F), highDark: (0xC9, 0xD2, 0xCC)
    )

    // MARK: Lines / fills
    /// En mode terrain, le filet passe à l'encre à 34 %, comme `[data-field]` web.
    static var separator: Color {
        guard !SQFieldMode.isEnabled else { return label.opacity(0.34) }
        return SQOledPalette.surface(asset: "Separator", oled: .outline)
    }
    static var fill: Color { SQOledPalette.surface(asset: "Fill", oled: .highest) }
    /// Fond des puces, tuiles d'icône et survols (`--h-chip`).
    static var chip: Color { fill }
    /// Pointillés des lignes clé-valeur, contours de cases, poignées (`--h-dots`).
    static let dots = dynamicTint(
        light: (0x1C, 0x20, 0x1E, 0.30), dark: (0xF1, 0xF4, 0xF1, 0.28)
    )
    /// Piste des sélecteurs segmentés et des interrupteurs éteints (`--h-seg`).
    static let segTrack = dynamicTint(
        light: (0xE6, 0xE3, 0xD9, 1.0), dark: (0x20, 0x26, 0x23, 1.0),
        oled: (0x16, 0x1B, 0x19, 1.0)
    )
    /// Pastille active d'un segmenté (`--h-seg-thumb`).
    static let segThumb = dynamicTint(
        light: (0xFF, 0xFF, 0xFF, 1.0), dark: (0x2A, 0x30, 0x2D, 1.0)
    )
    /// Blocs de squelette (`--h-skel`).
    static let skeleton = dynamicTint(
        light: (0xE9, 0xE6, 0xDD, 1.0), dark: (0x23, 0x29, 0x27, 1.0),
        oled: (0x17, 0x1C, 0x1A, 1.0)
    )
    /// Voile posé sous une fenêtre maison (`--h-scrim`).
    static let scrim = dynamicTint(
        light: (0x1C, 0x20, 0x1E, 0.45), dark: (0x00, 0x00, 0x00, 0.55)
    )
    /// Verre posé sur une photo ou une vidéo (`--h-glass`) : identique dans les
    /// deux thèmes, puisque l'image ne change pas avec eux. Texte en `onGlass`.
    static let glass = Color(red: 0x0F / 255, green: 0x13 / 255, blue: 0x12 / 255).opacity(0.52)
    static let glassLine = Color(red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEC / 255).opacity(0.16)
    static let onGlass = Color(red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEC / 255)

    // MARK: Semantic
    static let like = Color("Like")
    static let info = Color("Info")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")

    // MARK: Texte sur aplats

    /// Texte posé sur une surface accent : blanc en clair (7,5:1 sur le carmin),
    /// NUIT carmin en sombre (6,4:1), parce qu'en sombre l'accent est un carmin
    /// clair (`--h-on-brand`). Même bascule que `onInk`, qui traite le cas symétrique.
    ///
    /// **Ne pas l'atténuer par `.opacity()` sur du texte** : une hiérarchie de texte
    /// par l'alpha passe vite sous le seuil AA sur un aplat. La faire porter par la
    /// taille et la graisse. L'alpha reste légitime sur les objets graphiques
    /// (traits, icônes décoratives, `ProgressView`), au-dessus de **0,7** — seuil de
    /// WCAG 1.4.11. `DesignTokenContrastTests.testTranslucentOnAccentStaysReadable`
    /// verrouille ce plancher.
    ///
    /// ⚠️ `brandRed` et ce jeton forment un système : changer l'un suppose de
    /// remesurer l'autre, et `brandRed` sert AUSSI de premier plan sur les surfaces.
    static let onAccent = dynamicTint(
        light: (0xFF, 0xFF, 0xFF, 1.0), dark: (0x24, 0x06, 0x10, 1.0)
    )
    /// Aplat accent portant plusieurs lignes de petit texte (héro du Feed) :
    /// le carmin profond (`--h-brand-deep`) monte à 9,6:1 sous du blanc, avec une
    /// marge réelle pour l'anticrénelage ; le sombre garde le carmin clair.
    static let accentTextSurface = dynamicTint(
        light: (0x8A, 0x0E, 0x30, 1.0), dark: (0xFF, 0x5C, 0x7A, 1.0)
    )
    /// Texte posé sur le bouton encre (`label`) : papier en clair, nuit en sombre
    /// (`--h-go-ink`).
    static let onInk = dynamicTint(
        light: (0xF4, 0xF2, 0xEC, 1.0), dark: (0x0F, 0x13, 0x12, 1.0)
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

    /// Carmin à 10 % (14 % en sombre, `--h-brand-soft`) : pastilles d'icônes,
    /// pilule active du dock, tags, fonds teintés.
    static let accentSoft = dynamicTint(
        light: (0xA8, 0x12, 0x3A, 0.10), dark: (0xFF, 0x5C, 0x7A, 0.14)
    )
    /// Vert à 12 % (14 % en sombre, `--h-success-soft`) : succès, badges
    /// « Stable », validations.
    static let successSoft = dynamicTint(
        light: (0x18, 0x7B, 0x38, 0.12), dark: (0x7B, 0xD8, 0x9A, 0.14)
    )
    /// Danger à 10 % (12 % en sombre, `--h-danger-soft`) : fond du bouton destructif.
    static let dangerSoft = dynamicTint(
        light: (0xC5, 0x36, 0x3B, 0.10), dark: (0xE0, 0x7A, 0x7E, 0.12)
    )
    /// Ambre à 13 % (14 % en sombre, `--h-amb-soft`) : avertissements teintés.
    static let warningSoft = dynamicTint(
        light: (0x8C, 0x63, 0x13, 0.13), dark: (0xE3, 0xB6, 0x5E, 0.14)
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

    /// Carmin lisible sur `accentSoft` (6,24:1 en clair, 6,37:1 en sombre).
    static let accentInk = dynamicTint(
        light: (0xA8, 0x12, 0x3A, 1.0), dark: (0xFF, 0x8A, 0xA0, 1.0)
    )
    /// Danger lisible sur `dangerSoft` (5,96:1 en clair, 6,02:1 en sombre).
    /// En clair, cette marge couvre aussi les erreurs de formulaire sur fond crème
    /// après rendu : l'ancienne encre tombait à 4,29:1 sur la feuille de reset.
    static let dangerInk = dynamicTint(
        light: (0xA8, 0x2A, 0x2F, 1.0), dark: (0xEC, 0x8D, 0x90, 1.0)
    )

    // MARK: Surfaces spéciales

    /// Surface « verre » : SurfaceElevated à 92 % — à combiner avec un blur
    /// (barres de conversation, recherche carte, FABs).
    static let surfaceGlass = dynamicTint(
        light: (0xFF, 0xFF, 0xFF, 0.92), dark: (0x18, 0x1D, 0x1B, 0.92),
        oled: (0x0A, 0x0D, 0x0C, 0.92)
    )
    /// Items inactifs du dock : le gris-vert `--h-muted`, au moins 4,5:1 sur le
    /// papier. En mode terrain ou avec « Augmenter le contraste », ils
    /// prennent les encres secondaires renforcées.
    static let dockInactive = fieldAwareLabel(
        light: (0x63, 0x6B, 0x66),
        dark: (0x98, 0xA2, 0x9C),
        highLight: (0x3C, 0x44, 0x3F),
        highDark: (0xC9, 0xD2, 0xCC)
    )

    // MARK: Ombres (encre en clair, noir en sombre ; aucune en OLED ni en terrain)

    /// Ombre repos (chips, petites tuiles) : 5 % encre / 30 % noir.
    static let shadowSoft = dynamicTint(
        light: (0x1C, 0x20, 0x1E, 0.05), dark: (0x00, 0x00, 0x00, 0.30),
        oled: (0x00, 0x00, 0x00, 0), clearedInFieldMode: true
    )
    /// Ombre carte : 8 % encre / 35 % noir (`--h-shadow`).
    static let shadowCard = dynamicTint(
        light: (0x1C, 0x20, 0x1E, 0.08), dark: (0x00, 0x00, 0x00, 0.35),
        oled: (0x00, 0x00, 0x00, 0), clearedInFieldMode: true
    )
    /// Ombre accent (22 %) : uniquement sous les surfaces carmin.
    /// ⚠️ En OLED, cette ombre est ANNULÉE : un saumon à 28 % posé sur du noir pur
    /// ne se lit pas comme une ombre mais comme un halo lumineux autour des
    /// surfaces carmin — le défaut le plus voyant du mode sur appareil réel.
    static let shadowAccent = dynamicTint(
        light: (0xA8, 0x12, 0x3A, 0.22), dark: (0xFF, 0x5C, 0x7A, 0.22),
        oled: (0x00, 0x00, 0x00, 0), clearedInFieldMode: true
    )
    /// Ombre du dock flottant : 22 % encre / 50 % noir (`--h-shadow-dock`).
    static let shadowDock = dynamicTint(
        light: (0x1C, 0x20, 0x1E, 0.22), dark: (0x00, 0x00, 0x00, 0.50),
        oled: (0x00, 0x00, 0x00, 0), clearedInFieldMode: true
    )

    /// Couleur dynamique clair/sombre avec alpha, hors asset catalog.
    /// `oled` : teinte substituée en sombre quand le mode « Noir intense » est
    /// actif. Sans elle, les surfaces calculées — dock et verre en tête — gardaient
    /// leur brun chaud au milieu d'une app passée au noir. Le dock étant visible
    /// sur CHAQUE écran, c'était le défaut le plus voyant du mode.
    /// `clearedInFieldMode` : les ombres disparaissent en mode terrain, où la
    /// structure passe au filet (`SQOledPalette.cardStroke`), comme `[data-field]` web.
    private static func dynamicTint(
        light: (UInt8, UInt8, UInt8, CGFloat),
        dark: (UInt8, UInt8, UInt8, CGFloat),
        oled: (UInt8, UInt8, UInt8, CGFloat)? = nil,
        clearedInFieldMode: Bool = false
    ) -> Color {
        Color(UIColor { traits in
            if clearedInFieldMode, SQFieldMode.isEnabled { return .clear }
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
