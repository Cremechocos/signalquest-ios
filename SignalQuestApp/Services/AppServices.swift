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
    let photos: PhotoServicing
    let messages: MessagesServicing
    let leaderboards: LeaderboardServicing
    let sessions: SessionsServicing
    let validations: ValidationsServicing
    let identify: IdentifyServicing
    let e2ee: E2EEServicing
    let friends: FriendsServicing
    let gamification: GamificationServicing
    let notifications: NotificationsServicing
    let calls: CallsServicing
    let users: UserServicing
    let push: PushNotificationService
    let router: AppRouter
    let callManager: CallManager
    let sse: SSEClient
    let location = LocationService()
    let networkPath = NetworkPathMonitor()

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
        privacy = PrivacyService(api: api)
        map = MapSnapshotService(api: api)
        let marketsService = MarketRegistryService(api: api)
        markets = marketsService
        antennas = AntennasService(api: api)
        anfr = ANFRService(api: api)
        speedtest = SpeedtestService(api: api, markets: marketsService)
        networkOperator = NetworkOperatorService(api: api)
        photos = PhotoService(api: api)
        messages = MessagesService(api: api)
        leaderboards = LeaderboardService(api: api)
        sessions = SessionsService(api: api)
        validations = ValidationsService(api: api)
        identify = IdentifyService(api: api)
        friends = FriendsService(api: api)
        gamification = GamificationService(api: api)
        notifications = NotificationsService(api: api)
        let callsService = CallsService(api: api)
        calls = callsService
        users = UserService(api: api)
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
