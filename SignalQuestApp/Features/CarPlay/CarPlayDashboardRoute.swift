import Foundation

/// Relais entre la scène Dashboard et la scène CarPlay principale.
///
/// Les deux scènes sont indépendantes et peuvent être connectées séparément :
/// presser un raccourci du Dashboard alors que la scène principale n'est pas
/// encore installée doit malgré tout amener au bon écran. On dépose donc
/// l'intention ici, et la scène principale la consomme dès qu'elle est prête.
///
/// Même motif que `SQIntentRoute` pour les App Intents, à une différence près :
/// l'intention vit en mémoire et non dans `UserDefaults`. Elle n'a de sens que
/// pour la session en cours — retrouver au prochain démarrage un raccourci
/// pressé la veille n'aurait aucun intérêt.
@MainActor
enum CarPlayDashboardRoute {
    enum Destination {
        case map
        case here
    }

    private static var pending: Destination?

    static func request(_ destination: Destination) {
        pending = destination
    }

    /// Lit ET efface l'intention : une intention consommée deux fois rouvrirait
    /// le même écran au retour de chaque sous-écran.
    static func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
