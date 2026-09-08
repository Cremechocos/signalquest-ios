import Foundation

/// La première requête attend une géométrie mesurée ET le contexte initial.
/// Les filtres réutilisent ensuite exactement le snapshot admis par MapKit.
struct MapViewportLoadGate {
    private(set) var latest: MapViewportSnapshot?
    private(set) var isConfigured = false
    var admitted: MapViewportSnapshot? { isConfigured ? latest : nil }

    mutating func record(_ viewport: MapViewportSnapshot) { latest = viewport }
    mutating func configure() { isConfigured = true }
    mutating func invalidateCamera() { latest = nil }
    mutating func pause() { isConfigured = false; latest = nil }
}
