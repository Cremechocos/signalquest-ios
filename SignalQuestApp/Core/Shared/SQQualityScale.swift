import Foundation

/// Échelle unique de lecture du réseau : débit, signal et génération.
///
/// Une même mesure garde la même couleur partout — carte, fiches, Drive Test,
/// messagerie, widget — et la même que sur le web et Android (« Meaning Rule »
/// de DESIGN.md). Seuils, teintes et ordre d'évaluation suivent le contrat
/// commun `contracts/quality-scale-v1.json` (figé le 01/10/2026 avec Alexandre),
/// vérifié par `QualityScaleContractTests` : toute nouvelle version passe par
/// un changement visible de cette copie.
///
/// Partagé avec la cible widget : Foundation seulement, couleurs en hexadécimal.
/// Les glyphes donnent une lecture qui ne dépend pas des couleurs (WCAG 1.4.1) et
/// n'utilisent que des symboles présents dès iOS 16.
enum SQQualityScale {
    /// Gris « pas de mesure » (contrat : `signal.states.unknown`).
    static let unknownHex: UInt32 = 0x9CA3AF
    /// Ardoise « sans réseau constaté », dessinée hachurée (contrat :
    /// `signal.states.noService`).
    static let noServiceHex: UInt32 = 0x64748B

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

        /// Clé du palier dans le contrat (`downloadSpeed.levels`).
        var contractKey: String {
            switch self {
            case .exceptional: return "exceptional"
            case .excellent: return "excellent"
            case .veryGood: return "very-good"
            case .good: return "good"
            case .medium: return "fair"
            case .slow: return "slow"
            case .verySlow: return "very-slow"
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

    // MARK: Signal

    /// Qualité du signal reçu. Seuils propres à chaque technologie (RSRP en 4G,
    /// SS-RSRP en 5G, RSCP en 3G, RSSI en 2G) ; « sans réseau constaté » distinct
    /// de « pas de mesure ». Clés du contrat : `weak` est « poor » (Faible),
    /// `poor` est « critical » (Critique).
    enum Signal: CaseIterable, Sendable {
        case excellent, good, fair, weak, poor, noService, unknown

        enum Metric: Sendable {
            case rssi, rscp, rsrp, ssRsrp

            /// Seuils bas d'excellent, bon, moyen et faible, en dBm.
            var thresholds: [Int] {
                switch self {
                case .rsrp, .ssRsrp: return [-80, -90, -100, -110]
                case .rscp: return [-75, -85, -95, -105]
                case .rssi: return [-70, -80, -90, -100]
                }
            }

            var validRange: ClosedRange<Int> {
                switch self {
                case .rssi: return -120 ... -51
                case .rscp: return -130 ... -24
                case .rsrp: return -140 ... -40
                case .ssRsrp: return -156 ... -31
                }
            }

            /// Valeurs qui disent « pas de mesure » même dans la plage : 0 (import
            /// iOS, CoreTelephony ne donne pas le RSRP) et les planchers ou plafonds
            /// de chaque modem.
            func isSentinel(_ dbm: Int) -> Bool {
                if dbm == 0 { return true }
                switch self {
                case .rssi: return dbm <= -113
                case .rscp: return dbm >= -24
                case .rsrp, .ssRsrp: return dbm <= -140
                }
            }
        }

        private enum Reading { case metric(Metric), noService, unknown }

        private static let aliases: [String: String] = [
            "LTE": "4G", "LTE-A": "4G+", "LTE_CA": "4G+", "NR": "5G", "NR_NSA": "5G NSA",
            "UMTS": "3G", "WCDMA": "3G", "HSPA": "3G", "GSM": "2G", "EDGE": "2G",
        ]
        private static let noServiceTechnologies: Set<String> = ["AUCUN", "NONE", "NO SERVICE"]

        private static func reading(technology raw: String?) -> Reading {
            guard let raw else { return .unknown }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if noServiceTechnologies.contains(value) { return .noService }
            switch aliases[value] ?? value {
            case "2G": return .metric(.rssi)
            case "3G": return .metric(.rscp)
            case "4G", "4G+": return .metric(.rsrp)
            case "5G", "5G NSA": return .metric(.ssRsrp)
            default: return .unknown
            }
        }

        /// Ordre du contrat, le même sur les trois plateformes : la technologie
        /// d'abord (« sans réseau constaté » quelle que soit la valeur, même 0),
        /// puis dBm absent, arrondi, plage, sentinelles et seuils.
        init(dbm: Double?, technology: String?) {
            switch Self.reading(technology: technology) {
            case .noService: self = .noService
            case .unknown: self = .unknown
            case .metric(let metric): self = Self.level(dbm: dbm, metric: metric)
            }
        }

        /// Un RSRP déjà connu comme tel (4G, ou SS-RSRP aux mêmes seuils).
        init(rsrp: Double?) {
            self = Self.level(dbm: rsrp, metric: .rsrp)
        }

        private static func level(dbm: Double?, metric: Metric) -> Signal {
            guard let dbm, dbm.isFinite else { return .unknown }
            // Arrondi de Math.round (JavaScript, Java) : plancher(x + 0,5), soit
            // −80,5 → −80. Jamais `.rounded()`, qui s'éloigne de zéro (−81).
            let rounded = Int((dbm + 0.5).rounded(.down))
            guard metric.validRange.contains(rounded), !metric.isSentinel(rounded) else { return .unknown }
            let thresholds = metric.thresholds
            if rounded >= thresholds[0] { return .excellent }
            if rounded >= thresholds[1] { return .good }
            if rounded >= thresholds[2] { return .fair }
            if rounded >= thresholds[3] { return .weak }
            return .poor
        }

        /// Clé du niveau ou de l'état dans le contrat.
        var contractKey: String {
            switch self {
            case .excellent: return "excellent"
            case .good: return "good"
            case .fair: return "fair"
            case .weak: return "poor"
            case .poor: return "critical"
            case .noService: return "noService"
            case .unknown: return "unknown"
            }
        }

        var hex: UInt32 {
            switch self {
            case .excellent: return 0x16A34A
            case .good: return 0x65A30D
            case .fair: return 0xEAB308
            case .weak: return 0xFB923C
            case .poor: return 0xEF4444
            case .noService: return SQQualityScale.noServiceHex
            case .unknown: return SQQualityScale.unknownHex
            }
        }

        /// « Sans réseau constaté » se dessine hachuré (contrat).
        var isHatched: Bool { self == .noService }

        /// Remplissage du symbole `cellularbars` (valeur variable, iOS 16).
        var barsFraction: Double {
            switch self {
            case .excellent: return 1
            case .good: return 0.75
            case .fair: return 0.5
            case .weak: return 0.25
            case .poor, .noService, .unknown: return 0
            }
        }

        var glyph: String {
            switch self {
            case .noService: return "antenna.radiowaves.left.and.right.slash"
            case .unknown: return "questionmark"
            default: return "cellularbars"
            }
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

        /// Teintes foncées du contrat, pour qu'un libellé blanc reste lisible :
        /// 5G violet · 4G bleu · 3G sarcelle · 2G ardoise · aucune gris.
        var hex: UInt32 {
            switch self {
            case .fiveG: return 0x7C3AED
            case .fourG: return 0x2563EB
            case .threeG: return 0x0F766E
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
