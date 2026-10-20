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

/// Données de l'image de partage « A — Fiche » (validée le 19/10, commune au web
/// et à Android). Tout est déjà formaté : le rendu ne décide de rien, et chaque
/// valeur optionnelle absente RETIRE sa ligne — jamais de zéro ni de tiret.
struct SQShareCardModel {
    struct Graph {
        /// Real samples; fewer than two means no curve is drawn.
        let points: [Double]
        /// Valeur qui touche le haut du tracé.
        let localMax: Double
        /// Teinte du trait et de son dégradé : encre pour le descendant, marque
        /// pour le montant. Jamais l'échelle de qualité.
        let accentColor: UIColor
        var normalizedTimes: [Double]? = nil
        var durationSeconds: Double? = nil
        /// « MAX 231 Mb/s » à droite de l'intitulé, et la valeur où tombe son
        /// pointillé (planche commune du 20/10, alignée sur Android).
        var maxText: String? = nil
        var maxValue: Double? = nil
    }

    /// Flèche tracée (Sora n'a pas de glyphe ↓ ↑).
    enum Arrow { case down, up }

    /// Un nombre et son unité, composés séparément (« 1,722 » + « Gb/s »).
    struct Value: Equatable {
        let number: String
        let unit: String
    }

    /// « SFR · 5G », « Free · Wi-Fi », ou la techno seule et sans barre quand
    /// l'opérateur est inconnu (VPN).
    struct NetworkLine {
        let name: String
        let detail: String?
        let barColor: UIColor?
    }

    struct Grade {
        let letter: String
        let color: UIColor
        let background: UIColor
    }

    /// Ligne de la colonne de droite : libellé, pointillés, valeur.
    struct Row {
        let label: String
        let value: String
        var grade: Grade? = nil
        /// « Sous charge ↓ » : flèche tracée 6 après l'intitulé.
        var arrow: Arrow? = nil
    }

    var width: CGFloat = 1_200
    var height: CGFloat = 630

    /// `nil` : l'en-tête ne garde que « Speedtest ».
    let dateText: String?
    let network: NetworkLine?

    let download: Value
    /// « MAX 1,841 Gb/s » sous le chiffre, seulement sans courbe : avec elle, le
    /// MAX s'écrit sur la courbe.
    let downloadPeakText: String?
    let downloadGraph: Graph?

    let upload: Value?
    /// « MAX 131 Mb/s », même règle ; absent si égal au débit.
    let uploadPeakText: String?
    let uploadGraph: Graph?

    /// « Latence min. » au-dessus du minimum, « Latence » au-dessus d'un repli.
    let latencyLabel: String
    let latency: Value?
    /// « Moyenne 18 ms », seulement sous un minimum.
    let latencyAverageText: String?

    let rows: [Row]

    /// « iPhone 17 Pro · Grenoble » ; vide si l'utilisateur a retiré les deux.
    let deviceCityText: String

    var hasCurves: Bool { downloadGraph != nil || uploadGraph != nil }
}

// MARK: - Rendu

/// Rendu Core Graphics de l'image A, au point près de la référence HTML
/// (1200×630, exportée ×2).
///
/// **Pourquoi Core Graphics et non SwiftUI.** La référence est une grille CSS
/// figée ; ses cotes se calculent une fois pour toutes (en-tête 28, cartouche
/// 90…552, colonnes 1,1fr | 1 | 1fr…). Les poser en dur reproduit l'image à
/// l'identique, là où une hiérarchie SwiftUI dériverait au premier ajustement de
/// police ou d'interligne.
///
/// **Lignes de texte.** Le HTML compose chaque texte dans une boîte
/// `line-height` ; la ligne de base s'y trouve à mi-hauteur de l'œil de la
/// police, pas en haut. `baseline(top:height:font:)` refait ce calcul — sans lui
/// tout le texte remonte de plusieurs points.
enum SQShareCardRenderer {

    private static let exportScale: CGFloat = 2

