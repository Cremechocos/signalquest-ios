import SwiftUI

/// Un routeur par fenêtre (TRX-08).
///
/// Sur iPad, deux fenêtres de SignalQuest partageaient un seul `AppRouter` :
/// changer d'onglet ou ouvrir une conversation dans l'une le faisait aussi
/// dans l'autre. Chaque fenêtre a désormais le sien ; les routes venues de
/// l'extérieur (notification touchée, Siri, Plans) vont à la dernière fenêtre
/// passée au premier plan.
@MainActor
final class WindowRouting {
    /// Routeur de la fenêtre au premier plan.
    private(set) var active: AppRouter
    private var initialClaimed = false

    nonisolated init(initial: AppRouter) {
        active = initial
    }

    /// Routeur d'une nouvelle fenêtre. La première reprend le routeur initial,
    /// qui a pu recevoir une route avant qu'aucune fenêtre n'existe (notification
    /// touchée app fermée) ; les suivantes reçoivent le leur.
    func claimWindowRouter() -> AppRouter {
        guard initialClaimed else {
            initialClaimed = true
            return active
        }
        return AppRouter()
    }

    /// La fenêtre passée au premier plan reçoit désormais les routes extérieures.
    func activate(_ router: AppRouter) {
        active = router
    }
}

/// Routeur propre à une fenêtre, réclamé à sa première évaluation.
///
/// Réclamé ici et non dans un `init` de la vue racine : celle-ci est construite
/// hors du main actor (voir `AppRootView`), alors que la réclamation touche à
/// l'état partagé des fenêtres.
@MainActor
final class WindowRouterStore: ObservableObject {
    private var router: AppRouter?

    func router(claimingFrom routing: WindowRouting) -> AppRouter {
        if let router { return router }
        let claimed = routing.claimWindowRouter()
        router = claimed
        return claimed
    }
}

/// Raccourcis clavier de l'iPad (TRX-31) : les onglets au ⌘1…⌘5, listés par
/// iPadOS quand on maintient ⌘. Ils agissent sur la fenêtre au premier plan,
/// et seulement quand ses onglets sont affichés.
struct SignalQuestCommands: Commands {
    @FocusedObject private var router: AppRouter?

    var body: some Commands {
        CommandMenu("Aller à") {
            shortcut("Accueil", tab: .home, key: "1")
            shortcut("Carte", tab: .map, key: "2")
            shortcut("Tester", tab: .speed, key: "3")
            shortcut("Communauté", tab: .community, key: "4")
            shortcut("Profil", tab: .profile, key: "5")
        }
        // Plan 3, vague 1 : actions courantes, et la palette ⌘K pour tout le reste.
        CommandMenu("Actions") {
            ForEach(SQKeyboardAction.menu) { action in
                Button(action.title) {
                    if let router { action.perform(on: router) }
                }
                .keyboardShortcut(action.shortcut)
                .disabled(router == nil)
            }
            Divider()
            Button("Rechercher une action") { router?.showsCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(router == nil)
        }
    }

    private func shortcut(_ title: LocalizedStringKey, tab: AppRouter.AppTab, key: KeyEquivalent) -> some View {
        Button(title) { router?.selectedTab = tab }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(router == nil)
    }
}
