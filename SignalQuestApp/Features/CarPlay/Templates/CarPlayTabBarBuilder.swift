import CarPlay

/// Racine à onglets.
///
/// La racine était une liste de quatre intitulés génériques : rien ne
/// s'affichait avant d'avoir touché quelque chose, et chaque fonction coûtait un
/// aller-retour dans la pile. En voiture, l'information doit être là AVANT
/// l'interaction — c'est la règle la plus élémentaire de l'exercice.
///
/// Les onglets règlent les deux problèmes d'un coup :
///
/// - chaque fonction est à un doigt, sans navigation ;
/// - surtout, ils LIBÈRENT un niveau de pile. La catégorie « driving task »
///   plafonne à deux templates empilés ; l'ancienne arborescence
///   racine → liste → fiche en demandait trois, et le troisième était refusé par
///   le système, en silence. Avec les onglets, l'écran de contenu EST la racine,
///   et il reste un niveau disponible pour une fiche.
///
/// ⚠️ `maximumTabCount` dépend des entitlements et le système LÈVE UNE
/// EXCEPTION au-delà — d'où la troncature, qui n'est pas une précaution de
/// confort.
@MainActor
enum CarPlayTabBarBuilder {
    static func make(tabs: [CPTemplate]) -> CPTabBarTemplate {
        CPTabBarTemplate(templates: Array(tabs.prefix(maximumTabCount)))
    }

    /// Plafond publié par CarPlay, avec repli hors véhicule (la propriété vaut 0
    /// tant qu'aucune scène n'est connectée, ce qui viderait la barre en test).
    static var maximumTabCount: Int {
        let published = CPTabBarTemplate.maximumTabCount
        return published > 0 ? published : 4
    }

    /// Habille un template pour qu'il devienne un onglet lisible.
    ///
    /// CarPlay retombe sur le titre du template si l'on ne donne rien, ce qui
    /// produit des onglets nommés « SignalQuest » à l'identique.
    static func decorate(_ template: CPTemplate, title: String, systemImage: String) -> CPTemplate {
        template.tabTitle = title
        template.tabImage = UIImage(systemName: systemImage)
        return template
    }
}
