import Foundation

enum MapTilePlanningError: Error, Equatable {
    case invalidBounds
    case invalidZoom
    case invalidBudget
    case invalidMaximumZoom
    /// La zone géographique n'intersecte pas la projection des tuiles serveur.
    /// Cet état ne doit pas être converti en une réponse de données vide réussie.
    case outsideMercatorProjection
}

struct MapLongitudeRange: Equatable, Sendable {
    let west: Double
    let east: Double
}

struct MapTilePlan: Equatable, Sendable {
    let desiredZoom: Int
    let selectedZoom: Int
    let tiles: [AndroidMapTile]
    let longitudeRanges: [MapLongitudeRange]
    let north: Double
    let south: Double
    /// Vrai seulement si une partie du viewport fourni dépasse la projection
    /// Mercator. La couverture de cette partie n'est pas prétendue.
    let clipsPolarArea: Bool
    let coversWholeWorldLongitude: Bool

    var usesReducedDetail: Bool { selectedZoom < desiredZoom }
}

/// Sélection géométrique uniquement. Elle ne garantit ni la disponibilité des
/// tuiles, ni l'exhaustivité des marqueurs/pages renvoyés par leur endpoint.
enum MapTilePlanner {
    static let mercatorLatitudeLimit = atan(sinh(Double.pi)) * 180 / Double.pi
    /// Limite acceptée par parseTileParams côté API ; la carte choisit par défaut
    /// le plafond client actuel z16. Descendre jusqu'à z0 couvre le monde bornément.
    static let serverMaximumZoom = 20
    /// Plus grand budget déjà utilisé par le client (couverture renforcée).
    /// Le plafond mémoire/réseau ne dépend jamais d'une emprise géographique.
    static let maximumTileBudget = 40

    static func plan(bounds: MapBounds, zoom: Double, detailBoost: Int = 0,
                     tileBudget: Int = 24, maximumZoom: Int = 16) throws -> MapTilePlan {
        guard bounds.isFinite, bounds.north >= bounds.south,
              bounds.north <= 90, bounds.south >= -90 else { throw MapTilePlanningError.invalidBounds }
        guard zoom.isFinite else { throw MapTilePlanningError.invalidZoom }
        guard (1...maximumTileBudget).contains(tileBudget) else { throw MapTilePlanningError.invalidBudget }
        guard (0...serverMaximumZoom).contains(maximumZoom) else { throw MapTilePlanningError.invalidMaximumZoom }
        // MapKit et la formule serveur peuvent différer de quelques ULP à la
        // frontière exacte du monde ; ce n'est pas une véritable portion polaire.
        let latitudeRoundoff = mercatorLatitudeLimit.ulp * 4
        guard bounds.north >= -mercatorLatitudeLimit - latitudeRoundoff,
              bounds.south <= mercatorLatitudeLimit + latitudeRoundoff else { throw MapTilePlanningError.outsideMercatorProjection }
        let window = try LongitudeWindow(west: bounds.west, east: bounds.east)
        let north = min(mercatorLatitudeLimit, max(-mercatorLatitudeLimit, bounds.north))
        let south = max(-mercatorLatitudeLimit, min(mercatorLatitudeLimit, bounds.south))
        // Borner AVANT la conversion Int évite le piège des Double finis mais énormes.
        let requested = min(Double(maximumZoom), max(0, floor(zoom) + Double(detailBoost)))
        let desiredZoom = Int(requested)
        var selectedZoom = desiredZoom
        var grid = Grid(window: window, north: north, south: south, zoom: selectedZoom)
        while grid.count > tileBudget, selectedZoom > 0 {
            selectedZoom -= 1
            grid = Grid(window: window, north: north, south: south, zoom: selectedZoom)
        }
        // z0 contient une tuile : tout budget positif satisfait cette condition.
        precondition(grid.count <= tileBudget)
        var tiles: [AndroidMapTile] = []
        tiles.reserveCapacity(grid.count)
        for range in grid.xRanges {
            for x in range {
                for y in grid.yRange { tiles.append(AndroidMapTile(z: selectedZoom, x: x, y: y)) }
            }
        }
        // Un futur chargement progressif commence près du centre, sans abandonner
        // les bords. Le tie-break rend l'ordre stable à entrée identique.
        let n = Double(1 << selectedZoom)
        let centerX = (window.center + 180) / 360 * n
        let centerY = mercatorY(latitude: (north + south) / 2, scale: n)
        func distance(_ tile: AndroidMapTile) -> Double {
            let dx = abs(Double(tile.x) + 0.5 - centerX)
            let wrappedDX = min(dx, n - dx)
            let dy = Double(tile.y) + 0.5 - centerY
            return wrappedDX * wrappedDX + dy * dy
        }
        tiles.sort {
            let lhs = distance($0), rhs = distance($1)
            if lhs != rhs { return lhs < rhs }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }
        return MapTilePlan(desiredZoom: desiredZoom, selectedZoom: selectedZoom, tiles: tiles,
                           longitudeRanges: window.ranges, north: north, south: south,
                           clipsPolarArea: abs(north - bounds.north) > latitudeRoundoff || abs(south - bounds.south) > latitudeRoundoff,
                           coversWholeWorldLongitude: window.isWorld)
    }

