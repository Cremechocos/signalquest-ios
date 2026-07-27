import SwiftUI

/// Primitives d'accessibilité réutilisables.
///
/// Poser ces modificateurs sur les composants PARTAGÉS plutôt que sur chaque
/// écran est le seul moyen tenable à l'échelle de l'app : `EmptyStateView` et
/// `ErrorStateView` sont utilisés sur des dizaines d'écrans, les traiter une
/// fois les couvre tous. C'est la même stratégie que pour Reduce Motion, câblé
/// dans `SQMotion` plutôt que répété partout.
extension View {

    /// Regroupe une carte en UN seul élément annoncé d'un bloc.
    ///
    /// Sans cela, VoiceOver fait balayer l'utilisateur à travers chaque texte et
    /// chaque icône de la carte — huit arrêts pour une information qui se lit
    /// d'un coup d'œil.
    func sqCard(label: String, value: String? = nil, hint: String? = nil) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
    }

    /// Tuile de mesure : « Téléchargement, 142 mégabits par seconde ».
    ///
    /// L'unité est énoncée en toutes lettres parce qu'un lecteur d'écran lit
    /// « Mbps » lettre par lettre. La valeur va en `accessibilityValue`, que
    /// VoiceOver annonce après le nom et que le rotor n'indexe pas.
    func sqMetric(name: String, value: String, unit: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
    }

    /// Élément purement décoratif : masqué au lecteur d'écran.
    ///
    /// Une icône qui double un texte adjacent n'apporte rien et double le
    /// nombre d'arrêts au balayage.
    func sqDecorative() -> some View {
        accessibilityHidden(true)
    }

    /// Marque un en-tête de section pour le rotor « En-têtes », qui permet de
    /// sauter de section en section au lieu de tout balayer.
    func sqHeader() -> some View {
        accessibilityAddTraits(.isHeader)
    }

    /// Remonte un élément dans l'ordre de balayage.
    ///
    /// À utiliser là où l'ordre visuel ne suit pas l'ordre d'importance : sur
    /// l'Accueil le héros doit précéder les statistiques, sur le speedtest le
    /// résultat doit précéder l'historique.
    func sqReadFirst(_ priority: Double = 1) -> some View {
        accessibilitySortPriority(priority)
    }
}
