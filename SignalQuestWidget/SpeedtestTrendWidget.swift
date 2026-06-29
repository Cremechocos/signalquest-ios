import WidgetKit
import SwiftUI

struct SpeedtestTrendEntry: TimelineEntry {
    let date: Date
    let recent: [SpeedtestWidgetSnapshot]
}

struct SpeedtestTrendProvider: TimelineProvider {
    private var sample: [SpeedtestWidgetSnapshot] {
        (0..<8).map { i in
            SpeedtestWidgetSnapshot(
                downloadMbps: [120.0, 240, 310, 180, 420, 360, 510, 290][i],
                uploadMbps: 40, pingMs: 20, network: "5G", label: "test",
                date: Date().addingTimeInterval(Double(-i) * 3600)
            )
        }
    }

    func placeholder(in context: Context) -> SpeedtestTrendEntry {
        SpeedtestTrendEntry(date: Date(), recent: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedtestTrendEntry) -> Void) {
        let recent = WidgetSharedStore.recentSpeedtests()
        completion(SpeedtestTrendEntry(date: Date(), recent: recent.isEmpty ? sample : recent))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedtestTrendEntry>) -> Void) {
        completion(Timeline(entries: [SpeedtestTrendEntry(date: Date(), recent: WidgetSharedStore.recentSpeedtests())], policy: .never))
    }
}

struct SpeedtestTrendEntryView: View {
    var entry: SpeedtestTrendEntry
    @Environment(\.colorScheme) private var scheme

    private var series: [SpeedtestWidgetSnapshot] {
        // Du plus ancien au plus récent pour lire le graphique de gauche à droite.
        Array(entry.recent.prefix(10).reversed())
    }

    private var avg: Double {
        guard !entry.recent.isEmpty else { return 0 }
        return entry.recent.map(\.downloadMbps).reduce(0, +) / Double(entry.recent.count)
    }

    private var best: Double { entry.recent.map(\.downloadMbps).max() ?? 0 }

    var body: some View {
        Group {
            if series.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sqWidgetBackground(tint: speedColor(best))
        .widgetURL(speedtestWidgetURL)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(WidgetPalette.brand)
            Text("Aucun test")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetPalette.label)
                .lineLimit(1)
            Text("Pas encore de tendance")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WidgetPalette.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(speedColor(best))
                Text("TENDANCE DÉBIT")
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(WidgetPalette.labelSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(entry.recent.count) tests")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(WidgetPalette.labelSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            chart

            HStack(spacing: 10) {
                stat("Moy.", avg)
                stat("Record", best)
                Text("Mbps")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WidgetPalette.labelTertiary)
                Spacer(minLength: 4)
                if let last = entry.recent.first {
                    Text(last.date, style: .relative)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WidgetPalette.labelTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(-1)
                }
            }
            .lineLimit(1)
        }
    }

    private var chart: some View {
        GeometryReader { proxy in
            let maxVal = max(best, 1)
            let avgRatio = min(1, avg / maxVal)

            ZStack(alignment: .bottom) {
                // Ligne de moyenne (pointillés, teinte de qualité de la moyenne).
                if avg > 0 {
                    Path { path in
                        let y = proxy.size.height * (1 - CGFloat(avgRatio))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(speedColor(avg).opacity(0.55))
                }

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { idx, snap in
                        let isLast = idx == series.count - 1
                        let color = speedColor(snap.downloadMbps)
                        let h = max(4, proxy.size.height * CGFloat(min(1, snap.downloadMbps / maxVal)))

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(
                                colors: [color, color.opacity(0.32)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            .frame(height: h)
                            .opacity(isLast ? 1 : 0.62)
                            .overlay {
                                if isLast {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(color, lineWidth: 1.5)
                                        .shadow(color: color.opacity(0.6), radius: 4)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(WidgetPalette.labelSecondary)
            Text("\(Int(value.rounded()))")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(speedColor(value))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Widget « tendance » : barres des derniers débits + moyenne / record.
struct SpeedtestTrendWidget: Widget {
    let kind = "SignalQuestSpeedtestTrendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedtestTrendProvider()) { entry in
            SpeedtestTrendEntryView(entry: entry)
        }
        .configurationDisplayName("Tendance débit")
        .description("Tes derniers tests de débit en un coup d'œil.")
        .supportedFamilies([.systemMedium])
    }
}
