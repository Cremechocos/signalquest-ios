import CarPlay
import CoreLocation
import UserNotifications

/// Réglages des alertes CarPlay, désactivées par défaut.
///
/// Opt-in délibéré : une alerte non sollicitée pendant la conduite est au mieux
/// une nuisance, au pire un danger. Personne ne doit découvrir cette
/// fonctionnalité en sursautant au volant.
enum CarPlayAlertSettings {
    static let coverageAlertsKey = "sq.carplay.coverageAlerts"

    static var coverageAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: coverageAlertsKey)
    }
}

/// Décide s'il faut alerter le conducteur d'une zone mal couverte.
///
/// Entièrement pure et sans état caché : c'est la règle qui protège de
/// l'acharnement, et elle doit être vérifiable sans rouler. Un guidage bavard
/// se coupe ; une app qui parle au mauvais moment se désinstalle.
enum CarPlayAlertPolicy {
    /// Délai minimal entre deux alertes.
    static let minimumInterval: TimeInterval = 600

    /// Rayon en deçà duquel on considère être dans la MÊME zone déjà signalée.
    static let sameZoneRadiusMeters: CLLocationDistance = 2_000

    /// Vitesse plancher : à l'arrêt ou au pas, l'utilisateur n'est pas en train
    /// de « traverser » une zone, et l'alerte est du bruit.
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 5

    struct Context {
        var isEnabled: Bool
        var verdict: CoverageQualityBand?
        var sampleCount: Int
        var speed: CLLocationSpeed
        var coordinate: CLLocationCoordinate2D
        var lastAlertAt: Date?
        var lastAlertCoordinate: CLLocationCoordinate2D?
        var now: Date
        /// Une manœuvre est annoncée : le conducteur a besoin de son attention
        /// pour tourner, pas pour apprendre que le réseau est mauvais.
        var isManeuverImminent: Bool
    }

    static func shouldAlert(_ context: Context) -> Bool {
        guard context.isEnabled else { return false }
        guard !context.isManeuverImminent else { return false }

        // Seuls les mauvais verdicts alertent, et seulement s'ils reposent sur
        // assez de mesures : signaler « mauvais » sur trois relevés serait une
        // fausse alerte présentée comme un fait.
        guard let verdict = context.verdict, verdict == .poor || verdict == .weak else { return false }
        guard context.sampleCount >= 20 else { return false }

        guard context.speed >= minimumSpeedMetersPerSecond else { return false }

        if let lastAlertAt = context.lastAlertAt,
           context.now.timeIntervalSince(lastAlertAt) < minimumInterval {
            return false
        }
        if let lastCoordinate = context.lastAlertCoordinate {
            let distance = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
                .distance(from: CLLocation(latitude: context.coordinate.latitude,
                                           longitude: context.coordinate.longitude))
            // Deux alertes pour la même zone, c'est une alerte de trop.
            if distance < sameZoneRadiusMeters { return false }
        }
        return true
    }

    static func message(for verdict: CoverageQualityBand, operatorLabel: String) -> String {
        String(localized: "Réseau \(verdict.title.lowercased()) ici pour \(operatorLabel).")
    }
}

/// Catégories de notification exposées à CarPlay.
///
/// ⚠️ Sans `.allowInCarPlay`, iOS ne relaie RIEN vers l'écran du véhicule, même
/// si la notification s'affiche normalement sur l'iPhone. C'est l'unique
/// interrupteur côté app.
enum CarPlayNotificationCategories {
    static let sentinelleAlert = "SENTINELLE_ALERT"
    static let coverageAlert = "SQ_COVERAGE_ALERT"

    static func all() -> Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: sentinelleAlert, actions: [],
                                   intentIdentifiers: [], options: [.allowInCarPlay]),
            UNNotificationCategory(identifier: coverageAlert, actions: [],
                                   intentIdentifiers: [], options: [.allowInCarPlay]),
        ]
    }
}