    // Palette unique de A : une image publiée n'a pas à suivre le thème de l'app.
    private static let paper = UIColor(hex: 0xF4F2EC)
    private static let ink = UIColor(hex: 0x1C201E)
    private static let ink2 = UIColor(hex: 0x3C443F)
    private static let muted = UIColor(hex: 0x636B66)
    private static let brand = UIColor(hex: 0xA8123A)
    private static let rule = UIColor(hex: 0x1C201E, alpha: 0.09)
    private static let leaderDot = UIColor(hex: 0x1C201E, alpha: 0.34)

    // Cotes logiques de la référence.
    private static let pagePadX: CGFloat = 48
    private static let pagePadY: CGFloat = 40
    private static let sectionGap: CGFloat = 22
    private static let headerHeight: CGFloat = 28
    private static let footerHeight: CGFloat = 16
    private static let cardPadX: CGFloat = 40
    private static let cardPadY: CGFloat = 32
    private static let columnGap: CGFloat = 40
    private static let rowGap: CGFloat = 22
    /// 80 sans bloc radio (spécification v11) ; 92 auparavant.
    private static let graphHeight: CGFloat = 80

    static func render(_ model: SQShareCardModel) -> UIImage {
        let s = exportScale
        let size = CGSize(width: model.width * s, height: model.height * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // l'échelle est déjà dans les dimensions
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // Tout est ensuite posé en unités logiques, comme dans la référence.
            cg.scaleBy(x: s, y: s)
            paper.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: model.width, height: model.height))

