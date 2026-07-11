import SwiftUI

/// Dock de navigation flottant « Crème & Terre cuite ». Remplace la tab bar
/// système : capsule `SurfaceElevated` à 95 % + blur, marges 16 pt, posé
/// AU-DESSUS de la safe area (8 pt au-dessus de l'indicateur home — jamais
/// dessus), ombre dock. Item actif = pilule teintée brique + icône/libellé
/// brique ; inactifs = bruns discrets. Icônes 22 pt, libellés 9,5 pt.
struct SQDock: View {
    @Binding var selection: AppRouter.AppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Écart entre le bas du dock et la safe area (indicateur home sur
    /// Face ID, bord physique sur les appareils à bouton).
    static let bottomGap: CGFloat = 8

    /// Hauteur réservée AU-DESSUS de la safe area pour que le contenu ne se
    /// cache pas derrière le dock (capsule ~64 + bottomGap 8 + respiration 8).
    /// Sert au `safeAreaInset` des contenus.
    static let clearance: CGFloat = 80

    private let items: [(tab: AppRouter.AppTab, label: String, icon: String)] = [
        (.home, "Accueil", "house"),
        (.map, "Carte", "map"),
        (.speed, "Tester", "speedometer"),
        (.community, "Communauté", "person.2"),
        (.profile, "Profil", "person.crop.circle")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                dockItem(item)
            }
        }
        .padding(8)
        .background {
            Capsule(style: .continuous)
                .fill(SQColor.dockBackground)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
        .sqShadowDock()
        .padding(.horizontal, SQSpace.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation principale")
    }

    private func dockItem(_ item: (tab: AppRouter.AppTab, label: String, icon: String)) -> some View {
        let isActive = selection == item.tab
        return Button {
            Haptics.selection()
            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                selection = item.tab
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(item.label)
                    .font(SQFont.bodyFixed(9.5, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? SQColor.brandRed : SQColor.dockInactive)
            .background {
                if isActive {
                    Capsule(style: .continuous).fill(SQColor.accentSoft)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SQDockPressStyle())
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// Press = scale 0.94 (léger, comme le prototype).
private struct SQDockPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    /// Réserve la place du dock flottant en bas des contenus scrollables.
    /// À appliquer autour de chaque `NavigationStack` d'onglet : tout l'arbre
    /// (racine + pushes) hérite du safe area étendu. `active = false` retire
    /// la réserve (dock masqué, ex. conversation).
    func sqDockSafeArea(_ active: Bool = true) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if active {
                Color.clear.frame(height: SQDock.clearance)
            }
        }
    }
}
