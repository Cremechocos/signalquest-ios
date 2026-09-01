import SwiftUI
import CoreLocation
// `UIApplication.connectedScenes` : depuis que le manifeste autorise plusieurs
// scènes (CarPlay, fenêtres iPad), le cycle de vie ne peut plus se déduire du
// seul `scenePhase` d'une vue. Voir « Cycle de vie de la scène » plus bas.
import UIKit

/// État de présentation du badge Messages, borné à la session authentifiée qui
/// a lancé son rafraîchissement. Une réponse de A ne peut ainsi jamais publier
/// son compteur après un logout/login vers B, y compris pour le même compte
/// reconnecté avec un nouvel identifiant de session.
@MainActor
final class InboxBadgePresentationState {
    struct RefreshTicket: Equatable {
        let session: LocalAccountSession
        let generation: UInt
    }

    private let sessionSnapshot: () -> LocalAccountSession?
    private(set) var unreadCount = 0
    private var lastRefresh: Date = .distantPast
    private var generation: UInt = 0

    init(sessionSnapshot: @escaping () -> LocalAccountSession? = LocalAccountScope.sessionSnapshot) {
        self.sessionSnapshot = sessionSnapshot
    }

    func beginRefresh(force: Bool, now: Date = Date()) -> RefreshTicket? {
        guard let session = sessionSnapshot() else { return nil }
        if !force, now.timeIntervalSince(lastRefresh) < 20 { return nil }
        return RefreshTicket(session: session, generation: generation)
    }

    @discardableResult
    func publish(unreadCount: Int, for ticket: RefreshTicket, now: Date = Date()) -> Bool {
        guard ticket.generation == generation, sessionSnapshot() == ticket.session else { return false }
        self.unreadCount = unreadCount
        lastRefresh = now
        return true
    }

