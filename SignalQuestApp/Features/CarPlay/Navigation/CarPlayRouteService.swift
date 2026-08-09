import CoreLocation
import MapKit

/// Calcule les itinéraires et régule les recalculs.
///
/// ⚠️ `MKDirections` est **throttlé par Apple** : au-delà d'un certain rythme,
/// les requêtes échouent en `MKError.loadingThrottled` et le guidage s'arrête
/// net. Recalculer à chaque sortie de route détectée est donc intenable — d'où
/// le budget ci-dessous, qui n'est pas une optimisation mais une condition de
/// fonctionnement.
@MainActor
final class CarPlayRouteService {
    /// Intervalle minimal entre deux recalculs.
    static let minimumRecalculationInterval: TimeInterval = 15

    enum RouteError: Error, Equatable {
        /// Le budget d'appels est épuisé : garder l'itinéraire courant et
        /// signaler « hors itinéraire » plutôt qu'échouer.
        case throttled
        case noRoute
    }

    /// Injecté pour rester testable : le tracker et le budget ne doivent pas
    /// dépendre de l'heure réelle.
    private let now: () -> Date
    private var lastRequestAt: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Le recalcul est-il autorisé maintenant ?
    ///
    /// Séparé du calcul lui-même pour être vérifiable sans réseau — c'est la
    /// règle qui protège du throttle, elle mérite ses propres tests.
    func canRecalculate() -> Bool {
        guard let lastRequestAt else { return true }
        return now().timeIntervalSince(lastRequestAt) >= Self.minimumRecalculationInterval
    }

    /// Enregistre qu'une requête vient d'être émise. Appelé par `route(...)`, et
    /// utilisable seul pour vérifier la règle de budget sans toucher au réseau.
    func noteRequest() {
        lastRequestAt = now()
    }

    func route(from origin: CLLocationCoordinate2D,
               to destination: CLLocationCoordinate2D,
               isRecalculation: Bool = false) async throws -> RoutePlan {
        if isRecalculation, !canRecalculate() { throw RouteError.throttled }
        noteRequest()

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        // Une seule route : les alternatives ne servent qu'à la prévisualisation,
        // et chaque variante coûte du temps de calcul avant l'affichage.
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteError.noRoute }
        return Self.plan(from: route)
    }

    /// Conversion `MKRoute` → `RoutePlan`. C'est ici que vit l'impureté, pour que
    /// le suivi (`RouteProgressTracker`) reste testable sans MapKit.
    static func plan(from route: MKRoute) -> RoutePlan {
        RoutePlan(
            polyline: coordinates(of: route.polyline),
            steps: route.steps.compactMap { step in
                // MapKit émet une première étape vide (« Prenez la route ») dont
                // la polyline est réduite à un point : elle n'a pas de manœuvre
                // et ferait annoncer une instruction sans contenu.
                guard !step.instructions.isEmpty,
                      let maneuver = coordinates(of: step.polyline).last else { return nil }
                return RoutePlan.Step(
                    instruction: step.instructions,
                    distanceMeters: step.distance,
                    maneuverCoordinate: maneuver
                )
            },
            totalDistanceMeters: route.distance,
            expectedTravelTime: route.expectedTravelTime
        )
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }
}
