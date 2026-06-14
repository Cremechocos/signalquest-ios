import Foundation
import os

protocol MarketRegistryServicing: Sendable {
    /// Toujours non-throwing : mémoire → réseau (+ cache disque 24 h) →
    /// cache disque → JSON bundlé.
    func registry() async -> MarketRegistryPayload
    func market(forCode code: String?) async -> MarketRegistryEntry?
    /// Première aire (ordre de déclaration Android) contenant le point.
    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry?
    func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool
    /// Zone tampon France (métropole + Corse) : tant que le point y reste,
    /// on ne quitte pas FR (évite le ping-pong aux frontières).
    func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool
}

final class MarketRegistryService: MarketRegistryServicing, @unchecked Sendable {
    private let api: APIClient
    private let cache: DiskCache
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "MarketRegistry")

    private struct Resolved: Sendable {
        let payload: MarketRegistryPayload
        /// Vrai si le payload vient du réseau ou du cache disque récent ;
        /// faux quand on a dû servir le fallback bundlé (on retentera).
        let isAuthoritative: Bool
    }

    private struct State {
        var payload: MarketRegistryPayload?
        var isAuthoritative = false
        var lastAttempt: Date?
        var inFlight: Task<Resolved, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let areasState = OSAllocatedUnfairLock<MarketLocationAreasFile?>(initialState: nil)

    private static let diskKey = "market-registry-v1"
    private static let diskTTL: TimeInterval = 24 * 60 * 60
    /// Quand on tourne sur le fallback bundlé, on ne retente le réseau
    /// qu'à cet intervalle pour ne pas marteler à chaque mouvement de carte.
    private static let retryInterval: TimeInterval = 120

    init(api: APIClient, cache: DiskCache = DiskCache()) {
        self.api = api
        self.cache = cache
    }

    // MARK: Registre

    func registry() async -> MarketRegistryPayload {
        let now = Date()
        if let cached = state.withLock({ st -> MarketRegistryPayload? in
            guard let payload = st.payload else { return nil }
            if st.isAuthoritative { return payload }
            if let last = st.lastAttempt, now.timeIntervalSince(last) < Self.retryInterval {
                return payload
            }
            return nil
        }) {
            return cached
        }

        let task: Task<Resolved, Never> = state.withLock { st in
            if let inFlight = st.inFlight { return inFlight }
            st.lastAttempt = now
            let task = Task { [api, cache, logger] in
                await Self.resolveRegistry(api: api, cache: cache, logger: logger)
            }
            st.inFlight = task
            return task
        }

        let resolved = await task.value
        state.withLock { st in
            st.payload = resolved.payload
            st.isAuthoritative = resolved.isAuthoritative
            st.inFlight = nil
        }
        return resolved.payload
    }

    func market(forCode code: String?) async -> MarketRegistryEntry? {
        await registry().market(forCode: code)
    }

    // MARK: Résolution par position (portage exact d'Android)

    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let normalizedLongitude = Self.normalizeLongitude(longitude)
        let containing = locationAreas().areas.filter {
            $0.contains(latitude: latitude, longitude: normalizedLongitude)
        }
        guard !containing.isEmpty else { return nil }
        let payload = await registry()
        for area in containing {
            if let entry = payload.market(forCode: area.market) { return entry }
        }
        return nil
    }

    func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool {
        guard let code = marketCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !code.isEmpty,
            latitude.isFinite, longitude.isFinite else { return false }
        let normalizedLongitude = Self.normalizeLongitude(longitude)
        return locationAreas().areas.contains { area in
            area.market.uppercased() == code &&
                area.contains(latitude: latitude, longitude: normalizedLongitude)
        }
    }

    func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        let normalizedLongitude = Self.normalizeLongitude(longitude)
        return locationAreas().franceHysteresis.contains {
            $0.contains(latitude: latitude, longitude: normalizedLongitude)
        }
    }

    // MARK: Chargements

    private static func resolveRegistry(api: APIClient, cache: DiskCache, logger: Logger) async -> Resolved {
        // 1. Réseau, puis mise en cache disque (TTL 24 h).
        do {
            let payload = try await api.request(
                APIEndpoint(path: "/api/android/markets", authenticated: false),
                as: MarketRegistryPayload.self
            )
            if !payload.markets.isEmpty {
                try? await cache.write(payload, for: diskKey)
                return Resolved(payload: payload, isAuthoritative: true)
            }
        } catch {
            logger.debug("Registre marchés réseau indisponible: \(error.localizedDescription, privacy: .public)")
        }
        // 2. Cache disque encore frais.
        if let payload = try? await cache.read(MarketRegistryPayload.self, for: diskKey, maxAge: diskTTL),
           !payload.markets.isEmpty {
            return Resolved(payload: payload, isAuthoritative: true)
        }
        // 3. Fallback bundlé — garanti présent dans les ressources.
        return Resolved(payload: bundledFallback(logger: logger), isAuthoritative: false)
    }

    private static func bundledFallback(logger: Logger) -> MarketRegistryPayload {
        guard let url = Bundle.main.url(forResource: "market_registry_fallback", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: data) else {
            logger.error("market_registry_fallback.json introuvable ou illisible")
            return .empty
        }
        return payload
    }

    private func locationAreas() -> MarketLocationAreasFile {
        areasState.withLock { cached in
            if let cached { return cached }
            let loaded = Self.loadLocationAreas(logger: logger)
            cached = loaded
            return loaded
        }
    }

    private static func loadLocationAreas(logger: Logger) -> MarketLocationAreasFile {
        guard let url = Bundle.main.url(forResource: "market_location_areas", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(MarketLocationAreasFile.self, from: data) else {
            logger.error("market_location_areas.json introuvable ou illisible")
            return MarketLocationAreasFile(areas: [], franceHysteresis: [])
        }
        return file
    }

    /// Normalise la longitude dans [-180, 180], comme Android
    /// (truncatingRemainder == opérateur % de Kotlin).
    private static func normalizeLongitude(_ longitude: Double) -> Double {
        if longitude > 180 {
            return (longitude + 180).truncatingRemainder(dividingBy: 360) - 180
        }
        if longitude < -180 {
            return (longitude - 180).truncatingRemainder(dividingBy: 360) + 180
        }
        return longitude
    }
}

