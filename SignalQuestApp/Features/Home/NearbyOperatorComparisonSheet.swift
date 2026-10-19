import SwiftUI

/// Comparaison des opérateurs autour de toi : classement par valeur médiane communautaire,
/// en débit ou en signal, ou nombre de sites ANFR par opérateur (sélecteur en tête).
/// Charge son propre classement. Lecture seule.
struct NearbyOperatorComparisonSheet: View {
    /// Onglets du sélecteur. Les deux premiers suivent `NearbyOperatorMetric`, qui sert aussi à CarPlay.
    enum Tab: Equatable {
        case download
        case signal
        case antennas
    }

    let latitude: Double
    let longitude: Double
    var radiusMeters: Int = 1000
    /// Point choisi sur la carte plutôt que ta position.
    var isChosenPoint = false

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tab: Tab
    @State private var stats: [OperatorMetricStat] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var animate = false
    @StateObject private var zone: ZoneCompareModel

    init(metric: NearbyOperatorMetric, latitude: Double, longitude: Double, radiusMeters: Int = 1000,
         startsOnAntennas: Bool = false, isChosenPoint: Bool = false) {
        _tab = State(initialValue: startsOnAntennas ? .antennas : (metric == .signal ? .signal : .download))
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.isChosenPoint = isChosenPoint
        _zone = StateObject(wrappedValue: ZoneCompareModel(latitude: latitude, longitude: longitude))
    }

    private var metric: NearbyOperatorMetric { tab == .signal ? .signal : .download }

    /// Une requête ANFR par rayon, par détail de bandes et par relance ; changer de clé annule la précédente.
    private struct TaskKey: Equatable {
        let tab: Tab
        let radius: ANFRZoneRadius
        let bands: Bool
        let reload: Int
    }

    private var taskKey: TaskKey {
        TaskKey(tab: tab, radius: zone.radius, bands: zone.wantsBands, reload: zone.reloadToken)
    }

