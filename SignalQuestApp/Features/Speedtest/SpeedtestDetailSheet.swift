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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    SpeedtestDetailContent(
                        result: result,
                        onShowOnMap: onShowOnMap,
                        onDismiss: { dismiss() }
                    )
                    SpeedtestVisibilityControls(model: visibility)
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.bottom, SQSpace.xl)
                }
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
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await visibility.load() }
        .onDisappear { visibility.deactivate() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { visibility.refreshAvailability() }
        }
    }

    static func formatSpeedParts(_ mbps: Double?) -> (value: String, unit: String) {
        SpeedtestDetailContent.formatSpeedParts(mbps)
    }
}

/// Corps de la fiche, hors chrome de navigation : rendable seul par
/// `ImageRenderer`, donc réellement vérifiable en test (un `NavigationStack`
/// ne rend qu'un placeholder — un test qui l'ignore valide une image vide).
struct SpeedtestDetailContent: View {
    let result: SpeedtestRunResult
    var onShowOnMap: ((Coordinates) -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            header
            // Le verdict en mots avant les courbes ; sans comparaison de zone :
            // un test ancien ne se compare pas à l'habitude d'aujourd'hui.
            if result.downloadAverageMbps > 0 {
                SpeedtestVerdictCard(verdict: SpeedtestVerdict(result: result),
                                     measuredMbps: result.downloadAverageMbps)
            }
            speedCards
            latencyGrid
            metaCard
            actions
        }
        .padding(SQSpace.lg)
        .padding(.bottom, SQSpace.xl)
    }

    // MARK: En-tête — génération, opérateur, commune, date

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        if let generation { generationTitle(generation) }
                        Text(Self.dateFormatter.string(from: result.createdAt))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                } else {
                    HStack(spacing: SQSpace.sm) {
                        if let generation { generationTitle(generation) }
                        Spacer(minLength: 0)
                        Text(Self.dateFormatter.string(from: result.createdAt))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            Text(contextLine)
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « 5G NSA » et « 5G SA » sont le seul jargon de l'en-tête : ⓘ (MES-35).
    private func generationTitle(_ generation: String) -> some View {
        HStack(spacing: SQSpace.xs) {
            Text(generation)
                .font(SQFont.display(20, .bold))
                .foregroundStyle(SQColor.brandRed)
            if result.connectionType == .cellular,
               result.cellularTechnology == .fiveGNSA || result.cellularTechnology == .fiveGSA {
                SQInfoButton(term: .fiveGModes)
            }
        }
    }

    private var generation: String? {
        switch result.connectionType {
        case .wifi: return "Wi‑Fi"
        case .cellular: return result.cellularTechnology?.displayName ?? String(localized: "Cellulaire")
        case .wired: return "Ethernet"
        case .other: return nil
        }
    }

    private var contextLine: String {
        let op = result.networkOperatorName?.trimmedNonEmptyDetail
            ?? (generation == nil ? result.networkShareDisplayName.trimmedNonEmptyDetail : nil)
        let city = result.city?.trimmedNonEmptyDetail
        return [op, city].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Débits — mêmes courbes réelles que l'image de partage

    private var speedCards: some View {
        VStack(spacing: SQSpace.md) {
            speedCard(
                title: "Réception",
                accent: SQColor.success,
                average: result.downloadAverageMbps,
                maxValue: result.downloadMaxMbps,
                series: result.downloadSeriesMbps,
                graceCount: result.downloadGraceWindowCount,
                trace: result.measurementTrace?.phases.first { $0.phase == "download" }
            )
            speedCard(
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

    private func speedCard(
        title: String,
        accent: Color,
        average: Double?,
        maxValue: Double?,
        series: [Double]?,
        graceCount: Int?,
        trace: SpeedtestPhaseTrace? = nil
    ) -> some View {
        let parts = Self.formatSpeedParts(average)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        speedCardHeader(title: title, accent: accent, maxValue: maxValue)
                    }
                } else {
                    HStack(spacing: SQSpace.sm) {
                        speedCardHeader(title: title, accent: accent, maxValue: maxValue)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                Text(parts.value)
                    .font(SQFont.display(40, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Text(parts.unit)
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
            }
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
            .frame(height: 108)
            // Alternative non visuelle (A11Y-08) : la courbe de débit n'a aucun
            // descripteur accessible, on la résume pour VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.graphAccessibilityLabel(title: title, average: average, maxValue: maxValue))
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
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(cornerRadius: SQRadius.lg, elevation: .rest)
    }

    @ViewBuilder
    private func speedCardHeader(title: String, accent: Color, maxValue: Double?) -> some View {
        HStack(spacing: SQSpace.sm) {
            Circle().fill(accent).frame(width: 8, height: 8)
            Text(LocalizedStringKey(title))
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.label)
        }
        if let maxValue, maxValue.isFinite, maxValue > 0 {
            let maxParts = Self.formatSpeedParts(maxValue)
            Text("Max \(maxParts.value) \(maxParts.unit)")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        } else {
            Text("Mesure indisponible")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
    }

    // MARK: Latences — ping, jitter, et les deux pings en charge

    private var latencyGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
            spacing: SQSpace.sm
        ) {
            // Libellés du lexique, traduits : « Ping » et « Jitter » restaient en
            // dur, en majuscules et en 11 pt (TRX-25, TRX-12, TRX-30).
            latencyTile(String(localized: "Latence"), value: Self.msText(result.primaryPingMs), tint: SQColor.labelSecondary, sub: pingSub)
            latencyTile(String(localized: "Gigue"), value: Self.decimalText(result.jitterMs), tint: SQColor.labelSecondary,
                sub: String(localized: "au repos"))
            latencyTile(String(localized: "Latence en réception"), value: Self.msText(result.pingDlMs),
                tint: SQColor.success, sub: gigue(result.jitterDlMs))
            latencyTile(String(localized: "Latence en envoi"), value: Self.msText(result.pingUlMs),
                tint: SQColor.warning, sub: gigue(result.jitterUlMs))
        }
    }

    private var pingSub: String {
        guard let minMs = result.pingMinMs, let maxMs = result.pingMaxMs else { return " " }
        return "min \(Int(minMs.rounded())) · max \(Int(maxMs.rounded()))"
    }

    private func gigue(_ jitter: Double?) -> String {
        let label = String(localized: "gigue")
        guard let jitter, jitter.isFinite else { return "\(label) —" }
        return "\(label) ±\(Self.decimalText(jitter))"
    }

    private func latencyTile(_ label: String, value: String, tint: Color, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(SQType.micro)
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(SQFont.display(22, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Text("ms")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text(sub)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Méta — serveur, appareil, protocole

    private var metaCard: some View {
        VStack(spacing: 0) {
            if let server = (result.serverName ?? result.downloadServerName)?.trimmedNonEmptyDetail {
                metaRow("Serveur de mesure", server, icon: "server.rack")
                Divider().overlay(SQColor.separator)
            }
            if let city = result.city?.trimmedNonEmptyDetail {
                metaRow("Lieu", city, icon: "mappin.and.ellipse")
                Divider().overlay(SQColor.separator)
            }
            metaRow("Réseau", result.networkShareDisplayName, icon: "antenna.radiowaves.left.and.right")
            if let device = deviceLine {
                Divider().overlay(SQColor.separator)
                metaRow("Appareil", device, icon: "iphone")
            }
            if let host = result.downloadServerHost {
                metaRow("Serveur de réception", endpoint(host, result.downloadServerPort), icon: "arrow.down")
            }
            if let host = result.uploadServerHost {
                metaRow("Serveur d’envoi", endpoint(host, result.uploadServerPort), icon: "arrow.up")
            }
            if let host = result.pingServerHost {
                metaRow("Serveur de latence", endpoint(host, result.pingServerPort), icon: "timer")
            }
            if let version = result.methodologyVersion {
                metaRow("Méthodologie", String(version), icon: "info.circle")
            }
            if let source = Self.resultByteSource(result.measurementTrace?.phases.first(where: { $0.phase == "upload" }), fallback: result.uploadMeasurementSource) {
                metaRow("Comptage de l’envoi", Self.byteSourceLabel(source), icon: "arrow.up")
            }
            if let average = result.pingMs {
                metaRow("Latence moyenne", "\(Self.msText(average)) ms", icon: "timer")
            }
            if result.methodologyVersion == nil {
                metaRow("Latence", String(localized: "Valeur historique"), icon: "clock")
            }
            if let proto = result.pingProtocol?.trimmedNonEmptyDetail {
                Divider().overlay(SQColor.separator)
                metaRow("Latence", String(localized: "mesurée en \(proto)"), icon: "timer")
            }
        }
        .sqCardBackground(cornerRadius: SQRadius.lg, elevation: .rest)
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

    private func metaRow(_ label: String, _ value: String, icon: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    metaLabel(label, icon: icon)
                    metaValue(value, alignment: .leading)
                }
            } else {
                HStack(spacing: SQSpace.md) {
                    metaLabel(label, icon: icon)
                    Spacer(minLength: SQSpace.sm)
                    metaValue(value, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.md - 2)
    }

    private func metaLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(width: 20)
            Text(LocalizedStringKey(label))
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func metaValue(_ value: String, alignment: TextAlignment) -> some View {
        Text(value)
            .font(SQFont.body(14, .semibold))
            .foregroundStyle(SQColor.label)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(alignment)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            if let onShowOnMap, let coordinate = result.coordinate {
                GradientButton("Voir ce lieu sur la carte", systemImage: "map.fill", style: .secondary) {
                    onShowOnMap(coordinate)
                    onDismiss?()
                }
            }

        }
    }

    // MARK: Formats

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter
    }()

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


/// État serveur et actions de cette fiche ; aucun optimisme sur la visibilité.
private struct SpeedtestVisibilityControls: View {
    @ObservedObject var model: SpeedtestVisibilityViewModel
    @State private var publicationConfirmation: SpeedtestVisibilityViewModel.PublicationConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label("Carte publique", systemImage: "map")
                .font(SQType.subhead)
            Text(statusText)
                .font(SQFont.body(17, .semibold))
                .accessibilityIdentifier("speedtest.visibility.status")
            if model.isLoading || model.isSaving {
                ProgressView(model.isSaving
                             ? String(localized: "Enregistrement et vérification…")
                             : String(localized: "Vérification de la visibilité…"))
                    .font(SQType.caption)
                    .accessibilityIdentifier("speedtest.visibility.progress")
            }
            if let explanation {
                Text(explanation)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
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
            if model.canHide {
                GradientButton("Masquer de la carte", systemImage: "eye.slash", style: .secondary) {
                    Task { await model.hide() }
                }
                .accessibilityIdentifier("speedtest.visibility.hide")
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
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
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

    private var statusText: String {
        switch model.availability {
        case .guest: return String(localized: "Test invité")
        case .noServerReference: return String(localized: "Référence serveur indisponible")
        case .sessionChanged: return String(localized: "Session modifiée")
        case .unknown, .loaded: break
        }
        guard model.isStateCurrent, let state = model.state else {
            return String(localized: "Visibilité à vérifier")
        }
        if !state.isVisibleOnMap { return String(localized: "Masqué de la carte") }
        if !state.isPublic { return String(localized: "Non éligible à la carte") }
        if !state.hasMapPosition { return String(localized: "Position indisponible") }
        return String(localized: "Visible sur la carte")
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
        return String(localized: "Masquer un test le conserve dans ton historique. Sa publication reste soumise aux critères de la carte et à tes zones privées.")
    }
}
