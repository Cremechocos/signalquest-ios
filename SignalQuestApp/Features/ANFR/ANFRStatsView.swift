import SwiftUI
import Charts

// MARK: - Filter Enum

enum ANFRFilterType: String, CaseIterable, Identifiable {
    case g4 = "4G"
    case g5_3500 = "5G 3,5 GHz"
    case g5_2100 = "5G 2,1 GHz"
    case g5_700 = "5G 700 MHz"
    
    var id: String { rawValue }
    
    var bands: Set<String> {
        switch self {
        case .g4: return ["4g"]
        case .g5_3500: return ["n78"]
        case .g5_2100: return ["n1"]
        case .g5_700: return ["n28"]
        }
    }
    
    var label: String { rawValue }
}

// MARK: - ViewModel

@MainActor
final class ANFRStatsViewModel: ObservableObject {
    @Published var stats: ANFRStats?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Opérateur sélectionné pour le graphe d'évolution.
    @Published var selectedOperator: ANFROperator = .orange
    /// Bascule opérationnel ↔ total (incluant le projeté).
    @Published var showProjected = false
    /// Filtre sélectionné (par défaut 4G).
    @Published var selectedFilter: ANFRFilterType = .g4

    private let service: ANFRServicing
    init(service: ANFRServicing) { self.service = service }

