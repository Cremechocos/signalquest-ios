import SwiftUI
import UIKit
import UserNotifications
import FirebaseCore

@main
struct SignalQuestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services: AppServices
    @StateObject private var session: AuthSessionViewModel
    @StateObject private var appLock = AppLockController()
    /// Observé À LA RACINE, et nulle part ailleurs : les jetons de surface lisent
    /// ce réglage au moment du rendu, mais rien ne les ferait ré-évaluer si
    /// personne ne l'observait. Sans cette ligne, activer le mode OLED ne
    /// changerait l'apparence qu'au redémarrage de l'app.
    @AppStorage(SQOledPalette.storageKey) private var pureBlack = false

    init() {
        // Le graphe vient du holder plutôt que d'être construit ici : une scène
        // CarPlay peut se connecter AVANT cette fenêtre (app lancée en
        // arrière-plan au branchement du véhicule) et doit partager exactement
        // le même `AppServices` — deux graphes signifieraient deux `APIClient`,
        // donc deux jeux de cookies et deux refresh concurrents sur 401.
        _services = StateObject(wrappedValue: AppServicesHolder.services)
        _session = StateObject(wrappedValue: AppServicesHolder.session)
        Self.configureNavigationTypography()
    }

    /// Bricolage Grotesque pour les titres de navigation (DA Crème) — les
    /// `navigationTitle` SwiftUI passent par UINavigationBar, qu'on ne peut
    /// styler que via l'appearance UIKit. Retombe sur SF si la police manque.
    private static func configureNavigationTypography() {
        guard let large = UIFont(name: "BricolageGrotesque-Bold", size: 26),
              let inline = UIFont(name: "BricolageGrotesque-SemiBold", size: 17) else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes[.font] = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)
        appearance.titleTextAttributes[.font] = UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        // Lus ICI, dans `body` : `StateObject.wrappedValue` est `@MainActor`, donc
        // illisible depuis la fermeture `@Sendable` ci-dessous. Les trois sont des
        // classes `@MainActor`, donc `Sendable` — la capture est légale.
        let services = self.services
        let session = self.session
        let appLock = self.appLock
        // `@Sendable` n'est PAS décoratif et ne doit pas être retiré : sans lui,
        // cette fermeture hérite de l'isolation `@MainActor` d'`App.body` et le
        // mode langage Swift 6 lui greffe une vérification d'exécuteur qui piège
        // (EXC_BREAKPOINT) quand SwiftUI l'évalue depuis son renderer asynchrone.
        // Une fermeture `@Sendable` n'hérite d'aucune isolation, donc plus de
        // vérification. Voir la note d'en-tête d'`AppRootView`.
        return WindowGroup { @Sendable in
            AppRootView(services: services, session: session, appLock: appLock)
        }
    }
}

