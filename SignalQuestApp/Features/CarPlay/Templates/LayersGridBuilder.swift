import CarPlay
import UIKit

/// Grille de bascule des couches de la carte.
///
/// Une pression = une couche activée ou désactivée, puis retour à la carte.
/// Pas de sous-menu, pas de réglage fin : CarPlay plafonne la grille à
/// `CPGridTemplateMaximumItems`, et de toute façon un écran de véhicule n'est
/// pas l'endroit où composer un filtre par bande.
///
/// L'état est lu et écrit dans `MapFilterStore`, donc partagé avec l'iPhone :
/// une couche masquée dans la voiture l'est aussi dans l'app, et inversement.
@MainActor
enum LayersGridBuilder {
    /// Les couches proposées au volant, dans l'ordre d'utilité en conduite.
    /// Volontairement un sous-ensemble de `MapDisplayItem.Kind` : amis, photos
    /// et validations n'ont rien à faire sur l'écran d'une voiture.
    static let offered: [MapDisplayItem.Kind] = [.antenna, .outage, .planned, .coverage, .speedtest]

    /// - Parameter onSentinelle: si fourni, ajoute l'accès aux box surveillées.
    ///   Il atterrit ici faute de place ailleurs — les quatre boutons de carte et
    ///   les quatre de barre sont pris — et cette grille est de fait le menu de
    ///   l'app dans le véhicule.
    static func make(current: Set<MapDisplayItem.Kind>,
                     onToggle: @escaping (MapDisplayItem.Kind) -> Void,
                     onSentinelle: (() -> Void)? = nil,
                     onSearch: (() -> Void)? = nil,
                     onRecents: (() -> Void)? = nil) -> CPGridTemplate {
        var buttons = offered.map { kind in
            CPGridButton(
                titleVariants: [title(for: kind, active: current.contains(kind))],
                image: image(for: kind, active: current.contains(kind))
            ) { _ in onToggle(kind) }
        }
        // Destinations avant Sentinelle : sur les véhicules à clavier bloqué en
        // roulant, « Récents » est la seule source encore utilisable, elle doit
        // rester atteignable même si la grille est tronquée.
        if let onRecents {
            buttons.append(CPGridButton(
                titleVariants: [String(localized: "Récents")],
                image: UIImage(systemName: "clock.arrow.circlepath") ?? UIImage()
            ) { _ in onRecents() })
        }
        if let onSearch {
            buttons.append(CPGridButton(
                titleVariants: [String(localized: "Rechercher")],
                image: UIImage(systemName: "magnifyingglass") ?? UIImage()
            ) { _ in onSearch() })
        }
        if let onSentinelle {
            buttons.append(CPGridButton(
                titleVariants: [String(localized: "Sentinelle")],
                image: UIImage(systemName: "wifi.router.fill") ?? UIImage()
            ) { _ in onSentinelle() })
        }
        // Troncature explicite : au-delà du plafond, CarPlay coupe en silence et
        // la dernière entrée disparaîtrait sans que rien ne le signale.
        return CPGridTemplate(title: String(localized: "Plus"),
                              gridButtons: Array(buttons.prefix(Int(CPGridTemplateMaximumItems))))
    }

    static func title(for kind: MapDisplayItem.Kind, active: Bool) -> String {
        let name: String
        switch kind {
        case .antenna: name = String(localized: "Antennes")
        case .outage: name = String(localized: "Pannes")
        case .planned: name = String(localized: "Évolutions")
        case .coverage: name = String(localized: "Couverture")
        case .speedtest: name = String(localized: "Speedtests")
        default: name = String(localized: "Couche")
        }
        // Le coche préfixe le libellé : CarPlay ne propose pas d'état « activé »
        // sur un bouton de grille, et une couleur seule ne se lit pas en roulant.
        return active ? "✓ \(name)" : name
    }

    static func image(for kind: MapDisplayItem.Kind, active: Bool) -> UIImage {
        // La couche « Antennes » porte le glyphe pylône de SignalQuest, le même
        // que les marqueurs de la carte : c'est le seul endroit de la grille où
        // l'identité de l'app peut s'exprimer, le reste relevant du vocabulaire
        // système que CarPlay impose de fait.
        if kind == .antenna {
            let color = active ? UIColor(SQColor.brandRed) : UIColor(SQColor.labelTertiary)
            return SQAntennaGlyph.image(size: 44, color: color)
        }
        let systemName: String
        switch kind {
        case .outage: systemName = "exclamationmark.triangle.fill"
        case .planned: systemName = "hammer.fill"
        case .coverage: systemName = "circle.hexagongrid.fill"
        case .speedtest: systemName = "speedometer"
        default: systemName = "square.3.layers.3d"
        }
        let image = UIImage(systemName: systemName) ?? UIImage()
        return active ? image : image.withAlpha(0.45)
    }
}

private extension UIImage {
    /// Une couche inactive est estompée plutôt que masquée : le conducteur voit
    /// ce qu'il peut activer sans avoir à chercher ailleurs.
    func withAlpha(_ alpha: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(at: .zero, blendMode: .normal, alpha: alpha)
        }
    }
}
