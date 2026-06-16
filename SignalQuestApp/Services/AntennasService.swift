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
    func details(id: String) async throws -> AntennaDetails
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails
    func search(query: String) async throws -> [AntennaSite]
    func quickSearch(query: String) async throws -> [AntennaSite]
    func validate(siteId: String, type: String, value: String, action: String) async throws
    func reportIssue(siteId: String, reason: String, comment: String?) async throws
}

struct AntennaValidationRequest: Codable {
    let siteId: String
    let type: String
    let value: String
    let action: String
}

struct AntennaReportRequest: Codable {
    let siteId: String
    let reason: String
    let comment: String?
}

final class AntennasService: AntennasServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func list(bbox: BoundingBox) async throws -> [AntennaSite] {
        try await list(bbox: bbox, market: "FR", operatorName: "ALL", technologies: [])
    }

    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] {
        try await list(bbox: bbox, market: market, operatorName: operatorName, technologies: technologies, bands: [], sharing: [])
    }

    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] {
        let operators: [String]
        if operatorName == "ALL" {
            operators = market == "FR" ? ["SFR", "BOUYGUES", "ALL"] : ["ALL"]
        } else {
            operators = [operatorName]
        }

        var merged: [AntennaSite] = []
        for op in operators {
            var query = bbox.queryItems
            query.append(URLQueryItem(name: "market", value: market))
            query.append(URLQueryItem(name: "operator", value: op))
            query.append(URLQueryItem(name: "minimal", value: "1"))
            query.append(URLQueryItem(name: "limit", value: "1200"))
            if !technologies.isEmpty {
                query.append(URLQueryItem(name: "technologies", value: technologies.sorted().joined(separator: ",")))
            }
            if !bands.isEmpty {
                query.append(contentsOf: Self.bandQueryItems(bands))
            }
            if !sharing.isEmpty {
                query.append(URLQueryItem(name: "sharing", value: sharing.sorted().joined(separator: ",")))
            }
            let response = try await api.request(
                APIEndpoint(path: "/api/antennas", query: query),
                as: AntennasListResponse.self
            )
            merged.append(contentsOf: response.antennas)
        }
        var seen = Set<String>()
        return merged.filter { site in
            let key = site.siteId ?? site.id
            return seen.insert(key).inserted
        }
    }

    private static func bandQueryItems(_ bands: Set<Int>) -> [URLQueryItem] {
        let values = bands.sorted()
        guard !values.isEmpty else { return [] }
        let bandValue = values.map(String.init).joined(separator: ",")
        var items = [
            URLQueryItem(name: "bands", value: bandValue),
            URLQueryItem(name: "band", value: bandValue),
            URLQueryItem(name: "frequencyBands", value: bandValue)
        ]
        let frequencyValue = values.compactMap(frequencyMHz(forBand:)).map(String.init).joined(separator: ",")
        if !frequencyValue.isEmpty {
            items.append(URLQueryItem(name: "frequencies", value: frequencyValue))
            items.append(URLQueryItem(name: "frequency", value: frequencyValue))
        }
        return items
    }

    private static func frequencyMHz(forBand band: Int) -> Int? {
        switch band {
        case 1: return 2100
        case 3: return 1800
        case 7: return 2600
        case 20: return 800
        case 28: return 700
        case 78: return 3500
        default: return nil
        }
    }

    func listLegacy(bbox: BoundingBox) async throws -> [AntennaSite] {
        try await api.request(
            APIEndpoint(path: "/api/antennas", query: bbox.queryItems),
            as: AntennasListResponse.self
        ).antennas
    }

    func details(id: String) async throws -> AntennaDetails {
        try await details(id: id, market: "FR", operatorName: "SFR")
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

    func quickSearch(query: String) async throws -> [AntennaSite] {
        try await api.request(
            APIEndpoint(path: "/api/antennas/quick-search", query: [URLQueryItem(name: "q", value: query)]),
            as: AntennasListResponse.self
        ).antennas
    }

    func validate(siteId: String, type: String, value: String, action: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/antennas/validate",
            body: AntennaValidationRequest(siteId: siteId, type: type, value: value, action: action)
        )
    }

    func reportIssue(siteId: String, reason: String, comment: String?) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/antennas/reports",
            body: AntennaReportRequest(siteId: siteId, reason: reason, comment: comment)
        )
    }
}
