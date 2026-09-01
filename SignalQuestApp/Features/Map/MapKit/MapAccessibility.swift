import Foundation
import MapKit
import UIKit

/// Élément virtuel pour les couches Core Graphics de la carte. Contrairement à
/// une annotation MapKit, un point d'overlay n'a aucune vue UIKit et ne peut
/// donc pas recevoir VoiceOver sans représentation explicite.
final class SQMapOverlayAccessibilityElement: UIAccessibilityElement {
    var activation: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        activation?()
        return activation != nil
    }
}

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
        if payload.isSearchPin {
            let title = payload.title.isEmpty ? String(localized: "sans nom") : payload.title
            return SQAnnotationDescription(
                label: String(localized: "Lieu recherché \(title)"),
                value: payload.subtitle.isEmpty ? nil : payload.subtitle,
                hint: String(localized: "Point temporaire de recherche")
            )
        }
        // Un cluster n'est pas un lieu : on annonce ce qu'il regroupe.
        if let count = payload.clusterCount, count > 1 {
            return SQAnnotationDescription(
                label: String(localized: "Groupe de \(count) \(pluralNoun(for: payload.kind, count: count))"),
                value: payload.subtitle.isEmpty ? nil : payload.subtitle,
                hint: String(localized: "Zoome pour séparer les éléments")
            )
        }

        let title = payload.title.isEmpty ? fallbackTitle(for: payload.kind) : payload.title
        let label = "\(noun(for: payload)) \(title)"
        // `subtitle` et `metric` portent l'information utile (opérateur, techno,
        // débit, distance) : elle va en `value`, que VoiceOver énonce APRÈS le
        // label et que le rotor n'utilise pas pour la recherche.
        var parts = [payload.subtitle, payload.metric]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        // Une panne posée sur une antenne n'est qu'un petit badge en diagonale : à
        // l'œil c'est une pastille de plus, pour VoiceOver ce n'était rien du tout.
        // Le badge est pourtant la SEULE trace de la panne quand le filtre
        // « Pannes » est éteint.
        // Le badge suit le marqueur qui le porte, pas seulement les antennes : un site posé à la
        // main en porte un aussi, et dans un marché sans référentiel public c'est le seul point
        // qui puisse en porter.
        if payload.kind != .communityOutage, let mark = payload.communityOutage {
            parts.append(outageBadgeAnnouncement(mark))
        }
        // Le badge d'incident OPÉRATEUR, avec la source nommée : c'est ce qui le distingue du
        // précédent, et à l'œil c'est la forme du badge qui le dit — VoiceOver, lui, ne peut le
        // savoir que si on l'énonce.
        if payload.kind != .outage, let incident = payload.operatorIncident {
            parts.append(operatorBadgeAnnouncement(incident))
        }
        let value = parts.joined(separator: ", ")

        return SQAnnotationDescription(
            label: label,
            value: value.isEmpty ? nil : value,
            hint: hint(for: payload.kind)
        )
    }

    /// La nature de l'élément, affinée par ce que le marqueur montre réellement.
    ///
    /// Une panne confirmée et une panne seulement signalée se distinguent à l'œil
    /// (pastille pleine contre pastille évidée) : les annoncer toutes deux « Panne
    /// signalée » effacerait pour VoiceOver la seule nuance que la fonctionnalité
    /// cherche à établir — qui affirme quoi, et avec quelle corroboration.
    private static func noun(for payload: MapAnnotationPayload) -> String {
        if payload.kind == .communityOutage, let mark = payload.communityOutage {
            return mark.confirmed
                ? String(localized: "Panne confirmée")
                : String(localized: "Panne signalée")
        }
        return noun(for: payload.kind)
    }

    /// Ce que le badge de panne ajoute à l'annonce d'une antenne.
    ///
    /// Une phrase entière par cas, jamais deux fragments recollés : l'app est
    /// livrée en cinq langues, et l'ordre « état + gravité » n'y tient pas partout.
    private static func outageBadgeAnnouncement(_ mark: CommunityOutageMark) -> String {
        switch (mark.confirmed, mark.severity) {
        case (true, .down): return String(localized: "Panne confirmée : plus aucun service")
        case (true, .degraded): return String(localized: "Panne confirmée : service dégradé")
        case (false, .down): return String(localized: "Panne signalée : plus aucun service")
        case (false, .degraded): return String(localized: "Panne signalée : service dégradé")
        }
    }

    /// Ce que le badge d'incident opérateur ajoute à l'annonce d'un site.
    ///
    /// La SOURCE est nommée dans la phrase — « déclaré par l'opérateur ». C'est l'équivalent
    /// sonore du triangle : sans elle, VoiceOver rendrait indiscernables une déclaration de
    /// première main et une observation en attente de corroboration.
    private static func operatorBadgeAnnouncement(_ mark: OperatorIncidentMark) -> String {
        switch mark.issueType {
        case "maintenance": return String(localized: "Maintenance déclarée par l'opérateur")
        case "degraded": return String(localized: "Service dégradé déclaré par l'opérateur")
        default: return String(localized: "Site hors service déclaré par l'opérateur")
        }
    }

    private static func noun(for kind: MapDisplayItem.Kind) -> String {
        switch kind {
        case .antenna: return String(localized: "Antenne")
        case .photo: return String(localized: "Photo")
        case .friend: return String(localized: "Ami")
        case .validation: return String(localized: "Validation")
        case .session: return String(localized: "Session")
        case .outage: return String(localized: "Incident")
        case .communityOutage: return String(localized: "Panne signalée")
        case .planned: return String(localized: "Site prévu")
        case .communitySite: return String(localized: "Cellule observée")
        case .customSite: return String(localized: "Site ajouté par un membre")
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
        case .communityOutage: return String(localized: "pannes signalées")
        case .planned: return String(localized: "sites prévus")
        case .communitySite: return String(localized: "cellules observées")
        case .customSite: return String(localized: "sites ajoutés par des membres")
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
        case .communityOutage: return String(localized: "Ouvre le détail de la panne signalée")
        case .planned: return String(localized: "Ouvre le détail du site prévu")
        case .customSite: return String(localized: "Ouvre la fiche du site ajouté")
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
