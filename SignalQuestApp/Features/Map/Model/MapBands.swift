import SwiftUI
import CoreLocation
import MapKit

/// Politique de rendu de la couche couverture selon le zoom (pure & testable).
/// Points bruts dès le « zoom ville » (~z11) ; clusters seulement au niveau région/pays.
/// Caps relevés pour ne plus tronquer les points (bug « points qui disparaissent au zoom »).
enum CoverageRenderPolicy {
    /// Zoom à partir duquel le CLIENT demande les points bruts (`detail=points`) ; en
    /// dessous, des clusters (`detail=overview`). « Zoom ville ». Seuil iOS uniquement —
    /// Android a sa propre constante (z13), qu'on ne touche pas.
    static let rawPointsFromZoom = 11
    /// Plafond de points bruts par tuile (= `limit` demandé au backend). Unifié quel que
    /// soit le zoom — fini la dégradation 900→250 qui masquait ~75 % des points au dézoom.
    static let pointCapPerTile = 2500
    /// Plafond du repli `/api/coverage/points` (bbox, sans tuiles).
    static let fallbackCap = 6000

    /// Rendu piloté par la DONNÉE reçue (robuste quel que soit le zoom / le seuil de
    /// fetch) : on affiche les points bruts s'il y en a (ou si un filtre bande est actif),
    /// sinon les clusters. Mutuellement exclusifs.
    static func mode(hasPoints: Bool, hasClusters: Bool, hasBandFilter: Bool) -> (useClusters: Bool, useRawPoints: Bool) {
        let useRawPoints = hasPoints || hasBandFilter
        let useClusters = hasClusters && !useRawPoints
        return (useClusters, useRawPoints)
    }
}

enum CoverageQualityBand: String, CaseIterable, Identifiable {
    case excellent
    case good
    case fair
    case weak
    case poor
    case unknown

    var id: String { rawValue }

    static var visibleBands: [CoverageQualityBand] {
        [.excellent, .good, .fair, .weak, .poor]
    }

    // Seuils RSRP alignés sur le web (`lib/signal-quality.ts` RSRP_SCALE) :
    // ≥ -80 excellent · -90 bon · -100 moyen · -110 faible · sinon très faible.
    static func band(for rsrp: Double?) -> CoverageQualityBand {
        guard let rsrp else { return .unknown }
        // Garde-fou : un RSRP physiquement impossible (0 = « pas de mesure », ou
        // > -44 dBm le maximum théorique 3GPP) → INCONNU, jamais « excellent ». Sinon
        // un point sans vrai RSRP (couverture iOS = génération seule, potentiellement
        // servie à 0) s'afficherait en faux vert vif sur la carte Signal.
        guard rsrp <= -44 else { return .unknown }
        switch rsrp {
        case (-80)...: return .excellent
        case -90..<(-80): return .good
        case -100..<(-90): return .fair
        case -110..<(-100): return .weak
        default: return .poor
        }
    }

    var title: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Bon"
        case .fair: return "Moyen"
        case .weak: return "Faible"
        case .poor: return String(localized: "Très faible")
        case .unknown: return "Inconnu"
        }
    }

    // Couleurs QUALITY_HEX du web : #10b981 / #84cc16 / #f59e0b / #f97316 / #ef4444.
    var colorHex: UInt32 {
        switch self {
        case .excellent: return 0x10B981
        case .good: return 0x84CC16
        case .fair: return 0xF59E0B
        case .weak: return 0xF97316
        case .poor: return 0xEF4444
        case .unknown: return 0x94A3B8
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .excellent: return Color(hex: 0x10B981)
        case .good: return Color(hex: 0x84CC16)
        case .fair: return Color(hex: 0xF59E0B)
        case .weak: return Color(hex: 0xF97316)
        case .poor: return Color(hex: 0xEF4444)
        case .unknown: return Color(hex: 0x94A3B8)
        }
    }

    var uiColor: UIColor {
        switch self {
        case .excellent: return UIColor(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255, alpha: 1.0)
        case .good: return UIColor(red: 0x84 / 255, green: 0xCC / 255, blue: 0x16 / 255, alpha: 1.0)
        case .fair: return UIColor(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1.0)
        case .weak: return UIColor(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1.0)
        case .poor: return UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1.0)
        case .unknown: return UIColor(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255, alpha: 1.0)
        }
    }
}

/// Bandes de GÉNÉRATION pour la couche couverture (mode « génération », distinct du
/// RSRP). Couleurs alignées sur la carte « Mes mesures » (SessionGenerationColor) :
/// 5G violet · 4G bleu · 3G sarcelle · 2G ardoise · gris (aucun/inconnu).
enum CoverageGenerationBand: String, CaseIterable, Identifiable {
    case g5, g4, g3, g2, none

    var id: String { rawValue }

    static var visibleBands: [CoverageGenerationBand] { [.g5, .g4, .g3, .g2, .none] }

    static func band(for tech: String?) -> CoverageGenerationBand {
        let t = (tech ?? "").uppercased()
        if t.contains("5G") || t.contains("NR") { return .g5 }
        if t.contains("4G") || t.contains("LTE") { return .g4 }
        if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return .g3 }
        if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return .g2 }
        return .none
    }

    /// Rang de priorité pour élire la génération dominante d'un lieu
    /// (5G > 4G > 3G > 2G > aucun). Sert à ne conserver qu'UNE pastille par point
    /// logique en 5G NSA, où le backend renvoie des frères co-localisés (ancre
    /// LTE taguée « 4G » + cellule NR taguée « 5G »).
    var rank: Int {
        switch self {
        case .g5: return 5
        case .g4: return 4
        case .g3: return 3
        case .g2: return 2
        case .none: return 0
        }
    }

    var title: String {
        switch self {
        case .g5: return "5G"
        case .g4: return "4G"
        case .g3: return "3G"
        case .g2: return "2G"
        case .none: return "Aucun"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .g5: return 0x8B5CF6
        case .g4: return 0x3B82F6
        case .g3: return 0x14B8A6
        case .g2: return 0x64748B
        case .none: return 0x94A3B8
        }
    }

    var swiftUIColor: Color { Color(hex: colorHex) }
}

/// Paliers de débit descendant pour colorer la couche dense des speedtests —
/// échelle identique au web (`speedColorUtils.ts`) et à Android : rouge → orange
/// → jaune → vert clair → vert → cyan → bleu.
enum SpeedBand: String, CaseIterable {
    case verySlow
    case slow
    case medium
    case good
    case veryGood
    case excellent
    case exceptional

    static func band(forDownload mbps: Double) -> SpeedBand {
        switch mbps {
        case 1000...:    return .exceptional
        case 600..<1000: return .excellent
        case 300..<600:  return .veryGood
        case 100..<300:  return .good
        case 30..<100:   return .medium
        case 10..<30:    return .slow
        default:         return .verySlow
        }
    }

    var uiColor: UIColor {
        switch self {
        case .exceptional: return UIColor(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1.0)
        case .excellent:   return UIColor(red: 0x06 / 255, green: 0xB6 / 255, blue: 0xD4 / 255, alpha: 1.0)
        case .veryGood:    return UIColor(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255, alpha: 1.0)
        case .good:        return UIColor(red: 0x84 / 255, green: 0xCC / 255, blue: 0x16 / 255, alpha: 1.0)
        case .medium:      return UIColor(red: 0xEA / 255, green: 0xB3 / 255, blue: 0x08 / 255, alpha: 1.0)
        case .slow:        return UIColor(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1.0)
        case .verySlow:    return UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1.0)
        }
    }
}
