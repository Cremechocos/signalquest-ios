import SwiftUI

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var detail: CoverageSessionDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var identifyingId: String?
    @Published var identifyResult: String?
    /// Pages suivantes en cours : le tracé se complète sous les yeux.
    @Published var isLoadingMorePoints = false
    /// Change à chaque lot de points reçu : la carte ne se redessine que là.
    @Published var renderVersion = UUID()
    /// Tous les points sont là : revenir sur l'écran ne recharge rien.
    private var hasAllPoints = false

    let session: CoverageSession
    /// Première page petite pour un affichage rapide, les suivantes plus grosses.
    nonisolated static let firstPageLimit = 2_000
    nonisolated static let nextPageLimit = 5_000
    nonisolated static let antennaRefreshPageLimit = 100

    init(session: CoverageSession) { self.session = session }

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

    func load(service: SessionsServicing) async {
        guard !(hasAllPoints && detail != nil) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let first: CoverageSessionDetail
        do {
            first = try await service.sessionDetail(id: session.id, pageLimit: Self.firstPageLimit)
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
            return
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
        defer { identifyingId = nil }
        // Seul un point porteur des identifiants de CETTE antenne fait preuve :
        // le premier point radio venu peut appartenir à une autre cellule, voire
        // à un autre réseau.
        let sample = Self.sample(for: antenna, in: detail?.points ?? [])
        let coord = await location.currentLocation(timeoutSeconds: 5)?.coordinate ?? antenna.coordinate
        guard let siteId = antenna.siteId, !siteId.isEmpty else {
            identifyResult = "Site inconnu : rien à identifier."
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
            identifyResult = "PLMN servant absent dans cette session : identifie ce nœud depuis les logs radio ou choisis explicitement son réseau."
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
            identifyResult = result.success ? "Site identifié ✓" : (result.message ?? "Identification non confirmée")
            Haptics.success()
        } catch {
            identifyResult = String(localized: "Échec : \(error.userFacingMessage)")
            Haptics.error()
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: SessionDetailViewModel
    @State private var validationTarget: ValidationTarget?
    @State private var pendingIdentify: ServingAntenna?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct ValidationTarget: Identifiable {
        let id = UUID()
        let siteId: String
        let operatorName: String?
    }

    init(session: CoverageSession) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                statsCard
                if !model.session.operators.isEmpty || !model.session.technologies.isEmpty {
                    chipsRow
                }
                traceSection
                generationSection
                speedtestsSection
                if let antennas = model.detail?.servingAntennas, !antennas.isEmpty {
                    servingAntennasSection(antennas)
                } else if model.detail != nil && !model.isLoading {
                    emptyAntennasHint
                }
                if let result = model.identifyResult {
                    Label(result, systemImage: "checkmark.seal")
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.success)
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.warning)
                }
            }
            .padding()
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle(model.session.name ?? (model.session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture")))
        .toolbarTitleInlineCompat()
        .overlay {
            if model.isLoading && model.detail == nil { ProgressView().tint(SQColor.brandRed) }
        }
        .task { await model.load(service: services.sessions) }
        .sheet(item: $validationTarget) { target in
            ValidationsSheet(siteId: target.siteId, operatorName: target.operatorName, service: services.validations)
        }
        .confirmationDialog(
            "Confirmer cette antenne ?",
            isPresented: Binding(get: { pendingIdentify != nil }, set: { if !$0 { pendingIdentify = nil } }),
            presenting: pendingIdentify
        ) { antenna in
            Button("Valider cette antenne", role: .none) {
                Task {
                    await model.identify(antenna, service: services.identify, location: services.location)
                    pendingIdentify = nil
                    // SESS-DETAIL-BUG-01 : rafraîchir la liste pour repasser l'antenne identifiée en vert.
                    await model.refreshServingAntennas(service: services.sessions)
                }
            }
            Button("Annuler", role: .cancel) { pendingIdentify = nil }
        } message: { antenna in
            Text("Cette antenne est indiquée comme \(Self.statusLabel(antenna)). Confirme uniquement si tu l'as sélectionnée comme antenne réelle.")
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        // Stats du DÉTAIL (recalculées par le backend sur les points VISIBLES filtrés
        // qualité) plutôt que celles de la LISTE (comptage brut non filtré + valeurs
        // stockées parfois périmées) → cohérence avec la carte et le breakdown de
        // génération. Repli sur la liste tant que le détail n'est pas chargé.
        let s = model.detail?.session ?? model.session
        return GlassCard {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                spacing: SQSpace.sm
            ) {
                statTile("Points", s.totalPoints.map { "\($0)" } ?? "—", "mappin.and.ellipse")
                statTile("Distance", s.distanceKm.map(Self.formatKm) ?? "—", "ruler")
                statTile("RSRP moyen", s.avgRsrpLabel ?? "—", "antenna.radiowaves.left.and.right")
                statTile(s.isDriveTest ? "Durée" : "Date",
                         s.isDriveTest ? (s.durationLabel ?? "—")
                                       : (s.startTime.map { $0.formatted(.dateTime.day().month().year()) } ?? "—"),
                         s.isDriveTest ? "clock" : "calendar")
            }
        }
    }

    private func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        SQMetricTile(label: label, value: value, icon: icon, iconTint: SQColor.brandRed)
    }

    // MARK: Operators + technologies chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(model.session.operators) { op in
                    HStack(spacing: 5) {
                        Circle().fill(Self.operatorColor(op.colorHex)).frame(width: 8, height: 8)
                        Text(op.label).font(SQFont.body(13, .semibold, relativeTo: .caption))
                        if let count = op.count {
                            Text("\(count)")
                                .font(SQFont.body(12, relativeTo: .caption2))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.md).padding(.vertical, 7)
                    .background(SQColor.surface, in: Capsule(style: .continuous))
                    .sqShadowSoft()
                }
                ForEach(model.session.technologies, id: \.self) { tech in
                    TechBadge(text: tech, color: SQBrand.techColor(tech))
                }
            }
            .padding(.vertical, SQSpace.xs)
        }
    }

    // MARK: Trace

    @ViewBuilder
    private var traceSection: some View {
        if let detail = model.detail, !(detail.points.isEmpty && detail.servingAntennas.isEmpty) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                SessionTraceMapView(points: detail.points,
                                    antennas: detail.servingAntennas,
                                    speedtests: detail.speedtests,
                                    drawPath: model.session.isDriveTest,
                                    coloring: model.session.isIosCoverage ? .generation : .rsrp,
                                    renderID: model.renderVersion,
                                    keepsUserViewport: true)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .sqShadowCard()
                if model.isLoadingMorePoints {
                    pointsProgressRow
                }
                if !detail.points.isEmpty {
                    // Couverture iOS = génération seule (pas de RSRP) → légende génération.
                    if model.session.isIosCoverage {
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

    private var pointsProgressRow: some View {
        let percent = model.pointsProgress.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.sm) {
                Text("Chargement des points…")
                Spacer(minLength: 0)
                if let percent {
                    Text(percent).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small).tint(SQColor.brandRed)
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
    private var rsrpLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(SessionRSRPColor.ui(-70), "Excellent")
            legendDot(SessionRSRPColor.ui(-85), "Bon")
            legendDot(SessionRSRPColor.ui(-95), "Moyen")
            legendDot(SessionRSRPColor.ui(-105), "Faible")
            legendDot(SessionRSRPColor.ui(-115), "Mauvais")
        }
        .font(SQFont.body(12, .medium, relativeTo: .caption2))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    /// Légende GÉNÉRATION (couverture iOS) — couleurs de `SessionGenerationColor`,
    /// identiques aux points de la carte (correspondance légende ↔ tracé).
    private var generationLegend: some View {
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

    private func legendDot(_ color: UIColor, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(uiColor: color)).frame(width: 7, height: 7)
            Text(LocalizedStringKey(label))
        }
    }

    // MARK: Génération (répartition %)

    @ViewBuilder
    private var generationSection: some View {
        let shares = model.generationBreakdown
        if !shares.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Répartition par génération")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
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
                ForEach(shares) { s in
                    HStack(spacing: SQSpace.sm) {
                        Circle()
                            .fill(Color(uiColor: SessionGenerationColor.ui(genColorKey(s.generation))))
                            .frame(width: 9, height: 9)
                        Text(s.generation)
                            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Text("\(s.count) pts")
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                        Text("\(Int(s.pct.rounded()))%")
                            .font(SQFont.display(15, .bold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.label)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    /// "Aucun" → nil (gris) ; sinon la génération telle quelle pour SessionGenerationColor.
    private func genColorKey(_ gen: String) -> String? { gen == "Aucun" ? nil : gen }

    // MARK: Speedtests

    @ViewBuilder
    private var speedtestsSection: some View {
        let sts = model.speedtests
        if !sts.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack {
                    Text("Speedtests")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    Text("\(sts.count)")
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let sum = model.speedtestSummary {
                    // Lexique : Réception / Envoi / Latence, unité selon la langue (valeurs en Mbit/s).
                    // Couleurs de la fiche d'une mesure (TRX-11), portées par l'icône.
                    let stats = Group {
                        speedStat("Réception moy.", sum.avgDown, String(localized: "Mbit/s"), "arrow.down",
                                  Color(uiColor: SessionSpeedColor.ui(sum.avgDown)))
                        speedStat("Envoi moy.", sum.avgUp, String(localized: "Mbit/s"), "arrow.up", SQColor.success)
                        speedStat("Latence moy.", sum.avgPing, "ms", "bolt.horizontal", SQColor.warning)
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
                            .padding(.leading, SQSpace.lg)
                    }
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    /// Valeur à l'encre : la couleur du débit ne tenait pas 4,5:1 sur la tuile.
    private func speedStat(_ label: String, _ value: Double?, _ unit: String, _ icon: String, _ color: Color) -> some View {
        SQMetricTile(
            label: label, value: value.map { "\(Int($0.rounded()))" } ?? "—", unit: unit, icon: icon, iconTint: color,
            fillsHeight: true
        )
    }

    private func speedtestRow(_ st: SessionSpeedtest) -> some View {
        HStack(spacing: SQSpace.sm) {
            Circle().fill(Color(uiColor: SessionSpeedColor.ui(st.downloadMbps))).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    // Le RÉSEAU d'abord : c'est lui qui décrit la mesure. La SIM ne
                    // sert que de repli quand le réseau n'a pas été résolu (anciennes
                    // lignes sans operatorKey).
                    Text(st.operatorKey ?? st.mobileOperator ?? "Speedtest")
                        .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    if let mvno = st.mvnoName, !mvno.isEmpty,
                       mvno.caseInsensitiveCompare(st.operatorKey ?? "") != .orderedSame {
                        Text("SIM \(mvno)")
                            .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                    if let net = st.networkType, !net.isEmpty {
                        Text(net)
                            .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                            .foregroundStyle(Color(uiColor: SessionGenerationColor.ui(net)))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(uiColor: SessionGenerationColor.ui(net)).opacity(0.16), in: Capsule(style: .continuous))
                    }
                }
                if let t = st.timestamp {
                    Text(t.formatted(.dateTime.hour().minute()))
                        .font(SQFont.body(12, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ \(st.downloadMbps.map { "\(Int($0.rounded()))" } ?? "—") Mbps")
                    .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.info)
                HStack(spacing: 8) {
                    Text("↑ \(st.uploadMbps.map { "\(Int($0.rounded()))" } ?? "—")")
                        .foregroundStyle(SQColor.brandGreen)
                    Text("\(st.pingMs.map { "\(Int($0.rounded()))" } ?? "—") ms")
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .font(SQFont.body(12, relativeTo: .caption2))
            }
        }
        .padding(.vertical, SQSpace.xs)
    }

    // MARK: Serving antennas

    private func servingAntennasSection(_ antennas: [ServingAntenna]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Antennes desservantes")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .padding(.bottom, SQSpace.xs)
            ForEach(antennas) { antenna in
                antennaRow(antenna)
                if antenna.id != antennas.last?.id {
                    Rectangle()
                        .fill(SQColor.separator)
                        .frame(height: 1)
                        .padding(.leading, SQSpace.lg + 2)
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    private func antennaRow(_ antenna: ServingAntenna) -> some View {
        HStack(spacing: SQSpace.sm) {
            Circle().fill(Self.statusColor(antenna.status)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(antenna.operatorDisplayName ?? antenna.displayName ?? String(localized: "Antenne"))
                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(Self.statusLabel(antenna))
                    .font(SQFont.body(12, relativeTo: .caption2))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                if let commune = antenna.commune, !commune.isEmpty {
                    Text(commune)
                        .font(SQFont.body(12, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if antenna.isUnconfirmed && (antenna.siteId != nil || antenna.enb != nil || antenna.gnb != nil) {
                Button {
                    pendingIdentify = antenna
                } label: {
                    Group {
                        if model.identifyingId == antenna.id {
                            ProgressView().tint(SQColor.onAccent)
                        } else {
                            Text("Valider").font(SQFont.body(13, .semibold, relativeTo: .caption))
                        }
                    }
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.md + 2)
                    .frame(minHeight: 34)
                    .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    // Capsule visuelle 34 pt, zone tactile étendue à ≥ 44 pt.
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .disabled(model.identifyingId != nil)
                .accessibilityLabel("Valider l'antenne \(antenna.operatorDisplayName ?? antenna.displayName ?? "")")
            }
            if antenna.siteId != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let siteId = antenna.siteId {
                validationTarget = ValidationTarget(siteId: siteId, operatorName: antenna.operatorName)
            }
        }
        .accessibilityAction(named: Text("Afficher les validations")) {
            if let siteId = antenna.siteId {
                validationTarget = ValidationTarget(siteId: siteId, operatorName: antenna.operatorName)
            }
        }
        .padding(.vertical, SQSpace.sm)
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
        if km < 1 { return "\(Int((km * 1000).rounded())) m" }
        return SQUnits.distance(kilometers: km)
    }

    static func statusColor(_ s: ServingStatus) -> Color {
        switch s {
        case .identified: return SQColor.success
        case .hypothesis: return SQColor.warning
        case .proximity, .unknown: return SQColor.labelSecondary
        }
    }

    static func statusLabel(_ a: ServingAntenna) -> String {
        var parts: [String] = [a.status.label]
        // SESS-DETAIL-TELECOM-01 : la confiance n'a de sens que pour une hypothèse scorée ;
        // pour une antenne de proximité, la distance suffit à exprimer l'incertitude.
        if a.status == .hypothesis, let conf = a.confidenceFR {
            parts.append("confiance \(conf)")
        }
        if let d = a.distanceKm, d > 0 { parts.append(String(localized: "à \(formatKm(d))")) }
        return parts.joined(separator: " · ")
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
