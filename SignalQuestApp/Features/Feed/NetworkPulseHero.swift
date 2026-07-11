import SwiftUI

/// Héro « Pouls réseau » en tête du feed : agrégat réseau autour de la position
/// (RSRP moyen, débit descendant médian, meilleur opérateur de la zone). Parité
/// avec le `NetworkPulseHero` Android. Alimenté par `GET /api/social/network-pulse`.
///
/// DA « Crème & Terre cuite » : c'est LA surface accent de l'écran Communauté —
/// carte pleine brique, rayon 22, ombre accent, textes en `onAccent`.
struct NetworkPulseHero: View {
    let pulse: NetworkPulse
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.xs + 3) {
                // Pastille « live » : pulsation opacity 1 → 0.35, cycle 1,4 s
                // (désactivée sous Reduce Motion via sqAnimation).
                Circle()
                    .fill(SQColor.onAccent)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.35 : 1)
                    .sqAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                Text("Pouls réseau · autour de vous")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.onAccent)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                stat(value: rsrpText, label: "dBm moyen")
                divider
                stat(value: mbpsText, label: "Mb/s médian")
                divider
                stat(value: operatorText, label: operatorLabel, compact: hasOperator)
            }
        }
        .padding(.horizontal, SQSpace.lg + 2)
        .padding(.vertical, SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowAccent()
        .onAppear { pulsing = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func stat(value: String, label: String, compact: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(SQFont.display(compact ? 18 : 22, .bold))
                .monospacedDigit()
                .foregroundStyle(SQColor.onAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(SQFont.body(11, .medium))
                .foregroundStyle(SQColor.onAccent.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(SQColor.onAccent.opacity(0.3))
            .frame(width: 1, height: 30)
    }

    private var rsrpText: String { pulse.avgRsrpDbm.map { "\($0)" } ?? "—" }
    private var mbpsText: String { pulse.medianDownloadMbps.map { "\($0)" } ?? "—" }
    private var hasOperator: Bool { pulse.bestOperator?.isEmpty == false }

    /// Meilleur opérateur si disponible, sinon repli sur le nombre de mesures.
    private var operatorText: String {
        if let op = pulse.bestOperator, !op.isEmpty { return op }
        return "\(pulse.measurementsCount)"
    }
    private var operatorLabel: String { hasOperator ? "meilleur op." : "mesures" }

    private var accessibilitySummary: String {
        var parts: [String] = ["Pouls réseau autour de vous"]
        if let rsrp = pulse.avgRsrpDbm { parts.append("RSRP moyen \(rsrp) dBm") }
        if let mbps = pulse.medianDownloadMbps { parts.append("débit médian \(mbps) mégabits par seconde") }
        if hasOperator, let op = pulse.bestOperator { parts.append("meilleur opérateur \(op)") }
        else { parts.append("\(pulse.measurementsCount) mesures") }
        return parts.joined(separator: ", ")
    }
}
