import SwiftUI
import UIKit
import UserNotifications
import FirebaseCore

@main
struct SignalQuestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var services: AppServices
    @StateObject private var session: AuthSessionViewModel
    @StateObject private var appLock = AppLockController()
    @AppStorage("sq.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        let services = AppServices()
        _services = StateObject(wrappedValue: services)
        _session = StateObject(wrappedValue: AuthSessionViewModel(service: services.auth))
        Self.configureNavigationTypography()
    }

    /// DM Sans pour les titres de navigation (la DA signalquest.fr) — les
    /// `navigationTitle` SwiftUI passent par UINavigationBar, qu'on ne peut
    /// styler que via l'appearance UIKit. Retombe sur SF si la police manque.
    private static func configureNavigationTypography() {
        guard let large = UIFont(name: "ArchivoExpanded-Black", size: 30),
              let inline = UIFont(name: "Archivo-Bold", size: 17) else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes[.font] = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)
        appearance.titleTextAttributes[.font] = UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    /// Enregistre les notifications APNs + le token VoIP dès que la session
    /// devient authentifiée. Idempotent : `requestAuthorizationAndRegister` ne
    /// re-sollicite pas l'autorisation déjà déterminée et `registerForVoIPPushes`
    /// garde sur `voipRegistry == nil`.
    @MainActor
    private func registerPushIfAuthenticated(_ state: AuthSessionViewModel.State) async {
        guard case .authenticated = state, hasCompletedOnboarding else { return }
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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(session)
                .environmentObject(services.router)
                .environmentObject(services.callManager)
                .environmentObject(services.networkPath)
                .environmentObject(appLock)
                .task {
                    services.networkPath.start()
                    AppDelegate.sharedPush = services.push
                    AppDelegate.sharedCallManager = services.callManager
                    AppDelegate.sharedE2EE = services.e2ee
                    // PushKit doit être prêt avant tout `await` de bootstrap : au
                    // lancement à froid provoqué par une push VoIP, retarder la
                    // création du registre peut faire expirer le watchdog avant
                    // le report CallKit. Le token n'est associé au compte qu'après
                    // authentification par `registerPushIfAuthenticated`.
                    services.callManager.registerForVoIPPushes()
                    await session.bootstrap()
                    await registerPushIfAuthenticated(session.state)
                    // Verrouillage biométrique à l'ouverture (si activé + authentifié).
                    if case .authenticated = session.state { appLock.lockOnActivationIfNeeded() }
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
                    case .background:
                        appLock.didEnterBackground()
                    default:
                        break
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { presented in if !presented { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView { hasCompletedOnboarding = true }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var callManager: CallManager
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @EnvironmentObject private var appLock: AppLockController

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                ZStack {
                    Color.clear.signalQuestHeroBackground()
                    
                    VStack(spacing: SQSpace.xxl) {
                        Image("SQLogoMark")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
                            .shadow(color: SQColor.brandRed.opacity(0.35), radius: 18, x: 0, y: 8)
                        
                        VStack(spacing: SQSpace.md) {
                            ProgressView()
                                .tint(SQColor.brandRed)
                                .scaleEffect(1.2)
                            
                            Text("SIGNAL QUEST")
                                .font(SQFont.archivo(16, .bold))
                                .tracking(3)
                                .foregroundStyle(SQColor.label)
                                .padding(.top, SQSpace.sm)
                        }
                    }
                }
            case .loggedOut, .requires2FA:
                LoginView()
            case .offline:
                OfflineRetryView()
            case .authenticated(let user):
                MainTabView(user: user)
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                Text("Impossible de joindre SignalQuest. Vérifie ta connexion puis réessaie.")
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await session.retryBootstrap() }
                } label: {
                    Text("Réessayer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.sm + 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(SQColor.brandOrange)
                Button("Se déconnecter") { Task { await session.logout() } }
                    .font(.subheadline)
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
        TabView(selection: $router.selectedTab) {
            NavigationStack { SignalQuestHomeView(user: user) }
                .tabItem { Label("Accueil", systemImage: "house") }
                .tag(AppRouter.AppTab.home)

            NavigationStack { MapExplorerView(service: services.map, antennas: services.antennas, markets: services.markets) }
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(AppRouter.AppTab.map)

            NavigationStack { SpeedtestView() }
                .tabItem { Label("Tester", systemImage: "speedometer") }
                .tag(AppRouter.AppTab.speed)

            NavigationStack { FeedView(service: services.feed, location: services.location) }
                .tabItem { Label("Communauté", systemImage: "person.2") }
                .tag(AppRouter.AppTab.community)
                .badge(services.unreadConversations)

            NavigationStack {
                ProfileView(user: user)
#if DEBUG
                    .navigationDestination(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("--qa-anfr-map"))) {
                        ANFRMapView(service: services.anfr)
                    }
                    .navigationDestination(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("--qa-anfr-stats"))) {
                        ANFRStatsView(service: services.anfr)
                    }
#endif
            }
            .tabItem { Label("Profil", systemImage: "person.crop.circle") }
            .tag(AppRouter.AppTab.profile)
        }
        // Style « sidebar adaptable » (iPad/large) seulement iOS 18+, sinon onglets standard.
        .sqSidebarAdaptableTabStyle()
        .tint(SQColor.brandRed)
        .toolbarBackground(.automatic, for: .tabBar)
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
            Task { await services.refreshInboxBadge() }
        }
        .onOpenURL { url in handleDeepLink(url) }
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
        guard url.scheme == SQSharedConfiguration.urlScheme else { return }
        switch url.host {
        case "speedtest", "speed": router.selectedTab = .speed
        case "map", "carte": router.selectedTab = .map
        case "messages", "community", "communaute": router.route(toConversation: nil)
        default: break
        }
    }
}