    func reset() {
        generation &+= 1
        unreadCount = 0
        lastRefresh = .distantPast
    }
}

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
    /// Signalement communautaire de pannes — cf. `CommunityOutageService`.
    let communityOutages: CommunityOutageServicing
    /// Antennes suivies. Observable et UNIQUE : le contrat serveur remplace la liste entière,
    /// donc deux copies et la dernière à écrire effacerait les ajouts de l'autre.
    let favoriteAntennas: FavoriteAntennasService
    /// Création de sites pointés à la main (dont ceux déduits de cellules observées).
    let customSites: CustomSitesServicing
    let anfr: ANFRServicing
    let speedtest: SpeedtestService
    /// Catalogue des POPs iPerf3 servi par l'API : permet de corriger un POP mort
    /// côté serveur sans release. Rafraîchi à l'ouverture de l'écran Speedtest.
    let iperfCatalog: IPerfCatalogService
    let networkOperator: NetworkOperatorServicing
    /// Verdict de qualité réseau communautaire (opérateur SIM) — pastille d'accueil.
    let nearbyQuality: NearbyNetworkQualityServicing
    let photos: PhotoServicing
    let messages: MessagesServicing
    /// Sessions de partage GPS/radio initiées depuis les conversations. Unique
    /// au niveau application pour que l'envoi continue quand on quitte l'écran
    /// de discussion, tout en restant strictement limité au premier plan.
    let liveShare: ConversationLiveShareCoordinator
    let leaderboards: LeaderboardServicing
    let sessions: SessionsServicing
    let validations: ValidationsServicing
    let identify: IdentifyServicing
    /// Journal radio SYNCHRONISÉ du compte (capté sur Android, relu ici en
    /// lecture seule) — alimente la page « Logs antennes ».
    let radioLogs: RadioLogsServicing
    let e2ee: E2EEServicing
    let epochRotations: E2EEV2EpochRotationRuntime
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
    private let inboxBadgeState = InboxBadgePresentationState()

    init(config: AppConfig = .current) {
        let credentials = CredentialStore()
        let api = APIClient(config: config, credentials: credentials)
        self.api = api
        let appRouter = AppRouter()
        router = appRouter
        let e2eeService = E2EEService(api: api)
        e2ee = e2eeService
        epochRotations = E2EEV2EpochRotationRuntime(api: api)
        let sseClient = SSEClient(api: api)
        sse = sseClient
        let authService = AuthService(api: api, e2ee: e2eeService)
        auth = authService
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
        communityOutages = CommunityOutageService(api: api)
        favoriteAntennas = FavoriteAntennasService(api: api)
        customSites = CustomSitesService(
            api: api,
            currentUserId: { authService.cachedUser()?.id }
        )
        anfr = ANFRService(api: api)
        let networkOperatorService = NetworkOperatorService(api: api)
        networkOperator = networkOperatorService
        nearbyQuality = NearbyNetworkQualityService(map: mapService, markets: marketsService, networkOperator: networkOperatorService)
        speedtest = SpeedtestService(api: api, markets: marketsService, networkOperator: networkOperatorService)
        photos = PhotoService(api: api)
        let messagesService = MessagesService(api: api, sse: sseClient)
        messages = messagesService
        liveShare = ConversationLiveShareCoordinator(
            service: messagesService,
            location: location,
            networkPath: networkPath
        )
        leaderboards = LeaderboardService(api: api)
        let sessionsService = SessionsService(api: api)
        sessions = sessionsService
        // Catalogue iPerf3 : on remonte d'abord le dernier connu DU DISQUE, sans
        // réseau — l'app dispose ainsi du bon catalogue dès le premier test, même
        // hors ligne. Le rafraîchissement réseau, lui, attend l'ouverture de l'écran
        // Speedtest : inutile de solliciter l'API au lancement pour un écran que
        // l'utilisateur n'ouvrira peut-être pas.
        let catalogService = IPerfCatalogService(api: api)
        iperfCatalog = catalogService
        Task { await catalogService.primeFromDisk() }
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

    /// Recalcule le nombre de conversations non lues (dernier message postérieur à
    /// la dernière lecture). Approximation côté client, sans appel dédié.
    /// `force` (retour foreground) contourne le throttle de 20 s.
    func refreshInboxBadge(force: Bool = false) async {
        guard let ticket = inboxBadgeState.beginRefresh(force: force) else { return }
        guard let conversations = try? await messages.conversations() else { return }
        let unread = conversations.reduce(into: 0) { count, conversation in
            guard let lastMessageAt = conversation.lastMessageAt else { return }
            let lastReadAt = conversation.lastReadAt ?? .distantPast
            if lastMessageAt > lastReadAt { count += 1 }
        }
        guard inboxBadgeState.publish(unreadCount: unread, for: ticket) else { return }
        unreadConversations = inboxBadgeState.unreadCount
    }

    /// Efface immédiatement tout état visuel privé de l'ancien compte. Le reset
    /// invalide aussi les requêtes déjà parties et rouvre le throttle pour que le
    /// nouveau compte puisse charger son propre badge sans attendre 20 secondes.
    func resetAccountPresentationState() {
        inboxBadgeState.reset()
        unreadConversations = 0
    }

    // MARK: - Amorçage partagé

    private var bootstrapTask: Task<Void, Never>?

    /// Amorçage de session, appelable depuis TOUS les points d'entrée — la
    /// fenêtre SwiftUI comme la scène CarPlay. Idempotent et coalescé : les
    /// appelants concurrents attendent le même travail au lieu de le refaire.
    ///
    /// Il vivait auparavant dans le seul `.task` d'`AppRootView`, ce qui
    /// supposait qu'une fenêtre finisse toujours par apparaître. CarPlay casse
    /// cette hypothèse : au branchement du véhicule, iOS lance l'app en
    /// arrière-plan et peut ne connecter QUE la scène du véhicule. Sans ce
    /// point d'entrée, `session.state` resterait sur `.checking` et l'interface
    /// CarPlay s'ouvrirait sans utilisateur authentifié.
    ///
    /// Corollaire utile sur iPad : deux fenêtres ne lancent plus deux
    /// `bootstrap()` concurrents sur le même modèle de session.
    func bootstrapIfNeeded(session: AuthSessionViewModel) async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { @MainActor in
            networkPath.start()
            await session.bootstrap()
            if case .authenticated(let user) = session.state {
                epochRotations.resume()
                // Le namespace du compte est actif : les files ne peuvent plus être
                // rejouées avec l'identité d'un autre utilisateur.
                await sessions.retryPendingCoverageSessions()
                await speedtest.retryPendingSaves()
                await liveShare.bootstrap(currentUserId: user.id)
            }
        }
        bootstrapTask = task
        await task.value
        if case .authenticated = session.state {
            await customSites.retryPending()
        }
    }

    // MARK: - Multi-scènes

    /// Vrai tant qu'une scène CarPlay est connectée au véhicule.
    private(set) var isCarPlayConnected = false

    /// La scène CarPlay peut-elle réellement GUIDER vers une destination ?
    ///
    /// Distinct de `isCarPlayConnected` : le guidage exige une `CPMapTemplate`,
    /// donc la catégorie `carplay-maps`. Avec la catégorie « driving task »
    /// accordée aujourd'hui, la scène est bien connectée mais ne sait pas
    /// conduire quelqu'un quelque part. Sans cette distinction, l'iPhone
    /// détournait « Y aller » vers un véhicule incapable d'y répondre — et
    /// n'ouvrait plus Plan non plus, donc le bouton ne faisait rien.
    private(set) var isCarPlayGuidanceAvailable = false

    func setCarPlayConnected(_ connected: Bool, canGuide: Bool = false) {
        isCarPlayConnected = connected
        isCarPlayGuidanceAvailable = connected && canGuide
    }

    /// Reste-t-il une fenêtre visible ? (La scène CarPlay n'en est pas une :
    /// elle n'est pas une `UIWindowScene`, et son cas est traité par
    /// `isCarPlayConnected`.)
    ///
    /// `scenePhase` est par scène, alors que ce graphe, `AppLockController` et
    /// `livePresence` sont uniques au process. Depuis que plusieurs scènes
    /// coexistent, masquer une fenêtre iPad ne doit plus couper la présence de
    /// celle qui reste visible — ni la verrouiller.
    ///
    /// On lit l'état réel des scènes plutôt que de tenir un compteur : une scène
    /// détruite en arrière-plan ne décrémenterait rien, et le compteur finirait
    /// par empêcher toute coupure. UIKit met `activationState` à jour avant de
    /// notifier le passage en arrière-plan, donc la scène appelante est déjà
    /// comptée comme partie quand on interroge ici.
    var hasVisibleWindowScene: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard scene is UIWindowScene else { return false }
            return scene.activationState == .foregroundActive ||
                scene.activationState == .foregroundInactive
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
        // Le live-share de conversation est volontairement « premier plan » :
        // il doit relâcher son observateur GPS AVANT la garde `wantsTracking`,
        // sinon cet observateur serait pris à tort pour un Drive Test explicite
        // et maintiendrait lui-même l'application active écran verrouillé.
        liveShare.setAppActive(false)
        // `isCarPlayConnected` rejoint la même logique que le drive test et
        // l'appel en cours : l'écran du véhicule affiche l'app, donc l'activité
        // de fond est voulue — couper la présence pendant que l'utilisateur
        // roule reviendrait à le faire disparaître de la carte de ses amis.
        guard !location.wantsTracking,
              callManager.activeCall == nil,
              !isCarPlayConnected else { return }
        livePresence.setAppActive(false)
    }

    /// Retour au premier plan : la diffusion reprend si les réglages de partage
    /// et le mode l'autorisent (`reevaluate()` tranche).
    func enterForeground() {
        if networkPath.isOnline { epochRotations.resume() }
        livePresence.setAppActive(true)
        liveShare.setAppActive(true)
    }
}

