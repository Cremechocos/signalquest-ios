import SwiftUI
import UIKit

/// SOURCE UNIQUE des échelles de couleur « qualité réseau » (débit, RSRP,
/// génération).
///
/// Ces trois échelles sont CANONIQUES : elles reproduisent à l'identique les
/// barèmes de la carte principale (`MapExplorerView` : `SpeedBand`,
/// `CoverageQualityBand`, `CoverageGenerationBand`), eux-mêmes alignés sur le
/// web (`lib/speedColorUtils.ts`, `lib/signal-quality.ts`) et sur Android.
///
/// TOUT nouveau call site qui a besoin de colorer un débit, un RSRP ou une
/// génération DOIT passer par ici plutôt que de recopier des seuils : c'est ce
/// qui garantit qu'une même mesure a la même couleur partout (carte, fiches,
/// messagerie, sessions). Ne PAS diverger de ces valeurs sans mettre à jour la
/// carte et le web en même temps.
enum SQNetworkColors {

    // MARK: Gris « inconnu / aucun »

    /// Teinte neutre partagée par les bandes « inconnu » (RSRP) et « aucun »
    /// (génération). Identique au web (`QUALITY_HEX.unknown`).
    static let unknownHex: UInt32 = 0x94A3B8
    static var unknownUIColor: UIColor { uiColor(unknownHex) }

    // MARK: Débit (Mb/s) → couleur

    /// 7 paliers descendants — seuils {1000, 600, 300, 100, 30, 10} :
    /// ≥1000 bleu · excellent cyan · très bon vert · bon vert clair ·
    /// moyen jaune · lent orange · <10 rouge.
    static func speedColor(_ mbps: Double) -> Color { Color(hex: speedHex(mbps)) }
    static func speedUIColor(_ mbps: Double) -> UIColor { uiColor(speedHex(mbps)) }

    static func speedHex(_ mbps: Double) -> UInt32 {
        switch mbps {
        case 1000...:    return 0x3B82F6 // exceptionnel
        case 600..<1000: return 0x06B6D4 // excellent
        case 300..<600:  return 0x22C55E // très bon
        case 100..<300:  return 0x84CC16 // bon
        case 30..<100:   return 0xEAB308 // moyen
        case 10..<30:    return 0xF97316 // lent
        default:         return 0xEF4444 // très lent
        }
    }

    // MARK: RSRP (dBm) → couleur

    /// Seuils {-80, -90, -100, -110} : excellent émeraude · bon vert clair ·
    /// moyen ambre · faible orange · très faible rouge.
    ///
    /// Garde-fou canonique : `nil` ou un RSRP > -44 dBm (au-delà du maximum
    /// théorique 3GPP, ou la sentinelle 0 « pas de mesure ») → INCONNU (gris),
    /// jamais un faux « excellent » vert vif.
    static func rsrpColor(_ rsrp: Double?) -> Color { Color(hex: rsrpHex(rsrp)) }
    static func rsrpUIColor(_ rsrp: Double?) -> UIColor { uiColor(rsrpHex(rsrp)) }

    static func rsrpHex(_ rsrp: Double?) -> UInt32 {
        guard let rsrp, rsrp <= -44 else { return unknownHex }
        switch rsrp {
        case (-80)...:      return 0x10B981 // excellent
        case -90..<(-80):   return 0x84CC16 // bon
        case -100..<(-90):  return 0xF59E0B // moyen
        case -110..<(-100): return 0xF97316 // faible
        default:            return 0xEF4444 // très faible
        }
    }

    // MARK: Génération (technologie) → couleur

    /// 5G violet · 4G bleu · 3G teal · 2G ambre · inconnu gris.
    static func generationColor(_ tech: String?) -> Color { Color(hex: generationHex(tech)) }
    static func generationUIColor(_ tech: String?) -> UIColor { uiColor(generationHex(tech)) }

    static func generationHex(_ tech: String?) -> UInt32 {
        let t = (tech ?? "").uppercased()
        if t.contains("5G") || t.contains("NR") { return 0x8B5CF6 }
        if t.contains("4G") || t.contains("LTE") { return 0x3B82F6 }
        if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return 0x14B8A6 }
        if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return 0xF59E0B }
        return unknownHex
    }

    // MARK: Helper

    /// Convertit un 0xRRGGBB en `UIColor` (pour les call sites MapKit / Core
    /// Graphics qui ne peuvent pas utiliser `Color`).
    private static func uiColor(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