/// Contenu de la scène principale.
///
/// Tout ce qui compose la racine vit ici plutôt que directement dans la
/// fermeture `WindowGroup { … }`, et ce n'est pas cosmétique.
///
/// SwiftUI enveloppe le contenu du `WindowGroup` dans un `LazyView` et le
/// ré-évalue depuis son thread de rendu asynchrone
/// (`com.apple.SwiftUI.AsyncRenderer`), pas depuis le thread principal. Or une
/// fermeture non-`@Sendable` hérite *inconditionnellement* — quel que soit son
/// contenu — de l'isolation `@MainActor` d'`App.body` ; en mode langage Swift 6,
/// la convertir vers le type non isolé attendu par `WindowGroup.init(content:)`
/// y greffe une vérification d'exécuteur (`swift_task_isCurrentExecutor`) qui
/// piège en EXC_BREAKPOINT/SIGTRAP hors du thread principal. D'où le crash
/// intermittent, y compris au lancement.
///
/// La fermeture est donc marquée `@Sendable` (elle n'hérite alors d'aucune
/// isolation, et la vérification disparaît — constaté au désassemblage), ce qui
/// lui interdit du même coup tout accès `@MainActor`. Ce code doit bien vivre
/// quelque part : c'est cette vue. Le `body` d'une `View` n'est, lui, pas
/// instrumenté ainsi — SwiftUI l'appelle depuis son renderer sans franchir de
/// frontière d'isolation vérifiée.
///
/// Conséquence pratique : ce qu'on ajoute à la racine se met ICI. Le compilateur
/// refusera de toute façon de le mettre dans la fermeture.
struct AppRootView: View {
    // `@ObservedObject` et non `let` : `.onChangeCompat(of: session.state)` et le
    // badge `services.unreadConversations` n'ont d'effet que si cette vue est
    // bien invalidée — c'est ce que faisaient les `@StateObject` de l'`App`
    // quand cette hiérarchie était construite dans la fermeture.
    @ObservedObject var services: AppServices
    @ObservedObject var session: AuthSessionViewModel
    @ObservedObject var appLock: AppLockController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sq.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Miroir observable de l'unité de distance. Détenu ICI, là où se fait
    /// l'injection : les vues s'y abonnent pour se rafraîchir au changement,
    /// les formateurs purs (`SQUnits`) lisent le `UserDefaults` derrière.
    @StateObject private var unitsStore = SQUnitsStore()

    /// Enregistre les notifications APNs + le token VoIP dès que la session
    /// devient authentifiée. Idempotent : `requestAuthorizationAndRegister` ne
    /// re-sollicite pas l'autorisation déjà déterminée et `registerForVoIPPushes`
    /// garde sur `voipRegistry == nil`.
    @MainActor
    private func registerPushIfAuthenticated(_ state: AuthSessionViewModel.State) async {
        guard case .authenticated = state, hasCompletedOnboarding else { return }
        // En démo/QA, ne pas solliciter l'autorisation système de notifications
        // (la popup masquerait les captures et n'a pas de sens sans vrai compte).
        guard !AppEnvironment.usesDemoData else { return }
        await services.push.requestAuthorizationAndRegister()
        services.callManager.registerForVoIPPushes()
        // CALL-VOIP-04 : un login dans une session déjà lancée (install→1er login,
        // ou changement de compte) ne re-livre pas `didUpdate` (registry déjà créé) ;
        // on ré-associe explicitement le token VoIP connu au nouvel utilisateur.
        // No-op au tout premier login (token pas encore livré).
        await services.callManager.registerVoIPTokenForSession()
        // Rattrape un appel entrant déjà en attente au moment où l'on devient authentifié.
        await services.callManager.reconcilePendingIncomingCall()
    }

