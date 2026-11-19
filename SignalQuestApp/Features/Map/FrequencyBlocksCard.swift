import SwiftUI

/// Cadre « Fréquences » de la fiche (FREQ-BLOCKS r0.5, planche validée le 18/11) : la règle du
/// spectre (échelle logarithmique, une ligne par génération, ou par opérateur sur un support
/// partagé), puis une rangée par bande avec ses bornes, puis la source.
///
/// Support partagé (forme B, validée par Alexandre le 19/11) : chaque bande, puis une ligne par
/// opérateur qui la porte, avec son nom, ses bornes et ses générations ; les opérateurs dans l'ordre
/// des lignes opérateur de la fiche, l'actif en tête ; un opérateur sans bloc en bas du cadre.
struct FrequencyBlocksCard: View {
    let blocks: FrequencyBlocks
    let operatorLabel: (String) -> String
    let operatorShortLabel: (String) -> String
    let operatorColor: (String) -> Color
    /// Opérateurs du support sans bloc servi (« Bandes non publiées »).
    let unpublished: [String]

    /// `supportOperators` : les opérateurs du support dans l'ordre de la fiche, l'actif en tête.
    init(blocks: FrequencyBlocks, supportOperators: [String] = [],
         operatorLabel: @escaping (String) -> String,
         operatorShortLabel: ((String) -> String)? = nil,
         operatorColor: @escaping (String) -> Color) {
        self.blocks = blocks.ordered(by: supportOperators)
        self.unpublished = blocks.unpublishedOperators(of: supportOperators)
        self.operatorLabel = operatorLabel
        self.operatorShortLabel = operatorShortLabel ?? operatorLabel
        self.operatorColor = operatorColor
    }

