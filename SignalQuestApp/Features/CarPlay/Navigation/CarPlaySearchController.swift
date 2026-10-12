import CarPlay
import CoreLocation
import MapKit

/// Recherche d'une destination depuis le véhicule : adresse ou site par son code.
///
/// Deux sources en parallèle — `MKLocalSearch` pour les lieux et adresses,
/// `AntennasServicing.quickSearch` pour retrouver un site par son code ANFR ou
/// son identifiant. Un utilisateur de SignalQuest tape autant « 75-1234 » qu'une
/// rue, et n'a pas à savoir laquelle des deux recherches va répondre.
///
/// ⚠️ Sur beaucoup de véhicules, le clavier est INDISPONIBLE en roulant : le
/// système refuse d'ouvrir la saisie au-delà d'une certaine vitesse. Cet écran
/// ne doit donc jamais être le seul chemin vers une destination — c'est le rôle
/// des favoris et de « Antennes autour ».
@MainActor
final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    /// Au-delà, la liste n'est plus consultable au volant — et CarPlay tronque
    /// de toute façon en silence.
    static let maxResults = 10

    private let antennas: AntennasServicing
    private let around: () -> CLLocationCoordinate2D?
    private let market: () -> String?
    private let onSelect: (CLLocationCoordinate2D, String) -> Void

    /// Résultats du dernier appel. Chaque `CPListItem` porte son rang dans
    /// `userInfo` : la sélection nous rend l'item, pas la coordonnée.
    private var results: [Result] = []

    /// Recherche en cours, annulée à chaque frappe : sans cela, une réponse
    /// lente à « rue » écraserait les résultats de « rue de Rivoli ».
    private var searchTask: Task<Void, Never>?

    init(antennas: AntennasServicing,
         around: @escaping () -> CLLocationCoordinate2D?,
         market: @escaping () -> String?,
         onSelect: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.antennas = antennas
        self.around = around
        self.market = market
        self.onSelect = onSelect
    }

    func makeTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        return template
    }

    // MARK: - CPSearchTemplateDelegate

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deux caractères ne discriminent rien et déclencheraient une requête à
        // chaque frappe.
        guard query.count >= 3 else {
            results = []
            completionHandler([])
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            let results = await search(query)
            guard !Task.isCancelled else { return }
            self.results = results
            // Le rang du résultat, pas son titre : deux « Gare » homonymes
            // mènent chacune à sa propre destination.
            completionHandler(results.enumerated().map { index, result in
                let item = CPListItem(text: result.title, detailText: result.subtitle)
                item.userInfo = index
                return item
            })
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let index = item.userInfo as? Int, results.indices.contains(index) else { return }
        let match = results[index]
        onSelect(match.coordinate, match.title)
    }

    // MARK: - Recherche

    struct Result {
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    private func search(_ query: String) async -> [Result] {
        // Les deux sources partent ENSEMBLE : les enchaîner doublerait l'attente
        // pour quelqu'un qui a déjà les mains prises.
        async let places = searchPlaces(query)
        async let sites = searchSites(query)
        // Les sites d'abord : dans SignalQuest, taper un code ANFR est une
        // intention plus précise que taper un nom de rue.
        let foundSites = await sites
        let foundPlaces = await places
        return Array((foundSites + foundPlaces).prefix(Self.maxResults))
    }

    private func searchSites(_ query: String) async -> [Result] {
        guard let market = market() else { return [] }
        let department = market.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DROM"
            ? around().flatMap(DromRegion.from)?.department
            : nil
        guard let sites = try? await antennas.quickSearch(
            query: query,
            market: market,
            department: department
        )
        else { return [] }
        return sites.compactMap { site in
            guard let lat = site.latitude, let lon = site.longitude else { return nil }
            return Result(
                title: String(localized: "Site \(site.siteId ?? site.id)"),
                subtitle: [site.operators.joined(separator: "/"), site.address]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
            )
        }
    }

    private func searchPlaces(_ query: String) async -> [Result] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // Biais de proximité : « gare » doit renvoyer celle d'à côté, pas celle
        // d'une autre région.
        if let center = around() {
            request.region = MKCoordinateRegion(center: center,
                                                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            return Result(
                title: name,
                subtitle: item.placemark.title ?? "",
                coordinate: item.placemark.coordinate
            )
        }
    }
}
