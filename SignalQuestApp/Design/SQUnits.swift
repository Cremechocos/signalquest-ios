import Foundation
import SwiftUI

/// Système d'unités choisi par le membre (`GET/PATCH /api/user/preferences`).
enum SQUnitsSystem: String, Codable, CaseIterable, Sendable {
    case metric
    case imperial

    var label: String {
        switch self {
        case .metric: return String(localized: "Métrique")
        case .imperial: return String(localized: "Impérial")
        }
    }

    var hint: String {
        switch self {
        case .metric: return String(localized: "kilomètres et mètres")
        case .imperial: return String(localized: "miles et pieds")
        }
    }
}

/// Formatage des distances, en un seul endroit.
///
/// POURQUOI CENTRALISER. Le format `km`/`m` était réécrit à la main dans une
/// dizaine de vues, chacune avec ses propres seuils. Une préférence d'unités ne
/// pouvait pas s'y appliquer « dans toute l'app » : il aurait fallu retrouver
/// les dix, et le onzième appel écrit demain serait reparti en métrique en dur.
///
/// La préférence est LUE SYNCHRONEMENT depuis `UserDefaults` : ces formateurs
/// sont appelés depuis des `body` SwiftUI, où l'on ne peut pas attendre le
/// réseau. Le serveur reste la source de vérité — `SQUnitsStore` recopie sa
/// valeur au lancement et à chaque changement.
enum SQUnits {
    /// Clé de persistance. Publique au module : `SQUnitsStore` l'écrit.
    static let defaultsKey = "fr.signalquest.ios.unitsSystem"

    static var current: SQUnitsSystem {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let system = SQUnitsSystem(rawValue: raw)
        else { return .metric }
        return system
    }

    private static let metersPerMile = 1609.344
    private static let metersPerFoot = 0.3048

    /// Distance depuis des MÈTRES. Bascule vers l'unité longue au-delà d'un
    /// millier — le seuil que toutes les vues appliquaient déjà, à la main.
    static func distance(meters: Double, system: SQUnitsSystem = current) -> String {
        guard meters.isFinite else { return "—" }
        switch system {
        case .metric:
            return meters >= 1000
                ? String(format: "%.1f km", meters / 1000)
                : "\(Int(meters.rounded())) m"
        case .imperial:
            let miles = meters / metersPerMile
            // Sous un dixième de mile (~160 m), le pied est plus parlant : « 0,1 mi »
            // couvrirait indistinctement 80 et 240 mètres.
            return miles >= 0.1
                ? String(format: "%.1f mi", miles)
                : "\(Int((meters / metersPerFoot).rounded())) ft"
        }
    }

    /// Distance depuis des KILOMÈTRES — la forme que renvoient les sessions.
    static func distance(kilometers: Double, system: SQUnitsSystem = current) -> String {
        distance(meters: kilometers * 1000, system: system)
    }

    /// Rayon d'une zone, toujours court : on ne bascule pas en unité longue.
    static func radius(meters: Double, system: SQUnitsSystem = current) -> String {
        guard meters.isFinite else { return "—" }
        switch system {
        case .metric: return "\(Int(meters.rounded())) m"
        case .imperial: return "\(Int((meters / metersPerFoot).rounded())) ft"
        }
    }
}

/// Miroir observable de la préférence, pour que les vues se rafraîchissent quand
/// elle change et que le réseau ne soit interrogé qu'une fois.
@MainActor
final class SQUnitsStore: ObservableObject {
    @Published private(set) var system: SQUnitsSystem = SQUnits.current

    /// Applique une valeur venue du serveur (ou choisie par l'utilisateur).
    func apply(_ system: SQUnitsSystem) {
        guard system != self.system || UserDefaults.standard.string(forKey: SQUnits.defaultsKey) == nil else { return }
        UserDefaults.standard.set(system.rawValue, forKey: SQUnits.defaultsKey)
        self.system = system
    }
}
