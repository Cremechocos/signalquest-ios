import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let api: APIClient
    let auth: AuthServicing
    let feed: SocialFeedServicing
    let feedSignals: FeedSignalsCollector
    let comments: CommentsServicing
    let stories: StoriesServicing
    let reports: ReportsServicing
    let privacy: PrivacyServicing
    let map: MapSnapshotServicing
    let markets: MarketRegistryServicing
    let antennas: AntennasServicing
    /// Relief et bâti le long d'une ligne de visée — alimente le profil
    /// d'altitude de la fiche antenne.
    let terrain: TerrainServicing
    /// Signalements d'antenne (émission, suivi, discussion avec la modération).
    let antennaReports: AntennaReportsServicing
    /// Création de sites pointés à la main (dont ceux déduits de cellules observées).
    let customSites: CustomSitesServicing
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
    /// Journal radio SYNCHRONISÉ du compte (capté sur Android, relu ici en
    /// lecture seule) — alimente la page « Logs antennes ».
    let radioLogs: RadioLogsServicing
    let e2ee: E2EEServicing
    let friends: FriendsServicing
    let gamification: GamificationServicing
    let gamificationV2: GamificationV2Servicing
    let notifications: NotificationsServicing
    let calls: CallsServicing
    let users: UserServicing
    let sentinelle: SentinelleServicing
    let entitlements: EntitlementsStore
    let push: PushNotificationService
    let router: AppRouter
    let callManager: CallManager
    let sse: SSEClient
    let location = LocationService()
    let networkPath = NetworkPathMonitor()
    /// Émetteur de la position/présence live pour la carte des amis.
    let livePresence: LivePresenceService
    /// Kill-switch de version : permet de forcer une mise à jour sans revue
    /// App Store, et conditionne tout durcissement de contrat côté backend.
    let versionPolicy: VersionPolicyService

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
        // Nourrit le classement « Pour toi ». Livrer l'onglet sans émettre ces
        // signaux donnerait un classement aveugle : les deux vont ensemble.
        feedSignals = FeedSignalsCollector(api: api)
        comments = CommentsService(api: api)
        stories = StoriesService(api: api)
        reports = ReportsService(api: api)
        let privacyService = PrivacyService(api: api)
        privacy = privacyService
        livePresence = LivePresenceService(api: api, location: location, networkPath: networkPath, privacy: privacyService)
        versionPolicy = VersionPolicyService(api: api)
        let mapService = MapSnapshotService(api: api)
        map = mapService
        let marketsService = MarketRegistryService(api: api)
        markets = marketsService
        antennas = AntennasService(api: api)
        terrain = TerrainService(api: api)
        antennaReports = AntennaReportsService(api: api)
        customSites = CustomSitesService(api: api)
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
        radioLogs = RadioLogsService(api: api)
        friends = FriendsService(api: api)
        gamification = GamificationService(api: api)
        gamificationV2 = GamificationV2Service(api: api)
        notifications = NotificationsService(api: api)
        let callsService = CallsService(api: api)
        calls = callsService
        users = UserService(api: api)
        sentinelle = SentinelleService(api: api)
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

    // MARK: - Cycle de vie de la scène

    /// Passage en arrière-plan : coupe les boucles réseau qui n'ont plus de
    /// raison de tourner.
    ///
    /// Sans cela, la présence live continuait de publier toutes les 5 à 20 s,
    /// écran verrouillé et sans limite de durée — `mapDidDisappear()` n'est
    /// appelé que sur `.onDisappear` de la carte, qui ne se déclenche pas au
    /// backgrounding. En drive test c'est aggravé : le background mode
    /// `location` empêche iOS de suspendre le processus, donc la boucle tourne
    /// réellement au lieu d'être gelée.
    ///
    /// La garde est délibérée : un drive test ou un appel en cours signifie que
    /// l'utilisateur a explicitement demandé une activité de fond, et ses amis
    /// s'attendent à le voir bouger. On ne coupe rien dans ces cas.
    ///
    /// La messagerie n'est pas concernée : `ConversationDetailView` arrête déjà
    /// son flux SSE et son polling sur `scenePhase`.
    func enterBackground() {
        // Vidage AVANT le garde-fou : les signaux d'engagement doivent partir
        // même pendant un drive test ou un appel, sinon le dernier lot meurt
        // avec l'app. C'est un seul POST, sans incidence sur la batterie.
        Task { [feedSignals] in await feedSignals.flushNow() }
        guard !location.wantsTracking, callManager.activeCall == nil else { return }
        livePresence.setAppActive(false)
    }

    /// Retour au premier plan : la diffusion reprend si les réglages de partage
    /// et le mode l'autorisent (`reevaluate()` tranche).
    func enterForeground() {
        livePresence.setAppActive(true)
    }
}
