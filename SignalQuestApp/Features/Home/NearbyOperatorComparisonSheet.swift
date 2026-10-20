import SwiftUI

/// Comparaison des opérateurs autour d'un point, dans le même rayon pour les trois onglets :
/// débit et signal médians mesurés par la communauté (ZM-1), sites du registre officiel des
/// antennes du pays. Un opérateur mesuré ouvre sa fiche détaillée. Lecture seule.
struct NearbyOperatorComparisonSheet: View {
    /// Onglets du sélecteur. Les deux premiers suivent `NearbyOperatorMetric`, qui sert aussi à CarPlay.
    enum Tab: Equatable {
        case download
        case signal
        case antennas
    }

    let latitude: Double
    let longitude: Double
    /// Point choisi sur la carte plutôt que ta position.
    var isChosenPoint = false
    /// Ouverte depuis la carte : rayon montré sur la carte (mètres ; `true` = rayon arrêté,
    /// `false` = curseur en cours de glissé), et carte utilisable derrière la feuille.
    var onRadiusChange: ((Double, Bool) -> Void)?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tab: Tab
    @State private var detail: ZoneMetricsOperator?
    @StateObject private var zone: ZoneCompareModel
    @StateObject private var metrics = ZoneMetricsModel()

    /// `radiusMeters` : rayon de départ, commun aux trois onglets (1 km depuis l'Accueil, comme
    /// sa carte de classement) ; sans valeur, celui du comparateur (50 km).
    init(metric: NearbyOperatorMetric, latitude: Double, longitude: Double, radiusMeters: Int? = nil,
         startsOnAntennas: Bool = false, isChosenPoint: Bool = false,
         onRadiusChange: ((Double, Bool) -> Void)? = nil) {
        _tab = State(initialValue: startsOnAntennas ? .antennas : (metric == .signal ? .signal : .download))
        self.latitude = latitude
        self.longitude = longitude
        self.isChosenPoint = isChosenPoint
        self.onRadiusChange = onRadiusChange
        let model = ZoneCompareModel(latitude: latitude, longitude: longitude)
        if let radiusMeters { model.radius = ANFRZoneRadius(kilometers: Int((Double(radiusMeters) / 1000).rounded())) }
        _zone = StateObject(wrappedValue: model)
    }

    private var metric: NearbyOperatorMetric { tab == .signal ? .signal : .download }

    /// Une requête par onglet, point, rayon, période, détail de bandes et relance ; changer de clé annule la précédente.
    private struct TaskKey: Equatable {
        let tab: Tab
        let latitude: Double
        let longitude: Double
        let radius: ANFRZoneRadius
        let period: ZoneMetricsPeriod
        let bands: Bool
        let reload: Int
    }

    private var taskKey: TaskKey {
        TaskKey(tab: tab, latitude: latitude, longitude: longitude, radius: zone.radius, period: metrics.period,
                bands: zone.wantsBands, reload: zone.reloadToken &+ metrics.reloadToken)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                metricPicker
                ZoneRadiusPicker(model: zone) { kilometers in
                    onRadiusChange?(Double(kilometers) * 1000, false)
                }
                if tab == .antennas {
                    ZoneAntennasSection(model: zone)
                } else {
                    ZoneMetricsSection(model: metrics, marketEntry: zone.marketEntry, metric: metric) { detail = $0 }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .presentationDetents([.medium, .large])
        .modifier(MapBackgroundInteraction(enabled: onRadiusChange != nil))
        .sqSheet()
        .sheet(item: $detail) { item in
            ZoneOperatorDetailSheet(
                item: item, metric: metric, period: metrics.period, radiusKm: zone.radius.kilometers,
                isChosenPoint: isChosenPoint,
                color: zone.marketEntry?.operatorColor(forKey: item.key) ?? SQBrand.operatorColor(item.label)
            )
        }
        .task(id: taskKey) {
            zone.attach(service: services.anfr, markets: services.markets)
            zone.move(latitude: latitude, longitude: longitude)
            if tab == .antennas {
                await zone.load()
            } else {
                let market = await zone.marketCode()
                guard !Task.isCancelled else { return }
                await metrics.load(metric: metric, radius: zone.radius, latitude: latitude, longitude: longitude,
                                   market: market, service: services.anfr, ranking: services.nearbyQuality)
            }
        }
        .onAppear { reportRadius() }
        .onChangeCompat(of: zone.radius) { _, _ in reportRadius() }
    }

    /// Le cercle de la carte suit le rayon commun aux trois onglets.
    private func reportRadius() {
        onRadiusChange?(Double(zone.radius.kilometers) * 1000, true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(kickerText).sqKicker()
                Text("Comparer les opérateurs")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "home.compare.close") { dismiss() }
        }
    }

    private var kickerText: String {
        isChosenPoint ? String(localized: "Autour de ce point") : String(localized: "Autour de toi")
    }

    /// Débit, signal ou antennes : trois parts égales sur la piste segmentée Halo.
    private var metricPicker: some View {
        // Aux très grandes tailles de texte, trois parts égales coupent les mots : une pile verticale.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        return layout {
            segment(.download, label: "Débit")
            segment(.signal, label: "Signal")
            segment(.antennas, label: "Antennes")
        }
        .padding(SQSpace.xs)
        .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func segment(_ value: Tab, label: LocalizedStringKey) -> some View {
        let isSelected = tab == value
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { tab = value }
        } label: {
            Text(label)
                .font(SQType.chip)
                .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SQColor.segThumb)
                            .shadow(color: SQColor.shadowSoft, radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("home.compare.metric.\(value == .download ? "download" : value == .signal ? "signal" : "antennas")")
    }
}

// MARK: - Rayon commun

/// Curseur du rayon, partagé par les trois onglets : on compare toujours la même zone.
private struct ZoneRadiusPicker: View {
    @ObservedObject var model: ZoneCompareModel
    /// Rayon en cours de glissé, pour que la carte redessine son cercle sans attendre le relâcher.
    var onRadiusPreview: (Int) -> Void = { _ in }
    /// Position du curseur pendant un glissé ; `nil` = suit le rayon du modèle.
    @State private var sliderIndex: Double?
    @State private var isDraggingRadius = false

