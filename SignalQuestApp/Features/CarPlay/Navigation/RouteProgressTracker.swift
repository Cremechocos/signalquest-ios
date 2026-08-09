import CoreLocation

/// Itinéraire, dans une forme indépendante de MapKit.
///
/// `MKRoute` n'est pas instanciable : sans ce type intermédiaire, le suivi ne
/// serait vérifiable qu'en appelant réellement le service d'itinéraires d'Apple,
/// donc jamais en test. La conversion depuis `MKRoute` vit dans
/// `CarPlayRouteService`, qui a le droit d'être impur.
struct RoutePlan: Equatable {
    struct Step: Equatable {
        let instruction: String
        /// Longueur de l'étape.
        let distanceMeters: CLLocationDistance
        /// Point où la manœuvre se produit — la FIN de l'étape.
        let maneuverCoordinate: CLLocationCoordinate2D

        static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.instruction == rhs.instruction &&
            lhs.distanceMeters == rhs.distanceMeters &&
            lhs.maneuverCoordinate.latitude == rhs.maneuverCoordinate.latitude &&
            lhs.maneuverCoordinate.longitude == rhs.maneuverCoordinate.longitude
        }
    }

    let polyline: [CLLocationCoordinate2D]
    let steps: [Step]
    let totalDistanceMeters: CLLocationDistance
    let expectedTravelTime: TimeInterval

    static func == (lhs: RoutePlan, rhs: RoutePlan) -> Bool {
        lhs.steps == rhs.steps &&
        lhs.totalDistanceMeters == rhs.totalDistanceMeters &&
        lhs.polyline.count == rhs.polyline.count
    }
}

/// État du guidage à un instant donné.
struct RouteProgress: Equatable {
    /// Étape en cours ; `steps.count` une fois la dernière franchie.
    let stepIndex: Int
    /// Distance jusqu'à la prochaine manœuvre.
    let distanceToManeuver: CLLocationDistance
    /// Distance restante jusqu'à l'arrivée.
    let distanceRemaining: CLLocationDistance
    /// Écart perpendiculaire à l'itinéraire.
    let offRouteMeters: CLLocationDistance
    /// Sortie CONFIRMÉE — après hystérésis, pas au premier point aberrant.
    let isOffRoute: Bool
    let hasArrived: Bool
}

/// Suit la position sur l'itinéraire : étape courante, distances, sortie de
/// route, arrivée.
///
/// C'est le cœur du guidage et la pièce la plus couverte par les tests, pour une
/// raison simple : MapKit calcule l'itinéraire mais ne guide pas. Rien ici n'est
/// fourni par le système.
@MainActor
final class RouteProgressTracker {
    private let plan: RoutePlan

    /// Au-delà de cet écart, on considère que le véhicule a quitté l'itinéraire.
    /// 50 m est large à dessein : en ville, un GPS masqué par les immeubles
    /// dérive régulièrement de 20 à 30 m sans que personne n'ait tourné.
    private let offRouteThresholdMeters: CLLocationDistance

    /// Nombre de positions consécutives hors seuil avant de déclarer la sortie.
    /// Sans cette hystérésis, un seul point aberrant déclencherait un recalcul —
    /// et `MKDirections` est throttlé par Apple, donc ces recalculs se paient.
    private let confirmationsRequired: Int

    /// Distance en deçà de laquelle on considère être arrivé.
    private let arrivalRadiusMeters: CLLocationDistance

    private var consecutiveOffRoute = 0
    private(set) var stepIndex = 0

    init(plan: RoutePlan,
         offRouteThresholdMeters: CLLocationDistance = 50,
         confirmationsRequired: Int = 3,
         arrivalRadiusMeters: CLLocationDistance = 40) {
        self.plan = plan
        self.offRouteThresholdMeters = offRouteThresholdMeters
        self.confirmationsRequired = confirmationsRequired
        self.arrivalRadiusMeters = arrivalRadiusMeters
    }

