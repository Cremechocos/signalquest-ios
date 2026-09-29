import Foundation

/// Échelle unique de lecture du réseau : débit, signal (RSRP) et génération.
///
/// Une même mesure garde la même couleur partout — carte, fiches, Drive Test,
/// messagerie, widget — et la même que sur le web et Android (« Meaning Rule »
/// de DESIGN.md). Seuils et teintes reprennent donc à l'identique
/// `lib/speedColorUtils.ts` et `lib/signal-quality.ts`. Ils existaient en neuf
/// copies, plus une variante aux couleurs de marque où le meilleur palier (terre
/// cuite) et le pire (rouge) se confondaient (MES-11, TRX-05).
///
/// Partagé avec la cible widget : Foundation seulement, couleurs en hexadécimal.
/// Les glyphes donnent une lecture qui ne dépend pas des couleurs (WCAG 1.4.1) et
/// n'utilisent que des symboles présents dès iOS 16.
enum SQQualityScale {
    /// Gris « inconnu / aucun », identique au web (`QUALITY_HEX.unknown`).
    static let unknownHex: UInt32 = 0x94A3B8

    // MARK: Débit descendant

    /// Paliers de débit, du plus rapide au plus lent.
    enum Throughput: CaseIterable, Sendable {
        case exceptional, excellent, veryGood, good, medium, slow, verySlow

        init(mbps: Double) {
            switch mbps {
            case 1_000...: self = .exceptional
            case 600..<1_000: self = .excellent
            case 300..<600: self = .veryGood
            case 100..<300: self = .good
            case 30..<100: self = .medium
            case 10..<30: self = .slow
            default: self = .verySlow
            }
        }

        /// Seuil d'entrée du palier, en Mbit/s.
        var lowerBoundMbps: Double {
            switch self {
            case .exceptional: return 1_000
            case .excellent: return 600
            case .veryGood: return 300
            case .good: return 100
            case .medium: return 30
            case .slow: return 10
            case .verySlow: return 0
            }
        }

        /// Rouge → orange → jaune → vert clair → vert → cyan → bleu.
        var hex: UInt32 {
            switch self {
            case .exceptional: return 0x3B82F6
            case .excellent: return 0x06B6D4
            case .veryGood: return 0x22C55E
            case .good: return 0x84CC16
            case .medium: return 0xEAB308
            case .slow: return 0xF97316
            case .verySlow: return 0xEF4444
            }
        }

        /// Rapide, moyen ou lent : trois repères suffisent, le chiffre dit le reste.
        var glyph: String {
            switch self {
            case .exceptional, .excellent, .veryGood, .good: return "hare"
            case .medium: return "equal"
            case .slow, .verySlow: return "tortoise"
            }
        }
    }

    // MARK: Signal (RSRP)

    /// Qualité du signal reçu, en dBm.
    enum Signal: CaseIterable, Sendable {
        case excellent, good, fair, weak, poor, unknown

        /// `nil`, 0 (« pas de mesure ») ou plus de -44 dBm (au-delà du maximum
        /// 3GPP) donnent « inconnu », jamais un faux « excellent ».
        init(rsrp: Double?) {
            guard let rsrp, rsrp <= -44 else { self = .unknown; return }
            switch rsrp {
            case (-80)...: self = .excellent
            case -90..<(-80): self = .good
            case -100..<(-90): self = .fair
            case -110..<(-100): self = .weak
            default: self = .poor
            }
        }

        var hex: UInt32 {
            switch self {
            case .excellent: return 0x10B981
            case .good: return 0x84CC16
            case .fair: return 0xF59E0B
            case .weak: return 0xF97316
            case .poor: return 0xEF4444
            case .unknown: return SQQualityScale.unknownHex
            }
        }

        /// Remplissage du symbole `cellularbars` (valeur variable, iOS 16).
        var barsFraction: Double {
            switch self {
            case .excellent: return 1
            case .good: return 0.75
            case .fair: return 0.5
            case .weak: return 0.25
            case .poor, .unknown: return 0
            }
        }

        var glyph: String {
            self == .unknown ? "antenna.radiowaves.left.and.right.slash" : "cellularbars"
        }
    }

    // MARK: Génération radio

    enum Generation: CaseIterable, Sendable {
        case fiveG, fourG, threeG, twoG, none

        /// Normalise les libellés hétérogènes (« 5G NSA », « LTE », « HSPA »…).
        init(technology raw: String?) {
            let value = (raw ?? "").uppercased()
            if value.contains("5G") || value.contains("NR") { self = .fiveG }
            else if value.contains("4G") || value.contains("LTE") { self = .fourG }
            else if value.contains("3G") || value.contains("UMTS") || value.contains("HSPA") || value.contains("WCDMA") { self = .threeG }
            else if value.contains("2G") || value.contains("GSM") || value.contains("EDGE") || value.contains("GPRS") { self = .twoG }
            else { self = .none }
        }

        /// 5G violet · 4G bleu · 3G sarcelle · 2G ardoise · aucun gris.
        var hex: UInt32 {
            switch self {
            case .fiveG: return 0x8B5CF6
            case .fourG: return 0x3B82F6
            case .threeG: return 0x14B8A6
            case .twoG: return 0x64748B
            case .none: return SQQualityScale.unknownHex
            }
        }

        /// Priorité pour élire la génération dominante d'un lieu (5G NSA : ancre
        /// 4G et cellule 5G co-localisées).
        var rank: Int {
            switch self {
            case .fiveG: return 5
            case .fourG: return 4
            case .threeG: return 3
            case .twoG: return 2
            case .none: return 0
            }
        }
    }
}
