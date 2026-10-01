import SwiftUI

/// Détails d'un point speedtest tapé sur la mini-carte Drive Test. UI soignée :
/// anneau de jauge coloré par débit, tuiles de métriques, sparkline du download et
/// méta (génération, opérateur, serveur, lieu, heure). Lecture seule.
struct DriveSpeedtestDetailSheet: View {
    let point: DriveSpeedtestPoint
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var result: SpeedtestRunResult { point.result }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    hero
                    metricsGrid
                    if let series = result.downloadSeriesMbps, series.count > 2 {
                        sparkleCard(series: series)
                    }
                    metaCard
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Détails du test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero — anneau de jauge coloré par débit

    private var hero: some View {
        let download = result.downloadAverageMbps
        let color = Self.speedColor(download)
        return VStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .stroke(SQColor.surfaceMuted, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: Self.gaugeFraction(download))
                    .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(verbatim: SQUnits.throughputValue(mbps: download))
                        .font(SQFont.display(46, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: SQUnits.throughputUnit(mbps: download))
                        .font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                    Text(Self.speedLabel(download))
                        .font(SQFont.body(12, .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.14), in: Capsule(style: .continuous))
                        .padding(.top, 2)
                }
            }
            .frame(width: 196, height: 196)
            .padding(.top, SQSpace.sm)

            HStack(spacing: SQSpace.sm) {
                if let gen = generationText {
                    // Couleur data de la techno (même signification que sur la carte).
                    SQEditorialTag(text: gen, color: SQBrand.techColor(gen))
                }
                if let op = operatorText {
                    SQEditorialTag(text: op, color: SQBrand.operatorColor(op))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tuiles de métriques

    private var metricsGrid: some View {
        let columns = Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return GlassCard {
            LazyVGrid(columns: columns, spacing: SQSpace.sm) {
                // Vocabulaire du lexique et unités de SQUnits, comme le test
                // ponctuel : « Download », « Ping » et « Mbps » restaient ici (MES-24).
                metricTile("Réception", value: SQUnits.throughputValue(mbps: result.downloadAverageMbps),
                           unit: SQUnits.throughputUnit(mbps: result.downloadAverageMbps),
                           detail: Self.peak(result.downloadMaxMbps), color: Self.speedColor(result.downloadAverageMbps), icon: "arrow.down")
                metricTile("Envoi", value: result.uploadAverageMbps.map { SQUnits.throughputValue(mbps: $0) } ?? "—",
                           unit: SQUnits.throughputUnit(mbps: result.uploadAverageMbps ?? 0),
                           detail: Self.peak(result.uploadMaxMbps), color: SQColor.success, icon: "arrow.up")
                metricTile("Latence", value: Self.wholeMs(result.primaryPingMs), unit: "ms",
                           detail: pingRange, color: SQColor.warning, icon: "bolt.horizontal", term: .latency)
                metricTile("Gigue", value: Self.wholeMs(result.jitterMs), unit: "ms",
                           detail: String(localized: "variation de la latence"), color: SQColor.info, icon: "waveform.path", term: .jitter)
            }
        }
    }

    private func metricTile(_ title: String, value: String, unit: String, detail: String, color: Color, icon: String, term: SQTerm? = nil) -> some View {
        SQMetricTile(label: title, value: value, unit: unit, term: term, icon: icon, iconTint: color, detail: detail, size: .large)
    }

    // MARK: Sparkline du download

    private func sparkleCard(series: [Double]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Débit pendant le test")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Méta

    private var metaCard: some View {
        VStack(spacing: 0) {
            metaRow("antenna.radiowaves.left.and.right", "Opérateur", operatorText ?? "—")
            metaDivider
            metaRow("cellularbars", "Réseau", generationText ?? connectionText,
                    term: generationText?.hasPrefix("5G") == true ? .fiveGModes : nil)
            if let ssid = result.wifiSSID, !ssid.isEmpty {
                metaDivider
                metaRow("wifi", "Wi-Fi", ssid)
            }
            metaDivider
            metaRow("server.rack", "Serveur de mesure", serverText)
            metaDivider
            metaRow("timer", "Durée", "\(result.durationSeconds.formatted(.number.precision(.fractionLength(0...1)))) s")
            metaDivider
            metaRow("clock", "Heure", result.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let place = placeText {
                metaDivider
                metaRow("mappin.and.ellipse", "Lieu", place)
            }
        }
        .padding(.vertical, SQSpace.xs)
        .sqCardBackground()
    }

    private func metaRow(_ icon: String, _ label: String, _ value: String, term: SQTerm? = nil) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 36, height: 36)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(LocalizedStringKey(label)).font(SQFont.body(14.5, .medium)).foregroundStyle(SQColor.labelSecondary)
            if let term { SQInfoButton(term: term) }
            Spacer()
            Text(value).font(SQFont.body(14.5, .semibold)).foregroundStyle(SQColor.label)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
    }

    private var metaDivider: some View {
        Rectangle().fill(SQColor.separator).frame(height: 1).padding(.leading, SQSpace.md + 36 + SQSpace.md)
    }

    // MARK: Textes dérivés

    private var generationText: String? {
        result.cellularTechnology?.rawValue
    }
    private var operatorText: String? {
        let name = result.networkOperatorName ?? result.operatorKey
        return name?.isEmpty == false ? name : nil
    }
    private var connectionText: String {
        (result.wifiSSID?.isEmpty == false) ? "Wi-Fi" : String(localized: "Cellulaire")
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

    /// « Pic : 412 Mbit/s ».
    static func peak(_ mbps: Double?) -> String {
        guard let mbps, mbps.isFinite, mbps > 0 else { return "—" }
        return String(localized: "Pic : \(SQUnits.throughput(mbps: mbps))")
    }

    static func wholeMs(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "\(Int(value.rounded()))"
    }

    static func gaugeFraction(_ mbps: Double) -> CGFloat {
        // Échelle « log » douce : 0 → 0, ~50 → 0.5, 1000+ → 1.
        let clamped = max(0, min(mbps, 1000))
        return CGFloat(min(1, log10(clamped + 1) / 3))
    }

    /// Libellés de l'échelle unique : « Moyen » comme sur la carte, et traduits.
    static func speedLabel(_ mbps: Double) -> String {
        SQQualityScale.Throughput(mbps: mbps).label
    }

    static func speedColor(_ mbps: Double) -> Color {
        SQNetworkColors.speedColor(mbps)
    }
}
