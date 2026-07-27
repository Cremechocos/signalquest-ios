import SwiftUI
import CoreLocation
import MapKit

extension MapBounds {
    var asBoundingBox: BoundingBox {
        BoundingBox(north: north, south: south, east: east, west: west)
    }

    func contains(lat: Double?, lon: Double?) -> Bool {
        guard let lat, let lon else { return false }
        return lat <= north && lat >= south && lon <= east && lon >= west
    }
}
