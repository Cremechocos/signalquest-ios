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

// MARK: - Résultat épuré (piste A, commune avec Android et signalquest.fr/speedtest)

/// Ce que le résultat épuré affiche, lu dans le test enregistré : rien n'y est
/// lissé ni animé en chiffre, seuls les blocs apparaissent.
struct SpeedtestResultFigures {
    let result: SpeedtestRunResult

    /// Latence affichée : le minimum depuis la méthodologie v6, sinon la valeur historique.
    var latencyMs: Double? { valid(result.primaryPingMs) }
    var latencyIsMinimum: Bool { (result.methodologyVersion ?? 0) >= 6 && result.pingMinMs != nil }

    /// Ce que la latence prend quand la ligne est pleine : latence en réception (en
    /// envoi à défaut) moins la latence affichée, jamais négatif. Nil sans mesure.
    var underLoad: (deltaMs: Double, whileReceiving: Bool)? {
        guard let base = latencyMs else { return nil }
        if let loaded = valid(result.pingDlMs) { return (max(0, loaded - base), true) }
        if let loaded = valid(result.pingUlMs) { return (max(0, loaded - base), false) }
        return nil
    }

    /// Octets échangés par le test : ceux de la trace (réception + envoi), sinon
    /// le compteur de l'appareil pendant la mesure.
    func transferredBytes(deviceCount: Int?) -> Int64? {
        if let bytes = result.measurementTrace?.runTransferredBytes, bytes.download + bytes.upload > 0 {
            return bytes.download + bytes.upload
        }
        guard let deviceCount, deviceCount > 0 else { return nil }
        return Int64(deviceCount)
    }

    /// Octets et durée utile mesurés d'une phase (`download`, `upload`) de la trace.
    func measured(_ phase: String) -> (bytes: Int64, usefulSeconds: Double)? {
        guard let trace = result.measurementTrace?.phases.last(where: { $0.phase == phase }) else { return nil }
        let bytes = trace.finalMeasurement?.bytes ?? trace.measuredBytes
        let durationMs = trace.finalMeasurement?.durationMs ?? trace.usefulDurationMs
        guard bytes > 0, durationMs > 0 else { return nil }
        return (bytes, Double(durationMs) / 1_000)
    }

    var uploadMbps: Double? { valid(result.uploadAverageMbps).flatMap { $0 > 0 ? $0 : nil } }

    private func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// Onglets de la feuille « Détails du test ».
enum SpeedtestDetailsTab: Hashable, Identifiable {
    case speed, latency, radio, server
    var id: Self { self }
}

/// Apparition d'un bloc du résultat : il monte de 16 pt en 0,5 s, en décalé, une
/// fois par test. Rien en « Réduire les animations ».
private struct SpeedtestRise: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.5).delay(delay), value: shown)
    }
}

/// Le résultat : deux grands chiffres, trois tuiles, une ligne de contexte,
/// « Enregistré dans l'historique », Relancer et Détails. Rien d'autre.
struct SpeedtestResultSummary: View {
    let result: SpeedtestRunResult
    /// Octets comptés par l'appareil pendant la mesure (repli de la trace).
    let deviceBytes: Int?
    /// Débit habituel de l'opérateur autour du test, en mobile seulement.
    let typical: SpeedtestVerdictCard.Typical?
    let restartTitle: String
    let onRestart: () -> Void
    let onDetails: (SpeedtestDetailsTab) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var shown = false

    private var figures: SpeedtestResultFigures { SpeedtestResultFigures(result: result) }

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            Text(kicker)
                .font(SQFont.body(10, .bold, relativeTo: .caption))
                .tracking(10 * 0.18)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .modifier(SpeedtestRise(shown: shown, delay: 0))

            rates

            tiles

            context
                .modifier(SpeedtestRise(shown: shown, delay: 0.44))

            Label("Enregistré dans l'historique", systemImage: "checkmark")
                .font(SQFont.body(12.5, .bold, relativeTo: .caption))
                .foregroundStyle(SQColor.success)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(SQColor.successSoft, in: Capsule(style: .continuous))
                .modifier(SpeedtestRise(shown: shown, delay: 0.5))
                .accessibilityIdentifier("speedtest.result.saved")

