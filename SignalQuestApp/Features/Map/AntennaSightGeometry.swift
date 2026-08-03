import CoreLocation
import Foundation

/// Ce qui se calcule entre l'utilisateur et une antenne : distance, relèvement,
/// secteur qui le couvre, angle d'élévation — puis, une fois le relief connu, si
/// quelque chose se dresse sur la ligne de visée.
///
/// La trigonométrie sphérique (relèvement, secteur, destination) vit déjà dans
/// `AntennaSectorGeometry` : ce fichier ne la réécrit pas, il l'utilise et ajoute
/// ce que la visée demande en plus.
enum AntennaSightGeometry {
    /// Hauteur des yeux au-dessus du sol. Un observateur debout — c'est ce qui
    /// change un « dégagé » en « bloqué » quand l'obstacle est à hauteur d'homme.
    static let observerHeightMeters = 1.5

    /// Fraction de la première zone de Fresnel qui doit rester libre pour qu'une
    /// liaison se comporte comme en visibilité directe (règle des 60 %, ITU-R P.526).
    static let fresnelClearanceRatio = 0.6

    // MARK: Angles

    /// Angle d'élévation, en degrés, du sommet de l'antenne vu depuis l'observateur.
    /// Positif = il faut lever les yeux. `deltaHeight` inclut la différence
    /// d'altitude du sol si elle est connue.
    static func elevationAngle(distanceMeters: Double, deltaHeightMeters: Double) -> Double? {
        guard distanceMeters > 0, distanceMeters.isFinite, deltaHeightMeters.isFinite else { return nil }
        return atan2(deltaHeightMeters, distanceMeters) * 180 / .pi
    }

