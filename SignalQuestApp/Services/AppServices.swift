import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let api: APIClient
    let auth: AuthServicing
    let feed: SocialFeedServicing
    let comments: CommentsServicing
    let stories: StoriesServicing
    let reports: ReportsServicing
    let privacy: PrivacyServicing
    let map: MapSnapshotServicing
    let markets: MarketRegistryServicing
    let antennas: AntennasServicing
    /// Signalements d'antenne (émission, suivi, discussion avec la modération).
    let antennaReports: AntennaReportsServicing
    let anfr: ANFRServicing
    let speedtest: SpeedtestService
    let networkOperator: NetworkOperatorServicing
    /// Verdict de qualité réseau communautaire (opérateur SIM) — pastille d'accueil.
    let nearbyQuality: NearbyNetworkQualityServicing
    let photos: PhotoServicing
    let messages: MessagesServicing
    let leaderboards: LeaderboardServicing
    let sessions: SessionsServicing
    let validations: ValidationsServicing
    let identify: IdentifyServicing
    /// Import de logs radio (eNB Analytics CSV / NetMonster .ntm) → identification.
    let radioLogImport: RadioLogImportServicing
    let e2ee: E2EEServicing
    let friends: FriendsServicing
    let gamification: GamificationServicing
    let gamificationV2: GamificationV2Servicing
    let notifications: NotificationsServicing
    let calls: CallsServicing
    let users: UserServicing
    let entitlements: EntitlementsStore
    let push: PushNotificationService
    let router: AppRouter
    let callManager: CallManager
    let sse: SSEClient
    let location = LocationService()
    let networkPath = NetworkPathMonitor()
    /// Émetteur de la position/présence live pour la carte des amis.
    let livePresence: LivePresenceService

    /// Nombre de conversations non lues — alimente le badge de l'onglet Messages.
    @Published var unreadConversations = 0

    init(config: AppConfig = .current) {
        let credentials = CredentialStore()
        let api = APIClient(config: config, credentials: credentials)
        self.api = api
        let appRouter = AppRouter()
        router = appRouter
        let e2eeService = E2EEService(api: api)
        e2ee = e2eeService
        sse = SSEClient(api: api)
        auth = AuthService(api: api, e2ee: e2eeService)
        feed = SocialFeedService(api: api)
        comments = CommentsService(api: api)
        stories = StoriesService(api: api)
        reports = ReportsService(api: api)
        let privacyService = PrivacyService(api: api)
        privacy = privacyService
        livePresence = LivePresenceService(api: api, location: location, networkPath: networkPath, privacy: privacyService)
        let mapService = MapSnapshotService(api: api)
        map = mapService
        let marketsService = MarketRegistryService(api: api)
        markets = marketsService
        antennas = AntennasService(api: api)
        antennaReports = AntennaReportsService(api: api)
        anfr = ANFRService(api: api)
        let networkOperatorService = NetworkOperatorService(api: api)
        networkOperator = networkOperatorService
        nearbyQuality = NearbyNetworkQualityService(map: mapService, markets: marketsService, networkOperator: networkOperatorService)
        speedtest = SpeedtestService(api: api, markets: marketsService, networkOperator: networkOperatorService)
        photos = PhotoService(api: api)
        messages = MessagesService(api: api)
        leaderboards = LeaderboardService(api: api)
        let sessionsService = SessionsService(api: api)
        sessions = sessionsService
        // Rejoue au lancement les Drive Tests finalisés hors ligne ou interrompus
        // par une terminaison du processus. Un échec conserve la file sur disque.
        Task { await sessionsService.retryPendingCoverageSessions() }
        // Idem pour les speedtests sauvés hors-ligne : sans ça, un test réalisé
        // hors couverture restait non synchronisé tant que l'utilisateur ne rouvrait
        // pas l'onglet Tester/Drive Test (ROB-07). La file durable est idempotente.
        let speedtestService = speedtest
        Task { await speedtestService.retryPendingSaves() }
        validations = ValidationsService(api: api)
        let identifyService = IdentifyService(api: api)
        identify = identifyService
        radioLogImport = RadioLogImportService(api: api, identify: identifyService)
        friends = FriendsService(api: api)
        gamification = GamificationService(api: api)
        gamificationV2 = GamificationV2Service(api: api)
        notifications = NotificationsService(api: api)
        let callsService = CallsService(api: api)
        calls = callsService
        users = UserService(api: api)
        // Synchroniseur Apple branché : livre les transactions StoreKit vérifiées
        // au backend et lit l'entitlement canonique. Les achats restent malgré
        // tout fermés tant que les flags `SQFeatures.storeKit*` sont à `false`
        // (activés uniquement en build staging le temps de valider la chaîne
        // serveur) : sa seule présence n'autorise aucun débit.
        entitlements = EntitlementsStore(
            api: api,
            synchronizer: AppStoreTransactionSynchronizer(api: api)
        )
        push = PushNotificationService(api: api, router: appRouter)
        callManager = CallManager(callsService: callsService, api: api)
    }

    /// Horodatage du dernier rafraîchissement du badge, pour throttler les GET
    /// complets déclenchés à CHAQUE changement d'onglet (PERF-BADGE-01).
    private var lastInboxBadgeRefresh: Date = .distantPast

    /// Recalcule le nombre de conversations non lues (dernier message postérieur à
    /// la dernière lecture). Approximation côté client, sans appel dédié.
    /// `force` (retour foreground) contourne le throttle de 20 s.
    func refreshInboxBadge(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastInboxBadgeRefresh) < 20 { return }
        guard let conversations = try? await messages.conversations() else { return }
        lastInboxBadgeRefresh = Date()
        unreadConversations = conversations.reduce(into: 0) { count, conversation in
            guard let lastMessageAt = conversation.lastMessageAt else { return }
            let lastReadAt = conversation.lastReadAt ?? .distantPast
            if lastMessageAt > lastReadAt { count += 1 }
        }
    }
}
