import AppIntents
import Foundation

/// Raccourci Siri / Spotlight / Action « Lancer un Speedtest ». Ouvre l'app sur
/// l'onglet Tester, qui propose aussitôt le test avec confirmation (MES-34).
struct RunSpeedtestIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un Speedtest"
    static let description = IntentDescription("Ouvre SignalQuest et propose de lancer un test de débit.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Directement sur le routeur : le drapeau lu au passage au premier plan
        // ne partait pas quand l'app était déjà ouverte (MES-34).
        AppServicesHolder.services.router.requestSpeedtestStart()
        return .result()
    }
}

/// Raccourci « Ouvrir la carte ».
struct OpenMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir la carte SignalQuest"
    static let description = IntentDescription("Ouvre la carte des antennes et mesures.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SQIntentRoute.requestMap()
        return .result()
    }
}

/// Raccourci « Ouvrir la messagerie ».
struct OpenMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir la messagerie SignalQuest"
    static let description = IntentDescription("Ouvre la messagerie chiffrée SignalQuest.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SQIntentRoute.requestMessages()
        return .result()
    }
}

/// Raccourci « Lancer un Drive Test » (F4). Ouvre l'app sur l'onglet Speed et
/// présente le mode Drive Test (speedtests successifs le long du trajet).
struct RunDriveTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un Drive Test"
    static let description = IntentDescription("Ouvre SignalQuest et démarre le mode Drive Test (mesure en continu).")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SQIntentRoute.requestDriveTest()
        return .result()
    }
}

/// « Dernier résultat » (plan 3, vague 1) : Siri ou un raccourci donnent le
/// débit du dernier test sans ouvrir l'app. Lu dans l'instantané des widgets,
/// effacé à la déconnexion avec eux (MES-13).
struct LastSpeedtestResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Dernier résultat SignalQuest"
    static let description = IntentDescription("Donne le débit de ton dernier speedtest.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = WidgetSharedStore.lastSpeedtest().map { Self.summary(of: $0, now: Date()) }
            ?? String(localized: "Aucun test pour l’instant. Lance un speedtest dans SignalQuest.")
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }

    static func summary(of snapshot: SpeedtestWidgetSnapshot, now: Date) -> String {
        var measures = [String(localized: "\(Int(snapshot.downloadMbps.rounded())) Mbps en réception")]
        if let upload = snapshot.uploadMbps {
            measures.append(String(localized: "\(Int(upload.rounded())) Mbps en envoi"))
        }
        if let ping = snapshot.pingMs {
            measures.append(String(localized: "latence \(Int(ping.rounded())) ms"))
        }
        let when = RelativeDateTimeFormatter().localizedString(for: snapshot.date, relativeTo: now)
        return String(localized: "Dernier test \(when) sur \(snapshot.network) : \(measures.joined(separator: ", ")).")
    }
}

struct SignalQuestShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSpeedtestIntent(),
            phrases: [
                "Lance un speedtest avec \(.applicationName)",
                "Teste mon débit avec \(.applicationName)"
            ],
            shortTitle: "Speedtest",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: OpenMapIntent(),
            phrases: [
                "Ouvre la carte \(.applicationName)",
                "Montre les antennes avec \(.applicationName)"
            ],
            shortTitle: "Carte",
            systemImageName: "map"
        )
        AppShortcut(
            intent: OpenMessagesIntent(),
            phrases: [
                "Ouvre la messagerie \(.applicationName)",
                "Ouvre mes messages \(.applicationName)"
            ],
            shortTitle: "Messagerie",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: RunDriveTestIntent(),
            phrases: [
                "Lance un drive test avec \(.applicationName)",
                "Démarre un drive test \(.applicationName)"
            ],
            shortTitle: "Drive Test",
            systemImageName: "location.north.line.fill"
        )
        AppShortcut(
            intent: LastSpeedtestResultIntent(),
            phrases: [
                "Quel est mon dernier débit \(.applicationName)",
                "Mon dernier speedtest \(.applicationName)"
            ],
            shortTitle: "Dernier résultat",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
    }
}

/// Route en attente posée par un App Intent / Spotlight, consommée par l'app au
/// premier passage au premier plan (même process : `UserDefaults.standard`).
enum SQIntentRoute {
    private static let speedtestKey = "sq.intent.route.speedtest"
    private static let mapKey = "sq.intent.route.map"
    private static let messagesKey = "sq.intent.route.messages"
    private static let driveTestKey = "sq.intent.route.drivetest"

    static func requestSpeedtest() { UserDefaults.standard.set(true, forKey: speedtestKey) }
    static func requestMap() { UserDefaults.standard.set(true, forKey: mapKey) }
    static func requestMessages() { UserDefaults.standard.set(true, forKey: messagesKey) }
    static func requestDriveTest() { UserDefaults.standard.set(true, forKey: driveTestKey) }

    static func consumeSpeedtest() -> Bool { consume(speedtestKey) }
    static func consumeMap() -> Bool { consume(mapKey) }
    static func consumeMessages() -> Bool { consume(messagesKey) }
    static func consumeDriveTest() -> Bool { consume(driveTestKey) }

    private static func consume(_ key: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