    private var maxValue: Int { max(stats.map(\.value).max() ?? 1, 1) }
    private var totalSamples: Int { stats.reduce(0) { $0 + $1.sampleCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                metricPicker
                if tab == .antennas {
                    ZoneAntennasSection(model: zone)
                } else if !loaded {
                    SQSpinner()
                        .frame(maxWidth: .infinity)
                        .padding(.top, SQSpace.xxl)
                } else if loadFailed {
                    ErrorStateView(title: "Chargement impossible", message: "Impossible de charger les mesures. Réessaie.") {
                        loaded = false
                        Task { await load() }
                    }
                } else if stats.isEmpty {
                    EmptyStateView(
                        title: "Pas encore de comparaison",
                        message: "Aucune mesure d'opérateur partagée dans ce rayon pour l'instant.",
                        systemImage: "chart.bar.xaxis"
                    )
                    .padding(.top, SQSpace.lg)
                } else {
                    intro
                    VStack(spacing: 0) {
                        ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                            if index > 0 { Divider().overlay(SQColor.separator) }
                            operatorRow(stat, rank: index + 1)
                        }
                    }
                    .padding(.horizontal, SQSpace.md)
                    .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    footer
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .task(id: taskKey) {
            if tab == .antennas {
                zone.attach(service: services.anfr, markets: services.markets)
                await zone.load()
            } else {
                await load()
            }
        }
    }

    private func load() async {
        // Changer de métrique ne laisse pas les anciens chiffres sous la nouvelle unité
        // (Mbit/s lus en dBm le temps de la requête) : retour au chargement.
        stats = []
        loaded = false
        loadFailed = false
        animate = false
        if AppEnvironment.usesDemoData {
            // Tours de captures : un classement plausible, sans réseau.
            stats = metric == .download
                ? [.init(operatorName: "Orange", value: 214, sampleCount: 18, detail: nil),
                   .init(operatorName: "SFR", value: 132, sampleCount: 11, detail: nil),
                   .init(operatorName: "Free Mobile", value: 96, sampleCount: 9, detail: nil),
                   .init(operatorName: "Bouygues", value: 71, sampleCount: 7, detail: nil)]
                : [.init(operatorName: "Orange", value: -84, sampleCount: 18, detail: nil),
                   .init(operatorName: "Bouygues", value: -91, sampleCount: 7, detail: nil),
                   .init(operatorName: "SFR", value: -95, sampleCount: 11, detail: nil),
                   .init(operatorName: "Free Mobile", value: -103, sampleCount: 9, detail: nil)]
            loaded = true
            animate = true
            return
        }
        do {
            // Une panne réseau n'est pas une zone sans mesures : elle a son état.
            stats = try await services.nearbyQuality.loadOperatorRanking(
                metric: metric, latitude: latitude, longitude: longitude, maxAge: 90
            )
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
        loaded = true
        animate = false
        withAnimation(SQMotion.resolve(.easeOut(duration: 0.55), reduceMotion)) { animate = true }
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

    /// L’onglet Antennes compte des sites ANFR sur 20 à 100 km : le rayon des mesures communautaires n’y change rien.
    private var kickerText: String {
        let place = isChosenPoint ? String(localized: "Autour de ce point") : String(localized: "Autour de toi")
        return tab == .antennas ? place : "\(place) · \(radiusText)"
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

    private var intro: some View {
        let sentence: String
        switch metric {
        case .download:
            sentence = String(localized: "Débit médian en réception, mesuré par la communauté à moins de \(radiusText), sur tout l’historique.")
        case .signal:
            sentence = String(localized: "Signal médian capté, mesuré par la communauté à moins de \(radiusText), sur tout l’historique.")
        }
        return Text(sentence)
            .font(SQType.callout)
            .foregroundStyle(SQColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func operatorRow(_ stat: OperatorMetricStat, rank: Int) -> some View {
        let color = SQBrand.operatorColor(stat.operatorName)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Text(verbatim: "\(rank)")
                    .font(SQType.caption(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 16)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: stat.operatorName)
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    Text(verbatim: detailText(stat))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: SQSpace.sm)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: valueText(stat))
                        .font(SQFont.display(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: unitText(stat))
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SQColor.chip)
                    Capsule().fill(color)
                        .frame(width: animate ? max(6, geo.size.width * CGFloat(fraction(for: stat))) : 0)
                }
            }
            .frame(height: 6)
            .padding(.leading, 28)
            .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(stat.operatorName), \(valueText(stat)) \(unitText(stat)), \(measurementCountText(stat.sampleCount)).")
    }

    /// Le débit suit les unités de l'app (« Mbit/s » / « Mbps ») comme l'Accueil ;
    /// le signal reste en dBm.
    private func valueText(_ stat: OperatorMetricStat) -> String {
        switch metric {
        case .download: return SQUnits.throughputValue(mbps: Double(stat.value))
        case .signal: return "\(stat.value)"
        }
    }

    private func unitText(_ stat: OperatorMetricStat) -> String {
        switch metric {
        case .download: return SQUnits.throughputUnit(mbps: Double(stat.value))
        case .signal: return metric.unit
        }
    }

    private var footer: some View {
        Text([String(localized: "\(totalSamples) mesure au total · rayon \(radiusText)"),
              String(localized: "tout l’historique")].joined(separator: " · "))
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Remplissage de barre : proportion du max pour le débit ; échelle absolue
    /// −120…−60 dBm pour le signal (valeurs négatives, plus proche de 0 = mieux).
    private func fraction(for stat: OperatorMetricStat) -> Double {
        switch metric {
        case .download:
            return maxValue > 0 ? Double(stat.value) / Double(maxValue) : 0
        case .signal:
            return min(1, max(0, (Double(stat.value) + 120) / 60))
        }
    }

    private func detailText(_ stat: OperatorMetricStat) -> String {
        var parts: [String] = []
        if let detail = stat.detail { parts.append(detail) }
        parts.append(measurementCountText(stat.sampleCount))
        return parts.joined(separator: " · ")
    }

    private func measurementCountText(_ count: Int) -> String {
        String(localized: "\(count) mesure")
    }

    private var radiusText: String {
SQUnits.distanceCompact(meters: Double(radiusMeters))
    }
}

// MARK: - Onglet Antennes (sites ANFR par opérateur)

/// État et chargement de l’onglet Antennes. Le marché vient de la position (registre), le
/// serveur n’est interrogé que pour la France et l’outre-mer ; une zone déjà vue (même case de
/// grille, même rayon) se relit en mémoire.
@MainActor
final class ZoneCompareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(ANFRZoneCompare)
        /// Route pas encore servie (404) : un état neutre, pas une erreur.
        case comingSoon
        case noAntennaData
        case outOfMarket
        case failed
    }

    enum Resolution: Equatable {
        case supported(String)
        case noAntennaData
        case outOfMarket
    }

    let latitude: Double
    let longitude: Double
    @Published var radius: ANFRZoneRadius = .default
    @Published var wantsBands = false
    @Published private(set) var reloadToken = 0
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var bandsLoading = false
    @Published private(set) var bandsFailed = false
    @Published private(set) var marketEntry: MarketRegistryEntry?

    private var service: ANFRServicing?
    private var markets: MarketRegistryServicing?
    private var resolution: Resolution?
    private var cache: [String: ANFRZoneCompare] = [:]
    /// Rayon des chiffres affichés : le détail par bande se charge sans vider la liste tant qu’il le partage.
    private var shownRadius: ANFRZoneRadius?

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

    // MARK: Règles pures (testées)

    /// Un échec d’appel vu par l’écran. `nil` : annulation, jamais affichée comme un échec.
    static func phase(for error: Error) -> Phase? {
        if error.isCancellation { return nil }
        guard let api = error as? APIError, case .http(let status, let code, _, _, _) = api else { return .failed }
        switch (status, code?.uppercased()) {
        case (404, _): return .comingSoon
        case (422, "MARKET_NO_ANTENNA_DATA"): return .noAntennaData
        case (422, "OUT_OF_MARKET"): return .outOfMarket
        default: return .failed
        }
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
        case .noAntennaData: phase = .noAntennaData; return
        case .outOfMarket: phase = .outOfMarket; return
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

        let keepsList = bands && shownRadius == radius && showsList
        if keepsList {
            bandsLoading = true
            bandsFailed = false
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
            if keepsList { bandsFailed = true } else { phase = failure }
        }
    }

    private var showsList: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func show(_ result: ANFRZoneCompare, radius: ANFRZoneRadius) {
        shownRadius = radius
        bandsFailed = false
        bandsLoading = false
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

/// Contenu de l’onglet Antennes : rayon, total de la zone, une rangée par opérateur, pied de relevé.
private struct ZoneAntennasSection: View {
    @ObservedObject var model: ZoneCompareModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var legendMinWidth: CGFloat = 74
    @State private var animate = false
    /// Position du curseur pendant un glissé ; `nil` = suit le rayon du modèle.
    @State private var sliderIndex: Double?
    @State private var isDraggingRadius = false

    var body: some View {
        switch model.phase {
        case .loading:
            VStack(alignment: .leading, spacing: SQSpace.md) {
                radiusPicker
                SQSpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.top, SQSpace.xl)
                    .accessibilityLabel("Chargement des antennes de la zone")
            }
        case .loaded(let data):
            loadedContent(data)
                .onAppear { reveal() }
        case .comingSoon:
            EmptyStateView(
                title: "Bientôt disponible",
                message: "Le comparatif des antennes d’une zone arrive prochainement.",
                systemImage: "clock"
            )
            .padding(.top, SQSpace.lg)
        case .noAntennaData:
            EmptyStateView(
                title: "Pays non couvert",
                message: "Pas de données d’antennes officielles pour ce pays.",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
            .padding(.top, SQSpace.lg)
        case .outOfMarket:
            EmptyStateView(
                title: "Zone non couverte",
                message: "Le comparatif des antennes couvre la France métropolitaine et l’outre-mer. Cette position est en dehors.",
                systemImage: "map"
            )
            .padding(.top, SQSpace.lg)
        case .failed:
            VStack(alignment: .leading, spacing: SQSpace.md) {
                radiusPicker
                ErrorStateView(title: "Chargement impossible", message: "Impossible de charger les antennes de la zone. Réessaie.") {
                    model.reload()
                }
            }
        }
    }

    private func reveal() {
        animate = false
        withAnimation(SQMotion.resolve(.easeOut(duration: 0.55), reduceMotion)) { animate = true }
    }

    private func loadedContent(_ data: ANFRZoneCompare) -> some View {
        let rows = data.operators.filter { $0.key.uppercased() != "ALL" }
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            radiusPicker
            summary(data)
            if rows.isEmpty {
                EmptyStateView(
                    title: "Pas encore de comparaison",
                    message: "Aucun opérateur à comparer dans ce rayon pour l’instant.",
                    systemImage: "chart.bar.xaxis"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(SQColor.separator) }
                        operatorRow(item, in: data)
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                Text("Chaque barre compte les sites par génération ; un site qui en émet plusieurs compte dans chacune.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                bandsDisclosure(rows, data: data)
            }
            footer(data)
        }
    }

    // MARK: Rayon

    private var radiusPicker: some View {
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
            .onChange(of: sliderIndex) { _ in
                // VoiceOver ajuste la valeur sans glissé : on l'applique tout de suite.
                if !isDraggingRadius { commitRadius() }
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.sm))
                : AnyLayout(HStackLayout(spacing: SQSpace.sm))
            layout {
                ForEach(ANFRZoneRadius.presets) { option in
                    // Espace insécable : « 20 km » ne se coupe pas entre le nombre et l’unité.
                    SQChip(label: String(localized: "\(option.kilometers)\u{00A0}km"), isSelected: model.radius == option) {
                        sliderIndex = nil
                        guard model.radius != option else { return }
                        model.radius = option
                    }
                    .accessibilityIdentifier("home.compare.radius.\(option.kilometers)")
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
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

    // MARK: Total de la zone

    private func summary(_ data: ANFRZoneCompare) -> some View {
        let radius = data.radiusKm > 0 ? data.radiusKm : model.radius.kilometers
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Sites en service dans \(radius) km")
                .font(SQType.callout)
                .foregroundStyle(SQColor.ink2)
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: data.totalActive.formatted())
                    .font(SQFont.display(32, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if data.totalPlanned > 0 {
                    Text("+ \(data.totalPlanned.formatted()) en projet")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: legendMinWidth), alignment: .leading)], alignment: .leading, spacing: SQSpace.xs) {
                ForEach(data.totalByGeneration.ordered, id: \.label) { item in
                    HStack(spacing: SQSpace.xs2) {
                        Circle()
                            .fill(SQNetworkColors.generationChartColor(item.label))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(item.label) \(item.count.formatted())")
                            .font(SQType.caption(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                    }
                }
            }
            .accessibilityHidden(true)
            Text("Un site qui émet en 4G et en 5G ne compte qu’une fois.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryAccessibility(data, radius: radius))
    }

    private func summaryAccessibility(_ data: ANFRZoneCompare, radius: Int) -> String {
        let generations = data.totalByGeneration.ordered.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
        return [String(localized: "Sites en service dans \(radius) km : \(data.totalActive)"),
                String(localized: "en projet : \(data.totalPlanned)"),
                generations,
                String(localized: "Un site qui émet en 4G et en 5G ne compte qu’une fois.")].joined(separator: ". ")
    }

    // MARK: Rangée d’opérateur

    private func operatorRow(_ item: ANFRZoneOperator, in data: ANFRZoneCompare) -> some View {
        let name = MarketRegistryEntry.operatorLabel(item.key, in: model.marketEntry)
        let color = model.marketEntry?.operatorColor(forKey: item.key) ?? SQBrand.operatorColor(item.key)
        let generations = item.generations.ordered.filter { $0.count > 0 }
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
                    if item.planned > 0 {
                        Text("+ \(item.planned.formatted()) en projet")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            generationBar(data.barSegments(for: item))
            if !generations.isEmpty {
                Text(verbatim: generations.map { "\($0.label) \($0.count.formatted())" }.joined(separator: " · "))
                    .font(SQType.caption)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.leading, SQSpace.sm + 4)
            }
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibility(name: name, item: item))
    }

    /// Une barre par opérateur, graduée sur la plus grande somme de la zone, découpée par génération.
    private func generationBar(_ segments: [ANFRZoneCompare.BarSegment]) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.chip)
                HStack(spacing: 0) {
                    ForEach(segments, id: \.generation) { segment in
                        Rectangle()
                            .fill(SQNetworkColors.generationChartColor(segment.generation))
                            .frame(width: animate && segment.count > 0 ? max(2, geo.size.width * CGFloat(segment.fraction)) : 0)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .padding(.leading, SQSpace.sm + 4)
        .accessibilityHidden(true)
    }

    private func rowAccessibility(name: String, item: ANFRZoneOperator) -> String {
        let generations = item.generations.ordered.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
        return String(localized: "\(name) : en service \(item.active), en projet \(item.planned). \(generations).")
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
            if !data.activeDefinition.isEmpty {
                Text(verbatim: data.activeDefinition)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
