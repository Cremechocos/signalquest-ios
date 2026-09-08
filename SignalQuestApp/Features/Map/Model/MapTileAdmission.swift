import Foundation

/// Tous les payloads tuilés possèdent une identité et des tableaux vérifiables.
/// Les décodeurs métier tolérants ne peuvent fabriquer un succès vide pour une
/// enveloppe absente, une autre tuile ou un tableau entièrement indécodable.
protocol MapTilePayload: Decodable, Sendable {
    var tile: AndroidMapTile { get }
    static var payloadArrays: [String] { get }
    var decodedItemCount: Int { get }
}

extension AndroidAntennaTileResponse: MapTilePayload {
    static var payloadArrays: [String] { ["markers", "clusters"] }
    var decodedItemCount: Int { markers.count + clusters.count }
}
extension AndroidSpeedtestTileResponse: MapTilePayload {
    static var payloadArrays: [String] { ["markers", "clusters"] }
    var decodedItemCount: Int { markers.count + clusters.count }
}
extension AndroidCoverageTileResponse: MapTilePayload {
    static var payloadArrays: [String] { ["points", "clusters"] }
    var decodedItemCount: Int { points.count + clusters.count }
}
extension AndroidCommunitySiteTileResponse: MapTilePayload {
    static var payloadArrays: [String] { ["markers", "clusters"] }
    var decodedItemCount: Int { markers.count + clusters.count }
}
extension AndroidCustomSiteTileResponse: MapTilePayload {
    static var payloadArrays: [String] { ["markers"] }
    var decodedItemCount: Int { markers.count }
}

enum MapTileAdmission {
    static func decode<Value: MapTilePayload>(_ type: Value.Type, from data: Data,
                                               expectedTile: AndroidMapTile) throws -> Value {
        let envelope = try JSONDecoder.signalQuest.decode(Envelope<Value>.self, from: data)
        guard envelope.tile == expectedTile, envelope.value.tile == expectedTile,
              envelope.rawCount == envelope.value.decodedItemCount else {
            throw APIError.decoding("Map tile identity or item count does not match its envelope")
        }
        return envelope.value
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct RawMapItem: Decodable {
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Key.self)
            let id = (try? keys.decode(String.self, forKey: Key("id")))
                ?? (try? keys.decode(Int.self, forKey: Key("id"))).map(String.init)
            let latitude = try keys.decode(Double.self, forKey: Key("lat"))
            let longitude = try keys.decode(Double.self, forKey: Key("lng"))
            guard id?.isEmpty == false, latitude.isFinite, longitude.isFinite,
                  abs(latitude) <= 90, abs(longitude) <= 180 else {
                throw APIError.decoding("Map item identity or coordinates unavailable")
            }
        }
    }

    private struct Envelope<Value: MapTilePayload>: Decodable {
        let tile: AndroidMapTile
        let rawCount: Int
        let value: Value
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Key.self)
            if try keys.decodeIfPresent(Bool.self, forKey: Key("degraded")) == true {
                throw APIError.http(status: 503, code: "DATABASE_UNAVAILABLE",
                                    message: "Données cartographiques temporairement indisponibles", requestId: nil, retryAfter: 15)
            }
            tile = try keys.decode(AndroidMapTile.self, forKey: Key("tile"))
            var count = 0
            for name in Value.payloadArrays {
                var array = try keys.nestedUnkeyedContainer(forKey: Key(name))
                guard let itemCount = array.count else { throw APIError.decoding("Uncounted map tile array") }
                while !array.isAtEnd { _ = try array.decode(RawMapItem.self) }
                count += itemCount
            }
            rawCount = count
            value = try Value(from: decoder)
        }
    }
}

/// Les plafonds de transport restent indépendants de la couverture géométrique.
/// Aucune de ces valeurs ne permet de promettre « toutes les mesures affichées ».
enum MapDataLimits {
    static func speedtests(_ tiles: [AndroidSpeedtestTileResponse]) -> Bool {
        tiles.contains { $0.stats?.hasMore == true || $0.stats?.truncated == true }
    }
    static func coverage(_ tiles: [AndroidCoverageTileResponse]) -> Bool {
        tiles.contains {
            $0.stats?.hasMore == true || $0.stats?.truncated == true
                || ($0.stats == nil && $0.points.count >= 2500)
        }
    }
    static func communitySites(_ tiles: [AndroidCommunitySiteTileResponse]) -> Bool {
        // L'API limite les candidats AVANT de retirer ceux déjà identifiés ; un
        // résultat plus court ne permet pas de prouver l'exhaustivité du dataset.
        tiles.contains { $0.markers.count >= 1500 }
    }
    static func customSites(_ tiles: [AndroidCustomSiteTileResponse]) -> Bool {
        tiles.contains { $0.markers.count >= 800 }
    }
}
