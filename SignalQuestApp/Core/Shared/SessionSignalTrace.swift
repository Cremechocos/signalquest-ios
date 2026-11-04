import Foundation

/// Couleur du tracé d'une session, point par point (contrat
/// `session-signal-trace` v1, #958) : l'état d'un point est celui de l'échelle
/// commune pour sa techno et son signal, sans règle propre au tracé. Le segment
/// de p[i-1] à p[i] prend l'état de son point d'arrivée ; aucune coupure, aucun
/// marqueur de départ ni d'arrivée.
enum SessionSignalTrace {
    struct Point: Equatable {
        let technology: String?
        let signalStrength: Double?
    }

    /// Fourchette annoncée : du meilleur au plus faible niveau mesuré.
    enum Summary: Equatable {
        case range(best: SQQualityScale.Signal, worst: SQQualityScale.Signal)
        case none
    }

    static func states(_ points: [Point]) -> [SQQualityScale.Signal] {
        // Ordre servi, sans retri ni dédoublonnage.
        points.map { SQQualityScale.Signal(dbm: $0.signalStrength, technology: $0.technology) }
    }

    /// Un état par segment ; moins de 2 points : aucun segment.
    static func segments(_ points: [Point]) -> [SQQualityScale.Signal] {
        Array(states(points).dropFirst())
    }

    /// Niveaux mesurés seulement : « sans réseau constaté » et « pas de mesure » ne comptent pas.
    static func summary(_ points: [Point]) -> Summary {
        let order: [SQQualityScale.Signal] = [.excellent, .good, .fair, .weak, .poor]
        let measured = states(points).compactMap { order.firstIndex(of: $0) }
        guard let best = measured.min(), let worst = measured.max() else { return .none }
        return .range(best: order[best], worst: order[worst])
    }

    /// « Signal de Excellent à Critique », « Signal Bon », ou « aucun point mesuré ».
    static func spokenSummary(_ points: [Point]) -> String {
        switch summary(points) {
        case .none:
            return String(localized: "aucun point mesuré")
        case .range(let best, let worst) where best == worst:
            return String(localized: "signal \(best.label)")
        case .range(let best, let worst):
            return String(localized: "signal de \(best.label) à \(worst.label)")
        }
    }
}
