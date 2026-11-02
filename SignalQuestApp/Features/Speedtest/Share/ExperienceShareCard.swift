import CoreGraphics
import Foundation
import UIKit

// MARK: - Modèle

/// Données de l'image de partage d'un test d'expérience (modèle « A · Fiche » validé le 27/10,
/// commun au web et à Android) : déjà formatées, le rendu ne décide de rien.
struct ExperienceShareCardModel {
    /// Un usage : son nom, sa phrase courte (`presentation-v1`, `share`), une ligne de détail facultative, sa note.
    struct Row {
        let label: String
        let phrase: String
        let detail: String?
        let score: Int?
    }

    var width: CGFloat = 1_200
    var height: CGFloat = 630

    let title: String
    /// `nil` : l'en-tête ne garde que le titre.
    let dateText: String?
    let network: SQShareCardModel.NetworkLine?
    let overallLabel: String
    let overall: Int?
    /// « Moyenne des 4 usages », ou pourquoi il n'y a pas de note globale.
    let overallNote: String
    let rows: [Row]
}

enum ExperienceShareCardBuilder {
    /// `scores` : les notes servies d'abord, celles du téléphone sinon, comme la fiche du test.
    static func model(
        tests: [String: Any],
        scores: ExperienceScores,
        measuredAt: Date?,
        network: SQShareCardModel.NetworkLine?,
        language: ExperienceShareLanguage = .current
    ) -> ExperienceShareCardModel {
        // La phrase de chaque usage est la première ligne de `presentation-v1` (60 caractères
        // au plus) ; plus de ligne « Échelle · Adaptative » : la note de la Vidéo suffit.
        let uses = ExperiencePresentation.uses(tests: tests, methodology: ExperienceMethod.methodology)
        let rows = ExperienceSharePhrases.Use.allCases.map { use in
            let presentation = ExperiencePresentation.Use(rawValue: use.rawValue).flatMap { uses[$0] }
            return ExperienceShareCardModel.Row(
                label: use.label(language),
                phrase: presentation?.share.rendered(language) ?? "",
                detail: nil,
                score: presentation?.score
            )
        }
        let rated = scores.ratedUses
        let note = if scores.overall == nil {
            language.text("Note globale à partir de 2 usages notés", "Overall score from 2 rated uses")
        } else if rated == 4 {
            language.text("Moyenne des 4 usages", "Average of all 4 uses")
        } else {
            language.text("Moyenne des \(rated) usages notés", "Average of \(rated) rated uses")
        }
        return ExperienceShareCardModel(
            title: language.text("Test d’expérience", "Experience test"),
            dateText: measuredAt.map { SQShareCardBuilder.dateText($0, locale: language.locale) },
            network: network,
            overallLabel: language.text("Note globale", "Overall score"),
            overall: scores.overall,
            overallNote: note,
            rows: rows
        )
    }

    /// « Orange · 5G » avec la barre de l'opérateur, « Wi-Fi » seul comme la carte du fil ;
    /// un opérateur hors palette n'est pas nommé : la techno seule.
    static func networkLine(
        connectionType: String, technology: String?, operatorKey: String?,
        language: ExperienceShareLanguage = .current
    ) -> SQShareCardModel.NetworkLine? {
        switch connectionType {
        case "wifi":
            return .init(name: "Wi-Fi", detail: nil, barColor: nil)
        case "cellular":
            let link = technology ?? language.text("Réseau mobile", "Mobile network")
            guard let name = SQBrand.operatorName(operatorKey) else { return .init(name: link, detail: nil, barColor: nil) }
            return .init(name: name, detail: link, barColor: UIColor(SQBrand.operatorColors(name).solid))
        default:
            return nil
        }
    }

    static func renderImage(_ model: ExperienceShareCardModel) -> UIImage {
        ExperienceShareCardRenderer.render(model)
    }
}

// MARK: - Rendu

