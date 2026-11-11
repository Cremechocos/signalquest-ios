import SwiftUI
import CoreLocation
import Charts

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var detail: CoverageSessionDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var identifyingId: String?
    @Published var identifyResult: String?
    /// Verdict de la dernière identification : seul un succès s'affiche en vert.
    @Published var identifySucceeded = false
    /// Pages suivantes en cours : le tracé se complète sous les yeux.
    @Published var isLoadingMorePoints = false
    /// Change à chaque lot de points reçu : la carte ne se redessine que là.
    @Published var renderVersion = UUID()
    /// Analyse figée par le serveur (DRIVE-ANALYSIS-1) ; nil tant qu'elle n'est pas prête.
    @Published var analysis: SessionAnalysis?
    /// Tous les points sont là : revenir sur l'écran ne recharge rien.
    private var hasAllPoints = false {
        didSet { if hasAllPoints, !oldValue, let detail { onComplete?(detail) } }
    }
    /// Première page déjà reçue (session d'un autre membre ouverte depuis le fil).
    private var preloaded: CoverageSessionDetail?
    /// Appelé une fois, quand tous les points sont reçus.
    var onComplete: ((CoverageSessionDetail) -> Void)?

    let session: CoverageSession
    /// Première page petite pour un affichage rapide, les suivantes plus grosses.
    nonisolated static let firstPageLimit = 2_000
    nonisolated static let nextPageLimit = 5_000
    nonisolated static let antennaRefreshPageLimit = 100

    init(session: CoverageSession) { self.session = session }

    /// `complete` : la session entière, gardée en mémoire, ne relance aucune requête.
    init(preloaded detail: CoverageSessionDetail, complete: Bool) {
        session = detail.session
        if complete {
            self.detail = detail
            hasAllPoints = true
        } else {
            preloaded = detail
        }
    }

    struct GenerationShare: Identifiable {
        let generation: String
        let count: Int
        let pct: Double
        var id: String { generation }
    }

    /// Génération normalisée d'un point ; « Aucun » exige une absence explicite.
    static func generationKey(_ tech: String?) -> String {
        switch CoverageGenerationBand.band(for: tech) {
        case .g5: return "5G"
        case .g4: return "4G"
        case .g3: return "3G"
        case .g2: return "2G"
        case .none:
            let value = (tech ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ["AUCUN", "NONE", "NO SERVICE", "NO_SERVICE", "NOSERVICE"].contains(value)
                ? "Aucun" : "Inconnu"
        }
    }

    /// Répartition des points par génération et état (inconnu ≠ sans réseau).
    /// Celle du serveur couvre toute la session, même avant la dernière page.
    var generationBreakdown: [GenerationShare] {
        var counts: [String: Int] = [:]
        if let shares = detail?.technologyBreakdown, !shares.isEmpty {
            for share in shares where share.points > 0 {
                counts[Self.generationKey(share.technology), default: 0] += share.points
            }
        } else {
            for p in detail?.points ?? [] { counts[Self.generationKey(p.tech), default: 0] += 1 }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return ["5G", "4G", "3G", "2G", "Inconnu", "Aucun"].compactMap { gen -> GenerationShare? in
            guard let c = counts[gen], c > 0 else { return nil }
            return GenerationShare(generation: gen, count: c, pct: Double(c) / Double(total) * 100)
        }
    }

    var speedtests: [SessionSpeedtest] {
        (detail?.speedtests ?? []).sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    /// Synthèse speedtests (moyennes ↓/↑/ping + meilleur ↓) pour l'en-tête.
    var speedtestSummary: (count: Int, avgDown: Double?, maxDown: Double?, avgUp: Double?, avgPing: Double?)? {
        let sts = speedtests
        guard !sts.isEmpty else { return nil }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let downs = sts.compactMap(\.downloadMbps).filter { $0 > 0 }
        let ups = sts.compactMap(\.uploadMbps).filter { $0 > 0 }
        let pings = sts.compactMap(\.pingMs).filter { $0 > 0 }
        return (sts.count, mean(downs), downs.max(), mean(ups), mean(pings))
    }

    /// Part des points déjà chargés, tant que des pages restent à venir.
    var pointsProgress: Double? {
        guard isLoadingMorePoints, let detail, let expected = detail.expectedPointRows, expected > 0 else { return nil }
        return min(Double(detail.points.count) / Double(expected), 1)
    }

    /// Kilomètre parcouru à chaque point, recalculé à chaque lot de points.
    private var kilometerCache: (version: UUID, ids: [String: Int], points: [CoverageSessionPoint], km: [Double])?

    private func kilometers() -> (ids: [String: Int], points: [CoverageSessionPoint], km: [Double]) {
        if let cache = kilometerCache, cache.version == renderVersion { return (cache.ids, cache.points, cache.km) }
        let points = (detail?.points ?? []).filter(\.hasValidCoordinate)
        var km: [Double] = []
        km.reserveCapacity(points.count)
        var total = 0.0
        var previous: CLLocation?
        var ids: [String: Int] = [:]
        for (index, point) in points.enumerated() {
            let location = CLLocation(latitude: point.lat, longitude: point.lng)
            if let previous { total += location.distance(from: previous) / 1000 }
            previous = location
            km.append(total)
            ids[point.id] = index
        }
        kilometerCache = (renderVersion, ids, points, km)
        return (ids, points, km)
    }

    /// Mesure de signal placée le long du trajet (temps écoulé et kilomètre).
    struct SignalSample: Identifiable {
        let id: Int
        let seconds: Double
        let km: Double
        let rsrp: Double
        let point: CoverageSessionPoint
    }

    private var signalCache: (version: UUID, start: Date?, samples: [SignalSample])?

    /// Points porteurs d'un RSRP, dans l'ordre du trajet ; réduits à ~800 pour le graphique.
    var signalSamples: (start: Date?, samples: [SignalSample]) {
        if let cache = signalCache, cache.version == renderVersion { return (cache.start, cache.samples) }
        let k = kilometers()
        let start = k.points.compactMap(\.timestamp).min()
        var all: [SignalSample] = []
        for (index, point) in k.points.enumerated() {
            guard let rsrp = point.signalStrength, rsrp <= -44, rsrp > -140, let time = point.timestamp, let start else { continue }
            all.append(SignalSample(id: index, seconds: time.timeIntervalSince(start), km: k.km[index], rsrp: rsrp, point: point))
        }
        let step = max(1, Int((Double(all.count) / 800).rounded(.up)))
        let samples = step == 1 ? all : stride(from: 0, to: all.count, by: step).map { all[$0] }
        signalCache = (renderVersion, start, samples)
        return (start, samples)
    }

    /// Kilomètre d'un point du tracé.
    func kilometer(at point: CoverageSessionPoint) -> Double? {
        let k = kilometers()
        return k.ids[point.id].map { k.km[$0] }
    }

    /// Kilomètre du point du tracé le plus proche (un speedtest, par exemple).
    func kilometer(near coordinate: CLLocationCoordinate2D) -> Double? {
        let k = kilometers()
        var best: (index: Int, distance: Double)?
        for (index, point) in k.points.enumerated() {
            let dLat = point.lat - coordinate.latitude
            let dLng = (point.lng - coordinate.longitude) * cos(coordinate.latitude * .pi / 180)
            let d = dLat * dLat + dLng * dLng
            if best == nil || d < best!.distance { best = (index, d) }
        }
        return best.map { k.km[$0.index] }
    }

    /// Seulement pour un trajet Drive Test à points : un trajet iOS (récap seul)
    /// répondrait « no_points ». Un échec cache le bloc, sans message : le reste
    /// du détail suffit.
    func loadAnalysis(service: SessionsServicing) async {
        guard session.isDriveTest, !session.isSummaryOnly, analysis == nil else { return }
        guard let loaded = try? await service.sessionAnalysis(id: session.id), loaded.isDisplayable else { return }
        analysis = loaded
    }

    func load(service: SessionsServicing) async {
        guard !(hasAllPoints && detail != nil) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let first: CoverageSessionDetail
        if let preloaded {
            first = preloaded
            self.preloaded = nil
        } else {
            do {
                first = try await service.sessionDetail(id: session.id, pageLimit: Self.firstPageLimit)
            } catch {
                if !error.isCancellation { errorMessage = error.userFacingMessage }
                return
            }
        }
        detail = first
        renderVersion = UUID()
        guard let cursor = first.page?.nextCursor else {
            hasAllPoints = true
            return
        }
        isLoading = false
        await loadRemainingPoints(after: cursor, service: service)
    }

    /// Pages suivantes, ajoutées dans l'ordre. Un point déjà reçu n'est jamais
    /// doublé. Un curseur refusé (session modifiée entre deux pages) relance une
    /// seule fois depuis la première page.
    private func loadRemainingPoints(after firstCursor: String, service: SessionsServicing, restarted: Bool = false) async {
        isLoadingMorePoints = true
        defer { isLoadingMorePoints = false }
        var seen = Set((detail?.points ?? []).map(\.id))
        var seenCursors: Set<String> = []
        var cursor: String? = firstCursor
        // Un curseur déjà servi arrêterait jamais la boucle.
        while let current = cursor, seenCursors.insert(current).inserted, !Task.isCancelled {
            do {
                let page = try await service.sessionPoints(id: session.id, after: current, limit: Self.nextPageLimit)
                let fresh = page.points.filter { seen.insert($0.id).inserted }
                if !fresh.isEmpty {
                    detail?.points.append(contentsOf: fresh)
                    renderVersion = UUID()
                }
                cursor = page.page?.nextCursor
                if cursor == nil { hasAllPoints = true }
            } catch let error as APIError {
                if case .http(400, "INVALID_CURSOR", _, _, _) = error, !restarted {
                    await reloadFirstPage(service: service)
                } else if !error.isCancellation {
                    errorMessage = error.userFacingMessage
                }
                return
            } catch {
                if !error.isCancellation { errorMessage = error.userFacingMessage }
                return
            }
        }
    }

    /// Après une identification, seul l'état des antennes change : on relit la
    /// plus petite première page au lieu de tout recharger.
    func refreshServingAntennas(service: SessionsServicing) async {
        guard let fresh = try? await service.sessionDetail(id: session.id, pageLimit: Self.antennaRefreshPageLimit) else { return }
        if fresh.page == nil {
            // Serveur sans pagination : la réponse est complète.
            detail = fresh
        } else {
            detail?.servingAntennas = fresh.servingAntennas
        }
        renderVersion = UUID()
    }

    private func reloadFirstPage(service: SessionsServicing) async {
        let first: CoverageSessionDetail
        do {
            first = try await service.sessionDetail(id: session.id, pageLimit: Self.firstPageLimit)
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
            return
        }
        detail = first
        renderVersion = UUID()
        if let cursor = first.page?.nextCursor {
            await loadRemainingPoints(after: cursor, service: service, restarted: true)
        } else {
            hasAllPoints = true
        }
    }

    /// Point de la session qui porte le nœud de l'antenne (eNB ou gNB), et sa
    /// cellule ou son PCI quand l'antenne les donne. Jamais un point d'un autre nœud.
    nonisolated static func sample(for antenna: ServingAntenna, in points: [CoverageSessionPoint]) -> CoverageSessionPoint? {
        let sameNode = points.filter { p in
            (antenna.enb != nil && p.enb == antenna.enb) || (antenna.gnb != nil && p.gnb == antenna.gnb)
        }
        return sameNode.first { p in
            (antenna.cellId == nil || p.cellId == antenna.cellId) && (antenna.pci == nil || p.pci == antenna.pci)
        } ?? sameNode.first
    }

    /// Identifie une antenne non confirmée : croise les identifiants radio d'un
    /// point représentatif de la session avec le référentiel (backend).
    func identify(_ antenna: ServingAntenna, service: IdentifyServicing, location: LocationService) async {
        identifyingId = antenna.id
        identifyResult = nil
        identifySucceeded = false
        defer { identifyingId = nil }
        // Seul un point porteur des identifiants de CETTE antenne fait preuve :
        // le premier point radio venu peut appartenir à une autre cellule, voire
        // à un autre réseau.
        let sample = Self.sample(for: antenna, in: detail?.points ?? [])
        let coord = await location.currentLocation(timeoutSeconds: 5)?.coordinate ?? antenna.coordinate
        guard let siteId = antenna.siteId, !siteId.isEmpty else {
            identifyResult = String(localized: "Site inconnu : rien à identifier.")
            Haptics.error()
            return
        }
        // Le PLMN du POINT observé est la seule preuve acceptable. Un nom comme
        // « Orange » ou « Bouygues » n'est ni mondialement unique, ni une preuve
        // de réseau servant. Les anciennes sessions sans PLMN restent lisibles,
        // mais leur identification doit passer par le journal ou un choix manuel.
        guard let plmn = sample?.servingPlmn else {
            if sample == nil {
                identifyResult = isLoadingMorePoints
                    ? String(localized: "Points encore en chargement : réessaie dans un instant.")
                    : String(localized: "Aucune mesure de ce nœud dans la session : identifie-le depuis les logs radio.")
                Haptics.error()
                return
            }
            identifyResult = String(localized: "PLMN servant absent dans cette session : identifie ce nœud depuis les logs radio ou choisis explicitement son réseau.")
            Haptics.error()
            return
        }
        let isNr = (antenna.gnb ?? sample?.gnb) != nil
        do {
            let result = try await service.identify(
                IdentifyDirectRequest(
                    siteId: siteId,
                    // Les identifiants de l'antenne priment, le point ne fait que compléter.
                    enb: antenna.enb ?? sample?.enb,
                    gnb: antenna.gnb ?? sample?.gnb,
                    pci: (antenna.pci ?? sample?.pci).flatMap(Int.init),
                    cellId: antenna.cellId ?? sample?.cellId,
                    tech: isNr ? "5G" : "4G",
                    operatorName: sample?.operatorKey,
                    operatorKey: sample?.operatorKey,
                    marketCode: sample?.marketCode,
                    rawOperatorName: sample?.simOperator,
                    observedPlmn: plmn.plmn,
                    mcc: plmn.mcc,
                    mnc: plmn.mnc,
                    isRoaming: sample?.isRoaming,
                    networkIdentitySource: sample?.networkIdentitySource,
                    latitude: coord.latitude,
                    longitude: coord.longitude
                )
            )
            // Un refus du serveur n'est pas un succès : icône, couleur et
            // retour haptique suivent le verdict (AF-MES-03).
            identifyResult = result.success ? String(localized: "Site identifié") : (result.message ?? String(localized: "Identification non confirmée"))
            identifySucceeded = result.success
            if result.success { Haptics.success() } else { Haptics.warning() }
        } catch {
            identifyResult = String(localized: "Échec : \(error.userFacingMessage)")
            identifySucceeded = false
            Haptics.error()
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: SessionDetailViewModel
    @State private var validationTarget: ValidationTarget?
    @State private var pendingIdentify: ServingAntenna?
    @State private var marketRegistry: MarketRegistryPayload?
    /// Couleur des points choisie ; `nil` = signal, sauf couverture iOS (génération seule).
    @State private var chosenColoring: SessionPointColoring?
    @State private var showsFullMap = false
    @State private var signalSelection: SessionDetailViewModel.SignalSample?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    struct ValidationTarget: Identifiable {
        let id = UUID()
        let siteId: String
        let operatorName: String?
    }

    init(session: CoverageSession) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
    }

    init(preloaded detail: CoverageSessionDetail, complete: Bool, onComplete: @escaping (CoverageSessionDetail) -> Void) {
        _model = StateObject(wrappedValue: {
            let model = SessionDetailViewModel(preloaded: detail, complete: complete)
            model.onComplete = onComplete
            return model
        }())
    }

    private var title: String {
        model.session.name ?? (model.session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture"))
    }

    /// Couverture iOS : la génération seule, iOS ne lisant pas le signal.
    private var coloring: Binding<SessionPointColoring> {
        Binding(
            get: { model.session.isIosCoverage ? .generation : (chosenColoring ?? .rsrp) },
            set: { chosenColoring = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                traceSection
                summaryCard
                if let analysis = model.analysis {
                    SessionAnalysisCard(analysis: analysis)
                }
                generationSection
                signalSection
                speedtestsSection
                if let antennas = model.detail?.servingAntennas, !antennas.isEmpty {
                    servingAntennasSection(antennas)
                } else if model.detail != nil && !model.isLoading {
                    emptyAntennasHint
                }
                if let result = model.identifyResult {
                    Label(result, systemImage: model.identifySucceeded ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(model.identifySucceeded ? SQColor.success : SQColor.dangerInk)
                }
                if let errorMessage = model.errorMessage {
                    // Sans relance, il fallait quitter et rouvrir la session (AF-MES-09).
                    ErrorStateView(title: "Détail indisponible", message: errorMessage) {
                        Task { await model.load(service: services.sessions) }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .overlay {
            if model.isLoading && model.detail == nil { SQSpinner().tint(SQColor.brandRed) }
        }
        .task { await model.load(service: services.sessions) }
        .task { await model.loadAnalysis(service: services.sessions) }
        .task { marketRegistry = await services.markets.registry() }
        .sheet(item: $validationTarget) { target in
            ValidationsSheet(siteId: target.siteId, operatorName: target.operatorName, service: services.validations)
        }
        .fullScreenCover(isPresented: $showsFullMap) {
            SessionTraceFullScreen(
                model: model,
                title: title,
                coloring: coloring,
                operatorLabels: speedtestOperatorLabels,
                onClose: { showsFullMap = false }
            )
            .environmentObject(services)
        }
        .confirmationDialog(
            "Confirmer cette antenne ?",
            isPresented: Binding(get: { pendingIdentify != nil }, set: { if !$0 { pendingIdentify = nil } }),
            titleVisibility: .visible,
            presenting: pendingIdentify
        ) { antenna in
            Button("Valider l’antenne", role: .none) {
                Task {
                    await model.identify(antenna, service: services.identify, location: services.location)
                    pendingIdentify = nil
                    // SESS-DETAIL-BUG-01 : rafraîchir la liste pour repasser l'antenne identifiée en vert.
                    await model.refreshServingAntennas(service: services.sessions)
                }
            }
            Button("Annuler", role: .cancel) { pendingIdentify = nil }
        } message: { antenna in
            let place = [Self.antennaTitle(antenna), Self.antennaSubtitle(antenna)].filter { !$0.isEmpty }.joined(separator: " · ")
            Text("\(place). Confirme uniquement si tu l’as captée sur ce trajet : ton identification est publique et tu peux la retirer dans « Mes identifications ».")
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "sessionDetail.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(verbatim: title)
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                    .accessibilityIdentifier("sessionDetail.title")
                Text(subtitle)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Drive Test · samedi 10 octobre 2026 · 10:00 → 10:40 ».
    private var subtitle: String {
        let s = model.detail?.session ?? model.session
        // Le type vient de la liste, comme le tracé et la couleur des points.
        var parts = [model.session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture")]
        if let start = s.startTime {
            parts.append(start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
            let from = start.formatted(.dateTime.hour().minute())
            if let end = s.endTime, end > start {
                parts.append(String(localized: "\(from) → \(end.formatted(.dateTime.hour().minute()))"))
            } else {
                parts.append(from)
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Synthèse

    private var summaryCard: some View {
        // Stats du DÉTAIL (recalculées par le backend sur les points VISIBLES filtrés
        // qualité) plutôt que celles de la LISTE (comptage brut non filtré + valeurs
        // stockées parfois périmées) → cohérence avec la carte et le breakdown de
        // génération. Repli sur la liste tant que le détail n'est pas chargé.
        let s = model.detail?.session ?? model.session
        let operators = s.operators.isEmpty ? model.session.operators : s.operators
        let technologies = s.technologies.isEmpty ? model.session.technologies : s.technologies
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            if let summary = (s.driveSummary ?? model.session.driveSummary), s.isSummaryOnly || model.session.isSummaryOnly {
                // Trajet Drive Test sans tracé (MES-14) : tests et débits du récap.
                kpiRow([
                    (summary.testCount.map { $0.formatted() } ?? "—", "Tests"),
                    (s.distanceKm.map(Self.formatKm) ?? "—", "Distance"),
                    (s.durationLabel ?? "—", "Durée")
                ])
                if summary.downloadAvgMbps != nil || summary.downloadMaxMbps != nil {
                    Divider()
                    kpiRow([
                        (summary.downloadAvgMbps.map { SQUnits.throughput(mbps: $0) } ?? "—", "Débit moyen"),
                        (summary.downloadMaxMbps.map { SQUnits.throughput(mbps: $0) } ?? "—", "Débit max")
                    ])
                }
            } else {
                kpiRow([
                    (s.totalPoints.map { $0.formatted() } ?? "—", "Points"),
                    (s.distanceKm.map(Self.formatKm) ?? "—", "Distance"),
                    (s.durationLabel ?? "—", "Durée")
                ])
            }
            // iOS ne lit pas le RSRP : la ligne n'apparaît que si la session en porte un.
            if let average = s.avgRsrpLabel {
                Divider()
                kpiRow([
                    (average, "RSRP moyen"),
                    (Self.rsrpLabel(s.maxSignalStrength) ?? "—", "Meilleur"),
                    (Self.rsrpLabel(s.minSignalStrength) ?? "—", "Pire")
                ])
            }
            if !operators.isEmpty || !technologies.isEmpty {
                Divider()
                chipsRow(operators: operators, technologies: technologies)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityIdentifier("sessionDetail.summary")
    }

    /// Trois valeurs côte à côte, empilées quand le texte est très agrandi.
    private func kpiRow(_ items: [(value: String, label: LocalizedStringKey)]) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: SQSpace.sm))
        return layout {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.value)
                        .font(SQFont.display(18, .bold, relativeTo: .headline))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(item.label)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// RSRP lisible, avec le même garde-fou que la moyenne.
    static func rsrpLabel(_ value: Double?) -> String? {
        guard let value, value <= -44 else { return nil }
        return "\(Int(value)) dBm"
    }

    // MARK: Operators + technologies chips

    private func chipsRow(operators: [SessionOperator], technologies: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(operators) { op in
                    HStack(spacing: 5) {
                        Circle().fill(Self.operatorColor(op.colorHex)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(op.label).font(SQFont.body(13, .semibold, relativeTo: .caption))
                        if let count = op.count {
                            Text("\(count) points")
                                .font(SQFont.body(12, relativeTo: .caption2))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.sm2).padding(.vertical, 5)
                    .background(Self.operatorColor(op.colorHex).opacity(0.14), in: Capsule(style: .continuous))
                    .accessibilityElement(children: .combine)
                }
                ForEach(technologies, id: \.self) { tech in
                    TechBadge(text: tech, color: SQBrand.techColor(tech))
                }
            }
        }
    }

    // MARK: Trace

    private var speedtestOperatorLabels: [String: String] {
        var labels: [String: String] = [:]
        for st in model.detail?.speedtests ?? [] {
            if let label = st.networkOperatorLabel(in: marketRegistry) { labels[st.id] = label }
        }
        return labels
    }

    @ViewBuilder
    private var traceSection: some View {
        if let detail = model.detail, !(detail.points.isEmpty && detail.servingAntennas.isEmpty) {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                SessionTraceMapView(points: detail.points,
                                    antennas: detail.servingAntennas,
                                    speedtests: detail.speedtests,
                                    drawPath: model.session.isDriveTest,
                                    coloring: coloring.wrappedValue,
                                    renderID: model.renderVersion,
                                    keepsUserViewport: true,
                                    operatorLabels: speedtestOperatorLabels)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        MapFloatingIconButton(systemImage: "arrow.up.left.and.arrow.down.right",
                                              label: "Agrandir la carte",
                                              identifier: "sessionDetail.map.expand") { showsFullMap = true }
                            .padding(SQSpace.sm)
                    }
                    .sqShadowCard()
                    .accessibilityIdentifier("sessionDetail.map")
                if model.isLoadingMorePoints {
                    pointsProgressRow
                }
                if !detail.points.isEmpty {
                    if !model.session.isIosCoverage {
                        coloringMenu
                    }
                    if coloring.wrappedValue == .generation {
                        generationLegend
                    } else {
                        rsrpLegend
                    }
                }
            }
        } else if model.detail != nil && !model.isLoading {
            Text("Aucun point géolocalisé pour cette session.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, SQSpace.lg)
        }
    }

    /// « Couleur des points : signal ▾ » : signal ou génération.
    private var coloringMenu: some View {
        Menu {
            Picker(selection: coloring) {
                Text("Signal").tag(SessionPointColoring.rsrp)
                Text("Génération").tag(SessionPointColoring.generation)
            } label: {
                Text("Couleur des points")
            }
        } label: {
            HStack(spacing: SQSpace.xs) {
                Text(coloring.wrappedValue == .rsrp ? "Couleur des points : signal" : "Couleur des points : génération")
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(SQColor.labelSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("sessionDetail.coloring")
    }

    private var pointsProgressRow: some View {
        let percent = model.pointsProgress.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.sm) {
                Text("Chargement des points…")
                Spacer(minLength: 0)
                if let percent {
                    Text(percent).monospacedDigit()
                } else {
                    SQSpinner().controlSize(.small).tint(SQColor.brandRed)
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            if let progress = model.pointsProgress {
                ProgressView(value: progress).tint(SQColor.brandRed)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Chargement des points…"))
        .accessibilityValue(Text(percent ?? ""))
    }

    /// Légende RSRP — couleurs dérivées de `SessionRSRPColor` (celles des points
    /// de la carte) pour garantir la correspondance légende ↔ tracé.
    static var rsrpLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(SessionRSRPColor.ui(-70), "Excellent")
            legendDot(SessionRSRPColor.ui(-85), "Bon")
            legendDot(SessionRSRPColor.ui(-95), "Moyen")
            legendDot(SessionRSRPColor.ui(-105), "Faible")
            legendDot(SessionRSRPColor.ui(-115), "Critique")
        }
        .font(SQFont.body(12, .medium, relativeTo: .caption2))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    /// Légende GÉNÉRATION (couverture iOS) — couleurs de `SessionGenerationColor`,
    /// identiques aux points de la carte (correspondance légende ↔ tracé).
    static var generationLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(SessionGenerationColor.ui("5G"), "5G")
            legendDot(SessionGenerationColor.ui("4G"), "4G")
            legendDot(SessionGenerationColor.ui("3G"), "3G")
            legendDot(SessionGenerationColor.ui("2G"), "2G")
            legendDot(SessionGenerationColor.ui("Inconnu"), "Inconnu")
            legendDot(SessionGenerationColor.ui(nil), "Aucun")
        }
        .font(SQFont.body(12, .medium, relativeTo: .caption2))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    private var rsrpLegend: some View { Self.rsrpLegend }
    private var generationLegend: some View { Self.generationLegend }

    private static func legendDot(_ color: UIColor, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(uiColor: color)).frame(width: 7, height: 7)
            Text(LocalizedStringKey(label))
        }
    }

    /// Titre de section, posé au-dessus de sa carte.
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(SQType.heading)
            .foregroundStyle(SQColor.label)
            .sqHeader()
            .padding(.horizontal, SQSpace.xs)
            .padding(.bottom, -SQSpace.xs)
    }

    // MARK: Génération (répartition %)

    @ViewBuilder
    private var generationSection: some View {
        let shares = model.generationBreakdown
        if !shares.isEmpty {
            sectionHeader("Générations")
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                // Barre empilée : part de chaque génération sur l'ensemble des points.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(shares) { s in
                            Rectangle()
                                .fill(Color(uiColor: SessionGenerationColor.ui(genColorKey(s.generation))))
                                .frame(width: max(2, geo.size.width * s.pct / 100))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                .padding(.top, 2)
                .accessibilityHidden(true)
                ForEach(shares) { s in
                    HStack(spacing: SQSpace.sm) {
                        Circle()
                            .fill(Color(uiColor: SessionGenerationColor.ui(genColorKey(s.generation))))
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(s.generation))
                            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Text("\(s.count) points")
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                            .monospacedDigit()
                        Text((s.pct / 100).formatted(.percent.precision(.fractionLength(0))))
                            .font(SQFont.display(15, .bold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.label)
                            .monospacedDigit()
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    /// "Aucun" → nil (gris) ; sinon la génération telle quelle pour SessionGenerationColor.
    private func genColorKey(_ gen: String) -> String? { gen == "Aucun" ? nil : gen }

    // MARK: Signal le long du trajet

    @ViewBuilder
    private var signalSection: some View {
        let data = model.signalSamples
        if data.samples.count >= 2 {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Signal le long du trajet")
                Spacer(minLength: SQSpace.sm)
                Button(action: openSignalFullScreen) {
                    Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sessionDetail.signal.expand")
            }
            // Le bouton fait 44 pt : le titre reste aussi près de sa carte que les autres.
            .padding(.vertical, -SQSpace.sm)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                SessionSignalChart(samples: data.samples, start: data.start, axis: .time,
                                   selection: $signalSelection, onTap: openSignalFullScreen)
                    .frame(height: 130)
                    .accessibilityIdentifier("sessionDetail.signal.chart")
                if let sample = signalSelection {
                    SessionSignalReading(sample: sample, start: data.start, showsKilometer: model.session.isDriveTest)
                } else {
                    Text("Glisse sur la courbe pour lire une mesure.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    private func openSignalFullScreen() {
        ANFRLandscapeHost.present(
            SessionSignalFullScreen(model: model, title: title, axis: .time, onClose: ANFRLandscapeHost.dismissCurrent)
        )
    }

    // MARK: Speedtests

    @ViewBuilder
    private var speedtestsSection: some View {
        let sts = model.speedtests
        if !sts.isEmpty {
            sectionHeader("Speedtests · \(sts.count)")
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                if let sum = model.speedtestSummary {
                    // Lexique : Réception / Envoi / Latence, unité selon la langue (valeurs en Mbit/s).
                    // Couleurs de la fiche d'une mesure (TRX-11), portées par l'icône.
                    let stats = Group {
                        let down = Self.throughputParts(sum.avgDown)
                        let up = Self.throughputParts(sum.avgUp)
                        speedStat("Réception moy.", down.value, down.unit, "arrow.down",
                                  Color(uiColor: SessionSpeedColor.ui(sum.avgDown)))
                        speedStat("Envoi moy.", up.value, up.unit, "arrow.up", SQColor.success)
                        speedStat("Latence moy.", sum.avgPing.map { "\(Int($0.rounded()))" } ?? "—", "ms",
                                  "bolt.horizontal", SQColor.warning)
                    }
                    Group {
                        // Trois tuiles étroites coupaient « Réception » au milieu du mot
                        // dès le texte agrandi : une seule colonne à partir de .xxLarge.
                        if dynamicTypeSize >= .xxLarge {
                            VStack(spacing: SQSpace.sm) { stats }
                        } else {
                            // Même hauteur pour les trois, quel que soit le libellé le plus long.
                            HStack(alignment: .top, spacing: SQSpace.sm) { stats }
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, SQSpace.xs)
                }
                ForEach(Array(sts.enumerated()), id: \.element.id) { index, st in
                    speedtestRow(st)
                    if index != sts.count - 1 {
                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(height: 1)
                            .padding(.leading, 34 + SQSpace.sm2)
                    }
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    /// Valeur à l'encre : la couleur du débit ne tenait pas 4,5:1 sur la tuile.
    private func speedStat(_ label: String, _ value: String, _ unit: String, _ icon: String, _ color: Color) -> some View {
        SQMetricTile(
            label: label, value: value, unit: unit, icon: icon, iconTint: color,
            fillsHeight: true
        )
    }

    /// Débit et unité au format de l'app (une décimale sous 100, Gbit/s au-delà de 1 000),
    /// ou un tiret quand la mesure manque.
    private static func throughputParts(_ mbps: Double?) -> (value: String, unit: String) {
        guard let mbps, mbps.isFinite, mbps > 0 else { return ("—", SQUnits.throughputUnit(mbps: 0)) }
        return (SQUnits.throughputValue(mbps: mbps), SQUnits.throughputUnit(mbps: mbps))
    }

    /// « 10:05 · km 2,1 » : l'heure, et la position sur le trajet d'un Drive Test.
    private func speedtestWhen(_ st: SessionSpeedtest) -> String? {
        var parts: [String] = []
        if let t = st.timestamp { parts.append(t.formatted(.dateTime.hour().minute())) }
        if model.session.isDriveTest, let coordinate = st.coordinate, let km = model.kilometer(near: coordinate) {
            parts.append(SQUnits.routeMarker(kilometers: km))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func speedtestRow(_ st: SessionSpeedtest) -> some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "speedometer", size: 34, font: .system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    // Le RÉSEAU d'abord : c'est lui qui décrit la mesure. La SIM ne
                    // sert que de repli quand le réseau n'a pas été résolu (anciennes
                    // lignes sans operatorKey).
                    Text(st.networkOperatorLabel(in: marketRegistry) ?? String(localized: "Speedtest"))
                        .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                        .sqSingleLine()
                    if let mvno = st.mvnoName, !mvno.isEmpty,
                       mvno.caseInsensitiveCompare(st.operatorKey ?? "") != .orderedSame {
                        Text("SIM \(mvno)")
                            .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                            .sqSingleLine()
                    }
                    if let net = st.networkType, !net.isEmpty {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(uiColor: SessionGenerationColor.ui(net)))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(net)
                                .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                                .foregroundStyle(SQColor.label)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(uiColor: SessionGenerationColor.ui(net)).opacity(0.16), in: Capsule(style: .continuous))
                    }
                }
                if let when = speedtestWhen(st) {
                    Text(when)
                        .font(SQFont.body(12, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: SQSpace.xs)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityHidden(true)
                    let down = Self.throughputParts(st.downloadMbps)
                    Text(verbatim: down.value)
                        .font(SQFont.body(15, .bold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: down.unit)
                        .font(SQFont.body(11, .semibold, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                    let up = Self.throughputParts(st.uploadMbps)
                    Text(verbatim: "\(up.value) \(up.unit) · \(st.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—")")
                }
                .font(SQFont.body(12, relativeTo: .caption2))
                .foregroundStyle(SQColor.labelSecondary)
            }
            .monospacedDigit()
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: Serving antennas

    private func servingAntennasSection(_ antennas: [ServingAntenna]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            sectionHeader("Antennes desservantes · \(antennas.count)")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(antennas) { antenna in
                    antennaRow(antenna)
                    if antenna.id != antennas.last?.id {
                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(height: 1)
                            .padding(.leading, 34 + SQSpace.sm2)
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
            Text("Identifiée : confirmée par la communauté. Hypothèse : l’antenne la plus probable d’après tes mesures. Proximité : le site ANFR le plus proche du trajet.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SQSpace.xs)
        }
    }

    /// « Site 0381234 » quand le numéro est lisible ; sinon le nom du site ou l'opérateur.
    static func antennaTitle(_ antenna: ServingAntenna) -> String {
        if let siteId = antenna.siteId, !siteId.isEmpty, siteId.count <= 12 {
            return String(localized: "Site \(siteId)")
        }
        return antenna.displayName ?? antenna.operatorDisplayName ?? String(localized: "Antenne")
    }

    /// « Orange · Gières », puis le nom du site s'il n'est pas déjà le titre.
    static func antennaSubtitle(_ antenna: ServingAntenna) -> String {
        let title = antennaTitle(antenna)
        var parts: [String] = []
        if let op = antenna.operatorDisplayName, !op.isEmpty, op != title { parts.append(op) }
        if let commune = antenna.commune, !commune.isEmpty { parts.append(commune) }
        if let name = antenna.displayName, !name.isEmpty, name != title, name != antenna.commune { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private func antennaRow(_ antenna: ServingAntenna) -> some View {
        let canValidate = antenna.isUnconfirmed && (antenna.siteId != nil || antenna.enb != nil || antenna.gnb != nil)
        let subtitle = Self.antennaSubtitle(antenna)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: "antenna.radiowaves.left.and.right", size: 34,
                               tint: SQBrand.operatorColor(antenna.operatorName ?? ""))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.antennaTitle(antenna))
                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                        .sqSingleLine()
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(SQFont.body(13, relativeTo: .footnote))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: SQSpace.sm) {
                        statusPill(antenna.status)
                        if let detail = Self.statusDetail(antenna) {
                            Text(verbatim: detail)
                                .font(SQFont.body(12, relativeTo: .caption2))
                                .foregroundStyle(SQColor.labelSecondary)
                                .monospacedDigit()
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                    if antenna.status == .hypothesis, !antenna.evidenceLabels.isEmpty {
                        Text(verbatim: antenna.evidenceLabels.joined(separator: " · "))
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if canValidate || antenna.siteId != nil {
                HStack(spacing: SQSpace.sm) {
                    if canValidate {
                        if model.identifyingId == antenna.id {
                            SQSpinner().tint(SQColor.brandRed).frame(minWidth: 44, minHeight: 44)
                        } else {
                            RadioLogActionButton(label: "Valider l’antenne", systemImage: "checkmark") {
                                pendingIdentify = antenna
                            }
                            .disabled(model.identifyingId != nil)
                            .accessibilityLabel(Text("Valider l’antenne \(Self.antennaTitle(antenna))"))
                            .accessibilityIdentifier("sessionDetail.antenna.validate")
                        }
                    }
                    if let siteId = antenna.siteId {
                        RadioLogActionButton(label: "Détails", ghost: true) {
                            validationTarget = ValidationTarget(siteId: siteId, operatorName: antenna.operatorName)
                        }
                        .accessibilityLabel(Text("Validations de \(Self.antennaTitle(antenna))"))
                        .accessibilityIdentifier("sessionDetail.antenna.details")
                    }
                }
                .padding(.leading, 34 + SQSpace.sm2)
            }
        }
        .padding(.vertical, SQSpace.md)
    }

    /// Étiquette d'état : verte une fois identifiée, ambre pour une hypothèse, neutre sinon.
    private func statusPill(_ status: ServingStatus) -> some View {
        let ink: Color
        let container: Color
        switch status {
        case .identified: ink = SQColor.success; container = SQColor.successSoft
        case .hypothesis: ink = OutageTint.degradedInk; container = SQColor.warningSoft
        case .proximity, .unknown: ink = SQColor.labelSecondary; container = SQColor.chip
        }
        return HStack(spacing: 5) {
            Circle().fill(ink).frame(width: 6, height: 6)
            Text(status.label)
                .font(SQFont.body(12, .bold, relativeTo: .caption2))
                .foregroundStyle(ink)
                .sqSingleLine()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(container, in: Capsule(style: .continuous))
    }

    private var emptyAntennasHint: some View {
        Label("Aucune antenne desservante résolue pour cette session.", systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .sqCardBackground(cornerRadius: SQRadius.md, elevation: .rest)
    }

    // MARK: Helpers

    static func formatKm(_ km: Double) -> String {
        SQUnits.distance(kilometers: km)
    }

    static func statusColor(_ s: ServingStatus) -> Color {
        switch s {
        case .identified: return SQColor.success
        case .hypothesis: return SQColor.warning
        case .proximity, .unknown: return SQColor.labelSecondary
        }
    }

    /// Ce qui suit l'étiquette d'état : la confiance d'une hypothèse et la distance au trajet.
    /// SESS-DETAIL-TELECOM-01 : la confiance n'a de sens que pour une hypothèse scorée ;
    /// pour une antenne de proximité, la distance suffit à exprimer l'incertitude.
    static func statusDetail(_ a: ServingAntenna) -> String? {
        var parts: [String] = []
        if a.status == .hypothesis, let conf = a.confidenceFR { parts.append(conf) }
        if let d = a.distanceKm, d > 0 { parts.append(String(localized: "à \(formatKm(d))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Couleur d'opérateur fournie par le backend (donnée, pas décor) ;
    /// repli neutre si absente ou illisible.
    static func operatorColor(_ hex: String?) -> Color {
        guard let hex else { return SQColor.labelSecondary }
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(cleaned, radix: 16) else { return SQColor.labelSecondary }
        return Color(hex: value)
    }
}

/// Axe horizontal du graphique de signal : le temps, ou la distance parcourue.
enum SessionSignalAxis: Hashable { case time, distance }

/// Signal le long du trajet : la courbe du RSRP, ses seuils, et un curseur
/// qui lit une mesure. Compact dans le détail, plein écran en paysage.
private struct SessionSignalChart: View {
    let samples: [SessionDetailViewModel.SignalSample]
    let start: Date?
    let axis: SessionSignalAxis
    var domain: ClosedRange<Double>? = nil
    @Binding var selection: SessionDetailViewModel.SignalSample?
    var isExpanded = false
    var onTap: (() -> Void)? = nil
    @State private var lastHapticId: Int?

    /// Tranche du trajet : moyenne et écart du signal, pour la courbe lissée du détail.
    struct Bucket: Identifiable {
        let id: Int
        let x: Double
        let mean: Double
        let low: Double
        let high: Double
    }

    func x(_ sample: SessionDetailViewModel.SignalSample) -> Double {
        axis == .time ? sample.seconds : sample.km
    }

    var fullDomain: ClosedRange<Double> {
        let xs = samples.map(x)
        guard let low = xs.min(), let high = xs.max(), low < high else { return 0...1 }
        return low...high
    }

    private var xDomain: ClosedRange<Double> { domain ?? fullDomain }

    /// Le domaine est lu UNE fois : dans le filtre, `xDomain` relisait `fullDomain`
    /// (un passage sur tous les échantillons) pour chaque échantillon, soit ~800 × 800
    /// par appel, plusieurs fois par rendu (gels de 0,7 à 7 s mesurés sur iPhone, 11/11).
    private var visible: [SessionDetailViewModel.SignalSample] {
        let domain = xDomain
        return samples.filter { domain.contains(x($0)) }
    }

    /// Bornes à 5 dB près, avec une marge, sans dépasser la plage RSRP.
    private var yDomain: ClosedRange<Double> {
        let values = visible.map(\.rsrp)
        let low = max(-140, (((values.min() ?? -120) - 5) / 5).rounded(.down) * 5)
        let high = min(-44, (((values.max() ?? -70) + 5) / 5).rounded(.up) * 5)
        return low < high ? low...high : -120...(-70)
    }

    /// Tableaux de 0 ou 1 élément plutôt que des `if` dans `Chart {}` (plantage
    /// connu de Swift Charts avec `symbolSize`).
    private var selected: [SessionDetailViewModel.SignalSample] { selection.map { [$0] } ?? [] }

    /// Moyenne et bande min–max par tranche (48 dans le détail ; en plein écran
    /// environ quatre mesures par tranche, 160 au plus) ; chaque mesure telle
    /// quelle une fois assez zoomé.
    private var buckets: [Bucket] {
        let domain = xDomain
        let samples = visible
        let count = isExpanded ? min(160, samples.count / 4) : 48
        let width = (domain.upperBound - domain.lowerBound) / Double(max(count, 1))
        guard count >= 12, samples.count > count, width > 0 else {
            return samples.map { Bucket(id: $0.id, x: x($0), mean: $0.rsrp, low: $0.rsrp, high: $0.rsrp) }
        }
        var groups: [Int: [SessionDetailViewModel.SignalSample]] = [:]
        for sample in samples {
            groups[min(count - 1, Int((x(sample) - domain.lowerBound) / width)), default: []].append(sample)
        }
        return groups.keys.sorted().compactMap { key in
            guard let group = groups[key], !group.isEmpty else { return nil }
            let values = group.map(\.rsrp)
            let xs = group.map(x)
            return Bucket(id: key, x: xs.reduce(0, +) / Double(xs.count), mean: values.reduce(0, +) / Double(values.count),
                          low: values.min() ?? 0, high: values.max() ?? 0)
        }
    }

    func label(_ value: Double) -> String {
        switch axis {
        case .time:
            return (start ?? Date()).addingTimeInterval(value).formatted(.dateTime.hour().minute())
        case .distance:
            return SQUnits.routeMarker(kilometers: value, fractionDigits: 0...1)
        }
    }

    var body: some View {
        // Calculés une fois par rendu : l'axe Y les relisait pour chaque graduation.
        let xDomain = xDomain
        let yDomain = yDomain
        return Chart {
            ForEach(buckets) { bucket in
                AreaMark(x: .value("Position", bucket.x),
                         yStart: .value("Minimum", bucket.low),
                         yEnd: .value("Maximum", bucket.high))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(SQColor.brandRed.opacity(0.16))
                LineMark(x: .value("Position", bucket.x), y: .value("RSRP", bucket.mean))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: isExpanded ? 2.2 : 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(SQColor.brandRed)
            }
            ForEach(selected) { sample in
                RuleMark(x: .value("Position", x(sample)))
                    .foregroundStyle(SQColor.labelSecondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Position", x(sample)), y: .value("RSRP", sample.rsrp))
                    .symbolSize(90)
                    .foregroundStyle(SQQualityScale.Signal(rsrp: sample.rsrp).color)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-80, -95, -110].filter { yDomain.contains($0) }) { value in
                AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.6))
                AxisValueLabel {
                    if let dbm = value.as(Double.self) {
                        Text(verbatim: "\(Int(dbm))")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: isExpanded ? 6 : 3)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: label(v))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = geo[proxy.plotAreaFrame]
                // Un toucher ouvre le plein écran depuis la page, et lit la mesure une fois agrandi.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        if isExpanded {
                            select(at: value.location.x - plot.origin.x, proxy: proxy)
                        } else {
                            onTap?()
                        }
                    })
                    .gesture(
                        DragGesture(minimumDistance: isExpanded ? 0 : 8)
                            .onChanged { value in
                                select(at: value.location.x - plot.origin.x, proxy: proxy)
                            }
                            .onEnded { _ in
                                if !isExpanded { selection = nil }
                            }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Signal le long du trajet"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// Retient la mesure la plus proche du doigt, avec un retour haptique à chaque nouvelle mesure.
    private func select(at plotX: CGFloat, proxy: ChartProxy) {
        guard let position: Double = proxy.value(atX: plotX),
              let nearest = visible.min(by: { abs(x($0) - position) < abs(x($1) - position) })
        else { return }
        if lastHapticId != nearest.id {
            lastHapticId = nearest.id
            Haptics.selection()
        }
        selection = nearest
    }

    /// « De −112 à −78 dBm, −91 dBm en moyenne ».
    private var accessibilitySummary: String {
        let values = visible.map(\.rsrp)
        guard let low = values.min(), let high = values.max() else { return "" }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(localized: "De \(Int(low)) à \(Int(high)) dBm, \(Int(mean)) dBm en moyenne")
    }
}

/// Lecture d'une mesure sous le curseur : « 10:18 · km 8,4 », « −104 dBm · Faible »,
/// puis la génération et la cellule.
private struct SessionSignalReading: View {
    let sample: SessionDetailViewModel.SignalSample
    let start: Date?
    let showsKilometer: Bool

    var body: some View {
        let quality = SQQualityScale.Signal(rsrp: sample.rsrp)
        var when: [String] = []
        if let t = sample.point.timestamp { when.append(t.formatted(.dateTime.hour().minute())) }
        if showsKilometer {
            when.append(SQUnits.routeMarker(kilometers: sample.km))
        }
        var cell: [String] = []
        if let tech = sample.point.tech, !tech.isEmpty { cell.append(tech) }
        if let pci = sample.point.pci, !pci.isEmpty { cell.append("PCI \(pci)") }
        if let gnb = sample.point.gnb, !gnb.isEmpty {
            cell.append("gNB \(gnb)")
        } else if let enb = sample.point.enb, !enb.isEmpty {
            cell.append("eNB \(enb)")
        }
        return VStack(alignment: .leading, spacing: 2) {
            if !when.isEmpty {
                Text(verbatim: when.joined(separator: " · "))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            HStack(spacing: SQSpace.xs) {
                Circle().fill(quality.color).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(verbatim: "\(Int(sample.rsrp)) dBm · \(quality.label)")
                    .font(SQFont.display(15, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
            }
            if !cell.isEmpty {
                Text(verbatim: cell.joined(separator: " · "))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .sqCardBackground(cornerRadius: SQRadius.md, elevation: .rest)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessionDetail.signal.reading")
    }
}

/// Signal le long du trajet en paysage : axe Temps ou Distance, curseur, pincement.
private struct SessionSignalFullScreen: View {
    @ObservedObject var model: SessionDetailViewModel
    let title: String
    let onClose: () -> Void
    @State private var axis: SessionSignalAxis
    @State private var zoomDomain: ClosedRange<Double>?
    @State private var pinchBase: ClosedRange<Double>?
    @State private var selection: SessionDetailViewModel.SignalSample?

    init(model: SessionDetailViewModel, title: String, axis: SessionSignalAxis, onClose: @escaping () -> Void) {
        self.model = model
        self.title = title
        self.onClose = onClose
        _axis = State(initialValue: axis)
    }

    private var data: (start: Date?, samples: [SessionDetailViewModel.SignalSample]) { model.signalSamples }

    private var fullDomain: ClosedRange<Double> {
        SessionSignalChart(samples: data.samples, start: data.start, axis: axis, selection: .constant(nil)).fullDomain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            header
            ZStack(alignment: .topTrailing) {
                SessionSignalChart(samples: data.samples, start: data.start, axis: axis, domain: zoomDomain,
                                   selection: $selection, isExpanded: true)
                    .modifier(ANFRPinchZoom(onChange: zoom(scale:anchor:), onEnd: { pinchBase = nil }))
                    .accessibilityIdentifier("sessionDetail.signal.fullscreen.chart")
                if let selection {
                    SessionSignalReading(sample: selection, start: data.start, showsKilometer: model.session.isDriveTest)
                        .padding(SQSpace.sm)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            Text("Glisse le doigt pour lire chaque mesure · pince pour zoomer")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
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
                if model.session.isDriveTest { axisPicker.frame(width: 240) }
            }
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm2) {
                    closeButton
                    titleStack
                }
                if model.session.isDriveTest { axisPicker }
            }
        }
    }

    private var closeButton: some View {
        MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "sessionDetail.signal.fullscreen.close") { onClose() }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Signal le long du trajet")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Text(verbatim: title)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
        }
    }

    private var axisPicker: some View {
        MapSegmented(
            selection: Binding(get: { axis }, set: { value in
                axis = value
                zoomDomain = nil
                selection = nil
            }),
            options: [(.time, String(localized: "Temps")), (.distance, String(localized: "Distance"))],
            identifier: "sessionDetail.signal.fullscreen.axis"
        )
    }

    /// Pincement : resserre ou élargit la plage autour des doigts, sans
    /// descendre sous le vingtième du trajet.
    private func zoom(scale: Double, anchor: Double) {
        let full = fullDomain
        let base = pinchBase ?? (zoomDomain ?? full)
        if pinchBase == nil { pinchBase = base }
        let fullSpan = full.upperBound - full.lowerBound
        let baseSpan = base.upperBound - base.lowerBound
        let span = min(max(baseSpan / max(scale, 0.05), fullSpan / 20), fullSpan)
        let a = min(max(anchor, 0), 1)
        let anchorValue = base.lowerBound + baseSpan * a
        var lower = max(anchorValue - span * a, full.lowerBound)
        var upper = lower + span
        if upper > full.upperBound {
            upper = full.upperBound
            lower = upper - span
        }
        zoomDomain = lower...upper
    }
}

/// Carte d'un trajet en plein écran : couleur des points, antennes et speedtests
/// à la demande, et lecture d'un point touché.
private struct SessionTraceFullScreen: View {
    @ObservedObject var model: SessionDetailViewModel
    let title: String
    @Binding var coloring: SessionPointColoring
    let operatorLabels: [String: String]
    let onClose: () -> Void
    @EnvironmentObject private var services: AppServices
    @State private var showsAntennas = true
    @State private var showsSpeedtests = true
    @State private var selected: CoverageSessionPoint?
    /// Site touché (id de `ServingSiteGroup`), exclusif avec `selected`.
    @State private var selectedSiteID: String?
    @State private var pendingIdentify: ServingAntenna?
    @State private var openedSite: AntennaSite?
    @State private var openedSiteOperator: String?
    /// Sites de l'opérateur autour des anneaux TA de la sélection (choix d'Alexandre
    /// du 11/11 : sans eux, on ne voit pas sur quel support tombent les anneaux).
    @State private var candidates: [AntennaSite] = []
    @State private var candidatesKey: String?
    @State private var candidatesLoading = false
    @State private var candidatesFailed = false
    @State private var selectedCandidateID: String?
    /// Renouvelé à chaque réglage : la carte ne se redessine que là.
    @State private var renderID = UUID()

    var body: some View {
        let detail = model.detail
        let points = detail?.points ?? []
        let groups = ServingSiteGroup.groups(detail?.servingAntennas ?? [])
        let selectedGroup = selectedSiteID.flatMap { id in groups.first { $0.id == id } }
        // Calculé une fois par rendu : il parcourt tous les points du trajet.
        let highlight: SessionTraceHighlight? = {
            if let selected { return SessionTraceHighlight.forPoint(selected, in: points, groups: groups) }
            if let selectedGroup { return SessionTraceHighlight.forGroup(selectedGroup, in: points) }
            return nil
        }()
        let request = Self.candidateRequest(point: selected, group: selectedGroup, groups: groups,
                                            points: points, highlight: highlight)
        let operatorSites = showsAntennas && request != nil && candidatesKey == request?.key
            ? Self.candidateSites(candidates, rings: highlight?.rings ?? [], groups: groups,
                                  operatorName: request?.operatorName)
            : []
        // LOOKUP-CONFLICT : les autres supports où le nœud est validé, sans attendre la recherche.
        let conflictSites = showsAntennas
            ? SessionConflictSites.sites(SessionConflictSites.selectionAntennas(point: selected, group: selectedGroup, groups: groups),
                                 rings: highlight?.rings ?? [], groups: groups)
            : []
        let candidateSites = SessionConflictSites.merging(conflictSites, into: operatorSites)
        let selectedCandidate = selectedCandidateID.flatMap { id in candidateSites.first { $0.id == id } }
        SessionTraceMapView(points: points,
                            antennas: showsAntennas ? (detail?.servingAntennas ?? []) : [],
                            speedtests: showsSpeedtests ? (detail?.speedtests ?? []) : [],
                            drawPath: model.session.isDriveTest,
                            coloring: coloring,
                            renderID: renderID,
                            keepsUserViewport: true,
                            operatorLabels: operatorLabels,
                            onPointTap: { point in
                                selected = point
                                selectedSiteID = nil
                                selectedCandidateID = nil
                            },
                            selectedPoint: selected,
                            onAntennaTap: { id in
                                selectedSiteID = id
                                selected = nil
                                selectedCandidateID = nil
                            },
                            highlight: highlight,
                            candidateSites: candidateSites,
                            onCandidateTap: { selectedCandidateID = $0 })
            .ignoresSafeArea()
            .accessibilityIdentifier("sessionDetail.fullMap")
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomCard(points: points, groups: groups, selectedGroup: selectedGroup,
                           candidate: selectedCandidate, candidateSites: candidateSites,
                           searchesCandidates: request != nil)
            }
            .task(id: request?.key) { await loadCandidates(request) }
            .alert(
                "Confirmer cette antenne ?",
                isPresented: Binding(get: { pendingIdentify != nil }, set: { if !$0 { pendingIdentify = nil } }),
                presenting: pendingIdentify
            ) { antenna in
                Button("Valider l’antenne") {
                    Task {
                        await model.identify(antenna, service: services.identify, location: services.location)
                        pendingIdentify = nil
                        await model.refreshServingAntennas(service: services.sessions)
                    }
                }
                Button("Annuler", role: .cancel) { pendingIdentify = nil }
            } message: { antenna in
                let place = [SessionDetailView.antennaTitle(antenna), SessionDetailView.antennaSubtitle(antenna)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                Text("\(place). Confirme uniquement si tu l’as captée sur ce trajet : ton identification est publique et tu peux la retirer dans « Mes identifications ».")
            }
            .sheet(item: $openedSite) { site in
                AntennaDetailSheet(site: site,
                                   market: Self.market(of: site, in: points),
                                   operatorName: openedSiteOperator ?? "ALL",
                                   service: services.antennas)
                    .environmentObject(services)
            }
            .onChange(of: model.renderVersion) { _ in renderID = UUID() }
            .onChange(of: coloring) { _ in renderID = UUID() }
            .onChange(of: showsAntennas) { _ in renderID = UUID() }
            .onChange(of: showsSpeedtests) { _ in renderID = UUID() }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                MapFloatingIconButton(systemImage: "xmark", label: "Fermer",
                                      identifier: "sessionDetail.fullMap.close", action: onClose)
                MapFloatingTitle(title: "\(title)", identifier: "sessionDetail.fullMap.title")
                Spacer(minLength: 0)
            }
            HStack(spacing: SQSpace.sm) {
                if !model.session.isIosCoverage {
                    MapSegmented(selection: $coloring,
                                 options: [(SessionPointColoring.rsrp, "Signal"), (.generation, "Génération")],
                                 identifier: "sessionDetail.fullMap.coloring")
                        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .sqShadowCard()
                        .frame(maxWidth: 240)
                }
                Spacer(minLength: 0)
                layerToggle(isOn: $showsAntennas, systemImage: "antenna.radiowaves.left.and.right",
                            label: "Antennes", identifier: "sessionDetail.fullMap.antennas")
                layerToggle(isOn: $showsSpeedtests, systemImage: "speedometer",
                            label: "Speedtests", identifier: "sessionDetail.fullMap.speedtests")
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    /// Bouton rond qui affiche ou masque une couche ; son état est lu à voix haute.
    private func layerToggle(isOn: Binding<Bool>, systemImage: String, label: LocalizedStringKey, identifier: String) -> some View {
        MapFloatingIconButton(systemImage: systemImage, label: label, identifier: identifier,
                              tint: isOn.wrappedValue ? SQColor.accentInk : SQColor.labelTertiary) {
            isOn.wrappedValue.toggle()
        }
        .accessibilityValue(Text(isOn.wrappedValue ? "Affichés" : "Masqués"))
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func bottomCard(points: [CoverageSessionPoint], groups: [ServingSiteGroup],
                            selectedGroup: ServingSiteGroup?, candidate: SessionCandidateSite?,
                            candidateSites: [SessionCandidateSite], searchesCandidates: Bool) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            if let candidate {
                candidateCard(candidate, node: Self.representativePoint(point: selected, group: selectedGroup, in: points))
                Divider()
            } else if let point = selected {
                pointReading(point)
                servedBy(point, groups: groups)
                candidatesLine(candidateSites, searching: searchesCandidates)
                Divider()
            } else if let group = selectedGroup {
                siteCard(group, points: points)
                candidatesLine(candidateSites, searching: searchesCandidates)
                Divider()
            }
            if coloring == .generation {
                SessionDetailView.generationLegend
            } else {
                SessionDetailView.rsrpLegend
            }
            if selected == nil, selectedGroup == nil {
                Text("Touche un point pour lire sa mesure, ou une antenne pour voir ce qu’elle sert.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                if showsAntennas, let summary = antennaSummary(points: points, groups: groups) {
                    Text(verbatim: summary)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("sessionDetail.fullMap.antennaSummary")
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.sm)
        .sqReadableWidth()
    }

    /// « −104 dBm · Faible », la génération, l'heure, le kilomètre et la cellule.
    private func pointReading(_ point: CoverageSessionPoint) -> some View {
        let quality = SQQualityScale.Signal(rsrp: point.signalStrength)
        let dbm = SessionDetailView.rsrpLabel(point.signalStrength)
        var facts: [String] = []
        if let t = point.timestamp { facts.append(t.formatted(.dateTime.hour().minute())) }
        if model.session.isDriveTest, let km = model.kilometer(at: point) {
            facts.append(SQUnits.routeMarker(kilometers: km))
        }
        // RSRQ, SINR, bande et TA, quand le trajet les a (Android) : ce qu'il faut
        // pour juger une identification.
        var radio: [String] = []
        let oneDecimal = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if let rsrq = point.rsrq { radio.append("RSRQ \(rsrq.formatted(oneDecimal)) dB") }
        if let snr = point.snr { radio.append("SINR \(snr.formatted(oneDecimal)) dB") }
        if let band = point.primaryBand { radio.append(SQUnits.band(band, isNR: point.primaryBandIsNR)) }
        if let ta = point.timingAdvance, let meters = point.taDistanceMeters {
            radio.append(String(localized: "TA \(ta) ≈ \(SQUnits.distance(meters: meters))"))
        }
        var cell: [String] = []
        if let pci = point.pci, !pci.isEmpty { cell.append("PCI \(pci)") }
        if let gnb = point.gnb, !gnb.isEmpty {
            cell.append("gNB \(gnb)")
        } else if let enb = point.enb, !enb.isEmpty {
            cell.append("eNB \(enb)")
        }
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(quality.color).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(verbatim: dbm ?? String(localized: "Pas de mesure"))
                    .font(SQFont.display(17, .bold, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
                    .monospacedDigit()
                if dbm != nil {
                    Text(quality.label)
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if let tech = point.tech, !tech.isEmpty {
                    TechBadge(text: tech, color: SQBrand.techColor(tech))
                }
                Button { selected = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -SQSpace.sm)
                .accessibilityLabel(Text("Fermer la mesure"))
                .accessibilityIdentifier("sessionDetail.fullMap.point.close")
            }
            if !(facts.isEmpty && cell.isEmpty) {
                HStack(spacing: SQSpace.md) {
                    if !facts.isEmpty { Text(verbatim: facts.joined(separator: " · ")) }
                    if !cell.isEmpty {
                        Text(verbatim: cell.joined(separator: " · "))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
            }
            if !radio.isEmpty {
                Text(verbatim: radio.joined(separator: " · "))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessionDetail.fullMap.point")
    }

    /// « Servi par Orange · Hypothèse 72 % · à 450 m du point · TA cohérent »,
    /// qui ouvre la fiche de l'antenne. Un nœud sans site trouvé le dit.
    @ViewBuilder
    private func servedBy(_ point: CoverageSessionPoint, groups: [ServingSiteGroup]) -> some View {
        if let key = point.nodeKey {
            if let group = groups.first(where: { $0.nodeKeys.contains(key) }) {
                let antenna = group.antennas.first { $0.lookupKey == key } ?? group.primary
                Button {
                    selected = nil
                    selectedSiteID = group.id
                } label: {
                    HStack(spacing: SQSpace.sm) {
                        Circle()
                            .fill(SQBrand.operatorColor(antenna.operatorName ?? ""))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(verbatim: Self.servedByText(antenna, site: group.coordinate, point: point))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.label)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SQColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Ouvre la fiche de l’antenne"))
                .accessibilityIdentifier("sessionDetail.fullMap.point.servedBy")
            } else {
                Label(String(localized: "\(Self.nodeLabel(point)) : aucun site trouvé pour ce nœud"),
                      systemImage: "questionmark.circle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityIdentifier("sessionDetail.fullMap.point.unresolved")
            }
        }
    }

    static func nodeLabel(_ point: CoverageSessionPoint) -> String {
        if let enb = point.enb, !enb.isEmpty { return "eNB \(enb)" }
        return "gNB \(point.gnb ?? "")"
    }

    /// Écart toléré entre la distance au site et l'anneau TA : trois pas de TA,
    /// pour la précision du GPS et l'arrondi du TA lui-même.
    static let taToleranceMeters: Double = 3 * ServingAntenna.metersPerTimingAdvance

    static func servedByText(_ antenna: ServingAntenna, site: CLLocationCoordinate2D, point: CoverageSessionPoint) -> String {
        var parts: [String] = []
        let name = antenna.operatorDisplayName ?? String(localized: "Antenne")
        parts.append(String(localized: "Servi par \(name)"))
        if antenna.status == .hypothesis, let score = antenna.confidenceScore {
            parts.append(String(localized: "Hypothèse \(score) %"))
        } else {
            parts.append(antenna.status.label)
        }
        let meters = CLLocation(latitude: site.latitude, longitude: site.longitude)
            .distance(from: CLLocation(latitude: point.lat, longitude: point.lng))
        parts.append(String(localized: "à \(SQUnits.distance(meters: meters)) du point"))
        if let ta = point.taDistanceMeters {
            parts.append(abs(meters - ta) <= taToleranceMeters
                         ? String(localized: "TA cohérent")
                         : String(localized: "TA incohérent"))
        }
        return parts.joined(separator: " · ")
    }

    /// Fiche d'une antenne touchée : état et score, nœuds, points servis, indices,
    /// puis « C'est elle » et la fiche du site.
    private func siteCard(_ group: ServingSiteGroup, points: [CoverageSessionPoint]) -> some View {
        let antenna = group.primary
        let keys = group.nodeKeys
        let served = points.filter { $0.nodeKey.map(keys.contains) == true }
        let withTA = served.filter { $0.taDistanceMeters != nil }.count
        // Le site servant lui-même face aux anneaux de ses points : la liste des
        // autres sites l'exclut, sans quoi « compatibles : 0 » ne disait rien de lui.
        let ownFit = SessionTraceHighlight.ringFit(
            of: group.coordinate, rings: SessionTraceHighlight.taRings(nodeKeys: keys, in: points, emphasizing: nil))
        let canValidate = antenna.isUnconfirmed && (antenna.siteId != nil || antenna.enb != nil || antenna.gnb != nil)
        let conflict = group.antennas.lazy.compactMap(\.identificationConflict).first
        // LOOKUP-CONFLICT (a) : support confirmé, cellule du point pas encore validée.
        let suggestsCell = !canValidate && antenna.status == .identified && antenna.cellValidationSuggested
            && antenna.siteId != nil
        let subtitle = SessionDetailView.antennaSubtitle(antenna)
        let nodes = group.antennas.compactMap { member -> String? in
            var parts: [String] = []
            if let enb = member.enb, !enb.isEmpty { parts.append("eNB \(enb)") }
            if let gnb = member.gnb, !gnb.isEmpty { parts.append("gNB \(gnb)") }
            if parts.isEmpty, let key = member.lookupKey { parts.append(key) }
            if let pci = member.pci, !pci.isEmpty { parts.append("PCI \(pci)") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        var status = [String]()
        if antenna.status == .hypothesis, let score = antenna.confidenceScore {
            status.append(String(localized: "score \(score) %"))
        }
        if let d = antenna.distanceKm, d > 0 { status.append(String(localized: "à \(SQUnits.distance(kilometers: d)) du trajet")) }
        let estimate: String? = antenna.estimatedSite.map { site in
            let meters = CLLocation(latitude: site.latitude, longitude: site.longitude)
                .distance(from: CLLocation(latitude: antenna.lat, longitude: antenna.lng))
            return String(localized: "Position estimée par recoupement : à \(SQUnits.distance(meters: meters)) de ce site (± \(SQUnits.distance(meters: site.uncertaintyMeters)))")
        }
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: "antenna.radiowaves.left.and.right", size: 34,
                               tint: SQBrand.operatorColor(antenna.operatorName ?? ""))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: SessionDetailView.antennaTitle(antenna))
                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                        .sqSingleLine()
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(SQFont.body(13, relativeTo: .footnote))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: SQSpace.sm) {
                        Self.statusPill(antenna.status)
                        if conflict?.isActionable == true {
                            SignalPill(text: "En conflit")
                                .accessibilityIdentifier("sessionDetail.fullMap.site.conflict")
                        }
                        if !status.isEmpty {
                            Text(verbatim: status.joined(separator: " · "))
                                .font(SQFont.body(12, relativeTo: .caption2))
                                .foregroundStyle(SQColor.labelSecondary)
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button { selectedSiteID = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -SQSpace.sm)
                .accessibilityLabel(Text("Fermer la fiche de l’antenne"))
                .accessibilityIdentifier("sessionDetail.fullMap.site.close")
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                if !nodes.isEmpty {
                    Text(verbatim: nodes.joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced))
                }
                Text(verbatim: ([String(localized: "Points servis : \(served.count)"),
                                 String(localized: "avec TA : \(withTA)")]
                                + (ownFit.total > 0
                                   ? [String(localized: "anneaux TA compatibles : \(ownFit.matching) sur \(ownFit.total)")]
                                   : [])).joined(separator: " · "))
                    .monospacedDigit()
                if let estimate { Text(verbatim: estimate) }
                if let conflict, let line = SessionConflictSites.line(conflict) {
                    Text(verbatim: line)
                        .foregroundStyle(conflict.isActionable ? OutageTint.degradedInk : SQColor.labelSecondary)
                }
                if suggestsCell {
                    Text("La cellule de ce point n’est pas encore validée sur ce support.")
                }
                if antenna.status == .hypothesis, !antenna.evidenceLabels.isEmpty {
                    Text(verbatim: antenna.evidenceLabels.joined(separator: " · "))
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let result = model.identifyResult {
                Label(result, systemImage: model.identifySucceeded ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(model.identifySucceeded ? SQColor.success : SQColor.dangerInk)
            }
            if canValidate || suggestsCell || antenna.siteId != nil {
                HStack(spacing: SQSpace.sm) {
                    if suggestsCell {
                        if model.identifyingId == antenna.id {
                            SQSpinner().tint(SQColor.brandRed).frame(minWidth: 44, minHeight: 44)
                        } else {
                            RadioLogActionButton(label: "Valider la cellule", systemImage: "checkmark") {
                                pendingIdentify = antenna
                            }
                            .disabled(model.identifyingId != nil)
                            .accessibilityIdentifier("sessionDetail.fullMap.site.validateCell")
                        }
                    }
                    if canValidate {
                        if model.identifyingId == antenna.id {
                            SQSpinner().tint(SQColor.brandRed).frame(minWidth: 44, minHeight: 44)
                        } else {
                            RadioLogActionButton(label: "C’est elle", systemImage: "checkmark") {
                                pendingIdentify = antenna
                            }
                            .disabled(model.identifyingId != nil)
                            .accessibilityLabel(Text("Valider l’antenne \(SessionDetailView.antennaTitle(antenna))"))
                            .accessibilityIdentifier("sessionDetail.fullMap.site.validate")
                        }
                    }
                    if let siteId = antenna.siteId {
                        RadioLogActionButton(label: "Fiche du site", ghost: true) {
                            openedSiteOperator = antenna.operatorName
                            openedSite = AntennaSite(
                                id: siteId, siteId: siteId,
                                latitude: antenna.lat, longitude: antenna.lng,
                                operators: antenna.operatorNames,
                                technologies: [], bands: [], azimuths: [],
                                sharingType: nil, crozonLeader: nil,
                                address: nil, height: nil, owner: nil
                            )
                        }
                        .accessibilityIdentifier("sessionDetail.fullMap.site.open")
                    }
                }
            }
        }
        .accessibilityIdentifier("sessionDetail.fullMap.site")
    }

    /// Même étiquette d'état que la liste des antennes du détail.
    static func statusPill(_ status: ServingStatus) -> some View {
        let ink: Color
        let container: Color
        switch status {
        case .identified: ink = SQColor.success; container = SQColor.successSoft
        case .hypothesis: ink = OutageTint.degradedInk; container = SQColor.warningSoft
        case .proximity, .unknown: ink = SQColor.labelSecondary; container = SQColor.chip
        }
        return HStack(spacing: 5) {
            Circle().fill(ink).frame(width: 6, height: 6)
            Text(status.label)
                .font(SQFont.body(12, .bold, relativeTo: .caption2))
                .foregroundStyle(ink)
                .sqSingleLine()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(container, in: Capsule(style: .continuous))
    }

    /// « 12 antennes sur la carte · 3 nœuds sans site trouvé » : la carte ne
    /// passe plus pour complète quand une partie des nœuds n'est pas placée.
    private func antennaSummary(points: [CoverageSessionPoint], groups: [ServingSiteGroup]) -> String? {
        let unresolved = ServingSiteGroup.unresolvedNodeKeys(points: points, antennas: model.detail?.servingAntennas ?? [])
        guard !groups.isEmpty || !unresolved.isEmpty else { return nil }
        var parts = [String(localized: "Antennes sur la carte : \(groups.count)")]
        if !unresolved.isEmpty {
            parts.append(String(localized: "nœuds sans site trouvé : \(unresolved.count)"))
        }
        return parts.joined(separator: " · ")
    }

    /// Recherche des sites de l'opérateur pour la sélection. La clé ne dépend que
    /// de l'opérateur, du marché et des nœuds : passer d'un point à un autre du
    /// même eNB ne relance rien.
    struct CandidateRequest {
        let key: String
        let bbox: BoundingBox
        let market: String
        let operatorName: String
    }

    static func candidateRequest(point: CoverageSessionPoint?, group: ServingSiteGroup?, groups: [ServingSiteGroup],
                                 points: [CoverageSessionPoint], highlight: SessionTraceHighlight?) -> CandidateRequest? {
        guard let highlight else { return nil }
        let nodeKeys: Set<String>
        let operatorName: String?
        var extra = highlight.links.flatMap { [$0.0, $0.1] }
        if let point, let key = point.nodeKey {
            nodeKeys = [key]
            operatorName = point.operatorKey ?? groups.first { $0.nodeKeys.contains(key) }?.primary.operatorName
            extra.append(point.coordinate)
        } else if let group {
            nodeKeys = group.nodeKeys
            operatorName = group.primary.operatorName
                ?? points.first { $0.nodeKey.map(group.nodeKeys.contains) == true }?.operatorKey
            extra.append(group.coordinate)
        } else {
            return nil
        }
        guard let operatorName, !operatorName.isEmpty, !nodeKeys.isEmpty,
              let bbox = SessionTraceHighlight.searchBox(rings: highlight.rings, extra: extra) else { return nil }
        let sample = points.first { $0.nodeKey.map(nodeKeys.contains) == true } ?? point
        let market = ((sample?.marketCode ?? sample?.countryCode) ?? "FR").uppercased()
        return CandidateRequest(key: "\(operatorName.uppercased())|\(market)|\(nodeKeys.sorted().joined(separator: ","))",
                                bbox: bbox, market: market, operatorName: operatorName.uppercased())
    }

    private func loadCandidates(_ request: CandidateRequest?) async {
        selectedCandidateID = nil
        candidatesFailed = false
        guard let request else {
            candidates = []
            candidatesKey = nil
            return
        }
        candidatesLoading = true
        do {
            let sites = try await services.antennas.list(bbox: request.bbox, market: request.market,
                                                         operatorName: request.operatorName, technologies: [])
            candidates = sites
            candidatesKey = request.key
        } catch {
            guard !error.isCancellation else { return }
            candidates = []
            candidatesKey = nil
            candidatesFailed = true
        }
        candidatesLoading = false
    }

    /// Sites placés, hors antennes desservantes déjà dessinées, avec leur accord
    /// aux anneaux TA de la sélection.
    static func candidateSites(_ sites: [AntennaSite], rings: [SessionTraceHighlight.Ring],
                               groups: [ServingSiteGroup], operatorName: String?) -> [SessionCandidateSite] {
        let serving = Set(groups.flatMap { $0.antennas.compactMap(\.siteId) })
        return sites.compactMap { site in
            guard let lat = site.latitude, let lng = site.longitude, lat != 0 || lng != 0,
                  !serving.contains(site.writeSiteId), !serving.contains(site.siteId ?? site.id) else { return nil }
            let fit = SessionTraceHighlight.ringFit(of: CLLocationCoordinate2D(latitude: lat, longitude: lng), rings: rings)
            return SessionCandidateSite(site: site, operatorName: operatorName, fitMatching: fit.matching, fitTotal: fit.total)
        }
    }

    /// Point dont les identifiants serviront à « C'est elle » : le point touché, ou
    /// un point du nœud principal de l'antenne touchée.
    static func representativePoint(point: CoverageSessionPoint?, group: ServingSiteGroup?,
                                    in points: [CoverageSessionPoint]) -> CoverageSessionPoint? {
        if let point, point.nodeKey != nil { return point }
        guard let group else { return nil }
        let keys = group.primary.lookupKey.map { [$0] } ?? group.nodeKeys
        return points.first { $0.nodeKey.map(keys.contains) == true }
    }

    /// « Autres sites de l'opérateur autour : 14 · compatibles avec les anneaux TA : 2 ».
    @ViewBuilder
    private func candidatesLine(_ sites: [SessionCandidateSite], searching: Bool) -> some View {
        if searching, showsAntennas {
            Group {
                if candidatesLoading {
                    Text("Recherche des sites de l’opérateur autour…")
                } else if candidatesFailed {
                    Text("Sites de l’opérateur indisponibles pour le moment.")
                } else {
                    let likely = sites.filter(\.isLikely).count
                    Text(verbatim: [String(localized: "Autres sites de l’opérateur autour : \(sites.count)"),
                                    String(localized: "compatibles avec les anneaux TA : \(likely)")].joined(separator: " · "))
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("sessionDetail.fullMap.candidates")
        }
    }

    /// Fiche d'un site candidat : accord aux anneaux TA, distance au point, puis
    /// « C'est elle » (le nœud du point sur ce site) et la fiche du site.
    private func candidateCard(_ candidate: SessionCandidateSite, node: CoverageSessionPoint?) -> some View {
        let site = candidate.site
        let title = site.siteId.map { String(localized: "Site \($0)") } ?? String(localized: "Antenne")
        var facts: [String] = []
        if let conflict = candidate.conflict {
            facts += SessionConflictSites.facts(conflict)
        }
        if candidate.fitTotal > 0 {
            facts.append(String(localized: "anneaux TA compatibles : \(candidate.fitMatching) sur \(candidate.fitTotal)"))
        }
        if let point = selected {
            let meters = CLLocation(latitude: candidate.coordinate.latitude, longitude: candidate.coordinate.longitude)
                .distance(from: CLLocation(latitude: point.lat, longitude: point.lng))
            facts.append(String(localized: "à \(SQUnits.distance(meters: meters)) du point"))
        }
        let antenna = node.map { ServingAntenna(candidate: site, node: $0, operatorName: candidate.operatorName) }
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: "antenna.radiowaves.left.and.right", size: 34,
                               tint: SQBrand.operatorColor(candidate.operatorName ?? ""))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                        .sqSingleLine()
                    if let address = site.address, !address.isEmpty {
                        Text(verbatim: address)
                            .font(SQFont.body(13, relativeTo: .footnote))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    if !facts.isEmpty {
                        Text(verbatim: facts.joined(separator: " · "))
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(candidate.isLikely ? SQColor.accentInk : SQColor.labelSecondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button { selectedCandidateID = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -SQSpace.sm)
                .accessibilityLabel(Text("Fermer la fiche du site"))
                .accessibilityIdentifier("sessionDetail.fullMap.candidate.close")
            }
            if candidate.conflict != nil {
                Text("Ce nœud est aussi validé sur ce support. Le bon est celui qui recoupe les anneaux TA.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let node {
                Text("Ce site n’est pas rattaché à \(Self.nodeLabel(node)). « C’est elle » l’y rattache avec les identifiants de ce point.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = model.identifyResult {
                Label(result, systemImage: model.identifySucceeded ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(model.identifySucceeded ? SQColor.success : SQColor.dangerInk)
            }
            HStack(spacing: SQSpace.sm) {
                if let antenna {
                    if model.identifyingId == antenna.id {
                        SQSpinner().tint(SQColor.brandRed).frame(minWidth: 44, minHeight: 44)
                    } else {
                        RadioLogActionButton(label: "C’est elle", systemImage: "checkmark") {
                            pendingIdentify = antenna
                        }
                        .disabled(model.identifyingId != nil)
                        .accessibilityLabel(Text("Valider l’antenne \(title)"))
                        .accessibilityIdentifier("sessionDetail.fullMap.candidate.validate")
                    }
                }
                RadioLogActionButton(label: "Fiche du site", ghost: true) {
                    openedSiteOperator = candidate.operatorName
                    openedSite = site
                }
                .accessibilityIdentifier("sessionDetail.fullMap.candidate.open")
            }
        }
        .accessibilityIdentifier("sessionDetail.fullMap.candidate")
    }

    /// Marché de la fiche : celui des points mesurés, la France sinon.
    static func market(of site: AntennaSite, in points: [CoverageSessionPoint]) -> String {
        points.lazy.compactMap { ($0.marketCode ?? $0.countryCode)?.uppercased() }.first { !$0.isEmpty } ?? "FR"
    }
}

// MARK: - Session d'un autre membre (« Voir la session » du fil)

/// Sessions déjà ouvertes depuis le fil, gardées le temps de la navigation :
/// rouvrir le détail ne relance aucune requête. Chaque lecture de la session d'un
/// autre membre compte dans la limite du serveur, un 304 compris. Clé par compte,
/// vidée au changement de compte. Cinq minutes au plus : une session dépubliée
/// ou supprimée par son auteur ne reste pas visible au-delà.
@MainActor
final class SharedSessionMemory {
    static let shared = SharedSessionMemory()
    nonisolated static let lifetime: TimeInterval = 5 * 60
    private var entries: [(key: String, detail: CoverageSessionDetail, storedAt: Date)] = []
    private let capacity = 4
    /// Compte courant, injectable pour les tests.
    private let account: () -> String?

    init(account: @escaping () -> String? = { LocalAccountScope.sessionSnapshot().map { "\($0.ownerScopeId)|\($0.sessionId)" } }) {
        self.account = account
    }

    private func key(_ sessionId: String) -> String? {
        account().map { "\($0)|\(sessionId)" }
    }

    func detail(for sessionId: String, now: Date = Date()) -> CoverageSessionDetail? {
        entries.removeAll { now.timeIntervalSince($0.storedAt) >= Self.lifetime }
        guard let key = key(sessionId) else { return nil }
        return entries.first { $0.key == key }?.detail
    }

    func remember(_ detail: CoverageSessionDetail, for sessionId: String, now: Date = Date()) {
        guard let key = key(sessionId) else { return }
        entries.removeAll { $0.key == key }
        entries.append((key, detail, now))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func removeAll() { entries.removeAll() }
}

/// Détail d'une session ouverte par son identifiant (`metadata.sessionId` du post).
/// 404 : la session n'est plus publique ; 429 : limite de lecture, sans rejeu
/// automatique, le bouton revient après le délai donné par le serveur.
struct SharedSessionDetailView: View {
    let sessionId: String
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: (detail: CoverageSessionDetail, complete: Bool)?
    @State private var failure: String?
    @State private var retryAt: Date?

    var body: some View {
        if let loaded {
            SessionDetailView(preloaded: loaded.detail, complete: loaded.complete) { [sessionId] detail in
                SharedSessionMemory.shared.remember(detail, for: sessionId)
            }
        } else {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "sessionDetail.back") { dismiss() }
                if let failure {
                    ErrorStateView(
                        title: String(localized: "Session indisponible"),
                        message: failure,
                        retry: retryAt == nil ? { Task { await load() } } : nil
                    )
                    .accessibilityIdentifier("sharedSession.error")
                } else {
                    SQSpinner().tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SQColor.bg.ignoresSafeArea())
            .task { await load() }
            .task(id: retryAt) {
                guard let retryAt else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0, retryAt.timeIntervalSinceNow) * 1_000_000_000))
                if !Task.isCancelled { self.retryAt = nil }
            }
        }
    }

    private func load() async {
        if let remembered = SharedSessionMemory.shared.detail(for: sessionId) {
            loaded = (remembered, true)
            return
        }
        failure = nil
        do {
            let first = try await services.sessions.sessionDetail(id: sessionId, pageLimit: SessionDetailViewModel.firstPageLimit)
            loaded = (first, false)
        } catch {
            guard !error.isCancellation else { return }
            failure = Self.message(for: error)
            if case APIError.http(429, _, _, _, let retryAfter)? = error as? APIError {
                retryAt = Date().addingTimeInterval(TimeInterval(retryAfter ?? 60))
            }
        }
    }

    nonisolated static func message(for error: Error) -> String {
        guard let api = error as? APIError, case .http(let status, _, _, _, let retryAfter) = api else {
            return error.userFacingMessage
        }
        switch status {
        case 404:
            return String(localized: "Cette session n’est plus publique.")
        case 429:
            let seconds = retryAfter ?? 60
            if seconds < 90 { return String(localized: "Trop de sessions ouvertes. Réessaie dans \(max(seconds, 1)) s.") }
            if seconds < 90 * 60 { return String(localized: "Trop de sessions ouvertes. Réessaie dans \((seconds + 59) / 60) min.") }
            // Plafond du jour : un délai en heures ne dit rien de plus.
            return String(localized: "Trop de sessions ouvertes aujourd’hui. Réessaie plus tard.")
        default:
            return error.userFacingMessage
        }
    }
}
