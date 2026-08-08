import CarPlay

/// Construit les templates racine de la surface CarPlay.
///
/// Fonctions PURES — aucune I/O, aucun état retenu, entrées explicites. C'est
/// ce qui rend la surface vérifiable en test unitaire : le système ne fournit
/// jamais de `CPInterfaceController` hors d'un véhicule, mais les templates
/// s'instancient librement.
@MainActor
enum CarPlayRootTemplateBuilder {
    /// Écran posé immédiatement à la connexion, le temps de l'amorçage.
    /// CarPlay exige un template racine sans délai : laisser l'écran vide
    /// pendant un appel réseau donnerait une app figée au démarrage du véhicule.
    static func loading() -> CPListTemplate {
        let item = CPListItem(text: String(localized: "Chargement…"), detailText: nil)
        return CPListTemplate(
            title: String(localized: "SignalQuest"),
            sections: [CPListSection(items: [item])]
        )
    }

    static func root(isAuthenticated: Bool, showsMap: Bool) -> CPListTemplate {
        guard isAuthenticated else {
            // Pas de parcours de connexion au volant : saisir un mot de passe en
            // conduisant n'est ni faisable ni acceptable en revue App Store.
            let item = CPListItem(
                text: String(localized: "Connexion requise"),
                detailText: String(localized: "Ouvre SignalQuest sur ton iPhone pour te connecter.")
            )
            return CPListTemplate(
                title: String(localized: "SignalQuest"),
                sections: [CPListSection(items: [item])]
            )
        }

        let mode = CPListItem(
            text: showsMap
                ? String(localized: "Carte des antennes")
                : String(localized: "Antennes autour de toi"),
            detailText: showsMap
                ? nil
                : String(localized: "Mode liste : la carte demande l'autorisation CarPlay d'Apple.")
        )
        return CPListTemplate(
            title: String(localized: "SignalQuest"),
            sections: [CPListSection(items: [mode])]
        )
    }
}