    func load() async {
        if AppEnvironment.usesDemoData {
            stats = ANFRDemoData.stats
            errorMessage = nil
            return
        }
        guard stats == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            stats = try await service.stats()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func refresh() async {
        if AppEnvironment.usesDemoData {
            stats = ANFRDemoData.stats
            return
        }
        do {
            stats = try await service.stats()
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Dérivations (rollups depuis national.latest)

    /// Total national de supports opérationnels (somme bande 4G globale + 5G n78).
    /// On somme les bandes « porteuses » par opérateur pour un total de sites.
    var totalOperational: Int {
        latestForMetric.reduce(0) { $0 + $1.value }
    }

    var totalDelta: Int {
        guard let stats else { return 0 }
        return stats.latest
            .filter { headlineBands.contains($0.band) }
            .reduce(0) { $0 + (showProjected ? $1.deltaTotal : $1.deltaOperational) }
    }

    /// Bandes retenues pour le total « supports » (4G globale + chaque bande 5G).
    private var headlineBands: Set<String> {
        selectedFilter.bands
    }

    /// Valeur agrégée par opérateur sur les bandes phares.
    private var latestForMetric: [(operator: ANFROperator, value: Int)] {
        guard let stats else { return [] }
        var byOp: [ANFROperator: Int] = [:]
        for row in stats.latest where headlineBands.contains(row.band) {
            guard let op = ANFROperator.from(raw: row.operatorKey) else { continue }
            byOp[op, default: 0] += showProjected ? row.total : row.operational
        }
        return ANFROperator.allCases.compactMap { op in
            byOp[op].map { (op, $0) }
        }
    }

    /// Répartition par opérateur (pour barres / pastilles).
    var operatorBreakdown: [(operator: ANFROperator, value: Int, delta: Int)] {
        guard let stats else { return [] }
        var value: [ANFROperator: Int] = [:]
        var delta: [ANFROperator: Int] = [:]
        for row in stats.latest where headlineBands.contains(row.band) {
            guard let op = ANFROperator.from(raw: row.operatorKey) else { continue }
            value[op, default: 0] += showProjected ? row.total : row.operational
            delta[op, default: 0] += showProjected ? row.deltaTotal : row.deltaOperational
        }
        return ANFROperator.allCases.compactMap { op in
            value[op].map { (op, $0, delta[op] ?? 0) }
        }
        .sorted { $0.value > $1.value }
    }

    /// Répartition 4G / 5G (somme nationale toutes opérateurs sur bandes phares).
    var generationBreakdown: [(generation: ANFRGeneration, value: Int)] {
        guard let stats else { return [] }
        var byGen: [ANFRGeneration: Int] = [:]
        for row in stats.latest where headlineBands.contains(row.band) {
            let gen: ANFRGeneration = row.technology == "5G" ? .g5 : .g4
            byGen[gen, default: 0] += showProjected ? row.total : row.operational
        }
        return [ANFRGeneration.g4, .g5].compactMap { gen in byGen[gen].map { (gen, $0) } }
    }

    /// Détail par bande (n78 / n1 / n28 / 4G…) pour l'opérateur sélectionné.
    var bandBreakdown: [ANFRStatsLatest] {
        guard let stats else { return [] }
        return stats.latest
            .filter { ANFROperator.from(raw: $0.operatorKey) == selectedOperator }
            .filter { headlineBands.contains($0.band) }
            .sorted { $0.operational > $1.operational }
    }

    /// Série temporelle (opérateur sélectionné), une courbe par technologie.
    /// On agrège operational/total par date pour 4G globale + 5G n78 (porteuses).
    var trendSeries: [ANFRTrendPoint] {
        guard let stats else { return [] }
        let op = selectedOperator.apiKey
        let bands: [(band: String, gen: ANFRGeneration)]
        switch selectedFilter {
        case .g4:
            bands = [("4g", .g4)]
        case .g5_3500:
            bands = [("n78", .g5)]
        case .g5_2100:
            bands = [("n1", .g5)]
        case .g5_700:
            bands = [("n28", .g5)]
        }
        var points: [ANFRTrendPoint] = []
        for (band, gen) in bands {
            let rows = stats.series
                .filter { $0.operatorKey == op && $0.band == band }
                .sorted { $0.date < $1.date }
            for row in rows {
                guard let date = ANFRDateParser.date(from: row.date) else { continue }
                points.append(ANFRTrendPoint(
                    date: date,
                    value: showProjected ? row.total : row.operational,
                    generation: gen
                ))
            }
        }
        return points
    }

    var latestDateLabel: String {
        guard let raw = stats?.latestDate, let date = ANFRDateParser.date(from: raw) else { return "—" }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// Point de la courbe d'évolution.
struct ANFRTrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Int
    let generation: ANFRGeneration
}

// MARK: - View

struct ANFRStatsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: ANFRStatsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pilote l'animation des barres/donuts : passe à 1 après apparition.
    @State private var appeared = false

    init(service: ANFRServicing) {
        _model = StateObject(wrappedValue: ANFRStatsViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.xl) {
                if let stats = model.stats, !stats.latest.isEmpty {
                    header
                        .sqFadeUp()
                    VStack(spacing: SQSpace.sm) {
                        metricToggle
                        filterToggle
                            .padding(.top, SQSpace.xs)
                    }
                    .sqFadeUp()
                    heroCard
                        .sqFadeUp()
                    operatorSection
                        .sqFadeUp()
                    trendSection
                        .sqFadeUp()
                    bandSection
                        .sqFadeUp()
                    if !topRegions.isEmpty {
                        regionsSection
                            .sqFadeUp()
                    }
                } else if let error = model.errorMessage {
                    ErrorStateView(title: "Statistiques indisponibles", message: error) {
                        Task { await model.refresh() }
                    }
                    .padding(.top, SQSpace.huge)
                } else {
                    loadingState
                        .padding(.top, SQSpace.huge)
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge + SQSpace.huge)
        }
        .navigationTitle("Statistiques ANFR")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .refreshable { await model.refresh() }
        .task { await model.load() }
        .onAppear {
            withAnimation(reduceMotion ? nil : SQMotion.slow.delay(0.1)) { appeared = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Observatoire ANFR").sqKicker()
            Text("Le réseau mobile français")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SQSpace.xs + 2) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.bold))
                Text("Relevé du \(model.latestDateLabel)")
                    .font(SQType.subhead)
            }
            .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Op/Proj toggle

    private var metricToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(title: "Opérationnel", active: !model.showProjected) {
                setProjected(false)
            }
            toggleSegment(title: "Avec projeté", active: model.showProjected) {
                setProjected(true)
            }
        }
        .padding(3)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private func toggleSegment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(SQFont.archivo(14, .bold))
                .foregroundStyle(active ? .white : SQColor.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.sm + 2)
                .background(active ? SQColor.brandRed : Color.clear, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: active)
    }

    private func setProjected(_ value: Bool) {
        guard model.showProjected != value else { return }
        withAnimation(reduceMotion ? nil : SQMotion.standard) {
            model.showProjected = value
        }
    }

    // MARK: Filter selector

