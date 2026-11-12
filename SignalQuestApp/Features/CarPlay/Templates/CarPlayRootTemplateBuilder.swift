import CarPlay

/// Construit les templates racine de la surface CarPlay : chargement, session
/// absente, et la liste de repli posée si le véhicule refusait les onglets.
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
        case nearby, here, speedtest

        var title: String {
            switch self {
            case .nearby: return String(localized: "Antennes autour")
            case .here: return String(localized: "Ici")
            case .speedtest: return String(localized: "Speedtest")
            }
        }

        var subtitle: String {
            switch self {
            case .nearby: return String(localized: "Les sites les plus proches")
            case .here: return String(localized: "Ce que vaut le réseau à cet endroit")
            case .speedtest: return String(localized: "Mesurer la connexion")
            }
        }

        var systemImageName: String {
            switch self {
            case .nearby: return "antenna.radiowaves.left.and.right"
            case .here: return "dot.radiowaves.left.and.right"
            case .speedtest: return "speedometer"
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
        // conduisant n'est ni faisable ni acceptable en revue App Store. Et le
        // message constate l'état sans demander de prendre l'iPhone : Apple
        // l'interdit, même pour une erreur (CarPlay Developer Guide, règle 2).
        let item = CPListItem(
            text: String(localized: "Connexion requise"),
            detailText: String(localized: "Aucun compte SignalQuest n'est connecté.")
        )
        return CPListTemplate(
            title: String(localized: "SignalQuest"),
            sections: [CPListSection(items: [item])]
        )
    }

    /// Racine de repli, posée seulement si le véhicule refuse les onglets.
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