    var body: some View {
        // L'onboarding vit DANS la hiérarchie (ZStack d'`OnboardingHost`) et non
        // plus dans un `fullScreenCover` : son drapeau « complété » n'est écrit
        // que par un geste utilisateur, jamais par le démontage de la
        // présentation. C'est ce qui remplace le garde `set: { _ in }` de
        // l'ancien cover (UXP-06), et ce qui permet à la transition de sortie
        // d'être animée au lieu d'être coupée par la fermeture du cover.
        OnboardingHost { RootView() }
            .environmentObject(services)
            .environmentObject(session)
            .environmentObject(services.router)
            .environmentObject(services.callManager)
            .environmentObject(services.networkPath)
            .environmentObject(unitsStore)
            // Injecté SÉPARÉMENT, comme networkPath et callManager : un
            // ObservableObject imbriqué dans AppServices n'est pas observé
            // de façon transitive, donc `RootView` ne se reconstruirait pas
            // au changement d'état de la politique de version.
            .environmentObject(services.versionPolicy)
            .environmentObject(appLock)
            .task {
                // `networkPath.start()` et `session.bootstrap()` ont migré dans
                // `bootstrapIfNeeded` : la scène CarPlay a besoin des deux, et
                // elle peut se connecter sans qu'aucune fenêtre n'apparaisse.
                // Les ponts `AppDelegate.shared*` sont désormais posés par
                // `AppServicesHolder` à la construction du graphe — donc avant
                // le premier rendu, là où ils arrivaient trop tard pour une push
                // silencieuse reçue au lancement.
                //
                // PushKit doit être prêt avant tout `await` de bootstrap : au
                // lancement à froid provoqué par une push VoIP, retarder la
                // création du registre peut faire expirer le watchdog avant
                // le report CallKit. Le token n'est associé au compte qu'après
                // authentification par `registerPushIfAuthenticated`.
                services.callManager.registerForVoIPPushes()
                // Best-effort et NON bloquant : lancé en parallèle du
                // bootstrap pour ne pas rallonger le démarrage. Un échec
                // laisse l'état à `.unknown`, donc l'app fonctionne.
                Task { await services.versionPolicy.refresh() }
                await services.bootstrapIfNeeded(session: session)
                await registerPushIfAuthenticated(session.state)
                // Verrouillage biométrique à l'ouverture (si activé + authentifié).
                if case .authenticated = session.state { appLock.lockOnActivationIfNeeded() }
                // Mode « continu » : amorce la diffusion de présence dès le
                // lancement (le mode « carte ouverte » démarre, lui, à l'ouverture
                // de la couche Amis — inutile de payer un appel réseau ici).
                if case .authenticated = session.state, LiveShareModeStore.load() == .foregroundLive {
                    await services.livePresence.refreshSharingSettings()
                }
            }
            .onChangeCompat(of: session.state) { _, newState in
                // Un login effectué dans une session déjà lancée (cas nominal
                // installation → premier login, ou après logout/login) doit lui
                // aussi déclencher l'enregistrement push/VoIP — sinon l'utilisateur
                // ne reçoit ni notifications ni appels tant qu'il ne relance pas
                // l'app à froid. Les deux appels sont idempotents.
                Task { await registerPushIfAuthenticated(newState) }
                if case .authenticated = newState {
                    appLock.lockOnActivationIfNeeded()
                } else {
                    appLock.reset()   // jamais verrouillé par-dessus l'écran de login
                }
            }
            .onChangeCompat(of: hasCompletedOnboarding) { _, completed in
                guard completed else { return }
                Task { await registerPushIfAuthenticated(session.state) }
            }
            .onChangeCompat(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    UNUserNotificationCenter.current().setBadgeCountCompat(0)
                    // Verrouillage / déconnexion par inactivité au retour au 1er plan.
                    if case .authenticated = session.state, appLock.willEnterForeground() {
                        Task { await session.logout() }
                    }
                    // CALL-INCOMING-03 / CALL-VOIP-04 : ré-enregistrer le token VoIP
                    // et rattraper un appel entrant que le push VoIP aurait manqué.
                    if case .authenticated = session.state {
                        Task {
                            await services.callManager.retryVoIPTokenRegistrationIfNeeded()
                            await services.callManager.reconcilePendingIncomingCall()
                        }
                    }
                    services.enterForeground()
                case .background:
                    // On ne coupe QUE si plus aucune fenêtre n'est visible.
                    // `scenePhase` est par scène, mais `appLock` et `services`
                    // sont uniques au process : depuis que plusieurs scènes
                    // coexistent, masquer une fenêtre iPad verrouillait celle
                    // restée à l'écran — et pouvait même déconnecter la session
                    // via le délai d'inactivité de `willEnterForeground()`.
                    //
                    // Ne pas appeler `didEnterBackground()` laisse
                    // `backgroundedAt` à nil, ce qui rend le retour au premier
                    // plan de l'autre fenêtre inoffensif : sa garde anti-boucle
                    // s'en charge déjà. Corriger ce seul cas suffit donc.
                    guard !services.hasVisibleWindowScene else { break }
                    appLock.didEnterBackground()
                    services.enterBackground()
                default:
                    break
                }
            }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var callManager: CallManager
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @EnvironmentObject private var appLock: AppLockController
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var versionPolicy: VersionPolicyService

