import Foundation
import CoreLocation

/// La précision publiée est celle du capteur, jamais une précision inventée.
/// Un plafond peut être demandé par un usage exigeant ; sinon une position
/// approximative reste utilisable avec son incertitude réelle.
struct LocationFixPolicy: Equatable, Sendable {
    let maxAge: TimeInterval
    let maximumAccuracy: CLLocationAccuracy?
    static let futureTolerance: TimeInterval = 1

    var isValid: Bool {
        maxAge.isFinite && maxAge >= 0
            && (maximumAccuracy.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    func accepts(_ fix: CLLocation, now: Date, requestedAt: Date? = nil) -> Bool {
        guard isValid, CLLocationCoordinate2DIsValid(fix.coordinate),
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              fix.timestamp.timeIntervalSince1970.isFinite else { return false }
        if let maximumAccuracy, fix.horizontalAccuracy > maximumAccuracy { return false }
        let age = now.timeIntervalSince(fix.timestamp)
        guard age >= -Self.futureTolerance else { return false }
        // maxAge=0 interdit le cache : seul un relevé daté depuis le début de
        // cette demande est admissible (la livraison arrive forcément après).
        if maxAge == 0 {
            return requestedAt.map { fix.timestamp >= $0 } ?? false
        }
        return age < maxAge
    }
}