    func update(with location: CLLocation) -> RouteProgress {
        let coordinate = location.coordinate
        let offRoute = Self.distanceToPolyline(coordinate, polyline: plan.polyline)

        if offRoute > offRouteThresholdMeters {
            consecutiveOffRoute += 1
        } else {
            consecutiveOffRoute = 0
        }

        advanceStepIfNeeded(from: coordinate)

        let toManeuver = stepIndex < plan.steps.count
            ? Self.distance(from: coordinate, to: plan.steps[stepIndex].maneuverCoordinate)
            : 0
        let remaining = remainingDistance(from: coordinate)
        let arrived = remaining <= arrivalRadiusMeters
            || (stepIndex >= plan.steps.count && offRoute <= offRouteThresholdMeters)

        return RouteProgress(
            stepIndex: stepIndex,
            distanceToManeuver: toManeuver,
            distanceRemaining: remaining,
            offRouteMeters: offRoute,
            isOffRoute: consecutiveOffRoute >= confirmationsRequired,
            hasArrived: arrived
        )
    }

    /// Une manœuvre est franchie quand on s'en approche à moins de 25 m.
    /// On n'avance JAMAIS de plus d'une étape à la fois : sauter deux manœuvres
    /// sur un fix imprécis ferait annoncer la mauvaise instruction.
    private func advanceStepIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard stepIndex < plan.steps.count else { return }
        let distance = Self.distance(from: coordinate, to: plan.steps[stepIndex].maneuverCoordinate)
        if distance < 25 { stepIndex += 1 }
    }

    private func remainingDistance(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        guard stepIndex < plan.steps.count else {
            guard let last = plan.polyline.last else { return 0 }
            return Self.distance(from: coordinate, to: last)
        }
        let toCurrentManeuver = Self.distance(from: coordinate, to: plan.steps[stepIndex].maneuverCoordinate)
        let laterSteps = plan.steps.dropFirst(stepIndex + 1).reduce(0) { $0 + $1.distanceMeters }
        return toCurrentManeuver + laterSteps
    }

    // MARK: - Géométrie

    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Écart au tracé : distance au SEGMENT le plus proche, pas au sommet le plus
    /// proche. La nuance compte sur une ligne droite à sommets espacés — mesurer
    /// jusqu'au sommet donnerait des centaines de mètres d'écart alors qu'on
    /// roule exactement sur la route.
    static func distanceToPolyline(_ point: CLLocationCoordinate2D,
                                   polyline: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard polyline.count > 1 else {
            guard let only = polyline.first else { return .greatestFiniteMagnitude }
            return distance(from: point, to: only)
        }
        var best = CLLocationDistance.greatestFiniteMagnitude
        for index in 0..<(polyline.count - 1) {
            let d = distanceToSegment(point, polyline[index], polyline[index + 1])
            if d < best { best = d }
        }
        return best
    }

    /// Projection sur un segment, en plan local : à l'échelle d'un segment
    /// d'itinéraire (quelques centaines de mètres), l'erreur de projection est
    /// négligeable devant la précision du GPS.
    static func distanceToSegment(_ point: CLLocationCoordinate2D,
                                  _ start: CLLocationCoordinate2D,
                                  _ end: CLLocationCoordinate2D) -> CLLocationDistance {
        // Mètres par degré, corrigés en longitude par la latitude du point.
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(point.latitude * .pi / 180)

        let px = (point.longitude - start.longitude) * metersPerDegreeLon
        let py = (point.latitude - start.latitude) * metersPerDegreeLat
        let sx = (end.longitude - start.longitude) * metersPerDegreeLon
        let sy = (end.latitude - start.latitude) * metersPerDegreeLat

        let segmentLengthSquared = sx * sx + sy * sy
        guard segmentLengthSquared > 0 else { return hypot(px, py) }

        // Paramètre de projection, borné au segment : au-delà, le point le plus
        // proche est une extrémité.
        let t = max(0, min(1, (px * sx + py * sy) / segmentLengthSquared))
        return hypot(px - t * sx, py - t * sy)
    }
}
