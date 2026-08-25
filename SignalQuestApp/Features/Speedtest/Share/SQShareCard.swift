import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Thème

/// Thème de la carte de partage — valeurs reprises **à l'identique** d'Android
/// (`SpeedtestShareCardModel.kt`). La carte doit être la même image sur les deux
/// plateformes ; toute divergence de palette se verrait immédiatement côte à côte.
struct SQShareCardTheme {
    let isDark: Bool
    let background: UIColor
    let textPrimary: UIColor
    let textSecondary: UIColor
    /// Filets discrets — neutre translucide, jamais teinté.
    let separator: UIColor
    /// Grille des graphes.
    let track: UIColor

    static let light = SQShareCardTheme(
        isDark: false,
        background: UIColor(hex: 0xF3EEE6),
        textPrimary: UIColor(hex: 0x1A1712),
        textSecondary: UIColor(hex: 0x6B6156),
        separator: UIColor(hex: 0x000000, alpha: 0x14 / 255),
        track: UIColor(hex: 0xDED6C9)
    )

    /// Sombre classique : gris très foncé, pas noir pur.
    static let dark = SQShareCardTheme(
        isDark: true,
        background: UIColor(hex: 0x121316),
        textPrimary: UIColor(hex: 0xF2F4F6),
        textSecondary: UIColor(hex: 0x9AA0A6),
        separator: UIColor(hex: 0xFFFFFF, alpha: 0x1F / 255),
        track: UIColor(hex: 0x26282C)
    )

    /// OLED : identique au sombre, fond noir pur. Seul le fond change — les textes
    /// et les filets gardent leurs valeurs, sans quoi le contraste dériverait.
    static let oled = SQShareCardTheme(
        isDark: true,
        background: .black,
        textPrimary: dark.textPrimary,
        textSecondary: dark.textSecondary,
        separator: dark.separator,
        track: dark.track
    )

    static func resolve(isDark: Bool, isPureBlack: Bool) -> SQShareCardTheme {
        guard isDark else { return .light }
        return isPureBlack ? .oled : .dark
    }

    /// Échelle de qualité (rouge → vert) des points et des traînées. Identité
    /// STABLE de la carte : elle ne suit ni le thème de l'app ni la DA, seulement
    /// le clair/sombre — même règle que sur Android.
    var speedPalette: [UIColor] {
        isDark
            ? [UIColor(hex: 0xF87171), UIColor(hex: 0xFB923C), UIColor(hex: 0xFDE047),
               UIColor(hex: 0xA3E635), UIColor(hex: 0x4ADE80)]
            : [UIColor(hex: 0xEF4444), UIColor(hex: 0xF97316), UIColor(hex: 0xEAB308),
               UIColor(hex: 0x84CC16), UIColor(hex: 0x22C55E)]
    }

    /// Centre de bande des cinq teintes sur un remplissage 0…1 — `FILL_POSITIONS`
    /// d'Android : < 15 % rouge, 15-35 % orange, 35-55 % jaune, 55-80 % vert
    /// clair, ≥ 80 % vert.
    private static let fillPositions: [Double] = [0.075, 0.25, 0.45, 0.675, 0.90]

    /// Idem pour la latence, en ms — `PING_POSITIONS_MS` : ≤ 20 vert, 20-40 vert
    /// clair, 40-80 jaune, 80-150 orange, > 150 rouge.
    private static let pingPositionsMs: [Double] = [10, 30, 60, 115, 185]

    /// Couleur d'une valeur rapportée à un maximum réseau, comme Android : le
    /// ratio situe la teinte sur l'échelle, pas un seuil absolu en Mb/s.
    ///
    /// L'interpolation est CONTINUE, et non par paliers : Android fait un `lerp`
    /// entre teintes adjacentes. S'arrêter au palier le plus proche décalait la
    /// couleur du trait et du chiffre de latence d'un cran entier — la divergence
    /// la plus voyante quand les deux cartes sont mises côte à côte.
    func qualityColor(ratio: Double) -> UIColor {
        Self.gradient(ratio.clampedUnit, positions: Self.fillPositions, stops: speedPalette)
    }