    var body: some View {
        let steps = ANFRZoneRadius.steps
        let modelIndex = Double(steps.firstIndex(of: model.radius.kilometers) ?? 0)
        let shownKilometers = steps[min(max(Int(sliderIndex ?? modelIndex), 0), steps.count - 1)]
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Rayon · \(shownKilometers)\u{00A0}km")
                .font(SQType.caption(.semibold))
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            // Le rayon part au relâchement : un glissé ne lance pas une requête par marche.
            Slider(
                value: Binding(get: { sliderIndex ?? modelIndex }, set: { sliderIndex = $0 }),
                in: 0...Double(steps.count - 1),
                step: 1
            ) { editing in
                isDraggingRadius = editing
                if !editing { commitRadius() }
            }
            .tint(SQColor.accent)
            .frame(minHeight: 44)
            .accessibilityLabel(Text("Rayon"))
            .accessibilityValue(Text(verbatim: "\(shownKilometers)\u{00A0}km"))
            .accessibilityIdentifier("home.compare.radius.slider")
            .onChange(of: sliderIndex) { index in
                if let index { onRadiusPreview(steps[min(max(Int(index), 0), steps.count - 1)]) }
                // VoiceOver ajuste la valeur sans glissé : on l'applique tout de suite.
                if !isDraggingRadius { commitRadius() }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func commitRadius() {
        guard let index = sliderIndex else { return }
        let steps = ANFRZoneRadius.steps
        let radius = ANFRZoneRadius(kilometers: steps[min(max(Int(index), 0), steps.count - 1)])
        sliderIndex = nil
        if model.radius != radius { model.radius = radius }
    }
}

// MARK: - Onglets Débit et Signal (mesures de la communauté, ZM-1)

/// État et chargement des mesures de zone. Une zone déjà vue (même case de grille, même rayon,
/// même métrique, même période) se relit en mémoire. Tant que le serveur ne sert pas la route,
/// l'ancien classement calculé sur les tuiles de la carte (1 km) prend le relais.
@MainActor
final class ZoneMetricsModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(ZoneMetrics)
        /// Route absente du serveur : classement des tuiles, à 1 km, sans fiche détaillée.
        case legacy([OperatorMetricStat], NearbyOperatorMetric)
        case outOfMarket
        case failed
    }

    enum Failure: Equatable {
        case routeMissing
        case outOfMarket
        case failed
    }

    @Published var period: ZoneMetricsPeriod = .default
    @Published private(set) var phase: Phase = .loading
    /// Nouveau rayon, point ou période : les chiffres restent, estompés, jusqu'à la réponse.
    @Published private(set) var isRefreshing = false
    @Published private(set) var reloadToken = 0
    private var cache: [String: ZoneMetrics] = [:]

    func reload() {
        cache.removeAll()
        reloadToken += 1
    }

    /// Un échec d'appel vu par l'écran. `nil` : annulation, jamais affichée comme un échec.
    static func failure(for error: Error) -> Failure? {
        if error.isCancellation { return nil }
        guard let api = error as? APIError, case .http(let status, let code, _, _, _) = api else { return .failed }
        switch (status, code?.uppercased()) {
        case (404, nil), (404, "NOT_FOUND"): return .routeMissing
        case (422, "OUT_OF_MARKET"), (400, "INVALID_MARKET"): return .outOfMarket
        default: return .failed
        }
    }

    static func cacheKey(market: String, metric: NearbyOperatorMetric, period: ZoneMetricsPeriod,
                         radius: ANFRZoneRadius, latitude: Double, longitude: Double) -> String {
        let base = ZoneCompareModel.cacheKey(market: market, radius: radius, latitude: latitude, longitude: longitude, bands: false)
        return "\(base)|\(metric == .signal ? "signal" : "download")|\(period.rawValue)"
    }

    func load(metric: NearbyOperatorMetric, radius: ANFRZoneRadius, latitude: Double, longitude: Double,
              market: String?, service: ANFRServicing, ranking: NearbyNetworkQualityServicing) async {
        guard let market else {
            isRefreshing = false
            phase = .outOfMarket
            return
        }
        let period = self.period
        let key = Self.cacheKey(market: market, metric: metric, period: period, radius: radius,
                                latitude: latitude, longitude: longitude)
        if let hit = cache[key] {
            isRefreshing = false
            phase = .loaded(hit)
            return
        }
        // Même métrique : la liste reste, estompée. Autre métrique : des Mbit/s ne se lisent
        // pas en dBm le temps de la requête, retour au chargement.
        if case .loaded(let shown) = phase, shown.metric == (metric == .signal ? "signal" : "download") {
            isRefreshing = true
        } else {
            phase = .loading
        }
        do {
            let result: ZoneMetrics
            #if DEBUG
            if AppEnvironment.usesDemoData {
                result = ANFRDemoData.zoneMetrics(metric: metric, radius: radius, period: period)
            } else {
                result = try await service.zoneMetrics(latitude: latitude, longitude: longitude, radius: radius,
                                                       market: market, metric: metric, period: period)
            }
            #else
            result = try await service.zoneMetrics(latitude: latitude, longitude: longitude, radius: radius,
                                                   market: market, metric: metric, period: period)
            #endif
            guard !Task.isCancelled else { return }
            cache[key] = result
            isRefreshing = false
            phase = .loaded(result)
        } catch {
            guard !Task.isCancelled, let failure = Self.failure(for: error) else { return }
            isRefreshing = false
            switch failure {
            case .outOfMarket: phase = .outOfMarket
            case .failed: phase = .failed
            case .routeMissing:
                do {
                    let stats = try await ranking.loadOperatorRanking(metric: metric, latitude: latitude,
                                                                      longitude: longitude, maxAge: 90)
                    guard !Task.isCancelled else { return }
                    phase = .legacy(stats, metric)
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failed
                }
            }
        }
    }
}

