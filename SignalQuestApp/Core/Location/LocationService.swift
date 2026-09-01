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
    private var locationContinuations: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    private var authorizationContinuations: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]
    /// Suivi continu demandé (drive test) : permet de (re)démarrer le tracking dès
    /// que l'autorisation est accordée, même si l'utilisateur valide le prompt après.
    /// Suivi continu demandé (rafale / drive test). Exposé en lecture parce que
    /// c'est le signal qui autorise l'app à rester active écran verrouillé :
    /// tant qu'il est vrai, couper les boucles réseau d'arrière-plan priverait
    /// l'utilisateur de ce qu'il a explicitement lancé.
    @Published private(set) var wantsTracking = false
    /// Abonnés aux positions. Chaque consommateur possède son jeton : Drive Test,
    /// CarPlay et les alertes peuvent ainsi coexister sans s'écraser.
    private var locationObservers: [UUID: @MainActor (CLLocation) -> Void] = [:]

    /// Suivi réclamé explicitement par `startTracking()` (drive test, rafale),
    /// par opposition au suivi INDUIT par la présence d'abonnés.
    ///
    /// Les deux sources doivent être distinguées, sinon chacune coupe l'autre :
    /// un drive test qui se termine éteindrait le suivi dont CarPlay a encore
    /// besoin, et inversement.
    private var explicitTrackingRequested = false

    /// S'abonner suffit à obtenir des positions.
    ///
    /// Auparavant, poser un observateur n'enclenchait rien : seul `startTracking()`
    /// appelait `startUpdatingLocation()`. Un abonné qui ne démarrait pas lui-même
    /// le suivi n'était donc jamais appelé — c'est ce qui rendait les alertes de
    /// couverture CarPlay muettes hors guidage.
    @discardableResult
    func addLocationObserver(_ handler: @escaping @MainActor (CLLocation) -> Void) -> UUID {
        let token = UUID()
        locationObservers[token] = handler
        syncTracking()
        return token
    }

    func removeLocationObserver(_ token: UUID) {
        guard locationObservers.removeValue(forKey: token) != nil else { return }
        syncTracking()
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
        explicitTrackingRequested = true
        syncTracking()
    }

    /// Aligne l'état réel du `CLLocationManager` sur la demande courante.
    ///
    /// Point unique de bascule : le suivi démarre dès qu'au moins une source le
    /// réclame, et ne s'arrête qu'une fois la DERNIÈRE relâchée. Sans ce
    /// comptage, `startTracking()` laissait le GPS haute précision et
    /// `allowsBackgroundLocationUpdates` actifs indéfiniment — y compris après
    /// débranchement du véhicule.
    private func syncTracking() {
        let desired = explicitTrackingRequested || !locationObservers.isEmpty
        guard desired != wantsTracking else { return }
        wantsTracking = desired

        guard desired else {
            endTrackingNow()
            return
        }
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

    /// Relâche la demande explicite de suivi continu.
    ///
    /// ⚠️ N'éteint pas forcément le GPS : si des observateurs sont encore posés
    /// (CarPlay branché, par exemple), le suivi continue pour eux. C'est
    /// délibéré — couper leurs positions parce qu'un autre écran a terminé
    /// serait une panne silencieuse.
    func stopTracking() {
        explicitTrackingRequested = false
        syncTracking()
    }

    /// Coupe réellement le suivi et restaure les réglages one-shot par défaut.
    private func endTrackingNow() {
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
            let status = await withCheckedContinuation { continuation in
                let requestID = UUID()
                authorizationContinuations[requestID] = continuation
                if authorizationContinuations.count == 1 { requestWhenInUse() }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: min(timeoutSeconds, 6) * 1_000_000_000)
                    authorizationContinuations.removeValue(forKey: requestID)?
                        .resume(returning: authorizationStatus)
                }
            }
            authorizationStatus = status
        }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let requestID = UUID()
            locationContinuations[requestID] = continuation
            if locationContinuations.count == 1 { manager.requestLocation() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                locationContinuations.removeValue(forKey: requestID)?
                    .resume(returning: lastLocation)
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
            let continuations = Array(authorizationContinuations.values)
            authorizationContinuations.removeAll()
            continuations.forEach { $0.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            lastLocation = locations.last
            errorMessage = nil
            if let last = locations.last {
                // Copie avant itération : un abonné qui se désabonne depuis son
                // propre handler (arrivée à destination, par exemple) muterait
                // le dictionnaire en cours de parcours.
                for observer in Array(locationObservers.values) { observer(last) }
            }
            let continuations = Array(locationContinuations.values)
            locationContinuations.removeAll()
            continuations.forEach { $0.resume(returning: locations.last) }
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
            let continuations = Array(locationContinuations.values)
            locationContinuations.removeAll()
            continuations.forEach { $0.resume(returning: nil) }
        }
    }
}
