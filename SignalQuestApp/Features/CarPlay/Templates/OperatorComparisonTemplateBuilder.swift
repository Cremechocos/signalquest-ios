import CarPlay
import UIKit

/// « Qui capte le mieux ici ? »
///
/// La question la plus utile que SignalQuest sache trancher, et la seule de
/// l'app dont la réponse change vraiment d'un endroit à l'autre. Le service qui
/// la calcule (`operatorRanking`) existait déjà et alimentait la sheet de
/// l'iPhone ; le véhicule ne l'exposait pas.
///
/// Rendu en liste et non en fiche : un classement se lit par rang, et
/// `CPInformationTemplate` alignerait des paires clé/valeur sans ordre visible.
/// La pastille de couleur donne le verdict avant même la lecture.
@MainActor
enum OperatorComparisonTemplateBuilder {
    static func make(stats: [OperatorMetricStat],
                     metric: NearbyOperatorMetric) -> CPListTemplate {
        let template = CPListTemplate(title: title(for: metric),
                                      sections: [CPListSection(items: items(for: stats, metric: metric))])
        template.emptyViewTitleVariants = [String(localized: "Pas assez de mesures")]
        template.emptyViewSubtitleVariants = [
            String(localized: "La communauté n'a pas encore assez mesuré cette zone.")
        ]
        return template
    }

    static func items(for stats: [OperatorMetricStat],
                      metric: NearbyOperatorMetric) -> [CPListItem] {
        stats.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, stat in
            let item = CPListItem(text: "\(index + 1). \(stat.operatorName)",
                                  detailText: detail(for: stat, metric: metric))
            // Couleur de l'opérateur plutôt que du verdict : à cette échelle,
            // c'est elle qui permet de retrouver le sien d'un coup d'œil, sans
            // lire les noms.
            item.setImage(CarPlayImageFactory.dot(
                color: UIColor(SQBrand.operatorColor(stat.operatorName))
            ))
            return item
        }
    }

    /// La valeur d'abord, le nombre de mesures ensuite : « 42 Mb/s » répond à la
    /// question, « sur 128 mesures » dit à quel point on peut s'y fier.
    static func detail(for stat: OperatorMetricStat, metric: NearbyOperatorMetric) -> String {
        var parts = ["\(stat.value) \(metric.unit)"]
        if let extra = stat.detail, !extra.isEmpty { parts.append(extra) }
        parts.append(String(localized: "\(stat.sampleCount) mesures"))
        return parts.joined(separator: " · ")
    }

    static func title(for metric: NearbyOperatorMetric) -> String {
        switch metric {
        case .download: return String(localized: "Débit par opérateur")
        case .signal: return String(localized: "Signal par opérateur")
        }
    }
}
