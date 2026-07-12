import Foundation
import CoreLocation

/// Verdict de qualité réseau COMMUNAUTAIRE pour l'opérateur de la SIM, autour
/// d'une position donnée.
///
/// Le niveau retenu (`level`) est LE PIRE des deux bandes mesurées — couverture
/// (RSRP médian) et débit (Mb/s descendant médian) — car un réseau « au top »
/// suppose à la fois un bon signal ET un bon débit. Les deux bandes composantes
/// et leurs médianes restent exposées pour l'affichage (transparence).
struct NearbyNetworkQuality: Equatable, Sendable {
    /// Verdict combiné = pire de `signalBand` et `speedBand`.
    let level: CoverageQualityBand
    let signalBand: CoverageQualityBand
    let speedBand: CoverageQualityBand
    let medianRsrpDbm: Int?
    let medianDownloadMbps: Int?
    let operatorLabel: String
    let operatorKey: String
    /// Nombre de mesures communautaires (RSRP + débit) ayant servi au verdict.
    let sampleCount: Int
    /// Rayon d'analyse (m) autour de la position — pour l'explication à l'écran.
    let radiusMeters: Int
}

protocol NearbyNetworkQualityServicing: Sendable {
    /// Calcule le verdict pour l'opérateur de la SIM autour de la position.
    /// Renvoie `nil` si l'opérateur n'a pas pu être identifié ou si la zone n'a
    /// pas assez de mesures communautaires pour trancher.
    ///
    /// - Parameters:
    ///   - isCellular: connexion active cellulaire (autorise la résolution par IP/ASN).
    ///   - simMnc: MNC de la SIM lu par CoreTelephony (repli quand l'IP est indisponible).
    ///   - maxAge: fraîcheur du cache de tuiles (`0` = données fraîches forcées).
    func verdict(
        latitude: Double,
        longitude: Double,
        isCellular: Bool,
        simMnc: Int?,
        maxAge: TimeInterval?
    ) async -> NearbyNetworkQuality?

    /// Classe les opérateurs autour de la position pour une métrique (débit ou
    /// signal), par valeur décroissante. Vide si la zone est sans mesures.
    func operatorRanking(
        metric: NearbyOperatorMetric,
        latitude: Double,
        longitude: Double,
        maxAge: TimeInterval?
    ) async -> [OperatorMetricStat]
}

final class NearbyNetworkQualityService: NearbyNetworkQualityServicing {
    private let map: MapSnapshotServicing
    private let markets: MarketRegistryServicing
    private let networkOperator: NetworkOperatorServicing

    /// Rayon d'analyse : on ne retient que les mesures dont la distance RÉELLE au
    /// centre est ≤ 1 km. La fenêtre `halfSpan` ci-dessous ne sert qu'à choisir les
    /// tuiles à récupérer (leur maille est bien plus grossière que 1 km).
    private static let radiusMeters: Double = 1000
    /// Demi-fenêtre géographique englobant le cercle de 1 km (métropole ; l'E-O se
    /// resserre avec la latitude mais reste ≥ 1 km — le filtrage distance tranche).
    private static let halfSpanLat = 0.011
    private static let halfSpanLng = 0.016
    private static let tileZoom: Double = 14
    /// Sous ce nombre de points, la médiane n'est pas jugée représentative : la
    /// métrique correspondante est ignorée (bande `.unknown`).
    private static let minSamplesPerMetric = 3

    init(
        map: MapSnapshotServicing,
        markets: MarketRegistryServicing,
        networkOperator: NetworkOperatorServicing
    ) {
        self.map = map
        self.markets = markets
        self.networkOperator = networkOperator
    }

