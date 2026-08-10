import CoreLocation
import MapKit

/// Réception d'une demande d'itinéraire venant de l'app Plan.
///
/// L'`Info.plist` déclare `MKDirectionsRequest` et
/// `MKDirectionsApplicationSupportedModes` : SignalQuest apparaît donc dans la
/// liste des apps d'itinéraire de Plan. Déclarer sans traiter serait pire que ne
/// rien déclarer — l'utilisateur choisit SignalQuest, l'app s'ouvre et ne fait
/// rien, ce qui est un motif de rejet en revue.
///
/// Le traitement est volontairement séparé de l'`AppDelegate` : c'est une règle
/// de routage, pas du cycle de vie, et il faut pouvoir la vérifier sans lancer
/// l'app.
enum DirectionsRequestHandler {
    struct Destination: Equatable {
        let coordinate: CLLocationCoordinate2D
        let name: String

        static func == (lhs: Destination, rhs: Destination) -> Bool {
            lhs.name == rhs.name &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Extrait la destination d'une URL Plan, ou `nil` si l'URL n'en est pas une.
    ///
    /// Cette moitié-ci n'est pas testable : le format d'URL que Plan produit
    /// n'est pas documenté et `isDirectionsRequest(_:)` rejette tout ce qu'on
    /// fabriquerait à la main. La décision qui suit, elle, l'est — d'où la
    /// séparation.
    static func destination(from url: URL) -> Destination? {
        // Swift importe `MKDirectionsRequest` sous `MKDirections.Request`.
        guard MKDirections.Request.isDirectionsRequest(url) else { return nil }
        guard let item = MKDirections.Request(contentsOf: url).destination else { return nil }
        return destination(coordinate: item.placemark.coordinate,
                           name: item.name,
                           placemarkTitle: item.placemark.title)
    }

    /// Valide et nomme la destination reçue.
    ///
    /// Le nom est facultatif côté Plan : sans repli, la destination s'afficherait
    /// sans étiquette dans les récents et dans la prévisualisation CarPlay.
    static func destination(coordinate: CLLocationCoordinate2D,
                            name: String?,
                            placemarkTitle: String?) -> Destination? {
        // (0, 0) est le golfe de Guinée, pas une destination : c'est ce que rend
        // une requête vide, et l'accepter enverrait le conducteur au large.
        guard CLLocationCoordinate2DIsValid(coordinate),
              !(coordinate.latitude == 0 && coordinate.longitude == 0) else { return nil }
        let label = [name, placemarkTitle]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? String(localized: "Destination")
        return Destination(coordinate: coordinate, name: label)
    }
}
