import CarPlay
import CoreLocation

/// Destinations récentes, partagées entre l'iPhone et le véhicule.
///
/// C'est la source la plus sûre en conduite : une pression, aucune saisie. Sur
/// les véhicules où le clavier se bloque au-delà d'une certaine vitesse, c'est
/// aussi la seule qui reste disponible en roulant.
///
/// Persistées dans `UserDefaults` comme `MapRegionStore` et les autres
/// préférences de carte : ce sont des habitudes locales, pas des données de
/// compte à synchroniser.
enum CarPlayDestinationStore {
    static let key = "sq.carplay.recentDestinations.v1"

    /// Au-delà, une liste ne se parcourt plus au volant — et les entrées du bas
    /// ne seraient jamais atteintes.
    static let maxEntries = 8

    struct Destination: Codable, Equatable {
        let title: String
        let latitude: Double
        let longitude: Double
        let usedAt: Date

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static func all() -> [Destination] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder.signalQuest.decode([Destination].self, from: data) else {
            return []
        }
        return entries
    }

    /// Enregistre une destination utilisée. La plus récente passe en tête, et
    /// une destination déjà connue REMONTE au lieu de créer un doublon — sinon
    /// un trajet quotidien saturerait la liste de lui-même.
    static func record(title: String, coordinate: CLLocationCoordinate2D, now: Date = Date()) {
        var entries = all().filter { !isSamePlace($0.coordinate, coordinate) }
        entries.insert(
            Destination(title: title,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        usedAt: now),
            at: 0
        )
        save(Array(entries.prefix(maxEntries)))
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ entries: [Destination]) {
        guard let data = try? JSONEncoder.signalQuest.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Deux points à moins de 100 m sont le même endroit : le GPS d'un parking
    /// ne rend jamais deux fois exactement la même coordonnée, et sans cette
    /// tolérance la même destination apparaîtrait en double.
    static func isSamePlace(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < 100
    }
}

/// Liste des destinations récentes.
@MainActor
enum RecentDestinationsTemplateBuilder {
    static func make(_ destinations: [CarPlayDestinationStore.Destination],
                     onSelect: @escaping (CarPlayDestinationStore.Destination) -> Void) -> CPListTemplate {
        let items: [CPListItem] = destinations.map { destination in
            let item = CPListItem(text: destination.title, detailText: nil)
            item.handler = { _, completion in
                onSelect(destination)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: String(localized: "Récents"),
                                      sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [String(localized: "Aucune destination récente")]
        template.emptyViewSubtitleVariants = [
            String(localized: "Les endroits où tu te rends apparaîtront ici.")
        ]
        return template
    }
}
