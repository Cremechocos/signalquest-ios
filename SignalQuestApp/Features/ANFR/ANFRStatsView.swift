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
        #if DEBUG
        if AppEnvironment.usesDemoData {
            stats = ANFRDemoData.stats
            errorMessage = nil
            return
        }
        #endif
        guard stats == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            stats = try await service.stats()
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    func refresh() async {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            stats = ANFRDemoData.stats
            return
        }
        #endif
        do {
            stats = try await service.stats()
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    // MARK: Dérivations (rollups depuis national.latest)

    /// Total national de sites opérateurs (somme par opérateur sur la bande filtrée).
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

    /// Détail par bande (n78 / n1 / n28 / 4G…) pour l'opérateur sélectionné.
    var bandBreakdown: [ANFRStatsLatest] {
        guard let stats else { return [] }
        return stats.latest
            .filter { ANFROperator.from(raw: $0.operatorKey) == selectedOperator }
            .filter { headlineBands.contains($0.band) }
            .sorted { $0.operational > $1.operational }
    }

    /// Série temporelle de l'opérateur sélectionné, sur la bande filtrée.
    var trendSeries: [ANFRTrendPoint] { trendSeries(for: selectedOperator) }

    /// Série d'un opérateur sur la bande filtrée : le plein écran en superpose
    /// plusieurs.
    func trendSeries(for op: ANFROperator) -> [ANFRTrendPoint] {
        guard let stats else { return [] }
        let band: String
        let gen: ANFRGeneration
        switch selectedFilter {
        case .g4: (band, gen) = ("4g", .g4)
        case .g5_3500: (band, gen) = ("n78", .g5)
        case .g5_2100: (band, gen) = ("n1", .g5)
        case .g5_700: (band, gen) = ("n28", .g5)
        }
        return stats.series
            .filter { $0.operatorKey == op.apiKey && $0.band == band }
            .sorted { $0.date < $1.date }
            .compactMap { row in
                ANFRDateParser.date(from: row.date).map {
                    ANFRTrendPoint(date: $0, value: showProjected ? row.total : row.operational, generation: gen)
                }
            }
    }

    /// Variation relative entre le premier et le dernier relevé d'une série.
    static func change(of points: [ANFRTrendPoint]) -> Double? {
        guard let first = points.first?.value, let last = points.last?.value, first > 0, points.count > 1 else { return nil }
        return Double(last - first) / Double(first)
    }

    var latestDateLabel: String {
        guard let raw = stats?.latestDate, let date = ANFRDateParser.date(from: raw) else { return "—" }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// Point de la courbe d'évolution.
struct ANFRTrendPoint: Identifiable {
    let date: Date
    let value: Int
    let generation: ANFRGeneration
    /// Stable d'un rendu à l'autre : un identifiant tiré à chaque calcul
    /// faisait retracer la courbe à chaque mouvement du doigt.
    var id: Date { date }
}

/// Une courbe du graphique : la série d'un opérateur.
struct ANFRTrendSeries: Identifiable {
    let op: ANFROperator
    let points: [ANFRTrendPoint]
    var id: String { op.rawValue }
}

// MARK: - View

struct ANFRStatsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: ANFRStatsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    /// Pilote l'animation des barres/donuts : passe à 1 après apparition.
    @State private var appeared = false
    /// Relevé lu au doigt sur la courbe de la carte.
    @State private var scrubDate: Date?
    @Environment(\.locale) private var locale
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.controlSize) private var controlSize
    private let service: ANFRServicing

    init(service: ANFRServicing) {
        self.service = service
        _model = StateObject(wrappedValue: ANFRStatsViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                if let stats = model.stats, !stats.latest.isEmpty {
                    VStack(spacing: SQSpace.sm) {
                        metricToggle
                        filterToggle
                    }
                    .sqFadeUp()
                    heroCard
                        .sqFadeUp()
                    bandsLink
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
                    Text("Source : Observatoire ANFR. Les régions suivent l’opérateur choisi dans « Évolution ».")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SQSpace.xs)
                } else if model.errorMessage != nil {
                    ErrorStateView(title: "Statistiques indisponibles", message: friendlyError) {
                        Task { await model.refresh() }
                    }
                } else if model.stats != nil {
                    // Réponse reçue mais sans relevé : un état vide, pas un chargement sans fin.
                    EmptyStateView(
                        title: "Aucune statistique disponible",
                        message: "Les relevés ANFR ne sont pas encore disponibles. Tire l'écran vers le bas pour actualiser.",
                        systemImage: "chart.bar"
                    )
                } else {
                    loadingState
                        .padding(.top, SQSpace.huge)
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQDock.floatingContentInset)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : UIKit coupe le balayage retour, rétabli ici.
        .sqKeepsSwipeBack()
        .navigationTitle("Statistiques ANFR")
        .signalQuestBackground()
        .refreshable { await model.refresh() }
        .task { await model.load() }
        .onAppear {
            withAnimation(reduceMotion ? nil : SQMotion.slow.delay(0.1)) { appeared = true }
        }
    }

    /// Plein écran tourné en paysage ; la langue et le mode terrain suivent,
    /// l'hôte UIKit ne recevant que l'environnement système.
    private func openFullScreen() {
        ANFRLandscapeHost.present(
            ANFRTrendFullScreen(model: model, onClose: ANFRLandscapeHost.dismissCurrent)
                .environment(\.locale, locale)
                .environment(\.legibilityWeight, legibilityWeight)
                .controlSize(controlSize)
        )
    }

    /// Message serveur parfois technique : l'écran dit quoi faire, sauf hors
    /// ligne, qui a son propre état.
    private var friendlyError: String {
        if model.errorMessage == SQOfflineText.message { return SQOfflineText.message }
        return String(localized: "Impossible de charger les statistiques pour l’instant. Vérifie ta connexion, puis réessaie.")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "anfr.stats.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Statistiques ANFR")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("anfr.stats.title")
                Text("Le réseau mobile français, d’après l’Agence nationale des fréquences.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.stats != nil {
                    Label("Relevé du \(model.latestDateLabel)", systemImage: "clock")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Op/Proj toggle

    private var metricToggle: some View {
        MapSegmented(
            selection: Binding(get: { model.showProjected }, set: { setProjected($0) }),
            options: [(false, String(localized: "Opérationnel")), (true, String(localized: "Avec projeté"))],
            identifier: "anfr.stats.metric"
        )
    }

    private func setProjected(_ value: Bool) {
        guard model.showProjected != value else { return }
        withAnimation(reduceMotion ? nil : SQMotion.standard) {
            model.showProjected = value
        }
    }

    // MARK: Filter selector

    /// Bandes en pastilles, la choisie en encre.
    private var filterToggle: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFRFilterType.allCases) { type in
                    SQChip(
                        label: type.label, isSelected: model.selectedFilter == type,
                        selectedFill: SQColor.label, selectedInk: SQColor.onInk
                    ) {
                        withAnimation(reduceMotion ? nil : SQMotion.standard) {
                            model.selectedFilter = type
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Hero total

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sites opérateurs · \(model.selectedFilter.label)")
                    .sqKicker()
                Spacer(minLength: SQSpace.sm)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    heroValue
                    deltaTag(model.totalDelta)
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    heroValue
                    deltaTag(model.totalDelta)
                }
            }
            // Somme par opérateur : un pylône partagé compte une fois par opérateur,
            // à la différence du total « Tous » de l'écran Bandes.
            Text(model.showProjected
                 ? "Sites opérationnels et projetés, tous opérateurs."
                 : "Sites opérationnels, tous opérateurs.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Un pylône partagé compte une fois par opérateur.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    private var heroValue: some View {
        Text(model.totalOperational, format: .number.grouping(.automatic))
            .font(SQType.metricLarge)
            .foregroundStyle(SQColor.label)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : SQMotion.snappy, value: model.totalOperational)
    }

    // MARK: Générations et bandes

    private var bandsLink: some View {
        NavigationLink {
            ANFRBandsView(service: service)
        } label: {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: "square.stack.3d.up.fill", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Générations et bandes")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text("2G et 3G en extinction, 4G et 5G par fréquence")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .sqCardBackground()
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.98))
        .accessibilityIdentifier("anfr.stats.bands")
    }

    /// Variation sur 7 jours dite en mots : « +3 en 7 j », « −3 en 7 j », « stable ».
    @ViewBuilder
    private func deltaTag(_ delta: Int) -> some View {
        if delta != 0 {
            let positive = delta > 0
            Text(positive ? "+\(delta) en 7 j" : "−\(abs(delta)) en 7 j")
                .font(SQFont.body(12.5, .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(positive ? SQColor.success : SQColor.dangerInk)
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, SQSpace.xs)
                .background(positive ? SQColor.successSoft : SQColor.dangerSoft, in: Capsule(style: .continuous))
                .sqSingleLine()
                .fixedSize()
                .accessibilityLabel(positive ? "en hausse de \(delta) cette semaine" : "en baisse de \(abs(delta)) cette semaine")
        } else {
            // Delta nul MAIS donnée présente (la pastille n'est rendue que pour un
            // opérateur/total ayant des données) → indicateur NEUTRE « stable »,
            // distinct de « aucune donnée » (rien). Corrige le cas Free, dont
            // l'`operational` n'a pas bougé cette semaine et qui paraissait « vide ».
            Text("stable")
                .font(SQFont.body(12.5, .bold))
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, SQSpace.xs)
                .background(SQColor.chip, in: Capsule(style: .continuous))
                .fixedSize()
                .accessibilityLabel("stable cette semaine")
        }
    }

    // MARK: Opérateurs

    private var operatorSection: some View {
        let rows = model.operatorBreakdown
        let maxValue = max(rows.map(\.value).max() ?? 1, 1)
        return statsCard("Par opérateur") {
            Text("sur 7 jours")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.operator) { index, row in
                    operatorBar(row, fraction: Double(row.value) / Double(maxValue))
                        .padding(.vertical, SQSpace.sm2)
                        .mapRowDivider(index > 0)
                }
            }
        }
    }

    private func operatorBar(_ row: (operator: ANFROperator, value: Int, delta: Int), fraction: Double) -> some View {
        VStack(spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(row.operator.color).frame(width: 9, height: 9)
                Text(row.operator.label)
                    .font(SQType.body(.bold))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Text(row.value, format: .number.grouping(.automatic))
                    .font(SQType.body(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                deltaTag(row.delta)
            }
            .accessibilityElement(children: .combine)
            bar(fraction: appeared ? fraction : 0, color: row.operator.color, height: 6)
        }
        .animation(reduceMotion ? nil : SQMotion.slow, value: appeared)
        .animation(reduceMotion ? nil : SQMotion.standard, value: fraction)
    }

    private func bar(fraction: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.chip)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    // MARK: Évolution (line chart)

    private var trendSection: some View {
        let points = model.trendSeries
        let op = model.selectedOperator
        return statsCard("Évolution") {
            MapChipIconButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                label: "Ouvrir le graphique en plein écran",
                identifier: "anfr.stats.fullscreen"
            ) {
                scrubDate = nil
                openFullScreen()
            }
        } content: {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                operatorPicker
                trendReadout(points)
                ANFRTrendChart(
                    series: [ANFRTrendSeries(op: op, points: points)],
                    selection: $scrubDate,
                    animate: appeared && !reduceMotion,
                    drawKey: "\(op.rawValue)-\(model.selectedFilter.rawValue)-\(model.showProjected)",
                    onTap: { openFullScreen() }
                )
                .frame(height: 196)
                // Alternative non visuelle (A11Y-08) : on résume la courbe pour
                // VoiceOver en nommant explicitement la génération.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(trendAccessibilityLabel)
                .accessibilityHint("Ouvre le graphique en plein écran")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openFullScreen() }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    HStack(spacing: SQSpace.xs2) {
                        Capsule().fill(op.color).frame(width: 14, height: 3)
                            .accessibilityHidden(true)
                        Text(seriesCaption(for: op))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Glisse le doigt sur la courbe, touche-la pour l’agrandir.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    /// Valeur actuelle et hausse sur la période ; au doigt, la date et la valeur
    /// du relevé touché.
    @ViewBuilder
    private func trendReadout(_ points: [ANFRTrendPoint]) -> some View {
        let touched = scrubDate.flatMap { date in points.first { $0.date == date } }
        let value = touched?.value ?? points.last?.value
        if let value {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    readoutValue(value)
                    readoutCaption
                    Spacer(minLength: SQSpace.xs)
                    readoutTrailing(points, touched: touched)
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                        readoutValue(value)
                        readoutCaption
                    }
                    readoutTrailing(points, touched: touched)
                }
            }
        }
    }

    private func readoutValue(_ value: Int) -> some View {
        Text(value, format: .number.grouping(.automatic))
            .font(SQFont.display(22, .bold))
            .monospacedDigit()
            .foregroundStyle(SQColor.label)
            .contentTransition(.numericText())
    }

    private var readoutCaption: some View {
        Text("sites \(model.selectedFilter.label) \(model.selectedOperator.label)")
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .sqSingleLine()
    }

    @ViewBuilder
    private func readoutTrailing(_ points: [ANFRTrendPoint], touched: ANFRTrendPoint?) -> some View {
        if let touched {
            Text(ANFRTrendChart.weekLabel(touched.date))
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.ink2)
                .sqSingleLine()
        } else if let change = ANFRStatsViewModel.change(of: points) {
            ANFRChangePill(change: change)
        }
    }

    private func seriesCaption(for op: ANFROperator) -> String {
        let metric = model.showProjected
            ? String(localized: "sites opérationnels et projetés")
            : String(localized: "sites opérationnels")
        return "\(op.label) · \(model.selectedFilter.label), \(metric)"
    }

    /// Opérateurs en pastilles, le choisi en encre.
    private var operatorPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFROperator.allCases) { op in
                    let selected = model.selectedOperator == op
                    SQChip(
                        label: op.label, isSelected: selected, dot: op.color,
                        selectedFill: SQColor.label, selectedInk: SQColor.onInk
                    ) {
                        scrubDate = nil
                        withAnimation(reduceMotion ? nil : SQMotion.standard) {
                            model.selectedOperator = op
                        }
                    }
                    .sqAnimation(SQMotion.fast, value: selected)
                }
            }
        }
    }

    /// Résumé textuel de la courbe d'évolution pour VoiceOver : nomme la génération
    /// (4G / 5G), l'opérateur et la variation du début à la fin de la période.
    private var trendAccessibilityLabel: String {
        let points = model.trendSeries
        let scope = model.selectedFilter.label
        let opName = model.selectedOperator.label
        guard !points.isEmpty else {
            return String(localized: "Évolution des supports \(opName) en \(scope) : aucune donnée disponible sur la période.")
        }
        let metric = model.showProjected ? String(localized: "opérationnels et projetés") : String(localized: "opérationnels")
        let segments = ANFRGeneration.allCases
            .filter { gen in points.contains { $0.generation == gen } }
            .map { gen -> String in
                let series = points.filter { $0.generation == gen }.sorted { $0.date < $1.date }
                let start = (series.first?.value ?? 0).formatted(.number.grouping(.automatic))
                let end = (series.last?.value ?? 0).formatted(.number.grouping(.automatic))
                return String(localized: "\(gen.label) de \(start) à \(end) supports")
            }
        return String(localized: "Évolution des supports \(opName) en \(scope), \(metric) : ")
            + segments.joined(separator: " ; ") + String(localized: " sur la période.")
    }

    // MARK: Bandes (opérateur sélectionné)

    /// Bandes en lignes à pointillés, comme les détails du Tester.
    private var bandSection: some View {
        statsCard("Bandes · \(model.selectedOperator.label)") {
            VStack(spacing: SQSpace.xs) {
                ForEach(model.bandBreakdown) { band in
                    SQFactRow(
                        label: band.bandLabel,
                        value: (model.showProjected ? band.total : band.operational).formatted(.number.grouping(.automatic))
                    )
                }
            }
        }
    }

    // MARK: Régions (top)

    private var regionsSection: some View {
        let rows = topRegions
        let maxValue = max(rows.map(\.operational).max() ?? 1, 1)
        return statsCard("Top régions · \(model.selectedOperator.label) \(model.selectedFilter.label)") {
            VStack(spacing: SQSpace.sm2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, region in
                    HStack(spacing: SQSpace.sm2) {
                        Text("\(index + 1)")
                            .font(SQFont.body(13, .bold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(minWidth: 16)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(region.label)
                                    .font(SQFont.body(14.5, .semibold))
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(2)
                                Spacer(minLength: SQSpace.sm)
                                Text(region.operational, format: .number.grouping(.automatic))
                                    .font(SQType.subhead(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.label)
                            }
                            bar(
                                fraction: appeared ? Double(region.operational) / Double(maxValue) : 0,
                                color: model.selectedOperator.color, height: 5
                            )
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .animation(reduceMotion ? nil : SQMotion.slow, value: appeared)
                }
            }
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

    /// Carte titrée de la page : titre à gauche, accessoire éventuel à droite.
    private func statsCard<Trailing: View, Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .center, spacing: SQSpace.sm) {
                Text(title)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                Spacer(minLength: SQSpace.sm)
                trailing()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    private var loadingState: some View {
        VStack(spacing: SQSpace.lg) {
            SQSpinner()
                .tint(SQColor.brandRed)
            Text("Chargement des statistiques ANFR…")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// « +22 % sur la période », vert en hausse, rouge en baisse.
private struct ANFRChangePill: View {
    let change: Double
    var suffix: String? = nil

    var body: some View {
        let positive = change >= 0
        let percent = change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
        Label(suffix ?? String(localized: "\(percent) sur la période"), systemImage: positive ? "arrow.up.right" : "arrow.down.right")
            .font(SQType.caption(.bold))
            .foregroundStyle(positive ? SQColor.success : SQColor.dangerInk)
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, SQSpace.xs)
            .background(positive ? SQColor.successSoft : SQColor.dangerSoft, in: Capsule(style: .continuous))
            .sqSingleLine()
            .fixedSize()
    }
}

// MARK: - Trend chart (Swift Charts)

/// Courbe d'évolution : une ou plusieurs séries à la couleur de leur opérateur,
/// lecture au doigt (trait pointillé et points sur chaque courbe).
private struct ANFRTrendChart: View {
    let series: [ANFRTrendSeries]
    /// Période affichée ; toute la série par défaut.
    var domain: ClosedRange<Date>? = nil
    @Binding var selection: Date?
    let animate: Bool
    /// Change quand le jeu de données change (opérateur, bande…) : la courbe se retrace.
    let drawKey: String
    /// Plein écran : axe à l'échelle des valeurs, info-bulle et sélection gardée.
    var isExpanded = false
    var onTap: (() -> Void)? = nil
    @State private var drawn = false
    @State private var lastHapticDate: Date?
    @State private var chartWidth: CGFloat = 0

    /// « Semaine du 3 mars 2025 » : les relevés ANFR sont hebdomadaires.
    static func weekLabel(_ date: Date) -> String {
        String(localized: "Semaine du \(date.formatted(.dateTime.day().month(.wide).year()))")
    }

    static func nearest(in points: [ANFRTrendPoint], to date: Date) -> ANFRTrendPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private var allPoints: [ANFRTrendPoint] { series.flatMap(\.points) }

    private var fullDomain: ClosedRange<Date>? {
        guard let first = allPoints.map(\.date).min(), let last = allPoints.map(\.date).max(), first < last else { return nil }
        return first...last
    }

    private var xDomain: ClosedRange<Date>? { domain ?? fullDomain }

    private func visible(_ points: [ANFRTrendPoint]) -> [ANFRTrendPoint] {
        guard let xDomain else { return points }
        return points.filter { xDomain.contains($0.date) }
    }

    /// Relevés tracés : un de plus de chaque côté de la période, pour que la
    /// courbe aille jusqu'aux bords au lieu de s'arrêter au dernier relevé visible.
    private func drawn(_ points: [ANFRTrendPoint]) -> [ANFRTrendPoint] {
        guard let xDomain,
              let first = points.firstIndex(where: { $0.date >= xDomain.lowerBound }),
              let last = points.lastIndex(where: { $0.date <= xDomain.upperBound }) else {
            return xDomain == nil ? points : []
        }
        return Array(points[max(first - 1, 0)...min(last + 1, points.count - 1)])
    }

    /// Courbe prolongée hors de la période : on la coupe au bord du graphique.
    private var clipsPlot: Bool {
        series.contains { drawn($0.points).count != visible($0.points).count }
    }

    /// Marge au-dessus du plus haut point : le dernier libellé de l'axe n'est
    /// plus coupé par le haut du graphique.
    private var yDomain: ClosedRange<Int> {
        let values = series.flatMap { visible($0.points) }.map(\.value)
        let high = max(values.max() ?? 1, 1)
        guard isExpanded, let low = values.min() else { return 0...Int(Double(high) * 1.12) }
        let pad = max(Int(Double(high - low) * 0.12), 1)
        return max(0, low - pad)...(high + pad)
    }

    /// Une seule courbe : on la remplit dessous.
    private var areaSeries: [ANFRTrendSeries] { series.count == 1 && !isExpanded ? series : [] }

    /// Tableaux de 0 ou 1 élément plutôt que des `if` dans `Chart {}` (plantage
    /// connu de Swift Charts avec `symbolSize`).
    private var selectionDates: [Date] { selection.map { [$0] } ?? [] }

    private var selectedPoints: [(op: ANFROperator, point: ANFRTrendPoint)] {
        guard let selection else { return [] }
        return series.compactMap { s in Self.nearest(in: visible(s.points), to: selection).map { (s.op, $0) } }
    }

    var body: some View {
        chart
            .chartXScale(domain: xDomain ?? Date()...Date().addingTimeInterval(1))
            .chartYScale(domain: yDomain)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
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
            .chartXAxis { xAxis }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { chartWidth = geo.size.width }
                        .onChangeCompat(of: geo.size.width) { _, width in chartWidth = width }
                }
            }
            .chartPlotStyle { plot in
                if clipsPlot {
                    plot.background(Color.clear).clipped()
                } else {
                    plot.background(Color.clear)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = geo[proxy.plotAreaFrame]
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap?() }
                            .gesture(
                                DragGesture(minimumDistance: isExpanded ? 0 : 8)
                                    .onChanged { value in
                                        guard let date: Date = proxy.value(atX: value.location.x - plot.origin.x),
                                              let point = Self.nearest(in: series.flatMap { visible($0.points) }, to: date)
                                        else { return }
                                        if lastHapticDate != point.date {
                                            lastHapticDate = point.date
                                            Haptics.selection()
                                        }
                                        selection = point.date
                                    }
                                    .onEnded { _ in
                                        if !isExpanded { selection = nil }
                                    }
                            )
                        if isExpanded, let selection, let x = proxy.position(forX: selection) {
                            tooltip(at: selection)
                                .offset(
                                    x: plot.origin.x + x + 14 + 214 < plot.maxX
                                        ? plot.origin.x + x + 14
                                        : max(plot.origin.x, plot.origin.x + x - 14 - 214),
                                    y: plot.origin.y + 6
                                )
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
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
            .onChangeCompat(of: drawKey) { _, _ in
                // Nouveau jeu de données : re-trace, sauf sous « Réduire les
                // animations » où la courbe reste tracée.
                guard animate else { return }
                drawn = false
                withAnimation(.easeInOut(duration: 0.7)) { drawn = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    Text(accessibilitySummary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(series) { s in
                        ForEach(visible(s.points)) { point in
                            Text("\(s.op.label), \(point.date.formatted(.dateTime.month().year())) : \(point.value.formatted()) supports")
                        }
                    }
                }
            }
    }

    private var chart: some View {
        Chart {
            ForEach(areaSeries) { s in
                ForEach(drawn(s.points)) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Supports", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(s.op.color.opacity(0.12))
                }
            }
            ForEach(series) { s in
                ForEach(drawn(s.points)) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Supports", point.value),
                        series: .value("Opérateur", s.op.label)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: isExpanded ? 2.6 : 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(s.op.color)
                }
            }
            ForEach(selectionDates, id: \.self) { date in
                RuleMark(x: .value("Date", date))
                    .foregroundStyle(SQColor.label.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            ForEach(selectedPoints, id: \.op) { item in
                PointMark(
                    x: .value("Date", item.point.date),
                    y: .value("Supports", item.point.value)
                )
                .symbolSize(70)
                .foregroundStyle(item.op.color)
            }
        }
    }

    private var xAxis: some AxisContent {
        let span = xDomain.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? 0
        let months = span / (30.44 * 86_400)
        // Le pas suit la place disponible : un libellé « janv. 25 » tous les
        // 64 pt au plus (5 en portrait, une douzaine en paysage), à l’année
        // quand même un semestre serait trop serré.
        let room = Double(max(Int((chartWidth > 0 ? chartWidth : 320) / 64), 2))
        let stride = [1, 2, 3, 6].first { months / Double($0) <= room }
        return AxisMarks(values: stride.map { .stride(by: .month, count: $0) } ?? .stride(by: .year)) { _ in
            AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.4))
            AxisValueLabel(format: stride == nil ? .dateTime.year() : .dateTime.month(.abbreviated).year(.twoDigits))
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    /// Info-bulle du plein écran : la semaine et la valeur de chaque courbe affichée.
    private func tooltip(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.weekLabel(date))
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
            ForEach(selectedPoints.sorted { $0.point.value > $1.point.value }, id: \.op) { item in
                HStack(spacing: SQSpace.xs2) {
                    Circle().fill(item.op.color).frame(width: 8, height: 8)
                    Text(item.op.label)
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.ink2)
                    Spacer(minLength: SQSpace.sm)
                    Text(item.point.value, format: .number.grouping(.automatic))
                        .font(SQType.caption(.bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                }
            }
        }
        .padding(SQSpace.sm2)
        .frame(width: 214, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .strokeBorder(SQColor.separator, lineWidth: 1)
        }
    }

    private var accessibilitySummary: String {
        let names = series.map(\.op.label).joined(separator: ", ")
        let points = series.flatMap { visible($0.points) }
        guard let first = points.min(by: { $0.date < $1.date }),
              let last = points.max(by: { $0.date < $1.date }) else {
            return String(localized: "Évolution ANFR : aucune donnée")
        }
        return String(localized: "Évolution ANFR \(names), de \(first.date.formatted(.dateTime.month().year())) à \(last.date.formatted(.dateTime.month().year())).")
    }
}

// MARK: - Plein écran (paysage)

/// Graphique d'évolution en plein écran, téléphone tourné : plusieurs
/// opérateurs superposés, période 1 an / 3 ans / tout, lecture au doigt de
/// chaque relevé et pincement pour zoomer.
private struct ANFRTrendFullScreen: View {
    @ObservedObject var model: ANFRStatsViewModel
    let onClose: () -> Void
    @State private var shown: Set<ANFROperator> = Set(ANFROperator.allCases)
    @State private var range: TrendRange = .all
    /// Période ajustée au pincement ; `nil` = celle du segment.
    @State private var zoomDomain: ClosedRange<Date>?
    @State private var pinchBase: ClosedRange<Date>?
    @State private var selection: Date?

    private enum TrendRange: Hashable { case oneYear, threeYears, all }

    private var series: [ANFRTrendSeries] {
        ANFROperator.allCases
            .filter { shown.contains($0) }
            .map { ANFRTrendSeries(op: $0, points: model.trendSeries(for: $0)) }
    }

    private var fullDomain: ClosedRange<Date>? {
        let dates = ANFROperator.allCases.flatMap { model.trendSeries(for: $0) }.map(\.date)
        guard let first = dates.min(), let last = dates.max(), first < last else { return nil }
        return first...last
    }

    private var rangeDomain: ClosedRange<Date>? {
        guard let full = fullDomain else { return nil }
        let years: Double
        switch range {
        case .oneYear: years = 1
        case .threeYears: years = 3
        case .all: return full
        }
        let start = max(full.lowerBound, full.upperBound.addingTimeInterval(-years * 365 * 86_400))
        return start...full.upperBound
    }

    private var domain: ClosedRange<Date>? { zoomDomain ?? rangeDomain }

    private var title: String {
        model.showProjected
            ? String(localized: "Évolution · sites \(model.selectedFilter.label), opérationnels et projetés")
            : String(localized: "Évolution · sites \(model.selectedFilter.label) opérationnels")
    }

    /// Hausse de l'opérateur choisi (ou du premier affiché) sur la période visible.
    private var changeSummary: (op: ANFROperator, change: Double)? {
        let op = shown.contains(model.selectedOperator) ? model.selectedOperator : series.first?.op
        guard let op, let domain else { return nil }
        let points = model.trendSeries(for: op).filter { domain.contains($0.date) }
        return ANFRStatsViewModel.change(of: points).map { (op, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            header
            operatorToggles
            ANFRTrendChart(
                series: series,
                domain: domain,
                selection: $selection,
                animate: false,
                drawKey: "full",
                isExpanded: true
            )
            .modifier(ANFRPinchZoom(onChange: zoom(scale:anchor:), onEnd: { pinchBase = nil }))
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("anfr.stats.fullscreen.chart")
            footer
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.bg.ignoresSafeArea())
        .accessibilityAction(.escape) { onClose() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.sm2) {
                closeButton
                titleStack
                Spacer(minLength: SQSpace.sm)
                rangePicker.frame(width: 260)
            }
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm2) {
                    closeButton
                    titleStack
                }
                rangePicker
            }
        }
    }

    private var closeButton: some View {
        MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "anfr.stats.fullscreen.close") { onClose() }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
                .fixedSize(horizontal: false, vertical: true)
            Text("Observatoire ANFR · relevés hebdomadaires")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private var rangePicker: some View {
        MapSegmented(
            selection: Binding(get: { range }, set: { value in
                range = value
                zoomDomain = nil
                selection = nil
            }),
            options: [
                (.oneYear, String(localized: "1 an")),
                (.threeYears, String(localized: "3 ans")),
                (.all, String(localized: "Tout"))
            ],
            identifier: "anfr.stats.fullscreen.range"
        )
    }

    /// Pastilles à bascule : chaque opérateur s'affiche ou se masque, il en
    /// reste toujours un.
    private var operatorToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(ANFROperator.allCases) { op in
                    let on = shown.contains(op)
                    SQChip(
                        label: op.label, isSelected: on, selectedSystemImage: "checkmark", dot: op.color,
                        selectedFill: SQColor.label, selectedInk: SQColor.onInk,
                        spokenValue: on ? "Affiché" : "Masqué"
                    ) {
                        if on {
                            guard shown.count > 1 else { Haptics.error(); return }
                            shown.remove(op)
                        } else {
                            shown.insert(op)
                        }
                    }
                }
                Text("Touche un opérateur pour l’afficher ou le masquer")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.leading, SQSpace.xs)
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.sm) {
                hint.fixedSize()
                Spacer(minLength: SQSpace.sm)
                changePill
            }
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                hint.fixedSize(horizontal: false, vertical: true)
                changePill
            }
        }
    }

    private var hint: some View {
        Text("Glisse le doigt pour lire chaque relevé · pince pour zoomer sur une période")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
    }

    @ViewBuilder private var changePill: some View {
        if let summary = changeSummary {
            let percent = summary.change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
            ANFRChangePill(change: summary.change, suffix: String(localized: "\(percent) pour \(summary.op.label) sur la période"))
        }
    }

    /// Pincement : resserre ou élargit la période autour des doigts (au centre
    /// avant iOS 17), sans sortir des relevés ni descendre sous deux mois.
    private func zoom(scale: Double, anchor: Double) {
        guard let full = fullDomain, let current = domain else { return }
        let base = pinchBase ?? current
        if pinchBase == nil { pinchBase = base }
        let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
        let baseSpan = base.upperBound.timeIntervalSince(base.lowerBound)
        let span = min(max(baseSpan / max(scale, 0.05), 60 * 86_400), fullSpan)
        let a = min(max(anchor, 0), 1)
        let anchorDate = base.lowerBound.addingTimeInterval(baseSpan * a)
        var lower = anchorDate.addingTimeInterval(-span * a)
        if lower < full.lowerBound { lower = full.lowerBound }
        var upper = lower.addingTimeInterval(span)
        if upper > full.upperBound {
            upper = full.upperBound
            lower = upper.addingTimeInterval(-span)
        }
        zoomDomain = lower...upper
    }
}

