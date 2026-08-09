import CarPlay
import MapKit

/// Charge les couches de la carte CarPlay et les convertit en marqueurs.
///
/// Réutilise les mêmes services — donc les mêmes tuiles et le même `TileCache` —
/// que la carte iPhone : ce qui a déjà été chargé sur le téléphone ne sera pas
/// redemandé au réseau dans la voiture.
///
/// Volontairement plus permissif que `MapExplorerViewModel` : pas de filtres par
/// bande, par technologie ni par statut d'activation. Régler ça sur un écran de
/// véhicule n'a pas de sens, et chaque critère supplémentaire est un critère de
/// plus qui peut faire disparaître les antennes sans que le conducteur comprenne
/// pourquoi.
@MainActor
final class CarPlayLayerController {
    struct Layers {
        var antennas: [MapAnnotationPayload] = []
        var outages: [MapAnnotationPayload] = []
        var planned: [MapAnnotationPayload] = []
        var coverage: [CoverageHeatFeature] = []
        var speedtests: [SpeedtestFeature] = []

        /// Données SOURCES, indexées par l'identifiant du marqueur.
        ///
        /// `MapAnnotationPayload` ne transporte ni les services touchés par une
        /// panne, ni le statut d'activation d'une évolution. Les conserver ici
        /// évite un aller-retour réseau pour réafficher ce qu'on vient de
        /// charger, au moment précis où le conducteur attend une réponse.
        var outageSources: [String: OutageSiteLive] = [:]
        var plannedSources: [String: PlannedSiteLive] = [:]

        /// Tous les marqueurs-vues, dans l'ordre d'empilement voulu : les
        /// antennes en dessous, les incidents au-dessus.
        var annotations: [MapAnnotationPayload] { antennas + planned + outages }
    }

    private let map: MapSnapshotServicing

    init(map: MapSnapshotServicing) {
        self.map = map
    }

    /// Charge toutes les couches actives EN PARALLÈLE, chacune isolée : une
    /// couche qui échoue (réseau coupé, tuile absente) laisse les autres
    /// s'afficher. Une carte partielle vaut mieux qu'une carte vide.
    func load(bounds: MapBounds,
              zoom: Double,
              filters: Set<MapDisplayItem.Kind>,
              market: String,
              operatorKey: String) async -> Layers {
        async let antennaTiles = filters.contains(.antenna)
            ? (try? await map.antennaTiles(bounds: bounds, zoom: zoom, market: market,
                                           operatorName: operatorKey, withAzimuth: true, bands: [])) ?? []
            : []
        async let coverageTiles = filters.contains(.coverage)
            ? (try? await map.coverageTiles(bounds: bounds, zoom: zoom, market: market,
                                            operatorName: operatorKey, days: 90, bands: [], maxAge: nil)) ?? []
            : []
        async let speedtestTiles = filters.contains(.speedtest)
            ? (try? await map.speedtestTiles(bounds: bounds, zoom: zoom, market: market,
                                             operatorName: operatorKey, days: 90, bands: [], maxAge: nil)) ?? []
            : []
        async let outages = filters.contains(.outage)
            ? (try? await map.outageSites(market: market, operatorName: operatorKey,
                                          territory: nil, bands: [])) ?? []
            : []
        async let planned = filters.contains(.planned)
            ? (try? await map.plannedSites(market: market, operatorName: operatorKey,
                                           territory: nil, bands: [])) ?? []
            : []

        var layers = Layers()
        layers.antennas = Self.antennaPayloads(from: await antennaTiles, zoom: zoom)
        layers.coverage = Self.coverageFeatures(from: await coverageTiles)
        layers.speedtests = Self.speedtestFeatures(from: await speedtestTiles)
        let loadedOutages = await outages
        let loadedPlanned = await planned
        layers.outages = Self.outagePayloads(from: loadedOutages, within: bounds)
        layers.planned = Self.plannedPayloads(from: loadedPlanned, within: bounds)
        layers.outageSources = Dictionary(loadedOutages.map { ("outage-\($0.id)", $0) },
                                          uniquingKeysWith: { first, _ in first })
        layers.plannedSources = Dictionary(loadedPlanned.map { ("planned-\($0.id)", $0) },
                                           uniquingKeysWith: { first, _ in first })
        return layers
    }

    // MARK: - Conversion (pure, donc testable sans réseau)

