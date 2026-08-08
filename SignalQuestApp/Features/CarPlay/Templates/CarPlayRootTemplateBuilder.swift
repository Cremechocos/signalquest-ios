import CarPlay

/// Construit les templates racine de la surface CarPlay.
///
/// Deux racines très différentes selon l'entitlement accordé par Apple :
///
/// - avec `carplay-maps`, la racine est la CARTE (`CPMapTemplate`) et cette
///   liste ne sert qu'aux états dégradés — chargement, session absente ;
/// - sans elle, cette liste EST l'application. Tout doit donc y être
///   atteignable, sans quoi la scène s'ouvrirait sur un écran inerte alors que
///   fiches, speedtest, « Ici » et Sentinelle existent déjà.
///
/// Fonctions pures — aucune I/O, entrées explicites. C'est ce qui rend la
/// surface vérifiable en test : le système ne fournit jamais de
/// `CPInterfaceController` hors d'un véhicule, mais les templates s'instancient
/// librement.
@MainActor
enum CarPlayRootTemplateBuilder {
    /// Destinations de la racine en mode liste. L'ordre est celui de l'utilité
    /// au volant : ce qui est autour, puis ce qu'on capte, puis les outils.
    enum Entry: CaseIterable {
        case nearby, here, speedtest, sentinelle

        var title: String {
            switch self {
            case .nearby: return String(localized: "Antennes autour")
            case .here: return String(localized: "Ici")
            case .speedtest: return String(localized: "Débit")
            case .sentinelle: return String(localized: "Sentinelle")
            }
        }

        var subtitle: String {
            switch self {
            case .nearby: return String(localized: "Les sites les plus proches")
            case .here: return String(localized: "Ce que vaut le réseau à cet endroit")
            case .speedtest: return String(localized: "Mesurer la connexion")
            case .sentinelle: return String(localized: "État des box surveillées")
            }
        }

        var systemImageName: String {
            switch self {
            case .nearby: return "antenna.radiowaves.left.and.right"
            case .here: return "dot.radiowaves.left.and.right"
            case .speedtest: return "speedometer"
            case .sentinelle: return "wifi.router.fill"
            }
        }
    }

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

    static func signedOut() -> CPListTemplate {
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

    /// Racine du mode liste — l'application entière quand Apple n'a pas accordé
    /// la catégorie navigation.
    static func list(onSelect: @escaping (Entry) -> Void) -> CPListTemplate {
        let items: [CPListItem] = Entry.allCases.map { entry in
            let item = CPListItem(text: entry.title, detailText: entry.subtitle)
            item.setImage(UIImage(systemName: entry.systemImageName))
            item.handler = { _, completion in
                onSelect(entry)
                completion()
            }
            return item
        }
        return CPListTemplate(
            title: String(localized: "SignalQuest"),
            sections: [CPListSection(items: items)]
        )
    }
}
