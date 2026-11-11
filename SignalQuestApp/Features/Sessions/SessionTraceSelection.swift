import Foundation
import CoreLocation

/// Antennes desservantes d'un même site et d'un même opérateur, réunies en une
/// seule pastille : la 4G (eNB) et la 5G (gNB) d'un support étaient dessinées
/// l'une sur l'autre et passaient pour une antenne manquante.
struct ServingSiteGroup: Identifiable, Equatable {
    let id: String
    /// La mieux établie d'abord (identifiée, puis hypothèse au meilleur score).
    let antennas: [ServingAntenna]

    var primary: ServingAntenna { antennas[0] }
    var coordinate: CLLocationCoordinate2D { primary.coordinate }
    /// Clés des nœuds de ce site (`enb ?? gnb` des points servis).
    var nodeKeys: Set<String> { Set(antennas.compactMap(\.lookupKey)) }

    /// Un groupe par site et par opérateur, seulement pour les antennes placées.
    static func groups(_ antennas: [ServingAntenna]) -> [ServingSiteGroup] {
        var order: [String] = []
        var members: [String: [ServingAntenna]] = [:]
        for antenna in antennas where antenna.hasValidCoordinate {
            let site = antenna.siteId.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(format: "%.5f,%.5f", antenna.lat, antenna.lng)
            let key = "\(site)|\((antenna.operatorName ?? "").uppercased())"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(antenna)
        }
        return order.map { key in
            ServingSiteGroup(id: key, antennas: members[key]!.sorted(by: Self.isBetter))
        }
    }

    private static func isBetter(_ a: ServingAntenna, _ b: ServingAntenna) -> Bool {
        let ra = rank(a.status), rb = rank(b.status)
        if ra != rb { return ra < rb }
        return (a.confidenceScore ?? -1) > (b.confidenceScore ?? -1)
    }

    private static func rank(_ status: ServingStatus) -> Int {
        switch status {
        case .identified: return 0
        case .hypothesis: return 1
        case .proximity: return 2
        case .unknown: return 3
        }
    }