    func verdict(
        latitude: Double,
        longitude: Double,
        isCellular: Bool,
        simMnc: Int?,
        maxAge: TimeInterval?
    ) async -> NearbyNetworkQuality? {
        guard let market = await markets.marketForLocation(latitude: latitude, longitude: longitude),
              let op = await resolveOperator(market: market, isCellular: isCellular, simMnc: simMnc)
        else { return nil }

        let bounds = MapBounds(
            north: latitude + Self.halfSpanLat,
            south: latitude - Self.halfSpanLat,
            east: longitude + Self.halfSpanLng,
            west: longitude - Self.halfSpanLng
        )

        // Couverture (RSRP) et speedtests (débit) filtrés sur l'opérateur SIM,
        // en parallèle. `days: 0` = tout l'historique disponible pour maximiser la
        // représentativité de la médiane (la couverture évolue lentement).
        async let coverageTask = map.coverageTiles(
            bounds: bounds, zoom: Self.tileZoom, market: market.code,
            operatorName: op.key, days: 0, bands: [], maxAge: maxAge
        )
        async let speedTask = map.speedtestTiles(
            bounds: bounds, zoom: Self.tileZoom, market: market.code,
            operatorName: op.key, days: 0, bands: [], maxAge: maxAge
        )

        // Filtrage par distance réelle au centre (les tuiles débordent du rayon).
        let center = CLLocation(latitude: latitude, longitude: longitude)
        func isWithinRadius(lat: Double, lng: Double) -> Bool {
            center.distance(from: CLLocation(latitude: lat, longitude: lng)) <= Self.radiusMeters
        }

        let rsrps = ((try? await coverageTask) ?? [])
            .flatMap(\.points)
            .filter { isWithinRadius(lat: $0.lat, lng: $0.lng) }
            .compactMap(\.rsrp)
            // Écarte le bruit : > -44 dBm impossible (3GPP), < -140 dBm aberrant.
            .filter { $0 <= -44 && $0 >= -140 }
        let downloads = ((try? await speedTask) ?? [])
            .flatMap(\.markers)
            .filter { isWithinRadius(lat: $0.lat, lng: $0.lng) }
            .map(\.downloadMbps)
            .filter { $0 > 0 }

        let medianRsrp = Self.median(rsrps, minCount: Self.minSamplesPerMetric)
        let medianDownload = Self.median(downloads, minCount: Self.minSamplesPerMetric)

        let signalBand = CoverageQualityBand.band(for: medianRsrp)
        let speedBand = CoverageQualityBand.band(forDownloadMbps: medianDownload)
        let combined = CoverageQualityBand.worst(signalBand, speedBand)
        guard combined != .unknown else { return nil }

        return NearbyNetworkQuality(
            level: combined,
            signalBand: signalBand,
            speedBand: speedBand,
            medianRsrpDbm: medianRsrp.map { Int($0.rounded()) },
            medianDownloadMbps: medianDownload.map { Int($0.rounded()) },
            operatorLabel: op.shortLabel.isEmpty ? op.label : op.shortLabel,
            operatorKey: op.key,
            sampleCount: rsrps.count + downloads.count,
            radiusMeters: Int(Self.radiusMeters)
        )
    }

