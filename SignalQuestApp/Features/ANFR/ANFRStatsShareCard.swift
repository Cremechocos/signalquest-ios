import SwiftUI
import UIKit

// MARK: - Modèle

/// Image de partage des statistiques d'antennes, identique à celle du web
/// (`apps/web/components/stats/AnfrShare.tsx`, références du 05/11 dans
/// `~/Site/qa/anfr-share-reference`) : toujours en clair, parc en service seulement,
/// France ou Outre-mer. Le Canada n'a pas d'image, comme sur le web.
struct ANFRShareCardModel: Equatable {
    struct Row: Equatable {
        let name: String
        let color: UIColor
        let value: Int
        /// `nil` : aucun relevé d'une semaine avant pour comparer.
        let delta: Int?
    }

    let square: Bool
    let title: String
    let total: Int
    let totalDelta: Int?
    let dateText: String?
    let rows: [Row]

    var hasDeltas: Bool { rows.contains { $0.delta != nil } }
}

/// Bande de l'image : les quatre du web, dans son ordre.
struct ANFRShareBand: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }

    static let all: [ANFRShareBand] = [
        .init(key: "4g", label: String(localized: "4G")),
        .init(key: "n78", label: String(localized: "5G 3,5 GHz")),
        .init(key: "n28", label: String(localized: "5G 700 MHz")),
        .init(key: "n1", label: String(localized: "5G 2100")),
    ]

    /// L'outre-mer n'a pas la 5G 2100.
    static func available(in market: ANFRStatsMarket) -> [ANFRShareBand] {
        market == .drom ? all.filter { $0.key != "n1" } : all
    }
}

enum ANFRShareCardBuilder {
    /// Nom court et couleur de chaque opérateur, dans l'ordre du registre commun.
    private static let france: [(key: String, name: String, color: UInt32)] = [
        ("orange", "Orange", 0xFF7900), ("sfr", "SFR", 0xE60012),
        ("bytel", "Bouygues", 0x009DDC), ("free", "Free", 0x6B7280),
    ]
    private static let overseas: [(key: String, name: String, color: UInt32)] = [
        ("ORANGE", "Orange", 0xFF7900), ("OUTREMER_TELECOM", "Outremer Telecom", 0x8B5CF6),
        ("SRR", "SRR", 0x0EA5E9), ("DIGICEL", "Digicel", 0xB91C1C),
        ("FREE_CARAIBES", "Free Caraïbes", 0x6B7280), ("TELCO_OI", "Telco OI", 0x22C55E),
        ("ZEOP", "Zeop", 0xB7791F), ("MAORE_MOBILE", "Maore Mobile", 0x0891B2),
    ]

    static func model(stats: ANFRStats, market: ANFRStatsMarket, band: ANFRShareBand, square: Bool) -> ANFRShareCardModel? {
        guard market != .ca else { return nil }
        let operators = market == .drom ? overseas : france
        let latest = stats.latest.filter { $0.band == band.key }
        let hasWeek = hasWeekReference(stats, band: band.key)
        var value: [String: Int] = [:]
        var delta: [String: Int] = [:]
        for row in latest {
            value[row.operatorKey, default: 0] += row.operational
            delta[row.operatorKey, default: 0] += row.deltaOperational
        }
        let rows = operators.enumerated()
            .map { index, op in
                (index, ANFRShareCardModel.Row(
                    name: op.name, color: UIColor(hex: op.color), value: value[op.key] ?? 0,
                    delta: hasWeek ? delta[op.key] ?? 0 : nil
                ))
            }
            .sorted { $0.1.value != $1.1.value ? $0.1.value > $1.1.value : $0.0 < $1.0 }
            .map(\.1)
        let total = rows.reduce(0) { $0 + $1.value }
        let title = market == .drom
            ? String(localized: "Antennes \(band.label) · \(String(localized: "Outre-mer"))")
            : String(localized: "Antennes \(band.label) en France")
        let date = stats.latestDate.flatMap(ANFRDateParser.date(from:))
        return ANFRShareCardModel(
            square: square, title: title, total: total,
            totalDelta: hasWeek ? rows.reduce(0) { $0 + ($1.delta ?? 0) } : nil,
            dateText: date.map(dateText), rows: rows
        )
    }

