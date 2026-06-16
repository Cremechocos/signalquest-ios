import WidgetKit
import SwiftUI

struct SpeedtestEntry: TimelineEntry {
    let date: Date
    let snapshot: SpeedtestWidgetSnapshot?
}

struct SpeedtestProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedtestEntry {
        SpeedtestEntry(date: Date(), snapshot: SpeedtestWidgetSnapshot(
            downloadMbps: 412, uploadMbps: 64, pingMs: 18, network: "5G", label: "Dernier test", date: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedtestEntry) -> Void) {
        completion(SpeedtestEntry(date: Date(), snapshot: WidgetSharedStore.lastSpeedtest() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedtestEntry>) -> Void) {
        let entry = SpeedtestEntry(date: Date(), snapshot: WidgetSharedStore.lastSpeedtest())
        // L'app rafraîchit explicitement via WidgetCenter après chaque test.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

/// Couleur par débit descendant (échelle web/Android : rouge → bleu).
func speedColor(_ mbps: Double) -> Color {
    switch mbps {
    case 1000...: return Color(red: 0.231, green: 0.510, blue: 0.965)
    case 600..<1000: return Color(red: 0.024, green: 0.714, blue: 0.831)
    case 300..<600: return Color(red: 0.133, green: 0.773, blue: 0.369)
    case 100..<300: return Color(red: 0.518, green: 0.800, blue: 0.086)
    case 30..<100: return Color(red: 0.918, green: 0.702, blue: 0.031)
    case 10..<30: return Color(red: 0.976, green: 0.451, blue: 0.086)
    default: return Color(red: 0.937, green: 0.267, blue: 0.267)
    }
}

/// Deep-link ouvrant l'app sur l'onglet Speedtest (géré par `onOpenURL`).
let speedtestWidgetURL = URL(string: "signalquest://speedtest")!

/// Normalise un débit (Mbps) en 0…1 sur une échelle log (1→1000 Mbps).
func speedNormalized(_ mbps: Double) -> Double {
    guard mbps > 0 else { return 0 }
    return max(0.02, min(1, log10(mbps) / 3))
}

struct SpeedtestWidgetEntryView: View {
    var entry: SpeedtestEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: accessoryCircular
        case .accessoryRectangular: accessoryRectangular
        case .accessoryInline: accessoryInline
        default: homeContent
        }
    }

    // MARK: Home (small / medium)

    @ViewBuilder
    private var homeContent: some View {
        if let s = entry.snapshot {
            home(s).sqHomeWidgetBackground().widgetURL(speedtestWidgetURL)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "speedometer").font(.title2)
                Text("Aucun test").font(.caption).foregroundStyle(.secondary)
            }
            .sqHomeWidgetBackground()
            .widgetURL(speedtestWidgetURL)
        }
    }

    private func home(_ s: SpeedtestWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 2 : 6) {
            HStack(spacing: 4) {
                Image(systemName: "speedometer").font(.caption2.weight(.bold)).foregroundStyle(speedColor(s.downloadMbps))
                Text("SIGNALQUEST").font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(s.downloadMbps.rounded()))")
                    .font(.system(size: family == .systemSmall ? 34 : 44, weight: .black, design: .rounded))
                    .foregroundStyle(speedColor(s.downloadMbps))
                Text("Mbps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                metric("UL", s.uploadMbps.map { "\(Int($0.rounded())) Mbps" } ?? "—", "arrow.up")
                metric("Ping", s.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—", "bolt.fill")
            }
            Spacer(minLength: 0)
            Text(s.date, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold))
        }
    }

    // MARK: Accessory (lock screen)

    private var accessoryCircular: some View {
        let dl = entry.snapshot?.downloadMbps ?? 0
        return ZStack {
            AccessoryWidgetBackground()
            Gauge(value: speedNormalized(dl)) {
                Image(systemName: "speedometer")
            } currentValueLabel: {
                Text("\(Int(dl.rounded()))")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
        }
        .widgetURL(speedtestWidgetURL)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let s = entry.snapshot {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text("\(Int(s.downloadMbps.rounded())) Mbps").font(.headline)
                }
                Text("UL \(s.uploadMbps.map { "\(Int($0.rounded()))" } ?? "—") · Ping \(s.pingMs.map { "\(Int($0.rounded()))" } ?? "—") ms")
                    .font(.caption2)
                Text(s.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("Aucun test", systemImage: "speedometer").font(.headline)
            }
        }
        .widgetURL(speedtestWidgetURL)
    }

    private var accessoryInline: some View {
        Label(
            entry.snapshot.map { "\(Int($0.downloadMbps.rounded())) Mbps ↓" } ?? "Speedtest",
            systemImage: "speedometer"
        )
        .widgetURL(speedtestWidgetURL)
    }
}

struct SpeedtestWidget: Widget {
    let kind = "SignalQuestSpeedtestWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedtestProvider()) { entry in
            SpeedtestWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Dernier Speedtest")
        .description("Affiche ton dernier test de débit SignalQuest.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Widget background helper (iOS 17 containerBackground, repli < 17)

extension View {
    @ViewBuilder
    func sqHomeWidgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}