    /// Point cardinal en 8 secteurs, pour dire « nord-est » plutôt que « 38° » —
    /// un cap parlant se lit sans conversion mentale.
    static func cardinal(for bearing: Double) -> String {
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 45).rounded()) % 8
        let names = [
            String(localized: "nord"), String(localized: "nord-est"),
            String(localized: "est"), String(localized: "sud-est"),
            String(localized: "sud"), String(localized: "sud-ouest"),
            String(localized: "ouest"), String(localized: "nord-ouest")
        ]
        return names[index]
    }

    // MARK: Échantillonnage du trajet

    /// Points régulièrement espacés de l'utilisateur vers l'antenne, extrémités
    /// comprises. Le pas suit la règle du panneau web (un point tous les ~50 m,
    /// borné à 10–50) : assez fin pour attraper une crête, assez court pour tenir
    /// dans un seul appel réseau.
    static func samplePath(
        from user: CLLocationCoordinate2D,
        to antenna: CLLocationCoordinate2D,
        distanceMeters: Double
    ) -> [CLLocationCoordinate2D] {
        let count = min(50, max(10, Int((distanceMeters / 50).rounded())))
        guard count > 1 else { return [user, antenna] }
        let bearing = AntennaSectorGeometry.bearing(from: user, to: antenna)
        return (0..<count).map { index in
            let ratio = Double(index) / Double(count - 1)
            if ratio == 0 { return user }
            if ratio == 1 { return antenna }
            return AntennaSectorGeometry.destination(
                from: user,
                bearingDegrees: bearing,
                distanceMeters: distanceMeters * ratio
            )
        }
    }

    /// Rayon de la première zone de Fresnel, en mètres, au point situé à `d1` de
    /// l'émetteur et `d2` du récepteur : √(λ·d1·d2 / (d1+d2)).
    static func fresnelRadius(d1: Double, d2: Double, frequencyMhz: Double) -> Double {
        guard frequencyMhz > 0, d1 > 0, d2 > 0 else { return 0 }
        let wavelength = 299.792458 / frequencyMhz // c en m/µs ÷ MHz = mètres
        return (wavelength * d1 * d2 / (d1 + d2)).squareRoot()
    }

    // MARK: Profil

    /// Un point du profil : sa distance depuis l'utilisateur, l'altitude du sol,
    /// la hauteur du bâti éventuel, et l'altitude de la ligne de visée à cet endroit.
    struct ProfilePoint: Equatable {
        let distanceMeters: Double
        let groundMeters: Double
        /// Hauteur du bâti au-dessus du sol (0 si aucun/inconnu).
        let clutterMeters: Double
        /// Altitude de la droite observateur → sommet de l'antenne.
        let sightLineMeters: Double
        /// Rayon de la première zone de Fresnel à cet endroit.
        let fresnelRadiusMeters: Double

        /// Sommet de l'obstacle réel à cet endroit (sol + bâti).
        var obstacleMeters: Double { groundMeters + clutterMeters }
        /// Marge sous la ligne de visée. Négative = l'obstacle la coupe.
        var clearanceMeters: Double { sightLineMeters - obstacleMeters }
    }

    /// Verdict d'une visée : ce qu'on affiche en une ligne dans la fiche.
    struct SightVerdict: Equatable {
        enum Level: Equatable {
            /// Rien ne coupe la ligne de visée, et la zone de Fresnel est dégagée.
            case clear
            /// La ligne passe, mais un obstacle mord la zone de Fresnel : le signal
            /// est atténué sans être coupé.
            case grazing
            /// Un obstacle dépasse la ligne de visée.
            case blocked
        }

        let level: Level
        /// Distance de l'obstacle le plus gênant, s'il y en a un.
        let obstacleDistanceMeters: Double?
        /// De combien l'obstacle dépasse la ligne de visée (mètres, positif).
        let obstacleOvershootMeters: Double?
        /// Le verdict tient-il compte du bâti, ou seulement du relief ?
        let includesBuildings: Bool
    }

    /// Assemble le profil à partir du relief échantillonné.
    ///
    /// `groundElevations` et `clutterHeights` suivent l'ordre de `samplePath`
    /// (utilisateur en premier). Un trou dans le relief (`nil`) est interpolé sur
    /// ses voisins : une source d'élévation renvoie parfois `null` en mer ou hors
    /// couverture, et un trou traité comme une altitude nulle inventerait une
    /// falaise.
    static func buildProfile(
        distanceMeters: Double,
        groundElevations: [Double?],
        clutterHeights: [Double?],
        antennaHeightMeters: Double,
        frequencyMhz: Double
    ) -> [ProfilePoint] {
        let ground = interpolatedGaps(groundElevations)
        guard ground.count >= 2, let userGround = ground.first, let antennaGround = ground.last else { return [] }
        let observerTop = userGround + observerHeightMeters
        let antennaTop = antennaGround + antennaHeightMeters
        let step = distanceMeters / Double(ground.count - 1)

        return ground.enumerated().map { index, groundMeters in
            let d1 = step * Double(index)
            let d2 = max(0, distanceMeters - d1)
            let ratio = distanceMeters > 0 ? d1 / distanceMeters : 0
            return ProfilePoint(
                distanceMeters: d1,
                groundMeters: groundMeters,
                clutterMeters: max(0, clutterHeights.indices.contains(index) ? (clutterHeights[index] ?? 0) : 0),
                sightLineMeters: observerTop + (antennaTop - observerTop) * ratio,
                fresnelRadiusMeters: fresnelRadius(d1: d1, d2: d2, frequencyMhz: frequencyMhz)
            )
        }
    }

    /// Cherche l'obstacle le plus pénalisant du profil. Les extrémités sont
    /// ignorées : le sol sous les pieds de l'observateur et le pied du pylône
    /// touchent toujours la ligne de visée sans rien masquer.
    static func verdict(for profile: [ProfilePoint], includesBuildings: Bool) -> SightVerdict? {
        guard profile.count > 2 else { return nil }
        let interior = profile.dropFirst().dropLast()

        var worstBlocking: ProfilePoint?
        var worstGrazing: ProfilePoint?
        for point in interior {
            if point.clearanceMeters < 0 {
                if worstBlocking == nil || point.clearanceMeters < worstBlocking!.clearanceMeters {
                    worstBlocking = point
                }
            } else if point.clearanceMeters < point.fresnelRadiusMeters * fresnelClearanceRatio {
                let margin = point.fresnelRadiusMeters * fresnelClearanceRatio - point.clearanceMeters
                let currentMargin = worstGrazing.map { $0.fresnelRadiusMeters * fresnelClearanceRatio - $0.clearanceMeters } ?? 0
                if worstGrazing == nil || margin > currentMargin { worstGrazing = point }
            }
        }

        if let blocking = worstBlocking {
            return SightVerdict(
                level: .blocked,
                obstacleDistanceMeters: blocking.distanceMeters,
                obstacleOvershootMeters: -blocking.clearanceMeters,
                includesBuildings: includesBuildings
            )
        }
        if let grazing = worstGrazing {
            return SightVerdict(
                level: .grazing,
                obstacleDistanceMeters: grazing.distanceMeters,
                obstacleOvershootMeters: nil,
                includesBuildings: includesBuildings
            )
        }
        return SightVerdict(
            level: .clear,
            obstacleDistanceMeters: nil,
            obstacleOvershootMeters: nil,
            includesBuildings: includesBuildings
        )
    }

    /// Remplace les trous par une interpolation linéaire entre les valeurs
    /// connues qui les encadrent ; les trous de bordure reprennent la valeur
    /// connue la plus proche. Renvoie un tableau vide si tout est inconnu.
    static func interpolatedGaps(_ values: [Double?]) -> [Double] {
        let knownIndices = values.indices.filter { values[$0] != nil }
        guard let first = knownIndices.first, let last = knownIndices.last else { return [] }
        var result = [Double](repeating: 0, count: values.count)
        var previousKnown = first
        for index in values.indices {
            if let value = values[index] {
                result[index] = value
                previousKnown = index
                continue
            }
            if index < first { result[index] = values[first] ?? 0; continue }
            if index > last { result[index] = values[last] ?? 0; continue }
            guard let nextKnown = knownIndices.first(where: { $0 > index }),
                  let before = values[previousKnown], let after = values[nextKnown] else {
                result[index] = values[previousKnown] ?? 0
                continue
            }
            let span = Double(nextKnown - previousKnown)
            let ratio = span > 0 ? Double(index - previousKnown) / span : 0
            result[index] = before + (after - before) * ratio
        }
        return result
    }
}
