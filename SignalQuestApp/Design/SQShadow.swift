import SwiftUI

/// Ombres du système « Crème & Terre cuite ». Elles REMPLACENT les bordures :
/// une carte n'a jamais à la fois ombre et bordure (règle No-Border — seule
/// exception : la rangée « moi » des classements).
///
/// Correspondance avec le prototype :
/// - `sqShadowSoft`   : `0 2 8  encre@5%`  (chips, petites tuiles)
/// - `sqShadowCard`   : `0 4 18 encre@6%`  (cartes)
/// - `sqShadowAccent` : `0 8 22 brique@28%` (surfaces accent : tuile Tester, FAB…)
/// - `sqShadowDock`   : `0 10 30 encre@14%` (dock flottant, sheets détachées)
/// Les variantes sombres (noir 30–50 %) sont portées par les couleurs
/// dynamiques de `SQColor`.
extension View {
    /// Ombre repos — chips, petites tuiles, boutons secondaires.
    nonisolated func sqShadowSoft() -> some View {
        shadow(color: SQColor.shadowSoft, radius: 4, x: 0, y: 2)
    }

    /// Ombre carte — toutes les cartes de contenu.
    nonisolated func sqShadowCard() -> some View {
        shadow(color: SQColor.shadowCard, radius: 9, x: 0, y: 4)
    }

    /// Ombre accent — uniquement sous les surfaces brique.
    nonisolated func sqShadowAccent() -> some View {
        shadow(color: SQColor.shadowAccent, radius: 11, x: 0, y: 8)
    }

    /// Ombre du dock flottant et des sheets détachées.
    nonisolated func sqShadowDock() -> some View {
        shadow(color: SQColor.shadowDock, radius: 15, x: 0, y: 10)
    }
}
