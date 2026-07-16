import SwiftUI

/// Fiche d'un speedtest de l'historique. Mêmes chiffres que l'image de partage
/// — y compris les vraies courbes DL/UL du moteur, montée en charge comprise.
///
/// La ligne d'historique portait un chevron sans action : l'affordance mentait.
struct SpeedtestDetailSheet: View {
    let result: SpeedtestRunResult
    /// Centre la carte sur le lieu du test. `nil` masque le bouton.
    var onShowOnMap: ((Coordinates) -> Void)?
    /// Publie le test sur la carte publique. `nil` = publication impossible
    /// (test antérieur sans id serveur, invité, ou VPN actif) → pas de bouton
    /// plutôt qu'un bouton qui échouerait.
    var onPublish: (() -> Void)?
    var isPublishing = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SpeedtestDetailContent(
                    result: result,
                    onShowOnMap: onShowOnMap,
                    onPublish: onPublish,
                    isPublishing: isPublishing,
                    onDismiss: { dismiss() }
                )
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
    var onPublish: (() -> Void)?
    var isPublishing = false
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            header
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
            HStack(spacing: SQSpace.sm) {
                if let generation {
                    Text(generation)
                        .font(SQFont.display(20, .bold))
                        .foregroundStyle(SQColor.brandRed)
                }
                Spacer(minLength: 0)
                Text(Self.dateFormatter.string(from: result.createdAt))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text(contextLine)
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generation: String? {
        switch result.connectionType {
        case .wifi: return "WiFi"
        case .cellular: return result.cellularTechnology?.displayName ?? "Cellulaire"
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
                graceCount: result.downloadGraceWindowCount
            )
            speedCard(
                title: "Envoi",
                accent: SQColor.warning,
                average: result.uploadAverageMbps,
                maxValue: result.uploadMaxMbps,
                series: result.uploadSeriesMbps,
                graceCount: result.uploadGraceWindowCount
            )
        }
    }

    private func speedCard(
        title: String,
        accent: Color,
        average: Double?,
        maxValue: Double?,
        series: [Double]?,
        graceCount: Int?
    ) -> some View {
        let parts = Self.formatSpeedParts(average)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(title)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
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
                labelColor: SQColor.labelSecondary
            )
            .frame(height: 108)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .sqShadowSoft()
    }

    // MARK: Latences — ping, jitter, et les deux pings en charge

    private var latencyGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm) {
            latencyTile("Ping", value: Self.msText(result.pingMinMs ?? result.pingMs), tint: SQColor.labelSecondary, sub: pingSub)
            latencyTile("Jitter", value: Self.decimalText(result.jitterMs), tint: SQColor.labelSecondary, sub: "au repos")
            latencyTile("Ping chargé ↓", value: Self.msText(result.pingDlMs), tint: SQColor.success, sub: gigue(result.jitterDlMs))
            latencyTile("Ping chargé ↑", value: Self.msText(result.pingUlMs), tint: SQColor.warning, sub: gigue(result.jitterUlMs))
        }
    }

    private var pingSub: String {
        guard let minMs = result.pingMinMs, let maxMs = result.pingMaxMs else { return " " }
        return "min \(Int(minMs.rounded())) · max \(Int(maxMs.rounded()))"
    }

    private func gigue(_ jitter: Double?) -> String {
        guard let jitter, jitter.isFinite else { return "gigue —" }
        return "gigue ±\(Self.decimalText(jitter))"
    }

    private func latencyTile(_ label: String, value: String, tint: Color, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(SQFont.body(11, .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
                .font(SQFont.body(11))
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Méta — serveur, appareil, protocole

    private var metaCard: some View {
        VStack(spacing: 0) {
            if let server = (result.serverName ?? result.downloadServerName)?.trimmedNonEmptyDetail {
                metaRow("Serveur", server, icon: "server.rack")
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
            if let proto = result.pingProtocol?.trimmedNonEmptyDetail {
                Divider().overlay(SQColor.separator)
                metaRow("Ping", "mesuré en \(proto)", icon: "timer")
            }
        }
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .sqShadowSoft()
    }

    private var deviceLine: String? {
        let model = result.deviceModel?.trimmedNonEmptyDetail
        let os = result.osVersion?.trimmedNonEmptyDetail
        return [model, os].compactMap { $0 }.joined(separator: " • ").trimmedNonEmptyDetail
    }

    private func metaRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(width: 20)
            Text(label)
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
            Spacer(minLength: SQSpace.sm)
            Text(value)
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.md - 2)
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
            if let onPublish {
                GradientButton(
                    "Publier sur la carte",
                    systemImage: "antenna.radiowaves.left.and.right",
                    isBusy: isPublishing,
                    style: .ghost,
                    action: onPublish
                )
                Text("Ta mesure rejoindra la carte publique, à l'endroit du test.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Formats

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter
    }()

    private static let frFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// « 487 Mbps », « 45,3 Mbps », « 1,42 Gbps » — mêmes règles que le partage.
    static func formatSpeedParts(_ mbps: Double?) -> (value: String, unit: String) {
        guard let mbps, mbps.isFinite, mbps > 0 else { return ("—", "Mbps") }
        if mbps >= 1_000 { return (decimal(mbps / 1_000, digits: 2), "Gbps") }
        if mbps >= 100 { return (decimal(mbps, digits: 0), "Mbps") }
        return (decimal(mbps, digits: 1), "Mbps")
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
