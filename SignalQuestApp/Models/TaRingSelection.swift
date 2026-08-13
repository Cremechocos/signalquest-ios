import CoreLocation
import Foundation

/// Anneaux de Timing Advance — « depuis ce point, le site est à peu près à cette distance ».
///
/// PORT FIDÈLE de `TaRingSelection` (Android) et de `ta-rings.ts` (site). Les trois moitiés
/// doivent dire la même chose : si iOS trace des cercles que l'application Android ne trace
/// pas, ou juge convergent ce qu'elle juge divergent, l'utilisateur qui passe de l'une à
/// l'autre ne sait plus laquelle croire. Les valeurs numériques sont reprises telles quelles ;
/// tout écart ici est un bug, pas une adaptation.
///
/// L'intersection de plusieurs anneaux désigne le site — c'est de la trilatération, mais
/// tracée à l'écran, l'utilisateur tranchant lui-même.
enum TaRingSelection {

    /// Un relevé géolocalisé, tel que la route des points d'un site le rend.
    struct Reading {
        let latitude: Double
        let longitude: Double
        let timingAdvance: Int?
        let accuracyMeters: Double?
        let observedAt: Date?

        init(
            latitude: Double,
            longitude: Double,
            timingAdvance: Int?,
            accuracyMeters: Double? = nil,
            observedAt: Date? = nil
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.timingAdvance = timingAdvance
            self.accuracyMeters = accuracyMeters
            self.observedAt = observedAt
        }
    }

    struct Ring: Identifiable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
        /// Rayon en MÈTRES (TA × 78,12), jamais l'unité TA brute.
        let radiusMeters: Double
        let timingAdvance: Int
        /// Demi-largeur de la COURONNE d'incertitude : résolution du TA (±39 m) plus la
        /// précision GPS du point d'observation. Le site est dans la bande, pas sur la ligne.
        let toleranceMeters: Double
        let timestamp: TimeInterval

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Ce que la géométrie permet réellement de dire.
    enum Assessment {
        /// Trop peu d'anneaux, ou tous pris au même endroit : l'intersection reste une zone.
        case unusable
        /// Assez dispersés mais INCOMPATIBLES : aucun point du plan ne satisfait ces
        /// distances. On les affiche quand même — voir des anneaux diverger apprend quelque
        /// chose (handover, TA périmé, deux sites sous un même identifiant) — mais sans
        /// laisser croire que leur intersection désigne un lieu.
        case divergent
        /// Les anneaux se croisent : leur intersection désigne bien une zone restreinte.
        case convergent
    }

    /// Pas du TA en LTE. Le TA du journal vient toujours de l'ancre LTE : l'API radio
    /// n'expose aucun Timing Advance en NR.
    static let lteStepMeters = 78.12
    private static let lteTaMax = 1282

    /// Au-delà, le tracé coûte plus qu'il n'apprend.
    static let maxRings = 24

    /// Demi-pas du TA : la vraie distance est dans ±39 m du rayon nominal.
    private static let taHalfStepMeters = 39.0

    /// Précision GPS supposée quand elle n'est pas enregistrée. Mesurée sur un journal de
    /// terrain : renseignée sur une minorité de relevés, et valant alors 329 m en moyenne.
    /// Supposer « parfait » dessinerait une bande fine et mensongère.
    private static let assumedAccuracyMeters = 250.0

    /// Deux relevés plus proches que ça apportent la même information géométrique.
    private static let minSeparationMeters = 40.0

    private static let metersPerDegreeLat = 111_320.0

    private static let gridPasses = 7
    private static let gridSteps = 8

    /// Un résidu jusqu'à 1,5 × la largeur des couronnes reste explicable par l'incertitude.
    private static let residualToleranceFactor = 1.5

    /// Distance correspondant à un TA, au pas LTE. `nil` hors plage.
    static func distanceMeters(forTimingAdvance ta: Int) -> Double? {
        guard ta >= 0, ta <= lteTaMax else { return nil }
        return Double(ta) * lteStepMeters
    }

    private static func tolerance(forAccuracy accuracy: Double?) -> Double {
        let value = (accuracy?.isFinite == true && (accuracy ?? 0) > 0)
            ? (accuracy ?? assumedAccuracyMeters).rounded()
            : assumedAccuracyMeters
        return taHalfStepMeters + value
    }

