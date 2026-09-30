import CarPlay

/// Délégué du `CPMapTemplate` : panoramique, bannières de manœuvre quand une
/// autre app occupe l'écran du véhicule, et fin du guidage quand le système le
/// reprend (navigation native du véhicule, autre app de guidage).
///
/// Sans lui, CarPlay n'avait aucun moyen de nous prévenir : la voix et le GPS
/// continuaient pour un guidage que le véhicule avait déjà arrêté (CAR-03).
///
/// Retenu par le coordinateur : `CPMapTemplate.mapDelegate` est faible.
@MainActor
final class CarPlayMapTemplateDelegate: NSObject, CPMapTemplateDelegate {
    /// Flèche du mode panoramique (molette, pavé tactile).
    var onPan: (CPMapTemplate.PanDirection) -> Void = { _ in }
    /// Glissé du doigt, en déplacement depuis le relevé précédent.
    var onPanGesture: (CGPoint) -> Void = { _ in }
    var onPanningInterfaceChange: (Bool) -> Void = { _ in }
    var onNavigationCancelledBySystem: () -> Void = {}

    /// CarPlay transmet la translation CUMULÉE depuis le début du geste ; la
    /// carte, elle, se déplace par incréments.
    private var lastTranslation = CGPoint.zero

    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        onPan(direction)
    }

    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        lastTranslation = .zero
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        let delta = CGPoint(x: translation.x - lastTranslation.x, y: translation.y - lastTranslation.y)
        lastTranslation = translation
        onPanGesture(delta)
    }

    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        onPanningInterfaceChange(true)
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        onPanningInterfaceChange(false)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        onNavigationCancelledBySystem()
    }

    /// La prochaine manœuvre s'affiche en bannière même si l'écran du véhicule
    /// montre la musique : c'est tout l'intérêt d'un guidage.
    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor maneuver: CPManeuver) -> Bool {
        true
    }

    /// Et la distance y décompte, plutôt que de rester figée à sa première valeur.
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldUpdateNotificationFor maneuver: CPManeuver,
                     with travelEstimates: CPTravelEstimates) -> Bool {
        true
    }

    /// Aucune `CPNavigationAlert` n'est émise : les alertes de couverture passent
    /// par des notifications locales, déjà autorisées dans CarPlay.
    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor navigationAlert: CPNavigationAlert) -> Bool {
        false
    }
}
