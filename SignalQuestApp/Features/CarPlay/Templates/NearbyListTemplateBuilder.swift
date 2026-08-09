import CarPlay
import CoreLocation

/// Liste « Autour de moi » : les sites visibles, triés par distance.
///
/// Ce n'est pas un confort, c'est le SEUL chemin vers les fiches sur une bonne
/// partie du parc : beaucoup de véhicules CarPlay se pilotent à la molette, sans
/// écran tactile, et viser un marqueur de quelques points sur une carte qui
/// défile y est impossible. La carte reste le mode principal ; cette liste
/// garantit que rien n'est hors d'atteinte.
@MainActor
enum NearbyListTemplateBuilder {
    /// CarPlay tronque au-delà de `maximumItemCount`, en silence. On coupe
    /// nous-mêmes, plus tôt : au-delà d'une poignée d'entrées, une liste n'est
    /// de toute façon plus consultable en roulant.
    static let maxEntries = 12

    struct Entry {
        let payload: MapAnnotationPayload
        let distanceMeters: CLLocationDistance?
    }

    /// Trie par distance croissante et écarte les clusters : un « 42 sites »
    /// n'a pas de fiche à ouvrir.
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
            .prefix(maxEntries)
            .map { $0 }
    }

    static func make(entries: [Entry],
                     onSelect: @escaping (MapAnnotationPayload) -> Void) -> CPListTemplate {
        let items: [CPListItem] = entries.map { entry in
            let item = CPListItem(text: entry.payload.title, detailText: subtitle(for: entry))
            item.handler = { _, completion in
                onSelect(entry.payload)
                completion()
            }
            return item
        }
        let template = CPListTemplate(
            title: String(localized: "Autour de toi"),
            sections: [CPListSection(items: items)]
        )
        template.emptyViewTitleVariants = [String(localized: "Rien à proximité")]
        template.emptyViewSubtitleVariants = [
            String(localized: "Aucun site dans la zone affichée.")
        ]
        return template
    }

    /// Distance d'abord : c'est le critère de tri, il doit se lire en premier.
    static func subtitle(for entry: Entry) -> String {
        let base = entry.payload.subtitle
        guard let distance = entry.distanceMeters else { return base }
        let formatted = SQUnits.distance(meters: distance)
        return base.isEmpty ? formatted : "\(formatted) · \(base)"
    }
}
