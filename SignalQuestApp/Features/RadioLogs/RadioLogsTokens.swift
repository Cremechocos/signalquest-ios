import SwiftUI

/// Mesures de la maquette validée — `mocks/Logs_sites_3_skins.html`, skin HALO
/// (celui par défaut, le plus proche de la DA « Crème & Terre cuite »).
///
/// POURQUOI UN JEU LOCAL. La maquette scope ses variables sur `.sqm`, et ses
/// rayons ne sont pas ceux de `SQRadius` : `--r` vaut 18 là où l'échelle iOS
/// propose 14 ou 20. Aligner sur l'échelle globale décalerait toute la page d'un
/// ou deux points par rapport à la maquette ; l'y forcer redessinerait l'échelle
/// pour tout le reste de l'app. Ces jetons ne valent donc que pour cette page —
/// c'est le choix qu'a fait `AntennaLogsMockTokens.kt` côté Android, pour les
/// mêmes raisons.
///
/// CONVERSION : la maquette est cadrée sur un téléphone de 412 px. 1 px de
/// maquette = 1 pt, 1 px de police = 1 pt de police.
///
/// COULEURS : elles ne viennent PAS de la maquette. `SQColor` porte déjà la DA,
/// le mode sombre et le noir intense (OLED) ; les hex de la maquette n'en sont
/// qu'une approximation figée, qui ignorerait ces trois choses. Seules les
/// couleurs SÉMANTIQUES que la maquette fixe à l'identique dans ses trois skins
/// (l'orange d'hypothèse) sont reprises telles quelles.
enum RadioLogsMetrics {
    // .site — la carte
    static let cardRadius: CGFloat = 18
    static let cardPaddingH: CGFloat = 14
    static let cardPaddingV: CGFloat = 13
    static let cardSpacing: CGFloat = 9
    static let cardInnerGap: CGFloat = 12

    // .lead-pill — la pastille d'icône (propre au skin Halo)
    static let leadPill: CGFloat = 38
    static let leadPillRadius: CGFloat = 13

    // .site-id / .tech
    static let siteIdSize: CGFloat = 15.5
    static let siteIdTracking: CGFloat = 0.155   // .01em × 15.5
    static let techSize: CGFloat = 10
    static let techTracking: CGFloat = 0.8       // .08em × 10
    static let techPaddingH: CGFloat = 7
    static let techPaddingV: CGFloat = 2
    static let techRadius: CGFloat = 6

    // .site-name / .site-meta
    static let siteNameTop: CGFloat = 4
    static let siteNameSize: CGFloat = 13
    static let siteMetaTop: CGFloat = 3
    static let siteMetaSize: CGFloat = 11.5

    // .pills / .pill
    static let pillsTop: CGFloat = 8
    static let pillsGap: CGFloat = 5
    static let pillSize: CGFloat = 10.5
    static let pillPaddingH: CGFloat = 8
    static let pillPaddingV: CGFloat = 3
    static let pillRadius: CGFloat = 7

    // .state — la pastille d'état
    static let stateTop: CGFloat = 9
    static let stateGap: CGFloat = 6
    static let stateDot: CGFloat = 7
    static let stateSize: CGFloat = 12
    static let statePaddingH: CGFloat = 11
    static let statePaddingV: CGFloat = 5

    // .cta / .btn
    static let ctaTop: CGFloat = 10
    static let ctaGap: CGFloat = 8
    static let buttonSize: CGFloat = 12.5
    static let buttonPaddingH: CGFloat = 14
    static let buttonPaddingV: CGFloat = 8
    static let buttonRadius: CGFloat = 11

    // .cells — le panneau déplié
    static let cellsTop: CGFloat = 11
    static let cellsHeaderSize: CGFloat = 10
    static let cellsHeaderBottom: CGFloat = 8
    static let cellRowGap: CGFloat = 9
    static let cellRowPaddingV: CGFloat = 6
    static let cellPciSize: CGFloat = 11
    static let cellPciPaddingH: CGFloat = 7
    static let cellPciPaddingV: CGFloat = 3
    static let cellPciRadius: CGFloat = 6
    static let cellPciMinWidth: CGFloat = 58
    static let cellIdSize: CGFloat = 12
    static let cellBandSize: CGFloat = 10.5

    // .scan — le bandeau de balayage
    static let scanRadius: CGFloat = 18
    static let scanPaddingH: CGFloat = 14
    static let scanPaddingV: CGFloat = 13
    static let scanBottom: CGFloat = 12
    static let scanHeadGap: CGFloat = 10
    static let scanHeadBottom: CGFloat = 9
    static let scanDot: CGFloat = 9
    static let scanTitleSize: CGFloat = 13.5
    static let scanActionSize: CGFloat = 12
    static let scanActionPaddingH: CGFloat = 10
    static let scanActionPaddingV: CGFloat = 5
    static let scanActionRadius: CGFloat = 9
    static let barHeight: CGFloat = 6
    static let scanSubTop: CGFloat = 8
    static let scanSubSize: CGFloat = 11.5

