import Foundation
import os

protocol MarketRegistryServicing: Sendable {
    /// Toujours non-throwing et sans attente réseau : mémoire → cache disque
    /// récent (24 h) → JSON bundlé ; le réseau rafraîchit en arrière-plan.
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
        /// Premier chargement local, partagé par les appels concurrents.
        var localLoad: Task<Resolved, Never>?
        var refresh: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let areasState = OSAllocatedUnfairLock<MarketLocationAreasFile?>(initialState: nil)

    private static let diskKey = "market-registry-v1"
    private static let diskTTL: TimeInterval = 24 * 60 * 60
    /// Quand on tourne sur le fallback bundlé, on ne retente le réseau
    /// qu'à cet intervalle pour ne pas marteler à chaque mouvement de carte.
    private static let retryInterval: TimeInterval = 120
    /// ~900 Ko de JSON décodés une seule fois par processus : c'est à la fois le
    /// repli hors ligne et la référence de chaque comparaison (MES-29).
    private static let bundled: MarketRegistryPayload = {
        guard let url = Bundle.main.url(forResource: "market_registry_fallback", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: data) else {
            Logger(subsystem: "fr.signalquest.ios", category: "MarketRegistry")
                .error("market_registry_fallback.json introuvable ou illisible")
            return .empty
        }
        return payload
    }()

    // Dossier dédié — cf. la note dans MapSnapshotService : les deux partageaient
    // « SignalQuestCache » et s'évinçaient mutuellement.
    init(api: APIClient, cache: DiskCache = DiskCache(folderName: "SignalQuestMarketCache")) {
        self.api = api
        self.cache = cache
    }

    // MARK: Registre

    func registry() async -> MarketRegistryPayload {
        if let payload = state.withLock({ $0.payload }) {
            refreshIfNeeded()
            return payload
        }
        // Premier appel : le cache disque récent, sinon le registre embarqué. On
        // n'attend jamais le réseau ici — la carte choisit son pays avec ce
        // registre avant son premier chargement, et une requête lente ou hors
        // ligne la retenait jusqu'à 30 s au démarrage (TRX-18).
        let task: Task<Resolved, Never> = state.withLock { st in
            if let localLoad = st.localLoad { return localLoad }
            let task = Task { [cache] in
                await Self.loadLocal(cache: cache)
            }
            st.localLoad = task
            return task
        }
        let resolved = await task.value
        let payload = state.withLock { st -> MarketRegistryPayload in
            if st.payload == nil {
                st.payload = resolved.payload
                st.isAuthoritative = resolved.isAuthoritative
            }
            return st.payload ?? resolved.payload
        }
        refreshIfNeeded()
        return payload
    }

    /// Réseau en arrière-plan tant qu'on sert le registre embarqué ; au plus une
    /// tentative par `retryInterval`. Les appels suivants voient le résultat.
    private func refreshIfNeeded(now: Date = Date()) {
        state.withLock { st in
            guard !st.isAuthoritative, st.refresh == nil else { return }
            if let last = st.lastAttempt, now.timeIntervalSince(last) < Self.retryInterval { return }
            st.lastAttempt = now
            st.refresh = Task { [weak self, api, cache, logger] in
                let fetched = await Self.fetchRemote(api: api, cache: cache, logger: logger)
                self?.state.withLock { st in
                    if let fetched {
                        st.payload = fetched
                        st.isAuthoritative = true
                    }
                    st.refresh = nil
                }
            }
        }
    }

    func market(forCode code: String?) async -> MarketRegistryEntry? {
        await registry().market(forCode: code)
    }

    // MARK: Résolution par position (portage exact d'Android)

    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let normalizedLongitude = Self.normalizeLongitude(longitude)
        let containing = locationAreas().candidates(
            latitude: latitude,
            longitude: normalizedLongitude
        )
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

    private static func loadLocal(cache: DiskCache) async -> Resolved {
        if let payload = try? await cache.read(MarketRegistryPayload.self, for: diskKey, maxAge: diskTTL),
           payload.canReplaceRadioReference(bundled) {
            return Resolved(payload: payload, isAuthoritative: true)
        }
        return Resolved(payload: bundled, isAuthoritative: false)
    }