    /// Couleur d'une latence en ms — échelle INVERSÉE : une latence basse doit
    /// tomber sur le vert, donc la palette worst→best est renversée ici.
    func latencyColor(ms: Double) -> UIColor {
        Self.gradient(ms.isFinite ? Swift.max(ms, 0) : 0,
                      positions: Self.pingPositionsMs,
                      stops: Array(speedPalette.reversed()))
    }

    /// Dégradé linéaire par morceaux, saturé aux extrêmes — port de `gradient`
    /// (Android). `positions` est croissant et de même longueur que `stops`.
    private static func gradient(_ value: Double, positions: [Double], stops: [UIColor]) -> UIColor {
        guard positions.count == stops.count, positions.count > 1,
              let first = stops.first, let last = stops.last else { return stops.first ?? .gray }
        if value <= positions[0] { return first }
        if value >= positions[positions.count - 1] { return last }
        for index in 0..<(positions.count - 1)
        where value >= positions[index] && value <= positions[index + 1] {
            let span = positions[index + 1] - positions[index]
            let t = span > 0 ? (value - positions[index]) / span : 0
            return lerp(stops[index], stops[index + 1], CGFloat(t))
        }
        return last
    }

    private static func lerp(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: aa + (ba - aa) * t)
    }
}

// MARK: - Modèle

/// Données de la carte. Miroir de `ShareCardModel` (Android), réduit à ce que la
/// carte dessine réellement — tout le calcul (formatage, échelles, agrégats) se
/// fait en amont, le rendu ne décide de rien.
struct SQShareCardModel {
    struct Graph {
        /// ≤ 32 points, jamais vide.
        let points: [Double]
        let localMax: Double
        let accentColor: UIColor
    }

    struct StatBlock {
        let label: String
        let value: String
        let unit: String
        let maxValue: String
        let labelColor: UIColor
        let graph: Graph
    }

    struct UnderLoadRow {
        let prefix: String
        let valueText: String
        let jitText: String?
        let dotColor: UIColor
    }

    var width: CGFloat = 1_080
    /// 690 sur Android ; 650 ici, la remontée de 40 unités libérant autant de
    /// hauteur. Réduire la carte plutôt que la laisser respirer dans le vide.
    var height: CGFloat = 650
    let theme: SQShareCardTheme

    let brand: String
    let headerNetworkText: String
    let dateTimeText: String?

    let download: StatBlock
    let upload: StatBlock

    let latencyLabel: String
    let latencyValueText: String
    let latencyUnit: String
    let latencySubText: String
    let latencyColor: UIColor

    let underLoadLabel: String
    let underLoadRows: [UnderLoadRow]

    let serverLabel: String
    let serverText: String?

    let deviceCityText: String
    let radioLines: [String]
}

// MARK: - Rendu

/// Rendu Core Graphics de la carte de partage — port fidèle du Canvas Android
/// (`SpeedtestShareCardRenderer.kt`, composition « Halo v3.1 »).
///
/// **Pourquoi Core Graphics et non SwiftUI.** Android dessine en impératif, avec
/// des coordonnées en dur dans un espace logique 1080×690 (colonnes centrées à 297
/// et 783, filet séparateur à 540…). Reproduire cela avec un `ImageRenderer` sur
/// une hiérarchie SwiftUI reviendrait à réinventer la mise en page à partir de
/// contraintes, et elle dériverait au premier ajustement. Le même modèle impératif
/// préserve la géométrie exactement.
///
/// **Différence d'origine des coordonnées de texte.** `Canvas.drawText` place la
/// LIGNE DE BASE ; `NSAttributedString.draw(at:)` place le coin haut-gauche. Toutes
/// les positions verticales d'Android sont donc converties via l'ascendante de la
/// police — c'est le piège numéro un d'un tel port, et il décale tout le texte de
/// la hauteur d'une capitale s'il est manqué.
enum SQShareCardRenderer {

