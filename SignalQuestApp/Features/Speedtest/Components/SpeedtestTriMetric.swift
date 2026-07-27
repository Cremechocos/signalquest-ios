import SwiftUI

struct SpeedtestTriMetric: View {
    let activePhase: SpeedtestPhase
    let progress: SpeedtestLiveProgress
    let result: SpeedtestRunResult?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SQSpace.md) {
            cell(
                title: "Ping",
                value: pingText,
                state: state(for: .ping),
                quality: pingQuality
            )
            cell(
                title: "Réception",
                value: mbpsText(downloadMbps),
                state: state(for: .download),
                quality: mbpsQuality(downloadMbps)
            )
            cell(
                title: "Envoi",
                value: mbpsText(uploadMbps),
                state: state(for: .upload),
                quality: mbpsQuality(uploadMbps)
            )
        }
    }

    var qualityStops: [Color] {
        SpeedtestShareTheme.resolve(colorScheme).qualityStops
    }

    var pingMsValue: Double? {
        let value = result?.pingMinMs ?? progress.pingFinalMs ?? progress.pingLiveMs
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
        return "\(Int(value.rounded())) ms"
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

    /// Débit sans unité (« 403 », « 38.5 ») — le « Mbps » est porté par le cadran.
    func mbpsText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
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
        if value == "—" { return SQColor.labelTertiary }
        if state == .active { return quality ?? SQColor.brandRed }
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
    func cell(title: String, value: String, state: CellState, quality: Color?) -> some View {
        VStack(spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelSecondary)
            Text(value)
                .font(SQFont.display(20, .bold, relativeTo: .title3))
                .monospacedDigit()
                .foregroundStyle(valueColor(value, state: state, quality: quality))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(value == "—" ? "non mesuré" : value)")
    }
}