            actions
                .modifier(SpeedtestRise(shown: shown, delay: 0.56))
        }
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedtest.result")
    }

    private var kicker: String {
        let age = Date().timeIntervalSince(result.createdAt) < 60
            ? String(localized: "à l'instant")
            : result.createdAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "Résultat · \(age)")
    }

    // MARK: Deux grands chiffres

    @ViewBuilder
    private var rates: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SQSpace.lg)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            rate(title: String(localized: "↓ Descendant"), average: result.downloadAverageMbps, max: result.downloadMaxMbps)
                .modifier(SpeedtestRise(shown: shown, delay: 0.06))
            if !dynamicTypeSize.isAccessibilitySize {
                Rectangle().fill(SQColor.separator).frame(width: 1).padding(.vertical, SQSpace.xs)
            }
            rate(title: String(localized: "↑ Montant"), average: figures.uploadMbps, max: result.uploadMaxMbps)
                .modifier(SpeedtestRise(shown: shown, delay: 0.14))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rate(title: String, average: Double?, max: Double?) -> some View {
        let unit = SQUnits.throughputUnit(mbps: average ?? 0)
        return VStack(spacing: 3) {
            Text(verbatim: title)
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .foregroundStyle(SQColor.ink2)
            Text(verbatim: average.map { SQUnits.throughputValue(mbps: $0) } ?? "—")
                .font(SQFont.display(54, .heavy, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if average != nil {
                Text(verbatim: unit)
                    .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let max, max > 0, average != nil {
                // Même unité que la moyenne, sinon la valeur porte la sienne.
                let value = SQUnits.throughputUnit(mbps: max) == unit
                    ? SQUnits.throughputValue(mbps: max) : SQUnits.throughput(mbps: max)
                Text(verbatim: "MAX \(value)")
                    .font(SQFont.body(12, .semibold, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.ink2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Trois tuiles

    @ViewBuilder
    private var tiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SQSpace.sm)) : AnyLayout(HStackLayout(alignment: .top, spacing: SQSpace.sm))
        layout {
            if let latency = figures.latencyMs {
                tile(
                    title: figures.latencyIsMinimum ? String(localized: "Latence min.") : String(localized: "Latence"),
                    value: "\(Int(latency.rounded()))", unit: "ms",
                    detail: result.jitterMs.map { String(localized: "gigue \(SQUnits.jitterValue($0)) ms") },
                    tab: .latency, delay: 0.26, identifier: "speedtest.result.latency"
                )
            }
            if let load = figures.underLoad {
                tile(
                    title: String(localized: "Sous charge"),
                    value: "+\(Int(load.deltaMs.rounded()))", unit: "ms",
                    detail: load.whileReceiving ? String(localized: "en réception") : String(localized: "en envoi"),
                    tab: .latency, delay: 0.32, identifier: "speedtest.result.underLoad"
                )
            }
            if let bytes = figures.transferredBytes(deviceCount: deviceBytes) {
                tile(
                    title: String(localized: "Données"),
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), unit: nil,
                    detail: String(localized: "réception et envoi"),
                    tab: .speed, delay: 0.38, identifier: "speedtest.result.data"
                )
            }
        }
        // Même hauteur pour les trois tuiles, même quand un détail passe sur deux lignes.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(title: String, value: String, unit: String?, detail: String?, tab: SpeedtestDetailsTab,
                      delay: Double, identifier: String) -> some View {
        Button {
            Haptics.selection()
            onDetails(tab)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(SQFont.body(9.5, .bold, relativeTo: .caption2))
                    .tracking(9.5 * 0.08)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: value)
                        .font(SQFont.display(17, .heavy, relativeTo: .headline))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    if let unit {
                        Text(verbatim: unit)
                            .font(SQFont.body(11, .semibold, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if let detail {
                    Text(verbatim: detail)
                        .font(SQFont.body(10.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .topLeading)
            .sqCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Ouvre les détails du test"))
        .accessibilityIdentifier(identifier)
        .modifier(SpeedtestRise(shown: shown, delay: delay))
    }

    // MARK: Contexte et actions

    private var context: some View {
        VStack(spacing: SQSpace.xxs) {
            Text(verbatim: contextLine)
                .font(SQFont.body(12, .medium, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(SQColor.ink2)
            if let typical {
                Text("\(typical.operatorLabel) fait habituellement \(SQUnits.throughput(mbps: Double(typical.mbps))) ici.")
                    .font(SQFont.body(12, .medium, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// « Orange · 5G NSA · Cloudflare Paris · 11:21 ».
    private var contextLine: String {
        var parts: [String] = []
        if let name = result.networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        parts.append(result.networkDisplayName)
        if let server = (result.downloadServerName ?? result.serverName)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !server.isEmpty {
            parts.append(server)
        }
        parts.append(result.createdAt.formatted(date: .omitted, time: .shortened))
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: SQSpace.sm) {
            Button {
                onRestart()
            } label: {
                Label(restartTitle, systemImage: "play.fill")
                    .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
                    .background(SQColor.label, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityIdentifier("speedtest.start")

            Button {
                Haptics.selection()
                onDetails(.radio)
            } label: {
                Text("Détails")
                    .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
                    .background(SQColor.chip, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityIdentifier("speedtest.result.details")
        }
    }
}

/// Le dernier test, sous le GO : ouvre sa fiche.
struct SpeedtestLastTestCard: View {
    let result: SpeedtestRunResult
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.sm2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dernier test · \(when)")
                        .font(SQFont.body(9.5, .bold, relativeTo: .caption2))
                        .tracking(9.5 * 0.18)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text(verbatim: summary)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .sqCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Voir le détail du test"))
        .accessibilityIdentifier("speedtest.lastTest")
    }

    private var when: String {
        result.createdAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// « ↓ 612 · ↑ 74 Mbit/s · 21 ms ».
    private var summary: String {
        let down = result.downloadAverageMbps
        var text = "↓ \(SQUnits.throughputValue(mbps: down))"
        if let up = result.uploadAverageMbps, up > 0 {
            text += SQUnits.throughputUnit(mbps: up) == SQUnits.throughputUnit(mbps: down)
                ? " · ↑ \(SQUnits.throughput(mbps: up))"
                : " \(SQUnits.throughputUnit(mbps: down)) · ↑ \(SQUnits.throughput(mbps: up))"
        } else {
            text += " \(SQUnits.throughputUnit(mbps: down))"
        }
        if let ping = result.primaryPingMs, ping.isFinite, ping >= 0 {
            text += " · \(SQUnits.milliseconds(ping))"
        }
        return text
    }
}

// MARK: - Feuille « Détails du test »

/// Quatre onglets (Débit, Latence, Radio, Serveur), mêmes groupes qu'Android.
/// Une valeur absente ne donne pas de ligne « — » : elle est citée une fois en bas.
struct SpeedtestTestDetailsSheet: View {
    let result: SpeedtestRunResult
    @State var tab: SpeedtestDetailsTab
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var figures: SpeedtestResultFigures { SpeedtestResultFigures(result: result) }

    struct DetailRow: Identifiable {
        var id: String { key }
        let key: String
        let value: String?
    }

    struct DetailGroup: Identifiable {
        var id: String { title }
        let title: String
        let rows: [DetailRow]
        /// Lignes propres à un sens (Moyenne, MAX…) : une absence nomme aussi le sens.
        var perDirection = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                MessageSheetHeader(title: "Détails du test", closeIdentifier: "speedtest.details.close", onClose: onClose)
                MapSegmented(
                    selection: $tab,
                    options: [
                        (.speed, String(localized: "Débit")),
                        (.latency, String(localized: "Latence")),
                        (.radio, String(localized: "Radio")),
                        (.server, String(localized: "Serveur"))
                    ],
                    identifier: "speedtest.details.tabs"
                )
                .accessibilityElement(children: .contain)

                let groups = Self.groups(for: tab, figures: figures)
                ForEach(groups) { group in
                    let rows = group.rows.filter { $0.value != nil }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: group.title)
                                .font(SQFont.body(9.5, .bold, relativeTo: .caption2))
                                .tracking(9.5 * 0.18)
                                .textCase(.uppercase)
                                .foregroundStyle(SQColor.labelSecondary)
                                .padding(.bottom, SQSpace.xs)
                                .sqHeader()
                            ForEach(rows) { row in
                                dotRow(row.key, row.value ?? "")
                            }
                        }
                    }
                }

                let missing = Self.missing(in: groups)
                if !missing.isEmpty {
                    Text("Non relevés pendant ce test : \(missing.joined(separator: ", ")).")
                        .font(SQFont.body(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("speedtest.details.missing")
                }

                if let tip = Self.tip(for: tab) {
                    Text(verbatim: tip)
                        .font(SQFont.body(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SQColor.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .signalQuestBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("speedtest.details")
    }

    private func dotRow(_ label: String, _ value: String) -> some View {
        let labelText = Text(verbatim: label)
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.ink2)
        let valueText = Text(verbatim: value)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(SQColor.label)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
        return SwiftUI.Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    labelText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SQSpace.xs)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    labelText.layoutPriority(1)
                    SQDotLeader()
                        .frame(minWidth: SQSpace.md, maxWidth: .infinity)
                        .frame(height: 1)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    valueText.layoutPriority(1)
                }
                .frame(minHeight: 34)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Contenu (testable)

    static func groups(for tab: SpeedtestDetailsTab, figures: SpeedtestResultFigures) -> [DetailGroup] {
        let result = figures.result
        switch tab {
        case .speed:
            let down = figures.measured("download")
            let up = figures.measured("upload")
            return [
                DetailGroup(title: String(localized: "↓ Descendant"), rows: [
                    DetailRow(key: String(localized: "Moyenne"), value: speed(result.downloadAverageMbps)),
                    DetailRow(key: "MAX", value: speed(result.downloadMaxMbps)),
                    DetailRow(key: String(localized: "Données mesurées"), value: down.map { bytes($0.bytes) }),
                    DetailRow(key: String(localized: "Durée utile"), value: down.map { seconds($0.usefulSeconds) })
                ], perDirection: true),
                DetailGroup(title: String(localized: "↑ Montant"), rows: [
                    DetailRow(key: String(localized: "Moyenne"), value: speed(result.uploadAverageMbps)),
                    DetailRow(key: "MAX", value: speed(result.uploadMaxMbps)),
                    DetailRow(key: String(localized: "Données mesurées"), value: up.map { bytes($0.bytes) }),
                    DetailRow(key: String(localized: "Durée utile"), value: up.map { seconds($0.usefulSeconds) })
                ], perDirection: true)
            ]
        case .latency:
            let idle = result.pingProtocol.map { String(localized: "Au repos · \($0)") } ?? String(localized: "Au repos")
            return [
                DetailGroup(title: idle, rows: [
                    DetailRow(key: String(localized: "Minimum"), value: ms(result.pingMinMs)),
                    DetailRow(key: String(localized: "Médiane"), value: ms(result.pingMedianMs)),
                    DetailRow(key: String(localized: "Maximum"), value: ms(result.pingMaxMs)),
                    DetailRow(key: String(localized: "Gigue"), value: result.jitterMs.flatMap { $0.isFinite && $0 >= 0 ? SQUnits.jitter($0) : nil })
                ]),
                DetailGroup(title: String(localized: "Sous charge"), rows: [
                    DetailRow(key: String(localized: "Pendant la réception"), value: ms(result.pingDlMs)),
                    DetailRow(key: String(localized: "Pendant l'envoi"), value: ms(result.pingUlMs))
                ])
            ]
        case .radio:
            let operatorName = result.networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                DetailGroup(title: String(localized: "Pendant le test"), rows: [
                    DetailRow(key: String(localized: "Opérateur"), value: operatorName?.isEmpty == false ? operatorName : nil),
                    DetailRow(key: String(localized: "Réseau"), value: result.networkDisplayName),
                    DetailRow(key: "MCC-MNC", value: result.observedPlmn.map { SpeedtestTestDetailsSheet.plmn($0) }),
                    DetailRow(key: String(localized: "Itinérance"), value: result.isRoaming.map { $0 ? String(localized: "Oui") : String(localized: "Non") })
                ])
            ]
        case .server:
            return [
                DetailGroup(title: String(localized: "Serveurs"), rows: [
                    DetailRow(key: String(localized: "Réception"), value: text(result.downloadServerName ?? result.serverName)),
                    DetailRow(key: String(localized: "Envoi"), value: text(result.uploadServerHost)),
                    DetailRow(key: String(localized: "Latence"), value: text(result.pingServerHost))
                ]),
                DetailGroup(title: String(localized: "Méthode"), rows: [
                    DetailRow(key: String(localized: "Moteur"), value: text(result.engine)),
                    DetailRow(key: String(localized: "Méthodologie"), value: result.methodologyVersion.map { "v\($0)" })
                ])
            ]
        }
    }

    /// Valeurs absentes, citées une seule fois : un groupe entièrement absent (pas
    /// d'envoi mesuré) se nomme d'un mot, sinon chaque ligne manquante.
    static func missing(in groups: [DetailGroup]) -> [String] {
        var names: [String] = []
        func add(_ name: String) { if !names.contains(name) { names.append(name) } }
        for group in groups {
            let absent = group.rows.filter { $0.value == nil }
            guard !absent.isEmpty else { continue }
            let groupName = group.title.trimmingCharacters(in: CharacterSet(charactersIn: "↓↑ ")).lowercased()
            if absent.count == group.rows.count {
                add(groupName)
                continue
            }
            for row in absent {
                // Les sigles (MAX, MCC-MNC) restent en capitales.
                let key = row.key == row.key.uppercased() ? row.key : row.key.lowercased()
                add(group.perDirection ? "\(key) (\(groupName))" : key)
            }
        }
        return names
    }

    static func tip(for tab: SpeedtestDetailsTab) -> String? {
        switch tab {
        case .speed:
            return String(localized: "Moyenne : données reçues divisées par la durée utile, après la montée en charge. MAX : la meilleure seconde.")
        case .latency:
            return String(localized: "Sous charge : la latence pendant que la ligne est pleine. Plus elle s'éloigne de la latence au repos, plus la visio ou le jeu en souffrent.")
        case .radio:
            return String(localized: "iOS ne donne pas accès au signal radio (puissance, bandes, cellule) : seuls l'opérateur et le type de réseau sont connus.")
        case .server:
            return nil
        }
    }

    private static func speed(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return SQUnits.throughput(mbps: value)
    }

    private static func ms(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return SQUnits.milliseconds(value)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// « 20801 » → « 208-01 » ; laissé tel quel s'il n'a pas la forme attendue.
    static func plmn(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard digits.count == 5 || digits.count == 6 else { return value }
        return "\(digits.prefix(3))-\(digits.dropFirst(3))"
    }
}