/// Orchestrateur des sessions live des conversations.
///
/// Une instance unique vit dans `AppServices` : les flux SSE et la publication
/// ne dépendent donc pas de la présence de `ConversationDetailView` dans la pile
/// de navigation. En revanche, `setAppActive(false)` coupe systématiquement GPS,
/// SSE et requêtes lors du passage réel en arrière-plan. C'est la limite honnête
/// d'iOS sans demander une autorisation de localisation plus intrusive.
@MainActor
final class ConversationLiveShareCoordinator: ObservableObject {
    @Published private(set) var sessionsByID: [String: LiveShareSession] = [:]
    @Published private(set) var payloadsBySessionID: [String: LiveSharePayload] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let service: MessagesServicing
    private let location: LocationService
    private let networkPath: NetworkPathMonitor

    private var currentUserId: String?
    private var accountGeneration = 0
    private var appIsActive = true
    private var streamTasks: [String: Task<Void, Never>] = [:]
    private var locationObserverToken: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var publishRequested = false
    private var lastObservedLocation: CLLocation?
    private var lastPublishedLocation: CLLocation?
    private var lastPublishedAt: Date?
    /// Un refus contractuel (opérateur/session) ne doit pas marteler l'API toutes
    /// les 20 secondes. Un rechargement ou une nouvelle action le réessaiera.
    private var terminalPublishFailures: Set<String> = []