    /// Distance approchée, en projection plate locale. Suffisant : on compare des écarts de
    /// quelques dizaines de mètres à quelques kilomètres, jamais des distances
    /// intercontinentales.
    private static func approxDistanceMeters(_ a: Ring, _ b: Ring) -> Double {
        let dLat = (a.latitude - b.latitude) * metersPerDegreeLat
        let meanLatRad = ((a.latitude + b.latitude) / 2) * .pi / 180
        let dLon = (a.longitude - b.longitude) * metersPerDegreeLat * cos(meanLatRad)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Anneaux à tracer pour un nœud, les plus utiles d'abord.
    ///
    /// Un relevé n'est retenu que s'il porte une position ET un TA exploitable : un TA nul
    /// veut dire « collé à l'antenne » ou remplissage, et ne donne aucun cercle.
    static func rings(for readings: [Reading], maxRings: Int = maxRings) -> [Ring] {
        var candidates: [Ring] = []
        for reading in readings {
            guard reading.latitude.isFinite, reading.longitude.isFinite else { continue }
            guard let ta = reading.timingAdvance, ta > 0 else { continue }
            guard let radius = distanceMeters(forTimingAdvance: ta), radius > 0 else { continue }
            candidates.append(
                Ring(
                    latitude: reading.latitude,
                    longitude: reading.longitude,
                    radiusMeters: radius.rounded(),
                    timingAdvance: ta,
                    toleranceMeters: tolerance(forAccuracy: reading.accuracyMeters),
                    timestamp: reading.observedAt?.timeIntervalSince1970 ?? 0
                )
            )
        }
        if candidates.count <= maxRings { return dedupeByPosition(candidates, maxRings: maxRings) }
        return spreadOut(candidates, maxRings: maxRings)
    }

    /// Retire les relevés trop proches, en gardant le plus récent de chaque emplacement —
    /// même sous le plafond : dix cercles superposés encombrent la carte sans rien ajouter.
    private static func dedupeByPosition(_ candidates: [Ring], maxRings: Int) -> [Ring] {
        var kept: [Ring] = []
        for ring in candidates.sorted(by: { $0.timestamp > $1.timestamp }) {
            if kept.count >= maxRings { break }
            if kept.allSatisfy({ approxDistanceMeters($0, ring) >= minSeparationMeters }) {
                kept.append(ring)
            }
        }
        return kept
    }

    /// Sélection « la plus dispersée possible », par ajout glouton du point le plus éloigné
    /// de ceux déjà retenus. Prendre les N plus récents ramènerait les N relevés d'un même
    /// arrêt : beaucoup de cercles, aucune intersection utile.
    private static func spreadOut(_ candidates: [Ring], maxRings: Int) -> [Ring] {
        var remaining = candidates
        // Amorce : le plus récent, pour que l'anneau du relevé courant soit toujours présent.
        var seedIndex = 0
        for (index, ring) in remaining.enumerated() where ring.timestamp > remaining[seedIndex].timestamp {
            seedIndex = index
        }
        var kept: [Ring] = [remaining.remove(at: seedIndex)]

        while kept.count < maxRings, !remaining.isEmpty {
            var bestIndex = -1
            var bestDistance = -1.0
            for (index, candidate) in remaining.enumerated() {
                let nearest = kept.map { approxDistanceMeters($0, candidate) }.min() ?? 0
                if nearest > bestDistance {
                    bestDistance = nearest
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            // Sous le seuil de séparation, plus rien n'apporte d'information nouvelle.
            if bestDistance < minSeparationMeters { break }
            kept.append(remaining.remove(at: bestIndex))
        }
        return kept
    }

    /// Écartement maximal entre les anneaux retenus. Sous quelques centaines de mètres, les
    /// cercles restent quasi concentriques et ne désignent pas un point.
    static func spreadMeters(_ rings: [Ring]) -> Double {
        guard rings.count >= 2 else { return 0 }
        var max = 0.0
        for i in rings.indices {
            for j in (i + 1)..<rings.count {
                let d = approxDistanceMeters(rings[i], rings[j])
                if d > max { max = d }
            }
        }
        return max
    }

    private static func residual(atLatitude lat: Double, longitude lon: Double, rings: [Ring]) -> Double {
        var sum = 0.0
        for ring in rings {
            let dLat = (ring.latitude - lat) * metersPerDegreeLat
            let dLon = (ring.longitude - lon) * metersPerDegreeLat
                * cos(((ring.latitude + lat) / 2) * .pi / 180)
            sum += abs((dLat * dLat + dLon * dLon).squareRoot() - ring.radiusMeters)
        }
        return sum / Double(rings.count)
    }

    /// Écart moyen entre les rayons TA et les distances au meilleur centre possible : « s'il
    /// existait un site, à quel point les anneaux se tromperaient-ils ? ». Recherche par
    /// grille descendante depuis le barycentre — un ordre de grandeur suffit, pas une position.
    static func fitResidualMeters(_ rings: [Ring]) -> Double? {
        guard rings.count >= 3 else { return nil }
        var bestLat = rings.map(\.latitude).reduce(0, +) / Double(rings.count)
        var bestLon = rings.map(\.longitude).reduce(0, +) / Double(rings.count)
        var best = residual(atLatitude: bestLat, longitude: bestLon, rings: rings)
        var span = 0.25

        for _ in 0..<gridPasses {
            let step = span / Double(gridSteps)
            var improvedLat = bestLat
            var improvedLon = bestLon
            for i in -gridSteps...gridSteps {
                for j in -gridSteps...gridSteps {
                    let lat = bestLat + Double(i) * step
                    let lon = bestLon + Double(j) * step
                    let r = residual(atLatitude: lat, longitude: lon, rings: rings)
                    if r < best {
                        best = r
                        improvedLat = lat
                        improvedLon = lon
                    }
                }
            }
            bestLat = improvedLat
            bestLon = improvedLon
            span /= 4
        }
        return best
    }

    /// Verdict en trois états plutôt qu'un booléen : dans un cas il n'y a rien à montrer,
    /// dans l'autre il y a quelque chose à montrer ET un avertissement à donner. Un booléen
    /// forçait à choisir entre mentir et cacher.
    ///
    /// Mesuré sur 27 nœuds réels, 11 avaient des anneaux géométriquement incompatibles alors
    /// qu'ils passaient tous le seul test de dispersion — d'où le critère de résidu.
    static func assess(_ rings: [Ring]) -> Assessment {
        guard rings.count >= 3 else { return .unusable }
        guard spreadMeters(rings) >= 250 else { return .unusable }
        guard let residual = fitResidualMeters(rings) else { return .unusable }
        let tolerance = rings.map(\.toleranceMeters).reduce(0, +)
            / Double(rings.count) * residualToleranceFactor
        return residual <= tolerance ? .convergent : .divergent
    }
}
