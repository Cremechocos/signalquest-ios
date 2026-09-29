import SwiftUI

/// Un test du compte absent de ce téléphone (UI-12) : date, réception, latence,
/// réseau. Sans fiche détaillée : le serveur n'en renvoie ici qu'un résumé.
struct AccountSpeedtestRow: View {
    let test: SocialShareableSpeedtest

    var body: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(SQColor.surfaceMuted)
                    .frame(width: 40, height: 40)
                Image(systemName: "icloud")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: titleLine)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speedtest.account.title")
                if !subtitleLine.isEmpty {
                    Text(verbatim: subtitleLine)
                        .font(SQFont.body(12.5))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("speedtest.account.subtitle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SQSpace.lg + 2)
        .padding(.vertical, SQSpace.md + 3)
        .accessibilityElement(children: .combine)
    }

    /// « 10 juil. · 388 Mbit/s · 21 ms »
    var titleLine: String {
        var parts: [String] = []
        if let date = test.timestamp {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated)))
        }
        if let download = test.downloadAverageMbps, download.isFinite, download > 0 {
            parts.append(SQUnits.throughput(mbps: download))
        } else {
            parts.append("—")
        }
        if let ping = test.ping, ping.isFinite, ping >= 0 {
            parts.append(SQUnits.milliseconds(ping))
        }
        return parts.joined(separator: " · ")
    }

    /// « 5G · Orange »
    var subtitleLine: String {
        let operatorName = test.mobileOperator?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [TechAccent.shortLabel(for: test.networkType), operatorName]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}