    private var rows: [FrequencyBlocks.BandRow] { blocks.bandRows }
    private var isShared: Bool { blocks.operators.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            // Tailles AX : « FRÉQUENCE / S » se coupait à côté de l'en-tête. On empile.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    kicker
                    Spacer(minLength: SQSpace.sm)
                    count.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    kicker
                    count
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                FrequencySpectrumStrip(blocks: blocks, operatorLabel: operatorLabel, operatorShortLabel: operatorShortLabel,
                                       operatorColor: operatorColor)
                    // La liste dit tout ce que la règle dessine, en mots.
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        FrequencyBandRowView(row: row, source: blocks.source, isShared: isShared,
                                             operatorLabel: operatorLabel, operatorShortLabel: operatorShortLabel,
                                             operatorColor: operatorColor)
                            .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                    }
                    ForEach(unpublished, id: \.self) { key in
                        FrequencyUnpublishedLine(operatorKey: key, source: blocks.source, operatorLabel: operatorLabel,
                                                 operatorShortLabel: operatorShortLabel, operatorColor: operatorColor)
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

    private var kicker: some View {
        Text("Fréquences").sqKicker().lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
    }

    private var count: some View {
        Text(verbatim: countLine)
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// « SFR · 6 bandes », « 3 opérateurs · 7 bandes », « Bell · 7 porteuses · 5 bandes » (Canada),
    /// comme le site : un opérateur seul est nommé, plus rien n'est à deviner.
    var countLine: String {
        let bands = String(localized: "\(rows.count) bandes")
        let carriers = blocks.carrierCount.flatMap { $0 > 0 ? String(localized: "\($0) porteuses") : nil }
        if isShared {
            let count = blocks.operators.count + unpublished.count
            return ([String(localized: "\(count) opérateurs"), bands] + [carriers].compactMap { $0 }).joined(separator: " · ")
        }
        let name = blocks.operators.first.map(\.operatorKey).flatMap { $0.uppercased() == "ALL" ? nil : operatorLabel($0) }
        return ([name, carriers].compactMap { $0 } + [bands]).joined(separator: " · ")
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
    var operatorShortLabel: ((String) -> String)? = nil
    let operatorColor: (String) -> Color

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Colonne du chiffre et des noms d'opérateur d'une rangée partagée (72 px sur la planche).
    @ScaledMetric(relativeTo: .caption) private var sharedColumn: CGFloat = 72

    var body: some View {
        if isShared { sharedBody } else { singleBody }
    }

    // MARK: Support partagé (forme B)

    private var sharedBody: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) { number; unit }
                    sharedHeading
                }
            } else {
                HStack(alignment: .center, spacing: SQSpace.sm) {
                    VStack(alignment: .leading, spacing: 3) { number; unit }
                        .frame(width: sharedColumn, alignment: .leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    sharedHeading.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(row.operators, id: \.operatorKey) { entry in
                operatorLine(entry)
            }
        }
        .padding(.vertical, SQSpace.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// « B28 · n28 · FDD », puis la plage de la bande une seule fois en plan 3GPP (la même pour tous).
    private var sharedHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(verbatim: headingLabel).foregroundColor(row.isPlanned ? SQColor.labelSecondary : SQColor.label)
                + Text(verbatim: sharedDetail).foregroundColor(SQColor.labelSecondary))
                .font(SQType.caption(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if source == .bandPlan, let first = row.operators.first {
                ForEach(Array(Self.rangeLines(first, share: false).enumerated()), id: \.offset) { _, line in
                    rangeText(line)
                }
            }
        }
    }

    private var headingLabel: String {
        row.labels.isEmpty ? row.label : row.labels.joined(separator: " · ")
    }

    /// « · FDD », « · TDD · 75 % du temps en ↓ » : la part du TDD va en tête de rangée partagée.
    private var sharedDetail: String {
        var parts: [String] = []
        if let duplex = row.duplex { parts.append(duplex) }
        if let share = row.dlSharePercent { parts.append(String(localized: "\(Self.percent(share)) du temps en ↓")) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func operatorLine(_ entry: FrequencyBlocks.OperatorRanges) -> some View {
        let name = FrequencyOperatorName(key: entry.operatorKey, operatorLabel: operatorLabel,
                                         operatorShortLabel: operatorShortLabel ?? operatorLabel,
                                         operatorColor: operatorColor)
        let lines = VStack(alignment: .leading, spacing: 1) {
            if source == .bandPlan {
                Text("bande relevée")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                ForEach(Array(Self.rangeLines(entry, share: false, unit: false).enumerated()), id: \.offset) { _, line in
                    rangeText(line)
                }
            }
        }
        let tags = HStack(spacing: 4) {
            ForEach(entry.generations, id: \.generation) { FrequencyGenerationTag(generation: $0.generation, planned: $0.planned) }
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SQSpace.xs2) { name; lines; tags }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                name.frame(width: sharedColumn, alignment: .leading)
                lines.frame(maxWidth: .infinity, alignment: .leading)
                tags
            }
        }
    }

    private func rangeText(_ line: String) -> some View {
        Text(verbatim: line)
            .font(SQType.caption)
            .monospacedDigit()
            .foregroundStyle(SQColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Un seul opérateur

    private var singleBody: some View {
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
            FrequencyGenerationTag(generation: entry.generation, planned: entry.planned)
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

    private func rangeLines(_ entry: FrequencyBlocks.OperatorRanges) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(Self.rangeLines(entry).enumerated()), id: \.offset) { _, line in
                rangeText(line)
            }
        }
    }

    /// Les lignes d'un opérateur, comme le site : une paire FDD seule sur une ligne
    /// (« ↓ 763–773 · ↑ 708–718 MHz ») ; sinon une ligne par sens, « ↓ », « ↑ », « ↓↑ » (TDD) puis
    /// la plage sans sens, sans flèche (« ↕ » se confondait avec le « ↓↑ » du TDD, choix d'Alexandre du
    /// 18/11), et la part de descente d'un TDD. Une plage ne se coupe jamais. Sur une ligne d'opérateur
    /// d'un support partagé, ni « MHz » ni part du TDD (elle est en tête de rangée), comme le site.
    static func rangeLines(_ entry: FrequencyBlocks.OperatorRanges, share: Bool = true, unit: Bool = true) -> [String] {
        let mhz = unit ? " MHz" : ""
        func nb(_ text: String) -> String {
            text.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "\u{00A0}·\u{00A0}", with: "\u{00A0}· ")
        }
        func line(_ arrow: String, _ ranges: [FrequencyBlocks.Range]) -> String {
            nb("\(arrow) " + ranges.map(FrequencyBlocksCard.span).joined(separator: " · ") + mhz)
        }
        if entry.isSinglePair, let dl = entry.dl.first, let ul = entry.ul.first {
            return [nb("↓ \(FrequencyBlocksCard.span(dl)) · ↑ \(FrequencyBlocksCard.span(ul))" + mhz)]
        }
        var lines: [String] = []
        if !entry.dl.isEmpty { lines.append(line("↓", entry.dl)) }
        if !entry.ul.isEmpty { lines.append(line("↑", entry.ul)) }
        if !entry.both.isEmpty { lines.append(line("↓↑", entry.both)) }
        if !entry.unknown.isEmpty {
            lines.append(nb(entry.unknown.map(FrequencyBlocksCard.span).joined(separator: " · ") + mhz))
        }
        if share, let share = entry.dlSharePercent {
            lines.append(String(localized: "\(percent(share)) du temps en ↓"))
        }
        return lines
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Ce que lit VoiceOver : les flèches deviennent des mots.
    private var spoken: String {
        let heading = isShared ? headingLabel.replacingOccurrences(of: " · ", with: ", ")
            + sharedDetail.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "↓", with: String(localized: "descente"))
            : row.label + detail.replacingOccurrences(of: " · ", with: ", ")
        var parts = ["\(row.bandMhz.map { FrequencyBlocksCard.mhz($0) } ?? "") MHz", heading]
        if isShared, source == .bandPlan, let first = row.operators.first {
            parts.append(Self.spokenRanges(first))
        }
        for entry in row.operators {
            var line = isShared ? operatorLabel(entry.operatorKey) + ", " : ""
            line += isShared && source == .bandPlan ? String(localized: "bande relevée") : Self.spokenRanges(entry)
            if !isShared, let share = entry.dlSharePercent {
                line += ", " + String(localized: "\(Self.percent(share)) du temps en descente")
            }
            if isShared {
                line += ", " + entry.generations.map { $0.planned ? String(localized: "\($0.generation) en projet") : $0.generation }
                    .joined(separator: ", ")
            }
            parts.append(line)
        }
        if isShared { return parts.joined(separator: ", ") }
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

/// Nom d'un opérateur dans le cadre : liseré, nom complet, ou court quand la colonne est trop étroite.
private struct FrequencyOperatorName: View {
    let key: String
    let operatorLabel: (String) -> String
    let operatorShortLabel: (String) -> String
    let operatorColor: (String) -> Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(operatorColor(key))
                .frame(width: 3, height: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            ViewThatFits(in: .horizontal) {
                name(operatorLabel(key))
                name(operatorShortLabel(key))
            }
        }
    }

    private func name(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SQType.caption(.bold))
            .foregroundStyle(SQColor.label)
            .lineLimit(1)
    }
}

/// « Bouygues Telecom · Bandes non publiées » : un opérateur du support sans bloc servi.
private struct FrequencyUnpublishedLine: View {
    let operatorKey: String
    let source: FrequencyBlocks.Source
    let operatorLabel: (String) -> String
    let operatorShortLabel: (String) -> String
    let operatorColor: (String) -> Color

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var column: CGFloat = 72

    private var text: LocalizedStringKey {
        source == .bandPlan ? "aucune bande relevée sur ce site" : "Bandes non publiées"
    }

    var body: some View {
        let name = FrequencyOperatorName(key: operatorKey, operatorLabel: operatorLabel,
                                         operatorShortLabel: operatorShortLabel, operatorColor: operatorColor)
        let note = Text(text).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs2) { name; note }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    name.frame(width: column, alignment: .leading)
                    note.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SQSpace.sm)
        .accessibilityElement(children: .combine)
    }
}

/// Pastille de génération : pleine en service, en pointillé en projet. Partagée avec le bloc Radio.
struct FrequencyGenerationTag: View {
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
    var operatorShortLabel: (String) -> String = { $0 }
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
                // « Bouygues T… » : le nom court quand le complet ne tient pas, comme les lignes.
                ViewThatFits(in: .horizontal) {
                    stripName(operatorLabel(key))
                    stripName(operatorShortLabel(key))
                }
            }
        }
    }

    private func stripName(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SQType.micro(.bold))
            .foregroundStyle(SQColor.ink2)
            .lineLimit(1)
            .truncationMode(.tail)
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