    /// Le web compare au relevé d'une semaine avant ; sans lui, pas de delta.
    private static func hasWeekReference(_ stats: ANFRStats, band: String) -> Bool {
        guard let latest = stats.latestDate.flatMap(ANFRDateParser.date(from:)) else { return false }
        let limit = latest.addingTimeInterval(-6 * 86_400)
        return stats.series.contains { point in
            point.band == band && (ANFRDateParser.date(from: point.date).map { $0 <= limit } ?? false)
        }
    }

    /// jj/mm/aaaa dans l'ordre de la langue (05/11/2026, 11/05/2026 en anglais).
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        formatter.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return formatter.string(from: date)
    }

    /// signalquest-antennes-<bande>[-outre-mer]-<date ou anfr>[-carre].png
    static func fileName(market: ANFRStatsMarket, band: ANFRShareBand, latestDate: String?, square: Bool) -> String {
        var parts = ["signalquest-antennes", band.key]
        if market == .drom { parts.append("outre-mer") }
        parts.append(latestDate.flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil } ?? "anfr")
        if square { parts.append("carre") }
        return parts.joined(separator: "-") + ".png"
    }
}

// MARK: - Rendu

/// Rendu Core Graphics, en points CSS du web puis exporté ×2.
enum ANFRShareCardRenderer {
    private static let page = UIColor(hex: 0xF4F2EC)
    private static let card = UIColor(hex: 0xFFFFFF)
    private static let pill = UIColor(hex: 0xECEAE1)
    private static let ink = UIColor(hex: 0x1C201E)
    private static let ink2 = UIColor(hex: 0x3C443F)
    private static let muted = UIColor(hex: 0x6C746F)
    private static let brand = UIColor(hex: 0xA8123A)
    private static let success = UIColor(hex: 0x187B38)
    private static let successFill = UIColor(red: 24 / 255, green: 123 / 255, blue: 56 / 255, alpha: 0.12)
    private static let danger = UIColor(hex: 0xC5363B)
    private static let dangerFill = UIColor(red: 197 / 255, green: 54 / 255, blue: 59 / 255, alpha: 0.10)

    private static func font(_ size: CGFloat, _ weight: CGFloat) -> UIFont { SQShareFonts.display(size: size, weight: weight) }

    static func size(square: Bool) -> CGSize { square ? CGSize(width: 1_080, height: 1_080) : CGSize(width: 1_200, height: 630) }

