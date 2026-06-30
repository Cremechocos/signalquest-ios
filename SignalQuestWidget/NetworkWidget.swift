import WidgetKit
import SwiftUI

/// F8 — Widget d'accueil « réseau autour de moi » : opérateur résolu, génération,
/// antenne la plus proche connue et dernier débit. Alimenté par l'app via l'App
/// Group (`WidgetSharedStore.networkGlance`), écrit pendant le Drive Test. Cible
/// widget isolée : couleurs codées en dur (pas d'accès au design system de l'app).
struct NetworkGlanceEntry: TimelineEntry {
    let date: Date
    let glance: NetworkGlanceSnapshot?
}

struct NetworkGlanceProvider: TimelineProvider {
    private var sample: NetworkGlanceSnapshot {
        NetworkGlanceSnapshot(operatorLabel: "Orange", generation: "5G", nearestDistanceMeters: 180, nearestOperator: "ORANGE", lastDownloadMbps: 312, date: Date())
    }

    func placeholder(in context: Context) -> NetworkGlanceEntry {
        NetworkGlanceEntry(date: Date(), glance: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NetworkGlanceEntry) -> Void) {
        completion(NetworkGlanceEntry(date: Date(), glance: WidgetSharedStore.networkGlance() ?? sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetworkGlanceEntry>) -> Void) {
        let entry = NetworkGlanceEntry(date: Date(), glance: WidgetSharedStore.networkGlance())
        // Données mises à jour quand l'utilisateur ouvre l'app : rafraîchir dans ~30 min.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct NetworkWidgetEntryView: View {
    var entry: NetworkGlanceEntry
    private let brandRed = Color(red: 0.89, green: 0.0, blue: 0.10)

    private var distanceText: String? {
        guard let d = entry.glance?.nearestDistanceMeters else { return nil }
        return d >= 1000 ? String(format: "%.1f km", d / 1000) : "\(Int(d)) m"
    }

    var body: some View {
        let g = entry.glance
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(brandRed)
                Text(g?.operatorLabel ?? "Réseau")
                    .font(.headline)
                    .lineLimit(1)
                if let gen = g?.generation, !gen.isEmpty {
                    Text(gen)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(brandRed.opacity(0.15), in: Capsule())
                        .foregroundStyle(brandRed)
                }
            }
            Spacer(minLength: 0)
            if let d = g?.lastDownloadMbps {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(d.rounded()))")
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                    Text("Mbps").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Lance un Drive Test").font(.caption2).foregroundStyle(.secondary)
            }
            if let distanceText {
                Label("Antenne à \(distanceText)", systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .networkWidgetBackground()
    }
}

private extension View {
    @ViewBuilder
    func networkWidgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { Color(.systemBackground) }
        } else {
            self.background(Color(.systemBackground))
        }
    }
}

struct NetworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.signalquest.ios.widget.network", provider: NetworkGlanceProvider()) { entry in
            NetworkWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Réseau autour de moi")
        .description("Ton opérateur, l'antenne la plus proche et ton dernier débit.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
