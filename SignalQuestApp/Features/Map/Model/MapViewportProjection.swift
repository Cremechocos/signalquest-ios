import Foundation
import MapKit

enum MapViewportProjectionError: Error, Equatable {
    case invalidViewportSize
    case invalidRegion
    case invalidMapRect
    case unrepresentableScale
}

/// La mesure fournie par le moteur est la source de vérité pour tous les reloads
/// (pan, filtres, reprise), indépendamment de la largeur globale de l'appareil.
struct MapViewportSnapshot: Equatable, Sendable {
    let bounds: MapBounds
    let zoom: Double
    let widthPoints: Double
    let heightPoints: Double
    let centerLatitude: Double
    let centerLongitude: Double
}

enum MapViewportProjection {
    /// Pas de facteur UIScreen : le zoom du service et celui de MapKit prennent
    /// exactement la même largeur réellement mesurée de la carte.
    static func zoom(longitudeDelta: Double, widthPoints: Double) throws -> Double {
        guard widthPoints.isFinite, widthPoints > 0 else { throw MapViewportProjectionError.invalidViewportSize }
        guard longitudeDelta.isFinite, longitudeDelta > 0, longitudeDelta <= 360 else {
            throw MapViewportProjectionError.invalidRegion
        }
        // Calcul logarithmique pour ne pas déborder sur des entrées finies.
        return log2(widthPoints) + log2(360.0 / 256.0) - log2(longitudeDelta)
    }

    static func longitudeDelta(zoom: Double, widthPoints: Double) throws -> Double {
        guard widthPoints.isFinite, widthPoints > 0 else { throw MapViewportProjectionError.invalidViewportSize }
        guard zoom.isFinite else { throw MapViewportProjectionError.unrepresentableScale }
        let logDelta = log2(widthPoints) + log2(360.0 / 256.0) - zoom
        if logDelta >= log2(360) { return 360 }
        let delta = pow(2, logDelta)
        guard delta.isFinite, delta > 0 else { throw MapViewportProjectionError.unrepresentableScale }
        return delta
    }

    static func measured(region: MKCoordinateRegion, widthPoints: Double, heightPoints: Double) throws -> MapViewportSnapshot {
        try validateSize(width: widthPoints, height: heightPoints)
        guard region.center.latitude.isFinite, abs(region.center.latitude) <= 90,
              region.center.longitude.isFinite,
              region.span.latitudeDelta.isFinite, region.span.latitudeDelta > 0,
              region.span.latitudeDelta <= 180 else { throw MapViewportProjectionError.invalidRegion }
        let zoom = try zoom(longitudeDelta: region.span.longitudeDelta, widthPoints: widthPoints)
        let centerLongitude = normalizedLongitude(region.center.longitude)
        let bounds = MapBounds(
            north: min(90, region.center.latitude + region.span.latitudeDelta / 2),
            south: max(-90, region.center.latitude - region.span.latitudeDelta / 2),
            east: centerLongitude + region.span.longitudeDelta / 2,
            west: centerLongitude - region.span.longitudeDelta / 2
        )
        return MapViewportSnapshot(bounds: bounds, zoom: zoom, widthPoints: widthPoints, heightPoints: heightPoints,
                                   centerLatitude: region.center.latitude,
                                   centerLongitude: normalizedLongitude(region.center.longitude))
    }

    /// Convertit une emprise MapKit, y compris autour de l'antiméridien. La vue
    /// native mesure son rectangle UIKit complet quand des marges sont présentes.
    static func measured(mapRect: MKMapRect, widthPoints: Double, heightPoints: Double) throws -> MapViewportSnapshot {
        try validateSize(width: widthPoints, height: heightPoints)
        guard !mapRect.isNull, !mapRect.isEmpty,
              mapRect.origin.x.isFinite, mapRect.origin.y.isFinite,
              mapRect.size.width.isFinite, mapRect.size.height.isFinite,
              mapRect.size.width > 0, mapRect.size.height > 0,
              mapRect.maxX.isFinite, mapRect.maxY.isFinite,
              mapRect.maxX > mapRect.minX, mapRect.maxY > mapRect.minY else {
            throw MapViewportProjectionError.invalidMapRect
        }
        let worldWidth = MKMapRect.world.width
        let longitudeSpan = min(360, mapRect.width / worldWidth * 360)
        let rawWest = mapRect.minX / worldWidth * 360 - 180
        let west = normalizedLongitude(rawWest)
        let north = MKMapPoint(x: 0, y: mapRect.minY).coordinate.latitude
        let south = MKMapPoint(x: 0, y: mapRect.maxY).coordinate.latitude
        let center = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate
        guard west.isFinite, north.isFinite, south.isFinite,
              center.latitude.isFinite, center.longitude.isFinite else {
            throw MapViewportProjectionError.invalidMapRect
        }
        let zoom = try zoom(longitudeDelta: longitudeSpan, widthPoints: widthPoints)
        return MapViewportSnapshot(bounds: MapBounds(north: north, south: south, east: west + longitudeSpan, west: west),
                                   zoom: zoom, widthPoints: widthPoints, heightPoints: heightPoints,
                                   centerLatitude: center.latitude, centerLongitude: normalizedLongitude(center.longitude))
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        let remainder = longitude.truncatingRemainder(dividingBy: 360)
        if remainder >= 180 { return remainder - 360 }
        if remainder < -180 { return remainder + 360 }
        return remainder
    }

    private static func validateSize(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw MapViewportProjectionError.invalidViewportSize
        }
    }
}