    static func render(_ model: ANFRShareCardModel) -> UIImage {
        let size = size(square: model.square)
        let scale: CGFloat = 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale), format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            let left: CGRect
            let right: CGRect
            if model.square {
                // Rangées `1fr 1fr` : moitié chacune, sauf si les opérateurs débordent (Outre-mer), le haut prend alors le reste.
                let rightHeight = max(size.height / 2, rightContentHeight(model, width: size.width - 132) + 100)
                left = CGRect(x: 0, y: 0, width: size.width, height: size.height - rightHeight)
                right = CGRect(x: 0, y: size.height - rightHeight, width: size.width, height: rightHeight)
            } else {
                let leftWidth = size.width * 1.1 / 2.1
                left = CGRect(x: 0, y: 0, width: leftWidth, height: size.height)
                right = CGRect(x: leftWidth, y: 0, width: size.width - leftWidth, height: size.height)
            }
            page.setFill()
            cg.fill(left)
            card.setFill()
            cg.fill(right)
            drawLeft(cg, model, left.insetBy(dx: 66, dy: model.square ? 60 : 33))
            drawRight(cg, model, right.insetBy(dx: 66, dy: model.square ? 50 : 33))
        }
    }

    // MARK: Gauche : mot-symbole, chiffre, date

    private static func drawLeft(_ cg: CGContext, _ model: ANFRShareCardModel, _ rect: CGRect) {
        let titleKicker = attrs(font(18, 700), muted, kernEm: 0.16)
        let dateKicker = attrs(font(18, 700), muted, kernEm: 0.08)
        let number = attrs(font(112, 800), ink)
        let line = attrs(font(21, 400), ink2)

        // Trois blocs répartis comme `justify-content: space-between`.
        let wordmarkHeight: CGFloat = 27
        let kickerHeight: CGFloat = 18 * 1.5
        let lineHeight: CGFloat = 21 * 1.5
        let blockHeight = kickerHeight + 10 + 112 + 10 + lineHeight
        let gap = (rect.height - wordmarkHeight - blockHeight - kickerHeight) / 2

        drawWordmark(x: rect.minX, top: rect.minY, height: wordmarkHeight)

        var top = rect.minY + wordmarkHeight + gap
        draw(model.title.uppercased(), titleKicker, x: rect.minX, top: top, height: kickerHeight)
        top += kickerHeight + 10
        // Le web pose −0,04 em sur le chiffre, mais seul le séparateur des milliers en garde la trace
        // dans ses PNG : les chiffres gardent leur chasse.
        let separator = attrs(font(112, 800), ink, kernEm: -0.04)
        var numberX = rect.minX
        for character in group(model.total) {
            numberX += draw(String(character), character.isNumber ? number : separator, x: numberX, top: top, height: 112)
        }
        top += 112 + 10
        var x = rect.minX
        x += draw(String(localized: "supports en service"), line, x: x, top: top, height: lineHeight)
        if let delta = model.totalDelta, delta != 0 {
            x += draw(" · ", line, x: x, top: top, height: lineHeight)
            x += draw(signed(delta), attrs(font(21, 700), delta > 0 ? success : ink2), x: x, top: top, height: lineHeight)
            draw(" " + String(localized: "anfr.share.overWeek", defaultValue: "en une semaine"), line, x: x, top: top, height: lineHeight)
        }

        let date = model.dateText.map { String(localized: "Données ANFR du \($0)") } ?? String(localized: "Données ANFR")
        draw(date.uppercased(), dateKicker, x: rect.minX, top: rect.maxY - kickerHeight, height: kickerHeight)
    }

    /// « signal » ◆ « quest » : losange de la marque tourné de 45°, à 0,18 em de chaque mot.
    private static func drawWordmark(x: CGFloat, top: CGFloat, height: CGFloat) {
        let size: CGFloat = 27
        let wordAttrs = attrs(font(size, 800), ink, kernEm: -0.03)
        var cursor = x + draw("signal", wordAttrs, x: x, top: top, height: height)
        let side: CGFloat = 8.5
        let gap = size * 0.18
        let center = CGPoint(x: cursor + gap + side * sqrt(2) / 2, y: top + height / 2)
        let diamond = UIBezierPath()
        let half = side * sqrt(2) / 2
        diamond.move(to: CGPoint(x: center.x, y: center.y - half))
        diamond.addLine(to: CGPoint(x: center.x + half, y: center.y))
        diamond.addLine(to: CGPoint(x: center.x, y: center.y + half))
        diamond.addLine(to: CGPoint(x: center.x - half, y: center.y))
        diamond.close()
        brand.setFill()
        diamond.fill()
        cursor = center.x + half + gap
        draw("quest", wordAttrs, x: cursor, top: top, height: height)
    }

    // MARK: Droite : opérateurs

    /// Hauteur du kicker, des lignes (noms repliés compris) et du pied de page.
    private static func rightContentHeight(_ model: ANFRShareCardModel, width: CGFloat) -> CGFloat {
        let name = attrs(font(19, 800), ink)
        let rowLine: CGFloat = 19 * 1.5
        let nameWidth = (model.hasDeltas ? 0.24 : 0.30) * width
        let rowHeights = model.rows.map { max(CGFloat(wrap($0.name, name, maxWidth: nameWidth).count) * rowLine, rowLine) }
        let rowsHeight: CGFloat = rowHeights.reduce(0, +) + CGFloat(max(model.rows.count - 1, 0)) * 22
        return 14 * 1.5 + 22 + rowsHeight + 22 + 8 + 16 * 1.5
    }

    private static func drawRight(_ cg: CGContext, _ model: ANFRShareCardModel, _ rect: CGRect) {
        let kicker = attrs(font(14, 700), muted, kernEm: 0.16)
        let name = attrs(font(19, 800), ink)
        let rowLine: CGFloat = 19 * 1.5
        let width = rect.width
        let gap = width * 0.03
        // Grille du web : 24 % / 1fr / 19 % / 17 % avec les deltas, 30 % / 1fr / 22 % sans, écart 3 %.
        let shares: [CGFloat] = model.hasDeltas ? [0.24, 0.31, 0.19, 0.17] : [0.30, 0.42, 0.22]
        let columns: [CGFloat] = shares.map { (share: CGFloat) -> CGFloat in share * width }

        let names = model.rows.map { wrap($0.name, name, maxWidth: columns[0]) }
        let rowHeights = names.map { max(CGFloat($0.count) * rowLine, rowLine) }
        let kickerHeight: CGFloat = 14 * 1.5
        let content = rightContentHeight(model, width: width)
        var top = rect.minY + (rect.height - content) / 2

        let kickerText = model.hasDeltas ? String(localized: "Par opérateur · sur une semaine") : String(localized: "anfr.share.byOperator", defaultValue: "Par opérateur")
        draw(kickerText.uppercased(), kicker, x: rect.minX, top: top, height: kickerHeight)
        top += kickerHeight + 22

        let maxValue = max(model.rows.map(\.value).max() ?? 0, 1)
        for (index, row) in model.rows.enumerated() {
            let height = rowHeights[index]
            let centerY = top + height / 2
            for (line, text) in names[index].enumerated() {
                draw(text, name, x: rect.minX, top: top + CGFloat(line) * rowLine, height: rowLine)
            }
            var x = rect.minX + columns[0] + gap
            let barWidth = max(0.02, CGFloat(row.value) / CGFloat(maxValue)) * columns[1]
            row.color.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: centerY - 9, width: barWidth, height: 18), cornerRadius: 9).fill()
            x += columns[1] + gap
            let value = group(row.value)
            draw(value, name, x: x + columns[2] - textWidth(value, name), top: centerY - rowLine / 2, height: rowLine)
            if model.hasDeltas {
                x += columns[2] + gap
                drawPill(row.delta ?? 0, right: x + columns[3], centerY: centerY)
            }
            top += height + 22
        }
        draw("signalquest.fr/stats", attrs(font(16, 400), muted), x: rect.minX, top: top + 8, height: 16 * 1.5)
    }

    private static func drawPill(_ delta: Int, right: CGFloat, centerY: CGFloat) {
        let text = delta == 0 ? String(localized: "anfr.share.stable", defaultValue: "stable") : signed(delta)
        let color = delta > 0 ? success : delta < 0 ? danger : muted
        let fill = delta > 0 ? successFill : delta < 0 ? dangerFill : pill
        let textAttrs = attrs(font(15, 800), color)
        let height = 15 * 1.5 + 6
        let width = textWidth(text, textAttrs) + 22
        let rect = CGRect(x: right - width, y: centerY - height / 2, width: width, height: height)
        fill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()
        draw(text, textAttrs, x: rect.minX + 11, top: rect.minY + 3, height: 15 * 1.5)
    }

    // MARK: Texte

    private static func attrs(_ font: UIFont, _ color: UIColor, kernEm: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        SQShareCardRenderer.attributes(font, color, kernEm: kernEm)
    }

    private static func textWidth(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        SQShareCardRenderer.width(text, attrs)
    }

    /// Texte centré dans une boîte d'interligne `height` ; renvoie l'avance.
    @discardableResult
    private static func draw(_ text: String, _ attrs: [NSAttributedString.Key: Any], x: CGFloat, top: CGFloat, height: CGFloat) -> CGFloat {
        guard let font = attrs[.font] as? UIFont else { return 0 }
        return SQShareCardRenderer.draw(text, attrs: attrs, x: x, baseline: SQShareCardRenderer.baseline(top: top, height: height, font: font))
    }

    /// Passage à la ligne aux espaces, comme la grille du web pour un nom long.
    private static func wrap(_ text: String, _ attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || textWidth(candidate, attrs) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func group(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale.current))
    }

    /// « +1 234 » ou « −1 234 », avec le vrai signe moins.
    private static func signed(_ value: Int) -> String {
        (value > 0 ? "+" : "\u{2212}") + group(abs(value))
    }
}

