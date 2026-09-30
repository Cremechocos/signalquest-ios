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
            maneuver(for: plan.steps[index], in: plan)
        }
    }

    static func maneuver(for step: RoutePlan.Step, in plan: RoutePlan) -> CPManeuver {
        let maneuver = CPManeuver()
        // Plusieurs variantes : CarPlay choisit la plus longue qui tient dans la
        // largeur disponible, qui varie d'un véhicule à l'autre.
        maneuver.instructionVariants = instructionVariants(for: step.instruction)
        maneuver.symbolImage = symbol(for: step.instruction)
        maneuver.initialTravelEstimates = travelEstimates(
            distanceMeters: step.distanceMeters,
            timeRemaining: timeRemaining(forDistance: step.distanceMeters, in: plan)
        )
        return maneuver
    }

    /// Temps restant au prorata de la distance, sur la durée que MapKit prévoit
    /// pour tout le trajet. Approximatif, mais un temps nul envoyé à chaque
    /// position laissait le véhicule sans estimation (CAR-04).
    static func timeRemaining(forDistance meters: CLLocationDistance, in plan: RoutePlan) -> TimeInterval {
        guard plan.totalDistanceMeters > 0 else { return 0 }
        return plan.expectedTravelTime * max(0, meters) / plan.totalDistanceMeters
    }

    /// De la plus complète à la plus courte : sur un petit écran, mieux vaut une
    /// instruction tronquée intelligemment qu'un texte coupé au milieu d'un mot.
    static func instructionVariants(for instruction: String) -> [String] {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [String(localized: "Continuez")] }
        // « Tournez à droite sur la rue de Rivoli » → « Tournez à droite »,
        // « Turn right onto Main Street » → « Turn right » (MapKit parle la
        // langue de l'appareil).
        for separator in [" sur ", " onto "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let short = String(trimmed[trimmed.startIndex..<range.lowerBound])
            if short.count >= 4 { return [trimmed, short] }
        }
        return [trimmed]
    }

    /// Déduit le pictogramme du texte. Le repli neutre est délibéré : un symbole
    /// « à droite » sur une manœuvre à gauche est pire que pas de symbole.
    static func symbol(for instruction: String) -> UIImage? {
        UIImage(systemName: symbolName(for: instruction))
    }

    /// Mots-clés français ET anglais : MapKit rédige les consignes dans la
    /// langue de l'appareil, et un iPhone en anglais n'avait que la flèche
    /// neutre (CAR-04).
    ///
    /// Mots entiers, et seulement avant le nom de la voie : « Turn left onto
    /// Wright Street » ne doit pas afficher une flèche à droite.
    static func symbolName(for instruction: String) -> String {
        let head = instructionVariants(for: instruction).last ?? instruction
        let words = head.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let text = " " + words.joined(separator: " ") + " "
        func mentions(_ phrases: String...) -> Bool { phrases.contains { text.contains(" \($0) ") } }
        switch true {
        case mentions("demi tour", "faites demi", "u turn"):
            return "arrow.uturn.left"
        case mentions("légèrement à droite", "serrez à droite", "slight right", "keep right", "bear right"):
            return "arrow.up.right"
        case mentions("légèrement à gauche", "serrez à gauche", "slight left", "keep left", "bear left"):
            return "arrow.up.left"
        case mentions("droite", "right"):
            return "arrow.turn.up.right"
        case mentions("gauche", "left"):
            return "arrow.turn.up.left"
        case mentions("rond point", "giratoire", "roundabout"):
            return "arrow.triangle.turn.up.right.circle"
        case words.contains(where: { $0.hasPrefix("arriv") }), mentions("destination"):
            return "mappin.and.ellipse"
        default:
            return "arrow.up"
        }
    }

    static func travelEstimates(distanceMeters: CLLocationDistance,
                                timeRemaining: TimeInterval) -> CPTravelEstimates {
        CPTravelEstimates(
            distanceRemaining: Measurement(value: max(0, distanceMeters), unit: UnitLength.meters),
            timeRemaining: max(0, timeRemaining)
        )
    }
}
