import SwiftUI

extension SpeedtestPhase {
    /// Vocabulaire du lexique, traduit : « Ping », « Sync » et « Erreur »
    /// restaient en français dans l'app anglaise (MES-24, TRX-25).
    var displayTitle: String {
        switch self {
        case .idle: return String(localized: "Prêt")
        case .ping: return String(localized: "Latence")
        case .download: return String(localized: "Réception")
        case .upload: return String(localized: "Envoi")
        case .saving: return String(localized: "Synchronisation")
        case .finished: return String(localized: "Résultat")
        case .failed: return String(localized: "Erreur")
        }
    }

    /// Libellé de phase du cadran (casse normale, DA « Crème & Terre cuite »).
    /// `displayTitle` reste utilisé tel quel par la Live Activity.
    var dialTitle: String {
        switch self {
        case .idle: return String(localized: "Prêt à mesurer")
        case .ping: return String(localized: "Latence")
        case .download: return String(localized: "Réception")
        case .upload: return String(localized: "Envoi")
        case .saving: return String(localized: "Synchronisation")
        case .finished: return String(localized: "Résultat")
        case .failed: return String(localized: "Erreur")
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
