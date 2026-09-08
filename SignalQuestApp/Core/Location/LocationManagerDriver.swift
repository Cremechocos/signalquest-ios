import CoreLocation

/// Frontière native injectable : les tests pilotent permissions et callbacks
/// sans solliciter le GPS ni afficher une invite système.
@MainActor
protocol LocationManagerDriving: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var headingFilter: CLLocationDegrees { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startUpdatingHeading()
    func stopUpdatingHeading()
}

extension CLLocationManager: LocationManagerDriving {}

/// Un delegate par acquisition lie les callbacks à leur lot, même s'ils sont
/// déjà en attente sur le MainActor lors d'une annulation suivie d'une reprise.
@MainActor
final class LocationOneShotDelegate: NSObject, CLLocationManagerDelegate {
    private weak var service: LocationService?
    let generation: UUID

    init(service: LocationService, generation: UUID) {
        self.service = service
        self.generation = generation
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            service?.receiveLocations(locations, generation: generation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            service?.receiveLocationFailure(error, generation: generation)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.service?.refreshAuthorization() }
    }
}
