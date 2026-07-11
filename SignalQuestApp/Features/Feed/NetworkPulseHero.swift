import SwiftUI

/// Héro « Pouls réseau » en tête du feed : agrégat réseau autour de la position
/// (RSRP moyen, débit descendant médian, meilleur opérateur de la zone). Parité
/// avec le `NetworkPulseHero` Android. Alimenté par `GET /api/social/network-pulse`.
struct NetworkPulseHero: View {
    let pulse: NetworkPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.xs + 2) {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulsing ? 1.35 : 0.85)
                    .opacity(pulsing ? 0.5 : 1)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                Text("Pouls réseau · autour de vous")
                    .font(SQFont.archivo(12, .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.white)
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
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQGradient.signal, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .onAppear { pulsing = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func stat(value: String, label: String, compact: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(SQFont.archivo(compact ? 17 : 22, .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(SQType.micro)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.28))
            .frame(width: 0.5, height: 30)
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
