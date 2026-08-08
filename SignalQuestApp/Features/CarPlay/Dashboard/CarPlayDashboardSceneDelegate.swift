import CarPlay
import MapKit
import UIKit

/// Scène Dashboard : la vignette de carte affichée à côté des widgets du
/// véhicule, quand le conducteur n'a pas SignalQuest au premier plan.
///
/// C'est une scène DISTINCTE de la scène principale, avec sa propre fenêtre et
/// son propre cycle de vie — les deux peuvent être connectées en même temps. Elle
/// relève du même entitlement `carplay-maps`, donc rien de plus à demander à
/// Apple que ce qui est déjà nécessaire à la carte.
///
/// Contrainte de surface : quelques centimètres partagés avec les widgets du
/// système. D'où deux partis pris — les antennes seules, et aucune couche dense.
/// Reproduire ici la carte complète donnerait une bouillie illisible.
@MainActor
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    private var mapController: CarPlayMapController?
    private var layers: CarPlayLayerController?
    private var loadTask: Task<Void, Never>?
    private var locationObserver: UUID?
    private var lastLoadedCenter: CLLocationCoordinate2D?

    /// Zoom un cran plus large que l'écran principal : sur une vignette, un
    /// cadrage serré ne montre plus rien d'utile autour du véhicule.
    private static let dashboardZoom: Double = 13

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        let services = AppServicesHolder.services
        let controller = CarPlayMapController()
        mapController = controller
        layers = CarPlayLayerController(map: services.map)
        window.rootViewController = controller

        // Deux boutons au maximum, et ils ouvrent l'app plutôt que d'agir sur
        // place : le Dashboard est une vue de coin d'œil, pas un poste de
        // pilotage.
        dashboardController.shortcutButtons = [
            CPDashboardButton(
                titleVariants: [String(localized: "Antennes")],
                subtitleVariants: [String(localized: "Voir la carte")],
                image: UIImage(systemName: "antenna.radiowaves.left.and.right") ?? UIImage()
            ) { _ in },
            CPDashboardButton(
                titleVariants: [String(localized: "Ici")],
                subtitleVariants: [String(localized: "Réseau autour")],
                image: UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage()
            ) { _ in },
        ]

        controller.setZoom(Self.dashboardZoom, animated: false)
        locationObserver = services.location.addLocationObserver { [weak self] location in
            self?.reloadIfNeeded(around: location.coordinate)
        }
        if let location = services.location.lastLocation {
            reloadIfNeeded(around: location.coordinate)
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        teardown()
    }

    /// Filet de sécurité : la méthode de déconnexion du protocole est
    /// `@optional` et ne couvre pas toutes les terminaisons de scène.
    func sceneDidDisconnect(_ scene: UIScene) {
        teardown()
    }

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        if let locationObserver {
            AppServicesHolder.services.location.removeLocationObserver(locationObserver)
            self.locationObserver = nil
        }
        mapController = nil
        layers = nil
    }

    /// Rechargement plus paresseux que sur l'écran principal (800 m contre 400) :
    /// le Dashboard est consulté d'un coup d'œil, et il partage la connexion du
    /// véhicule avec la scène principale quand les deux sont actives.
    private func reloadIfNeeded(around coordinate: CLLocationCoordinate2D) {
        if let last = lastLoadedCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard moved >= 800 else { return }
        }
        lastLoadedCenter = coordinate
        guard let controller = mapController, let layers else { return }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = await layers.load(
                bounds: SQMapProjection.bounds(of: controller.mapView.region),
                zoom: Self.dashboardZoom,
                // Antennes seules : les couches denses n'ont pas la place de se
                // lire sur une vignette, et les charger coûterait des données
                // pour un rendu illisible.
                filters: [.antenna],
                market: MapMarketStore.initialMarketCode(),
                operatorKey: MapMarketStore.initialOperatorKey()
            )
            guard !Task.isCancelled, self != nil else { return }
            controller.apply(payloads: loaded.annotations)
        }
    }
}