/// Accueil réseau : un résumé lisible avant les détails experts, avec accès
/// direct aux trois tâches principales. Le feed social reste dans Communauté.
private struct SignalQuestHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthUser

    @State private var latestMeasurement: SpeedtestRunResult?
    @State private var networkStatus: NetworkPathStatus = .unknown

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Carnet de terrain").sqKicker()
                    Text("Bonjour \(firstName)")
                        .font(SQType.display)
                        .foregroundStyle(SQColor.label)
                    Text("Mesure ton réseau, comprends le signal, puis partage ce qui compte.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                }

                networkSummary
                primaryActions
                latestMeasurementSection
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
        }
        .navigationTitle("Accueil")
        .toolbarTitleLargeCompat()
        .signalQuestBackground()
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var firstName: String {
        user.name?.split(separator: " ").first.map(String.init) ?? "à toi"
    }

    private var networkSummary: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: networkStatus.connection == .cellular
                  ? "antenna.radiowaves.left.and.right"
                  : "wifi")
                .font(.title2.weight(.semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 44, height: 44)
                .background(SQColor.brandRed.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Réseau actuel")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                Text(networkStatus.displayName)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
            }
            Spacer()
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
    }

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Que veux-tu faire ?")
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
            homeAction(
                title: "Tester maintenant",
                detail: "Débit, latence et qualité radio",
                systemImage: "speedometer",
                tab: .speed
            )
            homeAction(
                title: "Explorer la carte",
                detail: "Antennes, couverture et mesures",
                systemImage: "map",
                tab: .map
            )
            homeAction(
                title: "Voir la communauté",
                detail: "Publications, stories et messages",
                systemImage: "person.2",
                tab: .community
            )
        }
    }

    private func homeAction(
        title: String,
        detail: String,
        systemImage: String,
        tab: AppRouter.AppTab
    ) -> some View {
        Button {
            Haptics.selection()
            router.selectedTab = tab
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text(detail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .padding(.vertical, SQSpace.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().overlay(SQColor.separator) }
        .accessibilityHint("Ouvre l’onglet \(title)")
    }

    @ViewBuilder
    private var latestMeasurementSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Dernière mesure")
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
            if let measurement = latestMeasurement {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text(measurement.downloadAverageMbps.formatted(.number.precision(.fractionLength(0))))
                            .font(SQType.display)
                            .foregroundStyle(SQColor.label)
                        Text("Mbps en téléchargement")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: SQSpace.xs) {
                        Text("\((measurement.pingMinMs ?? measurement.pingMs ?? 0).formatted(.number.precision(.fractionLength(0)))) ms")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        Text(measurement.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .padding(SQSpace.lg)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            } else {
                EmptyStateView(
                    title: "Aucune mesure locale",
                    message: "Lance un premier test pour créer ton repère.",
                    systemImage: "waveform.path.ecg"
                )
            }
        }
    }

    private func refresh() async {
        services.networkPath.refreshNow()
        networkStatus = services.networkPath.status
        latestMeasurement = await services.speedtest.history().first
    }
}
