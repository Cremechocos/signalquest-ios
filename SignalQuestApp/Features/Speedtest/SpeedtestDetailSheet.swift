import SwiftUI

/// Fiche d'un speedtest de l'historique. Mêmes chiffres que l'image de partage
/// — y compris les vraies courbes DL/UL du moteur, montée en charge comprise.
///
/// La ligne d'historique portait un chevron sans action : l'affordance mentait.
struct SpeedtestDetailSheet: View {
    let result: SpeedtestRunResult
    /// Centre la carte sur le lieu du test. `nil` masque le bouton.
    var onShowOnMap: ((Coordinates) -> Void)?
    @StateObject private var visibility: SpeedtestVisibilityViewModel
    @State private var sharePreviewResult: SpeedtestRunResult?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    init(result: SpeedtestRunResult, onShowOnMap: ((Coordinates) -> Void)? = nil,
         visibilityService: any SpeedtestVisibilityServicing, guestMode: Bool) {
        self.result = result
        self.onShowOnMap = onShowOnMap
        _visibility = StateObject(wrappedValue: SpeedtestVisibilityViewModel(
            clientID: result.id, service: visibilityService, guestMode: guestMode,
            vpnIsActive: { VPNDetector.isActive() }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "speedtest.detail.close") {
                        dismiss()
                    }
                    Spacer()
                    MapChipIconButton(systemImage: "square.and.arrow.up", label: "Partager",
                                      identifier: "speedtest.detail.share") {
                        sharePreviewResult = result
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                // « Voir sur la carte » rejoint la carte Visibilité, à côté de
                // « Masquer » : le contenu ne le rend donc pas une seconde fois.
                SpeedtestDetailContent(
                    result: result,
                    onDismiss: { dismiss() },
                    visibilityStatus: SpeedtestVisibilityControls.status(for: visibility)
                )
                SpeedtestVisibilityControls(model: visibility, onShowOnMap: showOnMapAction)
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.bottom, SQSpace.xl)
            }
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await visibility.load() }
        .onDisappear { visibility.deactivate() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { visibility.refreshAvailability() }
        }
        .sheet(item: $sharePreviewResult) { item in
            SpeedtestSharePreviewSheet(result: item, theme: SQShareCardTheme.current(colorScheme: colorScheme))
        }
    }

    private var showOnMapAction: (() -> Void)? {
        guard let onShowOnMap, let coordinate = result.coordinate else { return nil }
        return {
            onShowOnMap(coordinate)
            dismiss()
        }
    }

    static func formatSpeedParts(_ mbps: Double?) -> (value: String, unit: String) {
        SpeedtestDetailContent.formatSpeedParts(mbps)
    }
}

/// Pastille de visibilité affichée sous le titre et dans la carte Visibilité.
struct SpeedtestVisibilityStatus: Equatable {
    enum Tone { case positive, neutral, caution }
    let text: String
    let tone: Tone
}