    static func antennaPayloads(from tiles: [AndroidAntennaTileResponse], zoom: Double) -> [MapAnnotationPayload] {
        var seen = Set<String>()
        var payloads: [MapAnnotationPayload] = []
        // Les tuiles se recouvrent en bordure : sans dédoublonnage, un même site
        // apparaît deux fois et son marqueur clignote au rafraîchissement.
        for tile in tiles {
            for marker in tile.markers where seen.insert(marker.id).inserted {
                payloads.append(payload(for: marker, zoom: zoom))
            }
            for cluster in tile.clusters {
                payloads.append(
                    MapAnnotationPayload(
                        id: "antenna-cluster-\(cluster.id)",
                        kind: .antenna,
                        title: "\(cluster.count)",
                        subtitle: String(localized: "sites"),
                        coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lng),
                        metric: nil,
                        backendId: cluster.id,
                        details: nil,
                        antennaId: nil,
                        clusterCount: cluster.count,
                        azimuths: [],
                        showsAzimuths: false
                    )
                )
            }
        }
        return payloads
    }

    static func payload(for marker: AndroidAntennaMarker, zoom: Double) -> MapAnnotationPayload {
        let operators = marker.operators.isEmpty
            ? [marker.operator].compactMap { $0 }
            : marker.operators
        return MapAnnotationPayload(
            id: "antenna-\(marker.id)",
            kind: .antenna,
            title: String(localized: "Site \(marker.supId ?? marker.id)"),
            subtitle: [operators.joined(separator: "/"),
                       marker.technologies.prefix(3).joined(separator: "/")]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
            metric: nil,
            backendId: marker.supId ?? marker.id,
            details: nil,
            antennaId: marker.id,
            clusterCount: nil,
            azimuths: marker.azimuts,
            // En dessous de z13 les lobes se chevauchent en une tache illisible —
            // même seuil que la carte iPhone.
            showsAzimuths: zoom >= 13,
            tint: SQBrand.operatorColor(operators.first),
            hasEnb: marker.hasEnb,
            hasGnb: marker.hasGnb,
            has5G: !marker.operators5G.isEmpty,
            azimuthReachPoints: SQMapProjection.azimuthReach(forZoom: zoom),
            operatorTints: operators.map { SQBrand.operatorColor($0) }
        )
    }

    static func coverageFeatures(from tiles: [AndroidCoverageTileResponse]) -> [CoverageHeatFeature] {
        var seen = Set<String>()
        var features: [CoverageHeatFeature] = []
        for tile in tiles {
            for point in tile.points where seen.insert(point.id).inserted {
                features.append(
                    CoverageHeatFeature(
                        id: point.id,
                        coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                        weight: 1,
                        colorKey: point.tech ?? "unknown",
                        colorHex: SQNetworkColors.rsrpHex(point.rsrp),
                        // Une mesure sans RSRP ne vaut pas une mesure mesurée :
                        // on l'atténue plutôt que de la faire passer pour un
                        // relevé fiable.
                        dimmed: point.rsrp == nil
                    )
                )
            }
        }
        return features
    }

    static func speedtestFeatures(from tiles: [AndroidSpeedtestTileResponse]) -> [SpeedtestFeature] {
        var seen = Set<String>()
        var features: [SpeedtestFeature] = []
        for tile in tiles {
            for marker in tile.markers where seen.insert(marker.id).inserted {
                features.append(
                    SpeedtestFeature(
                        id: marker.id,
                        coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lng),
                        downloadMbps: marker.downloadMbps,
                        uploadMbps: marker.uploadMbps,
                        pingMs: marker.pingMs,
                        tech: marker.tech,
                        band: marker.band,
                        frequency: marker.frequency,
                        timestamp: marker.timestamp
                    )
                )
            }
        }
        return features
    }

    /// Pannes et évolutions arrivent par territoire, pas par tuile : on les borne
    /// nous-mêmes à la zone visible, sinon on épinglerait des incidents situés à
    /// des centaines de kilomètres.
    static func outagePayloads(from sites: [OutageSiteLive], within bounds: MapBounds) -> [MapAnnotationPayload] {
        sites.compactMap { site in
            guard let lat = site.lat, let lon = site.lon, bounds.contains(lat: lat, lon: lon) else { return nil }
            return MapAnnotationPayload(
                id: "outage-\(site.id)",
                kind: .outage,
                title: site.siteId ?? String(localized: "Site en panne"),
                subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                metric: nil,
                backendId: site.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: SQColor.danger
            )
        }
    }

    static func plannedPayloads(from sites: [PlannedSiteLive], within bounds: MapBounds) -> [MapAnnotationPayload] {
        sites.compactMap { site in
            guard let lat = site.lat, let lon = site.lon, bounds.contains(lat: lat, lon: lon) else { return nil }
            let status = site.activation?.status ?? .planned
            return MapAnnotationPayload(
                id: "planned-\(site.id)",
                kind: .planned,
                title: site.codeSite ?? String(localized: "Site prévisionnel"),
                subtitle: [site.operator, site.commune].compactMap { $0 }.joined(separator: " · "),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                metric: site.technologies.joined(separator: " / "),
                backendId: site.codeSite ?? site.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                plannedStatus: status
            )
        }
    }
}
