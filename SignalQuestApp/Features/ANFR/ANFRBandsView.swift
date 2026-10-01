import Charts
import SwiftUI

// MARK: - ViewModel

/// Progression ANFR par génération et par fréquence (`view=bands`, contrat v1) :
/// la 2G et la 3G pour leur extinction, la 4G et la 5G bande par bande, avec
/// l'opérateur en filtre. Composition partagée avec le web et Android.
@MainActor
final class ANFRBandsViewModel: ObservableObject {
    static let generations = ["2g", "3g", "4g", "5g"]
    /// `all` : supports distincts tous opérateurs, jamais la somme des quatre.
    static let operators: [(key: String, label: String)] = [("all", "Tous")]
        + ANFROperator.allCases.map { ($0.apiKey, $0.label) }
    /// Un an et une semaine : l'écart sur 52 semaines se lit sur la courbe.
    static let weeks = 53

    @Published private(set) var operatorKey = "all"
    @Published private(set) var generation = "5g"
    /// Toutes les bandes, une semaine : le résumé couvre tout l'historique.
    @Published private(set) var overview: ANFRBandStats?
    /// La génération choisie sur 53 semaines.
    @Published private(set) var detail: ANFRBandStats?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: ANFRServicing
    private var cache: [String: ANFRBandStats] = [:]

    init(service: ANFRServicing) { self.service = service }

    func load() async {
        guard overview == nil || detail == nil else { return }
        await reload()
    }

    func refresh() async {
        cache.removeAll()
        await reload()
    }

    func select(operatorKey: String) async {
        guard operatorKey != self.operatorKey else { return }
        self.operatorKey = operatorKey
        await reload()
    }

    func select(generation: String) async {
        guard generation != self.generation else { return }
        self.generation = generation
        await reload()
    }

    /// Une réponse arrivée après un autre choix est ignorée.
    private func reload() async {
        let operatorKey = operatorKey, generation = generation
        isLoading = true
        defer { isLoading = false }
        do {
            async let overview = stats(weeks: 1, generation: nil, operatorKey: operatorKey)
            async let detail = stats(weeks: Self.weeks, generation: generation, operatorKey: operatorKey)
            let (loadedOverview, loadedDetail) = try await (overview, detail)
            guard operatorKey == self.operatorKey, generation == self.generation else { return }
            self.overview = loadedOverview
            self.detail = loadedDetail
            errorMessage = nil
        } catch {
            guard !error.isCancellation, operatorKey == self.operatorKey, generation == self.generation else { return }
            errorMessage = error.userFacingMessage
        }
    }

    private func stats(weeks: Int, generation: String?, operatorKey: String) async throws -> ANFRBandStats {
        let key = "\(weeks):\(generation ?? "*"):\(operatorKey)"
        if let cached = cache[key] { return cached }
        #if DEBUG
        if AppEnvironment.usesDemoData {
            return ANFRDemoData.bandStats(generation: generation, operatorKey: operatorKey, weeks: weeks)
        }
        #endif
        let loaded = try await service.bandStats(weeks: weeks, generation: generation, operatorKey: operatorKey)
        cache[key] = loaded
        return loaded
    }

    // MARK: Dérivations

    struct GenerationRow: Identifiable, Equatable {
        let key: String
        let generation: String
        let summary: ANFRBandStats.Summary
        var id: String { key }
    }

    struct BandRow: Identifiable, Equatable {
        let band: ANFRBandStats.Band
        let summary: ANFRBandStats.Summary
        let series: [ANFRBandStats.Point]
        var id: String { band.key }
    }

    /// Les quatre générations de l'opérateur choisi, de la 2G à la 5G.
    var generationRows: [GenerationRow] {
        guard let overview else { return [] }
        return overview.generations.compactMap { band in
            overview.summary(operatorKey: operatorKey, band: band.key).map {
                GenerationRow(key: band.key, generation: band.generation, summary: $0)
            }
        }
    }

    var selectedGeneration: ANFRBandStats.Band? {
        detail?.generations.first { $0.key == generation }
    }

