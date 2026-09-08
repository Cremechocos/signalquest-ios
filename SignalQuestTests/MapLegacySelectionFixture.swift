import Foundation
@testable import SignalQuest

enum LegacySelection {
    static func visibleTiles(bounds: MapBounds, zoom: Double, detailBoost: Int = 0, maxTiles: Int = 24) -> [AndroidMapTile] {
        // `Int(zoom.rounded(.down))` trappe sur NaN/infini. Les `min`/`max` qui
        // suivent neutralisent les NaN de lat/lon par accident (sémantique de
        // Swift.min/max), mais pas celui du zoom. Point d'entrée des 4 couches
        // de tuiles : la garde ici les couvre toutes.
        guard bounds.isFinite, zoom.isFinite else { return [] }
        let z = min(16, max(4, Int(zoom.rounded(.down)) + detailBoost))
        let north = min(85.05112878, max(-85.05112878, bounds.north))
        let south = min(85.05112878, max(-85.05112878, bounds.south))
        let west = min(180, max(-180, bounds.west))
        let east = min(180, max(-180, bounds.east))
        let topLeft = tileXY(lat: north, lon: west, z: z)
        let bottomRight = tileXY(lat: south, lon: east, z: z)
        let minX = min(topLeft.x, bottomRight.x)
        let maxX = max(topLeft.x, bottomRight.x)
        let minY = min(topLeft.y, bottomRight.y)
        let maxY = max(topLeft.y, bottomRight.y)
        let maxTileCount = maxTiles
        var tiles: [AndroidMapTile] = []
        for x in minX...maxX {
            for y in minY...maxY {
                tiles.append(AndroidMapTile(z: z, x: x, y: y))
                if tiles.count >= maxTileCount { return tiles }
            }
        }
        return tiles
    }
    static func tileXY(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(z))
        let latRad = lat * .pi / 180
        let x = Int(((lon + 180.0) / 360.0 * n).rounded(.down))
        let y = Int(((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n).rounded(.down))
        let maxIndex = Int(n) - 1
        return (min(max(x, 0), maxIndex), min(max(y, 0), maxIndex))
    }
}
