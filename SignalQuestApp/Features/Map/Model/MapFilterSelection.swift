import Foundation

/// A value snapshot: editing a copy never writes preferences or starts a load.
struct MapFilterSelection: Equatable {
    var market: String
    var operatorName: String
    var technologies: Set<String>
    var bands: Set<Int>
    var bandMatch: BandMatchMode
    var azimuthStyle: AzimuthStyle
    var sharing: Set<String>
    var speedtestDays: Int
    var coverageDays: Int
    var layers: Set<MapDisplayItem.Kind>
    var includeObserved: Bool
    var plannedStatuses: Set<PlannedActivationStatus>

    static func defaults(market: String, operatorName: String) -> Self {
        Self(market: market, operatorName: operatorName, technologies: [], bands: [],
             bandMatch: .any, azimuthStyle: .lines, sharing: [], speedtestDays: 0,
             coverageDays: 0, layers: MapFilterStore.defaultFilters, includeObserved: true,
             plannedStatuses: Set(PlannedActivationStatus.allCases))
    }

    /// Only context-dependent values are pruned. Layer bits are preserved:
    /// photos, friends and coverage also have community-market consumers.
    func normalized(for entry: MarketRegistryEntry, dromRegion: DromRegion?) -> Self {
        var result = self
        result.market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        let operators = Self.operatorOptions(for: entry, dromRegion: dromRegion)
        let candidate = entry.operatorEntry(forKey: operatorName)?.key ?? operatorName.uppercased()
        result.operatorName = operators.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            ?? (entry.isCommunityOnly ? "ALL" : operators.first { $0 != "ALL" } ?? "ALL")
        result.technologies.formIntersection(MapFilterCatalog.technologies(forMarket: result.market).map(\.value))
        result.bands.formIntersection(MapFilterCatalog.bands(forMarket: result.market).map(\.band))
        result.sharing.formIntersection(MapFilterCatalog.sharing(forMarket: result.market).map(\.value))
        return result
    }

    static func operatorOptions(for entry: MarketRegistryEntry, dromRegion: DromRegion?) -> [String] {
        var keys = entry.selectableOperators.map(\.key)
        if entry.marketCode.uppercased() == "DROM", let dromRegion {
            keys = keys.filter { dromRegion.allows(operatorKey: $0) }
        }
        if !keys.contains(where: { $0.uppercased() == "ALL" }) { keys.append("ALL") }
        return keys
    }

    func requiresNetworkReload(comparedTo previous: Self) -> Bool {
        var request = self
        request.azimuthStyle = previous.azimuthStyle
        request.plannedStatuses = previous.plannedStatuses
        return request != previous
    }
}