    /// Nœuds mesurés sur le trajet qu'aucune antenne placée ne couvre, le plus
    /// mesuré d'abord : site introuvable, plafond du serveur ou résultat sans
    /// position. On le dit au lieu de laisser croire que la carte est complète.
    static func unresolvedNodeKeys(points: [CoverageSessionPoint], antennas: [ServingAntenna]) -> [String] {
        let located = Set(antennas.filter(\.hasValidCoordinate).compactMap(\.lookupKey))
        var counts: [String: Int] = [:]
        for point in points {
            guard let key = point.nodeKey, !located.contains(key) else { continue }
            counts[key, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Ce que la carte plein écran dessine pour la sélection : traits vers l'antenne,
/// anneaux TA des points du même nœud, cône du secteur supposé et zone estimée.
/// Rien n'est dessiné sans sélection (choix d'Alexandre du 11/11).
struct SessionTraceHighlight {
    struct Ring {
        let center: CLLocationCoordinate2D
        let radiusMeters: Double
        /// L'anneau du point touché, tracé plus fort que les autres.
        let emphasized: Bool
    }

    /// Change avec la sélection : la carte ne redessine que là.
    let id: String
    var links: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
    var rings: [Ring] = []
    var cones: [[CLLocationCoordinate2D]] = []
    var estimates: [ServingAntenna.EstimatedSite] = []

    /// Au-delà, la carte devient illisible et le rendu ralentit.
    static let ringLimit = 60
    static let linkLimit = 80
    /// Ouverture d'un secteur macro courant, faute d'ouverture servie.
    static let sectorBeamwidthDeg: Double = 65

    /// Point touché : un trait vers son antenne, les anneaux TA de tous les points
    /// du même nœud (le sien en fort) et le secteur supposé de l'antenne.
    static func forPoint(_ point: CoverageSessionPoint, in points: [CoverageSessionPoint],
                         groups: [ServingSiteGroup]) -> SessionTraceHighlight {
        var highlight = SessionTraceHighlight(id: "point|\(point.id)")
        guard let key = point.nodeKey else { return highlight }
        highlight.rings = taRings(nodeKeys: [key], in: points, emphasizing: point.id)
        if let group = groups.first(where: { $0.nodeKeys.contains(key) }) {
            highlight.links = [(point.coordinate, group.coordinate)]
            highlight.add(group: group, served: points.filter { $0.nodeKey == key })
        }
        return highlight
    }

    /// Antenne touchée : des traits vers les points qu'elle sert, les anneaux TA
    /// de ces points, son secteur supposé et sa position estimée.
    static func forGroup(_ group: ServingSiteGroup, in points: [CoverageSessionPoint]) -> SessionTraceHighlight {
        var highlight = SessionTraceHighlight(id: "site|\(group.id)")
        let keys = group.nodeKeys
        let served = points.filter { $0.hasValidCoordinate && $0.nodeKey.map(keys.contains) == true }
        highlight.links = thinned(served, cell: 0.0015, limit: linkLimit).map { (group.coordinate, $0.coordinate) }
        highlight.rings = taRings(nodeKeys: keys, in: points, emphasizing: nil)
        highlight.add(group: group, served: served)
        return highlight
    }

    private mutating func add(group: ServingSiteGroup, served: [CoverageSessionPoint]) {
        let origin = CLLocation(latitude: group.coordinate.latitude, longitude: group.coordinate.longitude)
        let farthest = served.filter(\.hasValidCoordinate)
            .map { origin.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) }
            .max() ?? 1_000
        let radius = min(max(farthest, 300), 5_000)
        var seenAzimuths = Set<Int>()
        for antenna in group.antennas {
            if let azimuth = antenna.sectorAzimuthDeg, seenAzimuths.insert(Int(azimuth.rounded())).inserted {
                cones.append(Self.cone(at: group.coordinate, azimuthDeg: azimuth, radiusMeters: radius))
            }
            if let estimate = antenna.estimatedSite { estimates.append(estimate) }
        }
    }

    /// Anneaux TA des points de ces nœuds. Un seul anneau par valeur de TA et par
    /// case d'environ 100 m : des points voisins au même TA tracent le même cercle.
    static func taRings(nodeKeys: Set<String>, in points: [CoverageSessionPoint],
                        emphasizing emphasizedId: String?) -> [Ring] {
        var seen = Set<String>()
        var candidates: [CoverageSessionPoint] = []
        var emphasized: CoverageSessionPoint?
        for point in points where point.hasValidCoordinate {
            guard let key = point.nodeKey, nodeKeys.contains(key), point.taDistanceMeters != nil else { continue }
            if point.id == emphasizedId { emphasized = point; continue }
            let cell = "\(point.timingAdvance ?? -1)|\(Int((point.lat * 1_000).rounded()))|\(Int((point.lng * 1_000).rounded()))"
            if seen.insert(cell).inserted { candidates.append(point) }
        }
        var rings = evenlySpaced(candidates, limit: ringLimit - (emphasized == nil ? 0 : 1)).map {
            Ring(center: $0.coordinate, radiusMeters: $0.taDistanceMeters ?? 0, emphasized: false)
        }
        if let emphasized, let radius = emphasized.taDistanceMeters {
            rings.append(Ring(center: emphasized.coordinate, radiusMeters: radius, emphasized: true))
        }
        return rings
    }

    /// Un point par case de `cell` degrés, puis au plus `limit`, répartis sur le trajet.
    static func thinned(_ points: [CoverageSessionPoint], cell: Double, limit: Int) -> [CoverageSessionPoint] {
        var seen = Set<String>()
        let unique = points.filter {
            seen.insert("\(Int(($0.lat / cell).rounded()))|\(Int(($0.lng / cell).rounded()))").inserted
        }
        return evenlySpaced(unique, limit: limit)
    }

    static func evenlySpaced<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[min(Int(Double($0) * step), items.count - 1)] }
    }

    /// Secteur en éventail : le sommet sur l'antenne, un arc tous les 5°.
    static func cone(at origin: CLLocationCoordinate2D, azimuthDeg: Double, radiusMeters: Double,
                     beamwidthDeg: Double = sectorBeamwidthDeg) -> [CLLocationCoordinate2D] {
        let half = beamwidthDeg / 2
        let steps = max(Int((beamwidthDeg / 5).rounded(.up)), 1)
        let arc = (0...steps).map { index in
            destination(from: origin, bearingDeg: azimuthDeg - half + beamwidthDeg * Double(index) / Double(steps),
                        meters: radiusMeters)
        }
        return [origin] + arc + [origin]
    }

    /// Point à `meters` de `origin` dans la direction `bearingDeg` (sphère terrestre).
    static func destination(from origin: CLLocationCoordinate2D, bearingDeg: Double, meters: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let delta = meters / radius
        let theta = bearingDeg * .pi / 180
        let phi1 = origin.latitude * .pi / 180
        let lambda1 = origin.longitude * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        return CLLocationCoordinate2D(latitude: phi2 * 180 / .pi, longitude: lambda2 * 180 / .pi)
    }
}

extension ServingAntenna {
    /// Indice du moteur d'identification, traduit. Un code inconnu n'est pas
    /// affiché : un identifiant brut (« operator_match ») ne dit rien à personne.
    static func evidenceLabel(_ code: String) -> String? {
        switch code {
        case "validation_found": return String(localized: "Déjà validée par la communauté")
        case "auto_validation", "cellid_auto_created", "pci_auto_created":
            return String(localized: "Identifiée automatiquement")
        case "operator_match": return String(localized: "Même opérateur que ta SIM")
        case "operator_mismatch": return String(localized: "Opérateur différent de ta SIM")
        case "frequency_match": return String(localized: "Fréquences présentes sur ce site")
        case "frequency_no_match": return String(localized: "Fréquences absentes de ce site")
        case "proximity_hypothesis": return String(localized: "Choisie par proximité")
        case "ta_absent_no_distance_prior": return String(localized: "Sans TA : distance non vérifiée")
        case "radio_identifiers_missing": return String(localized: "Identifiants radio absents")
        case "gps_missing": return String(localized: "Position GPS absente")
        case "location_accuracy_poor": return String(localized: "Position GPS imprécise")
        case "location_accuracy_medium": return String(localized: "Position GPS moyennement précise")
        case "location_stale", "cellinfo_stale": return String(localized: "Mesure ancienne")
        case "below_plausibility_floor": return String(localized: "Score sous le seuil de plausibilité")
        default: return nil
        }
    }

    /// Indices lisibles de l'antenne, sans doublon.
    var evidenceLabels: [String] {
        var seen = Set<String>()
        return evidence.compactMap(Self.evidenceLabel).filter { seen.insert($0).inserted }
    }
}