    var selectedSummary: ANFRBandStats.Summary? {
        detail?.summary(operatorKey: operatorKey, band: generation)
    }

    var selectedSeries: [ANFRBandStats.Point] {
        detail?.series(operatorKey: operatorKey, band: generation) ?? []
    }

    /// Les bandes de la génération, de la plus basse fréquence à la plus haute ;
    /// une bande que l'opérateur n'a jamais exploitée n'a pas de ligne.
    var bandRows: [BandRow] {
        guard let detail, let selectedGeneration else { return [] }
        return detail.bands(of: selectedGeneration.generation).compactMap { band in
            guard let summary = detail.summary(operatorKey: operatorKey, band: band.key),
                  summary.peak.operational > 0 else { return nil }
            return BandRow(band: band, summary: summary, series: detail.series(operatorKey: operatorKey, band: band.key))
        }
    }

    var latestDateLabel: String? {
        (detail ?? overview).flatMap { ANFRDateParser.date(from: $0.meta.latestDate) }
            .map { $0.formatted(.dateTime.day().month(.wide).year()) }
    }

    var isPartial: Bool { overview?.meta.partial == true || detail?.meta.partial == true }
}

// MARK: - Formats

/// Textes chiffrés de l'écran, dans la langue et les conventions de l'app.
enum ANFRBandsFormat {
    /// En dessous, une génération ou une bande est dite « au plus haut ».
    static let peakPermille = 995

