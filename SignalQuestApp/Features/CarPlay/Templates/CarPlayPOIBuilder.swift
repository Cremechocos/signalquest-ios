import CarPlay
import CoreLocation
import MapKit

/// Carte des antennes — sans la catégorie `carplay-maps`.
///
/// C'est la pièce qui change la nature de l'app dans le véhicule. Une
/// `CPMapTemplate` exige la catégorie navigation, qu'Apple réserve aux apps de
/// guidage ; un `CPPointOfInterestTemplate`, lui, est ouvert aux apps « driving
/// task » et affiche pourtant une VRAIE carte, avec nos propres épingles.
///
/// Deux propriétés en font le bon choix ici :
///
/// - la fiche d'un point vit DANS le template (`detailTitle`, `detailSubtitle`,
///   `detailSummary`, plus deux boutons). Consulter une antenne ne pousse donc
///   aucun écran, alors que la catégorie « driving task » plafonne la pile à
///   deux templates. Là où la liste + fiche dépassait le plafond, la carte
///   tient dans un seul niveau ;
/// - les épingles sont des images à nous, donc l'identité visuelle SignalQuest
///   arrive enfin sur l'écran du véhicule.
///
/// Fonctions pures, comme les autres builders : c'est ce qui les rend
/// vérifiables sans véhicule.
@MainActor
enum CarPlayPOIBuilder {
    /// Plafond imposé par CarPlay : au-delà, seuls les 12 premiers sont retenus,
    /// en silence. On coupe nous-mêmes pour choisir LESQUELS — les plus proches.
    static let maxPoints = 12

    struct Entry {
        let payload: MapAnnotationPayload
        let distanceMeters: CLLocationDistance?
    }

    struct Actions {
        /// Enrichissement serveur de la fiche.
        var details: ((MapAnnotationPayload) -> Void)?
        /// Itinéraire — absent quand rien ne peut guider.
        var navigate: ((MapAnnotationPayload) -> Void)?
    }

    /// Trie par distance croissante, écarte les clusters (un « 42 sites » n'a
    /// pas de fiche) et coupe au plafond.
    static func entries(from payloads: [MapAnnotationPayload],
                        userLocation: CLLocation?) -> [Entry] {
        payloads
            .filter { $0.clusterCount == nil }
            .map { payload in
                let distance = userLocation.map {
                    $0.distance(from: CLLocation(latitude: payload.coordinate.latitude,
                                                 longitude: payload.coordinate.longitude))
                }
                return Entry(payload: payload, distanceMeters: distance)
            }
            .sorted { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
            .prefix(maxPoints)
            .map { $0 }
    }

    static func make(entries: [Entry],
                     userLocation: CLLocation?,
                     actions: Actions) -> CPPointOfInterestTemplate {
        let template = CPPointOfInterestTemplate(
            title: String(localized: "Antennes"),
            pointsOfInterest: points(from: entries, userLocation: userLocation, actions: actions),
            selectedIndex: NSNotFound
        )
        template.tabTitle = String(localized: "Carte")
        template.tabImage = UIImage(systemName: "map.fill")
        return template
    }

    static func points(from entries: [Entry],
                       userLocation: CLLocation?,
                       actions: Actions) -> [CPPointOfInterest] {
        entries.map { entry in
            let payload = entry.payload
            let item = MKMapItem(placemark: MKPlacemark(coordinate: payload.coordinate))
            item.name = payload.title

            let color = payload.tint.map { UIColor($0) } ?? UIColor(SQColor.brandRed)
            let poi = CPPointOfInterest(
                location: item,
                title: headline(for: entry),
                subtitle: subtitle(for: entry),
                summary: nil,
                detailTitle: payload.title,
                detailSubtitle: payload.subtitle.isEmpty ? nil : payload.subtitle,
                detailSummary: detailSummary(for: entry, userLocation: userLocation),
                pinImage: CarPlayImageFactory.antennaPin(color: color),
                selectedPinImage: CarPlayImageFactory.antennaPin(color: color, selected: true)
            )
            poi.userInfo = payload
            if let details = actions.details {
                poi.primaryButton = CPTextButton(
                    title: String(localized: "Détails"), textStyle: .normal
                ) { _ in details(payload) }
            }
            if let navigate = actions.navigate {
                poi.secondaryButton = CPTextButton(
                    title: String(localized: "Y aller"), textStyle: .confirm
                ) { _ in navigate(payload) }
            }
            return poi
        }
    }

    // MARK: - Textes

    /// Ce qu'on lit en premier doit être ce qui distingue les points entre eux.
    /// Entre douze épingles, « Site 12345 » ne distingue rien : l'opérateur, si.
    static func headline(for entry: Entry) -> String {
        let operators = entry.payload.subtitle
            .split(separator: "·")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return operators.isEmpty ? entry.payload.title : operators
    }

    /// La distance d'abord : c'est le critère de tri, elle doit se lire sans
    /// être cherchée.
    static func subtitle(for entry: Entry) -> String {
        guard let distance = entry.distanceMeters else { return entry.payload.title }
        return "\(SQUnits.distance(meters: distance)) · \(entry.payload.title)"
    }

    /// Résumé de la fiche intégrée : distance, direction, et la position dans
    /// l'axe d'un secteur — la seule information qui explique VRAIMENT ce qu'on
    /// capte à cet endroit.
    static func detailSummary(for entry: Entry, userLocation: CLLocation?) -> String? {
        var parts: [String] = []
        if let distance = entry.distanceMeters {
            parts.append(SQUnits.distance(meters: distance))
        }
        if let userLocation {
            let bearing = AntennaSectorGeometry.bearing(from: userLocation.coordinate,
                                                        to: entry.payload.coordinate)
            parts.append(CarPlayDetailTemplateBuilder.compassLabel(bearing))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
