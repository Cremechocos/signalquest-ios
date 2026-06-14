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
            authorizationContinuation?.resume(returning: status)
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            lastLocation = locations.last
            errorMessage = nil
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