    static func sites(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    /// « +5 066 », « −3 640 », « 0 ».
    static func signed(_ delta: Int) -> String {
        delta == 0 ? 0.formatted() : delta.formatted(.number.sign(strategy: .always()))
    }

    /// 867 ‰ → « 86,7 % » (« 86.7% » en anglais).
    static func share(permille: Int) -> String {
        (Double(permille) / 1_000).formatted(.percent.precision(.fractionLength(1)))
    }

    static func monthYear(_ isoDate: String) -> String {
        ANFRDateParser.date(from: isoDate).map { $0.formatted(.dateTime.month(.wide).year()) } ?? isoDate
    }

    static func yearChange(_ summary: ANFRBandStats.Summary) -> String? {
        summary.delta52w.map { String(localized: "\(signed($0.operational)) en un an") }
    }

    /// Sites autorisés pas encore en service, pour la 4G et la 5G, comme le
    /// tableau du web.
    static func projects(_ summary: ANFRBandStats.Summary, generation: String) -> String? {
        guard ["4G", "5G"].contains(generation.uppercased()), summary.latest.projected > 0 else { return nil }
        return String(localized: "\(sites(summary.latest.projected)) en projet")
    }

    /// « au plus haut », ou « 86,7 % de son pic (janvier 2024) ».
    static func peak(_ summary: ANFRBandStats.Summary) -> String? {
        guard let permille = summary.shareOfPeakPermille else { return nil }
        if permille >= peakPermille { return String(localized: "au plus haut") }
        return String(localized: "\(share(permille: permille)) de son pic (\(monthYear(summary.peak.date)))")
    }
}

// MARK: - View

struct ANFRBandsView: View {
    @StateObject private var model: ANFRBandsViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(service: ANFRServicing) {
        _model = StateObject(wrappedValue: ANFRBandsViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                Text("Supports en service relevés chaque semaine par l’ANFR : la 2G et la 3G s’éteignent, la 4G et la 5G progressent bande par bande.")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                operatorChips
                if !model.generationRows.isEmpty {
                    generationsCard
                    detailCard
                    footnote
                } else if let error = model.errorMessage {
                    ErrorStateView(title: "Statistiques indisponibles", message: error) {
                        Task { await model.refresh() }
                    }
                } else {
                    loadingState
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
            .sqReadableWidth()
        }
        .navigationTitle("Générations et bandes")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    // MARK: Opérateur

    private var operatorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFRBandsViewModel.operators, id: \.key) { item in
                    SQChip(label: item.label, isSelected: model.operatorKey == item.key) {
                        Task { await model.select(operatorKey: item.key) }
                    }
                    .accessibilityIdentifier("anfr.bands.operator.\(item.key)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Générations

    private var generationsCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionHeader("Par génération", systemImage: "square.stack.3d.up.fill")
            VStack(spacing: SQSpace.sm) {
                ForEach(model.generationRows) { row in
                    generationRow(row)
                }
            }
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    private func generationRow(_ row: ANFRBandsViewModel.GenerationRow) -> some View {
        let selected = row.key == model.generation
        let trend = [ANFRBandsFormat.yearChange(row.summary), ANFRBandsFormat.peak(row.summary)].compactMap { $0 }
        let count = HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
            SQEditorialTag(text: row.generation, color: SQNetworkColors.generationChartColor(row.generation))
            VStack(alignment: .leading, spacing: 2) {
                Text(ANFRBandsFormat.sites(row.summary.latest.operational))
                    .font(SQFont.display(17, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                // Moins de 13 pt sur une tuile : à l'encre, comme au lot 4f
                // (le gris secondaire n'y tient pas le contraste une fois rendu).
                Text("sites en service")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
            }
        }
        let large = dynamicTypeSize.isAccessibilitySize
        let lines = VStack(alignment: large ? .leading : .trailing, spacing: 2) {
            ForEach(trend, id: \.self) { line in
                Text(line)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(large ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        return Button {
            Task { await model.select(generation: row.key) }
        } label: {
            Group {
                if large {
                    VStack(alignment: .leading, spacing: SQSpace.xs) { count; lines }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) { count; Spacer(minLength: SQSpace.sm); lines }
                }
            }
            .padding(.vertical, SQSpace.sm)
            .padding(.horizontal, SQSpace.md)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? SQColor.accentSoft : SQColor.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.98))
        .accessibilityLabel(([row.generation, String(localized: "\(ANFRBandsFormat.sites(row.summary.latest.operational)) sites en service")] + trend)
            .joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("anfr.bands.generation.\(row.key)")
    }

    // MARK: Détail d'une génération

    @ViewBuilder
    private var detailCard: some View {
        if let generation = model.selectedGeneration, let summary = model.selectedSummary {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                sectionHeader(String(localized: "\(generation.generation) par bande"), systemImage: "waveform")
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(ANFRBandsFormat.sites(summary.latest.operational))
                        .font(SQFont.display(32, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text("sites en service")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("anfr.bands.detail.unit")
                }
                if let projects = ANFRBandsFormat.projects(summary, generation: generation.generation) {
                    Text(projects)
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("anfr.bands.detail.projects")
                }
                changes(summary)
                ANFRBandsTrendChart(
                    points: model.selectedSeries,
                    color: SQNetworkColors.generationChartColor(generation.generation),
                    title: generation.localizedLabel()
                )
                .frame(height: 150)
                VStack(spacing: SQSpace.sm) {
                    ForEach(model.bandRows) { row in
                        bandRow(row, generation: generation.generation)
                    }
                }
            }
            .padding(SQSpace.lg)
            .sqCardBackground()
        } else if let error = model.errorMessage {
            ErrorStateView(title: "Statistiques indisponibles", message: error) {
                Task { await model.refresh() }
            }
        } else {
            loadingState
        }
    }

    /// Écarts sur 1, 4 et 52 semaines, chacun à sa référence.
    private func changes(_ summary: ANFRBandStats.Summary) -> some View {
        let items: [(String, ANFRBandStats.Summary.Change?)] = [
            (String(localized: "en une semaine"), summary.delta1w),
            (String(localized: "en 4 semaines"), summary.delta4w),
            (String(localized: "en un an"), summary.delta52w),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.sm) { changeChips(items) }
            VStack(alignment: .leading, spacing: SQSpace.xs) { changeChips(items) }
        }
    }

    @ViewBuilder
    private func changeChips(_ items: [(String, ANFRBandStats.Summary.Change?)]) -> some View {
        ForEach(items.filter { $0.1 != nil }, id: \.0) { item in
            if let change = item.1 {
                // Deux textes déjà traduits, dans le même ordre en anglais.
                Text(verbatim: "\(ANFRBandsFormat.signed(change.operational)) \(item.0)")
                    .font(SQFont.body(12.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            }
        }
    }

    private func bandRow(_ row: ANFRBandsViewModel.BandRow, generation: String) -> some View {
        let color = SQNetworkColors.bandColor(row.band.key, generation: generation)
        let trend = [ANFRBandsFormat.yearChange(row.summary), ANFRBandsFormat.peak(row.summary),
                     ANFRBandsFormat.projects(row.summary, generation: generation)].compactMap { $0 }
        let text = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(row.band.localizedLabel())
                    .font(SQFont.body(14.5, .semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "\(ANFRBandsFormat.sites(row.summary.latest.operational)) sites en service"))
                .font(SQType.caption)
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
            ForEach(trend, id: \.self) { line in
                Text(line)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let spark = ANFRBandsSparkline(points: row.series, color: color)
            .frame(width: 84, height: 32)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.sm) { text; spark }
            } else {
                HStack(alignment: .center, spacing: SQSpace.md) { text; Spacer(minLength: 0); spark }
            }
        }
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([row.band.localizedLabel(),
                              String(localized: "\(ANFRBandsFormat.sites(row.summary.latest.operational)) sites en service")] + trend)
            .joined(separator: ", "))
        .accessibilityIdentifier("anfr.bands.band.\(row.band.key)")
    }

    // MARK: Pied

    private var footnote: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            if let date = model.latestDateLabel {
                Text("Source : observatoire de l’ANFR, relevé du \(date).")
            }
            Text("« Tous » compte chaque support une fois, même partagé entre opérateurs.")
            if model.isPartial {
                Text("Rattrapage en cours côté serveur : ces chiffres peuvent encore bouger.")
            }
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 32, height: 32)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
                .accessibilityIdentifier("anfr.bands.section.title")
        }
    }

    private var loadingState: some View {
        VStack(spacing: SQSpace.lg) {
            ProgressView()
                .tint(SQColor.brandRed)
            Text("Chargement des générations et des bandes…")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SQSpace.huge)
    }
}

// MARK: - Graphiques

/// Courbe d'une génération (tous supports de l'opérateur choisi), sur 53 semaines.
private struct ANFRBandsTrendChart: View {
    let points: [ANFRBandStats.Point]
    let color: Color
    let title: String

