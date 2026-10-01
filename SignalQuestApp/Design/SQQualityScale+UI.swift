import SwiftUI
import UIKit

// Couleurs et libellés de l'échelle unique (`Core/Shared/SQQualityScale.swift`),
// côté app : le fichier partagé reste en Foundation pour la cible widget.

extension SQQualityScale.Throughput {
    var color: Color { Color(hex: hex) }
    var uiColor: UIColor { SQNetworkColors.uiColor(hex) }

    var label: String {
        switch self {
        case .exceptional: return String(localized: "Exceptionnel")
        case .excellent: return String(localized: "Excellent")
        case .veryGood: return String(localized: "Très bon")
        case .good: return String(localized: "Bon")
        case .medium: return String(localized: "Moyen")
        case .slow: return String(localized: "Lent")
        case .verySlow: return String(localized: "Très lent")
        }
    }

    /// Plage du palier pour une légende : « 600–1 000 », « 1 000+ », « < 10 ».
    var rangeLabel: String {
        let lower = Int(lowerBoundMbps).formatted()
        switch self {
        case .exceptional: return "\(lower)+"
        case .verySlow: return "< \(Int(Self.slow.lowerBoundMbps).formatted())"
        default:
            let upper = Self.allCases.firstIndex(of: self).flatMap { index in
                index > 0 ? Self.allCases[index - 1].lowerBoundMbps : nil
            } ?? lowerBoundMbps
            return "\(lower)–\(Int(upper).formatted())"
        }
    }
}

extension SQQualityScale.Signal {
    var color: Color { Color(hex: hex) }
    var uiColor: UIColor { SQNetworkColors.uiColor(hex) }

    var label: String {
        switch self {
        case .excellent: return String(localized: "Excellent")
        case .good: return String(localized: "Bon")
        case .fair: return String(localized: "Moyen")
        case .weak: return String(localized: "Faible")
        case .poor: return String(localized: "Critique")
        case .noService: return String(localized: "Sans réseau constaté")
        case .unknown: return String(localized: "Pas de mesure")
        }
    }
}

extension SQQualityScale.Generation {
    var color: Color { Color(hex: hex) }
    var uiColor: UIColor { SQNetworkColors.uiColor(hex) }

    var label: String {
        switch self {
        case .fiveG: return "5G"
        case .fourG: return "4G"
        case .threeG: return "3G"
        case .twoG: return "2G"
        case .none: return String(localized: "Aucune")
        }
    }
}