// MARK: - Feuille

/// Aperçu fidèle du PNG, avec le format et la bande, comme la boîte « Partager » du web.
struct ANFRStatsShareSheet: View {
    let stats: ANFRStats
    let market: ANFRStatsMarket
    let initialBandKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var square = false
    @State private var band: ANFRShareBand = ANFRShareBand.all[1]
    @State private var rendered: (key: String, image: UIImage)?
    @State private var shareURL: URL?
    @State private var shareError = false

    private var renderKey: String { "\(band.key)|\(square)" }
    private var currentImage: UIImage? { rendered?.key == renderKey ? rendered?.image : nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    MessageSheetHeader(title: "Partager l’image", closeIdentifier: "anfr.share.close") { dismiss() }
                    preview
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Format")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                        MapSegmented(
                            selection: $square,
                            options: [(false, String(localized: "Paysage")), (true, String(localized: "Carré"))],
                            identifier: "anfr.share.format"
                        )
                    }
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Technologie")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                        FlexibleChips(ANFRShareBand.available(in: market)) { option in
                            SQChip(
                                label: option.label, isSelected: band == option,
                                selectedFill: SQColor.label, selectedInk: SQColor.onInk
                            ) {
                                guard band != option else { return }
                                Haptics.selection()
                                band = option
                            }
                        }
                    }
                    Text("L’image montre les sites en service, même si la page compte aussi les projets.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
                .sqReadableWidth()
            }
            Divider()
            VStack(spacing: SQSpace.xs) {
                GradientButton("Partager", systemImage: "square.and.arrow.up", style: .primary, action: share)
                    .disabled(currentImage == nil)
                    .accessibilityIdentifier("anfr.share.send")
                if shareError {
                    Text("Impossible de préparer le partage.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.danger)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.md)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            band = ANFRShareBand.available(in: market).first { $0.key == initialBandKey } ?? ANFRShareBand.all[1]
        }
        .task(id: renderKey) { render() }
        .sheet(item: Binding(get: { shareURL.map(ShareFile.init) }, set: { if $0 == nil { removeFile() } })) { file in
            ShareSheet(items: [file.url]) { Task { @MainActor in removeFile() } }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .fill(SQColor.surfaceMuted)
            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Aperçu de l’image à partager")
            } else {
                SQSpinner().tint(SQColor.brandRed)
            }
        }
        .aspectRatio(square ? 1 : 1_200.0 / 630.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        // La moitié crème de l'image a la teinte de la feuille : le liseré en montre les bords.
        .overlay(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous).strokeBorder(SQColor.separator, lineWidth: 1))
        .accessibilityIdentifier("anfr.share.preview")
    }

    @MainActor
    private func render() {
        let key = renderKey
        guard let model = ANFRShareCardBuilder.model(stats: stats, market: market, band: band, square: square) else { return }
        rendered = (key, ANFRShareCardRenderer.render(model))
    }

    @MainActor
    private func share() {
        guard let image = currentImage, let data = image.pngData() else { return }
        shareError = false
        removeFile()
        let name = ANFRShareCardBuilder.fileName(market: market, band: band, latestDate: stats.latestDate, square: square)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            shareError = true
        }
    }

    @MainActor
    private func removeFile() {
        guard let url = shareURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        shareURL = nil
    }

    private struct ShareFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
}