    private static let exportScale: CGFloat = 2
    private static let padX: CGFloat = 54
    private static let colSepX: CGFloat = 540

    /// **Seule divergence assumée avec Android.** Sa mise en page réserve de la
    /// place à un pied garni de deux lignes d'identité radio, qu'iOS ne peut pas
    /// produire. À géométrie strictement identique, la carte iOS se retrouvait donc
    /// creuse en haut ET en bas. TOUT ce qui suit l'en-tête remonte donc de 40
    /// unités logiques, et la hauteur totale diminue d'autant — sinon on ne
    /// déplacerait le vide qu'au milieu de la carte. Largeurs, centres de colonnes
    /// et tailles de texte restent ceux d'Android.
    private static let columnShift: CGFloat = 40

    static func render(_ model: SQShareCardModel) -> UIImage {
        let s = exportScale
        let size = CGSize(width: model.width * s, height: model.height * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // l'échelle est déjà dans les dimensions
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let t = model.theme
            let w = size.width

            // Fond UNI — crème en clair, noir OLED ou gris très foncé en sombre.
            t.background.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            drawMasthead(cg, s: s, w: w, model: model)
            drawLumLine(cg, t: t, rect: CGRect(x: padX * s, y: 99 * s, width: w - 2 * padX * s, height: 1.5 * s), horizontal: true)

            drawLumLine(cg, t: t, rect: CGRect(x: colSepX * s, y: 125 * s, width: 1.5 * s, height: (486 - columnShift - 125) * s), horizontal: false)
            drawSpeedColumn(cg, s: s, t: t, block: model.download, arrow: "↓", centerX: 297)
            drawSpeedColumn(cg, s: s, t: t, block: model.upload, arrow: "↑", centerX: 783)

            drawBottomStrip(cg, s: s, w: w, model: model)
            drawFooter(cg, s: s, w: w, model: model)
        }
    }

    // MARK: Colonnes de débit