    static func longitudeRanges(west: Double, east: Double) throws -> [MapLongitudeRange] {
        guard west.isFinite, east.isFinite else { throw MapTilePlanningError.invalidBounds }
        return try LongitudeWindow(west: west, east: east).ranges
    }

    private struct LongitudeWindow {
        let ranges: [MapLongitudeRange]
        let center: Double
        let isWorld: Bool
        init(west: Double, east: Double) throws {
            let rawSpan = east - west
            guard rawSpan.isFinite else { throw MapTilePlanningError.invalidBounds }
            // Accepte les bounds non normalisés de MapKit (ex. 179…181) et les
            // bounds normalisés d'une API (179…-179). Aucun clamp à ±180 séparé.
            let world = abs(rawSpan) >= 360
            let span = world ? 360 : rawSpan >= 0 ? rawSpan : rawSpan + 360
            let start = MapViewportProjection.normalizedLongitude(west)
            isWorld = world
            center = MapViewportProjection.normalizedLongitude(start + span / 2)
            if world {
                ranges = [.init(west: -180, east: 180)]
            } else if start + span <= 180 {
                ranges = [.init(west: start, east: start + span)]
            } else {
                ranges = [.init(west: start, east: 180), .init(west: -180, east: start + span - 360)]
            }
        }
    }

    private struct Grid {
        let xRanges: [ClosedRange<Int>]
        let yRange: ClosedRange<Int>
        var count: Int { xRanges.reduce(0) { $0 + $1.count } * yRange.count }
        init(window: LongitudeWindow, north: Double, south: Double, zoom: Int) {
            let n = 1 << zoom
            func x(_ longitude: Double) -> Int {
                min(n - 1, max(0, Int(floor((longitude + 180) / 360 * Double(n)))))
            }
            func y(_ latitude: Double) -> Int {
                min(n - 1, max(0, Int(floor(mercatorY(latitude: latitude, scale: Double(n))))))
            }
            var ranges = window.ranges.map { x($0.west)...x($0.east) }
            // ±180 est la même frontière mais les enregistrements serveur peuvent
            // porter l'un ou l'autre signe. Demander ses deux cellules de bord.
            if window.ranges.contains(where: { $0.west == -180 || $0.east == 180 }) {
                ranges += [0...0, (n - 1)...(n - 1)]
            }
            ranges.sort { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Int>] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else { merged.append(range) }
            }
            xRanges = merged
            yRange = y(north)...y(south)
        }
    }

    private static func mercatorY(latitude: Double, scale: Double) -> Double {
        (1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * scale
    }
}


extension MapTilePlanningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .outsideMercatorProjection:
            return String(localized: "Cette zone dépasse la projection disponible pour la carte.")
        default:
            return String(localized: "Vue cartographique indisponible. Déplace la carte pour réessayer.")
        }
    }
}
