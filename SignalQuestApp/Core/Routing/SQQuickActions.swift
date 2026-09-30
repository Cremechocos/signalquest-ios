import UIKit

/// Actions rapides de l'icône (appui long sur SignalQuest dans l'écran
/// d'accueil). Déclarées depuis le code plutôt que dans l'Info.plist : iOS les
/// affiche dès le premier lancement. Elles passent par les mêmes routes que
/// Siri et Spotlight (`SQIntentRoute`), consommées par `MainTabView` au
/// passage au premier plan.
enum SQQuickActions {
    enum Kind: String, CaseIterable {
        case speedtest = "fr.signalquest.ios.quick.speedtest"
        case driveTest = "fr.signalquest.ios.quick.drivetest"
        case map = "fr.signalquest.ios.quick.map"
        case messages = "fr.signalquest.ios.quick.messages"
    }

    /// Messages suppose un compte : l'action n'est proposée qu'une fois connecté.
    static func items(signedIn: Bool) -> [UIApplicationShortcutItem] {
        var kinds: [Kind] = [.speedtest, .driveTest, .map]
        if signedIn { kinds.append(.messages) }
        return kinds.map { kind in
            UIApplicationShortcutItem(
                type: kind.rawValue,
                localizedTitle: title(kind),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: symbol(kind)),
                userInfo: nil
            )
        }
    }

    @MainActor
    static func install(signedIn: Bool) {
        UIApplication.shared.shortcutItems = items(signedIn: signedIn)
    }

    /// Pose la route correspondante ; l'app la consomme en passant au premier plan.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch Kind(rawValue: item.type) {
        case .speedtest: SQIntentRoute.requestSpeedtest()
        case .driveTest: SQIntentRoute.requestDriveTest()
        case .map: SQIntentRoute.requestMap()
        case .messages: SQIntentRoute.requestMessages()
        case nil: return false
        }
        return true
    }

    private static func title(_ kind: Kind) -> String {
        switch kind {
        case .speedtest: return String(localized: "Lancer un test")
        case .driveTest: return String(localized: "Drive Test")
        case .map: return String(localized: "Carte")
        case .messages: return String(localized: "Messages")
        }
    }

    private static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .speedtest: return "speedometer"
        case .driveTest: return "location.north.line.fill"
        case .map: return "map"
        case .messages: return "bubble.left.and.bubble.right"
        }
    }
}

/// Délégué des fenêtres de l'app : reçoit l'action rapide choisie quand
/// l'app tourne déjà. Au démarrage à froid, elle arrive dans
/// `AppDelegate.application(_:configurationForConnecting:options:)`.
@MainActor
final class SQWindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(SQQuickActions.handle(shortcutItem))
    }
}