/// Rendu Core Graphics de la maquette (1200 × 630, exportée ×2), sur les cotes, la palette et
/// les polices de l'image speedtest (`SQShareCardRenderer`).
///
/// **Rien ne se coupe** (réserve d'Alexandre, méthode §10) : une phrase passe à la ligne aux
/// espaces ordinaires, jamais aux insécables qui tiennent un nombre et son unité ; deux lignes
/// au plus, ce que `ExperienceSharePhraseTests` vérifie sur les pires cas.
enum ExperienceShareCardRenderer {
    private typealias R = SQShareCardRenderer

    private static let emptyScore = UIColor(hex: 0xC9CCC8)

    // Colonnes 0,78fr | 1 | 1,62fr, écart 40 ; rangées : texte | jauge 96 | note 84, écart 24.
    private static let leftShare: CGFloat = 0.78
    private static let rightShare: CGFloat = 1.62
    private static let meterWidth: CGFloat = 96
    private static let scoreWidth: CGFloat = 84
    private static let rowGap: CGFloat = 24

    static let phraseFont = SQShareFonts.display(size: 14, weight: 600)
    private static let phraseLineHeight: CGFloat = 14 * 1.25
    static let networkFont = SQShareFonts.display(size: 22, weight: 700)
    static let noteFont = SQShareFonts.display(size: 16, weight: 600)
    private static let noteLineHeight: CGFloat = 16 * 1.3

    /// Colonnes du cartouche pour une image de `width`.
    static func columns(width: CGFloat) -> (left: CGFloat, right: CGFloat, phrase: CGFloat) {
        let content = width - 2 * R.pagePadX - 2 * R.cardPadX
        let shared = content - 2 * R.columnGap - 1
        let left = shared * leftShare / (leftShare + rightShare)
        let right = shared * rightShare / (leftShare + rightShare)
        return (left, right, right - meterWidth - scoreWidth - 2 * rowGap)
    }

