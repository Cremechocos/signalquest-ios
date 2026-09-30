import CoreGraphics
import UIKit

/// Carte de partage d'un Drive Test (plan 3, vague 1).
///
/// Même thème, mêmes polices et même palette de débit que la carte d'un
/// speedtest (`SQShareCardTheme`, `SQShareFonts`), en portrait pour laisser
/// la place au tracé. Le tracé est dessiné sans fond de carte : aucune rue,
/// aucun nom de lieu, seulement la forme du trajet et ses mesures.
struct DriveShareCardModel {
    struct Stat: Equatable {
        let label: String
        let value: String
    }

    var width: CGFloat = 1_080
    var height: CGFloat = 1_350
    let theme: SQShareCardTheme
    let title: String
    let dateText: String
    /// Tracé normalisé (0…1, nord en haut). Vide : masqué ou trop court.
    let route: [CGPoint]
    let measures: [(point: CGPoint, qualityRatio: Double)]
    /// Ce qu'on écrit à la place d'un tracé absent.
    let routeCaption: String?
    let stats: [Stat]
    let footer: String?
}

enum DriveShareCardRenderer {
    private static let exportScale: CGFloat = 2
    private static let padX: CGFloat = 54

    static func render(_ model: DriveShareCardModel) -> UIImage {
        let s = exportScale
        let size = CGSize(width: model.width * s, height: model.height * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let t = model.theme
            t.background.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // En-tête : marque et titre à gauche, date à droite.
            let brand = SQShareFonts.display(size: 40 * s, weight: 800)
            let kicker = SQShareFonts.mono(size: 20 * s, weight: 700)
            draw("SignalQuest", font: brand, color: t.textPrimary, x: padX * s, top: 44 * s)
            draw(model.title.uppercased(), font: kicker, color: t.textSecondary, x: padX * s, top: 100 * s, kernEm: 0.18)
            drawRight(model.dateText, font: SQShareFonts.mono(size: 22 * s, weight: 400), color: t.textSecondary,
                      rightX: (model.width - padX) * s, top: 58 * s)
            t.separator.setFill()
            cg.fill(CGRect(x: padX * s, y: 150 * s, width: (model.width - 2 * padX) * s, height: 1.5 * s))

            drawRoute(cg, model: model, box: CGRect(x: padX * s, y: 180 * s,
                                                    width: (model.width - 2 * padX) * s, height: 700 * s), s: s)
            drawStats(model, s: s, top: 920 * s)

            if let footer = model.footer {
                draw(footer, font: SQShareFonts.mono(size: 22 * s, weight: 400), color: t.textSecondary,
                     x: padX * s, top: 1_270 * s)
            }
            drawRight("signalquest.fr", font: SQShareFonts.mono(size: 22 * s, weight: 700), color: t.textSecondary,
                      rightX: (model.width - padX) * s, top: 1_270 * s)
        }
    }

    // MARK: Tracé

    private static func drawRoute(_ cg: CGContext, model: DriveShareCardModel, box: CGRect, s: CGFloat) {
        let t = model.theme
        // Trame discrète : donne une échelle au tracé sans montrer de lieu.
        cg.saveGState()
        cg.addPath(UIBezierPath(roundedRect: box, cornerRadius: 28 * s).cgPath)
        cg.clip()
        t.track.withAlphaComponent(0.35).setFill()
        cg.fill(box)
        t.track.setStroke()
        cg.setLineWidth(1 * s)
        var x = box.minX + 60 * s
        while x < box.maxX { cg.move(to: CGPoint(x: x, y: box.minY)); cg.addLine(to: CGPoint(x: x, y: box.maxY)); x += 60 * s }
        var y = box.minY + 60 * s
        while y < box.maxY { cg.move(to: CGPoint(x: box.minX, y: y)); cg.addLine(to: CGPoint(x: box.maxX, y: y)); y += 60 * s }
        cg.strokePath()
        cg.restoreGState()

        guard model.route.count >= 2 else {
            if let caption = model.routeCaption {
                let font = SQShareFonts.mono(size: 26 * s, weight: 400)
                let width = (caption as NSString).size(withAttributes: [.font: font]).width
                draw(caption, font: font, color: t.textSecondary, x: box.midX - width / 2, top: box.midY - 16 * s)
            }
            return
        }
        // Carré centré : le tracé garde ses proportions.
        let side = min(box.width, box.height) - 120 * s
        let origin = CGPoint(x: box.midX - side / 2, y: box.midY - side / 2)
        func project(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * side, y: origin.y + p.y * side) }

        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(10 * s)
        t.textPrimary.withAlphaComponent(t.isDark ? 0.45 : 0.30).setStroke()
        cg.move(to: project(model.route[0]))
        for point in model.route.dropFirst() { cg.addLine(to: project(point)) }
        cg.strokePath()

        for measure in model.measures {
            let center = project(measure.point)
            let color = t.qualityColor(ratio: measure.qualityRatio)
            color.withAlphaComponent(0.25).setFill()
            cg.fillEllipse(in: CGRect(x: center.x - 26 * s, y: center.y - 26 * s, width: 52 * s, height: 52 * s))
            t.background.setFill()
            cg.fillEllipse(in: CGRect(x: center.x - 15 * s, y: center.y - 15 * s, width: 30 * s, height: 30 * s))
            color.setFill()
            cg.fillEllipse(in: CGRect(x: center.x - 11 * s, y: center.y - 11 * s, width: 22 * s, height: 22 * s))
        }
    }

    // MARK: Chiffres

    /// Grille de deux colonnes : libellé discret, valeur en grand.
    private static func drawStats(_ model: DriveShareCardModel, s: CGFloat, top: CGFloat) {
        let t = model.theme
        let columnWidth = (model.width - 2 * padX) / 2 * s
        let label = SQShareFonts.mono(size: 20 * s, weight: 700)
        for (index, stat) in model.stats.prefix(4).enumerated() {
            let x = padX * s + CGFloat(index % 2) * columnWidth
            let y = top + CGFloat(index / 2) * 160 * s
            draw(stat.label.uppercased(), font: label, color: t.textSecondary, x: x, top: y, kernEm: 0.18)
            var valueFont = SQShareFonts.display(size: 64 * s, weight: 800)
            let available = columnWidth - 24 * s
            let width = (stat.value as NSString).size(withAttributes: [.font: valueFont]).width
            if width > available {
                valueFont = SQShareFonts.display(size: 64 * s * available / width, weight: 800)
            }
            draw(stat.value, font: valueFont, color: t.textPrimary, x: x, top: y + 34 * s)
        }
    }

    // MARK: Texte

    private static func draw(_ text: String, font: UIFont, color: UIColor, x: CGFloat, top: CGFloat, kernEm: CGFloat = 0) {
        (text as NSString).draw(at: CGPoint(x: x, y: top), withAttributes: attributes(font, color, kernEm: kernEm))
    }

    private static func drawRight(_ text: String, font: UIFont, color: UIColor, rightX: CGFloat, top: CGFloat) {
        let attrs = attributes(font, color)
        let width = (text as NSString).size(withAttributes: attrs).width
        (text as NSString).draw(at: CGPoint(x: rightX - width, y: top), withAttributes: attrs)
    }

    private static func attributes(_ font: UIFont, _ color: UIColor, kernEm: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .kern: font.pointSize * kernEm]
    }
}
