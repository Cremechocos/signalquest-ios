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
        // langue de l'appareil, qui peut ne pas être celle de l'app).
        for separator in [" sur ", " onto ", " auf ", " in die ", " in den ", " hacia ", " in via ",
                          " su ", " naar ", " op ", " para a ", " para o ", " em direção a "] {
            guard let range = trimmed.range(of: separator, options: .caseInsensitive) else { continue }
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

    /// Mots-clés français, anglais, allemands, espagnols, italiens, néerlandais
    /// et portugais : MapKit rédige les consignes dans la langue de l'appareil,
    /// sans type de manœuvre public, et un iPhone dans une autre langue n'avait
    /// que la flèche neutre (CAR-04, INT-iOS-21).
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
        // Demi-tour, rond-point et arrivée se lisent dans toute la consigne : la
        // coupe avant le nom de voie tombe parfois avant eux (« Ha llegado a su
        // destino »). Seules les directions s'arrêtent avant le nom de la voie.
        let fullWords = instruction.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let fullText = " " + fullWords.joined(separator: " ") + " "
        func states(_ phrases: String...) -> Bool { phrases.contains { fullText.contains(" \($0) ") } }
        switch true {
        case states("demi tour", "faites demi", "u turn", "wenden", "kehrtwende", "cambio de sentido",
                      "media vuelta", "gira en u", "inversione", "keer om", "omkeren", "u bocht",
                      "retorno", "inversão de marcha", "meia volta"):
            return "arrow.uturn.left"
        // Rond-point et arrivée avant les virages : « Au rond-point, prenez la
        // deuxième sortie à droite » reste un rond-point, « Votre destination est
        // à droite » reste l'arrivée.
        case states("rond point", "giratoire", "roundabout", "kreisverkehr", "rotonda", "glorieta",
                      "rotatoria", "rotonde", "rotunda", "rotatória"):
            return "arrow.triangle.turn.up.right.circle"
        case fullWords.contains(where: { $0.hasPrefix("arriv") }),
             states("destination", "ziel", "destino", "llegada", "llegado", "destinazione", "bestemming", "chegada"):
            return "mappin.and.ellipse"
        case mentions("légèrement à droite", "serrez à droite", "slight right", "keep right", "bear right",
                      "leicht rechts", "rechts halten", "ligeramente a la derecha", "mantente a la derecha",
                      "manténgase a la derecha", "leggermente a destra", "mantieni la destra", "tieniti a destra",
                      "flauwe bocht naar rechts", "rechts aanhouden", "houd rechts aan",
                      "ligeiramente à direita", "mantenha se à direita", "mantenha a direita"):
            return "arrow.up.right"
        case mentions("légèrement à gauche", "serrez à gauche", "slight left", "keep left", "bear left",
                      "leicht links", "links halten", "ligeramente a la izquierda", "mantente a la izquierda",
                      "manténgase a la izquierda", "leggermente a sinistra", "mantieni la sinistra", "tieniti a sinistra",
                      "flauwe bocht naar links", "links aanhouden", "houd links aan",
                      "ligeiramente à esquerda", "mantenha se à esquerda", "mantenha a esquerda"):
            return "arrow.up.left"
        case mentions("droite", "right", "rechts", "rechtsaf", "derecha", "destra", "direita"):
            return "arrow.turn.up.right"
        case mentions("gauche", "left", "links", "linksaf", "izquierda", "sinistra", "esquerda"):
            return "arrow.turn.up.left"
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
