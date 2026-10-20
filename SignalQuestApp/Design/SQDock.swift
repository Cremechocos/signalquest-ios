import SwiftUI

/// Dock de navigation Halo : barre pleine largeur sur le papier, filet en haut,
/// libellés 12/600 gris, onglet actif à l'encre marqué d'un point carmin de
/// 5 pt. Remplace la tab bar système avant iOS 26 (dès iOS 26, la tab bar
/// Liquid Glass native prend le relais ; le dock reste forçable pour la QA).
/// Le fond descend sous l'indicateur home ; les onglets restent au-dessus.
/// `minimized` masque les libellés au scroll vers le bas (`sqDockAutoMinimize`) ;
/// un tap sur un onglet ou une remontée les rend.
struct SQDock: View {
    @Binding var selection: AppRouter.AppTab
    /// Conversations non lues — badge sur l'onglet Communauté.
    var communityBadge: Int = 0
    /// Libellés masqués après un scroll vers le bas.
    var minimized: Bool = false
    /// Appelé quand on tape la barre rétractée pour rendre les libellés.
    var onExpand: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Écart entre le bas du dock et la safe area : la barre y est posée à ras.
    static let bottomGap: CGFloat = 0

    /// Hauteur réservée AU-DESSUS de la safe area pour que le contenu ne se
    /// cache pas derrière la barre (~60 pt déployée). Sert au `safeAreaInset`
    /// des contenus.
    static let clearance: CGFloat = 64

    private let items: [(tab: AppRouter.AppTab, label: String, icon: String)] = [
        (.home, String(localized: "Accueil"), "house"),
        (.map, String(localized: "Carte"), "map"),
        (.speed, String(localized: "Tester"), "speedometer"),
        (.community, String(localized: "Communauté"), "person.2"),
        (.profile, String(localized: "Profil"), "person.crop.circle")
    ]

