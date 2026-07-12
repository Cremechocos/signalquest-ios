import Foundation

/// Métrique comparée entre opérateurs dans la sheet « Autour de toi ».
enum NearbyOperatorMetric: Equatable, Sendable {
    /// Débit descendant médian (Mb/s) — plus haut = mieux.
    case download
    /// RSRP médian (dBm) — plus haut (proche de zéro) = mieux.
    case signal

    var unit: String {
        switch self {
        case .download: return "Mb/s"
        case .signal: return "dBm"
        }
    }

    /// Fragment inséré dans l'intro (« … la communauté a mesuré {…} … »).
    var introMetric: String {
        switch self {
        case .download: return "le débit médian"
        case .signal: return "le signal médian"
        }
    }

    var icon: String {
        switch self {
        case .download: return "speedometer"
        case .signal: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Statistique d'un opérateur pour une métrique donnée, autour de la position.
/// `value` est en Mb/s (download) ou en dBm (signal).
struct OperatorMetricStat: Identifiable, Equatable, Sendable {
    let operatorName: String
    let value: Int
    let sampleCount: Int
    /// Détail secondaire (ex. « 24 ms » pour le débit), ou nil.
    let detail: String?

    var id: String { operatorName }
}