/// Valeurs et unités d'une mesure de zone : débit dans les unités de l'app, signal en dBm.
private enum ZoneMetricFormat {
    static func value(_ value: Double, metric: NearbyOperatorMetric) -> String {
        metric == .download ? SQUnits.throughputValue(mbps: value) : "\(Int(value.rounded()))"
    }

    static func unit(_ value: Double, metric: NearbyOperatorMetric) -> String {
        metric == .download ? SQUnits.throughputUnit(mbps: value) : "dBm"
    }

    static func text(_ value: Double, metric: NearbyOperatorMetric) -> String {
        "\(Self.value(value, metric: metric))\u{00A0}\(unit(value, metric: metric))"
    }

    /// Remplissage de barre : part du meilleur débit de la zone ; échelle absolue −120…−60 dBm
    /// pour le signal (plus proche de 0 = mieux).
    static func fraction(_ value: Double, best: Double, metric: NearbyOperatorMetric) -> Double {
        switch metric {
        case .download: return best > 0 ? min(max(value / best, 0), 1) : 0
        case .signal: return min(1, max(0, (value + 120) / 60))
        }
    }

    /// Teinte d'un palier du contrat quality-scale (débit ou signal).
    static func tierColor(_ tier: String, metric: NearbyOperatorMetric) -> Color {
        if metric == .download, let level = SQQualityScale.Throughput.allCases.first(where: { $0.contractKey == tier }) {
            return Color(hex: level.hex)
        }
        if metric == .signal, let level = SQQualityScale.Signal.allCases.first(where: { $0.contractKey == tier }) {
            return Color(hex: level.hex)
        }
        return SQColor.labelSecondary
    }

    static func count(_ count: Int) -> String {
        String(localized: "\(count) mesure")
    }

    /// Part (0…1) au format de la langue : « 52 % », « 52% ».
    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Contenu des onglets Débit et Signal : période, phrase de méthode, une rangée par opérateur.
private struct ZoneMetricsSection: View {
    @ObservedObject var model: ZoneMetricsModel
    let marketEntry: MarketRegistryEntry?
    let metric: NearbyOperatorMetric
    let onSelect: (ZoneMetricsOperator) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            switch model.phase {
            case .loading:
                periodPicker
                SQSpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.top, SQSpace.xl)
            case .loaded(let data):
                periodPicker
                loadedContent(data)
            case .legacy(let stats, let shownMetric):
                ZoneLegacyRanking(stats: stats, metric: shownMetric)
            case .outOfMarket:
                EmptyStateView(
                    title: "Zone non couverte",
                    message: "Cette position n’est dans aucun pays suivi par SignalQuest.",
                    systemImage: "map"
                )
                .padding(.top, SQSpace.lg)
            case .failed:
                periodPicker
                ErrorStateView(title: "Chargement impossible", message: "Impossible de charger les mesures. Réessaie.") {
                    model.reload()
                }
            }
        }
        .onChangeCompat(of: model.phase) { _, phase in
            guard case .loaded = phase, !animate else { return }
            withAnimation(SQMotion.resolve(.easeOut(duration: 0.55), reduceMotion)) { animate = true }
        }
        .onAppear {
            if case .loaded = model.phase { animate = true }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 3) {
            ForEach(ZoneMetricsPeriod.allCases) { period in
                let isSelected = model.period == period
                Button {
                    guard !isSelected else { return }
                    Haptics.selection()
                    model.period = period
                } label: {
                    Text(verbatim: period.label)
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SQColor.segThumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("home.compare.period.\(period.rawValue)")
            }
        }
        .padding(.horizontal, SQSpace.xs)
        .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Période"))
    }

    @ViewBuilder
    private func loadedContent(_ data: ZoneMetrics) -> some View {
        let rows = data.ranked
        let best = rows.compactMap(\.median).max() ?? 1
        Text(verbatim: intro(data))
            .font(SQType.callout)
            .foregroundStyle(SQColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        if data.totalSamples == 0 {
            EmptyStateView(
                title: "Pas encore de comparaison",
                message: "Aucune mesure d’opérateur partagée dans ce rayon sur cette période. Élargis le rayon ou la période.",
                systemImage: "chart.bar.xaxis"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(SQColor.separator) }
                    ZoneMetricsRow(
                        item: item, rank: item.hasMeasurements ? index + 1 : nil, metric: metric,
                        fraction: item.median.map { ZoneMetricFormat.fraction($0, best: best, metric: metric) } ?? 0,
                        color: marketEntry?.operatorColor(forKey: item.key) ?? SQBrand.operatorColor(item.label),
                        animate: animate
                    ) { onSelect(item) }
                }
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .opacity(model.isRefreshing ? 0.5 : 1)
        }
        Text(verbatim: footer(data))
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func intro(_ data: ZoneMetrics) -> String {
        let radius = data.radiusKm > 0 ? data.radiusKm : 1
        let period = ZoneMetricsPeriod(rawValue: data.period)?.phrase ?? model.period.phrase
        switch metric {
        case .download:
            return String(localized: "Débit médian en réception, mesuré par la communauté à moins de \(radius) km, \(period).")
        case .signal:
            return String(localized: "Signal 4G et 5G médian capté, mesuré par la communauté à moins de \(radius) km, \(period).")
        }
    }

    private func footer(_ data: ZoneMetrics) -> String {
        let method = metric == .signal
            ? String(localized: "Une mesure de signal = la médiane d’un membre sur environ 100 m pour une journée : un trajet répété ne compte qu’une fois par jour.")
            : String(localized: "Une mesure de débit = un test.")
        return String(localized: "\(data.totalSamples) mesure au total") + ". " + method + " "
            + String(localized: "Touche un opérateur pour le détail.")
    }
}