    func operatorRanking(
        metric: NearbyOperatorMetric,
        latitude: Double,
        longitude: Double,
        maxAge: TimeInterval?
    ) async -> [OperatorMetricStat] {
        guard let market = await markets.marketForLocation(latitude: latitude, longitude: longitude) else { return [] }
        let bounds = MapBounds(
            north: latitude + Self.halfSpanLat,
            south: latitude - Self.halfSpanLat,
            east: longitude + Self.halfSpanLng,
            west: longitude - Self.halfSpanLng
        )

        switch metric {
        case .download:
            // Un seul appel « tous opérateurs » : les speedtests portent l'opérateur,
            // on regroupe côté client.
            let center = CLLocation(latitude: latitude, longitude: longitude)
            let markers = ((try? await map.speedtestTiles(
                bounds: bounds, zoom: Self.tileZoom, market: market.code,
                operatorName: "ALL", days: 0, bands: [], maxAge: maxAge
            )) ?? [])
                .flatMap(\.markers)
                .filter { center.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) <= Self.radiusMeters }

            var groups: [String: [AndroidSpeedtestMarker]] = [:]
            for marker in markers {
                guard let name = marker.`operator`?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                groups[name, default: []].append(marker)
            }
            return groups.compactMap { name, items -> OperatorMetricStat? in
                let downloads = items.map(\.downloadMbps).filter { $0 > 0 }
                guard let median = Self.median(downloads, minCount: 1) else { return nil }
                let pings = items.compactMap(\.pingMs).filter { $0 > 0 }
                let detail = Self.median(pings, minCount: 1).map { "\(Int($0.rounded())) ms" }
                return OperatorMetricStat(
                    operatorName: name, value: Int(median.rounded()),
                    sampleCount: items.count, detail: detail
                )
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.sampleCount > $1.sampleCount }

        case .signal:
            // Les points de couverture ne portent pas l'opérateur : un appel filtré
            // par opérateur du marché, en parallèle.
            let marketCode = market.code
            let lat = latitude
            let lng = longitude
            let stats = await withTaskGroup(of: OperatorMetricStat?.self) { group in
                for op in market.selectableOperators {
                    let key = op.key
                    let label = op.shortLabel.isEmpty ? op.label : op.shortLabel
                    group.addTask { [map] in
                        let points = ((try? await map.coverageTiles(
                            bounds: bounds, zoom: Self.tileZoom, market: marketCode,
                            operatorName: key, days: 0, bands: [], maxAge: maxAge
                        )) ?? [])
                            .flatMap(\.points)
                        let origin = CLLocation(latitude: lat, longitude: lng)
                        let rsrps = points
                            .filter { origin.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) <= Self.radiusMeters }
                            .compactMap(\.rsrp)
                            .filter { $0 <= -44 && $0 >= -140 }
                        guard let median = Self.median(rsrps, minCount: Self.minSamplesPerMetric) else { return nil }
                        return OperatorMetricStat(
                            operatorName: label, value: Int(median.rounded()),
                            sampleCount: rsrps.count, detail: nil
                        )
                    }
                }
                var result: [OperatorMetricStat] = []
                for await stat in group {
                    if let stat { result.append(stat) }
                }
                return result
            }
            return stats.sorted { $0.value != $1.value ? $0.value > $1.value : $0.sampleCount > $1.sampleCount }
        }
    }

    /// Identifie l'opérateur de la SIM : IP/ASN d'abord (fiable en cellulaire,
    /// écarté sous VPN où l'IP refléterait le tunnel ; non tenté sur WiFi où l'IP
    /// pointerait le FAI fixe), puis repli sur le MNC de la SIM.
    private func resolveOperator(
        market: MarketRegistryEntry,
        isCellular: Bool,
        simMnc: Int?
    ) async -> MarketRegistryOperator? {
        if isCellular {
            let viaVpn = VPNDetector.isActive()
            if let detected = await networkOperator.resolve(viaVpn: viaVpn),
               detected.viaVpn != true,
               let entry = market.operatorEntry(forKey: detected.operatorKey) {
                return entry
            }
        }
        if let simMnc,
           let entry = market.selectableOperators.first(where: { $0.mncs.contains(simMnc) }) {
            return entry
        }
        return nil
    }

    private static func median(_ values: [Double], minCount: Int) -> Double? {
        guard values.count >= minCount else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

extension CoverageQualityBand {
    /// Rang qualité (plus grand = meilleur) ; `nil` pour `.unknown` (hors calcul).
    var qualityRank: Int? {
        switch self {
        case .excellent: return 4
        case .good: return 3
        case .fair: return 2
        case .weak: return 1
        case .poor: return 0
        case .unknown: return nil
        }
    }

    /// La PIRE de deux bandes ; ignore `.unknown` (une seule métrique dispo →
    /// on la retient). `.unknown` seulement si les deux le sont.
    static func worst(_ a: CoverageQualityBand, _ b: CoverageQualityBand) -> CoverageQualityBand {
        switch (a.qualityRank, b.qualityRank) {
        case let (ra?, rb?): return ra <= rb ? a : b
        case (_?, nil): return a
        case (nil, _?): return b
        case (nil, nil): return .unknown
        }
    }

    /// Bande qualité déduite d'un débit descendant médian (Mb/s). Seuils alignés
    /// sur les libellés de débit de l'app (≥300 excellent · 100 bon · 30 correct ·
    /// 10 faible · sinon très faible).
    static func band(forDownloadMbps mbps: Double?) -> CoverageQualityBand {
        guard let mbps, mbps > 0 else { return .unknown }
        switch mbps {
        case 300...: return .excellent
        case 100..<300: return .good
        case 30..<100: return .fair
        case 10..<30: return .weak
        default: return .poor
        }
    }

    /// Titre de la pastille d'accueil (« Réseau … ») pour un verdict de qualité.
    var homeNetworkTitle: String {
        switch self {
        case .excellent: return "Réseau au top"
        case .good: return "Bon réseau"
        case .fair: return "Réseau correct"
        case .weak: return "Réseau faible"
        case .poor: return "Réseau très faible"
        case .unknown: return "Réseau"
        }
    }
}
