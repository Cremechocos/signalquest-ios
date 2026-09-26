import CoreLocation
import Foundation

/// Contexte de scène, indépendant du clavier et de la caméra. Une recherche en
/// cours ne peut jamais se transformer silencieusement en position physique.
enum AntennaSightOrigin: Hashable {
    case device
    case searchedAddress(latitude: Double, longitude: Double, title: String)
    case unresolved

    static func resolve(query: String, latitudeText: String, longitudeText: String, title: String) -> Self {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unresolved }
        guard !latitudeText.isEmpty || !longitudeText.isEmpty || !title.isEmpty else { return .device }
        guard let latitude = Double(latitudeText), let longitude = Double(longitudeText),
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return .unresolved
        }
        return .searchedAddress(latitude: latitude, longitude: longitude, title: title)
    }

    var isDevice: Bool { self == .device }

    var label: String {
        switch self {
        case .device: return String(localized: "Depuis ta position")
        case .searchedAddress: return String(localized: "Depuis l’adresse recherchée")
        case .unresolved: return String(localized: "Origine à préciser")
        }
    }

    /// Le service appelant fournit uniquement une position admise par sa
    /// politique existante (autorisation, fraîcheur et précision).
    func coordinate(deviceLocation: CLLocation?) -> CLLocationCoordinate2D? {
        switch self {
        case .device: return deviceLocation?.coordinate
        case let .searchedAddress(latitude, longitude, _):
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        case .unresolved: return nil
        }
    }
}

/// Relevé exact du trajet GPS, stabilisé spatialement sans renouveler sa date.
/// La politique de fraîcheur reste celle du service, fournie par l'appelant.
struct AntennaSightGPSSnapshot {
    private(set) var location: CLLocation?
    private(set) var revision = UUID()
    static let movementThresholdMeters: Double = 100

    mutating func update(current: CLLocation?, policy: LocationFixPolicy, now: Date, force: Bool = false) {
        guard let current, policy.accepts(current, now: now) else {
            clear()
            return
        }
        if !force, let location, policy.accepts(location, now: now),
           location.distance(from: current) < Self.movementThresholdMeters { return }
        location = current
        revision = UUID()
    }

    mutating func clear() {
        guard location != nil else { return }
        location = nil
        revision = UUID()
    }

    func expiresAt(maxAge: TimeInterval) -> Date? {
        location?.timestamp.addingTimeInterval(maxAge)
    }

    /// La position courante conserve un veto absolu, même lorsque le trajet
    /// reste stabilisé à moins de 100 m. Une position absente n'est pas un zéro.
    static func permitsProfile(snapshotDistance: Double, currentDistance: Double?) -> Bool {
        guard let currentDistance, currentDistance.isFinite, currentDistance >= 0 else { return false }
        return snapshotDistance.isFinite && snapshotDistance > 20 && snapshotDistance <= 30_000
            && currentDistance <= 30_000
    }
}
