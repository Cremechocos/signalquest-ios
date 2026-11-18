import SwiftUI

/// Cadre « Fréquences » de la fiche (FREQ-BLOCKS r0.5, planche validée le 18/11) : la règle du
/// spectre (échelle logarithmique, une ligne par génération, ou par opérateur sur un support
/// partagé), puis une rangée par bande avec ses bornes, puis la source.
struct FrequencyBlocksCard: View {
    let blocks: FrequencyBlocks
    let operatorLabel: (String) -> String
    let operatorColor: (String) -> Color

    private var rows: [FrequencyBlocks.BandRow] { blocks.bandRows }
    private var isShared: Bool { blocks.operators.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fréquences").sqKicker().accessibilityAddTraits(.isHeader)
                Spacer(minLength: SQSpace.sm)
                Text(verbatim: countLine)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                FrequencySpectrumStrip(blocks: blocks, operatorLabel: operatorLabel, operatorColor: operatorColor)
                    // La liste dit tout ce que la règle dessine, en mots.
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        FrequencyBandRowView(row: row, source: blocks.source, isShared: isShared,
                                             operatorLabel: operatorLabel, operatorColor: operatorColor)
                            .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                    }
                }
                Text(verbatim: Self.footer(blocks))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SQSpace.xs2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                    .accessibilityIdentifier("antenna.detail.frequencies.source")
            }
            .padding(SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antenna.detail.frequencies")
    }

    /// « 6 bandes », « 2 opérateurs · 5 bandes », « 7 porteuses · 5 bandes » (Canada), comme le site.
    private var countLine: String {
        let bands = String(localized: "\(rows.count) bandes")
        if isShared { return String(localized: "\(blocks.operators.count) opérateurs") + " · " + bands }
        if let carriers = blocks.carrierCount, carriers > 0 { return String(localized: "\(carriers) porteuses") + " · " + bands }
        return bands
    }

    /// Pied de cadre, au mot près le même sur les 3 apps (r0.5 §2).
    static func footer(_ blocks: FrequencyBlocks) -> String {
        let date = datasetDate(blocks.datasetDate)
        var text: String
        switch blocks.source {
        case .anfr:
            text = date.map { String(localized: "Bornes déclarées à l’ANFR · jeu du \($0).") }
                ?? String(localized: "Bornes déclarées à l’ANFR.")
        case .ised:
            text = date.map { String(localized: "Porteuses inscrites à ISED · \($0).") }
                ?? String(localized: "Porteuses inscrites à ISED.")
        case .bandPlan:
            text = String(localized: "Plages des bandes (norme 3GPP), d’après les bandes relevées par la communauté.")
        case .unrecognized:
            text = ""
        }
        if blocks.showsPlanned {
            text += (text.isEmpty ? "" : " ") + String(localized: "Pointillé : en projet.")
        }
        return text
    }

    /// « 2026-11-06 » → « 6 novembre 2026 », jour civil sans fuseau.
    static func datasetDate(_ raw: String?) -> String? {
        guard let raw, raw.count >= 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC") ?? .current
        calendar.timeZone = utc
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: utc))
    }

    /// « 2154,8 » en français, « 2154.8 » en anglais, jamais de séparateur de milliers.
    static func mhz(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// « 763–773 », insécable : une plage ne se coupe jamais à son tiret.
    static func span(_ range: FrequencyBlocks.Range) -> String {
        "\(mhz(range.low))\u{2060}–\u{2060}\(mhz(range.high))"
    }
}

// MARK: - Rangée d'une bande

