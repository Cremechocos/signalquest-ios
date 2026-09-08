import Foundation

/// Availability metadata is separate from the sites. Upstream error details are
/// deliberately not retained: only the useful public state reaches the map.
struct MapFeedAvailability: Decodable, Equatable, Sendable {
    var available: Bool? = nil
    var failedSourceCount = 0
    var unavailableSourceCount = 0
    var truncated = false
    var successfulSourceIDs: Set<String> = []
    var failedSourceIDs: Set<String> = []
    var unavailableSourceIDs: Set<String> = []

    init() {}
    private enum CodingKeys: String, CodingKey { case available, sources, sourceErrors, unavailableSources, truncated }
    private struct SourceEntry: Decodable { let id: String? }
    private struct SourceFailure: Decodable { let source: SourceEntry? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available)
        let failures = try c.decodeIfPresent([SourceFailure].self, forKey: .sourceErrors) ?? []
        let unavailable = try c.decodeIfPresent([SourceEntry].self, forKey: .unavailableSources) ?? []
        let successful = try c.decodeIfPresent([SourceEntry].self, forKey: .sources) ?? []
        failedSourceCount = failures.count
        unavailableSourceCount = unavailable.count
        successfulSourceIDs = Set(successful.compactMap(\.id))
        failedSourceIDs = Set(failures.compactMap { $0.source?.id })
        unavailableSourceIDs = Set(unavailable.compactMap(\.id))
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
    var isComplete: Bool { available != false && failedSourceCount == 0 && !truncated }
    var errorMessage: String? {
        failedSourceCount > 0 ? String(localized: "Certaines sources sont en panne. Les dernières données disponibles sont conservées.") : nil
    }
    var information: String? {
        if failedSourceCount > 0 { return nil }
        if available == false { return String(localized: "Aucune source vérifiée n’est disponible pour ce pays et cet opérateur.") }
        if truncated { return String(localized: "Résultat partiel. Zoome pour préciser la zone.") }
        if unavailableSourceCount > 0 { return String(localized: "Certains opérateurs ne disposent pas de source publique vérifiée.") }
        return nil
    }
}

protocol MapFeedSite: Identifiable, Sendable where ID == String {
    var sourceId: String? { get }
}

struct MapFeedResult<Site: MapFeedSite>: Sendable {
    let sites: [Site]
    var availability = MapFeedAvailability()

    func retaining(_ previous: [Site]) -> [Site] {
        guard !availability.isComplete else { return sites }
        let retained = previous.filter { site in
            // Truncation is global, while a source failure is local. A healthy
            // source can confirm an empty result even if its neighbour failed.
            guard !availability.truncated, let source = site.sourceId else { return true }
            if availability.failedSourceIDs.contains(source) || availability.unavailableSourceIDs.contains(source) { return true }
            return !availability.successfulSourceIDs.contains(source)
        }
        var seen = Set<String>()
        return (sites + retained).filter { seen.insert(($0.sourceId ?? "") + ":" + $0.id).inserted }
    }
    func filter(_ include: (Site) -> Bool) -> Self {
        Self(sites: sites.filter(include), availability: availability)
    }
}