/// Rangée d'opérateur : rang, nom, médiane et barre. Un opérateur sans mesure reste listé,
/// estompé, sans fiche.
private struct ZoneMetricsRow: View {
    let item: ZoneMetricsOperator
    let rank: Int?
    let metric: NearbyOperatorMetric
    let fraction: Double
    let color: Color
    let animate: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm) {
                    Text(verbatim: rank.map { "\($0)" } ?? "–")
                        .font(SQType.caption(.bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 16)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 4, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.label)
                            .font(SQType.callout(.bold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(2)
                        Text(verbatim: detailText)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer(minLength: SQSpace.sm)
                    if let median = item.median, item.hasMeasurements {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: ZoneMetricFormat.value(median, metric: metric))
                                .font(SQFont.display(20, .bold))
                                .monospacedDigit()
                                .foregroundStyle(SQColor.label)
                            Text(verbatim: ZoneMetricFormat.unit(median, metric: metric))
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(SQType.caption(.semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                }
                if item.hasMeasurements {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SQColor.chip)
                            Capsule().fill(color)
                                .frame(width: animate ? max(6, geo.size.width * CGFloat(fraction)) : 0)
                        }
                    }
                    .frame(height: 6)
                    .padding(.leading, 28)
                    .accessibilityHidden(true)
                }
            }
            .padding(.vertical, SQSpace.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.hasMeasurements)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityHint(item.hasMeasurements ? Text("Ouvre le détail de l’opérateur") : Text(verbatim: ""))
        .accessibilityAddTraits(item.hasMeasurements ? .isButton : [])
        .accessibilityIdentifier("home.compare.operator.\(item.key)")
    }

    private var detailText: String {
        guard item.hasMeasurements else { return String(localized: "Pas de mesure dans ce rayon") }
        var parts = [ZoneMetricFormat.count(item.sampleCount)]
        if let share = item.share5G, share > 0 {
            parts.append("5G " + ZoneMetricFormat.percent(share))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        guard let median = item.median, item.hasMeasurements else {
            return String(localized: "\(item.label), pas de mesure dans ce rayon.")
        }
        let position = rank.map { "\($0). " } ?? ""
        return position + "\(item.label), \(ZoneMetricFormat.text(median, metric: metric)), \(detailText)."
    }
}

/// Ancien classement (tuiles de la carte, 1 km), le temps que le serveur serve la route ZM-1.
private struct ZoneLegacyRanking: View {
    let stats: [OperatorMetricStat]
    let metric: NearbyOperatorMetric