    private struct Dated: Identifiable {
        let date: Date
        let value: Int
        var id: Date { date }
    }

    private var dated: [Dated] {
        points.compactMap { point in ANFRDateParser.date(from: point.date).map { Dated(date: $0, value: point.operational) } }
    }

    var body: some View {
        Chart(dated) { point in
            AreaMark(x: .value("Date", point.date), y: .value("Supports", point.value))
                .foregroundStyle(color.opacity(0.12))
            LineMark(x: .value("Date", point.date), y: .value("Supports", point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        // Un décompte se lit depuis zéro ; l'ampleur d'un an tient dans les
        // écarts affichés au-dessus.
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.5))
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(count.formatted(.number.notation(.compactName)))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.4))
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let first = dated.first, let last = dated.last else {
            return String(localized: "\(title) : aucune donnée sur la période.")
        }
        return String(localized: "\(title) : de \(ANFRBandsFormat.sites(first.value)) à \(ANFRBandsFormat.sites(last.value)) sites en service sur la période.")
    }
}

/// Tendance d'une bande sur 53 semaines, à sa propre échelle : seule la forme
/// compte, les chiffres sont à côté.
private struct ANFRBandsSparkline: View {
    let points: [ANFRBandStats.Point]
    let color: Color

    private struct Week: Identifiable {
        let id: Int
        let value: Int
    }

    var body: some View {
        let weeks = points.enumerated().map { Week(id: $0.offset, value: $0.element.operational) }
        let low = weeks.map(\.value).min() ?? 0, high = max(weeks.map(\.value).max() ?? 1, low + 1)
        Chart(weeks) { week in
            LineMark(x: .value("Semaine", week.id), y: .value("Supports", week.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: low...high)
        .accessibilityHidden(true)
    }
}
