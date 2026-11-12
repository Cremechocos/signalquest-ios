import CarPlay
import UIKit

/// Point d'entrée de la scène CarPlay, référencé par `UISceneDelegateClassName`
/// dans l'Info.plist sous `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`.
///
/// Deux points à connaître avant d'y toucher :
///
/// 1. Apple n'a accordé que la catégorie « driving task » : le système appelle
///    la variante SANS fenêtre (`didConnect interfaceController:`), et l'app
///    n'affiche que des templates. La variante à `CPWindow` est réservée à la
///    navigation (`carplay-maps`), que nous n'avons pas.
///
/// 2. `CPTemplateApplicationSceneDelegate` hérite de `UISceneDelegate`, annoté
///    `NS_SWIFT_UI_ACTOR` : tout est isolé au main actor, comme `AppServices`.
///    D'où des accès directs, sans `await` ni franchissement d'acteur.
///
/// On hérite de `UIResponder` — et non de `NSObject` — comme tout délégué de
/// scène : UIKit l'instancie par `init()` et l'insère dans la chaîne de
/// répondeurs.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    // MARK: - Connexion

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        start(interfaceController, scene: templateApplicationScene)
    }

    // MARK: - Déconnexion

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        stop()
    }

    /// Ceinture et bretelles : la méthode ci-dessus est `@optional` côté
    /// protocole et ne couvre pas toutes les terminaisons de scène. Sans ce
    /// filet, un débranchement mal signalé laisserait les tâches du coordinateur
    /// tourner pour un écran qui n'existe plus.
    func sceneDidDisconnect(_ scene: UIScene) {
        stop()
    }

    // MARK: - Privé

    private func start(_ interfaceController: CPInterfaceController, scene: CPTemplateApplicationScene) {
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
            // « Y aller » : Plans prend l'écran du véhicule pour guider.
            openURL: { [weak scene] url in scene?.open(url, options: nil, completionHandler: nil) }
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    private func stop() {
        coordinator?.stop()
        coordinator = nil
    }
}
