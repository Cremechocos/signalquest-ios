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

    /// Nombre minimal d'anneaux avant d'oser en écarter un : en dessous, il n'existe pas de
    /// majorité à laquelle comparer le suspect.
    private static let minRingsForPruning = 4
    /// Écart minimal au meilleur centre pour qu'un anneau devienne suspect.
    private static let outlierFloorMeters = 800.0
    /// …et multiple de l'écart MÉDIAN qu'il doit dépasser, pour ne pas déshabiller un nœud flou.
    private static let outlierMedianFactor = 4.0
    /// Jamais plus d'un quart des anneaux — au-delà, on fabriquerait une convergence.
    private static let maxDiscardedDivisor = 4
    /// L'élagage doit faire tomber le résidu à au plus 75 % de sa valeur, sinon on renonce.
    private static let requiredResidualRatio = 0.75

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
        fitCenter(rings)?.residualMeters
    }

    /// Meilleur centre trouvé pour un jeu d'anneaux, et l'écart moyen qui subsiste.
    private struct Fit {
        let latitude: Double
        let longitude: Double
        let residualMeters: Double
    }

    private static func fitCenter(_ rings: [Ring]) -> Fit? {
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
        return Fit(latitude: bestLat, longitude: bestLon, residualMeters: best)
    }

    /// Anneaux conservés, et ceux qu'on a écartés.
    ///
    /// Les écartés ne sont pas jetés en silence : l'écran doit pouvoir le dire, sinon le
    /// garde-fou devient une censure invisible.
    struct PrunedRings {
        let kept: [Ring]
        let discarded: [Ring]
    }

    /// Écart entre le rayon annoncé par le TA et la distance réelle au centre estimé.
    private static func deviation(from fit: Fit, ring: Ring) -> Double {
        let dLat = (ring.latitude - fit.latitude) * metersPerDegreeLat
        let dLon = (ring.longitude - fit.longitude) * metersPerDegreeLat
            * cos(((ring.latitude + fit.latitude) / 2) * .pi / 180)
        return abs((dLat * dLat + dLon * dLon).squareRoot() - ring.radiusMeters)
    }

    /// Écarte les anneaux qui contredisent franchement tous les autres.
    ///
    /// POURQUOI. Un TA peut être juste et pourtant appartenir à une AUTRE cellule : mesuré sur
    /// un journal réel de 2 155 lignes, 6 % des anneaux étaient géométriquement incompatibles
    /// avec leurs voisins, et **un seul suffisait à déplacer le site estimé de 2,8 km** (jusqu'à
    /// 9,5 km sur le pire nœud). Signature du défaut : un TA identique porté au même mètre près
    /// par deux nœuds différents — les mesures d'une cellule collées à l'identité d'une autre.
    ///
    /// Le plafond du quart est le garde-fou du garde-fou : jeter des mesures jusqu'à ce que le
    /// reste s'accorde ne révèle rien, cela FABRIQUE une convergence.
    static func pruneOutliers(_ rings: [Ring]) -> PrunedRings {
        guard rings.count >= minRingsForPruning, let before = fitCenter(rings) else {
            return PrunedRings(kept: rings, discarded: [])
        }

        let deviations = rings.map { (ring: $0, value: deviation(from: before, ring: $0)) }
        let sorted = deviations.map(\.value).sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(outlierFloorMeters, outlierMedianFactor * median)

        let discarded = deviations
            .filter { $0.value > threshold }
            .sorted { $0.value > $1.value }
            .prefix(max(1, rings.count / maxDiscardedDivisor))
            .map(\.ring)
        guard !discarded.isEmpty else { return PrunedRings(kept: rings, discarded: []) }

        let discardedIds = Set(discarded.map(\.id))
        let kept = rings.filter { !discardedIds.contains($0.id) }
        // Sous trois anneaux il n'y a plus de verdict possible : mieux vaut tout garder et
        // annoncer une divergence que rendre le nœud muet.
        guard kept.count >= 3, let after = fitCenter(kept) else {
            return PrunedRings(kept: rings, discarded: [])
        }
        guard after.residualMeters <= before.residualMeters * requiredResidualRatio else {
            return PrunedRings(kept: rings, discarded: [])
        }
        return PrunedRings(kept: kept, discarded: discarded)
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
