import SwiftUI

/// Dock de navigation flottant « Crème & Terre cuite ». Remplace la tab bar
/// système sur TOUTES les versions d'iOS : la barre native iOS 26 flotte
/// collée à l'indicateur home (~21 pt du bord physique, sans réglage
/// possible) ; le dock est posé 8 pt AU-DESSUS de la safe area (~42 pt du
/// bord), jamais sur l'indicateur. Matériau : vrai Liquid Glass
/// (`glassEffect`) sur iOS 26+, capsule crème translucide + blur avant.
/// Item actif = pilule teintée brique ; inactifs = bruns discrets.
/// `minimized` rétracte le dock en pastille (icône de l'onglet actif),
/// piloté au scroll par `sqDockAutoMinimize`.
struct SQDock: View {
    @Binding var selection: AppRouter.AppTab
    /// Conversations non lues — badge sur l'onglet Communauté.
    var communityBadge: Int = 0
    /// Rétracté en pastille après un scroll vers le bas.
    var minimized: Bool = false
    /// Appelé quand on tape la pastille rétractée pour redéployer le dock.
    var onExpand: () -> Void = {}
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
            if minimized {
                expandButton
            } else {
                ForEach(items, id: \.tab) { item in
                    dockItem(item)
                }
            }
        }
        .padding(minimized ? 5 : 8)
        // Sur iPad la capsule reste une pilule compacte centrée, pas un ruban.
        .frame(maxWidth: minimized ? nil : 560)
        .sqDockChrome()
        .padding(.horizontal, SQSpace.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation principale")
    }

    private func dockItem(_ item: (tab: AppRouter.AppTab, label: String, icon: String)) -> some View {
        let isActive = selection == item.tab
        let badge = item.tab == .community ? communityBadge : 0
        return Button {
            Haptics.selection()
            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                selection = item.tab
            }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.icon)
                        .font(.system(size: 19, weight: .medium))
                        .frame(height: 22)
                    if badge > 0 {
                        Text(verbatim: badge > 99 ? "99+" : "\(badge)")
                            .font(SQFont.bodyFixed(9, .bold))
                            .foregroundStyle(SQColor.onAccent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(SQColor.brandRed, in: Capsule(style: .continuous))
                            .offset(x: 11, y: -5)
                    }
                }
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
        // Large Content Viewer : appui long = HUD agrandi de l'onglet, seul moyen
        // de lire les libellés du dock (9,5 pt fixes) aux grandes tailles Dynamic
        // Type pour les malvoyants non-VoiceOver (A11Y-09).
        .accessibilityShowsLargeContentViewer {
            Label(item.label, systemImage: item.icon)
        }
        .accessibilityLabel(badge > 0 ? "\(item.label), \(badge) non lus" : item.label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// Pastille rétractée : icône de l'onglet actif ; point rouge si des
    /// messages attendent ailleurs. Un tap redéploie le dock.
    private var expandButton: some View {
        let active = items.first { $0.tab == selection } ?? items[0]
        return Button {
            Haptics.selection()
            onExpand()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: active.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 48, height: 48)
                if communityBadge > 0, selection != .community {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 8, height: 8)
                        .offset(x: -5, y: 7)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(SQDockPressStyle())
        .accessibilityLabel("Déployer la navigation")
    }
}

private extension View {
    /// Habillage du dock : vrai matériau Liquid Glass sur iOS 26+ via l'API
    /// UIKit `UIGlassEffect` (rendu système fidèle : lentille, bords lumineux,
    /// adaptation au contenu qui défile dessous), capsule crème translucide
    /// avant. Pas d'ombre sur le verre : elle se verrait à travers et le
    /// rendrait laiteux.
    @ViewBuilder
    func sqDockChrome() -> some View {
        if #available(iOS 26.0, *) {
            self.background { SQGlassCapsuleBackground() }
        } else {
            self
                .background {
                    Capsule(style: .continuous)
                        .fill(SQColor.dockBackground)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                }
                .sqShadowDock()
        }
    }
}

/// Capsule Liquid Glass via UIKit : `UIVisualEffectView` + `UIGlassEffect`,
/// le matériau exact des barres système (la version SwiftUI `.glassEffect`
/// rendait plat/opaque en overlay d'un TabView).
@available(iOS 26.0, *)
private struct SQGlassCapsuleBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        let view = UIVisualEffectView(effect: glass)
        view.cornerConfiguration = .capsule()
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
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

/// Rétracte le dock quand on scrolle vers le bas et le redéploie quand on
/// remonte ou revient en haut — équivalent custom de
/// `tabBarMinimizeBehavior(.onScrollDown)`. À appliquer sur le `ScrollView`
/// racine de chaque onglet. iOS 18+ (API scroll geometry) ; no-op avant.
private struct SQDockAutoMinimize: ViewModifier {
    @EnvironmentObject private var services: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Distance cumulée dans la direction courante : hystérésis pour qu'un
    /// tremblement de 1-2 pt ne fasse pas clignoter le dock.
    @State private var accumulated: CGFloat = 0
    /// Vrai pendant que le doigt pilote le scroll. Les deltas ne comptent que
    /// dans ce cas : les dérives d'animation/décélération (la ré-organisation
    /// déclenchée par la minimisation fait reculer l'offset de ~80 pt) ne
    /// doivent pas redéployer le dock.
    @State private var isUserDriven = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                isUserDriven = newPhase == .interacting || newPhase == .tracking
                if !isUserDriven { accumulated = 0 }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Offset CLAMPÉ aux bornes du contenu : les rebonds élastiques
                // (haut comme bas) ne produisent ainsi aucun delta — sinon le
                // rubber-band de fin de contenu (~40 pt) redéploierait le dock.
                let raw = geometry.contentOffset.y + geometry.contentInsets.top
                let maxOffset = max(
                    0,
                    geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height
                )
                return min(max(raw, 0), maxOffset)
            } action: { oldOffset, newOffset in
                let delta = newOffset - oldOffset
                // Saut de layout (refresh, resize), pas un geste : ignorer.
                guard abs(delta) < 300 else { return }
                if newOffset <= 12 {
                    accumulated = 0
                    setMinimized(false)
                    return
                }
                guard isUserDriven else { return }
                if delta * accumulated < 0 { accumulated = 0 }
                accumulated += delta
                // Asymétrique : rétracter vite (24 pt), redéployer seulement
                // sur une remontée délibérée (64 pt) — le micro-règlage de fin
                // de geste peut dériver de ~30 pt vers le haut et ne doit pas
                // faire clignoter le dock.
                if accumulated > 24 {
                    setMinimized(true)
                } else if accumulated < -64 {
                    setMinimized(false)
                }
            }
        } else {
            content
        }
    }

    private func setMinimized(_ value: Bool) {
        let router = services.router
        guard router.isDockMinimized != value else { return }
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
            router.isDockMinimized = value
        }
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

    /// Rétraction du dock au scroll (voir `SQDockAutoMinimize`).
    func sqDockAutoMinimize() -> some View {
        modifier(SQDockAutoMinimize())
    }
}
