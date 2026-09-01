import Foundation

struct BoundingBox: Equatable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "north", value: String(north)),
            URLQueryItem(name: "south", value: String(south)),
            URLQueryItem(name: "east", value: String(east)),
            URLQueryItem(name: "west", value: String(west))
        ]
    }
}

protocol AntennasServicing: Sendable {
    func list(bbox: BoundingBox) async throws -> [AntennaSite]
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite]
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite]
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite]
    func details(id: String) async throws -> AntennaDetails
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails
    func search(query: String) async throws -> [AntennaSite]
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite]
    /// Sites créés par la communauté dans ce cadrage.
    ///
    /// Dans les 40+ pays sans référentiel officiel (Bosnie, États-Unis…), ce sont les SEULES
    /// antennes connues : `/api/antennas` y rend une liste vide, son dataset ne couvrant que
    /// la France, le Canada, les DROM et les pilotes européens. Sans cet appel, l'écran
    /// d'identification y reste définitivement sans candidat.
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite]
}

enum AntennasServiceError: LocalizedError {
    case marketRequired

    var errorDescription: String? {
        switch self {
        case .marketRequired:
            return String(localized: "Le pays du site est requis pour charger des antennes fiables.")
        }
    }
}

final class AntennasService: AntennasServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list(bbox: BoundingBox) async throws -> [AntennaSite] {
        // Un bbox ne prouve jamais un marché à lui seul. L'ancien repli FR pouvait
        // afficher des sites français dans le sélecteur photo d'un utilisateur à
        // l'étranger. Les appels runtime doivent désormais fournir le marché issu
        // du registre mondial (ou expliquer qu'il est inconnu).
        throw AntennasServiceError.marketRequired
    }

    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] {
        try await list(bbox: bbox, market: market, operatorName: operatorName, technologies: technologies, bands: [], sharing: [])
    }

    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] {
        try await list(bbox: bbox, market: market, operatorName: operatorName, technologies: technologies, bands: bands, bandMatch: .any, sharing: sharing)
    }

    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] {
        let operators: [String]
        if operatorName == "ALL" {
            operators = market == "FR" ? ["SFR", "BOUYGUES", "ALL"] : ["ALL"]
        } else {
            operators = [operatorName]
        }

        // Le backend ne sait pas agréger `operator=ALL` (ticket BE-3) : on émet une
        // requête PAR opérateur. Ces requêtes sont indépendantes → on les lance EN
        // PARALLÈLE (au lieu d'en série, latence ×N) puis on fusionne + déduplique
        // par siteId (une occurrence par site, quel que soit l'ordre d'arrivée).
        let batches = try await withThrowingTaskGroup(of: [AntennaSite].self) { group -> [[AntennaSite]] in
            for op in operators {
                group.addTask {
                    try await self.fetchAntennas(
                        bbox: bbox, market: market, operatorName: op,
                        technologies: technologies, bands: bands, bandMatch: bandMatch
                    )
                }
            }
            var collected: [[AntennaSite]] = []
            collected.reserveCapacity(operators.count)
            for try await batch in group { collected.append(batch) }
            return collected
        }

        var seen = Set<String>()
        return batches.flatMap { $0 }.filter { site in
            let key = site.siteId ?? site.id
            return seen.insert(key).inserted
        }
    }

    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] {
        var query = bbox.queryItems
        // Le marché est OBLIGATOIRE ici, contrairement à `/api/antennas` : sans lui la route
        // rendrait les sites communautaires du monde entier.
        query.append(URLQueryItem(name: "market", value: market))
        if let operatorName, operatorName != "ALL" {
            query.append(URLQueryItem(name: "operator", value: operatorName))
        }
        let response = try await api.request(
            APIEndpoint(path: "/api/custom-sites", query: query),
            as: CommunitySitesListResponse.self
        )
        return response.sites
    }

    /// Une requête `/api/antennas` pour UN opérateur (brique du fan-out parallèle).
    private func fetchAntennas(
        bbox: BoundingBox, market: String, operatorName op: String,
        technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode = .any
    ) async throws -> [AntennaSite] {
        var query = bbox.queryItems
        query.append(URLQueryItem(name: "market", value: market))
        query.append(URLQueryItem(name: "operator", value: op))
        query.append(URLQueryItem(name: "minimal", value: "1"))
        query.append(URLQueryItem(name: "limit", value: "1200"))
        if !technologies.isEmpty {
            query.append(URLQueryItem(name: "technologies", value: technologies.sorted().joined(separator: ",")))
        }
        if !bands.isEmpty {
            // Omis en mode « au moins une » : un backend antérieur ignore le
            // paramètre, mais autant ne pas l'envoyer quand il ne change rien.
            if bandMatch != .any {
                query.append(URLQueryItem(name: "bandMatch", value: bandMatch.rawValue))
            }
            query.append(contentsOf: Self.bandQueryItems(bands))
        }
        // NB : le filtre « Partage » (ZB/Crozon/ZTD) n'est PAS un paramètre de
        // requête — le backend /api/antennas ne lit que `sharingType`/`leader`
        // (valeur unique, FR), incapables d'exprimer un multi-select ni ZTD. Il
        // est appliqué CÔTÉ CLIENT sur les champs sharingType/crozonLeader/isZTD
        // de la réponse minimale (cf. MapExplorerView.matchesSelectedSharing),
        // comme le client Android. On force le chemin liste quand `sharing` est
        // actif (usesAdvancedAntennaFilters) pour disposer de ces champs.
        let response = try await api.request(
            APIEndpoint(path: "/api/antennas", query: query),
            as: AntennasListResponse.self
        )
        return response.antennas
    }

    // Le backend `/api/antennas` résout chaque valeur de bande via `getBand(id)`
    // — un LOOKUP DIRECT dans le registre dont les clés sont des identifiants de
    // bande ("B20", "n78"…), PAS des numéros. Envoyer un numéro nu ("20") ne
    // résout rien → `bands.length === 0` → le filtre serveur est entièrement
    // ignoré (toutes les antennes reviennent). Il faut donc émettre des IDs.
    //
    // On n'envoie PAS de paramètre `frequencies`/`frequency` (MHz) : côté backend
    // c'est un filtre SÉPARÉ (en ET) au matching numérique approximatif qui
    // exclurait à tort des antennes correctement retenues par le filtre de bande.
    private static func bandQueryItems(_ bands: Set<Int>) -> [URLQueryItem] {
        let ids = Self.bandCatalogIds(bands)
        guard !ids.isEmpty else { return [] }
        let value = ids.joined(separator: ",")
        return [
            URLQueryItem(name: "bands", value: value),
            URLQueryItem(name: "band", value: value)
        ]
    }

    /// Numéros de bande → identifiants du registre backend : 4G `"B{n}"`,
    /// 5G `"n{n}"`. On émet les DEUX variantes par bande (le backend ignore les
    /// IDs inconnus via `getBand`→null), ce qui couvre « bande N, toutes
    /// générations » sans sur-filtrer (ex. 7 → "B7"+"n7", 78 → "B78"(ignoré)+"n78").
    static func bandCatalogIds(_ bands: Set<Int>) -> [String] {
        bands.sorted().flatMap { ["B\($0)", "n\($0)"] }
    }

    func listLegacy(bbox: BoundingBox) async throws -> [AntennaSite] {
        try await api.request(
            APIEndpoint(path: "/api/antennas", query: bbox.queryItems),
            as: AntennasListResponse.self
        ).antennas
    }

    func details(id: String) async throws -> AntennaDetails {
        throw AntennasServiceError.marketRequired
    }

    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails {
        try await details(id: id, market: market, operatorName: operatorName, anfrCode: nil)
    }

    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorName)
        ]
        if let anfrCode, !anfrCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(URLQueryItem(name: "anfrCode", value: anfrCode))
        }
        return try await api.request(
            APIEndpoint(
                path: "/api/android/map/antenna/\(encodedId)",
                query: query
            ),
            as: AntennaDetails.self
        )
    }

    func search(query: String) async throws -> [AntennaSite] {
        try await api.request(
            APIEndpoint(path: "/api/antennas/search", query: [URLQueryItem(name: "q", value: query)]),
            as: AntennasListResponse.self
        ).antennas
    }

    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] {
        let queryItems = try Self.quickSearchQueryItems(
            query: query,
            market: market,
            department: department
        )
        return try await api.request(
            APIEndpoint(
                path: "/api/antennas/quick-search",
                query: queryItems
            ),
            as: AntennasListResponse.self
        ).antennas
    }

    static func quickSearchQueryItems(
        query: String,
        market: String,
        department: String?
    ) throws -> [URLQueryItem] {
        let normalizedMarket = try requiredMarketCode(market)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "market", value: normalizedMarket)
        ]
        let normalizedDepartment = department?.filter(\.isNumber)
        if normalizedMarket == "DROM",
           let normalizedDepartment,
           ["971", "972", "973", "974", "976"].contains(normalizedDepartment) {
            items.append(URLQueryItem(name: "department", value: normalizedDepartment))
        }
        return items
    }

    static func requiredMarketCode(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, normalized != "UNKNOWN" else {
            throw AntennasServiceError.marketRequired
        }
        return normalized
    }
}
