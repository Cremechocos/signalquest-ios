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
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis").font(.title2)
                    Text("Aucun test").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                content
            }
        }
        .sqHomeWidgetBackground()
        .widgetURL(speedtestWidgetURL)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chart.bar.xaxis").font(.caption2.weight(.bold)).foregroundStyle(speedColor(best))
                Text("TENDANCE DÉBIT").font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.recent.count) tests").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let maxVal = max(best, 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(series) { snap in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(speedColor(snap.downloadMbps))
                            .frame(height: max(3, proxy.size.height * CGFloat(snap.downloadMbps / maxVal)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 14) {
                stat("Moy.", avg)
                stat("Record", best)
                Spacer()
                if let last = entry.recent.first {
                    Text(last.date, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(speedColor(value))
            Text("Mbps").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        }
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
