import AppIntents
import Foundation

/// Raccourci Siri / Spotlight / Action « Lancer un Speedtest ». Ouvre l'app sur
/// l'onglet Speed (un test de débit nécessite le runtime de mesure de l'app).
struct RunSpeedtestIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un Speedtest"
    static let description = IntentDescription("Ouvre SignalQuest sur l'onglet Speed pour lancer un test de débit.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SQIntentRoute.requestSpeedtest()
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
/// présente le mode Drive Test (mesure continue + couverture le long du trajet).
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