            drawHeader(cg, model: model)
            drawCard(cg, model: model)
            drawFooter(model: model)
        }
    }

    // MARK: En-tête et pied

    private static func drawHeader(_ cg: CGContext, model: SQShareCardModel) {
        let top = pagePadY
        // « signal◆quest » : le losange est une boîte de 11 tournée de 45°.
        let logoFont = SQShareFonts.display(size: 28, weight: 800)
        let logoAttrs = attributes(logoFont, ink, kernEm: -0.03)
        let logoBaseline = baseline(top: top, height: headerHeight, font: logoFont)
        var x = pagePadX
        x += draw("signal", attrs: logoAttrs, x: x, baseline: logoBaseline)
        let diamondCenter = CGPoint(x: x + 7 + 5.5, y: top + headerHeight / 2)
        cg.saveGState()
        cg.translateBy(x: diamondCenter.x, y: diamondCenter.y)
        cg.rotate(by: .pi / 4)
        brand.setFill()
        cg.fill(CGRect(x: -5.5, y: -5.5, width: 11, height: 11))
        cg.restoreGState()
        x += 7 + 11 + 7
        draw("quest", attrs: logoAttrs, x: x, baseline: logoBaseline)

        let titleAttrs = attributes(tabular(SQShareFonts.display(size: 16, weight: 700)), ink)
        let dateAttrs = attributes(tabular(SQShareFonts.display(size: 16, weight: 600)), muted)
        let lineTop = top + (headerHeight - 16) / 2
        let base = baseline(top: lineTop, height: 16, font: titleAttrs.font)
        let title = String(localized: "Speedtest")
        let date = model.dateText.map { " · \($0)" } ?? ""
        let right = model.width - pagePadX
        let dateX = right - width(date, dateAttrs)
        draw(date, attrs: dateAttrs, x: dateX, baseline: base)
        draw(title, attrs: titleAttrs, x: dateX - width(title, titleAttrs), baseline: base)
    }

    private static func drawFooter(model: SQShareCardModel) {
        let top = model.height - pagePadY - footerHeight
        let leftAttrs = attributes(SQShareFonts.display(size: 16, weight: 500), ink2)
        let rightAttrs = attributes(SQShareFonts.display(size: 16, weight: 700), ink)
        let base = baseline(top: top, height: footerHeight, font: leftAttrs.font)
        let site = "signalquest.fr"
        let right = model.width - pagePadX
        let siteW = width(site, rightAttrs)
        draw(site, attrs: rightAttrs, x: right - siteW, baseline: base)
        if !model.deviceCityText.isEmpty {
            let maxW = right - siteW - 24 - pagePadX
            draw(ellipsize(model.deviceCityText, attrs: leftAttrs, maxWidth: maxW),
                 attrs: leftAttrs, x: pagePadX, baseline: base)
        }
    }

    // MARK: Cartouche

    private static func drawCard(_ cg: CGContext, model: SQShareCardModel) {
        let cardTop = pagePadY + headerHeight + sectionGap
        let cardBottom = model.height - pagePadY - footerHeight - sectionGap
        let card = CGRect(x: pagePadX, y: cardTop, width: model.width - 2 * pagePadX, height: cardBottom - cardTop)
        let cardPath = UIBezierPath(roundedRect: card, cornerRadius: 28).cgPath
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 4), blur: 20, color: UIColor(hex: 0x1C201E, alpha: 0.08).cgColor)
        UIColor.white.setFill()
        cg.addPath(cardPath)
        cg.fillPath()
        cg.restoreGState()

        let content = card.insetBy(dx: cardPadX, dy: cardPadY)
        // Grille 1,1fr | 1 | 1fr, écart 40 — la colonne de droite fait 449 de large,
        // la largeur exacte des courbes de la référence.
        let leftWidth = (content.width - 2 * columnGap - 1) * 1.1 / 2.1
        let ruleX = content.minX + leftWidth + columnGap
        let rightX = ruleX + 1 + columnGap
        let rightWidth = content.maxX - rightX

        // Rangée basse : hauteur de son contenu le plus haut (70 pour les chiffres,
        // 96 quand l'un porte une sous-ligne ; 22 par ligne de détail plus 6 entre
        // deux), comme `grid-template-rows: auto`.
        let figures = bottomFigures(model)
        let leftHeight: CGFloat = figures.isEmpty ? 0 : (figures.contains { $0.subText != nil } ? 96 : 70)
        let rightHeight: CGFloat = model.rows.isEmpty ? 0 : CGFloat(model.rows.count) * 28 - 6
        let bottomHeight = max(leftHeight, rightHeight)
        let topBottom = bottomHeight > 0 ? content.maxY - bottomHeight - 2 * rowGap - 1 : content.maxY

        if bottomHeight > 0 {
            fillRule(cg, CGRect(x: content.minX, y: topBottom + rowGap, width: content.width, height: 1))
        }
        // Le filet vertical court sur toute la hauteur quand il sépare les courbes ;
        // sans elles, il ne sépare plus que la rangée basse.
        if model.hasCurves {
            fillRule(cg, CGRect(x: ruleX, y: content.minY, width: 1, height: content.height))
        } else if leftHeight > 0, rightHeight > 0 {
            fillRule(cg, CGRect(x: ruleX, y: content.maxY - bottomHeight, width: 1, height: bottomHeight))
        }

        let heroWidth = model.hasCurves ? leftWidth : content.width
        drawHero(model: model, rect: CGRect(x: content.minX, y: content.minY, width: heroWidth, height: topBottom - content.minY))
        if model.hasCurves {
            drawGraphs(cg, model: model, rect: CGRect(x: rightX, y: content.minY, width: rightWidth, height: topBottom - content.minY))
        }
        if !figures.isEmpty {
            drawFigures(cg, figures, rect: CGRect(x: content.minX, y: content.maxY - leftHeight, width: leftWidth, height: leftHeight))
        }
        if !model.rows.isEmpty {
            drawRows(cg, model.rows, rect: CGRect(x: rightX, y: content.maxY - rightHeight, width: rightWidth, height: rightHeight))
        }
    }

    // MARK: Descendant

    private static func drawHero(model: SQShareCardModel, rect: CGRect) {
        if let network = model.network {
            var x = rect.minX
            if let bar = network.barColor {
                bar.setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: rect.minY, width: 4, height: 22), cornerRadius: 2).fill()
                x += 4 + 10
            }
            let nameAttrs = attributes(SQShareFonts.display(size: 22, weight: 700), ink)
            let detailAttrs = attributes(SQShareFonts.display(size: 22, weight: 600), ink2)
            let base = baseline(top: rect.minY, height: 22, font: nameAttrs.font)
            x += draw(network.name, attrs: nameAttrs, x: x, baseline: base)
            if let detail = network.detail {
                draw(" · \(detail)", attrs: detailAttrs, x: x, baseline: base)
            }
        }

        // Sans courbes, le chiffre a toute la largeur : il grossit (172 au lieu de 148).
        let heroSize: CGFloat = model.hasCurves ? 148 : 172
        let unitSize: CGFloat = model.hasCurves ? 34 : 40
        let peakHeight: CGFloat = model.downloadPeakText == nil ? 0 : 14 + 16
        // Pile calée en bas : rubrique 12, écart 14, chiffre (marges −6 et −4), écart 14, pic 16.
        let stackHeight = 12 + 14 + (heroSize - 10) + peakHeight
        let kickerTop = rect.maxY - stackHeight
        drawKicker(String(localized: "Descendant"), arrow: .down, x: rect.minX, top: kickerTop)

        var numberFont = tabular(SQShareFonts.display(size: heroSize, weight: 800))
        let unitAttrs = attributes(SQShareFonts.display(size: unitSize, weight: 700), muted)
        var numberAttrs = attributes(numberFont, ink, kernEm: -0.045)
        let unitW = width(model.download.unit, unitAttrs)
        // Rétréci plutôt que coupé : un débit tronqué serait faux.
        let numberW = width(model.download.number, numberAttrs)
        if numberW + 12 + unitW > rect.width {
            let shrink = max((rect.width - 12 - unitW) / numberW, 0.4)
            numberFont = tabular(SQShareFonts.display(size: heroSize * shrink, weight: 800))
            numberAttrs = attributes(numberFont, ink, kernEm: -0.045)
        }
        let numberTop = kickerTop + 12 + 14 - 6
        let base = baseline(top: numberTop, height: heroSize, font: SQShareFonts.display(size: heroSize, weight: 800))
        let advance = draw(model.download.number, attrs: numberAttrs, x: rect.minX, baseline: base)
        draw(model.download.unit, attrs: unitAttrs, x: rect.minX + advance + 12, baseline: base)

        if let peak = model.downloadPeakText {
            let peakAttrs = attributes(tabular(SQShareFonts.display(size: 16, weight: 600)), ink2)
            let peakTop = rect.maxY - 16
            draw(peak, attrs: peakAttrs, x: rect.minX, baseline: baseline(top: peakTop, height: 16, font: peakAttrs.font))
        }
    }

    // MARK: Courbes

    private static func drawGraphs(_ cg: CGContext, model: SQShareCardModel, rect: CGRect) {
        // Deux blocs (en-tête 22, écart 8, tracé) répartis aux extrémités.
        let blockHeight: CGFloat = 22 + 8 + graphHeight
        var blocks: [(SQShareCardModel.Graph, String, SQShareCardModel.Arrow, CGFloat)] = []
        if let graph = model.downloadGraph { blocks.append((graph, String(localized: "Descendant"), .down, 0.1)) }
        if let graph = model.uploadGraph { blocks.append((graph, String(localized: "Montant"), .up, 0.14)) }
        // La durée ne s'écrit qu'une fois, sous la dernière courbe, quand les deux
        // phases durent autant ; sinon sous chacune.
        let durations = blocks.map { block in
            block.0.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        }
        let sameDuration = durations.count == 2 && durations[0] != nil && durations[0] == durations[1]
        for (index, block) in blocks.enumerated() {
            let top = index == 0 ? rect.minY : rect.maxY - blockHeight
            drawKicker(block.1, arrow: block.2, x: rect.minX, top: top + 5)
            if let maxText = block.0.maxText {
                let attrs = attributes(tabular(SQShareFonts.display(size: 12, weight: 700)), ink2)
                draw(maxText, attrs: attrs, x: rect.maxX - width(maxText, attrs),
                     baseline: baseline(top: top + 5, height: 12, font: attrs.font))
            }
            let plot = CGRect(x: rect.minX, y: top + 30, width: rect.width, height: graphHeight)
            drawCurve(cg, graph: block.0, fillOpacity: block.3, rect: plot)
            if let seconds = durations[index], !sameDuration || index == blocks.count - 1 {
                // 3 sous la courbe, dans l'écart existant : aucune hauteur ajoutée.
                let attrs = attributes(tabular(SQShareFonts.display(size: 11, weight: 600)), muted)
                let text = "\(seconds) s"
                draw(text, attrs: attrs, x: rect.maxX - width(text, attrs),
                     baseline: baseline(top: plot.maxY + 3, height: 11, font: attrs.font))
            }
        }
    }

    /// Tracé de la référence : la valeur max touche y = 4, zéro tombe 1,5 au-dessus
    /// du bas ; dégradé vertical sous la courbe, filet de base, trait de 2,5. Chaque
    /// point est placé au temps de sa fenêtre, sans point (0, 0) ajouté ; tous sont
    /// tracés, montée en charge comprise.
    private static func drawCurve(_ cg: CGContext, graph: SQShareCardModel.Graph, fillOpacity: CGFloat, rect: CGRect) {
        fillRule(cg, CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        let points = graph.points
        guard points.count >= 2, graph.localMax > 0 else { return }
        if let maxValue = graph.maxValue, maxValue.isFinite, maxValue > 0 {
            // Pointillé du MAX à sa hauteur : un point de rayon 0,9 tous les 5,
            // de x + 1 à x + W, encre à 34 %.
            let ratio = CGFloat((maxValue / graph.localMax).clampedUnit)
            let y = rect.minY + 4 + (1 - ratio) * (rect.height - 5.5)
            leaderDot.setFill()
            var x = rect.minX + 1
            while x <= rect.maxX {
                cg.fillEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                x += 5
            }
        }
        let plotted: [CGPoint] = points.enumerated().map { index, value in
            let fraction = graph.normalizedTimes.flatMap { index < $0.count ? $0[index] : nil }
                ?? Double(index) / Double(points.count - 1)
            let ratio = CGFloat((value / graph.localMax).clampedUnit)
            return CGPoint(x: rect.minX + CGFloat(fraction.clampedUnit) * rect.width,
                           y: rect.minY + 4 + (1 - ratio) * (rect.height - 5.5))
        }
        let line = CGMutablePath()
        line.addLines(between: plotted)

        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: plotted[0].x, y: rect.maxY))
        fill.addLines(between: plotted)
        fill.addLine(to: CGPoint(x: plotted[plotted.count - 1].x, y: rect.maxY))
        fill.closeSubpath()
        let colors = [graph.accentColor.withAlphaComponent(fillOpacity).cgColor,
                      graph.accentColor.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            cg.saveGState()
            cg.addPath(fill)
            cg.clip()
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            cg.restoreGState()
        }

        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(2.5)
        cg.setStrokeColor(graph.accentColor.cgColor)
        cg.addPath(line)
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: Rangée basse

    private struct Figure {
        let label: String
        let arrow: SQShareCardModel.Arrow?
        let value: SQShareCardModel.Value
        let subText: String?
    }

    private static func bottomFigures(_ model: SQShareCardModel) -> [Figure] {
        [
            model.upload.map { Figure(label: String(localized: "Montant"), arrow: .up, value: $0, subText: model.uploadPeakText) },
            model.latency.map { Figure(label: model.latencyLabel, arrow: nil, value: $0, subText: model.latencyAverageText) },
        ].compactMap { $0 }
    }

    /// Montant et latence, deux colonnes égales (écart 24) : rubrique, chiffre de
    /// 48, puis la sous-ligne éventuelle, chacune à 10 de la précédente.
    private static func drawFigures(_ cg: CGContext, _ figures: [Figure], rect: CGRect) {
        let columnWidth = (rect.width - 24) / 2
        for (index, figure) in figures.enumerated() {
            let x = rect.minX + CGFloat(index) * (columnWidth + 24)
            drawKicker(figure.label, arrow: figure.arrow, x: x, top: rect.minY)
            var numberAttrs = attributes(tabular(SQShareFonts.display(size: 48, weight: 800)), ink, kernEm: -0.04)
            let unitAttrs = attributes(SQShareFonts.display(size: 17, weight: 700), muted)
            let unitW = width(figure.value.unit, unitAttrs)
            let numberW = width(figure.value.number, numberAttrs)
            if numberW + 8 + unitW > columnWidth {
                let shrink = max((columnWidth - 8 - unitW) / numberW, 0.4)
                numberAttrs = attributes(tabular(SQShareFonts.display(size: 48 * shrink, weight: 800)), ink, kernEm: -0.04)
            }
            let base = baseline(top: rect.minY + 22, height: 48, font: SQShareFonts.display(size: 48, weight: 800))
            let advance = draw(figure.value.number, attrs: numberAttrs, x: x, baseline: base)
            draw(figure.value.unit, attrs: unitAttrs, x: x + advance + 8, baseline: base)
            if let sub = figure.subText {
                let subAttrs = attributes(tabular(SQShareFonts.display(size: 16, weight: 600)), ink2)
                draw(ellipsize(sub, attrs: subAttrs, maxWidth: columnWidth), attrs: subAttrs, x: x,
                     baseline: baseline(top: rect.minY + 80, height: 16, font: subAttrs.font))
            }
        }
    }

    /// Lignes « libellé ····· valeur » de 22, espacées de 6.
    private static func drawRows(_ cg: CGContext, _ rows: [SQShareCardModel.Row], rect: CGRect) {
        let labelAttrs = attributes(SQShareFonts.display(size: 16, weight: 400), ink2)
        let valueAttrs = attributes(tabular(SQShareFonts.display(size: 16, weight: 700)), ink)
        for (index, row) in rows.enumerated() {
            let top = rect.minY + CGFloat(index) * 28
            let base = baseline(top: top, height: 22, font: labelAttrs.font)
            var labelEnd = rect.minX + draw(row.label, attrs: labelAttrs, x: rect.minX, baseline: base)
            if let arrow = row.arrow {
                drawArrow(arrow, x: labelEnd + 6, top: top + 5, color: ink2)
                labelEnd += 6 + 12
            }

            let badgeWidth: CGFloat = row.grade == nil ? 0 : 22 + 8
            let available = rect.maxX - labelEnd - 10 - 10 - badgeWidth
            let value = ellipsize(row.value, attrs: valueAttrs, maxWidth: available)
            let valueX = rect.maxX - width(value, valueAttrs)
            draw(value, attrs: valueAttrs, x: valueX, baseline: base)

            var leaderEnd = valueX - 10
            if let grade = row.grade {
                let badge = CGRect(x: valueX - 8 - 22, y: top, width: 22, height: 22)
                grade.background.setFill()
                UIBezierPath(roundedRect: badge, cornerRadius: 6).fill()
                let gradeAttrs = attributes(SQShareFonts.display(size: 13, weight: 800), grade.color)
                draw(grade.letter, attrs: gradeAttrs, x: badge.midX - width(grade.letter, gradeAttrs) / 2,
                     baseline: baseline(top: top, height: 22, font: gradeAttrs.font))
                leaderEnd = badge.minX - 10
            }
            drawLeader(cg, from: labelEnd + 10, to: leaderEnd, centerY: top + 22 - 6 - 1.5)
        }
    }

    /// Pointillés : un point de rayon ~1,2 tous les 6, comme le motif CSS
    /// `radial-gradient` 6×3 de la référence ; la dernière tuile est coupée.
    private static func drawLeader(_ cg: CGContext, from start: CGFloat, to end: CGFloat, centerY: CGFloat) {
        guard end > start else { return }
        cg.saveGState()
        cg.clip(to: CGRect(x: start, y: centerY - 1.5, width: end - start, height: 3))
        leaderDot.setFill()
        var x = start + 3
        while x - 1.2 < end {
            cg.fillEllipse(in: CGRect(x: x - 1.2, y: centerY - 1.2, width: 2.4, height: 2.4))
            x += 6
        }
        cg.restoreGState()
    }

    // MARK: Rubriques

    /// Rubrique « ↓ DESCENDANT » : flèche de 12 tracée (et non un glyphe,
    /// absent de Sora), 7 d'écart, capitales espacées de 0,18 em.
    private static func drawKicker(_ text: String, arrow: SQShareCardModel.Arrow?, x: CGFloat, top: CGFloat) {
        var textX = x
        if let arrow {
            drawArrow(arrow, x: x, top: top, color: muted)
            textX += 12 + 7
        }
        let attrs = attributes(SQShareFonts.display(size: 12, weight: 700), muted, kernEm: 0.18)
        draw(text.uppercased(), attrs: attrs, x: textX, baseline: baseline(top: top, height: 12, font: attrs.font))
    }

    /// Flèche de 12 × 12, trait de 1,8 aux bouts arrondis.
    private static func drawArrow(_ arrow: SQShareCardModel.Arrow, x: CGFloat, top: CGFloat, color: UIColor) {
        let path = UIBezierPath()
        switch arrow {
        case .down:
            path.move(to: CGPoint(x: x + 6, y: top + 1.5)); path.addLine(to: CGPoint(x: x + 6, y: top + 10.5))
            path.move(to: CGPoint(x: x + 2.5, y: top + 7)); path.addLine(to: CGPoint(x: x + 6, y: top + 10.5))
            path.addLine(to: CGPoint(x: x + 9.5, y: top + 7))
        case .up:
            path.move(to: CGPoint(x: x + 6, y: top + 10.5)); path.addLine(to: CGPoint(x: x + 6, y: top + 1.5))
            path.move(to: CGPoint(x: x + 2.5, y: top + 5)); path.addLine(to: CGPoint(x: x + 6, y: top + 1.5))
            path.addLine(to: CGPoint(x: x + 9.5, y: top + 5))
        }
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func fillRule(_ cg: CGContext, _ rect: CGRect) {
        rule.setFill()
        cg.fill(rect)
    }

    // MARK: Texte

    private static func attributes(_ font: UIFont, _ color: UIColor, kernEm: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // La référence exprime l'espacement en em ; `kern` l'attend en points.
        if kernEm != 0 { attrs[.kern] = kernEm * font.pointSize }
        return attrs
    }

    /// Chiffres à chasse fixe (`tnum`), comme `font-variant-numeric: tabular-nums`.
    private static func tabular(_ font: UIFont) -> UIFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]],
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Ligne de base d'un texte centré dans une boîte `line-height` de `height`.
    private static func baseline(top: CGFloat, height: CGFloat, font: UIFont) -> CGFloat {
        top + (height - (font.ascender - font.descender)) / 2 + font.ascender
    }

    private static func width(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        (text as NSString).size(withAttributes: attrs).width
    }

    /// Dessine à partir de la LIGNE DE BASE et renvoie l'avance horizontale.
    @discardableResult
    private static func draw(_ text: String, attrs: [NSAttributedString.Key: Any], x: CGFloat, baseline: CGFloat) -> CGFloat {
        guard let font = attrs[.font] as? UIFont else { return 0 }
        (text as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
        return width(text, attrs)
    }

    /// Coupe au caractère près : une fin en « … » plutôt qu'un débordement hors
    /// cartouche, qui passerait inaperçu à la génération.
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

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    var font: UIFont { self[.font] as? UIFont ?? .systemFont(ofSize: 12) }
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
