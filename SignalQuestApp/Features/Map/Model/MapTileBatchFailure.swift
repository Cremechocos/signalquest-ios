import Foundation

/// An incomplete batch is still an error. Its admitted tiles remain available
/// to consumers that can publish a partial layer and offer a retry.
struct MapTileBatchFailure<Value: MapTilePayload>: Error, LocalizedError {
    let requestedTiles: [AndroidMapTile]
    let successfulTiles: [Value]
    let failedTiles: [AndroidMapTile]
    let cause: any Error

    var errorDescription: String? { issue.message }

    var issue: MapTileLoadIssue {
        MapTileLoadIssue(requestedCount: requestedTiles.count, receivedCount: successfulTiles.count,
                         failedTiles: Set(failedTiles), detail: (cause as? CoverageBandFilterUnavailable)?.errorDescription)
    }

    /// Only the failed identities may retain old data. Successful empty tiles
    /// are authoritative, and old tiles outside this request are not reused.
    func retaining(_ previous: [Value]) -> [Value] {
        let failed = Set(failedTiles)
        let retained = previous.filter { failed.contains($0.tile) }
        let byTile = Dictionary((successfulTiles + retained).map { ($0.tile, $0) },
                                uniquingKeysWith: { first, _ in first })
        return requestedTiles.compactMap { byTile[$0] }
    }
}

struct MapTileLoadIssue: Equatable, Sendable {
    let requestedCount: Int
    let receivedCount: Int
    let failedTiles: Set<AndroidMapTile>
    var retainedCount = 0
    var detail: String? = nil

    static func layerName(_ kind: MapDisplayItem.Kind) -> String {
        switch kind {
        case .antenna: return String(localized: "Antennes")
        case .speedtest: return String(localized: "Speedtests")
        case .coverage: return String(localized: "Couverture")
        case .communitySite: return String(localized: "Cellules observées")
        case .customSite: return String(localized: "Sites ajoutés")
        default: return String(localized: "Carte")
        }
    }

    var message: String {
        let state = detail ?? (receivedCount > 0
            ? String(localized: "Données incomplètes. Certaines zones sont indisponibles.")
            : String(localized: "Données cartographiques indisponibles."))
        guard retainedCount > 0 else { return state }
        return state + " " + String(localized: "Les zones non actualisées conservent leurs dernières données.")
    }
}

/// Carries the response to the consumer's generation guard before any merge.
/// A cancellation has neither an issue nor an authoritative empty result.
struct MapTileLayerResult<Value: MapTilePayload>: Sendable {
    let tiles: [Value]?
    let failure: MapTileBatchFailure<Value>?
    let errorMessage: String?

    init(tiles: [Value]) {
        self.tiles = tiles
        self.failure = nil
        self.errorMessage = nil
    }

    private init(failure: MapTileBatchFailure<Value>) {
        // Zero admitted tiles lets legacy consumers attempt their compatible
        // fallback. A received tile with zero items remains an admitted tile.
        self.tiles = failure.successfulTiles.isEmpty ? nil : failure.successfulTiles
        self.failure = failure
        self.errorMessage = failure.localizedDescription
    }

    private init(error: any Error) {
        self.tiles = nil
        self.failure = nil
        self.errorMessage = error.isCancellation ? nil : error.localizedDescription
    }

    static func load(enabled: Bool = true,
                     operation: @Sendable () async throws -> [Value]) async -> Self {
        guard enabled else { return Self(tiles: []) }
        do { return Self(tiles: try await operation()) }
        catch let failure as MapTileBatchFailure<Value> { return Self(failure: failure) }
        catch { return Self(error: error) }
    }

    func retaining(_ previous: [Value]) -> [Value]? {
        failure.map { $0.retaining(previous) } ?? tiles
    }

    func issue(retaining previous: [Value]) -> MapTileLoadIssue? {
        guard var issue = failure?.issue else { return nil }
        issue.retainedCount = Set(previous.map(\.tile)).intersection(issue.failedTiles).count
        return issue
    }
}
