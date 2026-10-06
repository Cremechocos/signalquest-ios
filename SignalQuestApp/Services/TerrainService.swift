import CoreLocation
import Foundation

/// Relief et bâti le long d'un trajet, pour dire si une antenne est visible
/// depuis l'endroit où l'on se tient.
///
/// iOS n'expose aucun modèle de terrain (MapKit ne donne pas d'altitude, et
/// `CLLocation.altitude` est une mesure GPS/baro du seul point où l'on est).
/// Le backend, lui, sert déjà ces données au site web : `/api/rf/terrain`
/// interroge le RGE ALTI de l'IGN en France et retombe sur un MNT mondial
/// ailleurs, `/api/rf/clutter` remonte la hauteur du bâti OpenStreetMap.
protocol TerrainServicing: Sendable {
    /// Altitude du sol (m) pour chaque point, `nil` là où la source ne sait pas.
    func elevations(for points: [CLLocationCoordinate2D]) async throws -> [Double?]
    /// Hauteur du bâti (m au-dessus du sol) pour chaque point, `nil` si inconnue.
    func buildingHeights(for points: [CLLocationCoordinate2D]) async throws -> [Double?]
}

final class TerrainService: TerrainServicing {
    /// Plafond de la route backend. Au-delà, elle tronque en silence : mieux vaut
    /// tronquer nous-mêmes que recevoir moins de valeurs que de points envoyés et
    /// désaligner tout le profil.
    static let maxPoints = 512

    private let api: APIClient
    private let cache: DiskCache

    init(api: APIClient) {
        self.api = api
        // Le relief ne bouge pas : un cache long évite de réinterroger l'IGN à
        // chaque ouverture de fiche sur un site déjà consulté. Le bâti bouge un
        // peu plus (OSM s'enrichit), d'où un âge maximal plus court à la lecture.
        cache = DiskCache(folderName: "SignalQuestTerrainCache", maxBytes: 8 * 1024 * 1024, maxAge: 60 * 24 * 60 * 60)
    }

    private struct PointBody: Encodable {
        let lat: Double
        let lon: Double
    }

    private struct RequestBody: Encodable {
        let points: [PointBody]
    }

    private struct ElevationResponse: Decodable {
        struct Result: Decodable {
            let elevation: Double?
        }
        let results: [Result]
    }

    private struct ClutterResponse: Decodable {
        struct Result: Decodable {
            let buildingHeightM: Double?
            let buildingCount: Int?
        }
        let results: [Result]
    }

    func elevations(for points: [CLLocationCoordinate2D]) async throws -> [Double?] {
        try await sample(points, cachePrefix: "elev", maxAge: 60 * 24 * 60 * 60) { body in
            let response: ElevationResponse = try await self.api.requestJSON(
                "/api/rf/terrain",
                method: .post,
                body: body,
                authenticated: false
            )
            return response.results.map(\.elevation)
        }
    }

    func buildingHeights(for points: [CLLocationCoordinate2D]) async throws -> [Double?] {
        try await sample(points, cachePrefix: "clutter", maxAge: 14 * 24 * 60 * 60) { body in
            let response: ClutterResponse = try await self.api.requestJSON(
                "/api/rf/clutter",
                method: .post,
                body: body,
                authenticated: false
            )
            // Un point sans bâtiment renvoie un compte nul : c'est « dégagé », pas
            // « inconnu ». Le distinguer évite de traiter une rase campagne comme
            // une donnée manquante.
            return response.results.map { $0.buildingHeightM ?? (($0.buildingCount ?? 0) > 0 ? nil : 0) }
        }
    }

    /// Sert ce qui est déjà en cache et n'interroge le réseau que pour le reste.
    /// Deux profils voisins partagent l'essentiel de leurs points : sans ce
    /// filtrage, ouvrir deux fiches du même quartier paierait deux fois.
    private func sample(
        _ points: [CLLocationCoordinate2D],
        cachePrefix: String,
        maxAge: TimeInterval,
        fetch: (RequestBody) async throws -> [Double?]
    ) async throws -> [Double?] {
        guard !points.isEmpty else { return [] }
        let points = Array(points.prefix(Self.maxPoints))
        var results = [Double?](repeating: nil, count: points.count)
        var pending: [(index: Int, point: CLLocationCoordinate2D)] = []

        for (index, point) in points.enumerated() {
            let key = Self.cacheKey(prefix: cachePrefix, point: point)
            if let cached = try? await cache.read(Double.self, for: key, maxAge: maxAge) {
                results[index] = cached
            } else {
                pending.append((index, point))
            }
        }
        guard !pending.isEmpty else { return results }

        let body = RequestBody(points: pending.map { PointBody(lat: $0.point.latitude, lon: $0.point.longitude) })
        let fetched = try await fetch(body)
        for (offset, item) in pending.enumerated() {
            guard offset < fetched.count, let value = fetched[offset], value.isFinite else { continue }
            results[item.index] = value
            try? await cache.write(value, for: Self.cacheKey(prefix: cachePrefix, point: item.point))
        }
        return results
    }

    /// 5 décimales ≈ 1 m : c'est la granularité du cache serveur, et deux points
    /// plus proches que ça partagent de toute façon la même altitude.
    private static func cacheKey(prefix: String, point: CLLocationCoordinate2D) -> String {
        String(format: "%@-%.5f-%.5f", prefix, point.latitude, point.longitude)
    }
}
