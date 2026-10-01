import SwiftUI
import UIKit

/// Accès historique aux couleurs « qualité réseau » (débit, RSRP, génération).
///
/// Les seuils et teintes vivent désormais dans `SQQualityScale`
/// (`Core/Shared/`), seule source partagée avec le widget. Ce type garde ses
/// appels existants et ne fait que déléguer : ne plus recopier de seuils ailleurs.
enum SQNetworkColors {

    // MARK: Gris « inconnu / aucun »

    /// Teinte neutre partagée par les bandes « inconnu » (RSRP) et « aucun »
    /// (génération). Identique au web (`QUALITY_HEX.unknown`).
    static let unknownHex: UInt32 = SQQualityScale.unknownHex
    static var unknownUIColor: UIColor { uiColor(unknownHex) }

    // MARK: Débit (Mb/s) → couleur

    /// 7 paliers descendants — seuils {1000, 600, 300, 100, 30, 10} :
    /// ≥1000 bleu · excellent cyan · très bon vert · bon vert clair ·
    /// moyen jaune · lent orange · <10 rouge.
    static func speedColor(_ mbps: Double) -> Color { Color(hex: speedHex(mbps)) }
    static func speedUIColor(_ mbps: Double) -> UIColor { uiColor(speedHex(mbps)) }

    static func speedHex(_ mbps: Double) -> UInt32 {
        SQQualityScale.Throughput(mbps: mbps).hex
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
        SQQualityScale.Signal(rsrp: rsrp).hex
    }

    // MARK: Génération (technologie) → couleur

    /// 5G violet · 4G bleu · 3G sarcelle · 2G ardoise · inconnu gris.
    static func generationColor(_ tech: String?) -> Color { Color(hex: generationHex(tech)) }
    static func generationUIColor(_ tech: String?) -> UIColor { uiColor(generationHex(tech)) }

    static func generationHex(_ tech: String?) -> UInt32 {
        SQQualityScale.Generation(technology: tech).hex
    }

    // MARK: Bandes ANFR → couleur (contrat v1.1)

    /// Trait d'une bande ANFR, clair et sombre (`SQQualityScale.Band`). Une clé
    /// sans génération reconnaissable prend le trait de la génération donnée.
    static func bandColor(_ band: String, generation: String) -> Color {
        guard let stroke = SQQualityScale.Band.stroke(band) else { return generationChartColor(generation) }
        return dynamic(light: stroke.light, dark: stroke.dark)
    }

    /// Trait « tous supports » d'une génération dans un graphique : la teinte
    /// du contrat en clair ; en sombre, la même, éclaircie pour garder 3:1.
    static func generationChartColor(_ generation: String) -> Color {
        let scale = SQQualityScale.Generation(technology: generation)
        return dynamic(light: scale.hex, dark: scale.chartDarkHex)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in uiColor(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    // MARK: Helper

    /// Convertit un 0xRRGGBB en `UIColor` (pour les call sites MapKit / Core
    /// Graphics qui ne peuvent pas utiliser `Color`).
    ///
    /// Ouvert au module — et non plus privé — depuis que la carte CarPlay colore
    /// elle aussi ses pastilles de couverture à partir des `colorHex` renvoyés
    /// par le serveur. C'était ça ou une troisième conversion hex→UIColor dans
    /// le projet.
    static func uiColor(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