    var body: some View {
        let _ = SQRenderProbe.hit("dock")
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                dockItem(item)
            }
        }
        .padding(.horizontal, SQSpace.xs2)
        .padding(.top, 7)
        .padding(.bottom, SQSpace.xs)
        // Sur iPad, les onglets restent groupés au centre de la barre.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .sqDockChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation principale")
        .accessibilityIdentifier("main.navigation")
    }

    private func dockItem(_ item: (tab: AppRouter.AppTab, label: String, icon: String)) -> some View {
        let isActive = selection == item.tab
        let badge = item.tab == .community ? communityBadge : 0
        return Button {
            Haptics.selection()
            if minimized { onExpand() }
            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                selection = item.tab
            }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.icon)
                        .font(.system(size: 19, weight: isActive ? .semibold : .medium))
                        .frame(height: 22)
                    if badge > 0 {
                        SQCountBadge(count: badge)
                            .offset(x: 14, y: -7)
                    }
                }
                if !minimized {
                    Text(item.label)
                        // Libellés de la navigation PRINCIPALE : 12 pt au minimum,
                        // à la taille de texte choisie par l'utilisateur.
                        .font(SQType.micro)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Circle()
                    .fill(SQColor.brandRed)
                    .frame(width: 5, height: 5)
                    .opacity(isActive ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            // accessibility2 avoisine 200 % : le précédent plafond AX1
            // arrêtait la navigation principale avant le critère demandé.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(isActive ? SQColor.label : SQColor.dockInactive)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQDockPressStyle())
        // Large Content Viewer : appui long = HUD agrandi de l'onglet, seul moyen
        // de lire les libellés du dock aux grandes tailles Dynamic
        // Type pour les malvoyants non-VoiceOver (A11Y-09).
        .accessibilityShowsLargeContentViewer {
            Label(item.label, systemImage: item.icon)
        }
        .accessibilityLabel(badge > 0 ? "\(item.label), \(String(localized: "\(badge) conversation non lue"))" : item.label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// Habillage du dock : papier opaque et filet en haut ; le fond descend
    /// jusqu'au bord de l'écran.
    func sqDockChrome() -> some View {
        modifier(SQDockChrome())
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

/// Rétracte le dock quand on scrolle vers le bas et le redéploie quand on
/// remonte ou revient en haut — équivalent custom de
/// `tabBarMinimizeBehavior(.onScrollDown)`. À appliquer sur le `ScrollView`
/// racine de chaque onglet. iOS 18+ (API scroll geometry) ; no-op avant.
/// Le dock se redéploie dès que la racine quitte l'écran (push, onglet).
private struct SQDockAutoMinimize: ViewModifier {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
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
            // Écran poussé par-dessus la racine : il n'a pas de rétraction au
            // scroll, le dock y reste donc déployé (dock custom comme tab bar
            // native). Le signal : la racine quitte la fenêtre à la fin du push.
            .background(
                SQDockRootPresence { id, visible in
                    router.setDockRoot(id, visible: visible)
                    guard !visible else { return }
                    accumulated = 0
                    setMinimized(false)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            )
        } else {
            content
        }
    }

    private func setMinimized(_ value: Bool) {
        guard router.isDockMinimized != value else { return }
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
            router.isDockMinimized = value
        }
    }
}

/// Prévient quand l'écran racine d'un onglet entre dans la fenêtre ou la
/// quitte (push d'un écran par-dessus, changement d'onglet).
private struct SQDockRootPresence: UIViewRepresentable {
    let onChange: (ObjectIdentifier, Bool) -> Void

    func makeUIView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: (ObjectIdentifier, Bool) -> Void

        init(onChange: @escaping (ObjectIdentifier, Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onChange(ObjectIdentifier(self), window != nil)
        }
    }
}

extension SQDock {
    /// Dégagement bas à réserver pour un contenu FLOTTANT posé sur une carte
    /// plein écran (légende, notice, contrôles) — pas pour un contenu scrollable,
    /// qui passe par `sqDockSafeArea()`.
    ///
    /// Avec la barre NATIVE Liquid Glass (iOS 26+), la safe area est DÉJÀ décalée
    /// par la barre : un petit dégagement suffit. Avec le dock custom, c'est une
    /// simple superposition qui ne décale PAS la safe area — il faut réserver
    /// toute sa hauteur, sinon le contenu passe dessous et devient illisible.
    ///
    /// Sans cette distinction, l'un des deux cas est forcément faux : ou bien le
    /// contenu est caché par le dock custom, ou bien un grand vide s'ouvre sous
    /// la barre native.
    static var floatingContentInset: CGFloat {
        if #available(iOS 26.0, *), !usesLegacyDock {
            return SQSpace.lg
        }
        return SQSpace.cardPadding + clearance
    }

    /// Dégagement RESTANT à ajouter quand le contenu porte déjà une marge.
    ///
    /// Les vues concernées ont un `.padding(SQSpace.md/lg)` d'habillage : sans
    /// cette soustraction on cumulerait deux marges. Bornée à zéro, car avec la
    /// barre native l'inset vaut exactement `SQSpace.lg` — une soustraction nue
    /// donnerait alors un padding NÉGATIF, qui retire de l'espace au lieu d'en
    /// ajouter.
    static func floatingContentInset(subtracting existingPadding: CGFloat) -> CGFloat {
        max(0, floatingContentInset - existingPadding)
    }

    /// Le QA peut forcer le dock custom sur un OS qui aurait la barre native.
    static var usesLegacyDock: Bool {
        #if DEBUG
        AppEnvironment.usesLegacyDock
        #else
        false
        #endif
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


/// Habillage du dock Halo : papier opaque (rien à atténuer sous « Réduire la
/// transparence »), filet `--h-hair` en haut, encre en mode terrain.
private struct SQDockChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SQColor.bg.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SQOledPalette.fieldStroke)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
    }
}
