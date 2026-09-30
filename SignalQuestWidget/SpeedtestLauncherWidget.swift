import SwiftUI
import WidgetKit

/// Bouton « Lancer un test » sur l'écran d'accueil et l'écran verrouillé (plan
/// 3, vague 1) : un toucher ouvre SignalQuest, qui propose aussitôt le test
/// avec confirmation. Même lien que le widget de débit et le contrôle iOS 18.
struct SpeedtestLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.signalquest.ios.widget.launcher", provider: SpeedtestLauncherProvider()) { _ in
            SpeedtestLauncherView()
        }
        .configurationDisplayName("Lancer un test")
        .description("Un toucher pour lancer un speedtest.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct SpeedtestLauncherEntry: TimelineEntry {
    let date: Date
}

/// Rien à afficher qui change : une seule entrée, jamais rafraîchie.
struct SpeedtestLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedtestLauncherEntry {
        SpeedtestLauncherEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedtestLauncherEntry) -> Void) {
        completion(SpeedtestLauncherEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedtestLauncherEntry>) -> Void) {
        completion(Timeline(entries: [SpeedtestLauncherEntry(date: Date())], policy: .never))
    }
}

struct SpeedtestLauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "speedometer")
                    .font(.system(size: 22, weight: .semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Lancer un test"))
            .sqAccessoryBackground()
            .widgetURL(speedtestWidgetURL)
        default:
            VStack(alignment: .leading, spacing: 0) {
                BrandMark()
                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(WidgetPalette.brand)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Text("Lancer un test")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WidgetPalette.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .sqWidgetBackground(tint: WidgetPalette.brand)
            .widgetURL(speedtestWidgetURL)
        }
    }
}
