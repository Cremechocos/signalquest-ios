import MapKit

/// Conversion zoom ↔ span en projection « slippy map », celle des tuiles serveur
/// (z/x/y).
///
/// Extraite du `Coordinator` de `MapKitMapView` quand CarPlay est arrivé : le
/// véhicule dessine sa propre `MKMapView` et doit cadrer EXACTEMENT comme
/// l'iPhone. Une formule qui divergerait, même un peu, ferait demander des
/// tuiles d'un autre niveau que celui réellement affiché — antennes absentes ou
/// densité incohérente, sans erreur visible.
enum SQMapProjection {
    /// Largeur de repli quand la vue n'est pas encore mesurée.
    static let referenceWidth: CGFloat = 390

    static func span(forZoom zoom: Double, width: CGFloat) -> MKCoordinateSpan {
        let lonDelta = Double(width) * 360.0 / (256.0 * pow(2.0, max(zoom, 0.0)))
        return MKCoordinateSpan(latitudeDelta: min(170, lonDelta), longitudeDelta: min(360, lonDelta))
    }

    static func zoom(forRegion region: MKCoordinateRegion, width: CGFloat) -> Double {
        let lonDelta = max(region.span.longitudeDelta, 0.0000001)
        return log2(Double(width) * 360.0 / (256.0 * lonDelta))
    }

    /// Longueur des lobes d'azimut, en points, selon le zoom. Nulle en dessous
    /// de z9 : des cônes dessinés à cette échelle se chevauchent en une bouillie.
    static func azimuthReach(forZoom zoom: Double) -> CGFloat {
        switch zoom {
        case ..<9: return 0
        case ..<10: return 32
        case ..<11: return 42
        case ..<12: return 55
        default:    return 66
        }
    }

    /// Emprise d'une région, dans la forme attendue par les services de tuiles.
    static func bounds(of region: MKCoordinateRegion) -> MapBounds {
        MapBounds(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
    }
}
