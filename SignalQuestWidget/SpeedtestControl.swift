import AppIntents
import SwiftUI
import WidgetKit

/// F3 — Contrôle Centre de contrôle / écran verrouillé (iOS 18+) : lance un
/// speedtest en 1 tap. Ouvre l'app sur l'onglet Speed via le deep link
/// `signalquest://speedtest` (déjà géré par `handleDeepLink`). La cible widget
/// est isolée : aucune dépendance aux composants/couleurs de l'app.
@available(iOS 18.0, *)
struct SpeedtestControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "fr.signalquest.ios.control.speedtest") {
            ControlWidgetButton(action: LaunchSpeedtestControlIntent()) {
                Label("Speedtest", systemImage: "speedometer")
            }
        }
        .displayName("Speedtest SignalQuest")
        .description("Ouvre SignalQuest pour lancer un test de débit.")
    }
}

/// Ouvre l'app sur l'écran Speedtest (deep link consommé par l'app).
@available(iOS 18.0, *)
struct LaunchSpeedtestControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un Speedtest SignalQuest"

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "signalquest://speedtest")!))
    }
}