struct FrequencyBandRowView: View {
    let row: FrequencyBlocks.BandRow
    let source: FrequencyBlocks.Source
    let isShared: Bool
    let operatorLabel: (String) -> String
    let operatorColor: (String) -> Color

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Tailles AX : la colonne des MHz tronquait « 1800 ». On empile.
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        number
                        unit
                    }
                    ranges
                    HStack(spacing: 4) { tags }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: SQSpace.sm2) {
                    VStack(alignment: .leading, spacing: 3) {
                        number
                        unit
                    }
                    .frame(width: 58, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    ranges
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) { tags }
                }
            }
        }
        .padding(.vertical, SQSpace.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var number: some View {
        Text(verbatim: row.bandMhz.map { FrequencyBlocksCard.mhz($0) } ?? "–")
            .font(SQType.metricSmall)
            .monospacedDigit()
            .foregroundStyle(row.isPlanned ? SQColor.labelSecondary : SQColor.label)
    }

    private var unit: some View {
        Text(verbatim: "MHz")
            .font(SQType.micro(.bold))
            .foregroundStyle(SQColor.labelSecondary)
    }

    private var ranges: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(verbatim: row.label).foregroundColor(row.isPlanned ? SQColor.labelSecondary : SQColor.label)
                + Text(verbatim: detail).foregroundColor(SQColor.labelSecondary))
                .font(SQType.caption(.bold))
            ForEach(row.operators, id: \.operatorKey) { entry in
                rangeLines(entry)
            }
        }
    }

    private var tags: some View {
        ForEach(row.generations, id: \.generation) { entry in
            GenerationTag(generation: entry.generation, planned: entry.planned)
        }
    }

    /// « · FDD · 10 MHz », « · FDD · 2 porteuses » (Canada), « · TDD ». Plusieurs plages hors Canada :
    /// pas de chiffre, il ne vaudrait que pour l'une d'elles.
    private var detail: String {
        var parts: [String] = []
        if let duplex = row.duplex { parts.append(duplex) }
        if let carriers = row.carriers {
            parts.append(String(localized: "\(carriers) porteuses"))
        } else if let width = row.widthMhz {
            parts.append("\(FrequencyBlocksCard.mhz(width)) MHz")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rangeLines(_ entry: FrequencyBlocks.OperatorRanges) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isShared {
                Circle().fill(operatorColor(entry.operatorKey)).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(Self.rangeLines(entry).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Les lignes d'un opérateur, comme le site : une paire FDD seule sur une ligne
    /// (« ↓ 763–773 · ↑ 708–718 MHz ») ; sinon une ligne par sens, « ↓ », « ↑ », « ↓↑ » (TDD) puis
    /// « ↕ » (sens inconnu), et la part de descente d'un TDD. Une plage ne se coupe jamais.
    static func rangeLines(_ entry: FrequencyBlocks.OperatorRanges) -> [String] {
        func nb(_ text: String) -> String {
            text.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "\u{00A0}·\u{00A0}", with: "\u{00A0}· ")
        }
        func line(_ arrow: String, _ ranges: [FrequencyBlocks.Range]) -> String {
            nb("\(arrow) " + ranges.map(FrequencyBlocksCard.span).joined(separator: " · ") + " MHz")
        }
        if entry.isSinglePair, let dl = entry.dl.first, let ul = entry.ul.first {
            return [nb("↓ \(FrequencyBlocksCard.span(dl)) · ↑ \(FrequencyBlocksCard.span(ul)) MHz")]
        }
        var lines: [String] = []
        if !entry.dl.isEmpty { lines.append(line("↓", entry.dl)) }
        if !entry.ul.isEmpty { lines.append(line("↑", entry.ul)) }
        if !entry.both.isEmpty { lines.append(line("↓↑", entry.both)) }
        if !entry.unknown.isEmpty { lines.append(line("↕\u{FE0E}", entry.unknown)) }
        if let share = entry.dlSharePercent {
            lines.append(String(localized: "\(percent(share)) du temps en ↓"))
        }
        return lines
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Ce que lit VoiceOver : les flèches deviennent des mots.
    private var spoken: String {
        var parts = ["\(row.bandMhz.map { FrequencyBlocksCard.mhz($0) } ?? "") MHz", row.label + detail.replacingOccurrences(of: " · ", with: ", ")]
        for entry in row.operators {
            var line = isShared ? operatorLabel(entry.operatorKey) + ", " : ""
            line += Self.spokenRanges(entry)
            if let share = entry.dlSharePercent {
                line += ", " + String(localized: "\(Self.percent(share)) du temps en descente")
            }
            parts.append(line)
        }
        parts.append(row.generations.map { entry in
            entry.planned ? String(localized: "\(entry.generation) en projet") : entry.generation
        }.joined(separator: ", "))
        return parts.joined(separator: ", ")
    }

    private static func spokenRanges(_ entry: FrequencyBlocks.OperatorRanges) -> String {
        func lo(_ r: FrequencyBlocks.Range) -> String { FrequencyBlocksCard.mhz(r.low) }
        func hi(_ r: FrequencyBlocks.Range) -> String { FrequencyBlocksCard.mhz(r.high) }
        var parts: [String] = []
        parts += entry.dl.map { r in String(localized: "Descente de \(lo(r)) à \(hi(r)) MHz") }
        parts += entry.ul.map { r in String(localized: "Montée de \(lo(r)) à \(hi(r)) MHz") }
        parts += entry.both.map { r in String(localized: "Descente et montée de \(lo(r)) à \(hi(r)) MHz") }
        parts += entry.unknown.map { r in String(localized: "Sens inconnu, de \(lo(r)) à \(hi(r)) MHz") }
        return parts.joined(separator: ", ")
    }
}

/// Pastille de génération : pleine en service, en pointillé en projet.
private struct GenerationTag: View {
    let generation: String
    let planned: Bool

    var body: some View {
        let color = SQNetworkColors.generationChartColor(generation)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(verbatim: generation)
            .font(SQType.micro(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(shape.fill(planned ? Color.clear : color.opacity(0.13)))
            .overlay {
                if planned {
                    shape.strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
                }
            }
    }
}

// MARK: - Règle du spectre

/// Le bloc réel de chaque opérateur à sa place dans le spectre, en échelle logarithmique.
private struct FrequencySpectrumStrip: View {
    let blocks: FrequencyBlocks
    let operatorLabel: (String) -> String
    let operatorColor: (String) -> Color

    @ScaledMetric(relativeTo: .caption2) private var trackHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var generationLabelWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var operatorLabelWidth: CGFloat = 96

    /// Colonne des étiquettes : elle suit la taille du texte (« 3G » se coupait en AX).
    private var labelWidth: CGFloat { isShared ? min(operatorLabelWidth, 150) : generationLabelWidth }
    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 16

    private var isShared: Bool { blocks.operators.count > 1 }

    var body: some View {
        let rows = blocks.stripRows
        let domain = blocks.stripDomain
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: SQSpace.xs2) {
                    label(row.kind)
                        .frame(width: labelWidth, alignment: .leading)
                    Canvas { context, size in
                        Self.draw(row.marks, domain: domain, in: &context, size: size)
                    }
                    .frame(height: trackHeight)
                }
            }
            HStack(spacing: SQSpace.xs2) {
                Color.clear.frame(width: labelWidth, height: 1)
                Canvas { context, size in
                    Self.drawAxis(domain: domain, in: &context, size: size)
                }
                .frame(height: axisHeight)
            }
        }
    }

    @ViewBuilder
    private func label(_ kind: FrequencyBlocks.StripRow.Kind) -> some View {
        switch kind {
        case .generation(let gen):
            Text(verbatim: gen)
                .font(SQType.micro(.bold))
                .foregroundStyle(SQColor.ink2)
        case .operatorKey(let key):
            HStack(spacing: 4) {
                Circle().fill(operatorColor(key)).frame(width: 8, height: 8)
                Text(verbatim: operatorLabel(key))
                    .font(SQType.micro(.bold))
                    .foregroundStyle(SQColor.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    static func x(_ mhz: Double, domain: FrequencyBlocks.Range, width: CGFloat) -> CGFloat {
        let span = log(domain.high) - log(domain.low)
        guard span > 0 else { return 0 }
        return CGFloat((log(max(mhz, domain.low)) - log(domain.low)) / span) * width
    }

    private static func draw(_ marks: [FrequencyBlocks.Mark], domain: FrequencyBlocks.Range,
                             in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(SQColor.fill))
        for mark in marks {
            let x0 = x(mark.range.low, domain: domain, width: size.width)
            let x1 = x(mark.range.high, domain: domain, width: size.width)
            let width = max(5, x1 - x0)
            let rect = CGRect(x: min(x0, size.width - width), y: 2, width: width, height: max(size.height - 4, 4))
            let color = SQNetworkColors.generationChartColor(mark.generation)
            if mark.planned {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.65, dy: 0.65), cornerRadius: 2.5),
                               with: .color(color), style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
            } else {
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
            }
        }
    }

    /// Graduations : les deux bornes, puis 1, 2 et 3 GHz quand elles ont la place.
    private static func drawAxis(domain: FrequencyBlocks.Range, in context: inout GraphicsContext, size: CGSize) {
        func name(_ mhz: Double) -> String {
            mhz < 1000 ? FrequencyBlocksCard.mhz(mhz) : "\(FrequencyBlocksCard.mhz(mhz / 1000)) GHz"
        }
        func label(_ mhz: Double) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: name(mhz)).font(SQType.micro(.regular)).foregroundColor(SQColor.labelSecondary))
        }
        /// Étendue horizontale d'une étiquette selon son ancrage.
        func extent(_ position: CGFloat, _ width: CGFloat, _ anchor: UnitPoint) -> ClosedRange<CGFloat> {
            let start = position - width * anchor.x
            return start...(start + width)
        }
        let low = label(domain.low), high = label(domain.high)
        let lowWidth = low.measure(in: size).width, highWidth = high.measure(in: size).width
        var ticks: [(CGFloat, GraphicsContext.ResolvedText, UnitPoint)] = [(0, low, .topLeading), (size.width, high, .topTrailing)]
        var taken = [extent(0, lowWidth, .topLeading), extent(size.width, highWidth, .topTrailing)]
        // Une graduation intermédiaire n'est gardée que si son étiquette ne touche aucune autre.
        for mhz in [1000.0, 2000, 3000] where mhz > domain.low && mhz < domain.high {
            let position = x(mhz, domain: domain, width: size.width)
            let text = label(mhz)
            let span = extent(position, text.measure(in: size).width + 12, .top)
            guard taken.allSatisfy({ !$0.overlaps(span) }) else { continue }
            taken.append(span)
            ticks.append((position, text, .top))
        }
        for (position, text, anchor) in ticks {
            var tick = Path()
            tick.move(to: CGPoint(x: position, y: 0))
            tick.addLine(to: CGPoint(x: position, y: 3))
            context.stroke(tick, with: .color(SQColor.labelTertiary), lineWidth: 1)
            context.draw(text, at: CGPoint(x: position, y: 4), anchor: anchor)
        }
    }
}
