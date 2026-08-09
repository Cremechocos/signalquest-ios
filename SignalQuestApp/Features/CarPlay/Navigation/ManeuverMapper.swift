import CarPlay
import CoreLocation
import UIKit

/// Traduit les étapes d'un itinéraire en manœuvres CarPlay.
///
/// MapKit ne donne qu'un texte libre (« Tournez à droite sur la rue de Rivoli »)
/// et une distance : ni type de manœuvre, ni symbole. Le pictogramme affiché sur
/// le bandeau du véhicule doit donc être déduit de l'instruction. C'est
/// imparfait par construction — d'où le repli sur une flèche neutre plutôt qu'un
/// symbole faux, qui enverrait le conducteur du mauvais côté.
@MainActor
enum ManeuverMapper {
    /// Nombre de manœuvres poussées d'avance. CarPlay n'en affiche qu'une, mais
    /// en fournir la suivante permet au véhicule d'anticiper l'enchaînement.
    static let lookahead = 2

    static func maneuvers(for plan: RoutePlan, from stepIndex: Int) -> [CPManeuver] {
        guard stepIndex < plan.steps.count else { return [] }
        let upper = min(stepIndex + lookahead, plan.steps.count)
        return (stepIndex..<upper).map { index in
            maneuver(for: plan.steps[index])
        }
    }

    static func maneuver(for step: RoutePlan.Step) -> CPManeuver {
        let maneuver = CPManeuver()
        // Plusieurs variantes : CarPlay choisit la plus longue qui tient dans la
        // largeur disponible, qui varie d'un véhicule à l'autre.
        maneuver.instructionVariants = instructionVariants(for: step.instruction)
        maneuver.symbolImage = symbol(for: step.instruction)
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: step.distanceMeters, unit: UnitLength.meters),
            timeRemaining: 0
        )
        return maneuver
    }

    /// De la plus complète à la plus courte : sur un petit écran, mieux vaut une
    /// instruction tronquée intelligemment qu'un texte coupé au milieu d'un mot.
    static func instructionVariants(for instruction: String) -> [String] {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [String(localized: "Continuez")] }
        // « Tournez à droite sur la rue de Rivoli » → « Tournez à droite »
        if let range = trimmed.range(of: " sur ") {
            let short = String(trimmed[trimmed.startIndex..<range.lowerBound])
            if short.count >= 4 { return [trimmed, short] }
        }
        return [trimmed]
    }

    /// Déduit le pictogramme du texte. Le repli neutre est délibéré : un symbole
    /// « à droite » sur une manœuvre à gauche est pire que pas de symbole.
    static func symbol(for instruction: String) -> UIImage? {
        let lowered = instruction.lowercased()
        let name: String
        switch true {
        case lowered.contains("demi-tour"), lowered.contains("faites demi"):
            name = "arrow.uturn.left"
        case lowered.contains("légèrement à droite"), lowered.contains("serrez à droite"):
            name = "arrow.up.right"
        case lowered.contains("légèrement à gauche"), lowered.contains("serrez à gauche"):
            name = "arrow.up.left"
        case lowered.contains("droite"):
            name = "arrow.turn.up.right"
        case lowered.contains("gauche"):
            name = "arrow.turn.up.left"
        case lowered.contains("rond-point"), lowered.contains("giratoire"):
            name = "arrow.triangle.turn.up.right.circle"
        case lowered.contains("arriv"), lowered.contains("destination"):
            name = "mappin.and.ellipse"
        default:
            name = "arrow.up"
        }
        return UIImage(systemName: name)
    }

    static func travelEstimates(distanceMeters: CLLocationDistance,
                                timeRemaining: TimeInterval) -> CPTravelEstimates {
        CPTravelEstimates(
            distanceRemaining: Measurement(value: max(0, distanceMeters), unit: UnitLength.meters),
            timeRemaining: max(0, timeRemaining)
        )
    }
}
