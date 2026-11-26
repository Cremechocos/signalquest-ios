import SwiftUI
import CoreLocation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var page: SocialFeedPage?
    @Published var selectedHashtag: String? { didSet { if oldValue != selectedHashtag { invalidateQuery() } } }
    @Published var isLoading = false
    @Published var isLoadingMore = false
    /// La suite du fil n'est pas venue (échec, ou pages vides à la file) : le bas du fil offre
    /// de réessayer, sinon rien ne relançait le chargement quand les dernières cartes étaient
    /// déjà à l'écran (COM-04).
    @Published private(set) var loadMoreStalled = false
    @Published var errorMessage: String?
    /// Échec d'une action (like, vote, épingle…) : message passager, jamais
    /// l'écran d'erreur du chargement, dont « Réessayer » rechargeait tout le
    /// fil (SOC-14).
    @Published var actionError: String?
    /// Pouls réseau (héro) — nil tant qu'aucune donnée / position n'est disponible.
    @Published var pulse: NetworkPulse?
    /// Stories ouvertes depuis le chargement du rail : leur anneau passe en gris
    /// aussitôt, sans attendre le prochain rechargement du fil.
    @Published private(set) var viewedStoryIds: Set<String> = []
    private var lastPulseLoadAt: Date?

    private let service: SocialFeedServicing
    private let storiesService: StoriesServicing?
    private let location: LocationService?
    /// Au plus une revérification du fil par intervalle : chaque instantané du flux en
    /// relançait une (20 posts complets), sans délai (audit perf, E2). Un instantané reçu
    /// entre-temps n'est pas perdu : il en déclenche une seule, à l'échéance.
    private let liveCheckInterval: TimeInterval
    private var lastLiveCheckAt: Date?
    private var deferredLiveCheck: Task<Void, Never>?

    init(service: SocialFeedServicing, storiesService: StoriesServicing? = nil, location: LocationService? = nil,
         liveCheckInterval: TimeInterval = 10) {
        self.service = service
        self.storiesService = storiesService
        self.location = location
        self.liveCheckInterval = liveCheckInterval
    }

    /// Charge le pouls réseau autour de la position courante. Ne déclenche JAMAIS
    /// de prompt de localisation depuis le feed : on ne l'interroge que si
    /// l'autorisation est déjà accordée ou qu'une position est déjà connue. Échec
    /// silencieux : le héro disparaît simplement.
    func loadPulse(force: Bool = false) async {
        if AppEnvironment.usesDemoData { pulse = .demo; return }
        // Revenir sur le fil ne relance pas la mesure à chaque fois : cinq minutes
        // de validité, sauf tirer pour rafraîchir.
        if !force, pulse != nil, let last = lastPulseLoadAt, Date().timeIntervalSince(last) < 300 { return }
        guard let location else { return }
        let status = location.authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        guard authorized || location.lastLocation != nil else { return }
        guard let coordinate = await location.currentLocation()?.coordinate else { return }
        do {
            let result = try await service.networkPulse(latitude: coordinate.latitude, longitude: coordinate.longitude, radiusMeters: nil)
            pulse = result.hasData ? result : nil
            lastPulseLoadAt = Date()
        } catch {
            // Silencieux : le héro n'est simplement pas affiché.
        }
    }

    /// Onglet actif. Changer d'onglet change le couple filtre/classement envoyé
    /// au serveur — c'est le seul état qui pilote `loadFeed`.
    @Published var tab: FeedTab = .forYou { didSet { if oldValue != tab { invalidateQuery(); rememberTab() } } }

    /// Rayon de « Autour » servi par la dernière page reçue ; nil tant qu'aucune n'est arrivée.
    @Published private(set) var nearRadiusKm: Int?
    /// Mes abonnements, lus pour l'état vide de « Suivis » : « Tu ne suis encore personne »
    /// et « Rien de neuf » ne disent pas la même chose. nil tant qu'inconnu.
    @Published private(set) var followingCount: Int?
    /// La lecture a échoué : « Rien de neuf… », jamais « personne » à qui suit peut-être des profils.
    @Published private(set) var followingCountFailed = false
    private var followingCountOwner: String?
    /// Profils suivis depuis l'état vide, en un toucher, et ceux dont la réponse est attendue.
    @Published private(set) var followedSuggestionIds: Set<String> = []
    @Published private(set) var followBusyIds: Set<String> = []
    private var didRestoreTab = false

    /// Tri choisi par onglet (préférence `feedSort` du compte, Fil Communauté C8). Un onglet
    /// absent suit son défaut. Le dernier état connu sert tout de suite, le serveur le confirme.
    @Published private(set) var feedSort: [FeedTab: FeedSortChoice] = [:]
    private var feedSortOwner: String?

    /// Tri appliqué à un onglet ; nil pour un onglet sans choix (Suivis, Enregistrés).
    func sort(for tab: FeedTab) -> FeedSortChoice? {
        tab.sortKey == nil ? nil : (feedSort[tab] ?? tab.defaultSort)
    }

    /// L'onglet ouvert se lit dans l'ordre chronologique : séparateurs de jour, heure exacte.
    var isChronological: Bool { tab.isChronological(for: sort(for: tab)) }

    nonisolated static func feedSortKey(ownerScopeId: String) -> String {
        "FeedView.feedSort.\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    /// Dernier `feedSort` connu de ce compte, sur cet appareil : le fil s'ouvre dans le bon tri
    /// sans attendre le serveur. Relu à chaque changement de compte.
    func restoreFeedSort(defaults: UserDefaults = .standard) {
        let owner = LocalAccountScope.currentOwnerScopeId
        guard feedSortOwner != owner else { return }
        feedSortOwner = owner
        let raw = defaults.dictionary(forKey: Self.feedSortKey(ownerScopeId: owner)) as? [String: String]
        feedSort = FeedTab.sortPreference(from: raw)
    }

    private func storeFeedSort(defaults: UserDefaults = .standard) {
        var raw: [String: String] = [:]
        for (tab, choice) in feedSort { if let key = tab.sortKey { raw[key] = choice.rawValue } }
        defaults.set(raw, forKey: Self.feedSortKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId))
    }

    /// La préférence servie remplace le dernier état connu. Si le tri de l'onglet ouvert change
    /// (choisi sur une autre app), le fil se recharge, la page affichée restant à l'écran.
    func refreshFeedSort() async {
        guard !AppEnvironment.usesDemoData, LocalAccountScope.sessionSnapshot() != nil else { return }
        let owner = LocalAccountScope.currentOwnerScopeId
        guard let served = try? await service.feedSortPreference(),
              owner == LocalAccountScope.currentOwnerScopeId else { return }
        let before = sort(for: tab)
        feedSort = served
        storeFeedSort()
        if sort(for: tab) != before, page != nil { await reloadKeepingPage() }
    }

    /// « Pertinence | Récent » : le choix vaut pour cet onglet, sur le compte. La page affichée
    /// reste à l'écran jusqu'à l'arrivée de la nouvelle. Un enregistrement refusé ne change pas
    /// l'affichage ; le choix revient du serveur au prochain affichage.
    func selectSort(_ choice: FeedSortChoice) async {
        guard tab.sortKey != nil, sort(for: tab) != choice else { return }
        let changedTab = tab
        feedSort[changedTab] = choice
        storeFeedSort()
        if !AppEnvironment.usesDemoData, LocalAccountScope.sessionSnapshot() != nil {
            Task { [service] in _ = try? await service.setFeedSort(choice, for: changedTab) }
        }
        await reloadKeepingPage()
    }

    private func reloadKeepingPage() async {
        queryRevision = UUID()
        pendingCount = 0; pendingItems = []; pendingBaseline = nil; knownIds.removeAll(); needsLiveCheck = false; liveCheckID = nil
        restartStream()
        await load()
    }

    /// Dernier onglet ouvert, par compte, sur cet appareil (plan Fil Communauté, C1).
    nonisolated static func lastTabKey(ownerScopeId: String) -> String {
        "FeedView.lastTab.\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    /// Relit le dernier onglet, une seule fois, au premier affichage du fil. Jamais
    /// « Enregistrés », qui s'ouvre depuis le menu ⋯. Vrai si l'onglet a changé.
    func restoreLastTab(defaults: UserDefaults = .standard) -> Bool {
        guard !didRestoreTab else { return false }
        didRestoreTab = true
        let key = Self.lastTabKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
        guard let raw = defaults.string(forKey: key), let saved = FeedTab(rawValue: raw),
              saved != .saved, saved != tab else { return false }
        tab = saved
        return true
    }

    /// N'écrit que ce qui change : une écriture inutile à chaque toucher ne sert à rien.
    private func rememberTab(defaults: UserDefaults = .standard) {
        guard tab != .saved else { return }
        let key = Self.lastTabKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
        if defaults.string(forKey: key) != tab.rawValue { defaults.set(tab.rawValue, forKey: key) }
    }

    /// Mes abonnements, pour l'état vide de « Suivis ». Relu à chaque compte.
    func loadFollowingCount(userId: String) async {
        let owner = LocalAccountScope.currentOwnerScopeId
        guard followingCountOwner != owner || followingCount == nil else { return }
        if followingCountOwner != owner { followingCount = nil; followingCountFailed = false }
        if AppEnvironment.usesDemoData { followingCount = 0; followingCountOwner = owner; return }
        do {
            let profile = try await service.userProfile(userId: userId)
            guard owner == LocalAccountScope.currentOwnerScopeId else { return }
            followingCount = profile.followingCount
            followingCountFailed = false
            followingCountOwner = owner
        } catch {
            guard owner == LocalAccountScope.currentOwnerScopeId, !error.isCancellation else { return }
            followingCountFailed = true
        }
    }

    /// Suivre un profil suggéré en un toucher, depuis l'état vide. La route serveur est
    /// une bascule : un profil déjà suivi n'est jamais renvoyé, il serait désabonné.
    func followSuggestion(_ author: SocialFeedAuthor) {
        guard author.isFollowing != true, !followBusyIds.contains(author.id),
              !followedSuggestionIds.contains(author.id) else { return }
        Haptics.medium()
        followedSuggestionIds.insert(author.id)
        if AppEnvironment.usesDemoData { return }
        followBusyIds.insert(author.id)
        Task {
            defer { followBusyIds.remove(author.id) }
            do {
                let result = try await service.toggleFollow(userId: author.id)
                if !result.following { followedSuggestionIds.remove(author.id) }
                // « Rien de neuf… » aussitôt, sans relire le profil (règle commune du 25/11).
                if let count = result.followingCount { followingCount = count }
                else if result.following { followingCount = max(followingCount ?? 0, 1) }
                // « Suivis » se remplit aussitôt avec les publications du profil suivi.
                if result.following, tab == .following { await load() }
            } catch {
                followedSuggestionIds.remove(author.id)
                if !error.isCancellation { actionError = error.userFacingMessage }
                Haptics.error()
            }
        }
    }

    /// Où en est la position de l'onglet « Autour ».
    enum NearbyPosition: Equatable {
        case ready
        /// Jamais demandée : l'onglet propose de l'autoriser (choix explicite de la personne).
        case needsPermission
        case denied
        /// Autorisée mais aucun point obtenu (intérieur, délai dépassé).
        case unavailable
    }

    /// Point arrondi envoyé avec « Autour » ; relu à chaque chargement de l'onglet.
    @Published private(set) var nearPoint: FeedNearPoint?
    @Published private(set) var nearbyPosition: NearbyPosition = .ready
    /// Publications reçues en direct et NON encore insérées.
    ///
    /// Le plan est explicite : jamais d'insertion directe. Faire remonter la
    /// liste pendant que l'utilisateur lit déplace ce qu'il regarde — on
    /// annonce, il décide. C'est aussi ce que font toutes les apps de fil.
    @Published private(set) var pendingCount = 0
    /// Les publications annoncées par la pastille, plus récentes que tout ce qui est affiché.
    /// Un toucher les insère en tête, quel que soit le tri (Fil Communauté, C2/C8).
    private var pendingItems: [UnifiedSocialFeedItem] = []
    /// Référence de la pastille, prise à l'ouverture de l'onglet (ou après un changement de tri,
    /// de zone, un rechargement) par une lecture `latest` : en Pertinence, la page classée ne
    /// contient pas les plus récentes, qui seraient sinon annoncées dès l'ouverture (règle
    /// commune du 25/11, défaut vu en prod sur le Web).
    private struct PendingBaseline {
        let ids: Set<String>
        let newest: Date?
        init(_ items: [UnifiedSocialFeedItem]) {
            ids = Set(items.map(\.id))
            newest = items.compactMap(\.createdAt).max()
        }
    }
    private var pendingBaseline: PendingBaseline?
    private var baselineTask: Task<Void, Never>?
    @Published private(set) var trendingHashtags: [TrendingHashtag] = []
    private struct Query: Equatable {
        let tab: FeedTab
        let sort: FeedSortChoice?
        let near: FeedNearPoint?
        let hashtag: String?
        let owner: String
        let session: LocalAccountSession?
        let revision: UUID
    }
    private var queryRevision = UUID()
    private var loadRevision = UUID()
    private struct DetailReceipt {
        let revision: UInt64
        let item: UnifiedSocialFeedItem
    }
    private var detailReceiptRevision: UInt64 = 0
    private var detailReceipts: [String: DetailReceipt] = [:]
    private var streamRevision = UUID()
    private var metadataOwner = LocalAccountScope.currentOwnerScopeId
    private var streamTask: Task<Void, Never>?
    private var streamFactory: (() -> AsyncStream<(event: String, data: String)>)?
    private var needsLiveCheck = false
    private var liveCheckID: UUID?
    private var knownIds: Set<String> = []
    private var query: Query {
        Query(tab: tab, sort: sort(for: tab), near: tab.needsPosition ? nearPoint : nil, hashtag: selectedHashtag,
              owner: LocalAccountScope.currentOwnerScopeId,
              session: LocalAccountScope.sessionSnapshot(), revision: queryRevision)
    }

    private func invalidateQuery() {
        queryRevision = UUID(); loadRevision = UUID()
        detailReceipts.removeAll()
        page = nil; errorMessage = nil; isLoading = true; isLoadingMore = false; loadMoreStalled = false
        pendingCount = 0; pendingItems = []; pendingBaseline = nil; knownIds.removeAll(); needsLiveCheck = false; liveCheckID = nil
        if metadataOwner != LocalAccountScope.currentOwnerScopeId { trendingHashtags = [] }
        restartStream()
    }

    func select(_ newTab: FeedTab) async {
        guard newTab != tab else { return }
        tab = newTab
        await load()
    }

    /// Position de « Autour », sans jamais déclencher la demande d'autorisation : celle-ci ne part
    /// que du bouton de l'onglet. Un point déjà lu sert tant qu'il est frais (`currentLocation`).
    private func resolveNearPoint() async {
        // Une zone choisie à la main passe avant la position de l'appareil, sans rien lui demander.
        if let nearbyZone { nearPoint = nearbyZone.point; nearbyPosition = .ready; return }
        guard let location else { nearbyPosition = .unavailable; return }
        switch location.authorizationStatus {
        case .notDetermined:
            nearbyPosition = .needsPermission
        case .denied, .restricted:
            nearbyPosition = .denied
        default:
            if let coordinate = await location.currentLocation()?.coordinate {
                nearPoint = FeedNearPoint(coordinate)
                nearbyPosition = .ready
            } else {
                nearbyPosition = nearPoint == nil ? .unavailable : .ready
            }
        }
    }

    /// Zone choisie à la main pour « Autour » (plan Fil Communauté, C4) : elle remplace la
    /// position de l'appareil, refusée ou non, sans redemander l'autorisation. Le point est
    /// arrondi comme une position (environ 1 km). Elle vaut pour la session.
    struct NearbyZone: Equatable {
        let name: String
        let point: FeedNearPoint
    }
    @Published private(set) var nearbyZone: NearbyZone?

    /// L'état vide affiché propose déjà « Publier » (Autour sans publication) : le crayon
    /// flottant se retire pour ne pas doubler l'action (règle commune du 25/11). Mêmes
    /// conditions que celles qui affichent cet état vide dans la vue.
    var emptyStateOffersPublish: Bool {
        guard tab == .nearby, selectedHashtag == nil, nearbyPosition == .ready,
              !isLoading, errorMessage == nil, let page else { return false }
        return page.items.isEmpty
    }

    func chooseNearbyZone(name: String, coordinate: CLLocationCoordinate2D) async {
        nearbyZone = NearbyZone(name: name, point: FeedNearPoint(coordinate))
        guard tab.needsPosition else { return }
        await load()
    }

    /// Retour à la position de l'appareil : relue au chargement, ou l'état qui dit ce qui manque.
    func clearNearbyZone() async {
        guard nearbyZone != nil else { return }
        nearbyZone = nil
        nearPoint = nil
        guard tab.needsPosition else { return }
        await load()
    }

    /// Bouton « Autoriser » de l'onglet « Autour » : la demande d'iOS, puis l'onglet se recharge
    /// dès la réponse.
    func requestNearbyPermission() async {
        guard let location else { return }
        location.requestWhenInUse()
        for await status in location.$authorizationStatus.values where status != .notDetermined {
            break
        }
        guard tab.needsPosition else { return }
        await load()
    }

    func startStream(_ sse: SSEClient) {
        startStream { sse.dataStream(path: "/api/social/feed/stream", keep: ["snapshot"], bufferingPolicy: .bufferingNewest(1)) }
    }

    func startStream(_ factory: @escaping () -> AsyncStream<(event: String, data: String)>) {
        guard streamTask == nil else { return }
        streamFactory = factory
        restartStream()
        // Flux repris sur une page déjà affichée (retour sur le fil) : la référence d'abord.
        if page != nil, !isLoading, pendingBaseline == nil {
            let context = query, loading = loadRevision
            baselineTask = Task { [weak self] in await self?.establishPendingBaseline(context: context, loading: loading) }
        }
    }

    private func restartStream() {
        streamRevision = UUID()
        streamTask?.cancel(); streamTask = nil
        // Un nouveau flux (onglet, hashtag, reconnexion) revérifie sans attendre l'intervalle.
        deferredLiveCheck?.cancel(); deferredLiveCheck = nil; lastLiveCheckAt = nil
        guard let streamFactory else { return }
        let streamID = streamRevision, context = query
        let messages = streamFactory()
        streamTask = Task { [weak self] in
            for await message in messages {
                guard !Task.isCancelled else { break }
                await self?.handleSnapshot(message.data, context: context, streamID: streamID)
            }
            if self?.streamRevision == streamID { self?.streamTask = nil }
        }
    }

    func stopStream() {
        streamFactory = nil; streamRevision = UUID(); loadRevision = UUID()
        streamTask?.cancel(); streamTask = nil
        deferredLiveCheck?.cancel(); deferredLiveCheck = nil
        isLoading = false; isLoadingMore = false; needsLiveCheck = false; liveCheckID = nil
    }

    deinit { streamTask?.cancel(); deferredLiveCheck?.cancel() }

    private func handleSnapshot(_ raw: String, context: Query, streamID: UUID) async {
        guard await Self.isValidSnapshot(raw),
              context == query, streamID == streamRevision, !Task.isCancelled else { return }
        // The shared SSE endpoint sends global latest posts, not this tab or
        // hashtag. Treat it as an invalidation and re-read the exact filter.
        guard !isLoading, page != nil else { needsLiveCheck = true; return }
        await refreshPending(context: context, streamID: streamID)
    }

    /// L'instantané porte les derniers posts complets : il était décodé sur le fil
    /// principal à chaque événement, rien que pour le valider (SOC-43).
    nonisolated private static func isValidSnapshot(_ raw: String) async -> Bool {
        await Task.detached(priority: .utility) {
            struct Snapshot: Decodable { let items: [UnifiedSocialFeedItem] }
            guard let data = raw.data(using: .utf8) else { return false }
            return (try? JSONDecoder.signalQuest.decode(Snapshot.self, from: data)) != nil
        }.value
    }

    private func refreshPending(context: Query, streamID: UUID) async {
        guard context == query, streamID == streamRevision, !Task.isCancelled else { return }
        guard !isLoading, page != nil, liveCheckID == nil else { needsLiveCheck = true; return }
        if let last = lastLiveCheckAt, case let wait = liveCheckInterval - Date().timeIntervalSince(last), wait > 0 {
            guard deferredLiveCheck == nil else { return }
            deferredLiveCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.deferredLiveCheck = nil
                await self?.refreshPending(context: context, streamID: streamID)
            }
            return
        }
        lastLiveCheckAt = Date()
        let check = UUID()
        liveCheckID = check
        defer {
            if liveCheckID == check {
                liveCheckID = nil
                if needsLiveCheck, !isLoading, context == query, streamID == streamRevision {
                    needsLiveCheck = false
                    Task { [weak self] in await self?.refreshPending(context: context, streamID: streamID) }
                }
            }
        }
        // La lecture d'ouverture d'abord : sans elle, cette relecture servirait de référence.
        if pendingBaseline == nil, let baselineTask { await baselineTask.value }
        let loading = loadRevision
        do {
            // Toujours en `latest`, jamais mis en cache, quel que soit le tri affiché : la première
            // page « Pertinence » reste figée 60 s (contrat B3, « Pastille »).
            let freshPage = try await service.loadFeedItems(cursor: nil, hashtag: context.hashtag, tab: context.tab,
                                                            near: context.near, sort: .latest)
            guard context == query, streamID == streamRevision, loading == loadRevision,
                  !Task.isCancelled, let page else { return }
            // Sans référence encore (lecture d'ouverture ratée ou en cours), celle-ci la fixe.
            guard let baseline = pendingBaseline else { pendingBaseline = PendingBaseline(freshPage.items); return }
            let fresh = Self.newerItems(in: freshPage.items, than: page.items + pendingItems,
                                        excluding: knownIds.union(deferredDeletions.keys).union(deletions.pendingPostIds)
                                            .union(baseline.ids),
                                        after: baseline.newest)
                .filter { !removedAuthorIds.contains($0.author.id) }
            knownIds.formUnion(fresh.map(\.id))
            pendingItems = fresh + pendingItems
            pendingCount = pendingItems.count
        } catch {
            // A live refresh failure never replaces the current reading.
        }
    }

    /// Nouveautés : seulement ce qui est plus récent que la publication la plus récente déjà
    /// affichée. Une publication ancienne qui remonte (classement recalculé) ou une publication
    /// en cours de suppression n'est pas une nouveauté.
    nonisolated static func newerItems(in candidates: [UnifiedSocialFeedItem], than shown: [UnifiedSocialFeedItem],
                                       excluding ids: Set<String>, after reference: Date? = nil) -> [UnifiedSocialFeedItem] {
        let shownIds = Set(shown.map(\.id))
        let newest = (shown.compactMap(\.createdAt) + [reference].compactMap { $0 }).max()
        var seen = Set<String>()
        return candidates.filter { item in
            guard !shownIds.contains(item.id), !ids.contains(item.id), seen.insert(item.id).inserted else { return false }
            guard let newest else { return true }
            guard let created = item.createdAt else { return false }
            return created > newest
        }
    }

    /// Lecture `latest` d'ouverture : elle fixe la référence de la pastille, sans rien annoncer.
    private func establishPendingBaseline(context: Query, loading: UUID) async {
        guard let items = try? await service.loadFeedItems(cursor: nil, hashtag: context.hashtag, tab: context.tab,
                                                           near: context.near, sort: .latest).items,
              context == query, loading == loadRevision, pendingBaseline == nil else { return }
        pendingBaseline = PendingBaseline(items)
    }

    /// Toucher la pastille insère les nouveautés en tête, sans relire le tri affiché (figé 60 s
    /// en Pertinence, il ne les contiendrait pas). Sans nouveauté gardée, un rechargement.
    func applyPending() async {
        guard !pendingItems.isEmpty, let current = page else { await load(); return }
        let inserted = pendingItems.filter { item in !current.items.contains { $0.id == item.id } }
        page = SocialFeedPage(
            items: inserted + current.items, nextCursor: current.nextCursor, stories: current.stories,
            trendingHashtags: current.trendingHashtags, suggestedUsers: current.suggestedUsers,
            requestId: current.requestId
        )
        pendingItems = []; pendingCount = 0
    }

    func load() async {
        // « Autour » lit sa position d'abord : sans point, aucune requête, l'onglet dit pourquoi.
        if tab.needsPosition, !AppEnvironment.usesDemoData {
            await resolveNearPoint()
            guard tab.needsPosition else { return }
            if nearPoint == nil {
                // Une page vide, pas `nil` : sans page, le fil garde son squelette de chargement.
                page = SocialFeedPage(items: [], nextCursor: nil, stories: [], trendingHashtags: [],
                                      suggestedUsers: [], requestId: nil)
                errorMessage = nil; isLoading = false; isLoadingMore = false
                return
            }
        }
        let context = query, request = UUID()
        let receiptRevisionAtStart = detailReceiptRevision
        loadRevision = request; isLoading = true; isLoadingMore = false; loadMoreStalled = false; errorMessage = nil
        if metadataOwner != context.owner { trendingHashtags = [] }
        defer { if context == query && loadRevision == request { isLoading = false } }
        if AppEnvironment.usesDemoData {
            page = .demo; trendingHashtags = page?.trendingHashtags ?? []
            pendingCount = 0; pendingItems = []; pendingBaseline = nil; knownIds.removeAll()
            return
        }
        Task { await service.retryPendingPosts() }
        if AppEnvironment.delaysLoadForQA { try? await Task.sleep(for: .seconds(4)) }
        do {
            let loaded = try await service.loadFeed(cursor: nil, hashtag: context.hashtag, tab: context.tab,
                                                    near: context.near, sort: context.sort)
            guard context == query, request == loadRevision, !Task.isCancelled else { return }
            if let radius = loaded.nearRadiusKm, radius > 0 { nearRadiusKm = Int(radius.rounded()) }
            let deleting = deletions.pendingPostIds
            page = SocialFeedPage(
                items: loaded.items.filter { deferredDeletions[$0.id] == nil && !deleting.contains($0.id) }.map { item in
                    guard let receipt = detailReceipts[item.id],
                          receipt.revision > receiptRevisionAtStart else { return item }
                    return item.adoptingInteractions(from: receipt.item)
                },
                nextCursor: loaded.nextCursor,
                stories: loaded.stories,
                trendingHashtags: loaded.trendingHashtags,
                suggestedUsers: loaded.suggestedUsers,
                requestId: loaded.requestId
            )
            // Un GET démarré après le reçu peut désormais faire autorité.
            detailReceipts = detailReceipts.filter { $0.value.revision > receiptRevisionAtStart }
            trendingHashtags = loaded.trendingHashtags; metadataOwner = context.owner
            pendingCount = 0; pendingItems = []; pendingBaseline = nil; knownIds.removeAll()
            if context.tab.isChronological(for: context.sort) {
                // Page déjà lue en `latest` : elle sert de référence, sans autre requête.
                pendingBaseline = PendingBaseline(loaded.items)
            } else if streamFactory != nil {
                // Seulement quand le flux en direct tourne : sans lui, aucune pastille à régler.
                let loading = loadRevision
                baselineTask = Task { [weak self] in await self?.establishPendingBaseline(context: context, loading: loading) }
            }
            if needsLiveCheck, streamFactory != nil {
                needsLiveCheck = false
                let streamID = streamRevision
                Task { [weak self] in await self?.refreshPending(context: context, streamID: streamID) }
            }
            // Première page vide mais pas finie : la suite, plutôt qu'un fil vide.
            if loaded.items.isEmpty, let cursor = loaded.nextCursor, !cursor.isEmpty {
                isLoading = false
                await loadMore()
            }
        } catch {
            guard context == query, request == loadRevision, !error.isCancellation else { return }
            // Un rafraîchissement raté garde le fil affiché : seul un premier
            // chargement sans rien à montrer mérite l'écran d'erreur.
            if page == nil {
                errorMessage = error.userFacingMessage
            } else {
                actionError = error.userFacingMessage
            }
        }
    }

    /// Une page peut revenir vide avec une suite (posts cachés par le serveur, zones privées
    /// comprises) : rien n'apparaît alors pour demander la suivante, on l'enchaîne aussitôt,
    /// au plus quelques pages d'affilée.
    static let emptyPageHops = 5

    /// La page suivante se demande dès qu'une des quatre dernières cartes apparaît, plus à
    /// la toute dernière seulement : en défilant vite, on attendait la page en bas du fil
    /// (audit du 21/11, E5). `loadMore` ignore les demandes pendant un chargement.
    nonisolated static let loadMoreLead = 4
    /// Cartes suivantes dont la photo se charge pendant qu'on lit la carte affichée.
    nonisolated static let imagePrefetchLead = 3

    nonisolated static func shouldLoadMore(appearing id: String, in items: [UnifiedSocialFeedItem]) -> Bool {
        guard let index = items.lastIndex(where: { $0.id == id }) else { return false }
        return index >= items.count - loadMoreLead
    }

    nonisolated static func upcoming(after id: String, in items: [UnifiedSocialFeedItem]) -> ArraySlice<UnifiedSocialFeedItem> {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        return items[(index + 1)..<min(items.count, index + 1 + imagePrefetchLead)]
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let current = page,
              var cursor = current.nextCursor, !cursor.isEmpty, !AppEnvironment.usesDemoData else { return }
        let context = query, loading = loadRevision
        isLoadingMore = true
        loadMoreStalled = false
        defer { if context == query && loading == loadRevision { isLoadingMore = false } }
        do {
            for _ in 0..<Self.emptyPageHops {
                let next = try await service.loadFeedItems(cursor: cursor, hashtag: context.hashtag, tab: context.tab,
                                                           near: context.near, sort: context.sort)
                guard context == query, loading == loadRevision, !Task.isCancelled, let current = page else { return }
                var seen = Set(current.items.map(\.id))
                let deleting = deletions.pendingPostIds
                let appended = next.items.filter {
                    deferredDeletions[$0.id] == nil && !deleting.contains($0.id) && seen.insert($0.id).inserted
                }
                page = SocialFeedPage(items: current.items + appended, nextCursor: next.nextCursor,
                    stories: current.stories, trendingHashtags: current.trendingHashtags,
                    suggestedUsers: current.suggestedUsers, requestId: next.requestId ?? current.requestId)
                guard appended.isEmpty, let following = next.nextCursor, !following.isEmpty else { return }
                cursor = following
            }
            // Que des pages vides, et une suite encore annoncée : on s'arrête, sans le taire.
            loadMoreStalled = true
        } catch {
            guard context == query, loading == loadRevision, !error.isCancellation else { return }
            // La page déjà lue reste affichée ; le bas du fil offre de réessayer.
            loadMoreStalled = true
            actionError = error.userFacingMessage
        }
    }

    /// Bascules en cours, par publication et par geste (« post-1|react|❤️ ») : un second
    /// toucher pendant la requête ne part pas, sinon deux réponses se croisaient et la plus
    /// ancienne pouvait l'emporter (COM-03).
    private var interactionsInFlight: Set<String> = []

    func react(_ item: UnifiedSocialFeedItem, emoji: String = "❤️") {
        interact(item, key: "react|\(emoji)", toggle: { current in
            var copy = current
            // État propre à chaque emoji : `likedByMe` ne suit que le ❤️.
            let selected = !current.hasReacted(with: emoji)
            if emoji == "❤️" { copy.likedByMe = selected }
            copy.reactions = self.updatedReactions(current.reactions, emoji: emoji, selected: selected)
            return copy
        }, rollback: { current, previous in
            // Seuls les champs de ce geste reviennent : une autre action faite entre-temps reste.
            var copy = current
            copy.likedByMe = previous.likedByMe
            copy.reactions = previous.reactions
            return copy
        }, request: { [service] in try await service.react(postId: item.id, emoji: emoji) })
        Haptics.light()
    }

    func repost(_ item: UnifiedSocialFeedItem) {
        interact(item, key: "repost", toggle: { current in
            var copy = current
            copy.repostedByMe.toggle()
            copy.repostsCount = max(0, current.repostsCount + (copy.repostedByMe ? 1 : -1))
            return copy
        }, rollback: { current, previous in
            var copy = current
            copy.repostedByMe = previous.repostedByMe
            copy.repostsCount = previous.repostsCount
            return copy
        }, request: { [service] in try await service.repost(postId: item.id) })
        Haptics.medium()
    }

    func favorite(_ item: UnifiedSocialFeedItem) {
        interact(item, key: "favorite", toggle: { current in
            var copy = current
            copy.favoritedByMe.toggle()
            copy.favoritesCount = max(0, current.favoritesCount + (copy.favoritedByMe ? 1 : -1))
            return copy
        }, rollback: { current, previous in
            var copy = current
            copy.favoritedByMe = previous.favoritedByMe
            copy.favoritesCount = previous.favoritesCount
            return copy
        }, request: { [service] in try await service.favorite(postId: item.id) })
    }

    /// Bascule optimiste : l'état change tout de suite, la réponse du serveur fait foi, et un
    /// échec ne remet que les champs de ce geste.
    private func interact(
        _ item: UnifiedSocialFeedItem,
        key: String,
        toggle: @escaping @MainActor (UnifiedSocialFeedItem) -> UnifiedSocialFeedItem,
        rollback: @escaping @MainActor (UnifiedSocialFeedItem, UnifiedSocialFeedItem) -> UnifiedSocialFeedItem,
        request: @escaping @MainActor () async throws -> ReactionResponse
    ) {
        let flightKey = "\(item.id)|\(key)"
        guard interactionsInFlight.insert(flightKey).inserted else { return }
        let previous = currentItem(item)
        Task {
            await applyLocalToggle(itemId: item.id) { toggle($0) }
            defer { interactionsInFlight.remove(flightKey) }
            do {
                let response = try await request()
                await applyReactionResponse(itemId: item.id, response: response)
            } catch {
                await applyLocalToggle(itemId: item.id) { rollback($0, previous) }
                if !error.isCancellation {
                    Haptics.error()
                    actionError = error.userFacingMessage
                }
            }
        }
    }

    /// Épingle ou détache. Optimiste comme les autres bascules, avec une
    /// nuance : le serveur ne garde QU'UN post épinglé par auteur, donc épingler
    /// ici détache l'autre. On reflète cette exclusivité localement, sinon deux
    /// posts apparaîtraient épinglés jusqu'au prochain chargement.
    func togglePin(_ item: UnifiedSocialFeedItem) {
        let previous = item
        let willPin = !item.isPinned
        Task {
            await applyLocalToggle(itemId: item.id) { current in
                var copy = current
                copy.pinnedAt = willPin ? Date() : nil
                return copy
            }
            if willPin, let page {
                let others = page.items.filter { $0.id != item.id && $0.isPinned }
                for other in others {
                    await applyLocalToggle(itemId: other.id) { current in
                        var copy = current; copy.pinnedAt = nil; return copy
                    }
                }
            }
        }
        Task {
            do { try await service.setPinned(postId: item.id, pinned: willPin) }
            catch {
                await restore(previous)
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Visibilité seule (post automatique) : appliquée tout de suite, remise
    /// en place si le serveur refuse.
    func setVisibility(_ item: UnifiedSocialFeedItem, to visibility: SocialVisibility) {
        let previous = item
        Task {
            await applyLocalToggle(itemId: item.id) { var copy = $0; copy.visibility = visibility.rawValue; return copy }
            do { _ = try await service.setVisibility(postId: item.id, visibility: visibility.rawValue) }
            catch {
                await restore(previous)
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Lieu montré aux autres (`city` ou `none`) : appliqué tout de suite, remis si le serveur refuse.
    func setLocationPrecision(_ item: UnifiedSocialFeedItem, to precision: String) {
        let previous = item.locationPrecision
        Task {
            await applyLocalToggle(itemId: item.id) { var copy = $0; copy.locationPrecision = precision; return copy }
            do { try await service.setLocationPrecision(postId: item.id, precision: precision) }
            catch {
                await applyLocalToggle(itemId: item.id) { var copy = $0; copy.locationPrecision = previous; return copy }
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Suppressions en attente : la publication a quitté le fil tout de suite, le serveur
    /// ne la reçoit qu'au bout du délai d'annulation (plan Fil Communauté, C5, comme
    /// Android). Un rechargement pendant ce délai ne la fait pas revenir. Le délai lui-même
    /// est tenu par `PendingPostDeletions`, qui l'inscrit sur l'appareil : une app tuée
    /// pendant ces secondes envoie la suppression au lancement suivant (COM-01).
    private struct DeferredDeletion {
        let item: UnifiedSocialFeedItem
        /// Place dans la page ; nil pour une publication ouverte hors du fil (notification).
        let index: Int?
        let query: UUID
    }
    private var deferredDeletions: [String: DeferredDeletion] = [:]
    /// File partagée des suppressions ; remplaçable en test.
    var deletions = PendingPostDeletions.shared

    /// Retire la publication et programme sa suppression. Elle revient à sa place si
    /// l'auteur annule, ou si le serveur refuse.
    func deletePost(_ item: UnifiedSocialFeedItem, after delay: Duration = PendingPostDeletions.undoDelay) {
        guard deferredDeletions[item.id] == nil else { return }
        let index = page?.items.firstIndex { $0.id == item.id }
        removeItem(item.id)
        deferredDeletions[item.id] = DeferredDeletion(item: item, index: index, query: queryRevision)
        deletions.schedule(postId: item.id, after: delay, service: service) { [weak self] result in
            self?.deletionFinished(item.id, result)
        }
    }

    /// « Annuler » : rien n'est parti, la publication reprend sa place. Trop tard une
    /// fois la demande envoyée.
    func undoDeletion(_ id: String) {
        guard let pending = deferredDeletions[id], deletions.cancel(id) else { return }
        deferredDeletions[id] = nil
        // Onglet changé entre-temps : le prochain chargement la rendra, elle n'est pas supprimée.
        if pending.query == queryRevision, let index = pending.index { reinsert(pending.item, at: index) }
    }

    private func deletionFinished(_ id: String, _ result: Result<Void, Error>) {
        guard let pending = deferredDeletions.removeValue(forKey: id) else { return }
        guard case .failure(let error) = result else { return }
        if pending.query == queryRevision, let index = pending.index { reinsert(pending.item, at: index) }
        if !error.isCancellation { actionError = error.userFacingMessage }
    }

    /// Réinsère la seule publication retirée, à sa place : le reste du fil a pu
    /// changer entre-temps (réaction, rechargement).
    private func reinsert(_ item: UnifiedSocialFeedItem, at index: Int) {
        guard let current = page, !current.items.contains(where: { $0.id == item.id }) else { return }
        var items = current.items
        items.insert(item, at: min(index, items.count))
        page = SocialFeedPage(
            items: items, nextCursor: current.nextCursor, stories: current.stories,
            trendingHashtags: current.trendingHashtags, suggestedUsers: current.suggestedUsers,
            requestId: current.requestId
        )
    }

    /// Vote sur un sondage. Bascule si l'option était déjà choisie.
    ///
    /// Rien d'optimiste : le serveur applique ses propres règles (choix unique ou
    /// multiple, sondage clos, vote déjà émis ailleurs), et sa réponse remplace le
    /// sondage. Recalculer les pourcentages localement afficherait un résultat qui
    /// saute dès la réponse.
    func votePoll(_ item: UnifiedSocialFeedItem, option: FeedPoll.Option) {
        guard let poll = item.poll, poll.isOpen else { return }
        // Un vote à la fois par sondage : deux touchers rapides partaient calculés sur le même
        // état (COM-07).
        let flightKey = "\(item.id)|poll"
        guard interactionsInFlight.insert(flightKey).inserted else { return }
        let removing = option.votedByMe
        Task {
            defer { interactionsInFlight.remove(flightKey) }
            do {
                let updated = try await service.votePoll(
                    postId: item.id,
                    optionId: option.id,
                    removing: removing
                )
                guard let updated else { return }
                await applyLocalToggle(itemId: item.id) { current in
                    var copy = current; copy.poll = updated; return copy
                }
            } catch {
                if !error.isCancellation {
                    Haptics.error()
                    actionError = error.userFacingMessage
                }
            }
        }
    }

    func muteNotifications(_ item: UnifiedSocialFeedItem) {
        Task {
            do {
                _ = try await service.muteNotifications(postId: item.id)
                await applyLocalToggle(itemId: item.id) { current in
                    var copy = current
                    copy.notificationsMutedByMe = !(current.notificationsMutedByMe ?? false)
                    return copy
                }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Partage le post ; renvoie l'id du message créé (pour l'annulation), nil si échec.
    func share(_ item: UnifiedSocialFeedItem, to conversation: MessageConversation) async -> String? {
        do {
            let messageId = try await service.share(postId: item.id, conversationId: conversation.id)
            Haptics.success()
            return messageId
        } catch {
            // La feuille de partage affiche l'échec elle-même.
            Haptics.error()
            return nil
        }
    }

    /// Story qu'on vient de publier, montrée tout de suite en tête du rail
    /// (elle n'apparaissait qu'au rechargement suivant, SOC-34).
    func insertPublishedStory(_ story: SocialStory) {
        guard let page, !page.stories.contains(where: { $0.id == story.id }) else { return }
        self.page = SocialFeedPage(
            items: page.items, nextCursor: page.nextCursor, stories: [story] + page.stories,
            trendingHashtags: page.trendingHashtags, suggestedUsers: page.suggestedUsers,
            requestId: page.requestId
        )
    }

    func markStoryViewed(_ id: String) {
        viewedStoryIds.insert(id)
    }

    /// Membres bloqués pendant la session : leurs publications n'entrent plus par la pastille.
    private var removedAuthorIds: Set<String> = []

    /// Retire des publications et des stories d'un membre qu'on vient de bloquer, y compris
    /// celles qui attendaient derrière la pastille « N nouvelles » (COM-02).
    func removeAuthor(_ userId: String) {
        removedAuthorIds.insert(userId)
        dropPending { $0.author.id == userId }
        guard let page else { return }
        self.page = SocialFeedPage(
            items: page.items.filter { $0.author.id != userId },
            nextCursor: page.nextCursor,
            stories: page.stories.filter { $0.author.id != userId },
            trendingHashtags: page.trendingHashtags,
            suggestedUsers: page.suggestedUsers.filter { $0.id != userId },
            requestId: page.requestId
        )
    }

    /// Retire une publication supprimée depuis son détail, sans recharger le fil ; la pastille
    /// ne la rend pas non plus (COM-02).
    func removeItem(_ id: String) {
        dropPending { $0.id == id }
        guard let page else { return }
        self.page = SocialFeedPage(
            items: page.items.filter { $0.id != id },
            nextCursor: page.nextCursor,
            stories: page.stories,
            trendingHashtags: page.trendingHashtags,
            suggestedUsers: page.suggestedUsers,
            requestId: page.requestId
        )
    }

    /// Sourdine retirée : les publications du membre peuvent de nouveau entrer par la pastille.
    func restoreAuthor(_ userId: String) {
        removedAuthorIds.remove(userId)
    }

    /// Retire des publications en attente derrière la pastille, et la pastille avec elles.
    private func dropPending(where shouldDrop: (UnifiedSocialFeedItem) -> Bool) {
        guard pendingItems.contains(where: shouldDrop) else { return }
        pendingItems.removeAll(where: shouldDrop)
        pendingCount = pendingItems.count
    }

    func removeStory(_ id: String) {
        guard let page else { return }
        self.page = SocialFeedPage(
            items: page.items, nextCursor: page.nextCursor, stories: page.stories.filter { $0.id != id },
            trendingHashtags: page.trendingHashtags, suggestedUsers: page.suggestedUsers,
            requestId: page.requestId
        )
    }

    /// Version courante d'une publication du fil (à défaut, celle reçue).
    func currentItem(_ item: UnifiedSocialFeedItem) -> UnifiedSocialFeedItem {
        page?.items.first { $0.id == item.id } ?? item
    }

    /// Garde le fil cohérent avec le détail ouvert par notification/lien,
    /// même si son rechargement réseau au retour échoue.
    func acceptDetailItem(_ item: UnifiedSocialFeedItem) {
        detailReceiptRevision &+= 1
        detailReceipts[item.id] = DetailReceipt(revision: detailReceiptRevision, item: item)
        guard let current = page,
              current.items.contains(where: { $0.id == item.id }) else { return }
        page = SocialFeedPage(
            items: current.items.map { $0.id == item.id ? $0.adoptingInteractions(from: item) : $0 },
            nextCursor: current.nextCursor,
            stories: current.stories,
            trendingHashtags: current.trendingHashtags,
            suggestedUsers: current.suggestedUsers,
            requestId: current.requestId
        )
    }

    /// Un commentaire publié depuis la feuille compte aussitôt sur la carte.
    func commentPosted(on item: UnifiedSocialFeedItem) {
        Task { await applyLocalToggle(itemId: item.id) { var copy = $0; copy.commentsCount += 1; return copy } }
    }

    /// Un commentaire supprimé depuis la feuille se retire aussitôt du compteur de la carte.
    func commentDeleted(on item: UnifiedSocialFeedItem) {
        Task { await applyLocalToggle(itemId: item.id) { var copy = $0; copy.commentsCount = max(0, copy.commentsCount - 1); return copy } }
    }

    private func applyLocalToggle(itemId: String, _ transform: (UnifiedSocialFeedItem) -> UnifiedSocialFeedItem) async {
        guard var current = page else { return }
        let updated = current.items.map { $0.id == itemId ? transform($0) : $0 }
        current = SocialFeedPage(
            items: updated,
            nextCursor: current.nextCursor,
            stories: current.stories,
            trendingHashtags: current.trendingHashtags,
            suggestedUsers: current.suggestedUsers,
            requestId: current.requestId
        )
        page = current
    }

    private func applyReactionResponse(itemId: String, response: ReactionResponse) async {
        await applyLocalToggle(itemId: itemId) { current in
            var copy = current
            if let reactions = response.reactions {
                copy.reactions = reactions
                // Le backend ne renvoie pas `likedByMe` : on le dérive du ❤️.
                copy.likedByMe = reactions.first(where: { $0.emoji == "❤️" })?.reactedByMe ?? false
            }
            if let favorited = response.favorited { copy.favoritedByMe = favorited }
            if let favoritesCount = response.favoritesCount { copy.favoritesCount = favoritesCount }
            if let reposted = response.reposted { copy.repostedByMe = reposted }
            if let repostsCount = response.repostsCount { copy.repostsCount = repostsCount }
            return copy
        }
    }

    private func restore(_ item: UnifiedSocialFeedItem) async {
        guard var current = page else { return }
        current = SocialFeedPage(
            items: current.items.map { $0.id == item.id ? item : $0 },
            nextCursor: current.nextCursor,
            stories: current.stories,
            trendingHashtags: current.trendingHashtags,
            suggestedUsers: current.suggestedUsers,
            requestId: current.requestId
        )
        page = current
    }

    private func updatedReactions(_ reactions: [SocialReactionSummary], emoji: String, selected: Bool) -> [SocialReactionSummary] {
        var result = reactions
        if let index = result.firstIndex(where: { $0.emoji == emoji }) {
            let count = max(0, result[index].count + (selected ? 1 : -1))
            result[index] = SocialReactionSummary(emoji: emoji, count: count, reactedByMe: selected)
        } else if selected {
            result.append(SocialReactionSummary(emoji: emoji, count: 1, reactedByMe: true))
        }
        return result
    }
}

struct FeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFeedVisible = false
    @StateObject private var model: FeedViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private static let topAnchor = "feed.top"

    @State private var presentedSheet: FeedSheet?
    /// Post en attente de confirmation de suppression. La suppression est
    /// IRRÉVERSIBLE côté serveur : elle ne peut pas partir en deux taps depuis
    /// un menu contextuel.
    @State private var showRecap = false
    /// Post en cours d'édition — ouvre le composer en mode édition.
    @State private var editingPost: UnifiedSocialFeedItem?
    /// Membre à bloquer depuis le ⋯ d'une de ses publications, en attente de l'alerte.
    @State private var blockingAuthor: SocialFeedAuthor?
    @State private var presentedStoryStart: Int?
    /// Auteurs dont les stories sont masquées sur cet appareil.
    @State private var hiddenStoryAuthorIds = HiddenStoryAuthorsStore.hiddenIds()
    @State private var showStoryComposer = false
    /// Composer ouvert, avec la pièce jointe choisie depuis la ligne « Quoi de
    /// neuf ? ». Porté par la présentation : lu dans une feuille `isPresented`,
    /// l'état voisin arrivait encore à son ancienne valeur.
    @State private var composerRequest: ComposerRequest?
    @State private var showsZonePicker = false
    /// Page de choix de l'audience par défaut (PRIVACY-DPV v1, §6).
    @State private var showsDefaultVisibilityChoice = false
    /// Remonte en tête du fil (filtre par hashtag touché plus bas).
    @State private var scrollTopRequest = UUID()
    /// Actualisation lancée en retouchant l'onglet Communauté : sans le geste de
    /// tirer, rien d'autre ne montrerait que le fil se recharge.
    @State private var isTabRefreshing = false
    @State private var showExplore = false
    @State private var showMessages = false
    // Destinations reprises du menu Profil : elles relèvent de la communauté,
    // c'est ici qu'on les cherche.
    @State private var showFriends = false
    @State private var showNotifications = false
    @State private var showCalls = false
    @State private var showFeedPreferences = false
    @State private var isPulseExpanded = false
    /// Auteur dont on pousse le profil public (cards, commentaires, stories…).
    @State private var profileAuthor: SocialFeedAuthor?
    /// Profil demandé par notification (follow) via AppRouter — par id seul.
    @State private var routedProfileId: String?
    /// Post ouvert via deep-link / notification (résolu en item complet).
    @State private var routedPostItem: RoutedPost?
    @State private var failedRoutedPostID: String?
    /// Lien vers une publication supprimée ou inexistante : rien à réessayer.
    @State private var routedPostMissing = false
    @State private var routedPostRevision = UUID()
    /// Feuille ouverte par-dessus le détail (commentaires, signalement, partage).
    @State private var detailOverlay: FeedSheet?
    private enum FeedSheet: Identifiable {
        case detail(UnifiedSocialFeedItem)
        case comments(UnifiedSocialFeedItem)
        case report(UnifiedSocialFeedItem)
        case share(UnifiedSocialFeedItem)
        var id: String {
            switch self {
            case .detail(let i): return "detail-\(i.id)"
            case .comments(let i): return "comments-\(i.id)"
            case .report(let i): return "report-\(i.id)"
            case .share(let i): return "share-\(i.id)"
            }
        }
    }

    /// Commentaires, signalement et partage : ouverts depuis le fil à la place
    /// de toute autre feuille, ou depuis le détail par-dessus lui.
    @ViewBuilder
    private func overlaySheet(_ sheet: FeedSheet) -> some View {
        switch sheet {
        case .comments(let item):
            CommentsSheet(
                service: services.comments,
                postId: item.backendPostId,
                profileService: services.feed,
                reports: services.reports,
                commentsCount: item.commentsCount,
                onCommentPosted: {
                    recordSignal("comment", for: item)
                    model.commentPosted(on: item)
                },
                onCommentDeleted: { model.commentDeleted(on: item) }
            )
        case .report(let item):
            ReportSheet(post: item, service: services.reports)
        case .share(let item):
            PostShareSheet(
                post: item,
                messagesService: services.messages,
                onShare: { conversation in
                    await model.share(item, to: conversation)
                },
                onShared: { messageId, conversation in
                    recordSignal("share", for: item)
                    presentShareUndo(messageId: messageId, conversation: conversation)
                }
            )
        case .detail:
            EmptyView()
        }
    }

    /// Enveloppe `Hashable` d'un post pour `navigationDestination(item:)`
    /// (deep-link), identifiée par l'id du post.
    /// Une vignette de la galerie : la publication, et l'image qui la représente.
    private struct GalleryTile: Identifiable {
        let item: UnifiedSocialFeedItem
        let url: URL
        var id: String { item.id }
    }

    private struct ComposerRequest: Identifiable {
        let id = UUID()
        let start: ComposerStartAttachment?
        var shared: ComposerSharedContent? = nil
    }

    private struct RoutedPost: Identifiable, Hashable {
        let item: UnifiedSocialFeedItem
        var id: String { item.id }
        static func == (lhs: RoutedPost, rhs: RoutedPost) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    init(service: SocialFeedServicing, location: LocationService? = nil) {
        _model = StateObject(wrappedValue: FeedViewModel(service: service, location: location))
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Onglets épinglés par la Section (pinnedViews) : l'en-tête et les stories partent au
            // défilement sans qu'aucun état ne suive l'offset image par image (IOS-062).
            LazyVStack(alignment: .leading, spacing: SQSpace.md, pinnedViews: [.sectionHeaders]) {
                // La marge du haut appartient à l'ancre : revenir en tête
                // retrouve la position de repos, pas 8 pt plus haut.
                header
                    .padding(.top, SQSpace.sm)
                    .id(Self.topAnchor)
                if isTabRefreshing {
                    HStack { Spacer(); SQSpinner().tint(SQColor.brandRed); Spacer() }
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                // Rail visible dès que la page est chargée, même sans story
                // amie : « Ta story » reste le point d'entrée de création.
                if let stories = visibleStories {
                    StoriesBar(
                        stories: stories,
                        currentUser: currentUser,
                        onCompose: { showStoryComposer = true },
                        onSelect: { story in
                            if let idx = stories.firstIndex(where: { $0.id == story.id }) {
                                presentedStoryStart = idx
                            }
                        },
                        onHide: { hideStories(of: $0) },
                        viewedIds: model.viewedStoryIds
                    )
                    // Rail débordant : annule le padding écran pour que le
                    // scroll fuie sous les bords (1re bulle alignée à 20 pt).
                    .padding(.horizontal, -SQSpace.lg)
                }
                Section {
                if let tag = model.selectedHashtag { hashtagFilter(tag) }
                if model.tab == .nearby, model.selectedHashtag == nil, model.nearbyPosition == .ready {
                    nearbyZoneBar
                }

                if model.page == nil && model.errorMessage == nil {
                    // Photos se charge en grille : son squelette aussi (recette de l'audit, 24/11).
                    if model.tab.rendersAsGallery {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.xs), count: 3),
                                  spacing: SQSpace.xs) {
                            ForEach(0..<12, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                    .fill(SQColor.surfaceMuted)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .sqShimmer()
                        .accessibilityHidden(true)
                    } else {
                        LoadingSkeleton()
                            .sqShimmer()
                    }
                } else {
                    // Le pouls décrit la zone, pas un filtre : il n'ouvre que
                    // « Pour toi ».
                    if let pulse = model.pulse, model.tab == .forYou, model.selectedHashtag == nil {
                        pulseCard(pulse)
                    }
                    if let error = model.errorMessage {
                        ErrorStateView(title: "Fil indisponible", message: error) {
                            // Le pouls a échoué avec le fil : il revient avec lui.
                            Task { await model.load(); await model.loadPulse() }
                        }
                    }
                    if model.tab.needsPosition, model.nearbyPosition != .ready, !model.isLoading,
                       model.selectedHashtag == nil {
                        nearbyPositionState
                    } else if (model.page?.items.isEmpty ?? true), !model.isLoading, model.errorMessage == nil {
                        // État vide explicite : sans lui, un nouveau compte (onglet par
                        // défaut) voit un écran quasi nu, l'app paraît cassée (INT-01).
                        // Titres et gestes communs au Web et à Android (plan Fil
                        // Communauté du 24/11, C4).
                        emptyFeedState
                    }
                    if model.tab.rendersAsGallery {
                        photoGallery(model.page?.items ?? [])
                    } else {
                        let items = model.page?.items ?? []
                        let chronological = model.isChronological
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            // Fil chronologique : un séparateur à chaque nouveau jour (C8).
                            if chronological, let title = FeedDaySeparator.title(for: item, after: index > 0 ? items[index - 1] : nil) {
                                FeedDaySeparator(title: title)
                            }
                            feedCard(for: item)
                                .environment(\.feedCardExactTime, chronological)
                        }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); SQSpinner().tint(SQColor.brandRed); Spacer() }
                            .padding(.vertical, SQSpace.md)
                            .frame(maxWidth: .infinity)
                    } else if model.loadMoreStalled {
                        GradientButton("Charger plus de publications", systemImage: "arrow.clockwise", style: .secondary) {
                            Task { await model.loadMore() }
                        }
                        .padding(.vertical, SQSpace.md)
                        .accessibilityIdentifier("feed.loadMore.retry")
                    }
                }
                } header: {
                    feedTabs
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        // Les nouveautés flottent au-dessus de la lecture : les insérer dans la
        // liste déplacerait ce que l'on regarde.
        .overlay(alignment: .top) {
            if model.pendingCount > 0 {
                newPostsPill {
                    withAnimation(SQMotion.resolve(SQMotion.smooth, reduceMotion)) {
                        proxy.scrollTo(Self.topAnchor, anchor: .top)
                    }
                }
                // Sous les onglets épinglés : la pastille ne les recouvre jamais.
                .padding(.top, SQSpace.sm + 48)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Publier, depuis n'importe où dans le fil (Fil Communauté, haut du fil du 25/11).
        .overlay(alignment: .bottomTrailing) {
            if !model.emptyStateOffersPublish { composeButton }
        }
        .sqAnimation(SQMotion.snappy, value: model.pendingCount > 0)
        // Pastille annoncée sans déplacer le focus de VoiceOver (C7).
        .onChangeCompat(of: model.pendingCount) { old, new in
            guard new > old, UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: String(localized: "\(new) nouvelle publication"))
        }
        .onChangeCompat(of: scrollTopRequest) { _, _ in
            proxy.scrollTo(Self.topAnchor, anchor: .top)
        }
        // Onglet Communauté retouché : retour en tête, puis la même
        // actualisation que le geste de tirer.
        .onChangeCompat(of: router.tabReselection) { _, reselection in
            guard reselection?.tab == .community else { return }
            withAnimation(SQMotion.resolve(SQMotion.smooth, reduceMotion)) {
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
            guard !model.isLoading, !isTabRefreshing else { return }
            Task {
                isTabRefreshing = true
                await refreshFeed()
                isTabRefreshing = false
            }
        }
        .sqAnimation(SQMotion.snappy, value: isTabRefreshing)
        }
        // Directement sur le ScrollView (avant le ZStack de signalQuestBackground).
        .sqDockAutoMinimize()
        // Header custom (DA Crème) : plus de gros titre nav système.
        .toolbar(.hidden, for: .navigationBar)
        // Destinations du menu `⋯`. En navigation (et non en feuille) : ce sont
        // des écrans à part entière, avec leur propre profondeur, exactement
        // comme quand ils vivaient dans le menu du Profil.
        .navigationDestination(isPresented: $showFriends) {
            FriendsListView(service: services.friends)
        }
        .navigationDestination(isPresented: $showNotifications) {
            NotificationsCenterView(service: services.notifications, badge: services)
        }
        .navigationDestination(isPresented: $showCalls) {
            CallHistoryView(service: services.calls)
        }
        .navigationDestination(isPresented: $showFeedPreferences) {
            FeedPreferencesView(service: services.feed) {
                Task { await model.load() }
            }
        }
        .signalQuestBackground()
        // Sous la barre d'état, un fond opaque : le contenu défile jusque-là, et l'en-tête parti
        // transparaissait au-dessus des onglets épinglés. Encart de hauteur nulle posé sur la zone
        // sûre, dont le fond s'étend à la barre d'état : aucune mesure au défilement.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(SQColor.bg)
                .accessibilityHidden(true)
        }
        .task {
            isFeedVisible = true
            // Le dernier onglet ouvert, relu avant le premier chargement : changer d'onglet
            // marque le fil « en chargement » sans rien demander, d'où `restored`.
            let restored = model.page == nil && model.restoreLastTab()
            model.restoreFeedSort()
            model.startStream(services.sse)
            // Au lancement à froid, le passage à l'état actif arrive pendant ce
            // premier chargement : sans `isLoading`, le fil partait deux fois (F-44).
            if model.page == nil, restored || !model.isLoading { await model.load() }
            guard !Task.isCancelled, isFeedVisible else { return }
            await model.refreshFeedSort()
            await model.loadPulse()
            await consumeFeedRoutesIfNeeded()
            presentMessagesIfNeeded()
            await askDefaultPostVisibilityIfNeeded()
        }
        .onDisappear { isFeedVisible = false; model.stopStream() }
        .onChangeCompat(of: scenePhase) { _, phase in
            guard isFeedVisible else { return }
            if phase == .active {
                model.startStream(services.sse)
                if model.page == nil, !model.isLoading { Task { await model.load() } }
            } else { model.stopStream() }
        }
        .refreshable { await refreshFeed() }
        .navigationDestination(isPresented: $showExplore) {
            ExploreView(service: services.feed)
        }
        .navigationDestination(isPresented: $showMessages) {
            MessagesView(service: services.messages, e2ee: services.e2ee)
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(
                userId: author.id,
                prefill: author,
                hasActiveStory: (visibleStories?.contains(where: { $0.author.id == author.id })) ?? false,
                service: services.feed
            )
        }
        .navigationDestinationItemCompat($routedProfileId) { id in
            UserProfileView(userId: id, service: services.feed)
        }
        .navigationDestinationItemCompat($routedPostItem) { routed in
            PostDetailView(
                item: routed.item,
                feedService: services.feed,
                messagesService: services.messages,
                commentsService: services.comments,
                reportsService: services.reports,
                onItemChanged: { model.acceptDetailItem($0) },
                onDeleted: { model.removeItem($0) },
                onDelete: { deleteWithUndo($0) }
            )
        }
        // Publication supprimée, ouverte depuis une notification : un état, pas une
        // erreur (plan Fil Communauté, C6).
        .navigationDestination(isPresented: $routedPostMissing) {
            DeletedPostView()
        }
        .alert("Publication", isPresented: Binding(
            get: { failedRoutedPostID != nil },
            set: { if !$0 { failedRoutedPostID = nil } }
        )) {
            if let retryID = failedRoutedPostID {
                Button("Réessayer") {
                    Task { await openRoutedPost(retryID) }
                }
            }
            Button("Fermer", role: .cancel) { failedRoutedPostID = nil }
        } message: {
            Text("Une erreur est survenue. Réessaie.")
        }
        // Échec d'une action : bandeau passager, ou message dans la fiche
        // ouverte, qui masquerait le bandeau (SOC-14).
        .onChangeCompat(of: model.actionError) { _, message in
            guard let message, !isCoveredByModal else { return }
            inAppNotifications.showError(message)
            model.actionError = nil
        }
        // Une erreur arrivée sous une feuille (composer, story, récap…) s'affiche
        // à sa fermeture plutôt que derrière elle.
        .onChangeCompat(of: isCoveredByModal) { _, covered in
            guard !covered, let message = model.actionError else { return }
            inAppNotifications.showError(message)
            model.actionError = nil
        }
        // Membre bloqué depuis son profil ou une conversation : ses publications
        // et ses stories quittent le fil tout de suite.
        .onReceive(NotificationCenter.default.publisher(for: .sqMemberBlocked)) { note in
            if let userId = note.userInfo?["userId"] as? String { model.removeAuthor(userId) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sqMemberMuted)) { note in
            if let userId = note.userInfo?["userId"] as? String { model.removeAuthor(userId) }
        }
        .blockAuthorAlert($blockingAuthor, friends: services.friends, notifications: inAppNotifications)
        .onChangeCompat(of: router.openUserProfileId) { _, _ in
            Task { await consumeFeedRoutesIfNeeded() }
        }
        .onChangeCompat(of: router.openPostId) { _, _ in
            Task { await consumeFeedRoutesIfNeeded() }
        }
        .onChangeCompat(of: router.openFriendRequests) { _, _ in
            Task { await consumeFeedRoutesIfNeeded() }
        }
        .onChangeCompat(of: router.openConversationId) { _, conversationId in
            if conversationId != nil { showMessages = true }
        }
        .onChangeCompat(of: router.openMessagesInbox) { _, shouldOpen in
            if shouldOpen { presentMessagesIfNeeded() }
        }
        // ⌘⇧N sur iPad : sans attendre le chargement du fil.
        .onAppear { openComposerIfRequested() }
        .onChangeCompat(of: router.openPostComposer) { _, requested in
            if requested { openComposerIfRequested() }
        }
        // Contenu reçu de « Partager vers SignalQuest » : le composer s'ouvre prérempli.
        .onChangeCompat(of: router.pendingSharedPost?.id) { _, id in
            if id != nil { openComposerIfRequested() }
        }
        .sheet(item: $editingPost) { post in
            // Même composer qu'à la création : deux écrans divergeraient
            // dès la première évolution de la saisie.
            ComposerSheet(service: services.feed, editing: post, onPublished: { Task { await model.load() } })
        }
        .sheet(isPresented: $showRecap) {
            WeeklyRecapSheet(service: services.feed, onPublished: { Task { await model.load() } })
        }
        .sheet(item: $presentedSheet, onDismiss: {
            // Une erreur survenue pendant que la feuille était ouverte n'a pas pu
            // s'afficher en bandeau : on la montre à la fermeture plutôt que de l'effacer.
            if let message = model.actionError {
                inAppNotifications.showError(message)
                model.actionError = nil
            }
        }) { sheet in
            switch sheet {
            case .detail(let opened):
                // L'élément courant du fil, pas la copie prise à l'ouverture : sans
                // cela, un like donné dans la feuille n'y apparaissait pas (SOC-17).
                let item = model.currentItem(opened)
                SignalDetailSheet(
                    item: item,
                    onLike: {
                        if !item.likedByMe { recordSignal("like", for: item) }
                        model.react(item)
                    },
                    onRepost: {
                        if !item.repostedByMe { recordSignal("repost", for: item) }
                        repostWithUndo(item)
                    },
                    onFavorite: {
                        if !item.favoritedByMe { recordSignal("favorite", for: item) }
                        model.favorite(item)
                    },
                    // Par-dessus le détail, pas à sa place : fermer les commentaires
                    // ramène au détail au lieu du fil (F-29).
                    onComment: { detailOverlay = .comments(item) },
                    onShare: { detailOverlay = .share(item) },
                    onMute: { model.muteNotifications(item) },
                    onReport: { detailOverlay = .report(item) },
                    onPollVote: { option in model.votePoll(item, option: option) },
                    onAuthorTap: {
                        presentedSheet = nil
                        pushProfileAfterDismiss(item.author)
                    },
                    // Mêmes actions d'auteur que le ⋯ de la carte (signalement du 25/11).
                    onEdit: {
                        presentedSheet = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 380_000_000)
                            editingPost = item
                        }
                    },
                    onSetVisibility: { model.setVisibility(item, to: $0) },
                    onSetLocation: { setLocation(item, to: $0) },
                    onTogglePin: { model.togglePin(item) },
                    onDelete: {
                        presentedSheet = nil
                        deleteWithUndo(item)
                    },
                    onMuteAuthor: {
                        presentedSheet = nil
                        muteAuthor(item.author)
                    },
                    onBlockAuthor: {
                        presentedSheet = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 380_000_000)
                            blockingAuthor = item.author
                        }
                    },
                    actionError: model.actionError
                )
                .sheet(item: $detailOverlay) { overlaySheet($0) }
            case .comments, .report, .share:
                overlaySheet(sheet)
            }
        }
        .fullScreenCover(item: Binding(
            // Identité stable : un `UUID()` neuf à chaque lecture faisait fermer et
            // rouvrir le lecteur à chaque recalcul du fil (AF-FIL-13).
            get: { presentedStoryStart.map { StoriesPresentation(id: $0) } },
            set: { if $0 == nil { presentedStoryStart = nil } }
        )) { _ in
            if let stories = visibleStories, !stories.isEmpty, let start = presentedStoryStart {
                StoryViewer(stories: Array(stories[min(start, stories.count - 1)...]),
                            onMarkViewed: { story in
                                model.markStoryViewed(story.id)
                                Task { try? await services.stories.markViewed(story.id) }
                            },
                            onAuthorTap: { story in
                                presentedStoryStart = nil
                                pushProfileAfterDismiss(story.author)
                            },
                            onSendReply: { story, text, requestID in
                                try await sendStoryReply(story, text: text, requestID: requestID)
                            },
                            onDelete: { story in
                                Task {
                                    // L'échec était avalé : la story restait
                                    // sans rien dire (SOC-34).
                                    do {
                                        try await services.stories.delete(story.id)
                                        model.removeStory(story.id)
                                    } catch {
                                        if !error.isCancellation { model.actionError = error.userFacingMessage }
                                    }
                                }
                            },
                            viewersProvider: { story in
                                try await services.stories.viewers(storyId: story.id)
                            },
                            reports: services.reports,
                            onHideAuthor: { hideStories(of: $0) })
            }
        }
        // Plein écran : la story se compose telle qu'elle sera vue (refonte du 02/11).
        .fullScreenCover(isPresented: $showStoryComposer) {
            StoryComposer(service: services.stories, friendsService: services.friends, author: currentUser) { story in
                model.insertPublishedStory(story)
            }
        }
        .sheet(isPresented: $showsZonePicker) {
            NearbyZonePicker { name, coordinate in
                Task { await model.chooseNearbyZone(name: name, coordinate: coordinate) }
            }
        }
        .sheet(item: $composerRequest) { request in
            ComposerSheet(service: services.feed, userService: services.users, startingWith: request.start, sharing: request.shared,
                          trendingHashtags: model.trendingHashtags.map(\.tag),
                          onPublished: { Task { await model.load() } })
        }
        .sheet(isPresented: $isPulseExpanded) { pulseSheet }
        .sheet(isPresented: $showsDefaultVisibilityChoice) {
            DefaultPostVisibilitySheet(mode: .firstChoice)
        }
        .onReceive(NotificationCenter.default.publisher(for: HiddenStoryAuthorsStore.didChange)) { _ in
            hiddenStoryAuthorIds = HiddenStoryAuthorsStore.hiddenIds()
        }
    }

    /// Une feuille ou un plein écran couvre le fil : un bandeau d'erreur y serait invisible.
    private var isCoveredByModal: Bool {
        presentedSheet != nil || composerRequest != nil || editingPost != nil || showStoryComposer
            || presentedStoryStart != nil || showRecap || isPulseExpanded
    }

    /// Compte connecté, pour l'initiale de la bulle « Ta story ».
    private var currentUser: AuthUser? {
        if case .authenticated(let user) = session.state { return user }
        return nil
    }

    /// Stories du fil, sans celles des membres masqués sur cet appareil.
    private var visibleStories: [SocialStory]? {
        model.page?.stories.filter { !hiddenStoryAuthorIds.contains($0.author.id) }
    }

    /// Masque les stories d'un membre, sans le bloquer ni toucher à ses
    /// publications. Réversible tout de suite, puis depuis les Préférences du fil.
    private func hideStories(of story: SocialStory) {
        let author = story.author
        HiddenStoryAuthorsStore.hide(authorId: author.id, displayName: author.displayName)
        // Sans compte local (démo), le magasin refuse : le masquage vaut alors
        // pour la session seulement.
        hiddenStoryAuthorIds.insert(author.id)
        presentedStoryStart = nil
        Haptics.light()
        inAppNotifications.showUndo(
            body: SQElision.apply(String(localized: "Tu ne verras plus les stories de \(author.displayName)."), name: author.displayName),
            actionLabel: String(localized: "Annuler")
        ) {
            HiddenStoryAuthorsStore.unhide(authorId: author.id)
            hiddenStoryAuthorIds.remove(author.id)
        }
    }

    // MARK: Lieu affiché

    private func setLocation(_ item: UnifiedSocialFeedItem, to precision: String) {
        model.setLocationPrecision(item, to: precision)
        PostLocationPicker.announce(item, precision: precision, in: inAppNotifications)
    }

    // MARK: Sourdine d'un membre

    /// Sourdine depuis le ⋯ : ses publications partent du fil ; « Annuler » la retire et relit.
    private func muteAuthor(_ author: SocialFeedAuthor) {
        AuthorModeration.mute(author, friends: services.friends, notifications: inAppNotifications) {
            model.restoreAuthor(author.id)
            Task { await model.load() }
        }
    }

    // MARK: Repartage annulable

    /// Repartager est public : un bandeau le confirme et offre de l'annuler, au lieu d'un seul
    /// changement de teinte de l'icône (COM-06). Retirer son repartage n'en demande pas.
    private func repostWithUndo(_ item: UnifiedSocialFeedItem) {
        let reposting = !model.currentItem(item).repostedByMe
        model.repost(item)
        guard reposting else { return }
        inAppNotifications.showUndo(
            body: String(localized: "Publication repartagée"),
            actionLabel: String(localized: "Annuler")
        ) {
            let current = model.currentItem(item)
            if current.repostedByMe { model.repost(current) }
        }
    }

    // MARK: Suppression annulable

    private func deleteWithUndo(_ item: UnifiedSocialFeedItem) {
        Haptics.light()
        // Le bandeau dure exactement le délai : « Annuler » reste offert tant que rien n'est parti.
        let delay = PendingPostDeletions.undoDelay
        model.deletePost(item, after: delay)
        inAppNotifications.showUndo(
            body: String(localized: "Publication supprimée"),
            actionLabel: String(localized: "Annuler"),
            duration: delay
        ) {
            model.undoDeletion(item.id)
        }
    }

    // MARK: Annulation d'un partage

    private func presentShareUndo(messageId: String, conversation: MessageConversation) {
        let title = conversation.displayTitle.isEmpty ? String(localized: "la conversation") : conversation.displayTitle
        inAppNotifications.showUndo(
            body: String(localized: "Partagé vers \(title)"),
            actionLabel: String(localized: "Annuler")
        ) {
            undoShare(messageId: messageId)
        }
    }

    private func undoShare(messageId: String) {
        Task {
            do {
                try await services.messages.deleteMessage(messageId: messageId, forEveryone: true)
                await MainActor.run { Haptics.success() }
            } catch {
                await MainActor.run {
                    inAppNotifications.showError(String(localized: "Impossible d’annuler le partage. Réessaie."))
                }
            }
        }
    }

    /// Consomme les routes de notification Feed (profil/post) — appelé au montage
    /// (.task) ET sur changement du routeur, pour ne pas perdre une route au lancement
    /// à froid (NAV-BUG-01).
    private func consumeFeedRoutesIfNeeded() async {
        if router.openFriendRequests {
            router.openFriendRequests = false
            showFriends = true
        }
        if let id = router.openUserProfileId {
            router.openUserProfileId = nil
            if routedProfileId != nil, await popRoutedDestination({ routedProfileId = nil }) == false { return }
            routedProfileId = id
        }
        if let id = router.openPostId {
            router.openPostId = nil
            await openRoutedPost(id)
        }
    }

    /// Résout le post demandé depuis le serveur pour afficher des compteurs à
    /// jour. En panne réseau, une carte déjà chargée permet encore d'ouvrir le
    /// détail ; sans carte, l'intention reste réessayable au lieu de disparaître.
    private func openRoutedPost(_ id: String) async {
        let revision = UUID()
        routedPostRevision = revision
        failedRoutedPostID = nil
        if routedPostMissing {
            guard await popRoutedDestination({ routedPostMissing = false }), routedPostRevision == revision else { return }
        }
        if routedPostItem != nil {
            guard await popRoutedDestination({ routedPostItem = nil }), routedPostRevision == revision else { return }
        }
        if AppEnvironment.usesDemoData,
           let existing = model.page?.items.first(where: { $0.id == id || $0.backendPostId == id }) {
            routedPostItem = RoutedPost(item: existing)
            return
        }
        do {
            let fetched = try await services.feed.post(id: id)
            guard routedPostRevision == revision, !Task.isCancelled else { return }
            if let fetched {
                routedPostItem = RoutedPost(item: fetched)
            } else {
                routedPostMissing = true
            }
        } catch {
            guard routedPostRevision == revision, !error.isCancellation else { return }
            if case .http(let status, _, _, _, _)? = error as? APIError, status == 404 || status == 410 {
                routedPostMissing = true
            } else if let existing = model.page?.items.first(where: { $0.id == id || $0.backendPostId == id }) {
                routedPostItem = RoutedPost(item: existing)
            } else {
                failedRoutedPostID = id
            }
        }
    }

    /// IOS-019 : une destination routée déjà affichée peut porter d'autres écrans
    /// (profil de l'auteur, commentaires). La remplacer sur place (SOC-11)
    /// poserait la nouvelle cible SOUS ces écrans : on revient d'abord à la
    /// racine, le temps de l'animation de retour. `false` si la tâche est annulée.
    private func popRoutedDestination(_ pop: () -> Void) async -> Bool {
        pop()
        try? await Task.sleep(for: .milliseconds(450))
        return !Task.isCancelled
    }

    private func openComposerIfRequested() {
        if let shared = router.pendingSharedPost {
            router.pendingSharedPost = nil
            composerRequest = ComposerRequest(start: nil, shared: shared)
            return
        }
        guard router.openPostComposer else { return }
        router.openPostComposer = false
        composerRequest = ComposerRequest(start: nil)
    }

    /// PRIVACY-DPV v1, §6 : un GET frais par lancement, jamais le cache ; la page
    /// ne s'ouvre que si le serveur dit « à demander », jamais avec un ancien
    /// serveur (champ absent). Une autre feuille ouverte la remet à plus tard.
    private func askDefaultPostVisibilityIfNeeded() async {
        guard !AppEnvironment.usesDemoData, let owner = LocalAccountScope.sessionSnapshot(),
              services.defaultPostVisibility.needsLaunchCheck(owner: owner.ownerScopeId),
              let settings = try? await services.privacy.scoped(to: owner).get(),
              LocalAccountScope.sessionSnapshot() == owner, isFeedVisible else { return }
        guard settings.defaultPostVisibilityPending == true else {
            services.defaultPostVisibility.markLaunchChecked(owner: owner.ownerScopeId)
            return
        }
        guard presentedSheet == nil, composerRequest == nil, editingPost == nil, !showRecap,
              !showStoryComposer, presentedStoryStart == nil, !isPulseExpanded else { return }
        services.defaultPostVisibility.markLaunchChecked(owner: owner.ownerScopeId)
        showsDefaultVisibilityChoice = true
    }

    private func presentMessagesIfNeeded() {
        guard router.openMessagesInbox || router.openConversationId != nil else { return }
        router.openMessagesInbox = false
        showMessages = true
    }

    /// Pousse le profil après la fermeture d'un sheet / fullScreenCover :
    /// un push immédiat pendant l'animation de dismiss serait avalé.
    private func pushProfileAfterDismiss(_ author: SocialFeedAuthor) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            profileAuthor = author
        }
    }

    /// Répondre / réagir à une story = message privé à l'auteur (façon Instagram),
    /// chiffré de bout en bout dans le tête-à-tête avec lui, créé s'il n'existe pas.
    /// Depuis la bascule du 08/11, le serveur ne crée plus de conversation en
    /// clair et refuse d'y écrire (E2EE-AUTO §7.2) : un ancien tête-à-tête en
    /// clair ou v1 passe d'abord au chiffrement automatique, sans qu'aucun texte
    /// en clair ne parte. Le même identifiant de requête à chaque réessai : le
    /// serveur ne garde qu'un message. Le viewer ne confirme qu'après le reçu.
    private func sendStoryReply(_ story: SocialStory, text: String, requestID: String) async throws {
        guard !AppEnvironment.usesDemoData else { throw StoryReplyDeliveryError.unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoryReplyDeliveryError.unavailable }
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent,
              let currentUserID = LocalAccountScope.currentUserId else {
            throw CancellationError()
        }
        let messaging = services.e2eeV2Messaging
        guard story.author.id != currentUserID, messaging.writesEnabled, !messaging.lacksV2Readiness(session) else {
            throw StoryReplyDeliveryError.unavailable
        }
        let conversationId = try await storyReplyConversationId(authorID: story.author.id, currentUserID: currentUserID)
        guard session.isCurrent else { throw CancellationError() }
        var conversation = try await services.messages.conversation(id: conversationId)
        guard session.isCurrent else { throw CancellationError() }
        guard StoryReplyChannelPolicy.accepts(conversation, authorID: story.author.id, currentUserID: currentUserID) else {
            throw StoryReplyDeliveryError.conversationUnavailable
        }
        if !EncryptedConversationSurfaces.isV2(conversation) {
            guard await messaging.migrateIfReady(conversation, trigger: .firstSend) == .v2 else {
                throw StoryReplyDeliveryError.conversationUnavailable
            }
            conversation = try await services.messages.conversation(id: conversationId)
            guard session.isCurrent else { throw CancellationError() }
        }
        // Une conversation éphémère garde sa durée.
        let policy = await ConversationSecretPolicyCache.resolved(conversationId: conversationId, service: services.messages)
        let result = await services.sendV2TextOutsideThread(
            trimmed, to: conversation, ttlSeconds: policy?.backgroundSendTTLSeconds ?? 0, clientRequestId: requestID
        )
        guard session.isCurrent else { throw CancellationError() }
        if EncryptedConversationSurfaces.v2SendFailureMessage(result) != nil {
            throw StoryReplyDeliveryError.notSent
        }
    }

    /// Le tête-à-tête avec l'auteur : celui qui existe, sinon un nouveau, chiffré.
    private func storyReplyConversationId(authorID: String, currentUserID: String) async throws -> String {
        let conversations = try await services.messages.conversations()
        if let existing = conversations.first(where: {
            !$0.isGroup && ($0.directPeerUserId == authorID
                || Set($0.participants.map(\.userId)) == Set([authorID, currentUserID]))
        }) {
            return existing.id
        }
        switch await services.e2eeV2Messaging.create(
            participantIds: [authorID], isGroup: false, title: nil, excludesWeb: false
        ) {
        case .created(let conversationId, _):
            return conversationId
        case .failure(let failure) where failure.code == "E2EE_DIRECT_CONVERSATION_EXISTS":
            // Créé entre-temps ailleurs.
            guard case .string(let existing)? = failure.details?["conversationId"] else {
                throw StoryReplyDeliveryError.conversationUnavailable
            }
            return existing
        case .failure:
            throw StoryReplyDeliveryError.conversationUnavailable
        }
    }

    // MARK: Header custom — titre, actions rondes, menu secondaire

    /// « Autour de toi » : une ligne de chiffres, le détail dans une feuille.
    private func pulseCard(_ pulse: NetworkPulse) -> some View {
        Button {
            Haptics.selection()
            isPulseExpanded = true
        } label: {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: "waveform.path.ecg", size: 36,
                               tint: SQColor.accentInk, fill: SQColor.accentSoft)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Autour de toi · \(pulse.windowLabel)")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.label)
                        .accessibilityIdentifier("community.networkPulse.title")
                    if !pulseSummary(pulse).isEmpty {
                        Text(pulseSummary(pulse))
                            .font(SQType.caption)
                            .monospacedDigit()
                            .foregroundStyle(SQColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("community.networkPulse.summary")
                    }
                }
                Spacer(minLength: SQSpace.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md2)
            .padding(.vertical, SQSpace.md)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .sqSoftCard()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pouls réseau · autour de toi")
        .accessibilityValue(pulseSummary(pulse))
        .accessibilityHint("Ouvre le détail")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("community.networkPulse.toggle")
    }

    /// Débit médian · mesures · opérateur en tête ; chaque élément absent se tait.
    private func pulseSummary(_ pulse: NetworkPulse) -> String {
        var parts: [String] = []
        if let median = pulse.medianDownloadMbps {
            parts.append(String(localized: "\(median) Mbit/s médian"))
        }
        parts.append(String(localized: "\(pulse.measurementsCount) mesures"))
        if let best = pulse.bestOperator, !best.isEmpty {
            parts.append(String(localized: "\(best) en tête"))
        }
        return parts.joined(separator: " · ")
    }

    private var pulseSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pouls réseau")
                        .font(SQType.display)
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: SQSpace.sm)
                    Button { isPulseExpanded = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(width: 44, height: 44)
                            .sqSurface(SQColor.chip, in: Circle())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityLabel("Fermer")
                }
                if let pulse = model.pulse {
                    NetworkPulseHero(pulse: pulse)
                    pulseMethod(pulse)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xxl)
        }
        .signalQuestBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Ce que valent les chiffres : la feuille ne montrait que trois nombres
    /// sans dire d'où ils venaient, ni sur quoi un opérateur passait « en tête »
    /// (lot F, F-33). Règles du serveur (`/api/social/network-pulse`).
    private func pulseMethod(_ pulse: NetworkPulse) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Comment c’est calculé")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Signal moyen : la puissance reçue de l’antenne (RSRP), en moyenne sur les points de couverture partagés dans le rayon ; plus elle est proche de 0, mieux c’est.")
                Text("Réception médiane : la moitié des speedtests publics du rayon font mieux, l’autre moitié moins bien.")
                Text("En tête : le meilleur score, moitié signal moyen, moitié débit médian, parmi les opérateurs qui ont au moins 50 points de couverture.")
                Text("Seules les mesures publiques comptent, et rien ne s’affiche tant que moins de 3 membres ont mesuré dans la zone.")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community.networkPulse.method")
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            headerTitle(singleLine: true)
            Spacer(minLength: SQSpace.xs)
            headerRoundButton(identifier: "explore", systemImage: "magnifyingglass",
                              label: "Explorer") {
                showExplore = true
            }
            headerRoundButton(identifier: "messages", systemImage: "bubble.left.and.bubble.right",
                              label: "Messages", badgeCount: services.unreadConversations) {
                showMessages = true
            }
            .accessibilityValue(services.unreadConversations == 0
                                ? "Aucun message non lu"
                                : "\(services.unreadConversations) conversation non lue")
            communityMenu
        }
        .padding(.top, SQSpace.xs)
        .accessibilityElement(children: .contain)
    }

    /// Titre sur une ligne, qui se réduit plutôt que de sortir de l'écran en
    /// très grand texte et de pousser les boutons (UI-15).
    private func headerTitle(singleLine: Bool) -> some View {
        Text("Communauté")
            .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
            .foregroundStyle(SQColor.label)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("feed.header")
    }

    /// Bouton rond de l'en-tête, comme la cloche de l'Accueil.
    private func headerRoundButton(
        identifier: String,
        systemImage: String,
        label: String,
        badgeCount: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.surface, in: Circle())
                .sqShadowSoft()
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        SQCountBadge(count: badgeCount)
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityIdentifier("community.header.action.\(identifier)")
    }

    /// État vide de l'onglet ouvert, ou du hashtag choisi.
    @ViewBuilder
    private var emptyFeedState: some View {
        if let tag = model.selectedHashtag {
            EmptyStateView(title: String(localized: "Rien ici pour l’instant"),
                           message: String(localized: "Aucune publication avec #\(tag) pour l’instant."),
                           systemImage: "number")
                .padding(.top, SQSpace.xxl)
        } else {
            switch model.tab {
            case .forYou:
                EmptyStateView(title: model.tab.emptyTitle, message: model.tab.emptyMessage, systemImage: "sparkles")
                    .padding(.top, SQSpace.xxl)
                emptyFeedNextSteps(followable: false)
            case .following:
                followingEmptyState
            case .nearby:
                // Le rayon vient de la réponse du serveur ; 30 km tant qu'il ne l'a pas dit.
                let radius = model.nearRadiusKm ?? 30
                EmptyStateView(title: String(localized: "Rien de publié à moins de \(radius) km"),
                               message: String(localized: "Sois le premier à partager une mesure ici."),
                               systemImage: "location")
                    .padding(.top, SQSpace.xxl)
                GradientButton("Publier", systemImage: "square.and.pencil") {
                    composerRequest = ComposerRequest(start: nil)
                }
                .accessibilityIdentifier("feed.empty.publish")
                changeZoneButton
            case .photos:
                EmptyStateView(title: model.tab.emptyTitle, message: model.tab.emptyMessage, systemImage: "photo.on.rectangle.angled")
                    .padding(.top, SQSpace.xxl)
            case .saved:
                EmptyStateView(title: model.tab.emptyTitle, message: model.tab.emptyMessage, systemImage: "bookmark")
                    .padding(.top, SQSpace.xxl)
            }
        }
    }

    /// « Suivis » vide : personne de suivi, ou rien de neuf chez les profils suivis. Tant
    /// que le nombre d'abonnements n'est pas connu, le texte neutre de l'onglet.
    @ViewBuilder
    private var followingEmptyState: some View {
        Group {
            switch model.followingCount {
            case .some(0):
                EmptyStateView(title: FeedTab.following.emptyTitle, message: FeedTab.following.emptyMessage,
                               systemImage: "person.2")
            case .some:
                EmptyStateView(title: String(localized: "Rien de neuf chez les profils que tu suis"),
                               message: String(localized: "Leurs prochaines publications arriveront ici."),
                               systemImage: "person.2")
            case .none where model.followingCount == nil && model.followingCountFailed:
                // Le nombre d'abonnements ne s'est pas lu : rien n'affirme « rien de neuf » à
                // quelqu'un qui ne suit peut-être personne (COM-05).
                EmptyStateView(title: String(localized: "Rien ici pour l’instant"),
                               message: FeedTab.following.emptyMessage,
                               systemImage: "person.2")
            case .none:
                // Ni « personne » ni « rien de neuf » tant que le nombre d'abonnements n'est pas
                // connu : un texte qui change au bout de quelques secondes se lit comme un bug.
                LoadingSkeleton()
                    .sqShimmer()
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, SQSpace.xxl)
        .task(id: currentUser?.id) {
            if let id = currentUser?.id { await model.loadFollowingCount(userId: id) }
        }
        if model.followingCount != nil || model.followingCountFailed {
            emptyFeedNextSteps(followable: true)
        }
    }

    /// Fil vide : publier se fait déjà depuis la ligne « Quoi de neuf ? » au-dessus.
    /// Reste à trouver qui suivre : les membres que le serveur suggère, puis Explorer.
    /// `followable` : chaque profil se suit en un toucher (état vide de « Suivis »).
    @ViewBuilder
    private func emptyFeedNextSteps(followable: Bool) -> some View {
        let suggestions = Array((model.page?.suggestedUsers ?? []).prefix(3))
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if !suggestions.isEmpty {
                Text("Membres à découvrir")
                    .sqKicker()
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, SQSpace.xs)
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, author in
                        if index > 0 { Divider().padding(.leading, 58) }
                        HStack(spacing: 0) {
                        Button {
                            Haptics.light()
                            profileAuthor = author
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: author.avatarUrl, name: author.displayName, size: 34)
                                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                                    Text(author.displayName)
                                        .font(SQType.body(.bold))
                                        .foregroundStyle(SQColor.label)
                                        .lineLimit(1)
                                    if let handle = author.handle {
                                        Text(verbatim: "@\(handle)")
                                            .font(SQType.caption)
                                            .foregroundStyle(SQColor.labelSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if !followable {
                                    Image(systemName: "chevron.right")
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .padding(.leading, SQSpace.md)
                            .padding(.trailing, followable ? SQSpace.sm : SQSpace.md)
                            .padding(.vertical, SQSpace.xs2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SQElision.apply(String(localized: "Voir le profil de \(author.displayName)"), name: author.displayName))
                        .accessibilityIdentifier("feed.empty.suggestion")
                        if followable { suggestionFollowButton(author) }
                        }
                    }
                }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
            GradientButton("Découvrir des membres", systemImage: "magnifyingglass",
                           style: .secondary) {
                showExplore = true
            }
            .accessibilityIdentifier("feed.empty.explore")
        }
    }

    /// « Suivre » en un toucher, « Suivi » une fois fait : même pastille qu'Explorer.
    private func suggestionFollowButton(_ author: SocialFeedAuthor) -> some View {
        let followed = model.followedSuggestionIds.contains(author.id) || author.isFollowing == true
        return Button { model.followSuggestion(author) } label: {
            Text(followed ? "Suivi" : "Suivre")
                .font(SQType.subhead(.bold))
                .foregroundStyle(followed ? SQColor.label : SQColor.onInk)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 32)
                .background(followed ? SQColor.chip : SQColor.label, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(followed || model.followBusyIds.contains(author.id))
        .padding(.trailing, SQSpace.md)
        .accessibilityLabel(followed
            ? SQElision.apply(String(localized: "\(author.displayName), suivi"), name: author.displayName)
            : SQElision.apply(String(localized: "Suivre \(author.displayName)"), name: author.displayName))
        .accessibilityIdentifier("feed.empty.follow")
    }

    /// « Quoi de neuf ? » : la publication commence ici, en une ligne. Photo
    /// et Speedtest ouvrent la même feuille, la pièce jointe déjà choisie.
    /// Crayon flottant : ouvre le composer, où photo et speedtest se joignent. Remplace la rangée
    /// « Quoi de neuf ? » (choix d'Alexandre du 25/11) ; la safe area du dock le garde au-dessus.
    private var composeButton: some View {
        Button {
            Haptics.light()
            composerRequest = ComposerRequest(start: nil)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SQColor.onInk)
                .frame(width: 56, height: 56)
                .background(SQColor.label, in: Circle())
                .sqShadowDock()
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .padding(.trailing, SQSpace.lg)
        .padding(.bottom, SQSpace.md)
        .accessibilityLabel("Créer une publication")
        .accessibilityIdentifier("community.header.action.publish")
    }

    /// L'onglet « Photos », en galerie.
    ///
    /// Trois colonnes, vignettes carrées, sans chrome : ce qu'on regarde ici,
    /// c'est l'image. Les cartes du fil portent l'auteur, le texte, les
    /// métriques et six actions — nécessaires pour un speedtest, du bruit pour
    /// une photo. Un appui ouvre la publication complète, où tout cela revient.
    @ViewBuilder
    private func photoGallery(_ items: [UnifiedSocialFeedItem]) -> some View {
        let tiles: [GalleryTile] = items.compactMap { item in
            // Images seulement : une vidéo n'a pas de vignette décodable ici.
            guard let url = item.imageAttachments.lazy
                .compactMap({ $0.thumbnailUrl ?? $0.url })
                .first
            else { return nil }
            return GalleryTile(item: item, url: url)
        }
        if tiles.isEmpty, !items.isEmpty, !model.isLoadingMore, !model.loadMoreStalled {
            // Des publications sans image : la grille resterait vide sans rien dire.
            EmptyStateView(
                title: String(localized: "Rien ici pour l’instant"),
                message: model.tab.emptyMessage,
                systemImage: "photo.on.rectangle"
            )
            .padding(.top, SQSpace.xxl)
            .onAppear { Task { await model.loadMore() } }
        }
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.xs), count: 3),
            spacing: SQSpace.xs
        ) {
            ForEach(tiles) { tile in
                Button {
                    routedPostItem = RoutedPost(item: tile.item)
                    Haptics.light()
                } label: {
                    // 320 pt de côté max : une vignette de grille ne dépasse
                    // jamais le tiers de la largeur, décoder du 1500 px pour
                    // l'afficher à 120 remplirait le cache pour rien.
                    RemoteImage(url: tile.url, maxDimension: 320, contentMode: .fill, showsFailureUI: true) {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .fill(SQColor.surfaceMuted)
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(SQElision.apply(String(localized: "Photo de \(tile.item.author.displayName)"), name: tile.item.author.displayName)))
                .onAppear {
                    // La grille n'a pas de cartes : c'est sa dernière tuile qui demande la suite.
                    if tile.id == tiles.last?.id {
                        Task { await model.loadMore() }
                    }
                }
            }
        }
    }

    /// `⋯` — les destinations de la communauté qui ne méritent pas un bouton
    /// permanent, mais qu'on cherchait jusqu'ici dans l'onglet Profil.
    private var chronologicalBinding: Binding<Bool> {
        Binding(
            get: { model.sort(for: model.tab) == .latest },
            set: { on in
                Haptics.selection()
                Task { await model.selectSort(on ? .latest : .relevance) }
            }
        )
    }

    private var communityMenu: some View {
        Menu {
            Button { showFriends = true } label: {
                Label("Amis", systemImage: "person.2.fill")
            }
            Button { showNotifications = true } label: {
                Label("Notifications", systemImage: "bell.fill")
            }
            Button { showCalls = true } label: {
                Label("Appels", systemImage: "phone.circle")
            }
            Divider()
            Button { showRecap = true } label: {
                Label("Ma semaine", systemImage: "calendar")
            }
            Button { showFeedPreferences = true } label: {
                Label("Préférences du fil", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { await model.select(.saved) }
            } label: {
                Label("Enregistrés", systemImage: "bookmark")
            }
            // « Pour toi » est le fil classé : l'ordre chronologique n'est qu'une option, pour
            // l'onglet affiché, gardée avec le compte (feedSort). Remplace « Pertinence | Récent ».
            if model.tab.sortKey != nil {
                Divider()
                Toggle(isOn: chronologicalBinding) {
                    Label("Ordre chronologique", systemImage: "clock")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.surface, in: Circle())
                .sqShadowSoft()
        }
        // Même libellé que le Web et Android (contrôle croisé Fil Communauté, 25/11).
        .accessibilityLabel("Options du fil")
    }

    // MARK: Hashtags — capsules pleines/douces


    /// Carte du fil, extraite en fonction.
    ///
    /// Ce n'est pas cosmétique : construite en ligne dans le `LazyVStack`, avec
    /// ses six fermetures d'action, son menu contextuel et son `onAppear`,
    /// l'expression faisait saturer le vérificateur de types de Swift
    /// (« unable to type-check in reasonable time »). L'isoler lui redonne un
    /// contexte borné.
    @ViewBuilder
    private func feedCard(for item: UnifiedSocialFeedItem) -> some View {
        FeedItemCard(
            item: item,
            onTap: { presentedSheet = .detail(item) },
            // Chaque action nourrit aussi le classement : ce
            // sont les signaux les plus discriminants, bien plus
            // qu'une simple vue.
            // Un signal seulement quand l'action AJOUTE (retirer son like
            // envoyait « like ») ; commentaire et partage après réussite.
            onLike: {
                if !item.likedByMe { recordSignal("like", for: item) }
                model.react(item)
            },
            onRepost: {
                if !item.repostedByMe { recordSignal("repost", for: item) }
                repostWithUndo(item)
            },
            onComment: { presentedSheet = .comments(item) },
            onFavorite: {
                if !item.favoritedByMe { recordSignal("favorite", for: item) }
                model.favorite(item)
            },
            onShare: { presentedSheet = .share(item) },
            onAuthorTap: { profileAuthor = item.author },
            onReact: { emoji in
                if !item.hasReacted(with: emoji) { recordSignal("like", for: item) }
                model.react(item, emoji: emoji)
            },
            onPollVote: { option in model.votePoll(item, option: option) }
        )
        .contextMenu { postMenu(for: item) }
        // Même menu derrière le ⋯ de la carte, et en dernières actions VoiceOver,
        // Signaler compris (CardActionsBar) : plus de « Signaler » en tête (F-50).
        .environment(\.feedCardMenu, AnyView(postMenu(for: item)))
        // Mise en valeur Premium de l'auteur : le fil seulement (D13).
        .environment(\.feedCardSpotlightPostId, item.id)
        .environment(\.feedHashtagAction, { filter(byHashtag: $0) })
        .environment(\.feedOpenLink, { $0.open(with: services.router) })
        .sqFadeUp()
        .accessibilityIdentifier("feed.item.\(item.id)")
        .onAppear {
            // Une vue par post et par session : le collecteur
            // déduplique, l'appeler à chaque réapparition de
            // cellule est donc sans effet de bord.
            Task { await services.feedSignals.didAppear(item.backendPostId) }
            if let items = model.page?.items {
                if FeedViewModel.shouldLoadMore(appearing: item.id, in: items) {
                    Task { await model.loadMore() }
                }
                prefetchImages(after: item.id, in: items)
            }
        }
        .onDisappear {
            Task { await services.feedSignals.didDisappear(item.backendPostId) }
        }
    }

    /// Photos des cartes suivantes demandées d'avance (E5), au format de leur carte : même
    /// clé de cache, la carte les trouve décodées en apparaissant. Un échec reste muet, la
    /// carte retentera elle-même.
    private func prefetchImages(after id: String, in items: [UnifiedSocialFeedItem]) {
        // Fonds de plan des cartes de trajet suivantes (IOS-053) : préparés d'avance, au
        // format de la dernière miniature mesurée, sans jamais retarder une carte visible.
        for item in FeedViewModel.upcoming(after: id, in: items)
        where FeedActivity(item: item) == nil && ["coverage", "session", "drive_test"].contains(item.cardKind) {
            guard let trace = SignalDetailSheet.trace(kind: item.kind, signal: item.signal), !trace.isEmpty else { continue }
            RouteSnapshotCache.shared.prefetchRoute(postId: item.id, coordinates: trace)
        }
        let scale = displayScale
        let targets = FeedViewModel.upcoming(after: id, in: items).compactMap(FeedItemCard.prefetchImage(for:))
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) {
            for target in targets {
                let maxPixel = max(1, target.maxDimension * scale)
                guard ImagePipeline.shared.cachedImage(for: target.url, maxPixel: maxPixel) == nil else { continue }
                _ = try? await ImagePipeline.shared.image(for: target.url, maxPixel: maxPixel)
            }
        }
    }

    /// Actions d'une publication : appui long et bouton ⋯ de la carte, dans l'ordre commun
    /// (`PostOptionsMenu`). Suppression sans alerte : la publication disparaît et « Annuler »
    /// reste 5 s (plan Fil Communauté, C5, comme Android).
    private func postMenu(for item: UnifiedSocialFeedItem) -> some View {
        PostOptionsMenu(
            item: item,
            onViewProfile: { profileAuthor = item.author },
            onShare: { presentedSheet = .share(item) },
            onEdit: { editingPost = item },
            onSetVisibility: { model.setVisibility(item, to: $0) },
            onSetLocation: { setLocation(item, to: $0) },
            onTogglePin: { model.togglePin(item) },
            onMute: { model.muteNotifications(item) },
            onDelete: { deleteWithUndo(item) },
            onMuteAuthor: { muteAuthor(item.author) },
            onBlockAuthor: { blockingAuthor = item.author },
            onReport: { presentedSheet = .report(item) },
            identifierPrefix: "feed.post"
        )
    }

    /// Signal d'engagement du classement « Pour toi », avec l'identifiant brut
    /// du post : le serveur indexe ses signaux par `post.id`, et l'identifiant
    /// du fil (« post-… ») ne comptait pour rien (SOC-19).
    private func recordSignal(_ type: String, for item: UnifiedSocialFeedItem) {
        Task { await services.feedSignals.record(postId: item.backendPostId, type: type) }
    }

    /// Pilule « N nouveautés ».
    ///
    /// Annoncer plutôt qu'insérer : faire remonter la liste pendant que
    /// l'utilisateur lit déplacerait ce qu'il regarde. Il décide du moment.
    private func newPostsPill(onTap: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            onTap()
            Task { await model.applyPending() }
        } label: {
            HStack(spacing: SQSpace.xs + 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
                Text("\(model.pendingCount) nouvelle publication")
                    .font(SQType.subhead(.semibold))
            }
            .foregroundStyle(SQColor.onInk)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 40)
            .background(SQColor.label, in: Capsule(style: .continuous))
            .sqShadowDock()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint("Affiche les publications reçues")
        .accessibilityIdentifier("feed.pending")
    }

    /// « Autour » sans position : ce qui manque, et le geste qui le donne. La demande d'iOS ne part
    /// que d'ici, jamais à l'ouverture du fil.
    @ViewBuilder
    private var nearbyPositionState: some View {
        switch model.nearbyPosition {
        case .ready:
            EmptyView()
        case .needsPermission:
            EmptyStateView(
                title: String(localized: "Ce qui se passe autour de toi"),
                message: String(localized: "Autorise la localisation pour voir les publications partagées à moins de 30 km. Ta position est arrondie à environ 1 km avant d’être envoyée."),
                systemImage: "location"
            )
            .padding(.top, SQSpace.xxl)
            GradientButton("Autoriser la localisation", systemImage: "location.fill") {
                Task { await model.requestNearbyPermission() }
            }
            .accessibilityIdentifier("feed.nearby.allow")
            changeZoneButton
        case .denied:
            EmptyStateView(
                title: String(localized: "Localisation désactivée"),
                message: String(localized: "Active la localisation de SignalQuest dans Réglages pour voir les publications partagées autour de toi."),
                systemImage: "location.slash"
            )
            .padding(.top, SQSpace.xxl)
            GradientButton("Ouvrir Réglages", style: .secondary) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .accessibilityIdentifier("feed.nearby.settings")
            changeZoneButton
        case .unavailable:
            ErrorStateView(title: String(localized: "Position introuvable"),
                           message: String(localized: "Ta position n’a pas pu être lue. Réessaie dans un instant.")) {
                Task { await model.load() }
            }
            changeZoneButton
        }
    }

    /// Onglets visibles. « Enregistrés » vit dans le menu ⋯ et ne rejoint la
    /// rangée que tant qu'il est ouvert, pour qu'on sache où l'on est.
    private var visibleTabs: [FeedTab] {
        FeedTab.allCases.filter { $0 != .saved || model.tab == .saved }
    }

    /// Barre d'onglets du fil : texte souligné, l'active à l'encre. Épinglée en haut au défilement,
    /// d'où le fond opaque qui couvre toute la largeur.
    ///
    /// Défilante horizontalement : à Dynamic Type élevé, quatre onglets ne tiennent
    /// pas sur une largeur d'iPhone, et une barre segmentée les tronquerait.
    private var feedTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.lg) {
                ForEach(visibleTabs) { tab in
                    let selected = model.tab == tab
                    Button {
                        Haptics.selection()
                        Task { await model.select(tab) }
                    } label: {
                        Text(LocalizedStringKey(tab.title))
                            .font(SQType.subhead(selected ? .bold : .semibold))
                            .sqSingleLine()
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(selected ? SQColor.label : SQColor.chipInk)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) {
                                Capsule(style: .continuous)
                                    .fill(selected ? SQColor.label : Color.clear)
                                    .frame(height: 3)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SQPressButtonStyle(scale: 0.97))
                    // `.isSelected` plutôt qu'un libellé « sélectionné » ajouté au
                    // texte : VoiceOver l'annonce déjà, et le rotor s'en sert.
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("feed.tab.\(tab.rawValue)")
                }
            }
            .padding(.horizontal, SQSpace.lg)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SQColor.separator).frame(height: 1).accessibilityHidden(true)
        }
        // Le rail déborde volontairement des marges de l'écran, comme celui des
        // stories : la première pastille reste alignée sur la marge.
        .padding(.horizontal, -SQSpace.lg)
        .background(SQColor.bg)
    }

    /// « Changer de zone » : une ville choisie à la main, même sans localisation.
    private var changeZoneButton: some View {
        GradientButton("Changer de zone", systemImage: "map", style: .secondary) {
            showsZonePicker = true
        }
        .accessibilityIdentifier("feed.nearby.zone")
    }

    /// Zone de « Autour » : la position de l'appareil ou la ville choisie, et le geste pour en changer.
    private var nearbyZoneBar: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: model.nearbyZone == nil ? "location.fill" : "mappin.and.ellipse")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text(model.nearbyZone.map { String(localized: "Zone : \($0.name)") } ?? String(localized: "Zone : ma position"))
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Spacer(minLength: SQSpace.sm)
            if model.nearbyZone != nil {
                Button("Ma position") {
                    Haptics.selection()
                    Task { await model.clearNearbyZone() }
                }
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .accessibilityLabel("Revenir à ma position")
                .accessibilityIdentifier("feed.nearby.zone.reset")
            }
            Button("Changer") {
                Haptics.selection()
                showsZonePicker = true
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .accessibilityLabel("Changer de zone")
            .accessibilityIdentifier("feed.nearby.zone.change")
        }
        .padding(.horizontal, SQSpace.xs)
    }

    /// Filtre par hashtag actif : la pastille le nomme et le retire.
    private func hashtagFilter(_ tag: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Button {
                Haptics.selection()
                model.selectedHashtag = nil
                Task { await model.load() }
            } label: {
                HStack(spacing: SQSpace.xs2) {
                    Text("#\(tag)")
                        .font(SQType.subhead(.semibold))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(SQColor.onInk)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 34)
                .background(SQColor.label, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle(scale: 0.97))
            .accessibilityLabel(Text("Retirer le filtre #\(tag)"))
            .accessibilityIdentifier("feed.hashtag.clear")
            if let count = model.trendingHashtags.first(where: { $0.tag == tag })?.postCount {
                Text("\(count) publications")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    /// Tirer pour actualiser, ou retoucher l'onglet : le fil et le pouls repartent.
    private func refreshFeed() async {
        await model.load()
        await model.loadPulse(force: true)
        // Nombre d'abonnements illisible tout à l'heure : tirer pour actualiser le relit
        // (déjà connu, la lecture ne repart pas).
        if model.tab == .following, let id = currentUser?.id { await model.loadFollowingCount(userId: id) }
    }

    /// Filtre le fil sur un hashtag touché dans une carte.
    private func filter(byHashtag tag: String) {
        guard model.selectedHashtag != tag else { return }
        Haptics.selection()
        model.selectedHashtag = tag
        Task { await model.load() }
        scrollTopRequest = UUID()
    }
}

private struct StoriesPresentation: Identifiable { let id: Int }

struct PostShareSheet: View {
    let post: UnifiedSocialFeedItem
    let messagesService: MessagesServicing
    /// Renvoie l'id du message créé (succès) ou nil (échec).
    let onShare: (MessageConversation) async -> String?
    /// Appelé après un partage réussi, pour proposer l'annulation côté feed.
    var onShared: (String, MessageConversation) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var conversations: [MessageConversation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var busyConversationId: String?
    @State private var query = ""
    @State private var showsSystemShare = false

    /// Recherche locale : la liste vient déjà entière du serveur.
    private var visibleConversations: [MessageConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter { title(of: $0).localizedCaseInsensitiveContains(needle) }
    }

    /// Titre sans soi-même, comme la liste des messages : « Camille, Inès » devenait « Inès ».
    private func title(of conversation: MessageConversation) -> String {
        var currentUserId: String?
        if case .authenticated(let user) = session.state { currentUserId = user.id }
        return conversation.displayTitle(excluding: currentUserId)
    }

    /// Lien web de la publication, seulement si elle est publique : un lien vers
    /// une publication réservée aux amis mènerait les autres sur un refus.
    private var publicLink: URL? {
        guard post.visibility == nil || post.visibility == "public" else { return nil }
        return AppConfig.current.appBaseURL
            .appendingPathComponent("posts")
            .appendingPathComponent(post.backendPostId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(alignment: .center) {
                    Text("Envoyer à")
                        .font(SQFont.display(22, .bold, relativeTo: .title2))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "post.share.close") { dismiss() }
                }

                if !post.displayText.isEmpty {
                    Text(post.displayText)
                        .font(SQType.caption)
                        .lineLimit(2)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityLabel(Text("Publication : \(post.displayText)"))
                }

                SQSearchField(text: $query, placeholder: "Rechercher une conversation")

                if isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.vertical, SQSpace.lg)
                } else if conversations.isEmpty, errorMessage == nil {
                    Text("Aucune conversation active")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else if !visibleConversations.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleConversations.enumerated()), id: \.element.id) { index, conversation in
                            if index > 0 { Divider().padding(.leading, 62) }
                            conversationRow(conversation)
                        }
                    }
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("post.share.error")
                    if conversations.isEmpty {
                        Button("Réessayer") { Task { await load() } }
                            .font(SQType.subhead(.semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("post.share.retry")
                    }
                }

                if publicLink != nil {
                    GradientButton("Partager hors de l’app", systemImage: "square.and.arrow.up", style: .secondary) {
                        showsSystemShare = true
                    }
                    .accessibilityIdentifier("post.share.external")
                }
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await load() }
        .sheet(isPresented: $showsSystemShare) {
            if let publicLink { ShareSheet(items: [publicLink]) }
        }
        .presentationDetents([.medium, .large])
        .sqSheet(background: SQColor.bg)
    }

    /// Conversation v2 : la carte part chiffrée par l'app (E2EE-AUTO §7.7, `CARD` `POST`).
    private func sharesEncrypted(_ conversation: MessageConversation) -> Bool {
        EncryptedConversationSurfaces.isV2(conversation) && services.e2eeV2Messaging.writesEnabled
            && E2EEAutoPostShare.canShare(post)
    }

    /// Une conversation : avatar, nom, puis « Envoyer ». Une conversation
    /// chiffrée qu'on ne peut pas servir reste visible mais grisée, avec la raison.
    private func conversationRow(_ conversation: MessageConversation) -> some View {
        // Le partage de publication est inséré en CLAIR (aperçu texte,
        // auteur, image) côté serveur : on ne le propose donc PAS vers
        // une conversation chiffrée v1, pour ne pas briser la promesse
        // E2EE sous un badge « Chiffrée » (SEC-1). En v2, l'app chiffre la carte.
        let encrypted = sharesEncrypted(conversation)
        let isE2EE = conversation.e2eeEnabled == true && !encrypted
        let subtitle: String? = isE2EE
            ? String(localized: "Conversation chiffrée · pas de partage de publication")
            : encrypted ? String(localized: "Conversation chiffrée")
            : (conversation.isGroup ? String(localized: "\(conversation.participants.count) membres") : nil)
        return Button {
            Task { await share(conversation) }
        } label: {
            HStack(spacing: SQSpace.md) {
                SQAvatar(url: conversation.displayAvatarURL(excluding: LocalAccountScope.currentUserId), name: title(of: conversation), size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(of: conversation).isEmpty ? "Conversation" : title(of: conversation))
                        .font(SQType.body(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    if let subtitle {
                        HStack(spacing: 4) {
                            if isE2EE || encrypted {
                                Image(systemName: "lock.fill").font(.system(size: 10)).accessibilityHidden(true)
                            }
                            Text(subtitle)
                        }
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if busyConversationId == conversation.id {
                    SQSpinner().tint(SQColor.brandRed)
                } else if !isE2EE {
                    Text("Envoyer")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(SQColor.chip, in: Capsule())
                }
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .opacity(isE2EE ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busyConversationId != nil || isE2EE)
        .accessibilityIdentifier("post.share.conversation.\(conversation.id)")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            conversations = AppEnvironment.usesDemoData ? .demo : try await messagesService.conversations()
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    private func share(_ conversation: MessageConversation) async {
        let encrypted = sharesEncrypted(conversation)
        guard busyConversationId == nil, conversation.e2eeEnabled != true || encrypted else { return }
        busyConversationId = conversation.id
        defer { busyConversationId = nil }
        errorMessage = nil
        if encrypted {
            // Pas d'annulation proposée : elle passerait par une suppression chiffrée, faite depuis la conversation.
            if await E2EEAutoPostShare.send(post, to: conversation, messaging: services.e2eeV2Messaging) {
                Haptics.success()
                dismiss()
            } else {
                Haptics.error()
                errorMessage = String(localized: "Échec de l'envoi. Réessaie.")
            }
            return
        }
        if let messageId = await onShare(conversation) {
            onShared(messageId, conversation)
            dismiss()
        } else {
            errorMessage = String(localized: "Échec de l'envoi. Réessaie.")
        }
    }
}

extension SocialFeedPage {
    static var demo: SocialFeedPage {
        let json = """
        {
          "items": [
            {
              "id": "demo-post-1",
              "kind": "speedtest",
              "createdAt": "2026-05-11T10:20:00.000Z",
              "author": {"id": "u1", "name": "Camille", "handle": "camille", "avatarUrl": null},
              "text": "Speedtest iOS partagé depuis Paris. Radio détaillée indisponible sur iOS, mais débit et latence contribuent à la carte.",
              "placeLabel": "Paris",
              "attachments": [],
              "hashtags": ["ios", "5g", "paris"],
              "reactions": [{"emoji": "❤️", "count": 14, "reactedByMe": false}],
              "commentsCount": 3,
              "repostsCount": 2,
              "favoritesCount": 8,
              "likedByMe": false,
              "favoritedByMe": false,
              "repostedByMe": false,
              "signal": {
                "type": "speedtest",
                "technology": "5G",
                "downloadMbps": 412,
                "uploadMbps": 64,
                "pingMs": 18,
                "operator": "SignalQuest",
                "city": "Paris",
                "detectedTechs": ["5G"],
                "deviceModel": "iPhone"
              }
            },
            {
              "id": "demo-post-2",
              "kind": "photo",
              "createdAt": "2026-05-11T09:40:00.000Z",
              "author": {"id": "u2", "name": "Nora", "handle": "nora", "avatarUrl": null},
              "text": "Photo de site ajoutée et validée par la communauté.",
              "placeLabel": "Lyon",
              "attachments": [],
              "hashtags": ["photo", "site"],
              "reactions": [{"emoji": "🔥", "count": 9, "reactedByMe": false}],
              "commentsCount": 1,
              "repostsCount": 0,
              "favoritesCount": 4,
              "likedByMe": false,
              "favoritedByMe": false,
              "repostedByMe": false
            }
          ],
          "nextCursor": null,
          "stories": [
            {"id": "story-1", "author": {"id": "u1", "name": "Camille", "handle": "camille", "avatarUrl": null}, "text": "5G Paris", "mediaUrl": null, "thumbnailUrl": null, "mediaKind": "text", "background": null, "metadata": {"signal": {"operator": "SFR", "technology": "5g", "rsrp": -88}}, "visibility": "friends", "status": "active", "durationSeconds": 15, "createdAt": "2026-05-11T10:00:00.000Z", "expiresAt": null, "viewedByMe": false, "isMine": false},
            {"id": "story-2", "author": {"id": "u2", "name": "Nora", "handle": "nora", "avatarUrl": null}, "text": "Photo site", "mediaUrl": null, "thumbnailUrl": null, "mediaKind": "text", "background": null, "metadata": null, "visibility": "public", "status": "active", "durationSeconds": 15, "createdAt": "2026-05-11T10:00:00.000Z", "expiresAt": null, "viewedByMe": true, "isMine": false}
          ],
          "trendingHashtags": [{"tag": "ios", "postCount": 32}, {"tag": "5g", "postCount": 21}, {"tag": "photos", "postCount": 15}],
          "suggestedUsers": [],
          "requestId": "demo"
        }
        """
        return (try? JSONDecoder.signalQuest.decode(SocialFeedPage.self, from: Data(json.utf8)))
            ?? SocialFeedPage(items: [], nextCursor: nil, stories: [], trendingHashtags: [], suggestedUsers: [], requestId: nil)
    }
}

extension Notification.Name {
    /// Posté par `FriendsService.block` : `userInfo["userId"]` est le membre bloqué.
    static let sqMemberBlocked = Notification.Name("SignalQuest.MemberBlocked")
    /// Membre mis en sourdine : ses publications quittent le fil, comme pour un blocage.
    static let sqMemberMuted = Notification.Name("SignalQuest.MemberMuted")
}

/// Publication ouverte depuis une notification ou un lien alors qu'elle n'existe plus, ou
/// n'est plus visible pour ce compte : un état, pas une erreur (plan Fil Communauté, C6).
struct DeletedPostView: View {
    var body: some View {
        ScrollView {
            EmptyStateView(
                title: String(localized: "Publication supprimée"),
                message: String(localized: "Elle a été retirée, ou elle n’est plus visible pour toi."),
                systemImage: "trash"
            )
            .padding(.top, SQSpace.xxl)
            .padding(.horizontal, SQSpace.lg)
            .sqReadableWidth()
            .accessibilityIdentifier("feed.post.deleted")
        }
        .navigationTitle("Publication")
        .navigationBarTitleDisplayMode(.inline)
        .signalQuestBackground()
    }
}

/// Choix d'une zone à la main pour « Autour » : une ville ou un lieu cherché chez Apple
/// (même géocodage que la carte), jamais la position de l'appareil.
struct NearbyZonePicker: View {
    let onChoose: (String, CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { place in
                    Button {
                        Haptics.selection()
                        onChoose(place.name, CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: SQSpace.xxs) {
                            Text(verbatim: place.name)
                                .font(SQType.body(.semibold))
                                .foregroundStyle(SQColor.label)
                            if let subtitle = place.subtitle {
                                Text(verbatim: subtitle)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed.nearby.zone.result")
                }
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    // Feuille vide sans rien dire : une ligne d'aide (recette de l'audit, 25/11).
                    Label("Cherche une ville ou un lieu pour voir ce qui s’y publie.", systemImage: "magnifyingglass")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .listRowSeparator(.hidden)
                }
                if searched, results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Aucun lieu trouvé.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Ville ou lieu"))
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard text.count >= 2 else { results = []; searched = false; return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let found = await MapExplorerViewModel.geocodePlaces(text, near: nil)
                guard !Task.isCancelled else { return }
                results = found
                searched = true
            }
            .navigationTitle("Changer de zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .accessibilityIdentifier("feed.nearby.zone.cancel")
                }
            }
        }
    }
}

/// Séparateur de jour d'un fil chronologique : « Aujourd'hui », « Hier », puis la date.
struct FeedDaySeparator: View {
    let title: String

    /// Titre à poser avant `item` s'il ouvre un nouveau jour ; nil sinon, ou sans date.
    static func title(for item: UnifiedSocialFeedItem, after previous: UnifiedSocialFeedItem?,
                      now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date = item.createdAt else { return nil }
        if let before = previous?.createdAt, calendar.isDate(before, inSameDayAs: date) { return nil }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Aujourd’hui") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Hier")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(.dateTime.day().month(.wide).year())
    }

    var body: some View {
        Text(verbatim: title)
            .sqKicker()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SQSpace.sm)
            .padding(.leading, SQSpace.xs)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("feed.day")
    }
}
