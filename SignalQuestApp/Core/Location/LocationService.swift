import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var errorMessage: String?

    private let manager: CLLocationManager
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    /// Suivi continu demandé (drive test) : permet de (re)démarrer le tracking dès
    /// que l'autorisation est accordée, même si l'utilisateur valide le prompt après.
    private var wantsTracking = false
    /// Callback optionnel appelé à chaque position pendant un suivi continu.
    /// Mis à nil par l'appelant en fin de session (drive test).
    var onLocationUpdate: (@MainActor (CLLocation) -> Void)?

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

    func requestOneShotLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            requestWhenInUse()
            return
        }
        manager.requestLocation()
    }

    func currentLocation(timeoutSeconds: UInt64 = 8) async -> CLLocation? {
        if let lastLocation { return lastLocation }
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
        return await withCheckedContinuation { continuation in
            // Idem : résoudre toute continuation de localisation déjà en attente
            // avant d'en installer une nouvelle, pour éviter une fuite/blocage.
            locationContinuation?.resume(returning: lastLocation)
            locationContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if locationContinuation != nil {
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
            if let last = locations.last { onLocationUpdate?(last) }
            locationContinuation?.resume(returning: locations.last)
            locationContinuation = nil
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
