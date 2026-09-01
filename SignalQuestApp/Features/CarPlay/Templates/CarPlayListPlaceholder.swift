import CarPlay

/// Ce qu'une liste CarPlay affiche tant qu'elle n'a rien à montrer.
///
/// Trois états, pas deux. Une liste CarPlay n'expose qu'un `emptyView`, et le
/// code s'en servait pour tout : au premier rendu comme après un échec réseau,
/// l'écran annonçait « Aucune box surveillée » ou « Rien à proximité ». C'est un
/// fait FAUX présenté comme certain — l'utilisateur en conclut que sa zone est
/// déserte alors que la requête n'est jamais arrivée. Au volant, où l'on ne
/// vérifiera pas, c'est la pire des sorties possibles.
///
/// L'échec, lui, ne passe pas par l'`emptyView` : celui-ci n'est pas
/// interactif. On pose un item ACTIONNABLE à la place, pour que « réessayer »
/// soit à portée de pouce plutôt que de nécessiter un retour arrière.
@MainActor
enum CarPlayListPlaceholder {
    /// Premier rendu, requête en vol.
    static func applyLoading(to template: CPListTemplate) {
        template.updateSections([])
        template.emptyViewTitleVariants = [String(localized: "Chargement…")]
        template.emptyViewSubtitleVariants = []
    }

    /// Réponse reçue, réellement vide. C'est le seul cas où l'on a le droit
    /// d'affirmer qu'il n'y a rien.
    static func applyEmpty(to template: CPListTemplate, title: String, subtitle: String) {
        template.updateSections([])
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [subtitle]
    }

    /// Requête échouée : on le dit, et on propose de recommencer.
    static func applyFailure(to template: CPListTemplate,
                             message: String? = nil,
                             onRetry: @escaping () -> Void) {
        let item = CPListItem(
            text: String(localized: "Réessayer"),
            detailText: message ?? String(localized: "Impossible de charger pour le moment.")
        )
        item.setImage(UIImage(systemName: "arrow.clockwise"))
        item.handler = { _, completion in
            onRetry()
            completion()
        }
        template.updateSections([CPListSection(items: [item])])
    }
}
