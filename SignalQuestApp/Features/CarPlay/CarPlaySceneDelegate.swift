import CarPlay
import UIKit

/// Point d'entrée de la scène CarPlay, référencé par `UISceneDelegateClassName`
/// dans l'Info.plist sous `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`.
///
/// Deux points à connaître avant d'y toucher :
///
/// 1. CarPlay appelle une méthode DIFFÉRENTE selon la catégorie qu'Apple a
///    accordée. Avec `carplay-maps` (navigation), le système confie une
///    `CPWindow` où dessiner notre propre `MKMapView`. Sans elle, on ne reçoit
///    que le contrôleur d'interface et l'on se rabat sur des templates. Les deux
///    variantes sont implémentées : la bascule est automatique, et l'app ne se
///    retrouve jamais muette dans le véhicule.
///
/// 2. `CPTemplateApplicationSceneDelegate` hérite de `UISceneDelegate`, annoté
///    `NS_SWIFT_UI_ACTOR` : tout est isolé au main actor, comme `AppServices`.
///    D'où des accès directs, sans `await` ni franchissement d'acteur.
///
/// On hérite de `UIResponder` — et non de `NSObject` — comme tout délégué de
/// scène : UIKit l'instancie par `init()` et l'insère dans la chaîne de
/// répondeurs, ce dont la variante à `CPWindow` aura besoin.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    // MARK: - Connexion

    /// Catégorie navigation (`carplay-maps`) : on reçoit la fenêtre du véhicule.
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        start(interfaceController, carWindow: window)
    }

    /// Repli sans carte : templates seuls.
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        start(interfaceController, carWindow: nil)
    }

    // MARK: - Déconnexion

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        stop()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        stop()
    }

    /// Ceinture et bretelles : les deux méthodes ci-dessus sont `@optional` côté
    /// protocole et ne couvrent pas toutes les terminaisons de scène. Sans ce
    /// filet, un débranchement mal signalé laisserait les tâches du coordinateur
    /// tourner pour un écran qui n'existe plus.
    func sceneDidDisconnect(_ scene: UIScene) {
        stop()
    }

    // MARK: - Privé

    private func start(_ interfaceController: CPInterfaceController, carWindow: CPWindow?) {
        // CarPlay peut rappeler didConnect lors d'une reconnexion rapide. Un seul
        // coordinateur doit posséder les observers GPS, tâches et templates.
        coordinator?.stop()
        // Passe par le holder : la fenêtre iPhone n'existe peut-être pas encore
        // (app lancée en arrière-plan par le véhicule), et il faut malgré tout
        // le MÊME graphe de services qu'elle utilisera ensuite.
        let coordinator = CarPlayCoordinator(
            interface: interfaceController,
            services: AppServicesHolder.services,
            session: AppServicesHolder.session,
            carWindow: carWindow
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    private func stop() {
        coordinator?.stop()
        coordinator = nil
    }
}