    init(service: MessagesServicing, location: LocationService, networkPath: NetworkPathMonitor) {
        self.service = service
        self.location = location
        self.networkPath = networkPath
    }

    func sessions(for conversationId: String) -> [LiveShareSession] {
        sessionsByID.values
            .filter { $0.conversationId == conversationId && $0.isOpen }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func payload(for sessionId: String) -> LiveSharePayload? {
        payloadsBySessionID[sessionId]
    }

    func load(conversationId: String, currentUserId: String) async {
        let generation = activateAccount(currentUserId)
        do {
            let fetched = try await service.liveShareSessions(conversationId: conversationId)
            guard isCurrentAccount(currentUserId, generation: generation) else { return }
            terminalPublishFailures.subtract(fetched.map(\.id))
            replaceAuthoritative(fetched, conversationId: conversationId)
            errorMessage = nil
            syncRuntime()
        } catch {
            errorMessage = "Partage en direct indisponible : \(error.localizedDescription)"
        }
    }

    func bootstrap(currentUserId: String) async {
        let generation = activateAccount(currentUserId)
        do {
            let fetched = try await service.activeLiveShareSessions()
            guard isCurrentAccount(currentUserId, generation: generation) else { return }
            terminalPublishFailures.subtract(fetched.map(\.id))
            replaceAuthoritative(fetched)
            errorMessage = nil
            syncRuntime()
        } catch {
            errorMessage = "Partage en direct indisponible : \(error.localizedDescription)"
        }
    }

    func create(
        conversationId: String,
        e2eeEnabled: Bool,
        currentUserId: String,
        offerShare: Bool,
        message: String?,
        mode: String?,
        targetUserId: String?,
        targetUserIds: [String]
    ) async {
        guard !isBusy else { return }
        let generation = activateAccount(currentUserId)
        isBusy = true
        defer { isBusy = false }
        let plmn = networkPath.simPLMN()
        do {
            let response = try await service.createLiveShare(
                conversationId: conversationId,
                e2eeEnabled: e2eeEnabled,
                offerShare: offerShare,
                message: message,
                mode: mode,
                targetUserId: targetUserId,
                targetUserIds: targetUserIds,
                mobileCountryCode: plmn.mcc,
                mobileNetworkCode: plmn.mnc
            )
            guard isCurrentAccount(currentUserId, generation: generation) else { return }
            terminalPublishFailures.subtract(response.sessions.map(\.id))
            merge(response.sessions)
            errorMessage = nil
            syncRuntime()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func accept(sessionId: String) async {
        let e2eeV2Required = sessionsByID[sessionId]?.e2eeV2Required == true
        await mutate(sessionId: sessionId) {
            try await service.acceptLiveShare(
                sessionId: sessionId,
                e2eeV2Required: e2eeV2Required
            )
        }
    }

    func decline(sessionId: String) async {
        await mutate(sessionId: sessionId) {
            try await service.declineLiveShare(sessionId: sessionId)
        }
    }

    func stop(sessionId: String) async {
        guard !isBusy else { return }
        let generation = accountGeneration
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.stopLiveShare(sessionId: sessionId)
            guard generation == accountGeneration, currentUserId != nil else { return }
            updateStatus(sessionId: sessionId, status: "stopped")
            errorMessage = nil
            Haptics.success()
            syncRuntime()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        syncRuntime()
        if active, let currentUserId {
            Task { [weak self] in await self?.bootstrap(currentUserId: currentUserId) }
        }
    }

    func stopForSignOut() {
        accountGeneration &+= 1
        stopRuntime()
        sessionsByID = [:]
        payloadsBySessionID = [:]
        terminalPublishFailures = []
        currentUserId = nil
        errorMessage = nil
    }

    private func activateAccount(_ userId: String) -> Int {
        if currentUserId != userId {
            accountGeneration &+= 1
            stopRuntime()
            sessionsByID = [:]
            payloadsBySessionID = [:]
            terminalPublishFailures = []
            currentUserId = userId
        }
        return accountGeneration
    }

    private func isCurrentAccount(_ userId: String, generation: Int) -> Bool {
        currentUserId == userId && accountGeneration == generation
    }

    private func mutate(
        sessionId: String,
        operation: () async throws -> LiveShareSession
    ) async {
        guard !isBusy else { return }
        let generation = accountGeneration
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await operation()
            guard generation == accountGeneration, currentUserId != nil else { return }
            terminalPublishFailures.remove(sessionId)
            merge([updated])
            errorMessage = nil
            Haptics.success()
            syncRuntime()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func merge(_ incoming: [LiveShareSession]) {
        var next = sessionsByID
        var nextPayloads = payloadsBySessionID
        for var session in incoming {
            if let existing = next[session.id] {
                session.requester = session.requester ?? existing.requester
                session.sharer = session.sharer ?? existing.sharer
                session.lastPayload = session.lastPayload ?? existing.lastPayload
                session.lastLocation = session.lastLocation ?? existing.lastLocation
                session.lastUpdateAt = session.lastUpdateAt ?? existing.lastUpdateAt
            }
            next[session.id] = session
            if let payload = session.decodedPayload {
                nextPayloads[session.id] = payload
            }
        }
        sessionsByID = next
        payloadsBySessionID = nextPayloads
    }

    private func replaceAuthoritative(
        _ incoming: [LiveShareSession],
        conversationId: String? = nil
    ) {
        let retained = sessionsByID.filter { _, session in
            if let conversationId { return session.conversationId != conversationId }
            return false
        }
        sessionsByID = retained
        let retainedIDs = Set(retained.keys)
        payloadsBySessionID = payloadsBySessionID.filter { retainedIDs.contains($0.key) }
        merge(incoming)
    }

    private func updateStatus(sessionId: String, status: String) {
        guard var session = sessionsByID[sessionId] else { return }
        session.status = status
        if status != "pending" && status != "active" { session.endedAt = Date() }
        sessionsByID[sessionId] = session
    }

    private func syncRuntime() {
        guard appIsActive, currentUserId != nil else {
            stopRuntime()
            return
        }
        syncStreams()
        syncPublisher()
    }

    private func syncStreams() {
        let desired = Set(sessionsByID.values.filter { session in
            session.isOpen && (
                session.e2eeV2Required != true || E2EEV2RuntimeReadGate.enabled
            )
        }.map(\.id))
        for id in Array(streamTasks.keys) where !desired.contains(id) {
            streamTasks.removeValue(forKey: id)?.cancel()
        }
        for id in desired where streamTasks[id] == nil {
            let generation = accountGeneration
            streamTasks[id] = Task { [weak self, service = self.service] in
                defer {
                    if let self, self.accountGeneration == generation {
                        self.streamTasks[id] = nil
                        if self.sessionsByID[id]?.isOpen == true {
                            Task { [weak self] in
                                try? await Task.sleep(for: .seconds(2))
                                guard let self, self.accountGeneration == generation else { return }
                                self.syncStreams()
                            }
                        }
                    }
                }
                guard let initial = self?.sessionsByID[id] else { return }
                let events = initial.e2eeV2Required == true
                    ? service.e2eeLiveShareEvents(session: initial)
                    : service.liveShareEvents(sessionId: id)
                for await event in events {
                    guard !Task.isCancelled, let self,
                          self.accountGeneration == generation else { return }
                    self.consume(event, sessionId: id)
                }
            }
        }
    }

    private func consume(_ event: LiveShareStreamEvent, sessionId: String) {
        switch event {
        case .status(let status):
            updateStatus(sessionId: sessionId, status: status)
            syncRuntime()
        case .update(let status, let lastUpdateAt, let payload):
            if let status { updateStatus(sessionId: sessionId, status: status) }
            if var session = sessionsByID[sessionId] {
                session.lastUpdateAt = lastUpdateAt ?? session.lastUpdateAt
                sessionsByID[sessionId] = session
            }
            if let payload { payloadsBySessionID[sessionId] = payload }
        }
    }

    private func syncPublisher() {
        guard !publishableSessions.isEmpty else {
            stopPublisher()
            return
        }
        if locationObserverToken == nil {
            locationObserverToken = location.addLocationObserver { [weak self] value in
                self?.receiveLocation(value)
            }
        }
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            if let initial = await self.location.currentLocation(timeoutSeconds: 8, maxAge: 30) {
                self.receiveLocation(initial, force: true)
            } else {
                self.requestPublish(force: true)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.appIsActive else { break }
                self.requestPublish(force: true)
            }
        }
    }

    private var publishableSessions: [LiveShareSession] {
        guard let currentUserId else { return [] }
        return sessionsByID.values.filter {
            $0.status == "active" &&
            $0.sharerId == currentUserId &&
            ($0.e2eeV2Required != true || E2EEV2RuntimeWriteGate.enabled) &&
            !terminalPublishFailures.contains($0.id)
        }
    }

    private func receiveLocation(_ value: CLLocation, force: Bool = false) {
        lastObservedLocation = value
        requestPublish(force: force)
    }

    private func requestPublish(force: Bool) {
        guard appIsActive, !publishableSessions.isEmpty else { return }
        let now = Date()
        if !force, let lastPublishedAt {
            let elapsed = now.timeIntervalSince(lastPublishedAt)
            let distance = lastPublishedLocation.map { lastObservedLocation?.distance(from: $0) ?? 0 } ?? .greatestFiniteMagnitude
            if elapsed < 5 || (distance < 8 && elapsed < 20) { return }
        }
        publishRequested = true
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            guard let self else { return }
            while self.publishRequested, !Task.isCancelled {
                self.publishRequested = false
                await self.publishSnapshot(location: self.lastObservedLocation ?? self.location.lastLocation)
            }
            self.publishTask = nil
        }
    }

    private func publishSnapshot(location currentLocation: CLLocation?) async {
        guard appIsActive else { return }
        networkPath.refreshNow()
        let status = networkPath.status
        let sim = networkPath.simPLMN()
        let activeSimPlmn = status.connection == .cellular ? (status.simPlmn ?? sim.plmn) : nil
        let payload = LiveSharePayload(
            radio: LiveShareRadio(
                connectionType: status.speedtestConnectionType,
                technology: status.cellularTechnology?.displayName,
                // CoreTelephony décrit la SIM, pas nécessairement le réseau
                // visité. Aucun PLMN servant n'est donc fabriqué en roaming.
                operatorName: nil,
                mcc: nil,
                mnc: nil,
                observedPlmn: nil,
                simPlmn: activeSimPlmn,
                simOperatorName: status.operatorName,
                networkIdentitySource: activeSimPlmn == nil ? nil : "SIM"
            ),
            location: currentLocation.map {
                LiveShareLocation(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    accuracy: $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil,
                    altitude: $0.verticalAccuracy >= 0 ? $0.altitude : nil,
                    speed: $0.speed >= 0 ? $0.speed : nil,
                    heading: $0.course >= 0 ? $0.course : nil
                )
            },
            at: ISO8601DateFormatter().string(from: Date())
        )

        var sawSuccess = false
        for session in publishableSessions {
            guard appIsActive, !Task.isCancelled else { break }
            do {
                if session.e2eeV2Required == true {
                    try await service.updateE2eeLiveShare(session: session, payload: payload)
                } else {
                    let updated = try await service.updateLiveShare(
                        sessionId: session.id,
                        payload: payload
                    )
                    merge([updated])
                }
                payloadsBySessionID[session.id] = payload
                sawSuccess = true
            } catch {
                errorMessage = "Partage en direct interrompu : \(error.localizedDescription)"
                if case APIError.http(let status, _, _, _, _) = error,
                   status == 400 || status == 403 || status == 404 {
                    terminalPublishFailures.insert(session.id)
                }
            }
        }
        if sawSuccess {
            lastPublishedAt = Date()
            lastPublishedLocation = currentLocation
            errorMessage = nil
        }
        if publishableSessions.isEmpty { stopPublisher() }
    }

    private func stopRuntime() {
        for task in streamTasks.values { task.cancel() }
        streamTasks = [:]
        stopPublisher()
    }

    private func stopPublisher() {
        if let locationObserverToken {
            location.removeLocationObserver(locationObserverToken)
            self.locationObserverToken = nil
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        publishTask?.cancel()
        publishTask = nil
        publishRequested = false
        lastObservedLocation = nil
        lastPublishedLocation = nil
        lastPublishedAt = nil
    }
}
