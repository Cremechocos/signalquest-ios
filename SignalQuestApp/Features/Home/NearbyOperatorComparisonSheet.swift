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
    /// Ouverte depuis la carte : rayon montré sur la carte (mètres ; `true` = rayon arrêté,
    /// `false` = curseur en cours de glissé), et carte utilisable derrière la feuille.
    var onRadiusChange: ((Double, Bool) -> Void)?

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
         startsOnAntennas: Bool = false, isChosenPoint: Bool = false,
         onRadiusChange: ((Double, Bool) -> Void)? = nil) {
        _tab = State(initialValue: startsOnAntennas ? .antennas : (metric == .signal ? .signal : .download))
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.isChosenPoint = isChosenPoint
        self.onRadiusChange = onRadiusChange
        _zone = StateObject(wrappedValue: ZoneCompareModel(latitude: latitude, longitude: longitude))
    }

    private var metric: NearbyOperatorMetric { tab == .signal ? .signal : .download }

    /// Une requête par point, par rayon, par détail de bandes et par relance ; changer de clé annule la précédente.
    private struct TaskKey: Equatable {
        let tab: Tab
        let latitude: Double
        let longitude: Double
        let radius: ANFRZoneRadius
        let bands: Bool
        let reload: Int
    }

    private var taskKey: TaskKey {
        TaskKey(tab: tab, latitude: latitude, longitude: longitude, radius: zone.radius,
                bands: zone.wantsBands, reload: zone.reloadToken)
    }

    private var maxValue: Int { max(stats.map(\.value).max() ?? 1, 1) }
    private var totalSamples: Int { stats.reduce(0) { $0 + $1.sampleCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                metricPicker
                if tab == .antennas {
                    ZoneAntennasSection(model: zone) { kilometers in
                        onRadiusChange?(Double(kilometers) * 1000, false)
                    }
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
        .modifier(MapBackgroundInteraction(enabled: onRadiusChange != nil))
        .sqSheet()
        .task(id: taskKey) {
            if tab == .antennas {
                zone.attach(service: services.anfr, markets: services.markets)
                zone.move(latitude: latitude, longitude: longitude)
                await zone.load()
            } else {
                await load()
            }
        }
        .onAppear { reportRadius() }
        .onChangeCompat(of: tab) { _, _ in reportRadius() }
        .onChangeCompat(of: zone.radius) { _, _ in reportRadius() }
    }

    /// Le cercle de la carte suit le rayon de l'onglet : sites ANFR (20 à 100 km) ou mesures (1 km).
    private func reportRadius() {
        let meters = tab == .antennas ? Double(zone.radius.kilometers) * 1000 : Double(radiusMeters)
        onRadiusChange?(meters, true)
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

/// Contenu de l’onglet Antennes : rayon, total de la zone, une rangée par opérateur, pied de relevé.
private struct ZoneAntennasSection: View {
    @ObservedObject var model: ZoneCompareModel
    /// Rayon en cours de glissé, pour que la carte redessine son cercle sans attendre le relâcher.
    var onRadiusPreview: (Int) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        case .noAntennaData:
            // Canada, Belgique, Suisse et collectivités : des antennes existent ailleurs dans
            // l'app, mais le comparatif de zone ne les lit pas encore.
            EmptyStateView(
                title: "Pas encore disponible ici",
                message: "Le comparatif des antennes n’est pas encore disponible dans cette zone.",
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
                let leaders = ZoneCompareModel.leaders(rows)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(SQColor.separator) }
                        operatorRow(item, leads: leaders[item.key] ?? [])
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .opacity(model.isRefreshing ? 0.5 : 1)
                Text("Chaque colonne compte les sites qui émettent dans la génération ; un site peut compter dans plusieurs. Encadré : l’opérateur qui en a le plus.")
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
            .onChange(of: sliderIndex) { index in
                if let index { onRadiusPreview(steps[min(max(Int(index), 0), steps.count - 1)]) }
                // VoiceOver ajuste la valeur sans glissé : on l'applique tout de suite.
                if !isDraggingRadius { commitRadius() }
            }
            // Plus de pastilles 20 · 50 · 100 km : le curseur couvre toute l'échelle et la place
            // gagnée laisse voir les chiffres à mi-hauteur de feuille (demande du 19/10).
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
                if data.totalPlanned > 0 {
                    Text("+ \(data.totalPlanned.formatted()) en projet")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            GenerationCountsGrid(counts: data.totalByGeneration.ordered)
                .opacity(model.isRefreshing ? 0.5 : 1)
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

    private func operatorRow(_ item: ANFRZoneOperator, leads: Set<String>) -> some View {
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
                    if item.planned > 0 {
                        Text("+ \(item.planned.formatted()) en projet")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            GenerationCountsGrid(counts: item.generations.ordered, leaders: leads)
                .padding(.leading, SQSpace.sm + 4)
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibility(name: name, item: item, leads: leads))
    }

    private func rowAccessibility(name: String, item: ANFRZoneOperator, leads: Set<String>) -> String {
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
            // La définition du serveur nomme ses champs (`active`, `planned`) : l'app dit la même règle à l'utilisateur.
            Text("Sites au statut « En service » ; « Techniquement opérationnel » et « Projet approuvé » comptent en projet.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