    // .tally — le dénombrement
    static let tallyGap: CGFloat = 12
    static let tallyBottom: CGFloat = 12
    static let tallyBadge: CGFloat = 44
    static let tallyBadgeRadius: CGFloat = 14
    static let tallyNumberSize: CGFloat = 20
    static let tallySubSize: CGFloat = 12.5

    // .rail — le rail de filtres
    static let railGap: CGFloat = 8
    static let railBottom: CGFloat = 14
    static let chipSize: CGFloat = 12.5
    static let chipPaddingH: CGFloat = 13
    static let chipPaddingV: CGFloat = 8

    // .done-line — la complétude PERMANENTE
    static let doneGap: CGFloat = 9
    static let doneBottom: CGFloat = 12
    static let doneBarHeight: CGFloat = 5
    static let doneTextSize: CGFloat = 11.5

    // .oph — l'intertitre opérateur
    static let operatorHeaderSize: CGFloat = 11
    static let operatorHeaderStrongSize: CGFloat = 12
    static let operatorHeaderTop: CGFloat = 12
    static let operatorHeaderBottom: CGFloat = 8
    static let operatorHeaderGap: CGFloat = 9

    // .sheet — la feuille trier/filtrer
    static let sheetPaddingH: CGFloat = 16
    static let sheetPaddingBottom: CGFloat = 20
    static let sheetTitleSize: CGFloat = 16
    static let sheetSubtitleSize: CGFloat = 12
    static let sheetSubtitleBottom: CGFloat = 16
    static let groupBottom: CGFloat = 16
    static let groupHeaderSize: CGFloat = 10.5
    static let groupHeaderBottom: CGFloat = 8
    static let optionGap: CGFloat = 7
    static let optionSize: CGFloat = 12.5
    static let optionPaddingH: CGFloat = 13
    static let optionPaddingV: CGFloat = 9
    static let optionRadius: CGFloat = 11
    static let optionHintSize: CGFloat = 10.5
    static let toggleRowPaddingV: CGFloat = 11
    static let toggleRowGap: CGFloat = 12
    static let toggleLabelSize: CGFloat = 13
    static let toggleHintSize: CGFloat = 11.5

    // Identification en chaîne
    static let chainCountSize: CGFloat = 12
    static let chainCountPaddingH: CGFloat = 11
    static let chainCountPaddingV: CGFloat = 5
    static let chainCardPadding: CGFloat = 14
    static let chainMapHeight: CGFloat = 170
    static let chainMapRadius: CGFloat = 12
    static let chainDot: CGFloat = 5
    static let chainDotGap: CGFloat = 5
}

/// Couleurs de la page, dans l'ordre des variables de la maquette.
///
/// `hair` / `hairStrong` : la maquette les exprime en alpha de l'encre (.09 à
/// .30). On les dérive de `SQColor.separator`, qui suit déjà le thème et l'OLED,
/// plutôt que de figer un gris.
enum RadioLogsPalette {
    static var card: Color { SQColor.surface }
    static var ink: Color { SQColor.label }
    static var muted: Color { SQColor.labelSecondary }
    static var hair: Color { SQColor.separator.opacity(0.55) }
    static var hairStrong: Color { SQColor.separator }
    static var chip: Color { SQColor.surfaceMuted }
    static var chipInk: Color { SQColor.labelSecondary }
    static var accent: Color { SQColor.brandRed }
    static var onAccent: Color { SQColor.onAccent }
    static var accentSoft: Color { SQColor.accentSoft }
    /// Encre accent lisible SUR `accentSoft` (le plein n'y passe pas AA).
    static var accentInk: Color { SQColor.accentInk }
    static var barTrack: Color { SQColor.fill }
    static var okSoft: Color { SQColor.successSoft }
    static var okInk: Color { SQColor.success }
}

// MARK: - Typographie

extension Font {
    /// Identifiant technique (eNB, PCI, ECI). La maquette le met en `var(--mono)`,
    /// mais le skin Halo fait pointer sa mono sur sa police de texte : ce n'est
    /// donc pas une chasse fixe qui est demandée, c'est la lisibilité de chiffres
    /// alignés. `monospacedDigit` rend exactement ça — et garde Figtree, donc la DA.
    static func sqTechnical(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        SQFont.body(size, weight).monospacedDigit()
    }
}
