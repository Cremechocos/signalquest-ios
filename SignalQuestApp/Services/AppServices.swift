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
        validations = ValidationsService(api: api)
        identify = IdentifyService(api: api)
        friends = FriendsService(api: api)
        gamification = GamificationService(api: api)
        gamificationV2 = GamificationV2Service(api: api)
        notifications = NotificationsService(api: api)
        let callsService = CallsService(api: api)
        calls = callsService
        users = UserService(api: api)
        // Le synchroniseur Apple reste volontairement absent tant que le
        // backend ne valide pas les JWS StoreKit. Le store peut néanmoins lire
        // les droits canoniques et restaurer l'état local sans débiter.
        entitlements = EntitlementsStore(api: api)
        push = PushNotificationService(api: api, router: appRouter)
        callManager = CallManager(callsService: callsService, api: api)
    }

    /// Recalcule le nombre de conversations non lues (dernier message postérieur à
    /// la dernière lecture). Approximation côté client, sans appel dédié.
    func refreshInboxBadge() async {
        guard let conversations = try? await messages.conversations() else { return }
        unreadConversations = conversations.reduce(into: 0) { count, conversation in
            guard let lastMessageAt = conversation.lastMessageAt else { return }
            let lastReadAt = conversation.lastReadAt ?? .distantPast
            if lastMessageAt > lastReadAt { count += 1 }
        }
    }
}
