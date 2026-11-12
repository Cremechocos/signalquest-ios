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

    /// Intervalle minimal entre deux rechargements dus au déplacement de la
    /// carte : CarPlay demande de ne pas rafraîchir les points d'intérêt plus
    /// d'une fois par minute. Une zone demandée entre-temps n'est pas perdue :
    /// elle se charge à l'échéance.
    private let minimumInterval: TimeInterval

    private let onReload: (MKCoordinateRegion) -> Void
    private var lastLoadedCenter: CLLocationCoordinate2D?
    private var lastLoadedAt: Date?
    /// Dernière zone demandée pendant l'intervalle, chargée à son terme.
    private var pendingRegion: MKCoordinateRegion?
    private var catchUp: Task<Void, Never>?

    init(minimumInterval: TimeInterval = 60, onReload: @escaping (MKCoordinateRegion) -> Void) {
        self.minimumInterval = minimumInterval
        self.onReload = onReload
        super.init()
    }

    /// CarPlay l'appelle depuis sa file XPC, hors du fil principal (iOS 27.2) :
    /// sous `@MainActor`, le contrôle d'isolation de Swift 6 faisait planter
    /// l'app (EXC_BREAKPOINT, builds 178 à 181). On repasse sur le fil principal.
    nonisolated func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate,
                                             didChangeMapRegion region: MKCoordinateRegion) {
        Task { @MainActor [weak self] in self?.mapRegionDidChange(region) }
    }

    private func mapRegionDidChange(_ region: MKCoordinateRegion) {
        let center = region.center
        if let last = lastLoadedCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            guard moved >= Self.reloadDistanceMeters else {
                // Revenue près de la zone chargée : l'attente n'a plus d'objet.
                pendingRegion = nil
                return
            }
        }
        if let lastLoadedAt {
            let remaining = minimumInterval - Date().timeIntervalSince(lastLoadedAt)
            if remaining > 0 {
                pendingRegion = region
                scheduleCatchUp(after: remaining)
                return
            }
        }
        load(region)
    }

    private func load(_ region: MKCoordinateRegion) {
        catchUp?.cancel()
        catchUp = nil
        pendingRegion = nil
        noteLoaded(center: region.center)
        onReload(region)
    }

    private func scheduleCatchUp(after delay: TimeInterval) {
        guard catchUp == nil else { return }
        catchUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            catchUp = nil
            if let pendingRegion { load(pendingRegion) }
        }
    }

    /// Le coordinateur a chargé cette zone lui-même (ouverture de l'onglet,
    /// changement de couche) : le prochain déplacement compte à partir d'ici.
    func noteLoaded(center: CLLocationCoordinate2D) {
        lastLoadedCenter = center
        lastLoadedAt = Date()
    }

    /// Autorise un rechargement immédiat, quel que soit le dernier centre connu.
    /// Utile après un changement de couche, où la zone n'a pas bougé mais le
    /// contenu attendu, si.
    func invalidate() {
        catchUp?.cancel()
        catchUp = nil
        pendingRegion = nil
        lastLoadedCenter = nil
        lastLoadedAt = nil
    }
}