    private static func drawSpeedColumn(
        _ cg: CGContext, s: CGFloat, t: SQShareCardTheme,
        block: SQShareCardModel.StatBlock, arrow: String, centerX: CGFloat
    ) {
        let cx = centerX * s
        let colW: CGFloat = 486 * s

        // Kicker « ● ↓ DOWNLOAD » : pastille lumineuse + mono espacé, centrés ensemble.
        let kickFont = SQShareFonts.mono(size: 12 * s, weight: 700)
        let kickText = "\(arrow) \(block.label.uppercased())"
        let kickAttrs = attributes(kickFont, t.textSecondary, kernEm: 0.22)
        let kickW = kickText.size(withAttributes: kickAttrs).width
        let dotR = 4 * s
        let dotGap = 9 * s
        let kickTotal = dotR * 2 + dotGap + kickW
        let kickY = (208 - columnShift) * s
        drawGlowDot(cg, cx: cx - kickTotal / 2 + dotR, cy: kickY - 4 * s, r: dotR, color: block.labelColor, isDark: t.isDark, s: s)
        draw(kickText, attrs: kickAttrs, x: cx - kickTotal / 2 + dotR * 2 + dotGap, baseline: kickY)

        // Chiffre + unité, centrés ensemble. RÉTRÉCI plutôt que tronqué quand la
        // valeur est large (« 1240,6 » sur une colonne de 486) : un débit coupé
        // serait un mensonge, un débit plus petit reste lisible.
        var numFont = SQShareFonts.display(size: 116 * s, weight: 800)
        let unitFont = SQShareFonts.mono(size: 19 * s, weight: 400)
        let unitAttrs = attributes(unitFont, t.textSecondary)
        let unitGap = 12 * s
        var numAttrs = attributes(numFont, t.textPrimary, kernEm: -0.025)
        var numW = block.value.size(withAttributes: numAttrs).width
        let unitW = block.unit.size(withAttributes: unitAttrs).width
        let maxTotal = colW - 32 * s
        if numW + unitGap + unitW > maxTotal {
            let shrink = min(max((maxTotal - unitGap - unitW) / numW, 0.5), 1)
            numFont = SQShareFonts.display(size: 116 * s * shrink, weight: 800)
            numAttrs = attributes(numFont, t.textPrimary, kernEm: -0.025)
            numW = block.value.size(withAttributes: numAttrs).width
        }
        let numY = (330 - columnShift) * s
        let numX = cx - (numW + unitGap + unitW) / 2
        draw(block.value, attrs: numAttrs, x: numX, baseline: numY)
        draw(block.unit, attrs: unitAttrs, x: numX + numW + unitGap, baseline: numY)

        // « MAX 22,0 Mbps » — trois segments centrés.
        let mutedAttrs = attributes(SQShareFonts.mono(size: 12.5 * s, weight: 400), t.textSecondary)
        let valueAttrs = attributes(SQShareFonts.mono(size: 12.5 * s, weight: 700), t.textPrimary)
        let segLabel = "MAX "
        let segUnit = " \(block.unit)"
        let totalW = segLabel.size(withAttributes: mutedAttrs).width
            + block.maxValue.size(withAttributes: valueAttrs).width
            + segUnit.size(withAttributes: mutedAttrs).width
        var mx = cx - totalW / 2
        let maxY = (372 - columnShift) * s
        draw(segLabel, attrs: mutedAttrs, x: mx, baseline: maxY)
        mx += segLabel.size(withAttributes: mutedAttrs).width
        draw(block.maxValue, attrs: valueAttrs, x: mx, baseline: maxY)
        mx += block.maxValue.size(withAttributes: valueAttrs).width
        draw(segUnit, attrs: mutedAttrs, x: mx, baseline: maxY)

        drawTrail(cg, s: s, t: t, graph: block.graph,
                  rect: CGRect(x: cx - 220 * s, y: (388 - columnShift) * s, width: 440 * s, height: 80 * s))
    }