/// Hôte UIKit du plein écran. L'Info.plist garde l'iPhone en portrait et un
/// `fullScreenCover` SwiftUI s'y tient : seul un contrôleur présenté par UIKit
/// peut déclarer le paysage, le temps de sa présentation.
private final class ANFRLandscapeHost: UIHostingController<AnyView> {
    private static weak var current: ANFRLandscapeHost?
    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        Self.isPhone ? .allButUpsideDown : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        Self.isPhone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }

    static func present<Content: View>(_ content: Content) {
        guard current == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = (scene.keyWindow ?? scene.windows.first)?.rootViewController else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let host = ANFRLandscapeHost(rootView: AnyView(content))
        host.modalPresentationStyle = .fullScreen
        current = host
        SQOrientation.allowLandscape(true)
        presenter.present(host, animated: true)
    }

    static func dismissCurrent() {
        current?.dismiss(animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard Self.isPhone, let scene = view.window?.windowScene,
              !scene.interfaceOrientation.isLandscape else { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { SQOrientation.allowLandscape(false) }
    }
}

/// Geste de pincement : la position des doigts n'est connue qu'à partir d'iOS 17.
private struct ANFRPinchZoom: ViewModifier {
    let onChange: (Double, Double) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.simultaneousGesture(
                MagnifyGesture()
                    .onChanged { onChange($0.magnification, $0.startAnchor.x) }
                    .onEnded { _ in onEnd() }
            )
        } else {
            content.simultaneousGesture(
                MagnificationGesture()
                    .onChanged { onChange(Double($0), 0.5) }
                    .onEnded { _ in onEnd() }
            )
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
