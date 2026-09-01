import SwiftUI
import Foundation

/// Héro « Pouls réseau » en tête du feed : agrégat réseau autour de la position
/// (RSRP moyen, débit descendant médian, meilleur opérateur de la zone). Parité
/// avec le `NetworkPulseHero` Android. Alimenté par `GET /api/social/network-pulse`.
///
/// DA « Crème & Terre cuite » : c'est LA surface accent de l'écran Communauté —
/// carte pleine brique, rayon 22, ombre accent, textes en `onAccent`.
struct NetworkPulseHero: View {
    let pulse: NetworkPulse
    @State private var pulsing = false
    @State private var freshnessClock = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.xs + 3) {
                // Pastille « live » : pulsation opacity 1 → 0.35, cycle 1,4 s
                // (désactivée sous Reduce Motion via sqAnimation).
                //
                // ⚠️ Elle ne s'anime QUE si le pouls décrit vraiment l'instant
                // présent (fenêtre courte + mesure récente). Elle clignotait
                // auparavant en toutes circonstances, y compris devant une moyenne
                // agrégée sur douze mois : une animation qui affirmait « direct »
                // sans que rien ne le soit.
                Circle()
                    .fill(SQColor.onAccent)
                    .frame(width: 7, height: 7)
                    .opacity(pulseIsLive ? (pulsing ? 0.35 : 1) : 0.45)
                    .sqAnimation(
                        SQMotion.repeating(
                            .easeInOut(duration: 0.7),
                            active: pulseIsLive && pulsing,
                            reduceMotion: reduceMotion
                        ),
                        value: pulsing
                    )
                Text("Pouls réseau · autour de vous")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.onAccent)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Ce que le chiffre représente, et de quand il date.
            Text(contextLine)
                .font(.caption)
                .foregroundStyle(SQColor.onAccent)
                .fixedSize(horizontal: false, vertical: true)
            stats

            if hasDetails {
                Divider()
                    .overlay(SQColor.onAccent.opacity(0.72))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    if let trendText {
                        Text(trendText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SQColor.onAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(pulse.operators.prefix(3).enumerated()), id: \.element.operatorKey) { index, op in
                        operatorRow(index: index, entry: op)
                    }
                    if let technologyLine {
                        Text(technologyLine)
                            .font(.caption)
                            .foregroundStyle(SQColor.onAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let referenceLine {
                        Text(referenceLine)
                            .font(.caption)
                            .foregroundStyle(SQColor.onAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, SQSpace.lg + 2)
        .padding(.vertical, SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.accentTextSurface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .accessibilityIdentifier("community.networkPulse")
        .sqShadowAccent()
        .onAppear { pulsing = true }
        .task(id: pulse.lastMeasuredAt) {
            freshnessClock = Date()
            guard pulse.lastMeasuredAt != nil else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                freshnessClock = Date()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// « 7 derniers jours · 214 mesures · il y a 12 min » — la ligne qui donne son
    /// sens aux trois nombres du dessous.
    private var contextLine: String {
        var parts: [String] = [windowLabel, "\(pulse.measurementsCount) mesures"]
        if let radius = pulse.radiusMeters { parts.append("rayon \(formatRadius(radius))") }
        if let freshness = freshnessLabel { parts.append(freshness) }
        return parts.joined(separator: " · ")
    }

    private var windowLabel: String {
        switch pulse.windowDays {
        case ...7: return "7 derniers jours"
        case ...30: return "30 derniers jours"
        case ...90: return "3 derniers mois"
        default: return "12 derniers mois"
        }
    }

    private var trendText: String? {
        guard let trend = pulse.trend else { return nil }
        if trend.deltaPercent > 2 { return "+\(trend.deltaPercent) % vs 30 jours précédents" }
        if trend.deltaPercent < -2 { return "\(trend.deltaPercent) % vs 30 jours précédents" }
        return "Stable vs 30 jours précédents"
    }

    private var technologyLine: String? {
        let values = pulse.technologies
            .filter { $0.share >= 0.05 }
            .prefix(4)
            .map { "\($0.technology) \(Int(($0.share * 100).rounded())) %" }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var referenceLine: String? {
        guard let reference = pulse.reference else { return nil }
        return "Référence \(reference.label) : \(reference.medianDownloadMbps) Mbps (\(reference.sampleCount) tests)"
    }

    private var hasDetails: Bool {
        trendText != nil || pulse.operators.count > 1 || technologyLine != nil || referenceLine != nil
    }

    private func operatorMetrics(_ op: NetworkPulseOperator) -> String {
        var values: [String] = []
        if let speed = op.medianDownloadMbps { values.append("\(speed) Mbps") }
        if let rsrp = op.avgRsrpDbm { values.append("\(rsrp) dBm") }
        values.append("n=\(op.sampleCount)")
        return values.joined(separator: " · ")
    }

    private func formatRadius(_ meters: Int) -> String {
        if meters < 1_000 { return "\(meters) m" }
        if meters % 1_000 == 0 { return "\(meters / 1_000) km" }
        return String(format: "%.1f km", Double(meters) / 1_000)
    }

    /// `nil` si le serveur n'a pas renvoyé la date : on n'affiche alors rien plutôt
    /// qu'une fraîcheur inventée.
    private var freshnessLabel: String? {
        guard let last = pulse.lastMeasuredAt else { return nil }
        let minutes = Int(freshnessClock.timeIntervalSince(last) / 60)
        guard minutes >= 0 else { return nil }
        switch minutes {
        case ..<2: return "à l'instant"
        case ..<60: return "il y a \(minutes) min"
        case ..<(60 * 24): return "il y a \(minutes / 60) h"
        default: return "il y a \(minutes / (60 * 24)) j"
        }
    }

    private var pulseIsLive: Bool { pulse.isLive(at: freshnessClock) }

    private func stat(value: String, label: String, compact: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(compact ? .headline.weight(.bold) : .title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(SQColor.onAccent)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(label))
                .font(.caption.weight(.medium))
                .foregroundStyle(SQColor.onAccent)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stats: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: SQSpace.sm) {
                stat(value: rsrpText, label: "dBm moyen")
                horizontalDivider
                stat(value: mbpsText, label: "Mbps médian")
                horizontalDivider
                stat(value: operatorText, label: operatorLabel, compact: hasOperator)
            }
        } else {
            HStack(spacing: 0) {
                stat(value: rsrpText, label: "dBm moyen")
                divider
                stat(value: mbpsText, label: "Mbps médian")
                divider
                stat(value: operatorText, label: operatorLabel, compact: hasOperator)
            }
        }
    }

    @ViewBuilder
    private func operatorRow(index: Int, entry op: NetworkPulseOperator) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(op.label)")
                Text(operatorMetrics(op))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption.weight(.medium))
            .foregroundStyle(SQColor.onAccent)
        } else {
            HStack(spacing: SQSpace.xs) {
                Text("\(index + 1). \(op.label)")
                Spacer(minLength: SQSpace.xs)
                Text(operatorMetrics(op))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(SQColor.onAccent)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SQColor.onAccent.opacity(0.72))
            .frame(width: 1, height: 30)
            .accessibilityHidden(true)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(SQColor.onAccent.opacity(0.72))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var rsrpText: String { pulse.avgRsrpDbm.map { "\($0)" } ?? "—" }
    private var mbpsText: String { pulse.medianDownloadMbps.map { "\($0)" } ?? "—" }
    private var hasOperator: Bool { pulse.bestOperator?.isEmpty == false }

    /// Meilleur opérateur si disponible, sinon repli sur le nombre de mesures.
    private var operatorText: String {
        if let op = pulse.bestOperator, !op.isEmpty { return op }
        return "\(pulse.measurementsCount)"
    }
    private var operatorLabel: String {
        hasOperator ? String(localized: "meilleur op.") : String(localized: "mesures")
    }

    private var accessibilitySummary: String {
        // TOUS les morceaux passent par le catalogue. Deux d'entre eux ne le
        // faisaient pas, et VoiceOver énonçait un libellé mi-français
        // mi-anglais — le genre de défaut qu'aucune relecture de code ne
        // rattrape, seulement l'écoute ou un relevé des textes rendus.
        var parts: [String] = [String(localized: "Pouls réseau autour de vous")]
        if let rsrp = pulse.avgRsrpDbm { parts.append(String(localized: "RSRP moyen \(rsrp) dBm")) }
        if let mbps = pulse.medianDownloadMbps { parts.append(String(localized: "débit médian \(mbps) mégabits par seconde")) }
        if hasOperator, let op = pulse.bestOperator { parts.append(String(localized: "meilleur opérateur \(op)")) }
        else { parts.append(String(localized: "\(pulse.measurementsCount) mesure")) }
        parts.append(contextLine)
        if let trendText { parts.append(trendText) }
        if let referenceLine { parts.append(referenceLine) }
        return parts.joined(separator: ", ")
    }
}
