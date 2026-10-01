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

    // MARK: Bandes ANFR → couleur (provisoire)

    /// Table provisoire proposée au web le 01/10 comme base de la v1.1 du
    /// contrat de couleurs, à remplacer à l'octet dès son gel. Chaque bande
    /// reste dans la famille de sa génération ; la plus basse est la plus
    /// contrastée ; au moins 3:1 sur la carte, le fond et la tuile, en clair
    /// (premier) comme en sombre (second).
    private static let bandHexes: [String: (light: UInt32, dark: UInt32)] = [
        "2g900": (0x485363, 0xC6D2E3), "2g1800": (0x717D8F, 0x727D8C),
        "3g900": (0x03483F, 0x81CFC0), "3g2100": (0x228A87, 0x338886),
        "4g700": (0x013761, 0x88C3FE), "4g800": (0x014282, 0x76B4FF), "4g900": (0x024AAD, 0x6AA3FE),
        "4g1800": (0x2452CF, 0x6191FF), "4g2100": (0x455FE2, 0x617FF6), "4g2600": (0x616CF3, 0x626FE7),
        "n28": (0x3F0091, 0xBCB2FE), "n1": (0x761FC6, 0xB480FE), "n78": (0xB14AE5, 0xAB53DA),
    ]

    /// Trait « tous supports » d'une génération dans un graphique : la teinte
    /// du contrat en clair ; en sombre, la même, éclaircie pour garder 3:1.
    private static let generationChartDarkHexes: [String: UInt32] = [
        "2G": 0x6F8097, "3G": 0x308C83, "4G": 0x3877FF, "5G": 0x9160FF,
    ]

    /// Une bande inconnue prend la teinte de sa génération.
    static func bandColor(_ band: String, generation: String) -> Color {
        guard let hexes = bandHexes[band.lowercased()] else { return generationChartColor(generation) }
        return dynamic(light: hexes.light, dark: hexes.dark)
    }

    static func generationChartColor(_ generation: String) -> Color {
        let light = generationHex(generation)
        return dynamic(light: light, dark: generationChartDarkHexes[generation.uppercased()] ?? light)
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
