import SwiftUI
import CoreLocation
import MapKit

extension MapBounds {
    var asBoundingBox: BoundingBox {
        BoundingBox(north: north, south: south, east: east, west: west)
    }

    /// Au plus deux bbox monotones, compatibles avec les routes REST existantes.
    var canonicalSegments: [MapBounds] {
        get throws {
            guard isFinite, north >= south, north <= 90, south >= -90 else {
                throw MapTilePlanningError.invalidBounds
            }
            return try MapTilePlanner.longitudeRanges(west: west, east: east).map {
                MapBounds(north: north, south: south, east: $0.east, west: $0.west)
            }
        }
    }

    func contains(lat: Double?, lon: Double?) -> Bool {
        guard isFinite, north >= south, let lat, let lon, lat.isFinite, lon.isFinite,
              lat <= north, lat >= south,
              let ranges = try? MapTilePlanner.longitudeRanges(west: west, east: east) else { return false }
        let normalized = MapViewportProjection.normalizedLongitude(lon)
        return ranges.contains { (normalized >= $0.west && normalized <= $0.east)
            || (normalized == -180 && $0.east == 180) }
    }
}
