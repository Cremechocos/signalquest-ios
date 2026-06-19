import Foundation

/// Catalogue de filtres carte spécifique au marché (pays).
///
/// Porté du client Android (`MarketFrequencyBands`, `AntennaSharingFilter`,
/// `MapTechnologyFormatter`). Permet aux sections « Technologies », « Partage »
/// et « Bandes » de la feuille de filtres de s'adapter à 100 % au pays
/// sélectionné, avec un **repli européen** pour les marchés communautaires sans
/// définition dédiée (Allemagne, Italie, Espagne, Luxembourg…).
///
/// Les valeurs (`band`, `value` de techno/partage) restent les identifiants
/// canoniques côté filtre ; seuls les **libellés** affichés s'adaptent au marché
/// (ex. Amérique du Nord : « 4G » → « LTE »).
enum MapFilterCatalog {

    // MARK: - Bandes de fréquence

    /// Option de bande : numéro de bande 3GPP, libellé affiché, génération.
    struct BandOption: Hashable {
        let band: Int
        let label: String
        /// Génération radio ("4G" | "5G") — utile pour un filtrage croisé futur.
        let technology: String
    }

    /// Bandes par marché. Tout marché sans catalogue dédié retombe sur
    /// [`defaultEuropean`]. FR et DROM partagent les mêmes bandes ; BE/CH sont
    /// identiques au repli européen.
    static func bands(forMarket code: String) -> [BandOption] {
        switch normalize(code) {
        case "FR", "DROM": return franceBands
        case "CA":         return canadaBands
        case "BE", "CH":   return defaultEuropean
        default:           return defaultEuropean
        }
    }

    /// France métropolitaine + DROM (mêmes attributions ARCEP).
    private static let franceBands: [BandOption] = [
        BandOption(band: 1, label: "B1/n1 (2100)", technology: "4G"),
        BandOption(band: 3, label: "B3 (1800)", technology: "4G"),
        BandOption(band: 7, label: "B7 (2600)", technology: "4G"),
        BandOption(band: 8, label: "B8 (900)", technology: "4G"),
        BandOption(band: 20, label: "B20 (800)", technology: "4G"),
        BandOption(band: 28, label: "B28/n28 (700)", technology: "4G"),
        BandOption(band: 78, label: "n78 (3500)", technology: "5G")
    ]

    /// Canada (attributions ISED — bandes nord-américaines, AWS, 600 MHz…).
    private static let canadaBands: [BandOption] = [
        BandOption(band: 2, label: "B2/n2 (1900)", technology: "4G"),
        BandOption(band: 4, label: "B4 (AWS)", technology: "4G"),
        BandOption(band: 5, label: "B5/n5 (850)", technology: "4G"),
        BandOption(band: 7, label: "B7/n7 (2600)", technology: "4G"),
        BandOption(band: 12, label: "B12/n12 (700)", technology: "4G"),
        BandOption(band: 13, label: "B13/n13 (700)", technology: "4G"),
        BandOption(band: 14, label: "B14/n14 (700 PS)", technology: "4G"),
        BandOption(band: 17, label: "B17 (700)", technology: "4G"),
        BandOption(band: 26, label: "B26/n26 (850 ext)", technology: "4G"),
        BandOption(band: 29, label: "B29 (700 SDL)", technology: "4G"),
        BandOption(band: 30, label: "B30/n30 (2300)", technology: "4G"),
        BandOption(band: 41, label: "B41/n41 (2500 TDD)", technology: "4G"),
        BandOption(band: 42, label: "B42 (3500)", technology: "4G"),
        BandOption(band: 66, label: "B66/n66 (AWS-3)", technology: "4G"),
        BandOption(band: 70, label: "B70/n70 (AWS-4)", technology: "4G"),
        BandOption(band: 71, label: "B71/n71 (600)", technology: "4G"),
        BandOption(band: 77, label: "n77 (3800)", technology: "5G"),
        BandOption(band: 78, label: "n78 (3500)", technology: "5G")
    ]

    /// Bandes par défaut pour les marchés communautaires sans définition dédiée
    /// (Allemagne, Italie, Espagne, Pays-Bas…). Reflète les bandes utilisées en
    /// Europe par les principaux MNO. Identique à BE/CH.
    private static let defaultEuropean: [BandOption] = [
        BandOption(band: 1, label: "B1/n1 (2100)", technology: "4G"),
        BandOption(band: 3, label: "B3 (1800)", technology: "4G"),
        BandOption(band: 7, label: "B7 (2600)", technology: "4G"),
        BandOption(band: 8, label: "B8/n8 (900)", technology: "4G"),
        BandOption(band: 20, label: "B20 (800)", technology: "4G"),
        BandOption(band: 28, label: "B28/n28 (700)", technology: "4G"),
        BandOption(band: 38, label: "B38 (2600 TDD)", technology: "4G"),
        BandOption(band: 78, label: "n78 (3500)", technology: "5G")
    ]

    // MARK: - Partage / mutualisation d'antennes

    /// Option de partage : valeur de filtre, libellé, symbole SF.
    struct SharingOption: Hashable {
        let value: String
        let label: String
        let icon: String
    }

    /// Catégories de partage par marché. Seuls FR et DROM exposent la
    /// mutualisation (ZB, leaders Crozon, ZTD) — les autres marchés n'ont pas
    /// d'équivalent exploitable côté carte (le Canada a ses propres motifs ISED,
    /// non encore portés). Retour vide ⇒ la section « Partage » est masquée.
    static func sharing(forMarket code: String) -> [SharingOption] {
        switch normalize(code) {
        case "FR", "DROM":
            return [
                SharingOption(value: "ZB", label: "ZB", icon: "antenna.radiowaves.left.and.right"),
                SharingOption(value: "CROZON_LEADER_SFR", label: "Crozon SFR", icon: "arrow.triangle.branch"),
                SharingOption(value: "CROZON_LEADER_BOUYGUES", label: "Crozon Bytel", icon: "arrow.triangle.branch"),
                SharingOption(value: "ZTD", label: "ZTD", icon: "building.2.fill")
            ]
        default:
            return []
        }
    }

    // MARK: - Technologies

    /// Option de technologie : valeur canonique (filtre) + libellé adapté.
    struct TechOption: Hashable {
        /// Valeur canonique du filtre : "2G" | "3G" | "4G" | "5G".
        let value: String
        /// Libellé affiché, adapté au marché (Amérique du Nord : 4G → « LTE »).
        let label: String
    }

    /// Générations proposées (ordre croissant, comme historiquement sur iOS).
    /// Les libellés s'adaptent : sur les marchés nord-américains (CA/US), la 4G
    /// s'affiche « LTE » — convention locale honnête, valeur de filtre inchangée.
    static func technologies(forMarket code: String) -> [TechOption] {
        let northAmerican = isNorthAmerican(code)
        return ["2G", "3G", "4G", "5G"].map { tech in
            let label = (tech == "4G" && northAmerican) ? "LTE" : tech
            return TechOption(value: tech, label: label)
        }
    }

    // MARK: - Helpers

    private static func isNorthAmerican(_ code: String) -> Bool {
        switch normalize(code) {
        case "CA", "US": return true
        default: return false
        }
    }

    private static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces).uppercased()
    }
}