    var body: some View {
        if stats.isEmpty {
            EmptyStateView(
                title: "Pas encore de comparaison",
                message: "Aucune mesure d'opérateur partagée dans ce rayon pour l'instant.",
                systemImage: "chart.bar.xaxis"
            )
            .padding(.top, SQSpace.lg)
        } else {
            let best = Double(stats.map(\.value).max() ?? 1)
            VStack(alignment: .leading, spacing: SQSpace.md) {
                Text(metric == .download
                     ? LocalizedStringKey("Débit médian en réception, mesuré par la communauté à moins de 1 km, sur tout l’historique.")
                     : LocalizedStringKey("Signal médian capté, mesuré par la communauté à moins de 1 km, sur tout l’historique."))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                        if index > 0 { Divider().overlay(SQColor.separator) }
                        ZoneMetricsRow(
                            item: ZoneMetricsOperator(key: stat.operatorName, label: stat.operatorName,
                                                      sampleCount: stat.sampleCount, median: Double(stat.value)),
                            rank: index + 1, metric: metric,
                            fraction: ZoneMetricFormat.fraction(Double(stat.value), best: best, metric: metric),
                            color: SQBrand.operatorColor(stat.operatorName), animate: true
                        ) {}
                        .disabled(true)
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
        }
    }
}

// MARK: - Fiche d'un opérateur

/// Tout ce que la zone sait d'un opérateur : médiane et écart, répartition par palier, par
/// technologie, mesures secondaires et fraîcheur.
private struct ZoneOperatorDetailSheet: View {
    let item: ZoneMetricsOperator
    let metric: NearbyOperatorMetric
    let period: ZoneMetricsPeriod
    let radiusKm: Int
    let isChosenPoint: Bool
    let color: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                headline
                if !item.distribution.isEmpty { ZoneTierDistribution(tiers: item.distribution, metric: metric) }
                if !item.byTechnology.isEmpty { technologies }
                secondary
                freshness
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .accessibilityIdentifier("home.compare.detail")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(verbatim: kicker).sqKicker()
                HStack(spacing: SQSpace.sm) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 4, height: 22)
                        .accessibilityHidden(true)
                    Text(verbatim: item.label)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .sqHeader()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "home.compare.detail.close") { dismiss() }
        }
    }

    private var kicker: String {
        let what = metric == .signal ? String(localized: "Signal") : String(localized: "Débit")
        return "\(what) · \(radiusKm)\u{00A0}km · \(period.label)"
    }

    @ViewBuilder
    private var headline: some View {
        if let median = item.median {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Médiane")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Text(verbatim: ZoneMetricFormat.value(median, metric: metric))
                        .font(SQFont.display(36, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: ZoneMetricFormat.unit(median, metric: metric))
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let low = item.p25, let high = item.p75 {
                    Text(verbatim: String(localized: "La moitié des mesures entre \(ZoneMetricFormat.text(low, metric: metric)) et \(ZoneMetricFormat.text(high, metric: metric)).")) 
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Moins de 3 mesures : pas encore d’écart à montrer.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var technologies: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Par technologie").sqKicker()
            VStack(spacing: 0) {
                ForEach(Array(item.byTechnology.enumerated()), id: \.element.id) { index, tech in
                    if index > 0 { Divider().overlay(SQColor.separator) }
                    HStack(spacing: SQSpace.sm) {
                        Circle()
                            .fill(SQNetworkColors.generationChartColor(tech.tech))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(verbatim: tech.tech)
                            .font(SQType.callout(.bold))
                            .foregroundStyle(SQColor.label)
                        Text(verbatim: ZoneMetricFormat.count(tech.sampleCount))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        Spacer(minLength: SQSpace.sm)
                        Text(verbatim: tech.median.map { ZoneMetricFormat.text($0, metric: metric) } ?? String(localized: "Trop peu de mesures"))
                            .font(tech.median == nil ? SQType.caption : SQType.callout(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tech.median == nil ? SQColor.labelSecondary : SQColor.label)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            if let share = item.share5G {
                Text(verbatim: String(localized: "\(ZoneMetricFormat.percent(share)) des mesures en 5G."))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    @ViewBuilder
    private var secondary: some View {
        let rows: [(String, String)] = metric == .download
            ? [(String(localized: "Envoi médian"), item.uploadMedianMbps.map { ZoneMetricFormat.text($0, metric: .download) }),
               (String(localized: "Latence médiane"), item.pingMedianMs.map { "\(Int($0.rounded()))\u{00A0}ms" })]
                .compactMap { row in row.1.map { (row.0, $0) } }
            : [(String(localized: "RSRQ médian"), item.rsrqMedian.map { "\(Self.decimal($0))\u{00A0}dB" }),
               (String(localized: "SINR médian"), item.sinrMedian.map { "\(Self.decimal($0))\u{00A0}dB" })]
                .compactMap { row in row.1.map { (row.0, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Autres mesures").sqKicker()
                ZoneFactsList(rows: rows)
            }
        }
    }

    private var freshness: some View {
        var rows: [(String, String)] = []
        if let latest = item.latestAt {
            rows.append((String(localized: "Dernière mesure"), latest.formatted(.relative(presentation: .named))))
        }
        rows.append((String(localized: "Sur les 30 derniers jours"), ZoneMetricFormat.count(item.samples30d)))
        rows.append((String(localized: "Membres contributeurs"), item.contributors.formatted()))
        if metric == .signal, item.rawCount > item.sampleCount {
            rows.append((String(localized: "Relevés bruts"), item.rawCount.formatted()))
        }
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Fraîcheur").sqKicker()
            ZoneFactsList(rows: rows)
            Text(metric == .signal
                 ? LocalizedStringKey("Une mesure de signal = la médiane d’un membre sur environ 100 m pour une journée : un trajet répété ne compte qu’une fois par jour.")
                 : LocalizedStringKey("Une mesure de débit = un test."))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// Liste libellé / valeur, une ligne de 44 pt par fait.
private struct ZoneFactsList: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(SQColor.separator) }
                HStack {
                    Text(verbatim: row.0)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.ink2)
                    Spacer(minLength: SQSpace.sm)
                    Text(verbatim: row.1)
                        .font(SQType.callout(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.trailing)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }
}

/// Répartition des mesures par palier : une barre empilée aux teintes du contrat, doublée
/// d'une légende chiffrée (la couleur ne porte jamais seule l'information).
private struct ZoneTierDistribution: View {
    let tiers: [ZoneMetricsTier]
    let metric: NearbyOperatorMetric

    var body: some View {
        let total = max(tiers.reduce(0) { $0 + $1.count }, 1)
        // Du meilleur palier au moins bon, comme la lecture d'un classement.
        let ordered = metric == .download ? Array(tiers.reversed()) : tiers
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Répartition").sqKicker()
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(ordered.filter { $0.count > 0 }, id: \.tier) { tier in
                        Rectangle()
                            .fill(ZoneMetricFormat.tierColor(tier.tier, metric: metric))
                            .frame(width: max(2, (geo.size.width - 2 * CGFloat(ordered.count)) * CGFloat(tier.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            VStack(spacing: SQSpace.xs) {
                ForEach(ordered, id: \.tier) { tier in
                    HStack(spacing: SQSpace.sm) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(ZoneMetricFormat.tierColor(tier.tier, metric: metric))
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        Text(verbatim: tier.label)
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: SQSpace.sm)
                        Text(verbatim: ZoneMetricFormat.count(tier.count))
                            .font(SQType.caption)
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(verbatim: ZoneMetricFormat.percent(Double(tier.count) / Double(total)))
                            .font(SQType.callout(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tier.count > 0 ? SQColor.label : SQColor.labelSecondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}


// MARK: - Onglet Antennes (sites du registre officiel par opérateur)

/// État et chargement de l’onglet Antennes, et rayon commun aux trois onglets. Le marché vient
/// de la position (registre) ; le serveur dit lui-même quels pays n’ont pas de registre
/// d’antennes. Une zone déjà vue (même case de grille, même rayon) se relit en mémoire.
@MainActor
final class ZoneCompareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(ANFRZoneCompare)
        case noAntennaData
        case outOfMarket
        case failed
    }

    enum Resolution: Equatable {
        case supported(String)
        case noAntennaData
        case outOfMarket
    }

    private(set) var latitude: Double
    private(set) var longitude: Double
    @Published var radius: ANFRZoneRadius = .default
    @Published var wantsBands = false
    @Published private(set) var reloadToken = 0
    @Published private(set) var phase: Phase = .loading
    /// Nouveau point ou nouveau rayon : les chiffres affichés restent, estompés, jusqu'à la réponse.
    @Published private(set) var isRefreshing = false
    @Published private(set) var bandsLoading = false
    @Published private(set) var bandsFailed = false
    @Published private(set) var marketEntry: MarketRegistryEntry?

    private var service: ANFRServicing?
    private var markets: MarketRegistryServicing?
    private var resolution: Resolution?
    private var cache: [String: ANFRZoneCompare] = [:]
    /// Rayon et point des chiffres affichés : le détail par bande se charge sans vider la liste tant qu’il les partage.
    private var shownRadius: ANFRZoneRadius?
    private var shownPoint: [Double]?

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    func attach(service: ANFRServicing, markets: MarketRegistryServicing) {
        guard self.service == nil else { return }
        self.service = service
        self.markets = markets
    }

    func reload() {
        cache.removeAll()
        resolution = nil
        reloadToken += 1
    }

    /// Point déplacé sur la carte. Le marché se relit : le point a pu changer de territoire.
    func move(latitude: Double, longitude: Double) {
        guard latitude != self.latitude || longitude != self.longitude else { return }
        self.latitude = latitude
        self.longitude = longitude
        resolution = nil
    }

    /// Code de marché du point (registre), résolu une fois par point ; `nil` hors de tout marché.
    func marketCode() async -> String? {
        guard let markets else { return nil }
        if resolution == nil {
            let resolved = await resolveMarket(markets)
            guard !Task.isCancelled else { return nil }
            resolution = resolved
        }
        if case .supported(let code) = resolution { return code }
        return nil
    }

    // MARK: Règles pures (testées)

    /// Un échec d’appel vu par l’écran. `nil` : annulation, jamais affichée comme un échec.
    static func phase(for error: Error) -> Phase? {
        if error.isCancellation { return nil }
        guard let api = error as? APIError, case .http(let status, let code, _, _, _) = api else { return .failed }
        switch (status, code?.uppercased()) {
        case (422, "MARKET_NO_ANTENNA_DATA"): return .noAntennaData
        case (422, "OUT_OF_MARKET"): return .outOfMarket
        default: return .failed
        }
    }

    /// Pour chaque opérateur, les générations où il a le plus de sites de la zone (ex æquo compris ;
    /// une génération que personne n'émet n'a pas de meilleur).
    static func leaders(_ rows: [ANFRZoneOperator]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for label in ["2G", "3G", "4G", "5G"] {
            let counts = rows.map { row in (row.key, row.generations.ordered.first { $0.label == label }?.count ?? 0) }
            guard let best = counts.map(\.1).max(), best > 0 else { continue }
            for (key, count) in counts where count == best { result[key, default: []].insert(label) }
        }
        return result
    }

    /// Même case de grille serveur et même rayon : même réponse.
    static func cacheKey(market: String, radius: ANFRZoneRadius, latitude: Double, longitude: Double, bands: Bool) -> String {
        let cellLatitude = Int((latitude / radius.gridDegrees).rounded(.down))
        let cellLongitude = Int((longitude / radius.gridDegrees).rounded(.down))
        return "\(market)|\(radius.kilometers)|\(cellLatitude)|\(cellLongitude)|\(bands ? "b" : "-")"
    }

    // MARK: Chargement

    func load() async {
        guard let service, let markets else { return }
        let resolved: Resolution
        if let known = resolution {
            resolved = known
        } else {
            resolved = await resolveMarket(markets)
            guard !Task.isCancelled else { return }
            resolution = resolved
        }
        let market: String
        switch resolved {
        case .noAntennaData: isRefreshing = false; phase = .noAntennaData; return
        case .outOfMarket: isRefreshing = false; phase = .outOfMarket; return
        case .supported(let code): market = code
        }

        let radius = self.radius
        let bands = wantsBands
        // Le détail par bande répond aussi à la liste simple : on le relit pour les deux.
        let detailKey = Self.cacheKey(market: market, radius: radius, latitude: latitude, longitude: longitude, bands: true)
        let plainKey = Self.cacheKey(market: market, radius: radius, latitude: latitude, longitude: longitude, bands: false)
        if let hit = cache[detailKey] ?? (bands ? nil : cache[plainKey]) {
            show(hit, radius: radius)
            return
        }

        // Seul le détail par bande manque : la liste reste nette. Autre point ou autre rayon :
        // la liste reste aussi, estompée, plutôt qu'un écran de chargement à chaque geste.
        let keepsList = bands && shownRadius == radius && shownPoint == [latitude, longitude] && showsList
        if keepsList {
            bandsLoading = true
            bandsFailed = false
        } else if showsList {
            bandsLoading = false
            isRefreshing = true
        } else {
            bandsLoading = false
            phase = .loading
        }
        do {
            let result: ANFRZoneCompare
            #if DEBUG
            if AppEnvironment.usesDemoData {
                result = ANFRDemoData.zoneCompare(radius: radius, includeBands: bands)
            } else {
                result = try await service.zoneCompare(latitude: latitude, longitude: longitude, radius: radius,
                                                       market: market, includeBands: bands)
            }
            #else
            result = try await service.zoneCompare(latitude: latitude, longitude: longitude, radius: radius,
                                                   market: market, includeBands: bands)
            #endif
            guard !Task.isCancelled else { return }
            cache[bands ? detailKey : plainKey] = result
            show(result, radius: radius)
        } catch {
            guard !Task.isCancelled, let failure = Self.phase(for: error) else { return }
            bandsLoading = false
            isRefreshing = false
            if keepsList { bandsFailed = true } else { phase = failure }
        }
    }

    private var showsList: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func show(_ result: ANFRZoneCompare, radius: ANFRZoneRadius) {
        shownRadius = radius
        shownPoint = [latitude, longitude]
        bandsFailed = false
        bandsLoading = false
        isRefreshing = false
        phase = .loaded(result)
    }

    private func resolveMarket(_ markets: MarketRegistryServicing) async -> Resolution {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            marketEntry = await markets.market(forCode: "FR")
            return .supported("FR")
        }
        #endif
        guard let entry = await markets.marketForLocation(latitude: latitude, longitude: longitude) else { return .outOfMarket }
        marketEntry = entry
        guard let code = ANFRZoneMarket.apiCode(forMarket: entry.code) else { return .noAntennaData }
        return .supported(code)
    }
}

/// Contenu de l’onglet Antennes : total de la zone, une rangée par opérateur, pied de relevé.
/// Ce que le registre du pays ne publie pas (générations, bandes, projets) n’est pas montré.
private struct ZoneAntennasSection: View {
    @ObservedObject var model: ZoneCompareModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch model.phase {
        case .loading:
            SQSpinner()
                .frame(maxWidth: .infinity)
                .padding(.top, SQSpace.xl)
                .accessibilityLabel("Chargement des antennes de la zone")
        case .loaded(let data) where !data.capabilities.registryCoversCenter && data.totalActive == 0:
            // Centre en Wallonie et aucun site flamand ou bruxellois dans le cercle : rien à compter.
            EmptyStateView(
                title: "Pas de registre d’antennes",
                message: "La Wallonie ne publie pas de registre officiel des antennes. Signal et Débit restent comparables dans cette zone.",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
            .padding(.top, SQSpace.lg)
        case .loaded(let data):
            loadedContent(data)
        case .noAntennaData:
            // L’onglet reste : Signal et Débit, eux, comparent partout (décision du 20/10).
            EmptyStateView(
                title: "Pas de registre d’antennes",
                message: "Ce pays ne publie pas de registre officiel des antennes. Signal et Débit restent comparables dans cette zone.",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
            .padding(.top, SQSpace.lg)
        case .outOfMarket:
            EmptyStateView(
                title: "Zone non couverte",
                message: "Cette position n’est dans aucun pays suivi par SignalQuest.",
                systemImage: "map"
            )
            .padding(.top, SQSpace.lg)
        case .failed:
            ErrorStateView(title: "Chargement impossible", message: "Impossible de charger les antennes de la zone. Réessaie.") {
                model.reload()
            }
        }
    }

    private func loadedContent(_ data: ANFRZoneCompare) -> some View {
        let rows = data.operators.filter { $0.key.uppercased() != "ALL" }
        let capabilities = data.capabilities
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            if !capabilities.registryCoversCenter {
                Text("La Wallonie ne publie pas de registre : seuls les sites de Flandre et de Bruxelles sont comptés.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            summary(data)
            if rows.isEmpty {
                EmptyStateView(
                    title: "Pas encore de comparaison",
                    message: "Aucun opérateur à comparer dans ce rayon pour l’instant.",
                    systemImage: "chart.bar.xaxis"
                )
            } else {
                let leaders = capabilities.generations ? ZoneCompareModel.leaders(rows) : [:]
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(SQColor.separator) }
                        operatorRow(item, leads: leaders[item.key] ?? [], capabilities: capabilities)
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .opacity(model.isRefreshing ? 0.5 : 1)
                if capabilities.generations {
                    Text("Chaque colonne compte les sites qui émettent dans la génération ; un site peut compter dans plusieurs. Encadré : l’opérateur qui en a le plus.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if capabilities.bands {
                    bandsDisclosure(rows, data: data)
                }
            }
            footer(data)
        }
    }

    // MARK: Total de la zone

    private func summary(_ data: ANFRZoneCompare) -> some View {
        let radius = data.radiusKm > 0 ? data.radiusKm : model.radius.kilometers
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Text("Sites en service dans \(radius) km")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.ink2)
                if model.isRefreshing { SQSpinner() }
            }
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: data.totalActive.formatted())
                    .font(SQFont.display(32, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if data.capabilities.planned && data.totalPlanned > 0 {
                    Text("+ \(data.totalPlanned.formatted()) en projet")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if data.capabilities.generations {
                GenerationCountsGrid(counts: data.totalByGeneration.ordered)
                    .opacity(model.isRefreshing ? 0.5 : 1)
                Text("Un site qui émet en 4G et en 5G ne compte qu’une fois.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryAccessibility(data, radius: radius))
    }

    private func summaryAccessibility(_ data: ANFRZoneCompare, radius: Int) -> String {
        var parts = [String(localized: "Sites en service dans \(radius) km : \(data.totalActive)")]
        if data.capabilities.planned { parts.append(String(localized: "en projet : \(data.totalPlanned)")) }
        if data.capabilities.generations {
            parts.append(data.totalByGeneration.ordered.map { "\($0.label) \($0.count)" }.joined(separator: ", "))
            parts.append(String(localized: "Un site qui émet en 4G et en 5G ne compte qu’une fois."))
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Rangée d’opérateur

    private func operatorRow(_ item: ANFRZoneOperator, leads: Set<String>, capabilities: ANFRZoneCapabilities) -> some View {
        let name = MarketRegistryEntry.operatorLabel(item.key, in: model.marketEntry)
        let color = model.marketEntry?.operatorColor(forKey: item.key) ?? SQBrand.operatorColor(item.key)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 18)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                Spacer(minLength: SQSpace.sm)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: item.active.formatted())
                        .font(SQFont.display(24, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    if capabilities.planned && item.planned > 0 {
                        Text("+ \(item.planned.formatted()) en projet")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            if capabilities.generations {
                GenerationCountsGrid(counts: item.generations.ordered, leaders: leads)
                    .padding(.leading, SQSpace.sm + 4)
            }
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibility(name: name, item: item, leads: leads, capabilities: capabilities))
    }

    private func rowAccessibility(name: String, item: ANFRZoneOperator, leads: Set<String>,
                                  capabilities: ANFRZoneCapabilities) -> String {
        guard capabilities.generations else {
            return capabilities.planned
                ? String(localized: "\(name) : en service \(item.active), en projet \(item.planned).")
                : String(localized: "\(name) : en service \(item.active).")
        }
        let generations = item.generations.ordered.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
        let row = String(localized: "\(name) : en service \(item.active), en projet \(item.planned). \(generations).")
        guard !leads.isEmpty else { return row }
        let best = ["2G", "3G", "4G", "5G"].filter(leads.contains).joined(separator: ", ")
        return row + " " + String(localized: "Le plus de sites en \(best).")
    }

    // MARK: Détail par bande

    @ViewBuilder
    private func bandsDisclosure(_ rows: [ANFRZoneOperator], data: ANFRZoneCompare) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Button {
                Haptics.selection()
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { model.wantsBands.toggle() }
            } label: {
                HStack(spacing: SQSpace.xs2) {
                    Text("Détail par bande")
                        .font(SQType.chip)
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: SQSpace.sm)
                    if model.bandsLoading { SQSpinner() }
                    Image(systemName: "chevron.down")
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .rotationEffect(.degrees(model.wantsBands ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.wantsBands ? Text("Déplié") : Text("Replié"))
            .accessibilityIdentifier("home.compare.bands.toggle")

            if model.wantsBands {
                if model.bandsFailed {
                    HStack {
                        Text("Détail par bande indisponible.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        Spacer(minLength: SQSpace.sm)
                        Button("Réessayer") { model.reload() }
                            .font(SQType.chip)
                            .frame(minHeight: 44)
                    }
                } else if data.hasBands {
                    bandsTable(rows, data: data)
                } else if !model.bandsLoading {
                    Text("Pas de détail par bande pour cette zone.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }

    /// Tableau bandes × opérateurs : une colonne par opérateur, à sa couleur ; la teinte d'une
    /// case se densifie avec le nombre de sites. En grande taille de texte, une liste par bande.
    @ViewBuilder
    private func bandsTable(_ operators: [ANFRZoneOperator], data: ANFRZoneCompare) -> some View {
        let groups = data.bandGroups
        let maxCount = max(data.bandCellMax, 1)
        if groups.isEmpty {
            Text("Aucune bande en service.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        } else if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                ForEach(groups) { group in
                    ForEach(group.rows) { row in
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text(verbatim: row.band.spokenName)
                                .font(SQType.callout(.bold))
                                .foregroundStyle(SQColor.label)
                            ForEach(operators) { item in
                                HStack {
                                    Text(verbatim: shortName(item.key))
                                    Spacer(minLength: SQSpace.sm)
                                    Text(verbatim: row.counts[item.key].map { $0.formatted() } ?? "–")
                                        .monospacedDigit()
                                }
                                .font(SQType.callout)
                                .foregroundStyle(SQColor.label)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: bandRowAccessibility(row, operators: operators)))
                    }
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: SQSpace.xs, verticalSpacing: SQSpace.xs) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(operators) { item in
                        VStack(spacing: SQSpace.xxs) {
                            Capsule()
                                .fill(operatorColor(item.key))
                                .frame(width: 18, height: 3)
                            Text(verbatim: shortName(item.key))
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
                ForEach(groups) { group in
                    GridRow {
                        Text(verbatim: group.generation)
                            .sqKicker()
                            .padding(.top, SQSpace.xs)
                            .gridCellColumns(operators.count + 1)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.rows) { row in
                        GridRow {
                            Text(verbatim: row.band.frequencyLabel)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(1)
                                .fixedSize()
                            ForEach(operators) { item in
                                bandCell(row.counts[item.key], color: operatorColor(item.key), maxCount: maxCount)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: bandRowAccessibility(row, operators: operators)))
                    }
                }
            }
        }
    }

    private func bandCell(_ count: Int?, color: Color, maxCount: Int) -> some View {
        let share = Double(count ?? 0) / Double(maxCount)
        return Text(verbatim: count.map { $0.formatted() } ?? "–")
            .font(SQType.caption(count == nil ? .regular : .semibold))
            .monospacedDigit()
            .foregroundStyle(count == nil ? SQColor.labelSecondary : SQColor.label)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                if count != nil {
                    // De 12 % à 45 % de la couleur de l'opérateur : le nombre reste lisible.
                    RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                        .fill(color.opacity(0.12 + 0.33 * share))
                }
            }
    }

    private func shortName(_ key: String) -> String {
        model.marketEntry?.operatorEntry(forKey: key)?.shortLabel
            ?? MarketRegistryEntry.operatorLabel(key, in: model.marketEntry)
    }

    private func operatorColor(_ key: String) -> Color {
        model.marketEntry?.operatorColor(forKey: key) ?? SQBrand.operatorColor(key)
    }

    private func bandRowAccessibility(_ row: ANFRZoneCompare.BandRow, operators: [ANFRZoneOperator]) -> String {
        let parts = operators.map { item in
            let name = MarketRegistryEntry.operatorLabel(item.key, in: model.marketEntry)
            return row.counts[item.key].map { "\(name) \($0)" } ?? String(localized: "\(name) aucun")
        }
        return "\(row.band.spokenName) : " + parts.joined(separator: ", ")
    }

    // MARK: Pied

    private func footer(_ data: ANFRZoneCompare) -> some View {
        // Date du fichier des sites que le serveur a comparé, sans nommer la source (décision du 19/10).
        let date = ANFRText.date(data.snapshotDate, month: .abbreviated)
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            if let date {
                Text(verbatim: String(localized: "Données du \(date)"))
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            // La définition du serveur nomme ses champs (`active`, `planned`) : l'app dit la même règle
            // à l'utilisateur, propre au registre du pays, sans nommer la source.
            Text(definition(market: data.market))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func definition(market: String) -> LocalizedStringKey {
        switch market.uppercased() {
        case "CA", "CH": return "Sites présents dans le registre officiel du pays."
        case "BE": return "Sites présents dans les registres officiels de Flandre et de Bruxelles ; la Wallonie n’en publie pas."
        default: return "Sites au statut « En service » ; « Techniquement opérationnel » et « Projet approuvé » comptent en projet."
        }
    }
}

/// Les quatre générations en colonnes de même largeur, d'une rangée à l'autre : on compare les
/// opérateurs en lisant de haut en bas. La plus forte valeur de chaque colonne est encadrée.
private struct GenerationCountsGrid: View {
    let counts: [(label: String, count: Int)]
    var leaders: Set<String> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Aux très grandes tailles de texte, deux colonnes : un nombre ne se coupe jamais.
        let columns = Array(repeating: GridItem(.flexible(), spacing: SQSpace.xs, alignment: .leading),
                            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, alignment: .leading, spacing: SQSpace.xs) {
            ForEach(counts, id: \.label) { item in cell(item) }
        }
        .accessibilityHidden(true)
    }

    private func cell(_ item: (label: String, count: Int)) -> some View {
        let color = SQNetworkColors.generationChartColor(item.label)
        let leads = leaders.contains(item.label) && item.count > 0
        let shape = RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SQSpace.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(verbatim: item.label)
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text(verbatim: item.count > 0 ? item.count.formatted() : "–")
                .font(SQFont.display(17, .bold))
                .monospacedDigit()
                .foregroundStyle(item.count > 0 ? SQColor.label : SQColor.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(leads ? color.opacity(0.14) : SQColor.surface))
        .overlay { if leads { shape.strokeBorder(color, lineWidth: 1.5) } }
    }
}

/// Feuille ouverte depuis la carte : la carte reste utilisable derrière à hauteur moyenne
/// (iOS 16.4+), pour glisser l'épingle et voir le cercle pendant qu'on lit les chiffres.
private struct MapBackgroundInteraction: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.presentationBackgroundInteractionCompat()
        } else {
            content
        }
    }
}
