import SwiftUI

struct SpeedtestTriMetric: View {
    let activePhase: SpeedtestPhase
    let progress: SpeedtestLiveProgress
    let result: SpeedtestRunResult?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) { metricCells }
            } else {
                HStack(spacing: SQSpace.md) { metricCells }
            }
        }
    }

    @ViewBuilder
    private var metricCells: some View {
            cell(
                title: "Ping",
                value: pingText,
                unit: "ms",
                state: state(for: .ping),
                quality: pingQuality
            )
            cell(
                title: "Réception",
                value: mbpsText(downloadMbps),
                unit: SpeedtestDetailContent.formatSpeedParts(downloadMbps).unit,
                state: state(for: .download),
                quality: mbpsQuality(downloadMbps)
            )
            cell(
                title: "Envoi",
                value: mbpsText(uploadMbps),
                unit: SpeedtestDetailContent.formatSpeedParts(uploadMbps).unit,
                state: state(for: .upload),
                quality: mbpsQuality(uploadMbps)
            )
    }

    var qualityStops: [Color] {
        SpeedtestShareTheme.resolve(colorScheme).qualityStops
    }

    var pingMsValue: Double? {
        let value = result?.primaryPingMs ?? progress.pingFinalMs ?? progress.pingLiveMs
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    var downloadMbps: Double? {
        let value = result?.downloadAverageMbps ?? progress.downloadAverageMbps ?? progress.downloadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    var uploadMbps: Double? {
        let value = result?.uploadAverageMbps ?? progress.uploadAverageMbps ?? progress.uploadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    var pingText: String {
        guard let value = pingMsValue else { return "—" }
        return "\(Int(value.rounded()))"
    }

    var pingQuality: Color? {
        guard let ms = pingMsValue else { return nil }
        let ratio = max(0, min(1, (120 - ms) / 120))
        return SpeedtestQualityPalette.color(forRatio: ratio, stops: qualityStops)
    }

    func mbpsQuality(_ mbps: Double?) -> Color? {
        guard let mbps, mbps > 0 else { return nil }
        let ratio = max(0, min(1, log10(mbps) / 3))
        return SpeedtestQualityPalette.color(forRatio: ratio, stops: qualityStops)
    }

    /// Valeur compacte ; l'unité reste visible dans chaque carte, y compris
    /// lorsque la mesure n'a pas encore commencé.
    func mbpsText(_ value: Double?) -> String {
        SpeedtestDetailContent.formatSpeedParts(value).value
    }

    enum CellState { case pending, active, done }

    func state(for phase: SpeedtestPhase) -> CellState {
        let target = phase.order
        let current = activePhase.order
        if current > target { return .done }
        if current == target && isLiveTracked(activePhase) { return .active }
        if result != nil { return .done }
        return .pending
    }

    func isLiveTracked(_ phase: SpeedtestPhase) -> Bool {
        switch phase {
        case .ping, .download, .upload: return true
        default: return false
        }
    }

    func valueColor(_ value: String, state: CellState, quality: Color?) -> Color {
        if value == "—" { return SQColor.label }
        // La qualité reste portée par la barrette. Les couleurs RF/qualité ne
        // sont pas toutes des encres texte garanties à 4,5:1.
        return SQColor.label
    }

    /// Barrette : qualité (phase active) / olive (terminée) / muted (à venir).
    func barColor(_ state: CellState, quality: Color?) -> Color {
        switch state {
        case .active: return quality ?? SQColor.brandRed
        case .done: return SQColor.success
        case .pending: return SQColor.surfaceMuted
        }
    }

    @ViewBuilder
    func cell(title: String, value: String, unit: String, state: CellState, quality: Color?) -> some View {
        VStack(spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("speedtest.metric.\(title.lowercased()).title")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SQFont.display(20, .bold, relativeTo: .title3))
                    .monospacedDigit()
                    .foregroundStyle(valueColor(value, state: state, quality: quality))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("speedtest.metric.\(title.lowercased()).value")
                Text(unit)
                    .font(SQFont.body(10.5, .semibold, relativeTo: .caption))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityIdentifier("speedtest.metric.\(title.lowercased()).unit")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor(state, quality: quality))
                .frame(width: 26, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.md + 2)
        .padding(.horizontal, SQSpace.sm)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .sqAnimation(.snappy(duration: 0.25), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("speedtest.metric.\(title.lowercased())")
        // `title` est un littéral d'interface, `value` une mesure : seul le
        // premier — et le repli « non mesuré » — passent par le catalogue.
        .accessibilityLabel(
            Text(LocalizedStringKey(title)) + Text(" : ")
                + (value == "—" ? Text("non mesuré") + Text(" · \(unit)") : Text("\(value) \(unit)"))
        )
    }
}
