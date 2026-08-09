import CarPlay
import UIKit

/// Écran Sentinelle : l'état des box surveillées.
///
/// Le tri passe par `SentinelleListOrder`, partagé avec le web, Android et
/// l'app iPhone. C'est délibéré : ce module porte en commentaire que les
/// plateformes doivent trier IDENTIQUEMENT, faute de quoi la même liste se lit
/// différemment selon l'appareil. CarPlay est une quatrième surface, pas une
/// exception — et le tri par état, qui met le pire en tête, est exactement ce
/// qu'on veut au volant.
///
/// Pas de graphe ici : `SentinelleCharts` est du SwiftUI, et une courbe ne se
/// lit pas en conduisant.
@MainActor
enum SentinelleTemplateBuilder {
    static func list(targets: [SentinelleTarget],
                     onSelect: @escaping (SentinelleTarget) -> Void) -> CPListTemplate {
        let ordered = SentinelleListOrder.sorted(targets, by: .state)
        let items: [CPListItem] = ordered.prefix(CPListTemplate.maximumItemCount).map { target in
            let item = CPListItem(text: title(for: target), detailText: subtitle(for: target))
            item.setImage(statusDot(for: target.status))
            item.handler = { _, completion in
                onSelect(target)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: String(localized: "Sentinelle"),
                                      sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [String(localized: "Aucune box surveillée")]
        template.emptyViewSubtitleVariants = [
            String(localized: "Ajoute une connexion à surveiller depuis l'app.")
        ]
        return template
    }

    static func detail(_ target: SentinelleTarget) -> CPInformationTemplate {
        var items: [CPInformationItem] = [
            CPInformationItem(title: String(localized: "État"), detail: statusLabel(target.status))
        ]
        if let since = target.statusSince {
            items.append(CPInformationItem(title: String(localized: "Depuis"), detail: since))
        }
        if let owner = target.ownerLabel {
            items.append(CPInformationItem(title: String(localized: "Connexion de"),
                                           detail: [target.ownerEmoji, owner].compactMap { $0 }.joined(separator: " ")))
        }
        items.append(CPInformationItem(title: String(localized: "Adresse"), detail: target.displayAddress))
        if let probe = target.lastProbeAt {
            items.append(CPInformationItem(title: String(localized: "Dernière sonde"), detail: probe))
        }
        return CPInformationTemplate(
            title: title(for: target),
            layout: .twoColumn,
            items: Array(items.prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: []
        )
    }

    /// L'emoji du propriétaire précède le nom, comme dans l'app : c'est ce qui
    /// permet de repérer « la box des parents » sans lire.
    static func title(for target: SentinelleTarget) -> String {
        guard let emoji = target.ownerEmoji, !emoji.isEmpty else { return target.label }
        return "\(emoji) \(target.label)"
    }

    static func subtitle(for target: SentinelleTarget) -> String {
        guard let since = target.statusSince, !since.isEmpty else { return statusLabel(target.status) }
        return "\(statusLabel(target.status)) · \(since)"
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "up": return String(localized: "Répond normalement")
        case "down": return String(localized: "Ne répond plus")
        case "degraded": return String(localized: "Dégradée")
        default: return String(localized: "État inconnu")
        }
    }

    /// Pastille de couleur, générée plutôt que dessinée en asset : trois états,
    /// et CarPlay veut une image. Le vert et le rouge viennent du design system,
    /// donc la voiture et le téléphone parlent la même langue visuelle.
    static func statusDot(for status: String) -> UIImage {
        let color: UIColor
        switch status {
        case "up": color = UIColor(SQColor.success)
        case "down": color = UIColor(SQColor.danger)
        case "degraded": color = UIColor(SQColor.warning)
        default: color = UIColor(SQColor.labelTertiary)
        }
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
    }
}
