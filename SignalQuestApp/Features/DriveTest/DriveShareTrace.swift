import CoreGraphics
import CoreLocation
import Foundation

/// Tracé d'un Drive Test pour sa carte de partage (plan 3, vague 1).
///
/// Gardé en mémoire seulement, pour la session qui vient de finir : une
/// trace de position n'a pas à dormir sur le disque. La carte le dessine sans
/// fond de carte, et peut en retirer le départ et l'arrivée, qui disent
/// souvent où l'on habite ou travaille.
struct DriveShareTrace: Equatable {
    struct Measure: Equatable {
        let coordinate: CLLocationCoordinate2D
        let downloadMbps: Double
        /// Débit rapporté au maximum atteignable sur ce réseau, comme la carte
        /// d'un speedtest : 300 Mb/s est excellent en 4G et médiocre en 5G.
        let qualityRatio: Double

        static func == (lhs: Measure, rhs: Measure) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.downloadMbps == rhs.downloadMbps
                && lhs.qualityRatio == rhs.qualityRatio
        }
    }

    let route: [CLLocationCoordinate2D]
    let measures: [Measure]

    /// Distance retirée à chaque bout quand on masque départ et arrivée.
    static let privacyTrimMeters: CLLocationDistance = 500
    /// Au-delà, les points sont espacés régulièrement : la carte n'en a pas
    /// besoin de plus pour dessiner la forme du trajet.
    static let maxRoutePoints = 400

    static func == (lhs: DriveShareTrace, rhs: DriveShareTrace) -> Bool {
        lhs.measures == rhs.measures
            && lhs.route.count == rhs.route.count
            && zip(lhs.route, rhs.route).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// Le trajet privé de ses `meters` premiers et derniers mètres, et les
    /// mesures faites dans ces bouts. Un trajet trop court pour cela n'a plus
    /// rien à montrer.
    func trimmingEnds(by meters: CLLocationDistance = privacyTrimMeters) -> DriveShareTrace {
        guard meters > 0, route.count >= 2 else { return self }
        var cumulative: [CLLocationDistance] = [0]
        for index in 1..<route.count {
            cumulative.append(cumulative[index - 1] + Self.distance(route[index - 1], route[index]))
        }
        let total = cumulative.last ?? 0
        guard total > meters * 2 else { return DriveShareTrace(route: [], measures: []) }
        let kept = Set(route.indices.filter { cumulative[$0] >= meters && cumulative[$0] <= total - meters })
        // Une mesure suit le point du trajet le plus proche : retirée avec lui,
        // elle ne trahit pas le départ qu'on vient de masquer.
        let visible = measures.filter { measure in
            let nearest = route.indices.min {
                Self.distance(route[$0], measure.coordinate) < Self.distance(route[$1], measure.coordinate)
            }
            return nearest.map(kept.contains) ?? false
        }
        return DriveShareTrace(route: kept.sorted().map { route[$0] }, measures: visible)
    }

    /// Au plus `maxRoutePoints`, en gardant le premier et le dernier.
    func thinned(to limit: Int = maxRoutePoints) -> DriveShareTrace {
        guard route.count > limit, limit >= 2 else { return self }
        let step = Double(route.count - 1) / Double(limit - 1)
        let sampled = (0..<limit).map { route[Int((Double($0) * step).rounded())] }
        return DriveShareTrace(route: sampled, measures: measures)
    }

    /// Positions dans un carré 0…1, proportions gardées (une latitude ne
    /// vaut pas une longitude : on corrige par le cosinus de la latitude).
    func normalized() -> (route: [CGPoint], measures: [(point: CGPoint, qualityRatio: Double)]) {
        let all = route + measures.map(\.coordinate)
        guard let first = all.first else { return ([], []) }
        let cosLat = cos(first.latitude * .pi / 180)
        let xs = all.map { $0.longitude * cosLat }, ys = all.map { $0.latitude }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return ([], []) }
        let span = max(maxX - minX, maxY - minY, 1e-9)
        let offsetX = (span - (maxX - minX)) / 2, offsetY = (span - (maxY - minY)) / 2
        func project(_ c: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: (c.longitude * cosLat - minX + offsetX) / span,
                    // Nord en haut : la latitude croît vers le haut.
                    y: 1 - (c.latitude - minY + offsetY) / span)
        }
        return (route.map(project), measures.map { (project($0.coordinate), $0.qualityRatio) })
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
