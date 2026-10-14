import SwiftUI

/// Détails d'un point speedtest tapé sur la mini-carte Drive Test, comme la
/// fiche d'un test : jauge, trois valeurs, courbe de réception et détails
/// (génération, opérateur, serveur, lieu, heure). Seule la visibilité sur
/// la carte publique se règle ici : l'historique local ne garde pas tout un trajet.
struct DriveSpeedtestDetailSheet: View {
    let point: DriveSpeedtestPoint
    @EnvironmentObject private var services: AppServices
    @State private var marketEntry: MarketRegistryEntry?
    @StateObject private var visibility: SpeedtestVisibilityViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(point: DriveSpeedtestPoint, visibilityService: any SpeedtestVisibilityServicing, guestMode: Bool) {
        self.point = point
        _visibility = StateObject(wrappedValue: SpeedtestVisibilityViewModel(
            clientID: point.result.id, service: visibilityService, guestMode: guestMode,
            vpnIsActive: { VPNDetector.isActive() }
        ))
    }

    private var result: SpeedtestRunResult { point.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack {
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "drivetest.detail.close") {
                        dismiss()
                    }
                    Spacer()
                }
                header
                speedCard
                if let series = result.downloadSeriesMbps, series.count > 2 {
                    curveCard(series: series)
                }
                metaCard
                SpeedtestVisibilityControls(model: visibility)
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { marketEntry = await services.markets.market(forCode: result.marketCode) }
        .task { await visibility.load() }
        .onDisappear { visibility.deactivate() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { visibility.refreshAvailability() }
        }
    }

    // MARK: En-tête — « Test du trajet · 14:12 », lieu, pastilles

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Test du trajet · \(result.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(SQFont.body(12, .bold, relativeTo: .caption))
                .tracking(12 * 0.16)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(placeText ?? String(localized: "Détails du test"))
                .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            let download = result.downloadAverageMbps
            let pills = Group {
                if let op = operatorText {
                    // Couleur data de l'opérateur et de la techno, comme sur la carte.
                    SQEditorialTag(text: op, color: SQBrand.operatorColor(op))
                }
                if let gen = generationText {
                    SQEditorialTag(text: gen, color: SQBrand.techColor(gen))
                }
                if download > 0 {
                    SQEditorialTag(text: Self.speedLabel(download), color: Self.speedColor(download))
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs) { pills }
            } else {
                HStack(spacing: SQSpace.xs) { pills }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Débits mesurés — jauge, trois valeurs et pics

    private var speedCard: some View {
        detailCard("Débits mesurés") {
            ViewThatFits(in: .horizontal) {
                dial(width: 280)
                dial(width: 240)
            }
            .frame(maxWidth: .infinity)
            // Vocabulaire du lexique et unités de SQUnits, comme le test
            // ponctuel : « Download », « Ping » et « Mbps » restaient ici (MES-24).
            let metrics = Group {
                triCell("Envoi", value: result.uploadAverageMbps.map { SQUnits.throughputValue(mbps: $0) } ?? "—",
                        unit: SQUnits.throughputUnit(mbps: result.uploadAverageMbps ?? 0))
                triCell("Latence", value: Self.wholeMs(result.primaryPingMs), unit: "ms", term: .latency)
                triCell("Gigue", value: result.jitterMs.map { SQUnits.jitterValue($0) } ?? "—", unit: "ms", term: .jitter)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) { metrics }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: SQSpace.sm) { metrics }
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: SQSpace.xxs) {
                dotRow("Réception max", Self.peakValue(result.downloadMaxMbps))
                dotRow("Envoi max", Self.peakValue(result.uploadMaxMbps))
                dotRow("Min · max", pingRange)
            }
        }
    }

    private func dial(width: CGFloat) -> some View {
        SignatureSpeedDial(
            value: result.downloadAverageMbps,
            unit: SQUnits.throughputUnit(mbps: 0),
            phaseTitle: String(localized: "Réception"),
            phase: .finished,
            completionLabel: nil,
            extendsToTenGigabits: (result.downloadMaxMbps ?? 0) > 1_000,
            width: width
        )
    }

    private func triCell(_ title: LocalizedStringKey, value: String, unit: String, term: SQTerm? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title)
                    .font(SQFont.body(11, .bold, relativeTo: .caption2))
                    .tracking(11 * 0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let term { SQInfoButton(term: term) }
            }
            // La valeur ne se coupe jamais : l'unité passe dessous si la tuile
            // est trop étroite.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) { triValue(value, unit: unit) }
                VStack(alignment: .leading, spacing: 0) { triValue(value, unit: unit) }
            }
        }
        .padding(.horizontal, SQSpace.sm2)
        .padding(.vertical, SQSpace.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func triValue(_ value: String, unit: String) -> some View {
        Text(verbatim: value)
            .font(SQFont.display(20, .bold))
            .monospacedDigit()
            .foregroundStyle(SQColor.label)
            .fixedSize()
        Text(verbatim: unit)
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
    }

    // MARK: Courbe de réception

    private func curveCard(series: [Double]) -> some View {
        detailCard("Débit pendant le test") {
            let trace = result.measurementTrace?.phases.first { $0.phase == "download" }
            SpeedtestShareGraph(series: series, averageMbps: result.downloadAverageMbps,
                accent: Self.speedColor(result.downloadAverageMbps), plotBackground: SQColor.surfaceMuted,
                gridColor: SQColor.separator, labelColor: SQColor.labelSecondary,
                timedSeries: trace?.recentSeries, timedAverageSeries: trace?.averageSeries,
                timeOriginMs: trace?.sampleStartMs, unitLabel: SQUnits.throughputUnit(mbps: 0))
                .frame(height: 108)
            if trace == nil {
                Text("Courbe historique sans horodatage").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    // MARK: Détails de la mesure

    private var metaCard: some View {
        detailCard("Détails de la mesure") {
            VStack(spacing: SQSpace.xxs) {
                dotRow("Opérateur", operatorText ?? "—")
                dotRow("Réseau", generationText ?? connectionText,
                       term: generationText?.hasPrefix("5G") == true ? .fiveGModes : nil)
                if let ssid = result.wifiSSID, !ssid.isEmpty {
                    dotRow("Wi-Fi", ssid)
                }
                dotRow("Serveur de mesure", serverText)
                dotRow("Durée", "\(result.durationSeconds.formatted(.number.precision(.fractionLength(0...1)))) s")
                dotRow("Heure", result.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let place = placeText {
                    dotRow("Lieu", place)
                }
            }
        }
    }

    // MARK: Briques — carte à sur-titre et ligne clé · · · valeur

    private func detailCard<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            Text(title)
                .font(SQFont.body(12, .bold, relativeTo: .caption))
                .tracking(12 * 0.16)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .sqHeader()
            content()
        }
        .padding(SQSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    /// Les très grands textes empilent la clé et la valeur plutôt que de les tronquer.
    private func dotRow(_ label: LocalizedStringKey, _ value: String, term: SQTerm? = nil) -> some View {
        let labelView = HStack(spacing: 2) {
            Text(label)
                .font(SQType.subhead(.regular))
                .foregroundStyle(SQColor.labelSecondary)
            if let term { SQInfoButton(term: term) }
        }
        let valueText = Text(verbatim: value)
            .font(SQFont.body(14, .bold, relativeTo: .subheadline))
            .monospacedDigit()
            .foregroundStyle(SQColor.label)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    labelView
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SQSpace.xxs)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    labelView
                        .layoutPriority(1)
                    SQDotLeader()
                        .frame(minWidth: SQSpace.md, maxWidth: .infinity)
                        .frame(height: 1)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    valueText
                        .layoutPriority(1)
                }
                .frame(minHeight: 28)
            }
        }
    }

    // MARK: Textes dérivés

    private var generationText: String? {
        result.cellularTechnology?.rawValue
    }
    private var operatorText: String? {
        if let name = result.networkOperatorName, !name.isEmpty { return name }
        guard let key = result.operatorKey, !key.isEmpty else { return nil }
        return MarketRegistryEntry.operatorLabel(key, in: marketEntry)
    }
    private var connectionText: String {
        result.networkDisplayName
    }
    private var serverText: String {
        if let dl = result.downloadServerName, let s = result.serverName, dl != s { return "\(s) · \(dl)" }
        return result.serverName ?? result.downloadServerName ?? "—"
    }
    private var pingRange: String {
        guard let mn = result.pingMinMs, let mx = result.pingMaxMs else { return "—" }
        return "\(Int(mn.rounded()))–\(SQUnits.milliseconds(mx))"
    }
    private var placeText: String? {
        let parts = [result.address, result.city].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.first
    }

    // MARK: Helpers couleur/format (échelle SpeedBand)

    /// « 412 Mbit/s », ou un tiret quand la mesure manque.
    static func peakValue(_ mbps: Double?) -> String {
        guard let mbps, mbps.isFinite, mbps > 0 else { return "—" }
        return SQUnits.throughput(mbps: mbps)
    }

    static func wholeMs(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "\(Int(value.rounded()))"
    }

    /// Libellés de l'échelle unique : « Moyen » comme sur la carte, et traduits.
    static func speedLabel(_ mbps: Double) -> String {
        SQQualityScale.Throughput(mbps: mbps).label
    }

    static func speedColor(_ mbps: Double) -> Color {
        SQNetworkColors.speedColor(mbps)
    }
}