// MARK: - Aires géographiques (market_location_areas.json)

private struct MarketLocationAreasFile: Decodable, Sendable {
    let areas: [MarketLocationArea]
    let franceHysteresis: [MarketLocationArea]

    init(areas: [MarketLocationArea], franceHysteresis: [MarketLocationArea]) {
        self.areas = areas
        self.franceHysteresis = franceHysteresis
    }

    enum CodingKeys: String, CodingKey {
        case areas, franceHysteresis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areas = c.decodeLossyArray([MarketLocationArea].self, forKey: .areas)
        franceHysteresis = c.decodeLossyArray([MarketLocationArea].self, forKey: .franceHysteresis)
    }
}

private struct MarketLocationArea: Decodable, Sendable {
    let market: String
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    /// Sommets en `[lat, lng]`, comme Android.
    let polygon: [[Double]]?

    /// Portage exact de MarketRegistry.kt : bbox d'abord, puis ray-casting
    /// si un polygone est déclaré.
    func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= south, latitude <= north,
              longitude >= west, longitude <= east else { return false }
        guard let polygon, !polygon.isEmpty else { return true }
        return Self.containsPoint(polygon, latitude: latitude, longitude: longitude)
    }

    private static func containsPoint(_ points: [[Double]], latitude: Double, longitude: Double) -> Bool {
        var inside = false
        var previous = points.count - 1
        for current in points.indices {
            guard points[current].count >= 2, points[previous].count >= 2 else {
                previous = current
                continue
            }
            let currentLat = points[current][0]
            let currentLng = points[current][1]
            let previousLat = points[previous][0]
            let previousLng = points[previous][1]
            let intersects = (currentLat > latitude) != (previousLat > latitude) &&
                longitude < (previousLng - currentLng) * (latitude - currentLat) / (previousLat - currentLat) + currentLng
            if intersects { inside.toggle() }
            previous = current
        }
        return inside
    }
}