    /// Registre du serveur, mis en cache disque (TTL 24 h) s'il vaut au moins
    /// la référence embarquée ; `nil` sinon.
    private static func fetchRemote(api: APIClient, cache: DiskCache, logger: Logger) async -> MarketRegistryPayload? {
        do {
            let payload = try await api.request(
                APIEndpoint(path: "/api/android/markets", authenticated: false),
                as: MarketRegistryPayload.self
            )
            guard payload.canReplaceRadioReference(bundled) else { return nil }
            try? await cache.write(payload, for: diskKey)
            return payload
        } catch {
            logger.debug("Registre marchés réseau indisponible: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

struct MarketLocationAreasFile: Decodable, Sendable {
    let areas: [MarketLocationArea]
    let franceHysteresis: [MarketLocationArea]

    private static let coastlineToleranceDegrees = 0.08

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

    /// Polygone exact d'abord, puis contour côtier le plus proche dans un rayon
    /// borné. Le second chemin compense seulement les petites îles omises par la
    /// simplification Natural Earth (New York/Istanbul, notamment).
    func candidates(latitude: Double, longitude: Double) -> [MarketLocationArea] {
        let exact = areas
            .filter { $0.contains(latitude: latitude, longitude: longitude) }
            .sorted { $0.boundingArea < $1.boundingArea }
        if !exact.isEmpty { return exact }

        let nearest = areas.compactMap { area -> (MarketLocationArea, Double)? in
            guard let distance = area.boundaryDistanceSquared(
                latitude: latitude,
                longitude: longitude,
                maximumDistance: Self.coastlineToleranceDegrees
            ) else { return nil }
            return (area, distance)
        }.min { $0.1 < $1.1 }
        return nearest.map { [$0.0] } ?? []
    }
}

struct MarketLocationArea: Decodable, Sendable {
    let market: String
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    /// Sommets en `[lat, lng]`, comme Android.
    let polygon: [[Double]]?

    var boundingArea: Double {
        max(0, north - south) * max(0, east - west)
    }

    /// Portage exact de MarketRegistry.kt : bbox d'abord, puis ray-casting
    /// si un polygone est déclaré.
    func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= south, latitude <= north,
              longitude >= west, longitude <= east else { return false }
        guard let polygon, !polygon.isEmpty else { return true }
        return Self.containsPoint(polygon, latitude: latitude, longitude: longitude)
    }

    func boundaryDistanceSquared(
        latitude: Double,
        longitude: Double,
        maximumDistance: Double
    ) -> Double? {
        guard latitude >= south - maximumDistance,
              latitude <= north + maximumDistance,
              longitude >= west - maximumDistance,
              longitude <= east + maximumDistance else { return nil }

        guard let polygon, !polygon.isEmpty else {
            let clampedLatitude = min(max(latitude, south), north)
            let clampedLongitude = min(max(longitude, west), east)
            let distance = Self.squaredDistance(
                latitude,
                longitude,
                clampedLatitude,
                clampedLongitude
            )
            return distance <= maximumDistance * maximumDistance ? distance : nil
        }

        var closest = Double.infinity
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            guard current.count >= 2, previous.count >= 2 else {
                previous = current
                continue
            }
            closest = min(
                closest,
                Self.squaredDistanceToSegment(
                    latitude: latitude,
                    longitude: longitude,
                    startLatitude: previous[0],
                    startLongitude: previous[1],
                    endLatitude: current[0],
                    endLongitude: current[1]
                )
            )
            previous = current
        }
        return closest <= maximumDistance * maximumDistance ? closest : nil
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

    private static func squaredDistanceToSegment(
        latitude: Double,
        longitude: Double,
        startLatitude: Double,
        startLongitude: Double,
        endLatitude: Double,
        endLongitude: Double
    ) -> Double {
        let latitudeDelta = endLatitude - startLatitude
        let longitudeDelta = endLongitude - startLongitude
        let segmentLengthSquared = latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta
        guard segmentLengthSquared > 0 else {
            return squaredDistance(latitude, longitude, startLatitude, startLongitude)
        }
        let projection = (
            (latitude - startLatitude) * latitudeDelta +
                (longitude - startLongitude) * longitudeDelta
        ) / segmentLengthSquared
        let boundedProjection = min(max(projection, 0), 1)
        return squaredDistance(
            latitude,
            longitude,
            startLatitude + boundedProjection * latitudeDelta,
            startLongitude + boundedProjection * longitudeDelta
        )
    }

    private static func squaredDistance(
        _ firstLatitude: Double,
        _ firstLongitude: Double,
        _ secondLatitude: Double,
        _ secondLongitude: Double
    ) -> Double {
        let latitudeDelta = firstLatitude - secondLatitude
        let longitudeDelta = firstLongitude - secondLongitude
        return latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta
    }
}