    var body: some View {
        Group {
            // Version trop ancienne : on ne construit RIEN d'autre.
            //
            // Un simple `.overlay` ne suffit pas — le dock flottant restait
            // atteignable en dessous (vérifié : les 5 onglets répondaient encore
            // aux taps derrière l'écran de blocage). Court-circuiter la
            // hiérarchie garantit qu'aucune requête d'une version obsolète
            // n'atteigne un backend dont le contrat a été durci, ce qui est tout
            // l'objet de ce kill-switch.
            if case .updateRequired(let message, let storeURL) = versionPolicy.state {
                ForcedUpdateView(message: message, storeURL: storeURL)
            } else {
                switch session.state {
                case .checking:
                    LaunchLoadingView()
                case .loggedOut, .requires2FA:
                    LoginView()
                case .offline:
                    OfflineRetryView()
                case .authenticated(let user):
                    MainTabView(user: user)
                }
            }
        }
        .sqAnimation(SQMotion.smooth, value: session.state)
        .fullScreenCover(isPresented: $callManager.showCallScreen) {
            CallScreen(callManager: callManager)
        }
        .overlay(alignment: .top) {
            OfflineBanner(isVisible: !networkPath.isOnline)
        }
        // Verrouillage biométrique : masque tout le contenu authentifié tant que
        // l'utilisateur ne s'est pas déverrouillé par Face ID / Touch ID.
        .overlay {
            if isAuthenticated, appLock.isLocked {
                AppLockScreen(lock: appLock).transition(.opacity)
            }
        }
        .sqAnimation(SQMotion.smooth, value: versionPolicy.state)
        .sqAnimation(SQMotion.smooth, value: appLock.isLocked)
        // CALL-VOIP-07 : au retour du réseau (sortie de tunnel/mode avion), si le
        // dernier enregistrement du token VoIP avait échoué, on le rejoue — sinon
        // l'utilisateur resterait injoignable jusqu'au prochain passage foreground.
        .onChangeCompat(of: networkPath.isOnline) { _, online in
            guard online, case .authenticated = session.state else { return }
            Task { await callManager.retryVoIPTokenRegistrationIfNeeded() }
        }
    }

    private var isAuthenticated: Bool {
        if case .authenticated = session.state { return true }
        return false
    }
}

/// Bandeau global discret affiché en haut de l'écran lors d'une perte de
/// connexion réseau (mode avion, tunnel…). Respecte Reduce Motion.
struct OfflineBanner: View {
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13, weight: .bold))
                    Text("Hors ligne — certaines actions sont indisponibles")
                        .font(SQFont.archivo(13, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0x18150F).opacity(0.94))
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(reduceMotion ? nil : SQMotion.smooth, value: isVisible)
    }
}

/// Shown when we have a stored session but couldn't reach the server at launch,
/// so a transient network outage doesn't force a logged-in user back to login.
struct OfflineRetryView: View {
    @EnvironmentObject private var session: AuthSessionViewModel