    static func render(_ model: ExperienceShareCardModel) -> UIImage {
        let s = R.exportScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: model.width * s, height: model.height * s), format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: s, y: s)
            R.paper.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: model.width, height: model.height))

            R.drawMasthead(cg, title: model.title, dateText: model.dateText, width: model.width)
            let card = R.drawCardShape(cg, width: model.width, height: model.height)
            let content = card.insetBy(dx: R.cardPadX, dy: R.cardPadY)
            let columns = columns(width: model.width)
            let ruleX = content.minX + columns.left + R.columnGap
            R.fillRule(cg, CGRect(x: ruleX, y: content.minY, width: 1, height: content.height))
            drawOverall(cg, model: model, rect: CGRect(x: content.minX, y: content.minY, width: columns.left, height: content.height))
            drawRows(cg, model.rows, rect: CGRect(x: ruleX + 1 + R.columnGap, y: content.minY, width: columns.right, height: content.height))

            let siteAttrs = R.attributes(SQShareFonts.display(size: 16, weight: 700), R.ink)
            let footerTop = model.height - R.pagePadY - R.footerHeight
            let site = "signalquest.fr"
            R.draw(site, attrs: siteAttrs, x: model.width - R.pagePadX - R.width(site, siteAttrs),
                   baseline: R.baseline(top: footerTop, height: R.footerHeight, font: siteAttrs.font))
        }
    }

    // MARK: Colonne gauche

    /// Réseau en haut ; en bas, la rubrique, la note globale (ou « — ») et sa légende.
    private static func drawOverall(_ cg: CGContext, model: ExperienceShareCardModel, rect: CGRect) {
        if let network = model.network {
            let barSpace: CGFloat = network.barColor == nil ? 0 : 4 + 10
            var runs = [Run(network.name, R.attributes(networkFont, R.ink))]
            // L'insécable garde « · » sur la ligne de l'opérateur.
            if let detail = network.detail {
                runs.append(Run("\u{00A0}· \(detail)", R.attributes(SQShareFonts.display(size: 22, weight: 600), R.ink2)))
            }
            let lines = wrap(runs, maxWidth: rect.width - barSpace)
            if let bar = network.barColor {
                bar.setFill()
                let barTop = rect.minY + (CGFloat(lines.count) * 22 - 22) / 2
                UIBezierPath(roundedRect: CGRect(x: rect.minX, y: barTop, width: 4, height: 22), cornerRadius: 2).fill()
            }
            drawLines(lines, x: rect.minX + barSpace, top: rect.minY, lineHeight: 22)
        }

        let noteAttrs = R.attributes(noteFont, R.ink2)
        let noteLines = wrap([Run(model.overallNote, noteAttrs)], maxWidth: rect.width)
        let numberSize: CGFloat = 120
        // Pile calée en bas : rubrique 12, écart 14, chiffre (marges −6 et −4), écart 14, légende.
        let stackHeight = 12 + 14 + (numberSize - 10) + 14 + CGFloat(noteLines.count) * noteLineHeight
        let kickerTop = rect.maxY - stackHeight
        R.drawKicker(model.overallLabel, arrow: nil, x: rect.minX, top: kickerTop)

        let numberFont = SQShareFonts.display(size: numberSize, weight: 800)
        let base = R.baseline(top: kickerTop + 12 + 14 - 6, height: numberSize, font: numberFont)
        if let overall = model.overall {
            let advance = R.draw("\(overall)", attrs: R.attributes(numberFont, R.ink, kernEm: -0.045), x: rect.minX, baseline: base)
            R.draw("/100", attrs: R.attributes(SQShareFonts.display(size: 28, weight: 700), R.muted), x: rect.minX + advance + 10, baseline: base)
        } else {
            R.draw("—", attrs: R.attributes(numberFont, emptyScore, kernEm: -0.045), x: rect.minX, baseline: base)
        }
        drawLines(noteLines, x: rect.minX, top: rect.maxY - CGFloat(noteLines.count) * noteLineHeight, lineHeight: noteLineHeight)
    }

    // MARK: Colonne droite

    private static func drawRows(_ cg: CGContext, _ rows: [ExperienceShareCardModel.Row], rect: CGRect) {
        guard !rows.isEmpty else { return }
        let rowHeight = rect.height / CGFloat(rows.count)
        let textWidth = rect.width - meterWidth - scoreWidth - 2 * rowGap
        let labelAttrs = R.attributes(SQShareFonts.display(size: 17, weight: 700), R.ink)
        let detailAttrs = R.attributes(SQShareFonts.display(size: 12, weight: 600), R.muted)

        for (index, row) in rows.enumerated() {
            var top = rect.minY + CGFloat(index) * rowHeight
            if index > 0 {
                R.fillRule(cg, CGRect(x: rect.minX, y: top, width: rect.width, height: 1))
                top += 1
            }
            let centerY = top + (rect.minY + CGFloat(index + 1) * rowHeight - top) / 2

            // Texte : nom 17 (interligne 1,15), écart 6, phrase 14 (1,25), écart 6, détail 12 (1,2).
            let phraseAttrs = R.attributes(phraseFont, row.score == nil ? R.muted : R.ink2)
            let phraseLines = wrap([Run(row.phrase, phraseAttrs)], maxWidth: textWidth)
            let labelHeight: CGFloat = 17 * 1.15, detailHeight: CGFloat = 12 * 1.2
            let stackHeight = labelHeight + 6 + CGFloat(phraseLines.count) * phraseLineHeight + (row.detail == nil ? 0 : 6 + detailHeight)
            var y = centerY - stackHeight / 2
            R.draw(row.label, attrs: labelAttrs, x: rect.minX, baseline: R.baseline(top: y, height: labelHeight, font: labelAttrs.font))
            y += labelHeight + 6
            drawLines(phraseLines, x: rect.minX, top: y, lineHeight: phraseLineHeight)
            y += CGFloat(phraseLines.count) * phraseLineHeight
            if let detail = row.detail {
                R.draw(detail, attrs: detailAttrs, x: rect.minX, baseline: R.baseline(top: y + 6, height: detailHeight, font: detailAttrs.font))
            }

            // Jauge 96 × 6 : la note en pourcentage de sa largeur.
            let meter = CGRect(x: rect.minX + textWidth + rowGap, y: centerY - 3, width: meterWidth, height: 6)
            R.rule.setFill()
            UIBezierPath(roundedRect: meter, cornerRadius: 3).fill()
            if let score = row.score, score > 0 {
                R.ink.setFill()
                UIBezierPath(roundedRect: CGRect(x: meter.minX, y: meter.minY, width: meterWidth * CGFloat(min(score, 100)) / 100, height: 6),
                             cornerRadius: 3).fill()
            }

            // Note calée à droite : « 81 » + « /100 » sur la même ligne de base, ou « — ».
            let right = rect.maxX
            let scoreFont = SQShareFonts.display(size: 34, weight: 800)
            let base = R.baseline(top: centerY - 17, height: 34, font: scoreFont)
            if let score = row.score {
                let numberAttrs = R.attributes(scoreFont, R.ink, kernEm: -0.03)
                let unitAttrs = R.attributes(SQShareFonts.display(size: 13, weight: 700), R.muted)
                let unitWidth = R.width("/100", unitAttrs)
                R.draw("/100", attrs: unitAttrs, x: right - unitWidth, baseline: base)
                let number = "\(score)"
                R.draw(number, attrs: numberAttrs, x: right - unitWidth - 4 - R.width(number, numberAttrs), baseline: base)
            } else {
                let attrs = R.attributes(scoreFont, emptyScore)
                R.draw("—", attrs: attrs, x: right - R.width("—", attrs), baseline: base)
            }
        }
    }

    // MARK: Passage à la ligne

    struct Run {
        let text: String
        let attrs: [NSAttributedString.Key: Any]
        init(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            self.text = text
            self.attrs = attrs
        }
    }

    /// Lignes d'une phrase de l'image, dans la largeur de sa colonne.
    static func phraseLines(_ text: String, width: CGFloat = 1_200) -> [String] {
        wrap([Run(text, R.attributes(phraseFont, R.ink2))], maxWidth: columns(width: width).phrase)
            .map { $0.map(\.text).joined() }
    }

    /// Coupe aux espaces ordinaires seulement ; un mot plus long que la ligne reste entier.
    static func wrap(_ runs: [Run], maxWidth: CGFloat) -> [[Run]] {
        var words: [[Run]] = [[]]
        for run in runs {
            for (index, part) in run.text.components(separatedBy: " ").enumerated() {
                if index > 0 { words.append([]) }
                if !part.isEmpty { words[words.count - 1].append(Run(part, run.attrs)) }
            }
        }
        var lines: [[Run]] = []
        var line: [Run] = []
        var lineWidth: CGFloat = 0
        for word in words where !word.isEmpty {
            let wordWidth = word.reduce(0) { $0 + R.width($1.text, $1.attrs) }
            let space = Run(" ", word[0].attrs)
            let spaceWidth = R.width(" ", space.attrs)
            if !line.isEmpty, lineWidth + spaceWidth + wordWidth > maxWidth {
                lines.append(line)
                line = []
                lineWidth = 0
            }
            if !line.isEmpty {
                line.append(space)
                lineWidth += spaceWidth
            }
            line += word
            lineWidth += wordWidth
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func drawLines(_ lines: [[Run]], x: CGFloat, top: CGFloat, lineHeight: CGFloat) {
        for (index, line) in lines.enumerated() {
            guard let font = line.first?.attrs[.font] as? UIFont else { continue }
            let base = R.baseline(top: top + CGFloat(index) * lineHeight, height: lineHeight, font: font)
            var cursor = x
            for run in line { cursor += R.draw(run.text, attrs: run.attrs, x: cursor, baseline: base) }
        }
    }
}

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    var font: UIFont { self[.font] as? UIFont ?? .systemFont(ofSize: 12) }
}
