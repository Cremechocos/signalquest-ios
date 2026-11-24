import SwiftUI
import CoreLocation
import MapKit

/// Métrique de la couche Débits (IOS-037, comme Android) : débit descendant (échelle du contrat
/// commun), débit montant ou ping. Montant et ping reprennent les seuils d'Android, avec les six
/// teintes du contrat, sans cyan ni bleu (choix d'Alexandre du 12/11 pour l'échelle des débits).
enum SpeedtestMapMetric: String, CaseIterable, Identifiable, Sendable {
    case download, upload, ping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: String(localized: "Débit ↓")
        case .upload: String(localized: "Débit ↑")
        case .ping: String(localized: "Ping")
        }
    }

    /// Palier d'une valeur, sur les teintes du contrat ; `nil` sans mesure de cette métrique.
    func tier(for feature: SpeedtestFeature) -> SQQualityScale.Throughput? {
        switch self {
        case .download:
            return SQQualityScale.Throughput(mbps: feature.downloadMbps)
        case .upload:
            guard let mbps = feature.uploadMbps, mbps.isFinite, mbps >= 0 else { return nil }
            return Self.uploadTier(mbps)
        case .ping:
            guard let ms = feature.pingMs, ms.isFinite, ms > 0 else { return nil }
            return Self.pingTier(ms)
        }
    }

    func hex(for feature: SpeedtestFeature) -> UInt32 {
        tier(for: feature)?.hex ?? SQQualityScale.unknownHex
    }

    static func uploadTier(_ mbps: Double) -> SQQualityScale.Throughput {
        switch mbps {
        case 50...: .exceptional
        case 20..<50: .veryGood
        case 10..<20: .good
        case 5..<10: .medium
        case 2..<5: .slow
        default: .verySlow
        }
    }

    /// Plus bas, meilleur : sous 20 ms le meilleur palier, 150 ms et plus le pire.
    static func pingTier(_ ms: Double) -> SQQualityScale.Throughput {
        switch ms {
        case ..<20: .exceptional
        case 20..<40: .veryGood
        case 40..<60: .good
        case 60..<90: .medium
        case 90..<150: .slow
        default: .verySlow
        }
    }

    /// Lignes de légende, du meilleur au pire, comme Android : « ≥ 300 Mb/s », « < 20 ms ».
    var legendRows: [(hex: UInt32, label: String)] {
        func mbps(_ value: Double) -> String { value.formatted(.number.grouping(.automatic)) }
        switch self {
        case .download:
            return SQQualityScale.Throughput.allCases.map { tier in
                tier == .verySlow
                    ? (tier.hex, String(localized: "< \(mbps(SQQualityScale.Throughput.slow.lowerBoundMbps)) Mb/s"))
                    : (tier.hex, String(localized: "≥ \(mbps(tier.lowerBoundMbps)) Mb/s"))
            }
        case .upload:
            let bounds: [(SQQualityScale.Throughput, Double)] = [(.exceptional, 50), (.veryGood, 20), (.good, 10), (.medium, 5), (.slow, 2)]
            return bounds.map { ($0.0.hex, String(localized: "≥ \(mbps($0.1)) Mb/s")) }
                + [(SQQualityScale.Throughput.verySlow.hex, String(localized: "< \(mbps(2)) Mb/s"))]
        case .ping:
            let bounds: [(SQQualityScale.Throughput, Int)] = [(.exceptional, 20), (.veryGood, 40), (.good, 60), (.medium, 90), (.slow, 150)]
            return bounds.map { ($0.0.hex, String(localized: "< \($0.1) ms")) }
                + [(SQQualityScale.Throughput.verySlow.hex, String(localized: "≥ \(150) ms"))]
        }
    }
}

/// Point speedtest rendu en couche dense (MKOverlay Core Graphics). Distinct des
/// annotations-vues : permet d'afficher TOUS les points (milliers) sans cluster
/// ni cap, coloré par débit — comportement identique à Android.
struct SpeedtestFeature: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let downloadMbps: Double
    let uploadMbps: Double?
    let pingMs: Double?
    let tech: String?
    let band: Int?
    let frequency: String?
    let timestamp: Date?

    static func == (lhs: SpeedtestFeature, rhs: SpeedtestFeature) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.downloadMbps == rhs.downloadMbps &&
        lhs.uploadMbps == rhs.uploadMbps &&
        lhs.pingMs == rhs.pingMs &&
        lhs.tech == rhs.tech &&
        lhs.band == rhs.band &&
        lhs.frequency == rhs.frequency &&
        lhs.timestamp == rhs.timestamp
    }
}

struct CoverageHeatFeature: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let weight: Double
    /// Clé de regroupement — une source/couche par clé (bande RSRP ou génération).
    let colorKey: String
    /// Couleur de la pastille (0xRRGGBB), figée selon le mode de coloration courant.
    let colorHex: UInt32
    /// Opacité réduite pour les bandes « inconnu » (RSRP) / « aucun » (génération).
    let dimmed: Bool
    /// « Sans réseau constaté » : pastille hachurée (contrat quality-scale v1).
    var hatched: Bool = false
    /// Rang de génération (5..2, 0 = aucun/RSRP) — pilote le z-order en mode « par
    /// génération » : les features de rang supérieur sont dessinées EN DERNIER (au
    /// -dessus), donc un vrai 5G n'est jamais recouvert par une 4G chevauchante. Vaut
    /// 0 en mode RSRP (le tri est alors neutralisé). Défaut `0` → l'init memberwise
    /// reste rétro-compatible ; volontairement absent de `==` (covariant de `colorHex`
    /// en mode génération, comme `dimmed` déjà omis).
    var generationRank: Int = 0

    static func == (lhs: CoverageHeatFeature, rhs: CoverageHeatFeature) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.weight == rhs.weight &&
        lhs.colorKey == rhs.colorKey &&
        lhs.colorHex == rhs.colorHex
    }
}
