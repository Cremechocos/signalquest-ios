import Foundation

/// Classe les sites candidats par compatibilité avec les anneaux TA d'un nœud.
///
/// PORT FIDÈLE de `TaPlausibility` (Android) et de `ta-plausibility.ts` (site). Les trois
/// doivent retenir les MÊMES sites : si iOS propose un candidat que l'application Android
/// masque, l'utilisateur qui passe de l'une à l'autre ne sait plus laquelle croire.
///
/// POURQUOI UN CLASSEMENT ET NON UN SEUIL. Le réflexe serait d'exiger qu'un site tombe dans
/// TOUTES les couronnes TA — c'est la définition mathématique de l'intersection. Mesuré sur le
/// journal réel : même en cherchant le meilleur centre possible et avec une marge de 1,5 × la
/// tolérance, **3 nœuds sur 27 seulement** satisfont toutes leurs couronnes. Un tel filtre
/// viderait la carte sur 24 nœuds — y compris de la bonne antenne.
///
/// D'où le parti pris : **on ne juge pas un site dans l'absolu, on le compare aux autres**. On
/// garde ceux qui satisfont le plus de couronnes. La carte n'est donc jamais vide, et le
/// classement reste informatif même quand les relevés se contredisent.
enum TaPlausibility {

    /// Un site retenu, avec de quoi expliquer POURQUOI il l'a été.
    ///
    /// `matchedRings` sur `totalRings` est ce qu'on peut montrer à l'utilisateur : « ce site
    /// est compatible avec 8 de vos 11 passages ». C'est vérifiable, contrairement à un score.
    struct Scored<T> {
        let item: T
        let matchedRings: Int
        let totalRings: Int
    }

    /// Élargissement des couronnes avant le test d'appartenance.
    ///
    /// La tolérance d'un anneau vaut déjà « demi-pas TA + précision GPS ». On l'élargit encore
    /// parce que le coût des deux erreurs n'est pas symétrique : garder un site de trop coûte
    /// un marqueur à l'écran, en écarter un de trop rend l'identification impossible.
    static let safetyFactor = 1.5

    /// Écart de rang toléré sous le meilleur candidat. À 0, un site compatible avec 7 couronnes
    /// disparaîtrait dès qu'un autre en atteint 8 — beaucoup trop tranchant vu le bruit.
    static let rankTolerance = 1

    /// Sous ce nombre d'anneaux, le classement n'ordonne rien de fiable : avec deux couronnes,
    /// la moitié d'un secteur les satisfait toutes les deux.
    static let minRings = 3

    private static let metersPerDegreeLat = 111_320.0

    private static func distanceMeters(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double
    ) -> Double {
        let dLat = (lat1 - lat2) * metersPerDegreeLat
        let dLon = (lon1 - lon2) * metersPerDegreeLat * cos(((lat1 + lat2) / 2) * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Nombre de couronnes contenant ce point, marge de sécurité comprise.
    ///
    /// C'est le seul « score » du système, et il est entièrement explicable : un entier, égal à
    /// un nombre de passages compatibles.
    static func matchedRings(
        latitude: Double, longitude: Double, rings: [TaRingSelection.Ring]
    ) -> Int {
        rings.filter { ring in
            let delta = abs(
                distanceMeters(latitude, longitude, ring.latitude, ring.longitude)
                    - ring.radiusMeters
            )
            return delta <= ring.toleranceMeters * safetyFactor
        }.count
    }

    /// Retient les sites les plus compatibles avec les anneaux.
    ///
    /// Renvoie `nil` — c'est-à-dire « je m'abstiens », et non « aucun site » — dans deux cas où
    /// filtrer serait malhonnête : quand il n'y a pas assez d'anneaux pour trancher, et quand
    /// AUCUN site n'est compatible avec quoi que ce soit. Là, la géométrie n'a rien à dire, et
    /// masquer des sites ferait passer une absence d'information pour un tri.
    static func filterPlausible<T>(
        _ items: [T],
        rings: [TaRingSelection.Ring],
        position: (T) -> (latitude: Double, longitude: Double)?
    ) -> [Scored<T>]? {
        guard rings.count >= minRings, !items.isEmpty else { return nil }

        let scored: [Scored<T>] = items.compactMap { item in
            guard let at = position(item) else { return nil }
            return Scored(
                item: item,
                matchedRings: matchedRings(
                    latitude: at.latitude, longitude: at.longitude, rings: rings
                ),
                totalRings: rings.count
            )
        }

        let maxScore = scored.map(\.matchedRings).max() ?? 0
        guard maxScore > 0 else { return nil }

        let floor = max(1, maxScore - rankTolerance)
        return scored
            .filter { $0.matchedRings >= floor }
            .sorted { $0.matchedRings > $1.matchedRings }
    }
}
