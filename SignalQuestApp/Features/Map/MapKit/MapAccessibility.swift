import Foundation
import MapKit
import UIKit

/// Ce qu'un lecteur d'écran annonce pour une annotation de carte.
struct SQAnnotationDescription {
    let label: String
    let value: String?
    let hint: String?
}

/// Source unique des descriptions d'accessibilité de la carte.
///
/// Avant ce fichier, le projet ne comptait **aucun** `isAccessibilityElement` ni
/// `accessibilityLabel` de forme UIKit : les cinq sous-classes de
/// `MKAnnotationView` n'exposaient rien. Un utilisateur de VoiceOver ne pouvait
/// donc ni énumérer ni sélectionner une antenne, un ami ou une photo — sur la
/// fonction centrale de l'app.
///
/// Le `switch` est exhaustif sur `MapDisplayItem.Kind`, comme
/// `SQMapKitMarkerView.glyphName(for:)` : un nouveau type d'annotation force à
/// écrire sa description plutôt que de la laisser silencieusement vide.
enum MapAccessibility {

    static func describe(_ payload: MapAnnotationPayload) -> SQAnnotationDescription {
        // Un cluster n'est pas un lieu : on annonce ce qu'il regroupe.
        if let count = payload.clusterCount, count > 1 {
            return SQAnnotationDescription(
                label: String(localized: "Groupe de \(count) \(pluralNoun(for: payload.kind, count: count))"),
                value: payload.subtitle.isEmpty ? nil : payload.subtitle,
                hint: String(localized: "Zoome pour séparer les éléments")
            )
        }

        let title = payload.title.isEmpty ? fallbackTitle(for: payload.kind) : payload.title
        let label = "\(noun(for: payload.kind)) \(title)"
        // `subtitle` et `metric` portent l'information utile (opérateur, techno,
        // débit, distance) : elle va en `value`, que VoiceOver énonce APRÈS le
        // label et que le rotor n'utilise pas pour la recherche.
        let value = [payload.subtitle, payload.metric]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")

        return SQAnnotationDescription(
            label: label,
            value: value.isEmpty ? nil : value,
            hint: hint(for: payload.kind)
        )
    }

    private static func noun(for kind: MapDisplayItem.Kind) -> String {
        switch kind {
        case .antenna: return String(localized: "Antenne")
        case .photo: return String(localized: "Photo")
        case .friend: return String(localized: "Ami")
        case .validation: return String(localized: "Validation")
        case .session: return String(localized: "Session")
        case .outage: return String(localized: "Incident")
        case .planned: return String(localized: "Site prévu")
        case .communitySite: return String(localized: "Site communautaire")
        case .speedtest: return String(localized: "Mesure de débit")
        case .coverage: return String(localized: "Point de couverture")
        }
    }

    private static func pluralNoun(for kind: MapDisplayItem.Kind, count: Int) -> String {
        switch kind {
        case .antenna: return String(localized: "antennes")
        case .photo: return String(localized: "photos")
        case .friend: return String(localized: "amis")
        case .validation: return String(localized: "validations")
        case .session: return String(localized: "sessions")
        case .outage: return String(localized: "incidents")
        case .planned: return String(localized: "sites prévus")
        case .communitySite: return String(localized: "sites communautaires")
        case .speedtest: return String(localized: "mesures de débit")
        case .coverage: return String(localized: "points de couverture")
        }
    }

    private static func fallbackTitle(for kind: MapDisplayItem.Kind) -> String {
        String(localized: "sans nom")
    }

    /// L'indice ne répète pas le label : il dit ce que le tap PRODUIT, ce qui
    /// n'est pas déductible visuellement pour un lecteur d'écran.
    private static func hint(for kind: MapDisplayItem.Kind) -> String? {
        switch kind {
        case .antenna: return String(localized: "Ouvre la fiche de l'antenne")
        case .photo: return String(localized: "Ouvre la photo en plein écran")
        case .friend: return String(localized: "Ouvre la fiche de l'ami")
        case .outage: return String(localized: "Ouvre le détail de l'incident")
        case .planned: return String(localized: "Ouvre le détail du site prévu")
        case .communitySite, .validation, .session, .speedtest, .coverage: return nil
        }
    }
}

/// Applique une description à une vue d'annotation.
///
/// Une extension par défaut plutôt qu'une duplication dans chaque classe : le
/// texte est écrit une seule fois et un oubli devient visible.
protocol SQAccessibleAnnotationView: MKAnnotationView {}

extension SQAccessibleAnnotationView {
    func applyAccessibility(for payload: MapAnnotationPayload) {
        let description = MapAccessibility.describe(payload)
        isAccessibilityElement = true
        accessibilityLabel = description.label
        accessibilityValue = description.value
        accessibilityHint = description.hint
        accessibilityTraits = .button
        // Ancre STABLE pour les tests : les libellés visibles (« Photos »,
        // « Antennes ») existent aussi sur les puces de filtre, donc matcher le
        // texte ne prouverait pas que le MARQUEUR est exposé.
        accessibilityIdentifier = "map.marker"
    }
}