    /// Traînée : grille fine, puis halo et trait net. **Aucun remplissage** sous la
    /// courbe — c'est ce qui distingue la composition Halo d'un graphe classique.
    private static func drawTrail(
        _ cg: CGContext, s: CGFloat, t: SQShareCardTheme,
        graph: SQShareCardModel.Graph, rect: CGRect
    ) {
        cg.saveGState()
        cg.setStrokeColor(t.track.cgColor)
        cg.setLineWidth(1 * s)
        for fraction in [0.26, 0.50, 0.74] as [CGFloat] {
            let y = rect.minY + rect.height * fraction
            cg.move(to: CGPoint(x: rect.minX, y: y))
            cg.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        cg.strokePath()
        cg.restoreGState()

        let points = graph.points
        guard points.count >= 2, graph.localMax > 0 else { return }
        let padXInner = 8 * s
        let padY = 5 * s
        let innerW = rect.width - 2 * padXInner
        let innerH = rect.height - 2 * padY
        let stepX = innerW / CGFloat(points.count - 1)

        let path = CGMutablePath()
        for (index, value) in points.enumerated() {
            let x = rect.minX + padXInner + CGFloat(index) * stepX
            let ratio = CGFloat((value / graph.localMax).clampedUnit)
            let y = rect.minY + padY + innerH - ratio * innerH
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }

        // Halo : une ombre colorée sans décalage tient lieu du `BlurMaskFilter`
        // d'Android — même intention, même rayon.
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(5 * s)
        cg.setStrokeColor(graph.accentColor.withAlphaComponent(t.isDark ? 128 / 255 : 64 / 255).cgColor)
        cg.setShadow(offset: .zero, blur: 6 * s, color: graph.accentColor.withAlphaComponent(t.isDark ? 0.5 : 0.25).cgColor)
        cg.addPath(path)
        cg.strokePath()
        cg.restoreGState()

        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(2.6 * s)
        cg.setStrokeColor(graph.accentColor.cgColor)
        cg.addPath(path)
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: Bande basse

    private static func drawBottomStrip(_ cg: CGContext, s: CGFloat, w: CGFloat, model: SQShareCardModel) {
        let t = model.theme
        let kickAttrs = attributes(SQShareFonts.mono(size: 10.5 * s, weight: 700), t.textSecondary, kernEm: 0.22)
        let kickY = (520 - columnShift) * s

        // LATENCE — héros coloré par la qualité, sous-ligne mono.
        let latX = padX * s
        draw(model.latencyLabel.uppercased(), attrs: kickAttrs, x: latX, baseline: kickY)
        let latFont = SQShareFonts.display(size: 40 * s, weight: 800)
        let latAttrs = attributes(latFont, model.latencyColor, kernEm: -0.01)
        let latY = (566 - columnShift) * s
        draw(model.latencyValueText, attrs: latAttrs, x: latX, baseline: latY)
        let latUnitAttrs = attributes(SQShareFonts.mono(size: 16 * s, weight: 400), model.latencyColor)
        draw(" \(model.latencyUnit)", attrs: latUnitAttrs,
             x: latX + model.latencyValueText.size(withAttributes: latAttrs).width, baseline: latY)
        draw(model.latencySubText,
             attrs: attributes(SQShareFonts.mono(size: 11.5 * s, weight: 400), t.textSecondary),
             x: latX, baseline: (590 - columnShift) * s)

        // SOUS CHARGE — masqué s'il n'y a aucune rangée, filet vertical sinon.
        if !model.underLoadRows.isEmpty {
            drawLumLine(cg, t: t, rect: CGRect(x: 270 * s, y: (505 - columnShift) * s, width: 1.5 * s, height: 90 * s), horizontal: false)
            let blockX = 300 * s
            draw(model.underLoadLabel.uppercased(), attrs: kickAttrs, x: blockX, baseline: kickY)
            let emAttrs = attributes(SQShareFonts.mono(size: 10.5 * s, weight: 700), t.textSecondary)
            let valAttrs = attributes(SQShareFonts.mono(size: 14 * s, weight: 700), t.textPrimary)
            let jitAttrs = attributes(SQShareFonts.mono(size: 11 * s, weight: 400), t.textSecondary)
            for (index, row) in model.underLoadRows.enumerated() {
                let rowY = (545 - columnShift + CGFloat(index) * 25) * s
                drawGlowDot(cg, cx: blockX + 3.5 * s, cy: rowY - 4 * s, r: 3.5 * s, color: row.dotColor, isDark: t.isDark, s: s)
                draw(row.prefix, attrs: emAttrs, x: blockX + 16 * s, baseline: rowY)
                let valX = blockX + 56 * s
                draw(row.valueText, attrs: valAttrs, x: valX, baseline: rowY)
                if let jit = row.jitText {
                    draw(jit, attrs: jitAttrs,
                         x: valX + row.valueText.size(withAttributes: valAttrs).width + 8 * s, baseline: rowY)
                }
            }
        }

        // SERVEUR — aligné à droite, valeur en display. Quand « Sous charge »
        // existe, sa colonne est réservée jusqu'à x=600 : les noms longs ne
        // peuvent plus passer dessous ni le recouvrir.
        if let server = model.serverText {
            let rightX = w - padX * s
            drawRightAligned(model.serverLabel.uppercased(), attrs: kickAttrs, rightX: rightX, baseline: kickY)
            let srvAttrs = attributes(SQShareFonts.display(size: 17 * s, weight: 700), t.textPrimary)
            let serverColumnLeft = (model.underLoadRows.isEmpty ? 470 : 600) * s
            let maxW = rightX - serverColumnLeft
            drawRightAligned(ellipsize(server, attrs: srvAttrs, maxWidth: maxW), attrs: srvAttrs, rightX: rightX, baseline: (552 - columnShift) * s)
        }
    }

    // MARK: Pied

    private static func drawFooter(_ cg: CGContext, s: CGFloat, w: CGFloat, model: SQShareCardModel) {
        let t = model.theme
        cg.saveGState()
        cg.setStrokeColor(t.separator.cgColor)
        cg.setLineWidth(1 * s)
        cg.move(to: CGPoint(x: padX * s, y: (622 - columnShift) * s))
        cg.addLine(to: CGPoint(x: w - padX * s, y: (622 - columnShift) * s))
        cg.strokePath()
        cg.restoreGState()

        let baseY = (652 - columnShift) * s
        let lineStep = 20 * s
        let monoAttrs = attributes(SQShareFonts.mono(size: 12 * s, weight: 400), t.textSecondary)

        // Gauche : appareil et ville lorsqu'ils sont autorisés. Si les deux sont
        // masqués, la signature produit garde le pied visuellement utile sans
        // réintroduire une donnée personnelle.
        let footerText = model.deviceCityText.isEmpty ? "signalquest.fr" : model.deviceCityText
        draw(ellipsize(footerText, attrs: monoAttrs, maxWidth: w * 0.5),
             attrs: monoAttrs, x: padX * s, baseline: baseY)

        // Droite : jusqu'à deux lignes d'identité radio.
        var ry = baseY
        for line in model.radioLines.reversed() {
            drawRightAligned(ellipsize(line, attrs: monoAttrs, maxWidth: w * 0.55), attrs: monoAttrs, rightX: w - padX * s, baseline: ry)
            ry -= lineStep
        }
    }

    // MARK: En-tête

    private static func drawMasthead(_ cg: CGContext, s: CGFloat, w: CGFloat, model: SQShareCardModel) {
        let t = model.theme
        let logoRect = CGRect(x: padX * s, y: 42 * s, width: 42 * s, height: 42 * s)
        drawAppLogo(cg, rect: logoRect, s: s)

        let brandFont = SQShareFonts.display(size: 21 * s, weight: 800)
        let brandAttrs = attributes(brandFont, t.textPrimary, kernEm: 0.26)
        let brandY = logoRect.midY + brandFont.pointSize * 0.35
        draw(model.brand, attrs: brandAttrs, x: logoRect.maxX + 13 * s, baseline: brandY)

        let rightX = w - padX * s
        let hasNetwork = !model.headerNetworkText.isEmpty
        if hasNetwork {
            let netAttrs = attributes(SQShareFonts.mono(size: 14 * s, weight: 700), t.textPrimary, kernEm: 0.03)
            drawRightAligned(
                ellipsize(model.headerNetworkText.uppercased(), attrs: netAttrs, maxWidth: w * 0.5),
                attrs: netAttrs, rightX: rightX,
                baseline: model.dateTimeText != nil ? 58 * s : logoRect.midY + 5 * s
            )
        }
        if let date = model.dateTimeText {
            let dateAttrs = attributes(SQShareFonts.mono(size: 12.5 * s, weight: 400), t.textSecondary)
            drawRightAligned(
                date,
                attrs: dateAttrs,
                rightX: rightX,
                baseline: hasNetwork ? 78 * s : logoRect.midY + 5 * s
            )
        }
    }

    /// Logo de l'app clippé en carré arrondi, cerclé d'un liseré discret — sans
    /// halo, conformément à la v3.1.
    private static func drawAppLogo(_ cg: CGContext, rect: CGRect, s: CGFloat) {
        let radius = 12 * s
        cg.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        UIColor(hex: 0xF4E9DF).setFill()
        cg.fill(rect)
        if let icon = appIcon() {
            // Contrairement au foreground adaptatif d'Android, l'icône iOS est déjà
            // cadrée : pas de débord à compenser, sous peine de rogner le logo.
            icon.draw(in: rect)
        }
        cg.restoreGState()

        cg.saveGState()
        cg.setStrokeColor(UIColor(hex: 0x000000, alpha: 0x1F / 255).cgColor)
        cg.setLineWidth(1 * s)
        UIBezierPath(roundedRect: rect, cornerRadius: radius).stroke()
        cg.restoreGState()
    }

    /// Icône de l'app pour la carte.
    ///
    /// `UIImage(named: "AppIcon")` ne fonctionne PAS : une icône d'app n'est pas une
    /// ressource image adressable du catalogue. Il faut passer par `Info.plist`, qui
    /// liste les fichiers réellement produits par le build. Sans cela le logo
    /// restait un carré beige vide — un défaut invisible en compilation, et qui ne
    /// se voit que sur l'image exportée.
    static func appIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let lastName = files.last
        else { return nil }
        return UIImage(named: lastName)
    }

    // MARK: Primitives

    /// Filet qui s'évanouit aux extrémités — dégradé neutre, jamais teinté.
    private static func drawLumLine(_ cg: CGContext, t: SQShareCardTheme, rect: CGRect, horizontal: Bool) {
        let strong = t.separator.cgColor
        let faint = t.separator.withAlphaComponent(0).cgColor
        guard let space = strong.colorSpace,
              let gradient = CGGradient(colorsSpace: space, colors: [faint, strong, faint] as CFArray, locations: [0, 0.5, 1])
        else { return }
        cg.saveGState()
        cg.clip(to: rect)
        cg.drawLinearGradient(
            gradient,
            start: horizontal ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY),
            end: horizontal ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        cg.restoreGState()
    }

    private static func drawGlowDot(_ cg: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, color: UIColor, isDark: Bool, s: CGFloat) {
        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 4 * s, color: color.withAlphaComponent(isDark ? 120 / 255 : 70 / 255).cgColor)
        color.setFill()
        cg.fillEllipse(in: rect)
        cg.restoreGState()
        color.setFill()
        cg.fillEllipse(in: rect)
    }

