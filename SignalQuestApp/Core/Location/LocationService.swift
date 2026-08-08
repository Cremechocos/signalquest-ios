import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var errorMessage: String?

    /// Âge maximal d'un fix réutilisé tel quel par `currentLocation()`. Au-delà,
    /// on redemande une position fraîche au lieu de renvoyer un cache périmé —
    /// sinon une app gardée en mémoire géotague les mesures (et les publie sur la
    /// carte communautaire) à une position quittée depuis longtemps (TEL-01/ROB-04).
    static let defaultMaxLocationAge: TimeInterval = 60

    private let manager: CLLocationManager
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    /// Jeton incrémenté à chaque requête one-shot : un timeout ne doit résoudre
    /// que SA propre continuation, jamais celle d'un appel plus récent (ROB-13).
    private var locationRequestGeneration = 0
    /// Suivi continu demandé (drive test) : permet de (re)démarrer le tracking dès
    /// que l'autorisation est accordée, même si l'utilisateur valide le prompt après.
    /// Suivi continu demandé (rafale / drive test). Exposé en lecture parce que
    /// c'est le signal qui autorise l'app à rester active écran verrouillé :
    /// tant qu'il est vrai, couper les boucles réseau d'arrière-plan priverait
    /// l'utilisateur de ce qu'il a explicitement lancé.
    @Published private(set) var wantsTracking = false
    /// Callback optionnel appelé à chaque position pendant un suivi continu.
    /// Mis à nil par l'appelant en fin de session (drive test).
    var onLocationUpdate: (@MainActor (CLLocation) -> Void)?

    /// Abonnés supplémentaires aux positions.
    ///
    /// `onLocationUpdate` est un emplacement UNIQUE : le drive test s'y installe
    /// et le libère en fin de session. Depuis que le guidage CarPlay suit lui
    /// aussi la position, deux consommateurs peuvent coexister — et l'écraser
    /// ferait perdre ses fixes à un drive test en cours, sans la moindre erreur.
    /// Même motif que `headingSubscribers` : on compte les abonnés au lieu de
    /// supposer qu'il n'y en a qu'un.
    private var locationObservers: [UUID: @MainActor (CLLocation) -> Void] = [:]

    @discardableResult
    func addLocationObserver(_ handler: @escaping @MainActor (CLLocation) -> Void) -> UUID {
        let token = UUID()
        locationObservers[token] = handler
        return token
    }

    func removeLocationObserver(_ token: UUID) {
        locationObservers[token] = nil
    }

    /// Cap de l'appareil en degrés (0 = nord géographique), `nil` tant que
    /// personne ne l'a demandé ou si le magnétomètre est indisponible ou non
    /// calibré. Sert à orienter une visée : une flèche qui tourne avec le
    /// téléphone désigne l'antenne dans le monde réel, là où un relèvement en
    /// degrés demande de faire le calcul soi-même.
    ///
    /// On ne publie qu'un scalaire, pas le `CLHeading` : la classe n'est pas
    /// `Sendable` et ne peut pas traverser vers le main actor sous Swift 6.
    @Published private(set) var headingDegrees: Double?
    /// Nombre d'écrans qui ont demandé le cap. Le magnétomètre consomme : on ne
    /// l'arrête que lorsque le DERNIER écran le relâche, sinon deux fiches
    /// ouvertes en pile s'éteignent mutuellement.
    private var headingSubscribers = 0

    override init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Démarre un suivi de position CONTINU (mode rafale / drive test). Les updates
    /// alimentent `lastLocation`, que `currentLocation()` renvoie immédiatement à
    /// chaque test. `allowsBackgroundLocationUpdates` (avec le background mode
    /// `location` de l'Info.plist) maintient l'app active écran verrouillé. À
    /// n'appeler qu'au premier plan, autorisation « Pendant l'utilisation » accordée.
    func startTracking() {
        wantsTracking = true
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginTrackingNow()
        case .notDetermined:
            manager.requestWhenInUseAuthorization() // le tracking démarrera à l'octroi
        default:
            break // refusé : pas de tracking (le drive test tournera sans position)
        }
    }

    private func beginTrackingNow() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // PERF-GPS-01 : ne livrer un fix que tous les 8 m (= le seuil applicatif de la
        // trace). Supprime les fixes redondants à l'arrêt / basse vitesse, qui
        // déclenchaient sinon à chaque fois recomputeNearest (O(antennes)) + écriture
        // App Group + tâches sur le main thread. Densité de trace inchangée (seuil 8 m).
        manager.distanceFilter = 8
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    /// Arrête le suivi continu et restaure les réglages one-shot par défaut.
    func stopTracking() {
        wantsTracking = false
        manager.stopUpdatingLocation()
        if manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Démarre la diffusion du cap. Aucune autorisation supplémentaire n'est
    /// requise : le cap relève de la même permission de localisation. À appeler
    /// à l'apparition d'un écran qui vise, et à relâcher à sa disparition.
    func startHeadingUpdates() {
        headingSubscribers += 1
        guard headingSubscribers == 1, CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2 // degrés : sous ce seuil, la flèche ne bouge pas à l'œil
        manager.startUpdatingHeading()
    }

    func stopHeadingUpdates() {
        headingSubscribers = max(0, headingSubscribers - 1)
        guard headingSubscribers == 0 else { return }
        manager.stopUpdatingHeading()
        headingDegrees = nil
    }

    func requestOneShotLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            requestWhenInUse()
            return
        }
        manager.requestLocation()
    }

    func currentLocation(
        timeoutSeconds: UInt64 = 8,
        maxAge: TimeInterval = LocationService.defaultMaxLocationAge
    ) async -> CLLocation? {
        // En suivi continu (drive test), `lastLocation` est rafraîchi en flux : on
        // peut le renvoyer directement. Hors suivi, on ne le réutilise que s'il est
        // récent ; périmé, on redemande un fix au lieu de renvoyer une vieille position.
        if let lastLocation, wantsTracking || lastLocation.timestamp.timeIntervalSinceNow > -maxAge {
            return lastLocation
        }
        if authorizationStatus == .notDetermined {
            requestWhenInUse()
            let status = await withCheckedContinuation { continuation in
                // Ne jamais écraser une continuation en attente sans la résoudre
                // (sinon l'appelant précédent reste suspendu pour toujours).
                authorizationContinuation?.resume(returning: authorizationStatus)
                authorizationContinuation = continuation
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: min(timeoutSeconds, 6) * 1_000_000_000)
                    if authorizationContinuation != nil {
                        authorizationContinuation?.resume(returning: authorizationStatus)
                        authorizationContinuation = nil
                    }
                }
            }
            authorizationStatus = status
        }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            return nil
        }
        manager.requestLocation()
        locationRequestGeneration &+= 1
        let generation = locationRequestGeneration
        return await withCheckedContinuation { continuation in
            // Idem : résoudre toute continuation de localisation déjà en attente
            // avant d'en installer une nouvelle, pour éviter une fuite/blocage.
            locationContinuation?.resume(returning: lastLocation)
            locationContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                // Ne résoudre que si c'est TOUJOURS notre requête : un appel plus
                // récent a pu remplacer la continuation entre-temps (ROB-13).
                if locationRequestGeneration == generation, locationContinuation != nil {
                    locationContinuation?.resume(returning: lastLocation)
                    locationContinuation = nil
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationStatus = status
            // Suivi continu demandé avant l'octroi : on le (re)démarre maintenant.
            if wantsTracking, status == .authorizedWhenInUse || status == .authorizedAlways {
                beginTrackingNow()
            }
            authorizationContinuation?.resume(returning: status)
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            lastLocation = locations.last
            errorMessage = nil
            if let last = locations.last {
                onLocationUpdate?(last)
                // Copie avant itération : un abonné qui se désabonne depuis son
                // propre handler (arrivée à destination, par exemple) muterait
                // le dictionnaire en cours de parcours.
                for observer in Array(locationObservers.values) { observer(last) }
            }
            locationContinuation?.resume(returning: locations.last)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Une précision négative signale un magnétomètre non calibré, et un
        // `trueHeading` négatif un cap géographique indisponible (pas de position) :
        // mieux vaut pas de flèche qu'une flèche qui pointe n'importe où. Le cap
        // magnétique reste utilisable à défaut — la déclinaison est de l'ordre du
        // degré en France, invisible sur un cadran de 90 pt.
        let degrees: Double?
        if newHeading.headingAccuracy < 0 {
            degrees = nil
        } else if newHeading.trueHeading >= 0 {
            degrees = newHeading.trueHeading
        } else {
            degrees = newHeading.magneticHeading >= 0 ? newHeading.magneticHeading : nil
        }
        Task { @MainActor in
            headingDegrees = degrees
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
        }
    }
}
