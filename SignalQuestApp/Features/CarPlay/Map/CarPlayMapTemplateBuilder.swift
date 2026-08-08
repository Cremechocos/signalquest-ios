import CarPlay
import UIKit

/// Construit le `CPMapTemplate` — la barre et les boutons qui se superposent à
/// notre carte.
///
/// CarPlay plafonne à 4 `CPMapButton` et 2 boutons par côté de barre. Ce n'est
/// pas une limite à contourner : au volant, chaque commande supplémentaire est
/// une seconde de regard en moins sur la route. D'où le choix de garder les
/// réglages (les couches) derrière un bouton de barre plutôt que sur la carte.
@MainActor
enum CarPlayMapTemplateBuilder {
    struct Actions {
        var recenter: () -> Void
        var zoomIn: () -> Void
        var zoomOut: () -> Void
        var showLayers: () -> Void
        var showHere: () -> Void
        var showNearby: () -> Void
        var stopGuidance: () -> Void
        var showSpeedtest: () -> Void
    }

    static func make(actions: Actions) -> CPMapTemplate {
        let template = CPMapTemplate()
        template.mapButtons = [
            mapButton(systemName: "location.fill", handler: actions.recenter),
            mapButton(systemName: "plus.magnifyingglass", handler: actions.zoomIn),
            mapButton(systemName: "minus.magnifyingglass", handler: actions.zoomOut),
            mapButton(systemName: "square.3.layers.3d", handler: actions.showLayers),
        ]
        // Deux boutons à gauche, le maximum autorisé par CarPlay. Le speedtest
        // atterrit ici parce que les quatre boutons de carte et le côté droit de
        // la barre sont déjà pris — et parce qu'il relève de la même question
        // que « Ici » : que vaut le réseau à cet endroit.
        template.leadingNavigationBarButtons = [
            CPBarButton(title: String(localized: "Ici")) { _ in actions.showHere() },
            CPBarButton(title: String(localized: "Test")) { _ in actions.showSpeedtest() },
        ]
        template.trailingNavigationBarButtons = trailingButtons(isGuiding: false, actions: actions)
        // Les boutons de panoramique n'apparaissent que sur les véhicules à
        // molette ; CarPlay les masque seul sur un écran tactile.
        template.automaticallyHidesNavigationBar = false
        return template
    }

    /// Boutons de droite, recomposés selon qu'un guidage est en cours.
    ///
    /// CarPlay plafonne à deux boutons par côté, et « Arrêter » n'a de sens que
    /// pendant un trajet : l'afficher en permanence occuperait la moitié de la
    /// barre pour une action indisponible. À l'inverse, un guidage qu'on ne peut
    /// pas interrompre depuis l'écran du véhicule est un motif de rejet en revue
    /// — et une vraie gêne : personne ne va décrocher son iPhone en roulant pour
    /// arrêter un itinéraire.
    static func trailingButtons(isGuiding: Bool, actions: Actions) -> [CPBarButton] {
        // « Autour » n'est pas un doublon de la carte : sur les véhicules pilotés
        // à la molette, viser un marqueur est impossible et cette liste est le
        // seul accès aux fiches.
        let nearby = CPBarButton(title: String(localized: "Autour")) { _ in actions.showNearby() }
        guard isGuiding else { return [nearby] }
        let stop = CPBarButton(title: String(localized: "Arrêter")) { _ in actions.stopGuidance() }
        // « Arrêter » en dernier, donc le plus à droite : c'est l'action la plus
        // recherchée pendant un trajet, et le bord est le plus facile à viser.
        return [nearby, stop]
    }

    private static func mapButton(systemName: String, handler: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in handler() }
        button.image = UIImage(systemName: systemName)
        return button
    }
}
