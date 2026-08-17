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

    /// Scène principale prête à recevoir une intention immédiatement.
    ///
    /// Le dépôt seul ne suffisait pas : il n'était relu qu'à l'INSTALLATION de
    /// la racine. Or le cas nominal est l'inverse — véhicule déjà branché,
    /// scène déjà installée, et l'utilisateur presse « Y aller » sur son
    /// iPhone. L'intention restait alors en mémoire jusqu'à la prochaine
    /// connexion, c'est-à-dire que le bouton ne faisait visiblement rien.
    private static var listener: ((Destination) -> Void)?

    static func request(_ destination: Destination) {
        if let listener {
            listener(destination)
            return
        }
        pending = destination
    }

    /// Installe (ou retire) le consommateur, en lui servant au passage une
    /// intention déposée avant qu'il n'existe.
    static func setListener(_ handler: ((Destination) -> Void)?) {
        listener = handler
        guard let handler, let waiting = consume() else { return }
        handler(waiting)
    }

    /// Lit ET efface l'intention : une intention consommée deux fois rouvrirait
    /// le même écran au retour de chaque sous-écran.
    static func consume() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
