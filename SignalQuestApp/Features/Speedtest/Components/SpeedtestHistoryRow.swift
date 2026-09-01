import SwiftUI

struct SpeedtestHistoryRow: View {
    let result: SpeedtestRunResult

    var body: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(SQColor.successSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.success)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleLine)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitleLine)
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.lg + 2)
        .padding(.vertical, SQSpace.md + 3)
        .accessibilityElement(children: .combine)
    }

    /// « 10 juil. · 388 Mbps · 21 ms »
    var titleLine: String {
        var parts = [result.createdAt.formatted(.dateTime.day().month(.abbreviated))]
        parts.append("\(shortSpeed(result.downloadAverageMbps)) Mbps")
        if let ping = result.pingMinMs ?? result.pingMs, ping.isFinite, ping >= 0 {
            parts.append("\(Int(ping.rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }

    /// Sous-titre réseau : « 5G NSA · Orange », « WiFi · Freebox »… Repli sur
    /// l'adresse ou la commune quand elles sont connues (contexte de la mesure).
    var subtitleLine: String {
        var parts = [result.networkDisplayName]
        if let op = result.networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !op.isEmpty {
            parts.append(op)
        }
        if let city = result.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            parts.append(city)
        }
        return parts.joined(separator: " · ")
    }

    func shortSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }
}
