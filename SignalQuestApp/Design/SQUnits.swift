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

    // MARK: Débit, latence, bande

    /// « 412 Mbit/s », « 64,3 Mbit/s », « 1,2 Gbit/s » ; « Mbps » en anglais.
    ///
    /// Trente écrans formataient le débit à la main avec `String(format:)`, donc
    /// avec un point décimal en français (« 64.0 »), et « Mbps » partout (TRX-24,
    /// MES-25).
    static func throughput(mbps: Double, locale: Locale = .current) -> String {
        guard mbps.isFinite, mbps >= 0 else { return "—" }
        return "\(throughputValue(mbps: mbps, locale: locale)) \(throughputUnit(mbps: mbps))"
    }

    /// Le nombre seul, pour un grand chiffre dont l'unité est posée à part. Une
    /// décimale sous 100 Mbit/s et en Gbit/s, aucune entre les deux.
    static func throughputValue(mbps: Double, locale: Locale = .current) -> String {
        guard mbps.isFinite, mbps >= 0 else { return "—" }
        if mbps >= 1_000 {
            return (mbps / 1_000).formatted(.number.precision(.fractionLength(1)).locale(locale))
        }
        return mbps.formatted(.number.precision(.fractionLength(mbps < 100 ? 1 : 0)).locale(locale))
    }

    static func throughputUnit(mbps: Double) -> String {
        mbps >= 1_000 ? String(localized: "Gbit/s") : String(localized: "Mbit/s")
    }

    /// Latence ou gigue : « 18 ms ».
    static func milliseconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return "\(Int(value.rounded())) ms"
    }

    /// Bande radio : « n78 » en 5G, « B20 » en 4G (TRX-27). Sans technologie
    /// explicite, les numéros qui n'existent qu'en 5G restent en « n ». La 5G NSA
    /// seule ne tranche pas : sa bande principale est souvent celle de l'ancre 4G.
    static func band(_ number: Int, technology: String? = nil) -> String {
        let tech = (technology ?? "").uppercased()
        let explicitNR = tech.contains("NR") || (tech.contains("5G") && !tech.contains("NSA"))
        return band(number, isNR: explicitNR)
    }

    static func band(_ number: Int, isNR: Bool) -> String {
        let nrOnly = [77, 78, 79].contains(number) || number >= 257
        return isNR || nrOnly ? "n\(number)" : "B\(number)"
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
