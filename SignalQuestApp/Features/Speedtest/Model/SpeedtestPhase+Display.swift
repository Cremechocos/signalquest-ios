import SwiftUI

extension SpeedtestPhase {
    var displayTitle: String {
        switch self {
        case .idle: return String(localized: "Prêt")
        case .ping: return "Ping"
        case .download: return String(localized: "Réception")
        case .upload: return "Envoi"
        case .saving: return "Sync"
        case .finished: return String(localized: "Résultat")
        case .failed: return "Erreur"
        }
    }

    /// Libellé de phase du cadran (casse normale, DA « Crème & Terre cuite »).
    /// `displayTitle` reste utilisé tel quel par la Live Activity.
    var dialTitle: String {
        switch self {
        case .idle: return String(localized: "Prêt à mesurer")
        case .ping: return "Latence"
        case .download: return String(localized: "Téléchargement")
        case .upload: return "Envoi"
        case .saving: return "Synchronisation"
        case .finished: return String(localized: "Téléchargement")
        case .failed: return "Erreur"
        }
    }

    var order: Int {
        switch self {
        case .idle: return 0
        case .ping: return 1
        case .download: return 2
        case .upload: return 3
        case .saving, .finished: return 4
        case .failed: return 0
        }
    }
}
