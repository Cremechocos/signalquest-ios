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
        guard case .authenticated = state else { return }
        await services.push.requestAuthorizationAndRegister()
        services.callManager.registerForVoIPPushes()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(session)
                .environmentObject(services.router)
                .environmentObject(services.callManager)
                .environmentObject(services.networkPath)
                .task {
                    services.networkPath.start()
                    AppDelegate.sharedPush = services.push
                    AppDelegate.sharedCallManager = services.callManager
                    AppDelegate.sharedE2EE = services.e2ee
                    await session.bootstrap()
                    await registerPushIfAuthenticated(session.state)
                }
                .onChangeCompat(of: session.state) { _, newState in
                    // Un login effectué dans une session déjà lancée (cas nominal
                    // installation → premier login, ou après logout/login) doit lui
                    // aussi déclencher l'enregistrement push/VoIP — sinon l'utilisateur
                    // ne reçoit ni notifications ni appels tant qu'il ne relance pas
                    // l'app à froid. Les deux appels sont idempotents.
                    Task { await registerPushIfAuthenticated(newState) }
                }
                .onChangeCompat(of: scenePhase) { _, phase in
                    if phase == .active {
                        UNUserNotificationCenter.current().setBadgeCount(0)
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
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthUser

    init(user: AuthUser) {
        self.user = user
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack { FeedView(service: services.feed) }
                .tabItem { Label("Feed", systemImage: "sparkles") }
                .tag(AppRouter.AppTab.feed)

            NavigationStack { MapExplorerView(service: services.map, antennas: services.antennas, markets: services.markets) }
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(AppRouter.AppTab.map)

            NavigationStack { SpeedtestView() }
                .tabItem { Label("Speed", systemImage: "speedometer") }
                .tag(AppRouter.AppTab.speed)

            NavigationStack { MessagesView(service: services.messages, e2ee: services.e2ee) }
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppRouter.AppTab.messages)
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
        .tint(SQColor.brandOrange)
        .toolbarBackground(.automatic, for: .tabBar)
        .task { await services.refreshInboxBadge(); consumeIntentRoutes() }
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
        }
    }

    /// Deep-link `signalquest://…` (widgets, raccourcis) → onglet correspondant.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "signalquest" else { return }
        switch url.host {
        case "speedtest", "speed": router.selectedTab = .speed
        case "map", "carte": router.selectedTab = .map
        case "messages": router.selectedTab = .messages
        default: break
        }
    }
}
