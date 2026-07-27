import SwiftUI
import CoreLocation
import MapKit

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