    private var filterToggle: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFRFilterType.allCases) { type in
                    let selected = model.selectedFilter == type
                    Button {
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : SQMotion.standard) {
                            model.selectedFilter = type
                        }
                    } label: {
                        Text(type.label)
                            .font(SQFont.archivo(13, .bold))
                            .padding(.horizontal, SQSpace.md)
                            .frame(height: 36)
                            .background(selected ? SQColor.brandRed : SQColor.fill, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(selected ? Color.clear : SQColor.separator, lineWidth: 1.5)
                            }
                            .foregroundStyle(selected ? Color.white : SQColor.label)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .sqAnimation(SQMotion.fast, value: selected)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Hero total

    private var heroCard: some View {
        let filterLabel = model.selectedFilter.label
        let subtext = model.showProjected
            ? "Total opérationnel + projeté, \(filterLabel)"
            : "Supports opérationnels, \(filterLabel)"
            
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Supports déployés").sqKicker()
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(model.totalOperational, format: .number.grouping(.automatic))
                    .font(SQFont.display(46, .black))
                    .foregroundStyle(SQColor.label)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : SQMotion.snappy, value: model.totalOperational)
                deltaTag(model.totalDelta)
            }
            Text(subtext)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(SQColor.brandRed.opacity(0.16))
                .padding(SQSpace.lg)
        }
    }

    @ViewBuilder
    private func deltaTag(_ delta: Int) -> some View {
        if delta != 0 {
            let positive = delta > 0
            HStack(spacing: 2) {
                Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .black))
                Text("\(abs(delta))")
                    .font(SQFont.archivo(13, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(positive ? SQColor.success : SQColor.danger)
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, SQSpace.xs)
            .background((positive ? SQColor.success : SQColor.danger).opacity(0.12), in: Capsule())
            .accessibilityLabel(positive ? "en hausse de \(delta) cette semaine" : "en baisse de \(abs(delta)) cette semaine")
        }
    }

    // MARK: Opérateurs

    private var operatorSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionHeader("Par opérateur", systemImage: "person.3.fill")
            let rows = model.operatorBreakdown
            let maxValue = max(rows.map(\.value).max() ?? 1, 1)
            VStack(spacing: SQSpace.md) {
                ForEach(rows, id: \.operator) { row in
                    operatorBar(row, fraction: Double(row.value) / Double(maxValue))
                }
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private func operatorBar(_ row: (operator: ANFROperator, value: Int, delta: Int), fraction: Double) -> some View {
        VStack(spacing: SQSpace.xs + 2) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(row.operator.color).frame(width: 10, height: 10)
                Text(row.operator.label)
                    .font(SQFont.archivo(15, .bold))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Text(row.value, format: .number.grouping(.automatic))
                    .font(SQFont.archivo(15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                deltaTag(row.delta)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SQColor.fill).frame(height: 8)
                    Capsule()
                        .fill(row.operator.color)
                        .frame(width: proxy.size.width * (appeared ? fraction : 0), height: 8)
                }
            }
            .frame(height: 8)
        }
        .animation(reduceMotion ? nil : SQMotion.slow, value: appeared)
        .animation(reduceMotion ? nil : SQMotion.standard, value: fraction)
    }

    // MARK: Générations (donut)

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionHeader("Par génération", systemImage: "chart.pie.fill")
            HStack(spacing: SQSpace.xl) {
                ANFRDonutChart(
                    segments: model.generationBreakdown.map { (color: $0.generation.color, value: Double($0.value)) },
                    progress: appeared ? 1 : 0
                )
                .frame(width: 116, height: 116)

                VStack(alignment: .leading, spacing: SQSpace.md) {
                    let total = max(model.generationBreakdown.reduce(0) { $0 + $1.value }, 1)
                    ForEach(model.generationBreakdown, id: \.generation) { item in
                        HStack(spacing: SQSpace.sm) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.generation.color)
                                .frame(width: 12, height: 12)
                            Text(item.generation.label)
                                .font(SQFont.archivo(15, .bold))
                                .foregroundStyle(SQColor.label)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(item.value, format: .number.grouping(.automatic))
                                    .font(SQFont.archivo(15, .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.label)
                                    .contentTransition(.numericText())
                                Text("\(Int((Double(item.value) / Double(total) * 100).rounded()))%")
                                    .font(SQType.micro)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Évolution (line chart)

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack {
                sectionHeader("Évolution", systemImage: "chart.xyaxis.line")
                Spacer()
            }
            operatorPicker
            ANFRTrendChart(points: model.trendSeries, animate: appeared && !reduceMotion)
                .frame(height: 196)
            HStack(spacing: SQSpace.lg) {
                if model.selectedFilter == .g4 {
                    legendDot(color: ANFRGeneration.g4.color, label: "4G globale")
                } else {
                    legendDot(color: ANFRGeneration.g5.color, label: model.selectedFilter.label)
                }
                Spacer()
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private var operatorPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFROperator.allCases) { op in
                    let selected = model.selectedOperator == op
                    Button {
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : SQMotion.standard) {
                            model.selectedOperator = op
                        }
                    } label: {
                        HStack(spacing: SQSpace.xs + 2) {
                            Circle().fill(selected ? Color.white : op.color).frame(width: 7, height: 7)
                            Text(op.label)
                                .font(SQFont.archivo(13, .bold))
                        }
                        .padding(.horizontal, SQSpace.md - 2)
                        .frame(height: 34)
                        .background(selected ? AnyShapeStyle(op.color) : AnyShapeStyle(SQColor.fill), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                .stroke(selected ? Color.clear : SQColor.separator, lineWidth: 1.5)
                        }
                        .foregroundStyle(selected ? Color.white : SQColor.label)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .sqAnimation(SQMotion.fast, value: selected)
                }
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: SQSpace.xs + 2) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    // MARK: Bandes (opérateur sélectionné)

    private var bandSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                sectionHeader("Bandes — \(model.selectedOperator.label)", systemImage: "waveform")
                Spacer()
            }
            VStack(spacing: SQSpace.sm) {
                ForEach(model.bandBreakdown) { band in
                    HStack(spacing: SQSpace.sm) {
                        SQEditorialTag(text: band.technology, color: SQBrand.techColor(band.technology))
                        Text(band.bandLabel)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                        Spacer()
                        Text(model.showProjected ? band.total : band.operational, format: .number.grouping(.automatic))
                            .font(SQFont.archivo(15, .bold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                            .contentTransition(.numericText())
                    }
                    .padding(.vertical, SQSpace.sm)
                    .padding(.horizontal, SQSpace.md)
                    .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Régions (top)

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            let filterLabel = model.selectedFilter.label
            sectionHeader("Top régions — \(model.selectedOperator.label) \(filterLabel)", systemImage: "map.fill")
            let rows = topRegions
            let maxValue = max(rows.map(\.operational).max() ?? 1, 1)
            VStack(spacing: SQSpace.sm) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, region in
                    HStack(spacing: SQSpace.sm) {
                        Text("\(index + 1)")
                            .font(SQFont.archivo(12, .bold))
                            .foregroundStyle(SQColor.labelTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(region.label)
                                .font(SQFont.archivo(14, .semibold))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(1)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SQColor.fill).frame(height: 6)
                                    Capsule()
                                        .fill(model.selectedOperator.color)
                                        .frame(width: proxy.size.width * (appeared ? Double(region.operational) / Double(maxValue) : 0), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                        Text(region.operational, format: .number.grouping(.automatic))
                            .font(SQFont.archivo(14, .bold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                    }
                    .animation(reduceMotion ? nil : SQMotion.slow, value: appeared)
                }
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private var topRegions: [ANFRTerritoryMetric] {
        guard let stats = model.stats else { return [] }
        return stats.regions
            .filter { $0.operatorKey == model.selectedOperator.apiKey && model.selectedFilter.bands.contains($0.band) }
            .sorted { $0.operational > $1.operational }
            .prefix(6)
            .map { $0 }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SQColor.brandRed)
            Text(title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
        }
    }

    private var loadingState: some View {
        VStack(spacing: SQSpace.lg) {
            ProgressView()
                .tint(SQColor.brandRed)
            Text("Chargement des statistiques ANFR…")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Donut chart (Canvas, animé)

private struct ANFRDonutChart: View {
    let segments: [(color: Color, value: Double)]
    /// 0 → 1 : fraction de l'anneau tracée (animation d'apparition).
    var progress: Double

    var body: some View {
        Canvas { context, size in
            let total = segments.reduce(0) { $0 + $1.value }
            guard total > 0 else { return }
            let lineWidth = size.width * 0.20
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            var start = -90.0
            for segment in segments {
                let sweep = (segment.value / total) * 360 * progress
                var path = Path()
                path.addArc(
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    radius: rect.width / 2,
                    startAngle: .degrees(start),
                    endAngle: .degrees(start + sweep),
                    clockwise: false
                )
                context.stroke(path, with: .color(segment.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                start += (segment.value / total) * 360
            }
        }
        .animation(.easeOut(duration: 0.7), value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Trend chart (Swift Charts)

private struct ANFRTrendChart: View {
    let points: [ANFRTrendPoint]
    let animate: Bool
    @State private var drawn = false

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Supports", point.value)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .foregroundStyle(by: .value("Génération", point.generation.label))

            AreaMark(
                x: .value("Date", point.date),
                y: .value("Supports", point.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(by: .value("Génération", point.generation.label))
            .opacity(0.12)
        }
        .chartForegroundStyleScale([
            ANFRGeneration.g4.label: ANFRGeneration.g4.color,
            ANFRGeneration.g5.label: ANFRGeneration.g5.color
        ])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.5))
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text(intValue.formatted(.number.notation(.compactName)))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { value in
                AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.4))
                AxisValueLabel(format: .dateTime.year())
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        // Tracé progressif : on masque puis révèle horizontalement.
        .mask(alignment: .leading) {
            GeometryReader { proxy in
                Rectangle().frame(width: drawn ? proxy.size.width : 0)
            }
        }
        .onAppear {
            guard animate else { drawn = true; return }
            withAnimation(.easeInOut(duration: 0.9)) { drawn = true }
        }
        .onChangeCompat(of: points.map(\.id)) { _, _ in
            // Nouveau jeu de données (changement d'opérateur) : re-trace.
            drawn = false
            withAnimation(.easeInOut(duration: 0.7)) { drawn = true }
        }
    }
}

// MARK: - Date parsing

enum ANFRDateParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