    // MARK: Texte

    private static func attributes(_ font: UIFont, _ color: UIColor, kernEm: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // Android exprime l'espacement en EM ; `kern` l'attend en points.
        if kernEm != 0 { attrs[.kern] = kernEm * font.pointSize }
        return attrs
    }

    /// Dessine à partir de la LIGNE DE BASE, comme `Canvas.drawText`.
    private static func draw(_ text: String, attrs: [NSAttributedString.Key: Any], x: CGFloat, baseline: CGFloat) {
        guard let font = attrs[.font] as? UIFont else { return }
        (text as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
    }

    private static func drawRightAligned(_ text: String, attrs: [NSAttributedString.Key: Any], rightX: CGFloat, baseline: CGFloat) {
        let width = (text as NSString).size(withAttributes: attrs).width
        draw(text, attrs: attrs, x: rightX - width, baseline: baseline)
    }

    /// Coupe au caractère près, comme Android : on préfère une fin en « … » à un
    /// débordement hors carte, qui passerait inaperçu à la génération.
    static func ellipsize(_ text: String, attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> String {
        guard (text as NSString).size(withAttributes: attrs).width > maxWidth else { return text }
        var end = text.count
        while end > 1 {
            let candidate = String(text.prefix(end)) + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth { break }
            end -= 1
        }
        return String(text.prefix(end)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Utilitaires

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private extension Double {
    /// Borné à 0…1, `NaN` inclus — une division par un maximum nul produirait
    /// sinon une coordonnée non finie et un tracé vide.
    var clampedUnit: Double { isFinite ? Swift.min(Swift.max(self, 0), 1) : 0 }
}

extension SQShareCardTheme {
    /// Thème de la carte pour l'apparence courante et le réglage OLED de l'app —
    /// même règle qu'Android, où `buildShareCardTheme` écrase le fond selon
    /// `isPureBlack`. Une carte partagée depuis une app en noir intense doit
    /// l'être aussi, sinon le réglage s'arrête à la frontière de l'image.
    static func current(colorScheme: ColorScheme) -> SQShareCardTheme {
        resolve(isDark: colorScheme == .dark, isPureBlack: SQOledPalette.isEnabled)
    }
}
