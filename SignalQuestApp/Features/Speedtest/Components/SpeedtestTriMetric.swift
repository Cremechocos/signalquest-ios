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
                id: "latency",
                title: "Latence",
                value: pingText,
                unit: "ms",
                state: state(for: .ping),
                quality: pingQuality
            )
            cell(
                id: "download",
                title: "Réception",
                value: mbpsText(downloadMbps),
                unit: SpeedtestDetailContent.formatSpeedParts(downloadMbps).unit,
                state: state(for: .download),
                quality: mbpsQuality(downloadMbps)
            )
            cell(
                id: "upload",
                title: "Envoi",
                value: mbpsText(uploadMbps),
                unit: SpeedtestDetailContent.formatSpeedParts(uploadMbps).unit,
                state: state(for: .upload),
                quality: mbpsQuality(uploadMbps)
            )
    }

    var pingMsValue: Double? {
        let value = result?.primaryPingMs ?? progress.pingFinalMs ?? progress.pingLiveMs
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Pendant sa phase, la cellule lit le débit instantané, comme l'aiguille ;
    /// une fois la phase passée, elle garde la moyenne retenue pour le résultat.
    var downloadMbps: Double? {
        let live = activePhase == .download && result == nil ? progress.downloadLiveMbps : nil
        let value = live ?? result?.downloadAverageMbps ?? progress.downloadAverageMbps ?? progress.downloadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    var uploadMbps: Double? {
        let live = activePhase == .upload && result == nil ? progress.uploadLiveMbps : nil
        let value = live ?? result?.uploadAverageMbps ?? progress.uploadAverageMbps ?? progress.uploadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    var pingText: String {
        guard let value = pingMsValue else { return "—" }
        return "\(Int(value.rounded()))"
    }

    var pingQuality: Color? {
        guard let ms = pingMsValue else { return nil }
        let theme = SQShareCardTheme.resolve(isDark: colorScheme == .dark, isPureBlack: false)
        return Color(uiColor: theme.latencyColor(ms: ms))
    }

    func mbpsQuality(_ mbps: Double?) -> Color? {
        guard let mbps, mbps > 0 else { return nil }
        return SQNetworkColors.speedColor(mbps)
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
        // La qualité reste portée par la jauge. Les couleurs RF/qualité ne
        // sont pas toutes des encres texte garanties à 4,5:1.
        return SQColor.label
    }

    @ViewBuilder
    /// `id` : identifiant stable des tests, indépendant du libellé affiché.
    func cell(id: String, title: String, value: String, unit: String, state: CellState, quality: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(12, .bold, relativeTo: .caption))
                .tracking(12 * 0.12)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speedtest.metric.\(id).title")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SQFont.display(21, .bold, relativeTo: .title3))
                    .monospacedDigit()
                    .foregroundStyle(valueColor(value, state: state, quality: quality))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("speedtest.metric.\(id).value")
                Text(unit)
                    .font(SQFont.body(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityIdentifier("speedtest.metric.\(id).unit")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SQSpace.md)
        .padding(.horizontal, SQSpace.md)
        .sqCardBackground(cornerRadius: SQRadius.lg, elevation: .rest)
        // La valeur en cours de mesure est entourée d'encre, comme l'aiguille.
        .overlay {
            if state == .active {
                RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    .strokeBorder(SQColor.label, lineWidth: 1.5)
            }
        }
        .sqAnimation(.snappy(duration: 0.25), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("speedtest.metric.\(id)")
        // `title` est un littéral d'interface, `value` une mesure : seul le
        // premier — et le repli « non mesuré » — passent par le catalogue.
        .accessibilityLabel(
            Text(LocalizedStringKey(title)) + Text(" : ")
                + (value == "—" ? Text("non mesuré") + Text(" · \(unit)") : Text("\(value) \(unit)"))
        )
    }
}