    var body: some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            VStack(spacing: SQSpace.lg) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 52))
                    .foregroundStyle(SQColor.brandOrange)
                Text("Connexion indisponible")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                Text("Impossible de joindre SignalQuest. Vérifie ta connexion puis réessaie.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                // Système typographique + bouton DA (capsule 56 pt) comme le reste de
                // l'app, au lieu d'un .borderedProminent système détonnant (UI-13).
                GradientButton("Réessayer", systemImage: "arrow.clockwise") {
                    Task { await session.retryBootstrap() }
                }
                Button("Se déconnecter") { Task { await session.logout() } }
                    .font(SQType.body)
                    .tint(SQColor.labelSecondary)
            }
            .padding(SQSpace.xxl)
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthUser
    @State private var showHandleGate = false

    init(user: AuthUser) {
        self.user = user
    }

    var body: some View {
        tabContainer
        .task {
            await services.refreshInboxBadge()
            consumeIntentRoutes()
            // À l'arrivée (Feed = onglet par défaut) sans @handle : inviter à en choisir un.
            if (user.handle ?? "").isEmpty { showHandleGate = true }
        }
        .sheet(isPresented: $showHandleGate) {
            ChooseHandleSheet(onSuccess: { _ in Task { await session.refreshUser() } })
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await services.refreshInboxBadge() }
                consumeIntentRoutes()
            }
        }
        .onChangeCompat(of: router.selectedTab) { _, _ in
            // Changement d'onglet (tap, deep-link, intent) : dock redéployé.
            withAnimation(SQMotion.snappy) { router.isDockMinimized = false }
            Task { await services.refreshInboxBadge() }
        }
        .onChangeCompat(of: router.isDockHidden) { _, hidden in
            // Retour de conversation : le dock réapparaît toujours déployé
            // (le reset se fait pendant qu'il est masqué, sans pop visible).
            if hidden { router.isDockMinimized = false }
        }
        .onOpenURL { url in handleDeepLink(url) }
        // Lien universel : `onOpenURL` ne suffit pas au démarrage à froid, où
        // iOS passe par une activité de navigation. Les deux chemins mènent au
        // même routage.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { handleDeepLink(url) }
        }
    }

    /// iOS 26+ : tab bar système Liquid Glass native — vrai verre, glissement
    /// du doigt entre les onglets (la pilule suit), rétraction au scroll
    /// (`tabBarMinimizeBehavior`), comme les apps natives et la référence
    /// Revolut. Sa position verticale est celle du système (non réglable).
    /// Avant iOS 26 : dock flottant custom « Crème » (le verre système
    /// n'existe pas), posé 8 pt au-dessus de la safe area.
    @ViewBuilder
    private var tabContainer: some View {
        if #available(iOS 26.0, *), !Self.forceLegacyDock {
            glassTabView
        } else {
            dockTabView
        }
    }

    /// QA uniquement : force le dock custom sur un simulateur iOS 26+ pour
    /// vérifier le rendu et la rétraction pré-iOS 26 (DockMinimizeQATests).
    private static var forceLegacyDock: Bool {
#if DEBUG
        AppEnvironment.usesLegacyDock
#else
        false
#endif
    }

    // MARK: Tab bar Liquid Glass native (iOS 26+)

    @available(iOS 26.0, *)
    private var glassTabView: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack { SignalQuestHomeView(user: user) }
                .tabItem { Label("Accueil", systemImage: "house") }
                .tag(AppRouter.AppTab.home)

            NavigationStack {
                MapExplorerView(service: services.map, antennas: services.antennas, markets: services.markets, communityOutages: services.communityOutages)
#if DEBUG
                    .navigationDestination(isPresented: .constant(AppEnvironment.opensANFRMap)) {
                        ANFRMapView(service: services.anfr)
                    }
                    .navigationDestination(isPresented: .constant(AppEnvironment.opensANFRStats)) {
                        ANFRStatsView(service: services.anfr)
                    }
#endif
            }
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(AppRouter.AppTab.map)

            NavigationStack { SpeedtestView() }
                .tabItem { Label("Tester", systemImage: "speedometer") }
                .tag(AppRouter.AppTab.speed)

            NavigationStack { FeedView(service: services.feed, location: services.location) }
                // La conversation pose isDockHidden : on masque aussi la barre
                // système pour laisser le composer prendre le bas de l'écran.
                .toolbar(router.isDockHidden ? .hidden : .automatic, for: .tabBar)
                .tabItem { Label("Communauté", systemImage: "person.2") }
                .tag(AppRouter.AppTab.community)
                .badge(services.unreadConversations)

            NavigationStack { ProfileView(user: user) }
            .tabItem { Label("Profil", systemImage: "person.crop.circle") }
            .tag(AppRouter.AppTab.profile)
        }
        // Rétraction au scroll (Liquid Glass) : la barre se réduit en pastille
        // quand on descend et se redéploie quand on remonte.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(SQColor.brandRed)
    }

    // MARK: Dock flottant custom (avant iOS 26)

    /// La tab bar système est masquée sur chaque onglet et remplacée par
    /// `SQDock`, posé 8 pt au-dessus de la safe area, avec rétraction au
    /// scroll custom (`sqDockAutoMinimize` sur les racines, iOS 18+).
    private var dockTabView: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack { SignalQuestHomeView(user: user).toolbar(.hidden, for: .tabBar) }
                .sqDockSafeArea()
                .tag(AppRouter.AppTab.home)

            NavigationStack {
                MapExplorerView(service: services.map, antennas: services.antennas, markets: services.markets, communityOutages: services.communityOutages)
                    .toolbar(.hidden, for: .tabBar)
#if DEBUG
                    .navigationDestination(isPresented: .constant(AppEnvironment.opensANFRMap)) {
                        ANFRMapView(service: services.anfr)
                    }
                    .navigationDestination(isPresented: .constant(AppEnvironment.opensANFRStats)) {
                        ANFRStatsView(service: services.anfr)
                    }
#endif
            }
                .tag(AppRouter.AppTab.map)

            NavigationStack { SpeedtestView().toolbar(.hidden, for: .tabBar) }
                .sqDockSafeArea()
                .tag(AppRouter.AppTab.speed)

            NavigationStack { FeedView(service: services.feed, location: services.location).toolbar(.hidden, for: .tabBar) }
                .sqDockSafeArea(!router.isDockHidden)
                .tag(AppRouter.AppTab.community)

            NavigationStack { ProfileView(user: user).toolbar(.hidden, for: .tabBar) }
            .sqDockSafeArea()
            .tag(AppRouter.AppTab.profile)
        }
        .tint(SQColor.brandRed)
        .overlay(alignment: .bottom) {
            // Posé DANS la safe area : 8 pt au-dessus de l'indicateur home
            // (Face ID) ou du bord physique (bouton). Jamais sur l'indicateur —
            // le prototype HTML le posait à 14 pt du bord physique, trop bas.
            if !router.isDockHidden {
                SQDock(
                    selection: $router.selectedTab,
                    communityBadge: services.unreadConversations,
                    minimized: router.isDockMinimized,
                    onExpand: {
                        withAnimation(SQMotion.snappy) { router.isDockMinimized = false }
                    }
                )
                .padding(.bottom, SQDock.bottomGap)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(SQMotion.standard, value: router.isDockHidden)
    }

    /// Applique une route demandée par un App Intent / raccourci Siri (onglet Speed/Carte).
    private func consumeIntentRoutes() {
        if SQIntentRoute.consumeSpeedtest() {
            router.selectedTab = .speed
        } else if SQIntentRoute.consumeMap() {
            router.selectedTab = .map
        } else if SQIntentRoute.consumeMessages() {
            router.route(toConversation: nil)
        } else if SQIntentRoute.consumeDriveTest() {
            router.selectedTab = .speed
            router.pendingDriveTest = true
        }
    }

    /// Deep-link de l'environnement (widgets, raccourcis) → onglet correspondant.
    private func handleDeepLink(_ url: URL) {
        // Lien universel https : seul le partage Sentinelle est revendiqué côté
        // app pour l'instant. Le chemin est vérifié ici ET dans
        // .well-known/apple-app-site-association — iOS n'ouvre l'app que si les
        // deux concordent.
        if url.scheme == "https" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[0] == "sentinelle", parts[1] == "p" {
                router.route(toSentinelleShare: parts[2])
            }
            return
        }

        guard url.scheme == SQSharedConfiguration.urlScheme else { return }
        switch url.host {
        case "speedtest", "speed": router.selectedTab = .speed
        case "map", "carte": router.selectedTab = .map
        case "messages", "community", "communaute": router.route(toConversation: nil)
        default: break
        }
    }
}