/// Corps de la fiche, hors chrome de navigation : rendable seul par
/// `ImageRenderer`, donc réellement vérifiable en test (un `NavigationStack`
/// ne rend qu'un placeholder — un test qui l'ignore valide une image vide).
struct SpeedtestDetailContent: View {
    let result: SpeedtestRunResult
    var onShowOnMap: ((Coordinates) -> Void)?
    var onDismiss: (() -> Void)?
    var visibilityStatus: SpeedtestVisibilityStatus? = nil
    @State private var graphDirection: GraphDirection = .download
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum GraphDirection: Hashable { case download, upload }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            header
            speedSummaryCard
            // Le verdict en mots avant les courbes ; sans comparaison de zone :
            // un test ancien ne se compare pas à l'habitude d'aujourd'hui.
            if result.downloadAverageMbps > 0 {
                SpeedtestVerdictCard(verdict: SpeedtestVerdict(result: result),
                                     measuredMbps: result.downloadAverageMbps)
            }
            curveCard
            latencyCard
            measureCard
            actions
        }
        .padding(SQSpace.lg)
        .padding(.bottom, SQSpace.xl)
    }

    // MARK: En-tête — « Speedtest · Orange 5G », lieu et date, pastilles

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.xs) {
                Text(verbatim: kickerLine)
                    .font(SQFont.body(12, .bold, relativeTo: .caption))
                    .tracking(12 * 0.16)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // « 5G NSA » et « 5G SA » sont le seul jargon de l'en-tête : ⓘ (MES-35).
                if result.connectionType == .cellular,
                   result.cellularTechnology == .fiveGNSA || result.cellularTechnology == .fiveGSA {
                    SQInfoButton(term: .fiveGModes)
                }
            }
            Text(verbatim: titleLine)
                .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if visibilityStatus != nil || deviceModel != nil {
                let pills = Group {
                    if let visibilityStatus {
                        SpeedtestStatusPill(status: visibilityStatus, systemImage: visibilityStatus.tone == .positive ? "eye" : nil)
                    }
                    if let deviceModel {
                        SpeedtestStatusPill(status: SpeedtestVisibilityStatus(text: deviceModel, tone: .neutral))
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: SQSpace.xs) { pills }
                } else {
                    HStack(spacing: SQSpace.xs) { pills }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generation: String? {
        switch result.connectionType {
        case .wifi: return "Wi‑Fi"
        case .cellular: return result.cellularTechnology?.displayName ?? String(localized: "Cellulaire")
        case .wired: return "Ethernet"
        case .other: return nil
        }
    }

    /// « Speedtest · Orange 5G SA », « Speedtest · Wi‑Fi ».
    private var kickerLine: String {
        let op = result.networkOperatorName?.trimmedNonEmptyDetail
        var network = [op, generation].compactMap { $0 }.joined(separator: " ")
        if network.isEmpty { network = result.networkShareDisplayName }
        return [String(localized: "Speedtest"), network.trimmedNonEmptyDetail].compactMap { $0 }.joined(separator: " · ")
    }

    /// « Lyon 7ᵉ — 11 oct., 14:05 » ; l'année seulement quand elle diffère.
    private var titleLine: String {
        let sameYear = Calendar.current.isDate(result.createdAt, equalTo: Date(), toGranularity: .year)
        let date = sameYear
            ? result.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : result.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        guard let city = result.city?.trimmedNonEmptyDetail else { return date }
        return "\(city) — \(date)"
    }

    private var deviceModel: String? { result.deviceModel?.trimmedNonEmptyDetail }

    // MARK: Débits mesurés — jauge et trois valeurs

    private var speedSummaryCard: some View {
        detailCard("Débits mesurés") {
            // 280 pt dans la carte ; un iPhone étroit prend la jauge réduite.
            ViewThatFits(in: .horizontal) {
                dial(width: 280)
                dial(width: 240)
            }
            .frame(maxWidth: .infinity)
            let metrics = Group {
                let upload = Self.formatSpeedParts(result.uploadAverageMbps)
                triCell("Envoi", value: upload.value, unit: upload.unit)
                triCell("Latence", value: Self.msText(result.primaryPingMs), unit: "ms")
                triCell("Gigue", value: Self.decimalText(result.jitterMs), unit: "ms")
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) { metrics }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Trois tuiles de même hauteur, même quand l'une passe sur deux lignes.
                HStack(alignment: .top, spacing: SQSpace.sm) { metrics }
                    .fixedSize(horizontal: false, vertical: true)
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

    private func triCell(_ title: LocalizedStringKey, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SQFont.body(11, .bold, relativeTo: .caption2))
                .tracking(11 * 0.12)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // La valeur ne se coupe jamais : l'unité passe dessous si la tuile
            // est trop étroite (« 45,0 » puis « Mbit/s »).
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

    // MARK: Débit pendant le test — mêmes courbes réelles que l'image de partage

    private var curveCard: some View {
        detailCard("Débit pendant le test") {
            MapSegmented(
                selection: $graphDirection,
                options: [(.download, String(localized: "Réception")), (.upload, String(localized: "Envoi"))],
                identifier: "speedtest.detail.curve"
            )
            switch graphDirection {
            case .download:
                curve(
                    title: "Réception",
                    accent: SQColor.success,
                    average: result.downloadAverageMbps,
                    maxValue: result.downloadMaxMbps,
                    series: result.downloadSeriesMbps,
                    graceCount: result.downloadGraceWindowCount,
                    trace: result.measurementTrace?.phases.first { $0.phase == "download" }
                )
            case .upload:
                curve(
                    title: "Envoi",
                    accent: SQColor.warning,
                    average: result.uploadAverageMbps,
                    maxValue: result.uploadMaxMbps,
                    series: result.uploadSeriesMbps,
                    graceCount: result.uploadGraceWindowCount,
                    trace: result.measurementTrace?.phases.first { $0.phase == "upload" }
                )
            }
        }
    }

    @ViewBuilder
    private func curve(
        title: String,
        accent: Color,
        average: Double?,
        maxValue: Double?,
        series: [Double]?,
        graceCount: Int?,
        trace: SpeedtestPhaseTrace? = nil
    ) -> some View {
        SpeedtestShareGraph(
            series: (series ?? []).filter { $0.isFinite && $0 >= 0 },
            averageMbps: average ?? 0,
            graceCount: max(0, graceCount ?? 0),
            accent: accent,
            plotBackground: SQColor.surfaceMuted,
            gridColor: SQColor.separator,
            labelColor: SQColor.labelSecondary,
            timedSeries: trace?.recentSeries,
            timedAverageSeries: trace?.averageSeries,
            timeOriginMs: trace?.sampleStartMs,
            unitLabel: SQUnits.throughputUnit(mbps: 0)
        )
        .frame(height: 120)
        // Alternative non visuelle (A11Y-08) : la courbe de débit n'a aucun
        // descripteur accessible, on la résume pour VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.graphAccessibilityLabel(title: title, average: average, maxValue: maxValue))
        if let average, average.isFinite, average > 0, let maxValue, maxValue.isFinite, maxValue > 0 {
            let avg = Self.formatSpeedParts(average)
            let peak = Self.formatSpeedParts(maxValue)
            Text("Moyenne \(avg.value) \(avg.unit) · max \(peak.value) \(peak.unit)")
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
        } else {
            Text("Mesure indisponible")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        if let trace {
            ForEach(Self.throughputSourceLabels(trace), id: \.self) { label in
                Text(label).font(.caption).foregroundStyle(SQColor.labelSecondary)
            }
            Text("Débit récent · fenêtre de 1 s · pointillés : moyenne cumulée")
                .font(.caption).foregroundStyle(SQColor.labelSecondary)
            Text("Mesure : \(Double(trace.sampleDurationMs) / 1000, format: .number.precision(.fractionLength(2))) s · MAX sur \(Double(Self.maxWindowMs(trace)) / 1000, format: .number.precision(.fractionLength(2))) s")
                .font(.caption).foregroundStyle(SQColor.labelSecondary)
        } else if !(series ?? []).isEmpty {
            Text("Courbe historique sans horodatage")
                .font(.caption).foregroundStyle(SQColor.labelSecondary)
        }
    }

    // MARK: Latence — au repos, gigue, et les deux latences en charge

    private var latencyCard: some View {
        detailCard("Latence") {
            VStack(spacing: SQSpace.xxs) {
                dotRow("Au repos", "\(Self.msText(result.primaryPingMs)) ms", trailing: result.pingProtocol?.trimmedNonEmptyDetail)
                if let minMs = result.pingMinMs, let maxMs = result.pingMaxMs {
                    dotRow("Min · max", "\(Int(minMs.rounded())) · \(Int(maxMs.rounded())) ms")
                }
                dotRow("Gigue", "\(Self.decimalText(result.jitterMs)) ms")
                dotRow("En réception", "\(Self.msText(result.pingDlMs)) ms", trailing: gigue(result.jitterDlMs))
                dotRow("En envoi", "\(Self.msText(result.pingUlMs)) ms", trailing: gigue(result.jitterUlMs))
                if let average = result.pingMs {
                    dotRow("Latence moyenne", "\(Self.msText(average)) ms")
                }
                if result.methodologyVersion == nil {
                    dotRow("Mesure de latence", String(localized: "Valeur historique"))
                }
            }
        }
    }

    private func gigue(_ jitter: Double?) -> String {
        let label = String(localized: "gigue")
        guard let jitter, jitter.isFinite else { return "\(label) —" }
        return "\(label) ±\(Self.decimalText(jitter))"
    }

    // MARK: Mesure — réseau, serveurs, appareil, octets réellement comptés

    private var measureCard: some View {
        detailCard("Détails de la mesure") {
            VStack(spacing: SQSpace.xxs) {
                dotRow("Réseau", result.networkShareDisplayName)
                if let city = result.city?.trimmedNonEmptyDetail {
                    dotRow("Lieu", city)
                }
                if let server = (result.serverName ?? result.downloadServerName)?.trimmedNonEmptyDetail {
                    dotRow("Serveur de mesure", server)
                }
                if let device = deviceLine {
                    dotRow("Appareil", device)
                }
                if let host = result.downloadServerHost {
                    dotRow("Serveur de réception", endpoint(host, result.downloadServerPort))
                }
                if let host = result.uploadServerHost {
                    dotRow("Serveur d’envoi", endpoint(host, result.uploadServerPort))
                }
                if let host = result.pingServerHost {
                    dotRow("Serveur de latence", endpoint(host, result.pingServerPort))
                }
                if let version = result.methodologyVersion {
                    dotRow("Méthodologie", String(version))
                }
                if let source = Self.resultByteSource(result.measurementTrace?.phases.first(where: { $0.phase == "upload" }), fallback: result.uploadMeasurementSource) {
                    dotRow("Comptage de l’envoi", Self.byteSourceLabel(source))
                }
                // Octets comptés pendant la fenêtre de mesure, avec leur source.
                ForEach(measuredByteRows, id: \.label) { row in
                    dotRow(row.label, row.value, localized: false)
                }
            }
        }
    }

    private var measuredByteRows: [(label: String, value: String)] {
        let phases = ["download", "upload"].compactMap { name in
            result.measurementTrace?.phases.first { $0.phase == name && $0.measuredBytes > 0 }
        }
        return phases.map { phase in
            (Self.byteSourceLabel(phase.byteSource),
             ByteCountFormatter.string(fromByteCount: phase.measuredBytes, countStyle: .file))
        }
    }

    static func resultByteSource(_ phase: SpeedtestPhaseTrace?, fallback: String?) -> String? {
        phase?.finalMeasurement?.source ?? fallback ?? phase?.byteSource
    }

    static func maxByteSource(_ phase: SpeedtestPhaseTrace) -> String {
        if let receipt = phase.finalMeasurement, receipt.maxMbps != nil { return receipt.source }
        return phase.sampleByteSource
    }

    static func maxWindowMs(_ phase: SpeedtestPhaseTrace) -> Int64 {
        if let receipt = phase.finalMeasurement, receipt.maxMbps != nil { return receipt.peakWindowMs }
        return phase.peakWindowMs
    }

    static func throughputSourceLabels(_ phase: SpeedtestPhaseTrace, bundle: Bundle = .main) -> [String] {
        let curveSource = phase.sampleByteSource
        let maxSource = maxByteSource(phase)
        let curveLabel = byteSourceLabel(curveSource, bundle: bundle)
        if curveSource == maxSource {
            return [String(localized: "Courbe et MAX : \(curveLabel)", bundle: bundle)]
        }
        let maxLabel = byteSourceLabel(maxSource, bundle: bundle)
        return [String(localized: "Courbe : \(curveLabel)", bundle: bundle),
                String(localized: "MAX : \(maxLabel)", bundle: bundle)]
    }

    static func byteSourceLabel(_ source: String, bundle: Bundle = .main) -> String {
        switch source {
        case "tcp-acknowledged": return String(localized: "Acquittés TCP (en-têtes inclus)", bundle: bundle)
        case "server-received": return String(localized: "Reçus côté serveur", bundle: bundle)
        case "client-written": return String(localized: "Écrits côté client", bundle: bundle)
        case "client-received": return String(localized: "Reçus côté client", bundle: bundle)
        default: return String(localized: "Source inconnue", bundle: bundle)
        }
    }

    private func endpoint(_ host: String, _ port: Int?) -> String {
        port.map { "\(host):\($0)" } ?? host
    }

    private var deviceLine: String? {
        let model = result.deviceModel?.trimmedNonEmptyDetail
        let os = result.osVersion?.trimmedNonEmptyDetail
        return [model, os].compactMap { $0 }.joined(separator: " • ").trimmedNonEmptyDetail
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

    /// Ligne clé · · · valeur, comme le « Diagnostic radio » du web. Les très
    /// grands textes empilent la clé et la valeur plutôt que de les tronquer.
    private func dotRow(_ label: String, _ value: String, trailing: String? = nil, localized: Bool = true) -> some View {
        let valueText = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: value)
                .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
            if let trailing {
                Text(verbatim: trailing)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        let labelText = (localized ? Text(LocalizedStringKey(label)) : Text(verbatim: label))
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    labelText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SQSpace.xxs)
            } else {
                // Le libellé et la valeur passent avant les pointillés, qui
                // remplissent seulement l'espace restant.
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    labelText
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

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if let onShowOnMap, let coordinate = result.coordinate {
            GradientButton("Voir ce lieu sur la carte", systemImage: "map.fill", style: .secondary) {
                onShowOnMap(coordinate)
                onDismiss?()
            }
        }
    }

    // MARK: Formats

    private static let frFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// « 487 Mbit/s », « 45,3 Mbit/s », « 1,4 Gbit/s » (« Mbps » en anglais) :
    /// le formateur commun (`SQUnits`), plus un tiret quand la mesure manque.
    static func formatSpeedParts(_ mbps: Double?) -> (value: String, unit: String) {
        guard let mbps, mbps.isFinite, mbps > 0 else { return ("—", SQUnits.throughputUnit(mbps: 0)) }
        return (SQUnits.throughputValue(mbps: mbps), SQUnits.throughputUnit(mbps: mbps))
    }

    /// Résumé textuel de la courbe de débit pour VoiceOver : direction (Réception /
    /// Envoi), débit moyen et pic, à partir des valeurs déjà affichées dans la carte.
    static func graphAccessibilityLabel(title: String, average: Double?, maxValue: Double?) -> String {
        let direction = title == "Réception" ? String(localized: "Réception")
            : title == "Envoi" ? String(localized: "Envoi") : title
        let averageLabel = String(localized: "moyenne")
        let peakLabel = String(localized: "pic")
        let unavailable = String(localized: "indisponible")
        let avgText: String
        if let average, average.isFinite, average > 0 {
            let parts = formatSpeedParts(average)
            avgText = "\(averageLabel) \(parts.value) \(parts.unit)"
        } else {
            avgText = "\(averageLabel) \(unavailable)"
        }
        let maxText: String
        if let maxValue, maxValue.isFinite, maxValue > 0 {
            let parts = formatSpeedParts(maxValue)
            maxText = "\(peakLabel) \(parts.value) \(parts.unit)"
        } else {
            maxText = "\(peakLabel) \(unavailable)"
        }
        return String(localized: "Courbe de débit \(direction) : \(avgText), \(maxText).")
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        frFormatter.minimumFractionDigits = 0
        frFormatter.maximumFractionDigits = digits
        return frFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    private static func msText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private static func decimalText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return decimal(value, digits: 1)
    }
}

private extension String {
    var trimmedNonEmptyDetail: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}


/// Pastille de la fiche : visibilité (verte, neutre ou ambre) ou appareil.
struct SpeedtestStatusPill: View {
    let status: SpeedtestVisibilityStatus
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: status.text)
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, SQSpace.sm2)
        .padding(.vertical, 5)
        .frame(minHeight: 26)
        .background(background, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch status.tone {
        case .positive: return SQColor.success
        case .caution: return SQColor.warning
        case .neutral: return SQColor.label
        }
    }

    private var background: Color {
        switch status.tone {
        case .positive: return SQColor.successSoft
        case .caution: return SQColor.warningSoft
        case .neutral: return SQColor.chip
        }
    }
}

/// État serveur et actions de cette fiche ; aucun optimisme sur la visibilité.
struct SpeedtestVisibilityControls: View {
    @ObservedObject var model: SpeedtestVisibilityViewModel
    /// « Voir sur la carte », à côté de « Masquer ». `nil` sans position.
    var onShowOnMap: (() -> Void)? = nil
    @State private var publicationConfirmation: SpeedtestVisibilityViewModel.PublicationConfirmation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text("Visibilité")
                        .font(SQFont.body(12, .bold, relativeTo: .caption))
                        .tracking(12 * 0.16)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelSecondary)
                        .sqHeader()
                    Spacer(minLength: SQSpace.xs)
                    SpeedtestStatusPill(status: Self.status(for: model))
                        .accessibilityIdentifier("speedtest.visibility.status")
                }
                if model.isLoading || model.isSaving {
                    ProgressView(model.isSaving
                                 ? String(localized: "Enregistrement et vérification…")
                                 : String(localized: "Vérification de la visibilité…"))
                        .font(SQType.caption)
                        .accessibilityIdentifier("speedtest.visibility.progress")
                }
                if let explanation {
                    Text(explanation)
                        .font(SQType.subhead(.regular))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("speedtest.visibility.error")
                }
                if let message = model.confirmationMessage {
                    Text(message)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.success)
                        .accessibilityIdentifier("speedtest.visibility.confirmation")
                }
                if onShowOnMap != nil || model.canHide {
                    let buttons = Group {
                        if let onShowOnMap {
                            GradientButton("Voir sur la carte", systemImage: "map", style: .secondary, action: onShowOnMap)
                                .accessibilityIdentifier("speedtest.visibility.map")
                        }
                        if model.canHide {
                            GradientButton("Masquer", systemImage: "eye.slash", style: .destructive) {
                                Task { await model.hide() }
                            }
                            .accessibilityLabel("Masquer de la carte")
                            .accessibilityIdentifier("speedtest.visibility.hide")
                        }
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: SQSpace.sm) { buttons }
                    } else {
                        HStack(spacing: SQSpace.sm) { buttons }
                    }
                }
                if model.canPublish {
                    GradientButton("Publier ce test", systemImage: "map", style: .secondary) {
                        publicationConfirmation = model.requestPublicationConfirmation()
                    }
                    .accessibilityIdentifier("speedtest.visibility.publish")
                }
                if !model.isLoading && !model.isSaving && !model.isStateCurrent
                    && model.availability != .guest && model.availability != .sessionChanged {
                    GradientButton("Vérifier la visibilité", systemImage: "arrow.clockwise", style: .ghost) {
                        Task { await model.load() }
                    }
                    .accessibilityIdentifier("speedtest.visibility.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(SQSpace.cardPadding)
            .sqCardBackground()

            if showsHideFootnote {
                Text("Masquer un test le conserve dans ton historique. Sa publication reste soumise aux critères de la carte et à tes zones privées.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
        }
        .confirmationDialog("Publier ce test ?", isPresented: Binding(
            get: { publicationConfirmation != nil },
            set: { if !$0 { publicationConfirmation = nil } }
        ), titleVisibility: .visible, presenting: publicationConfirmation) { confirmation in
            Button("Publier ce test") {
                Task { await model.confirmPublication(confirmation) }
            }
            Button("Annuler", role: .cancel) {
                model.cancelPublicationConfirmation()
                publicationConfirmation = nil
            }
        } message: { _ in
            Text("Sa mesure et sa position enregistrée seront visibles sur la carte publique. Tes zones privées restent appliquées.")
        }
    }

    static func status(for model: SpeedtestVisibilityViewModel) -> SpeedtestVisibilityStatus {
        switch model.availability {
        case .guest: return .init(text: String(localized: "Test invité"), tone: .neutral)
        case .noServerReference: return .init(text: String(localized: "Référence serveur indisponible"), tone: .caution)
        case .sessionChanged: return .init(text: String(localized: "Session modifiée"), tone: .caution)
        case .unknown, .loaded: break
        }
        guard model.isStateCurrent, let state = model.state else {
            return .init(text: String(localized: "Visibilité à vérifier"), tone: .caution)
        }
        if !state.isVisibleOnMap { return .init(text: String(localized: "Masqué de la carte"), tone: .neutral) }
        if !state.isPublic { return .init(text: String(localized: "Non éligible à la carte"), tone: .neutral) }
        if !state.hasMapPosition { return .init(text: String(localized: "Position indisponible"), tone: .caution) }
        return .init(text: String(localized: "Visible sur la carte"), tone: .positive)
    }

    /// Note générale sous la carte, quand le propriétaire peut agir.
    private var showsHideFootnote: Bool {
        guard model.availability == .loaded || model.availability == .unknown,
              model.isStateCurrent, let state = model.state else { return false }
        return state.isOwner && !(model.publicationBlockedByVPN && !state.isVisibleOnMap)
    }

    private var explanation: String? {
        switch model.availability {
        case .guest:
            return String(localized: "Pour supprimer un test invité, ouvre Mes tests partagés.")
        case .noServerReference:
            return String(localized: "Ce test n’a pas de référence serveur disponible. Il peut être en attente de synchronisation ou provenir d’une ancienne version.")
        case .sessionChanged: return nil
        case .unknown, .loaded: break
        }
        guard model.isStateCurrent, let state = model.state else { return nil }
        if !state.isOwner { return String(localized: "Seul le propriétaire peut modifier la visibilité de ce test.") }
        if model.publicationBlockedByVPN && !state.isVisibleOnMap {
            return String(localized: "La publication est indisponible sous VPN. Le masquage reste possible.")
        }
        if state.isVisibleOnMap && state.isPublic && state.hasMapPosition {
            return String(localized: "Sa mesure et sa position enregistrée sont visibles sur la carte publique. Tes zones privées restent appliquées.")
        }
        return nil
    }
}
