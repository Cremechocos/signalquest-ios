import SwiftUI
import UIKit

/// Échelles de lecture du réseau : génération radio et débit.
///
/// Elles existaient en plusieurs copies, écrites en hexadécimal Tailwind
/// (violet `#8B5CF6`, bleu `#3B82F6`, cyan `#06B6D4`…) au milieu d'une app crème
/// et terre cuite. Deux conséquences : la carte détonnait, et deux écrans
/// pouvaient diverger sans que rien ne le signale.
///
/// Tout passe désormais par les jetons du design system. Chaque palier porte
/// aussi un **glyphe** : c'est ce qui rend la carte lisible sans distinguer les
/// couleurs (WCAG 1.4.1 « Differentiate Without Color »), et ce que l'ancienne
/// échelle purement chromatique ne permettait pas.
enum SQSignalScale {

    // MARK: Génération radio

    enum Generation: String, CaseIterable {
        case fiveG = "5G"
        case fourG = "4G"
        case threeG = "3G"
        case twoG = "2G"
        case none

        /// Normalise les libellés hétérogènes venus du réseau ou de CoreTelephony
        /// (« 5G NSA », « LTE », « HSPA », « Aucun »…).
        static func from(_ raw: String?) -> Generation {
            let value = (raw ?? "").uppercased()
            if value.contains("5G") || value.hasPrefix("NR") { return .fiveG }
            if value.contains("4G") || value.contains("LTE") { return .fourG }
            if value.contains("3G") || value.contains("UMTS") || value.contains("HSPA") || value.contains("WCDMA") { return .threeG }
            if value.contains("2G") || value.contains("GSM") || value.contains("EDGE") || value.contains("GPRS") { return .twoG }
            return .none
        }

        /// Ordonnée du meilleur au moins bon : la 5G prend l'accent de marque, et
        /// l'absence de réseau reste neutre plutôt que rouge — une zone blanche
        /// est une information, pas une erreur.
        var color: Color {
            switch self {
            case .fiveG: return SQColor.brandRed
            case .fourG: return SQColor.success
            case .threeG: return SQColor.warning
            case .twoG: return SQColor.brandOrange
            case .none: return SQColor.labelTertiary
            }
        }

        var uiColor: UIColor { UIColor(color) }

        /// Glyphe SF Symbols : le nombre de barres décroît avec la génération,
        /// donc l'échelle se lit même en niveaux de gris.
        var glyph: String {
            switch self {
            case .fiveG: return "chart.bar.fill"
            case .fourG: return "chart.bar"
            case .threeG: return "cellularbars"
            case .twoG: return "antenna.radiowaves.left.and.right"
            case .none: return "antenna.radiowaves.left.and.right.slash"
            }
        }

        var label: String {
            self == .none ? String(localized: "Aucun") : rawValue
        }
    }

    // MARK: Débit descendant

    /// Paliers de débit, du plus rapide au plus lent. `lowerBound` est le seuil
    /// d'entrée en Mb/s.
    enum Throughput: CaseIterable {
        case gigabit, veryFast, fast, good, fair, slow, poor

        static func from(_ mbps: Double) -> Throughput {
            switch mbps {
            case 1_000...: return .gigabit
            case 600..<1_000: return .veryFast
            case 300..<600: return .fast
            case 100..<300: return .good
            case 30..<100: return .fair
            case 10..<30: return .slow
            default: return .poor
            }
        }

        /// Trois couleurs de la DA seulement (succès / avertissement / danger),
        /// modulées en opacité pour les paliers intermédiaires. Sept teintes
        /// distinctes seraient illisibles sur une carte, et surtout impossibles à
        /// tenir dans une palette de marque.
        var color: Color {
            switch self {
            case .gigabit: return SQColor.brandRed
            case .veryFast: return SQColor.success
            case .fast: return SQColor.success.opacity(0.72)
            case .good: return SQColor.warning
            case .fair: return SQColor.warning.opacity(0.72)
            case .slow: return SQColor.brandOrange
            case .poor: return SQColor.danger
            }
        }

        var uiColor: UIColor { UIColor(color) }

        /// Le nombre de chevrons matérialise le palier sans recourir à la couleur.
        var glyph: String {
            switch self {
            case .gigabit: return "chevron.up.3"
            case .veryFast, .fast: return "chevron.up.2"
            case .good, .fair: return "chevron.up"
            case .slow: return "chevron.down"
            case .poor: return "chevron.down.2"
            }
        }

        /// Seuil affiché en légende.
        var label: String {
            switch self {
            case .gigabit: return "1000+"
            case .veryFast: return "600"
            case .fast: return "300"
            case .good: return "100"
            case .fair: return "30"
            case .slow: return "10"
            case .poor: return "<10"
            }
        }
    }
}
