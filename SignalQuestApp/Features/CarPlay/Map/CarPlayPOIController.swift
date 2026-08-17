import CarPlay
import CoreLocation
import MapKit

/// Tient la carte des points d'intérêt à jour quand le conducteur la déplace.
///
/// Existe comme objet plutôt que comme closure pour une raison précise :
/// `CPPointOfInterestTemplate.pointOfInterestDelegate` est une référence
/// FAIBLE. Un délégué local serait libéré avant le premier déplacement de
/// carte, et le rechargement ne se produirait jamais — exactement le piège déjà
/// documenté pour `CPSearchTemplate.delegate`. Le coordinateur le retient.
///
/// `didChangeMapRegion` est `@required` : sans lui, la carte n'afficherait que
/// les antennes chargées au premier rendu, et faire défiler la carte donnerait
/// une zone vide.
@MainActor
final class CarPlayPOIController: NSObject, CPPointOfInterestTemplateDelegate {
    /// Distance minimale entre deux chargements.
    ///
    /// Le délégué est appelé à chaque micro-déplacement. Le seuil vient du
    /// rechargement des couches de la carte, où il est éprouvé — au-delà, on
    /// interrogerait le serveur en continu pour un contenu identique.
    private static let reloadDistanceMeters: CLLocationDistance = 400

    private let onReload: (MKCoordinateRegion) -> Void
    private var lastLoadedCenter: CLLocationCoordinate2D?

    init(onReload: @escaping (MKCoordinateRegion) -> Void) {
        self.onReload = onReload
        super.init()
    }

    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate,
                                 didChangeMapRegion region: MKCoordinateRegion) {
        let center = region.center
        if let last = lastLoadedCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            guard moved >= Self.reloadDistanceMeters else { return }
        }
        lastLoadedCenter = center
        onReload(region)
    }

    /// Autorise un rechargement immédiat, quel que soit le dernier centre connu.
    /// Utile après un changement de filtre, où la zone n'a pas bougé mais le
    /// contenu attendu, si.
    func invalidate() {
        lastLoadedCenter = nil
    }
}
