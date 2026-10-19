import CoreLocation
import SwiftUI

// Exploration du réseau social : hashtags tendance (flux filtré),
// suggestions d'utilisateurs à suivre et recherche d'utilisateurs.

@MainActor
final class ExploreViewModel: ObservableObject {
    @Published var trending: [TrendingHashtag] = []
    @Published var suggestions: [SocialFeedAuthor] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Échec d'une action (suivre, page suivante) : bandeau passager, pas
    /// « Exploration indisponible » (SOC-14).
    @Published var actionError: String?

    // Recherche d'utilisateurs
    @Published var searchText = ""
    @Published var searchResults: [SocialUserSearchResult] = []
    /// Publications correspondant à la recherche — jusqu'ici jamais peuplées.
    @Published var searchPosts: [UnifiedSocialFeedItem] = []
    /// Lieux et antennes trouvés en même temps (plan 3, vague 2) : la même
    /// recherche mène aussi à la carte.
    @Published var searchPlaces: [PlaceResult] = []
    @Published var searchSites: [AntennaSite] = []
    @Published var isSearching = false
    /// Échec de LA recherche en cours, distinct de l'échec de la page : il
    /// s'efface à la recherche suivante (AF-FIL-08).
    @Published var searchError: String?
    /// Posé par la vue : le service des antennes vit dans l'environnement.
    var antennas: AntennasServicing?

    // Flux filtré par hashtag
    @Published var selectedHashtag: String?
    @Published var hashtagItems: [UnifiedSocialFeedItem] = []
    @Published var hashtagCursor: String?
    @Published var isLoadingHashtag = false
    /// Hashtags suivis (sans `#`), lus une fois : Suivre n'existait nulle part
    /// alors que les Préférences y renvoient (AF-FIL-09).
    @Published private(set) var followedHashtags: Set<String>?
    @Published private(set) var isTogglingHashtagFollow = false
    @Published var isLoadingMoreHashtag = false

    // Etat optimiste des follows déclenchés depuis les suggestions
    // (surcharge locale par-dessus author.isFollowing).
    @Published var followOverrides: [String: Bool] = [:]
    @Published var followBusyIds: Set<String> = []

    private let service: SocialFeedServicing
    private var searchTask: Task<Void, Never>?

    init(service: SocialFeedServicing) {
        self.service = service
    }

    /// Reporte des interactions confirmées par le serveur sur les listes affichées.
    func accept(_ item: UnifiedSocialFeedItem) {
        searchPosts = searchPosts.map { $0.id == item.id ? $0.adoptingInteractions(from: item) : $0 }
        hashtagItems = hashtagItems.map { $0.id == item.id ? $0.adoptingInteractions(from: item) : $0 }
    }

    /// Élément tel qu'il est maintenant dans les listes de l'écran (la fiche
    /// ouverte suit ainsi les votes et la sourdine).
    func currentItem(_ item: UnifiedSocialFeedItem) -> UnifiedSocialFeedItem {
        searchPosts.first { $0.id == item.id } ?? hashtagItems.first { $0.id == item.id } ?? item
    }

    /// Un commentaire publié depuis la feuille compte aussitôt sur la carte.
    func commentPosted(on item: UnifiedSocialFeedItem) {
        update(item.id) { var copy = $0; copy.commentsCount += 1; return copy }
    }

    private func update(_ id: String, _ transform: (UnifiedSocialFeedItem) -> UnifiedSocialFeedItem) {
        searchPosts = searchPosts.map { $0.id == id ? transform($0) : $0 }
        hashtagItems = hashtagItems.map { $0.id == id ? transform($0) : $0 }
    }

    // Mêmes actions que le fil principal (`FeedViewModel`) : les boutons des
    // cartes d'Explorer ne faisaient rien (AF-FIL-01).

    func votePoll(_ item: UnifiedSocialFeedItem, option: FeedPoll.Option) {
        guard let poll = item.poll, poll.isOpen else { return }
        let removing = option.votedByMe
        Task {
            do {
                guard let updated = try await service.votePoll(postId: item.id, optionId: option.id, removing: removing) else { return }
                update(item.id) { current in var copy = current; copy.poll = updated; return copy }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    func muteNotifications(_ item: UnifiedSocialFeedItem) {
        Task {
            do {
                _ = try await service.muteNotifications(postId: item.id)
                update(item.id) { current in
                    var copy = current
                    copy.notificationsMutedByMe = !(current.notificationsMutedByMe ?? false)
                    return copy
                }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Renvoie l'id du message créé, nil si échec (la feuille affiche l'échec).
    func share(_ item: UnifiedSocialFeedItem, to conversation: MessageConversation) async -> String? {
        do {
            let messageId = try await service.share(postId: item.id, conversationId: conversation.id)
            Haptics.success()
            return messageId
        } catch {
            Haptics.error()
            return nil
        }
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            loadDemo()
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let trends = service.trendingHashtags()
            async let people = service.suggestedUsers()
            trending = try await trends
            suggestions = try await people
            // Les tendances portent « Suivre » : il faut savoir lesquelles le sont.
            if followedHashtags == nil { await loadFollowedHashtags() }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Recherche avec un léger debounce pour ne pas marteler l'API.
    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchPosts = []
            searchError = nil
            searchPlaces = []
            searchSites = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        searchError = nil
        if AppEnvironment.usesDemoData {
            searchPosts = []
            searchResults = Self.demoSearchResults.filter {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                ($0.handle?.localizedCaseInsensitiveContains(query) ?? false)
            }
            searchPlaces = Self.demoPlaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
            searchSites = []
            return
        }
        isSearching = true
        // Une recherche remplacée en cours de route ne remet pas le drapeau à faux.
        defer { if !Task.isCancelled { isSearching = false } }
        let antennasService = antennas
        async let map = Self.mapResults(for: query, antennas: antennasService)
        do {
            // UN appel au lieu de deux, et surtout : la recherche renvoie enfin
            // des PUBLICATIONS. `searchUsers` n'en rapportait aucune, si bien
            // qu'un mot-clé ne trouvait jamais le post qui le contenait.
            let result = try await service.explore(query: query)
            searchResults = result.peopleAsSearchResults
            searchPosts = result.posts
        } catch {
            // Une frappe rapide annule la recherche précédente : URLSession lève
            // alors `URLError(.cancelled)` ou `APIError.cancelled`, pas
            // `CancellationError`. Elle s'affichait « Requête annulée » (SOC-15).
            if !error.isCancellation {
                searchError = error.userFacingMessage
                // Les résultats de la requête précédente ne répondent pas à celle-ci.
                searchResults = []
                searchPosts = []
            }
        }
        let found = await map
        guard !Task.isCancelled else { return }
        searchPlaces = found.places
        searchSites = found.sites
    }

    /// Trois lieux et trois antennes au plus : la carte garde sa propre
    /// recherche, plus complète. Un échec laisse la section vide.
    ///
    /// Un @pseudo ou un #hashtag ne part pas chez Apple : la recherche de lieux
    /// ne reçoit que ce qui peut être un lieu, de trois caractères au moins.
    nonisolated static func mapResults(
        for query: String, antennas: AntennasServicing?
    ) async -> (places: [PlaceResult], sites: [AntennaSite]) {
        guard query.count >= 2, let first = query.first, first != "@", first != "#" else { return ([], []) }
        let searchesPlaces = query.count >= 3
        async let places: [PlaceResult] = searchesPlaces ? await MapExplorerViewModel.geocodePlaces(query, near: nil) : []
        async let sites = (try? await antennas?.quickSearch(
            query: query, market: MapMarketStore.initialMarketCode(), department: nil
        )) ?? []
        return (Array(await places.prefix(3)), Array(await sites.prefix(3)))
    }

    static let demoPlaces = [
        PlaceResult(id: "demo-place-lyon", name: "Lyon", subtitle: "Auvergne-Rhône-Alpes, France",
                    latitude: 45.764, longitude: 4.8357)
    ]

    func selectHashtag(_ tag: String?) {
        guard selectedHashtag != tag else {
            selectedHashtag = nil
            hashtagItems = []
            hashtagCursor = nil
            return
        }
        selectedHashtag = tag
        hashtagItems = []
        hashtagCursor = nil
        guard let tag else { return }
        Task { await loadHashtagFeed(tag: tag) }
        if followedHashtags == nil, !AppEnvironment.usesDemoData {
            Task { await loadFollowedHashtags() }
        }
    }

    private func loadFollowedHashtags() async {
        guard let follows = try? await service.followedHashtags() else { return }
        followedHashtags = Set(follows.map { $0.hashtag.normalizedHashtag })
    }

    func isFollowing(hashtag tag: String) -> Bool {
        followedHashtags?.contains(tag.normalizedHashtag) == true
    }

    func toggleHashtagFollow(_ tag: String) async {
        guard !isTogglingHashtagFollow else { return }
        let normalized = tag.normalizedHashtag
        let following = !isFollowing(hashtag: tag)
        isTogglingHashtagFollow = true
        defer { isTogglingHashtagFollow = false }
        do {
            try await service.setHashtagFollowed(tag, following: following)
            var set = followedHashtags ?? []
            if following { set.insert(normalized) } else { set.remove(normalized) }
            followedHashtags = set
            Haptics.success()
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    private func loadHashtagFeed(tag: String) async {
        if AppEnvironment.usesDemoData {
            hashtagItems = SocialFeedPage.demo.items.filter { $0.hashtags.contains(tag) }
            return
        }
        isLoadingHashtag = true
        defer { isLoadingHashtag = false }
        do {
            let page = try await service.loadFeed(cursor: nil, hashtag: tag, tab: nil)
            guard selectedHashtag == tag else { return }
            hashtagItems = page.items
            hashtagCursor = page.nextCursor
        } catch {
            // Passager : il ne doit pas remplacer la page d'exploration.
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    func loadMoreHashtagFeed() async {
        guard !AppEnvironment.usesDemoData,
              let tag = selectedHashtag,
              let cursor = hashtagCursor,
              !isLoadingMoreHashtag else { return }
        isLoadingMoreHashtag = true
        defer { isLoadingMoreHashtag = false }
        do {
            let page = try await service.loadFeed(cursor: cursor, hashtag: tag, tab: nil)
            guard selectedHashtag == tag else { return }
            let known = Set(hashtagItems.map(\.id))
            hashtagItems.append(contentsOf: page.items.filter { !known.contains($0.id) })
            hashtagCursor = page.nextCursor
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    func isFollowed(_ author: SocialFeedAuthor) -> Bool {
        followOverrides[author.id] ?? (author.isFollowing == true)
    }

    func toggleFollow(_ author: SocialFeedAuthor) {
        guard !followBusyIds.contains(author.id) else { return }
        Haptics.medium()
        let wasFollowed = isFollowed(author)
        // Bascule optimiste, corrigée par la réponse serveur.
        followOverrides[author.id] = !wasFollowed
        if AppEnvironment.usesDemoData { return }
        followBusyIds.insert(author.id)
        Task {
            defer { followBusyIds.remove(author.id) }
            do {
                let result = try await service.toggleFollow(userId: author.id)
                followOverrides[author.id] = result.following
            } catch {
                followOverrides[author.id] = wasFollowed
                if !error.isCancellation { actionError = error.userFacingMessage }
                Haptics.error()
            }
        }
    }

    // MARK: Démo

    private func loadDemo() {
        trending = [
            TrendingHashtag(tag: "ios", postCount: 32),
            TrendingHashtag(tag: "5g", postCount: 21),
            TrendingHashtag(tag: "paris", postCount: 17),
            TrendingHashtag(tag: "photos", postCount: 15)
        ]
        suggestions = [
            SocialFeedAuthor(id: "u1", name: "Camille", handle: "camille", avatarUrl: nil, isFriend: false, isFollowing: false, liveRadio: nil),
            SocialFeedAuthor(id: "u2", name: "Nora", handle: "nora", avatarUrl: nil, isFriend: false, isFollowing: false, liveRadio: nil),
            SocialFeedAuthor(id: "u3", name: "Mehdi", handle: "mehdi", avatarUrl: nil, isFriend: false, isFollowing: true, liveRadio: nil)
        ]
        followedHashtags = ["5g"]
        errorMessage = nil
    }

    private static let demoSearchResults: [SocialUserSearchResult] = [
        SocialUserSearchResult(id: "u1", name: "Camille", handle: "camille", avatarUrl: nil, isFriend: false),
        SocialUserSearchResult(id: "u2", name: "Nora", handle: "nora", avatarUrl: nil, isFriend: true),
        SocialUserSearchResult(id: "u3", name: "Mehdi", handle: "mehdi", avatarUrl: nil, isFriend: false)
    ]
}

struct ExploreView: View {
    @StateObject private var model: ExploreViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter

    private let service: SocialFeedServicing

    @State private var profileAuthor: SocialFeedAuthor?
    /// Une seule présentation : la fiche détail cède ainsi la place aux
    /// commentaires, au signalement ou au partage (AF-FIL-02).
    @State private var presentedSheet: ExploreSheet?
    /// Salons publics (ROOM-1) : la liste de tous les salons, ou un salon.
    @State private var roomsRoute: RoomsRoute?

    private enum ExploreSheet: Identifiable {
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
    /// Profils consultés récemment sur cet appareil (plan 3, vague 1).
    @State private var recentProfiles: [RecentlyViewedStore.Item] = []
    @ScaledMetric(relativeTo: .caption) private var recentTileWidth: CGFloat = 76

    init(service: SocialFeedServicing) {
        self.service = service
        _model = StateObject(wrappedValue: ExploreViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Explorer", backIdentifier: "explore.back")
                SQSearchField(text: $model.searchText, placeholder: "Membre, publication, lieu ou antenne") {
                    model.scheduleSearch()
                }
                .onChangeCompat(of: model.searchText) { _, _ in
                    model.scheduleSearch()
                }
                .onChangeCompat(of: model.actionError) { _, message in
                    guard let message else { return }
                    inAppNotifications.showError(message)
                    model.actionError = nil
                }

                if let error = model.errorMessage {
                    ErrorStateView(title: "Exploration indisponible", message: error) {
                        Task { await model.load() }
                    }
                }

                if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchSection
                } else if model.isLoading && model.trending.isEmpty && model.suggestions.isEmpty {
                    LoadingSkeleton().sqShimmer()
                } else {
                    if model.selectedHashtag != nil {
                        hashtagFeedSection
                    } else {
                        ExploreRoomsSection(
                            onOpenAll: { roomsRoute = .list },
                            onOpen: { roomsRoute = .room($0) }
                        )
                        if !recentProfiles.isEmpty {
                            recentProfilesSection
                        }
                        trendingSection
                        // Pendant une erreur de chargement, « Aucune suggestion »
                        // contredirait le message d'erreur affiché au-dessus.
                        if model.errorMessage == nil || !model.suggestions.isEmpty {
                            suggestionsSection
                        }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .navigationTitle("Explorer")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task {
            if model.trending.isEmpty && model.suggestions.isEmpty { await model.load() }
        }
        .refreshable { await model.load() }
        .onAppear {
            recentProfiles = Self.storedRecentProfiles()
            model.antennas = services.antennas
        }
        .onReceive(NotificationCenter.default.publisher(for: RecentlyViewedStore.didChange)) { _ in
            recentProfiles = Self.storedRecentProfiles()
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: service)
        }
        .navigationDestinationItemCompat($roomsRoute) { route in
            switch route {
            case .list: RoomsListView()
            case .room(let room): RoomThreadView(room: room, service: services.rooms)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .detail(let opened):
                let item = model.currentItem(opened)
                SignalDetailSheet(
                    item: item,
                    onLike: { interact(with: item) { try await service.react(postId: $0, emoji: "❤️") } },
                    onRepost: { interact(with: item) { try await service.repost(postId: $0) } },
                    onFavorite: { interact(with: item) { try await service.favorite(postId: $0) } },
                    onComment: { presentedSheet = .comments(item) },
                    onShare: { presentedSheet = .share(item) },
                    onMute: { model.muteNotifications(item) },
                    onReport: { presentedSheet = .report(item) },
                    onPollVote: { option in model.votePoll(item, option: option) },
                    onAuthorTap: {
                        presentedSheet = nil
                        pushProfileAfterDismiss(item.author)
                    }
                )
            case .comments(let item):
                CommentsSheet(service: services.comments, postId: item.backendPostId,
                              profileService: services.feed, reports: services.reports,
                              commentsCount: item.commentsCount,
                              onCommentPosted: { model.commentPosted(on: item) })
            case .report(let item):
                ReportSheet(target: .post(item.backendPostId), service: services.reports)
            case .share(let item):
                PostShareSheet(
                    post: item,
                    messagesService: services.messages,
                    onShare: { conversation in await model.share(item, to: conversation) }
                )
            }
        }
    }

    /// La feuille gardait l'état d'ouverture et le fil de l'écran ne bougeait
    /// pas : la réponse du serveur est appliquée aux deux (SOC-17).
    private func interact(
        with item: UnifiedSocialFeedItem,
        _ action: @escaping @MainActor (String) async throws -> ReactionResponse
    ) {
        Task { @MainActor in
            let response: ReactionResponse
            do {
                response = try await action(item.id)
            } catch {
                // L'échec d'un « j'aime » se disait nulle part.
                if !error.isCancellation { model.actionError = error.userFacingMessage }
                return
            }
            let updated = item.applying(response)
            model.accept(updated)
        }
    }

    // MARK: Récents

    private static func storedRecentProfiles() -> [RecentlyViewedStore.Item] {
        RecentlyViewedStore.items().filter { $0.kind == .profile }
    }

    /// Profils consultés récemment, le plus récent d'abord.
    private var recentProfilesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Récents") {
                Button("Effacer") {
                    Haptics.selection()
                    RecentlyViewedStore.clear([.profile])
                }
                .font(SQType.caption(.bold))
                .tint(SQColor.accentInk)
                .frame(minHeight: 44)
                .accessibilityLabel("Effacer les récents")
                .accessibilityIdentifier("explore.recents.clear")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: SQSpace.md) {
                    ForEach(recentProfiles) { item in
                        Button {
                            Haptics.light()
                            profileAuthor = SocialFeedAuthor(
                                id: item.targetId,
                                name: item.title,
                                handle: item.handle,
                                avatarUrl: item.avatarURL,
                                isFriend: nil,
                                isFollowing: nil,
                                liveRadio: nil
                            )
                        } label: {
                            VStack(spacing: SQSpace.xs) {
                                SQAvatar(url: item.avatarURL, name: item.title, size: 48)
                                Text(item.title)
                                    .font(SQType.caption(.semibold))
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: recentTileWidth)
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .accessibilityLabel("Voir le profil de \(item.title)")
                        .accessibilityIdentifier("explore.recent.profile.\(item.targetId)")
                    }
                }
                .padding(.vertical, SQSpace.xxs)
            }
        }
    }

    // MARK: Recherche

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // Sans membre trouvé, l'en-tête restait seul au-dessus des lieux.
            if model.isSearching || !model.searchResults.isEmpty || !hasOtherSearchResults {
                SQSectionHeader("Utilisateurs")
            }
            if model.isSearching {
                SQSpinner()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.lg)
            } else if let searchError = model.searchError, model.searchResults.isEmpty && model.searchPosts.isEmpty {
                // Échec : ce n'est pas « aucun résultat ».
                ErrorStateView(title: "Recherche indisponible", message: searchError) {
                    model.scheduleSearch()
                }
            } else if model.searchResults.isEmpty && model.searchPosts.isEmpty
                        && model.searchPlaces.isEmpty && model.searchSites.isEmpty {
                EmptyStateView(
                    title: "Aucun résultat",
                    // Le message parlait de nom et de @handle alors que la
                    // recherche couvre désormais aussi les publications.
                    message: "Essaie un autre mot-clé, un nom ou un @handle.",
                    systemImage: "magnifyingglass"
                )
            } else {
                LazyVStack(spacing: SQSpace.sm) {
                    ForEach(model.searchResults) { result in
                        Button {
                            Haptics.light()
                            profileAuthor = SocialFeedAuthor(
                                id: result.id,
                                name: result.name,
                                handle: result.handle,
                                avatarUrl: result.avatarUrl,
                                isFriend: result.isFriend,
                                isFollowing: nil,
                                liveRadio: nil
                            )
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: result.avatarUrl, name: result.displayName, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.displayName)
                                        .font(SQType.heading)
                                        .foregroundStyle(SQColor.label)
                                    if let handle = result.handle {
                                        Text("@\(handle)")
                                            .font(SQType.caption)
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                }
                                Spacer()
                                if result.isFriend == true {
                                    SQEditorialTag(text: "Ami", color: SQColor.success)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SQColor.labelTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(SQSpace.md)
                            .sqEditorialCard()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Voir le profil de \(result.displayName)")
                    }
                }

                }
                if !model.searchPosts.isEmpty {
                    // Les publications trouvées : c'est la moitié de la
                    // recherche qui n'existait pas côté iOS.
                    Text("Publications")
                        .font(SQFont.archivo(13, .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, SQSpace.md)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.searchPosts) { item in
                        exploreCard(item)
                    }
                }
                if !model.searchPlaces.isEmpty || !model.searchSites.isEmpty {
                    mapResultsSection
                }
        }
    }

    private var hasOtherSearchResults: Bool {
        !model.searchPosts.isEmpty || !model.searchPlaces.isEmpty || !model.searchSites.isEmpty
    }

    /// Lieux et antennes de la même recherche (plan 3, vague 2) : ils
    /// s'ouvrent sur la carte, comme depuis sa propre recherche.
    private var mapResultsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Sur la carte")
                .font(SQFont.archivo(13, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SQSpace.md)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.searchPlaces) { place in
                mapResultRow(icon: "mappin.circle.fill", title: place.name, subtitle: place.subtitle,
                             id: "explore.map.place") {
                    services.router.pendingMapFocus = Coordinates(latitude: place.latitude, longitude: place.longitude)
                    services.router.selectedTab = .map
                }
            }
            ForEach(model.searchSites) { site in
                mapResultRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: site.address ?? String(localized: "Site \(site.siteId ?? site.id)"),
                    subtitle: Self.siteSubtitle(site),
                    id: "explore.map.site"
                ) {
                    services.router.route(toSite: site.siteId ?? site.id)
                }
            }
        }
    }

    private func mapResultRow(icon: String, title: String, subtitle: String?, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.md)
            .frame(minHeight: 44)
            .sqEditorialCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre la carte")
        .accessibilityIdentifier(id)
    }

    /// « Orange · Free · site n° 37199 », comme la recherche de la carte.
    private static func siteSubtitle(_ site: AntennaSite) -> String {
        var seen = Set<String>()
        var parts = site.operators
            .filter { seen.insert($0.uppercased()).inserted }
            .map(SentinelleListOrder.displayOperator)
        if site.address != nil, let number = site.siteId, !number.isEmpty {
            parts.append(String(localized: "site n° \(number)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Tendances

    /// Tendances en lignes : nombre de publications et « Suivre ». C'est ici
    /// que vivent les hashtags retirés du fil.
    @ViewBuilder
    private var trendingSection: some View {
        if !model.trending.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                sectionTitle("Tendances")
                VStack(spacing: 0) {
                    ForEach(Array(model.trending.enumerated()), id: \.element.id) { index, tag in
                        if index > 0 { Divider().padding(.leading, 62) }
                        trendingRow(tag)
                    }
                }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
        }
    }

    private func trendingRow(_ tag: TrendingHashtag) -> some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.selection()
                model.selectHashtag(tag.tag)
            } label: {
                HStack(spacing: SQSpace.md) {
                    Image(systemName: "number")
                        .font(SQFont.body(16, .bold, relativeTo: .body))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(width: 38, height: 38)
                        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SQSpace.xxs) {
                        Text(verbatim: "#\(tag.tag)")
                            .font(SQType.body(.bold))
                            .foregroundStyle(SQColor.label)
                        Text("\(tag.postCount) publications")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("explore.trend.\(tag.tag)")

            if model.followedHashtags != nil {
                let following = model.isFollowing(hashtag: tag.tag)
                followButton(isOn: following, onTitle: String(localized: "Suivi"), offTitle: String(localized: "Suivre")) {
                    Task { await model.toggleHashtagFollow(tag.tag) }
                }
                .disabled(model.isTogglingHashtagFollow)
                .accessibilityLabel(following
                    ? String(localized: "Ne plus suivre #\(tag.tag)")
                    : String(localized: "Suivre #\(tag.tag)"))
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs2)
    }

    /// « Suivre » à l'encre ; une fois suivi, bouton secondaire.
    private func followButton(isOn: Bool, onTitle: String, offTitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: isOn ? onTitle : offTitle)
                .font(SQType.subhead(.bold))
                .foregroundStyle(isOn ? SQColor.label : SQColor.onInk)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 32)
                .background(isOn ? SQColor.chip : SQColor.label, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sqLikePop(trigger: isOn)
    }

    /// Titre de section en petites capitales, action facultative à droite.
    private func sectionTitle<Trailing: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.leading, SQSpace.xs)
        .frame(minHeight: 24)
    }

    // MARK: Flux hashtag

    @ViewBuilder
    private var hashtagFeedSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            if let tag = model.selectedHashtag {
                SQSectionHeader("#\(tag)") {
                    HStack(spacing: SQSpace.md) {
                        if model.followedHashtags != nil {
                            let following = model.isFollowing(hashtag: tag)
                            // `String(localized:)` : un ternaire de littéraux devient un
                            // `String` que SwiftUI ne traduit pas.
                            Button {
                                Task { await model.toggleHashtagFollow(tag) }
                            } label: {
                                Text(verbatim: following ? String(localized: "Suivi") : String(localized: "Suivre"))
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .font(SQType.caption.weight(.semibold))
                            .tint(following ? SQColor.labelSecondary : SQColor.brandRed)
                            .disabled(model.isTogglingHashtagFollow)
                            .accessibilityLabel(following
                                ? String(localized: "Ne plus suivre #\(tag)")
                                : String(localized: "Suivre #\(tag)"))
                            .accessibilityIdentifier("explore.hashtag.follow")
                        }
                        Button {
                            Haptics.selection()
                            model.selectHashtag(nil)
                        } label: {
                            Text("Effacer")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .font(SQType.caption)
                        .tint(SQColor.brandRed)
                    }
                }
            }
            if model.isLoadingHashtag && model.hashtagItems.isEmpty {
                LoadingSkeleton().sqShimmer()
            } else if model.hashtagItems.isEmpty {
                EmptyStateView(
                    title: "Aucune publication",
                    message: "Pas encore de publication sur ce hashtag.",
                    systemImage: "number"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: SQSpace.cardPadding) {
                    ForEach(model.hashtagItems) { item in
                        exploreCard(item)
                        .sqFadeUp()
                        .onAppear {
                            if item.id == model.hashtagItems.last?.id {
                                Task { await model.loadMoreHashtagFeed() }
                            }
                        }
                    }
                    if model.isLoadingMoreHashtag {
                        SQSpinner()
                            .tint(SQColor.brandRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SQSpace.md)
                    }
                }
            }
        }
    }

    /// Carte d'Explorer, câblée comme celle du fil principal.
    private func exploreCard(_ item: UnifiedSocialFeedItem) -> some View {
        FeedItemCard(
            item: item,
            onTap: { presentedSheet = .detail(item) },
            onLike: { interact(with: item) { try await service.react(postId: $0, emoji: "❤️") } },
            onRepost: { interact(with: item) { try await service.repost(postId: $0) } },
            onComment: { presentedSheet = .comments(item) },
            onFavorite: { interact(with: item) { try await service.favorite(postId: $0) } },
            onShare: { presentedSheet = .share(item) },
            onAuthorTap: { profileAuthor = item.author },
            onReact: { emoji in interact(with: item) { try await service.react(postId: $0, emoji: emoji) } },
            onPollVote: { option in model.votePoll(item, option: option) }
        )
        // Appui long et bouton ⋯ de la carte : couper les notifications, signaler.
        .contextMenu { exploreMenu(for: item) }
        .environment(\.feedCardMenu, AnyView(exploreMenu(for: item)))
    }

    @ViewBuilder
    private func exploreMenu(for item: UnifiedSocialFeedItem) -> some View {
        Button { model.muteNotifications(item) } label: {
            let muted = item.notificationsMutedByMe == true
            let title: LocalizedStringKey = muted ? "Réactiver notifs" : "Couper notifs"
            let icon = muted ? "bell" : "bell.slash"
            Label(title, systemImage: icon)
        }
        // On ne signale pas sa propre publication.
        if !item.canManage {
            Button(role: .destructive) { presentedSheet = .report(item) } label: {
                Label("Signaler", systemImage: "flag")
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            sectionTitle("Suggestions")
            if model.suggestions.isEmpty {
                EmptyStateView(
                    title: "Aucune suggestion",
                    message: "Reviens plus tard pour découvrir de nouveaux profils.",
                    systemImage: "person.2"
                )
            } else {
                // Une seule carte, une ligne par profil.
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, author in
                        if index > 0 { Divider().padding(.leading, 58) }
                        suggestionRow(author)
                    }
                }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
        }
    }

    /// Pousse le profil après la fermeture de la feuille : un push immédiat
    /// pendant l'animation serait avalé.
    private func pushProfileAfterDismiss(_ author: SocialFeedAuthor) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            profileAuthor = author
        }
    }

    private func suggestionRow(_ author: SocialFeedAuthor) -> some View {
        let followed = model.isFollowed(author)
        return HStack(spacing: SQSpace.md) {
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
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voir le profil de \(author.displayName)")

            followButton(isOn: followed, onTitle: String(localized: "Suivi"), offTitle: String(localized: "Suivre")) {
                model.toggleFollow(author)
            }
            .disabled(model.followBusyIds.contains(author.id))
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs2)
    }
}

// MARK: - Salons (ROOM-1)

/// Ce que l'appareil sait de l'utilisateur pour retrouver « Ton salon » : son opérateur et son
/// département. Tout se lit localement : la position ne part vers aucun serveur de SignalQuest
/// (seul le géocodage inverse d'Apple, déjà utilisé ailleurs dans l'app, la reçoit), et le département
/// trouvé ne quitte pas cet objet.
@MainActor
final class RoomsLocalContext {
    struct Snapshot: Equatable {
        var operatorKey: String?
        var department: String?
        var resolvedAt: Date
    }

    static let shared = RoomsLocalContext()
    private static let operatorDefaultsKey = "rooms.operator.v1"
    private static let lifetime: TimeInterval = 600

    private var cache: Snapshot?

    func resolve(_ services: AppServices) async -> Snapshot {
        if AppEnvironment.usesDemoData {
            return Snapshot(operatorKey: "SFR", department: "038", resolvedAt: Date())
        }
        if let cache, Date().timeIntervalSince(cache.resolvedAt) < Self.lifetime { return cache }
        async let operatorKey = resolveOperator(services)
        async let department = resolveDepartment(services)
        let snapshot = Snapshot(operatorKey: await operatorKey, department: await department, resolvedAt: Date())
        cache = snapshot
        return snapshot
    }

    /// Opérateur : IP/ASN en cellulaire hors VPN, puis PLMN de la SIM, puis nom d'opérateur, puis le
    /// dernier opérateur trouvé de cette façon (en Wi-Fi, rien ne l'indique).
    private func resolveOperator(_ services: AppServices) async -> String? {
        services.networkPath.refreshNow()
        let status = services.networkPath.status
        if status.connection == .cellular, !VPNDetector.isActive(),
           let detected = await services.networkOperator.resolve(viaVpn: false),
           detected.viaVpn != true,
           let key = RoomsLogic.operatorKey(from: detected.operatorKey) {
            return remember(key)
        }
        if let plmn = services.networkPath.simPLMN().plmn {
            for code in ["FR", "DROM"] {
                if let entry = await services.markets.market(forCode: code),
                   let registryKey = entry.radioOperatorKey(observedPlmn: plmn),
                   let key = RoomsLogic.operatorKey(from: registryKey) {
                    return remember(key)
                }
            }
        }
        if let key = RoomsLogic.operatorKey(from: status.operatorName) { return remember(key) }
        return RoomsLogic.operatorKey(from: UserDefaults.standard.string(forKey: Self.operatorDefaultsKey))
    }

    private func remember(_ key: String) -> String {
        UserDefaults.standard.set(key, forKey: Self.operatorDefaultsKey)
        return key
    }

    /// Département : seulement si la position est DÉJÀ autorisée (aucune demande de permission ici).
    /// Outre-mer par emprise, métropole par code postal du géocodage inverse.
    private func resolveDepartment(_ services: AppServices) async -> String? {
        let location = services.location
        guard LocationFixPolicy.isAuthorized(location.authorizationStatus),
              let fix = await location.currentLocation(timeoutSeconds: 4, maxAge: 3_600) else { return nil }
        if let territory = DromRegion.from(fix.coordinate) { return territory.department }
        return await Self.postalDepartment(of: fix)
    }

    nonisolated private static func postalDepartment(of fix: CLLocation) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first,
                      placemark.isoCountryCode == "FR" else { return nil }
                return RoomsLogic.departmentCode(postalCode: placemark.postalCode)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let department = await group.next() ?? nil
            group.cancelAll()
            return department
        }
    }
}

/// Les salons d'un marché et « Ton salon », pour l'entrée de l'Explorer et pour la liste.
@MainActor
final class RoomsHomeModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    @Published private(set) var rooms: [RoomSummary] = []
    @Published private(set) var market = "FR"
    @Published private(set) var phase: Phase = .loading
    private(set) var context: RoomsLocalContext.Snapshot?

    /// « Ton salon » dans la liste affichée ; nil si on ne peut pas le déterminer.
    var yourRoom: RoomSummary? {
        guard let context else { return nil }
        return RoomsLogic.yourRoom(in: rooms, operatorKey: context.operatorKey, department: context.department)
    }

    /// `market` nil : celui de l'utilisateur (outre-mer s'il y est, sinon la France métropolitaine).
    func load(_ services: AppServices, market requested: String? = nil) async {
        if rooms.isEmpty { phase = .loading }
        let snapshot = await RoomsLocalContext.shared.resolve(services)
        context = snapshot
        let target = requested
            ?? (DromRegion.fromDepartment(snapshot.department) != nil ? "DROM" : "FR")
        do {
            rooms = try await services.rooms.rooms(market: target)
            market = target
            phase = .loaded
        } catch {
            guard !error.isCancellation else { return }
            if rooms.isEmpty { phase = .failed(error.userFacingMessage) }
        }
    }
}

/// La section « Salons » en tête de l'Explorer : « Ton salon » et l'accès à tous les salons.
struct ExploreRoomsSection: View {
    let onOpenAll: () -> Void
    let onOpen: (RoomSummary) -> Void

    @EnvironmentObject private var services: AppServices
    @StateObject private var model = RoomsHomeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .center) {
                Text("Salons")
                    .sqKicker()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Haptics.selection()
                    onOpenAll()
                } label: {
                    Text("Tous les salons")
                        .font(SQType.caption(.bold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("explore.rooms.all")
            }
            .padding(.leading, SQSpace.xs)

            if let room = model.yourRoom {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Ton salon")
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.leading, SQSpace.xs)
                    Button {
                        Haptics.light()
                        onOpen(room)
                    } label: {
                        RoomRowLabel(room: room)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.xs2)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .accessibilityIdentifier("explore.rooms.yours")
                }
            } else if model.phase == .loading {
                SQSpinner()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, SQSpace.sm)
            } else {
                Text("Discute avec les autres membres, par région et par opérateur.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SQSpace.xs)
            }
        }
        .task { await model.load(services) }
    }
}

/// La ligne d'un salon : nom, activité, badge de nouveaux messages. Se lit d'un trait.
struct RoomRowLabel: View {
    let room: RoomSummary

    var body: some View {
        let unread = RoomSeenStore.newMessageCount(for: room)
        HStack(spacing: SQSpace.md) {
            SQIconPastille(systemImage: icon, size: 38, tint: SQColor.accentInk, fill: SQColor.accentSoft)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(verbatim: room.name)
                    .font(SQType.rowTitle)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: Self.activity(of: room))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if unread > 0 {
                Text(verbatim: unread > 99 ? "99+" : String(unread))
                    .font(SQType.micro)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.sm)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spokenLabel(of: room, unread: unread)))
    }

    private var icon: String {
        if room.technology != nil { return "dot.radiowaves.left.and.right" }
        return room.isNational ? "globe.europe.africa" : "bubble.left.and.bubble.right"
    }

    /// « 14 messages ces dernières 24 h · 2 en direct ».
    static func activity(of room: RoomSummary) -> String {
        var parts: [String] = []
        if room.messages24h > 0 {
            parts.append(String(localized: "\(room.messages24h) messages ces dernières 24 h"))
        } else {
            parts.append(String(localized: "Aucun message ces dernières 24 h"))
        }
        if room.liveCount > 0 {
            parts.append(String(localized: "\(room.liveCount) en direct"))
        }
        return parts.joined(separator: " · ")
    }

    static func spokenLabel(of room: RoomSummary, unread: Int) -> String {
        var parts = [room.name, activity(of: room)]
        if unread > 0 { parts.append(String(localized: "\(unread) nouveaux messages")) }
        return parts.joined(separator: ". ")
    }
}

/// Où l'Explorer envoie : la liste de tous les salons, ou un salon.
enum RoomsRoute: Hashable {
    case list
    case room(RoomSummary)
}

/// Tous les salons : France ou outre-mer, « Ton salon » en tête, filtre par opérateur.
struct RoomsListView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model = RoomsHomeModel()
    @State private var openedRoom: RoomSummary?
    @State private var operatorFilter: String?
    /// Relit les badges au retour d'un salon (le « vu » est gardé sur l'appareil).
    @State private var seenTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Salons", subtitle: "Par région et par opérateur", backIdentifier: "rooms.back")
                marketPicker
                content
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rooms.list")
        }
        .navigationTitle("Salons")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task { await model.load(services) }
        .refreshable { await model.load(services, market: model.market) }
        .onAppear { seenTick += 1 }
        .navigationDestinationItemCompat($openedRoom) { room in
            RoomThreadView(room: room, service: services.rooms)
        }
    }

    private var marketPicker: some View {
        Picker("Territoire", selection: Binding(
            get: { model.market },
            set: { market in
                operatorFilter = nil
                Task { await model.load(services, market: market) }
            }
        )) {
            Text("France").tag("FR")
            Text("Outre-mer").tag("DROM")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("rooms.market")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            SQSpinner().frame(maxWidth: .infinity).padding(.vertical, SQSpace.xl)
        case .failed(let message):
            ErrorStateView(title: "Salons indisponibles", message: message) {
                Task { await model.load(services, market: model.market) }
            }
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        let _ = seenTick
        if let room = model.yourRoom {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Ton salon").sqKicker().accessibilityAddTraits(.isHeader).padding(.leading, SQSpace.xs)
                rowsCard([room], identifierPrefix: "rooms.yours.")
            }
        }
        operatorChips
        let groups = Self.groups(of: model.rooms, operatorFilter: operatorFilter)
        if groups.isEmpty {
            EmptyStateView(title: "Aucun salon", message: "Aucun salon ne correspond à ce filtre.",
                           systemImage: "bubble.left.and.bubble.right")
        } else {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(verbatim: group.title)
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.leading, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    rowsCard(group.rooms)
                }
            }
        }
    }

    @ViewBuilder
    private var operatorChips: some View {
        let keys = Self.operatorKeys(of: model.rooms)
        if keys.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.sm) {
                    chip(title: String(localized: "Tous"), selected: operatorFilter == nil) { operatorFilter = nil }
                    ForEach(keys, id: \.self) { key in
                        chip(title: RoomsLogic.operatorLabel(key), selected: operatorFilter == key) { operatorFilter = key }
                    }
                }
                .padding(.vertical, SQSpace.xxs)
            }
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(verbatim: title)
                .font(SQType.chip)
                .foregroundStyle(selected ? SQColor.onAccent : SQColor.label)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 44)
                .background(selected ? SQColor.brandRed : SQColor.chip, in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rowsCard(_ rooms: [RoomSummary], identifierPrefix: String = "rooms.row.") -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                if index > 0 { Divider().padding(.leading, 62) }
                Button {
                    Haptics.light()
                    openedRoom = room
                } label: {
                    RoomRowLabel(room: room)
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.xs2)
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityIdentifier("\(identifierPrefix)\(room.id)")
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    struct RoomGroup: Equatable {
        let title: String
        let rooms: [RoomSummary]
    }

    /// Les salons nationaux d'abord, puis une carte par région ou territoire, dans l'ordre alphabétique.
    static func groups(of rooms: [RoomSummary], operatorFilter: String?) -> [RoomGroup] {
        let kept = rooms.filter { room in
            guard let operatorFilter else { return true }
            return room.operatorKey == operatorFilter
        }
        var result: [RoomGroup] = []
        let national = kept.filter(\.isNational)
        if !national.isEmpty { result.append(RoomGroup(title: String(localized: "Toute la France"), rooms: national)) }
        let regional = Dictionary(grouping: kept.filter { !$0.isNational }, by: { $0.region?.name ?? $0.name })
        for name in regional.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            result.append(RoomGroup(title: name, rooms: regional[name] ?? []))
        }
        return result
    }

    /// Les opérateurs ayant au moins un salon, les quatre métropolitains d'abord.
    static func operatorKeys(of rooms: [RoomSummary]) -> [String] {
        let present = Set(rooms.compactMap(\.operatorKey))
        let metro = RoomsLogic.metroOperators.filter(present.contains)
        let others = present.subtracting(RoomsLogic.metroOperators).sorted()
        return metro + others
    }
}

/// Le modèle d'un salon ouvert : première page, pages plus anciennes, relecture toutes les 15 s.
///
/// iOS n'utilise pas le canal temps réel `room:<id>` : le contrat prévoit une relecture de la
/// première page. Elle se fusionne par identifiant et ne déplace rien si l'utilisateur lit plus bas :
/// les nouveaux messages attendent alors derrière une pastille.
@MainActor
final class RoomThreadModel: ObservableObject {
    static let refreshInterval: UInt64 = 15_000_000_000

    @Published private(set) var messages: [RoomMessage] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    /// Le serveur ne connaît pas ce salon.
    @Published private(set) var unavailable = false
    @Published private(set) var loadingMore = false
    @Published private(set) var moreFailed = false
    @Published private(set) var posting = false
    @Published var postError: String?
    @Published var actionError: String?
    @Published private(set) var deletingId: String?
    @Published private(set) var live: [RoomLiveShare] = []
    /// Messages arrivés pendant que l'utilisateur lit plus bas, pas encore affichés.
    @Published private(set) var pendingCount = 0

    private let roomId: String
    private let service: RoomsServicing
    private var pending: [RoomMessage]?
    private var loadedMorePages = false

    init(roomId: String, service: RoomsServicing) {
        self.roomId = roomId
        self.service = service
    }

    func load() async {
        loading = true
        loadError = nil
        unavailable = false
        defer { loading = false }
        do {
            let page = try await service.messages(roomId: roomId, cursor: nil)
            messages = page.messages
            nextCursor = page.nextCursor
            pending = nil
            pendingCount = 0
            loadedMorePages = false
            moreFailed = false
        } catch {
            guard !error.isCancellation else { return }
            if case .http(let status, _, _, _, _) = error as? APIError, status == 404 {
                unavailable = true
            } else {
                loadError = error.userFacingMessage
            }
        }
    }

    /// Relit la première page. `isAtTop` faux : les nouveautés attendent, rien ne bouge sous le doigt.
    func refresh(isAtTop: Bool) async {
        guard !loading, loadError == nil, !unavailable else { return }
        guard let page = try? await service.messages(roomId: roomId, cursor: nil) else { return }
        let base = pending ?? messages
        let merged: [RoomMessage]
        if loadedMorePages {
            merged = RoomsLogic.refreshed(firstPage: page.messages, hasMore: page.nextCursor != nil, existing: base)
        } else {
            merged = page.messages
            nextCursor = page.nextCursor
        }
        let added = RoomsLogic.newIds(in: merged, comparedTo: messages)
        if isAtTop || added.isEmpty {
            messages = merged
            pending = nil
            pendingCount = 0
        } else {
            pending = merged
            pendingCount = added.count
        }
    }

    /// Affiche les messages mis en attente (l'utilisateur touche la pastille ou revient en haut).
    func applyPending() {
        guard let pending else { return }
        messages = pending
        self.pending = nil
        pendingCount = 0
    }

    func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await service.messages(roomId: roomId, cursor: cursor)
            messages = RoomsLogic.appending(page.messages, to: messages)
            pending = pending.map { RoomsLogic.appending(page.messages, to: $0) }
            nextCursor = page.nextCursor
            loadedMorePages = true
            moreFailed = false
        } catch {
            if !error.isCancellation { moreFailed = true }
        }
    }

    /// Les partages radio en cours (connecté seulement). Un échec garde ce qui est affiché.
    func refreshLive() async {
        guard let shares = try? await service.live(roomId: roomId) else { return }
        live = shares
    }

    func post(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !posting else { return false }
        posting = true
        postError = nil
        defer { posting = false }
        do {
            // Le serveur renvoie le message tel qu'il l'a enregistré : on l'affiche sans relire le fil.
            let message = try await service.post(roomId: roomId, text: text)
            if !messages.contains(where: { $0.id == message.id }) { messages.insert(message, at: 0) }
            if pending != nil, pending?.contains(where: { $0.id == message.id }) == false {
                pending?.insert(message, at: 0)
            }
            Haptics.success()
            return true
        } catch {
            // Le brouillon reste pour un nouvel essai.
            if !error.isCancellation {
                Haptics.error()
                postError = error.userFacingMessage
            }
            return false
        }
    }

    func delete(_ message: RoomMessage) async {
        deletingId = message.id
        actionError = nil
        defer { deletingId = nil }
        do {
            try await service.delete(messageId: message.id)
            messages.removeAll { $0.id == message.id }
            pending?.removeAll { $0.id == message.id }
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }
}

/// Un salon ouvert : les messages, le direct radio des autres membres, le champ d'écriture.
struct RoomThreadView: View {
    let room: RoomSummary

    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: RoomThreadModel
    @State private var draft = ""
    @State private var atTop = true
    @State private var pendingDelete: RoomMessage?
    @State private var reportTarget: RoomMessage?

    private static let textLimit = 1000
    private static let topAnchor = "rooms.thread.top"

    init(room: RoomSummary, service: RoomsServicing) {
        self.room = room
        _model = StateObject(wrappedValue: RoomThreadModel(roomId: room.id, service: service))
    }

    private var isSignedIn: Bool {
        AppEnvironment.usesDemoData || LocalAccountScope.sessionSnapshot() != nil
    }

    private var canPost: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.posting && !text.isEmpty && text.count <= Self.textLimit
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Color.clear.frame(height: 1)
                        .id(Self.topAnchor)
                        .onAppear { atTop = true }
                        .onDisappear { atTop = false }
                    SQSettingsHeader(
                        title: LocalizedStringKey(room.name),
                        subtitle: "Salon public : tout le monde peut lire. Les messages ne sont pas chiffrés.",
                        backIdentifier: "rooms.thread.back"
                    )
                    if isSignedIn && !model.live.isEmpty { liveSection }
                    if let actionError = model.actionError { SQInlineError(message: actionError) }
                    messagesSection
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.xxl)
                .sqReadableWidth()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rooms.thread")
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { composerBar(proxy) }
            .overlay(alignment: .top) { pendingPill(proxy) }
        }
        .navigationTitle(Text(verbatim: room.name))
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .onAppear { services.router.isDockHidden = true }
        .onDisappear {
            services.router.isDockHidden = false
            RoomSeenStore.markSeen(room.id)
        }
        .task(id: room.id) {
            await model.load()
            RoomSeenStore.markSeen(room.id)
            if isSignedIn { await model.refreshLive() }
        }
        // Relecture toutes les 15 s tant que l'écran est affiché et l'app active : `task(id:)` annule
        // la boucle quand l'écran disparaît ou que l'app passe en arrière-plan.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: RoomThreadModel.refreshInterval)
                guard !Task.isCancelled else { return }
                await model.refresh(isAtTop: atTop)
                if isSignedIn { await model.refreshLive() }
            }
        }
        .alert(
            "Supprimer ce message ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { message in
            Button("Supprimer", role: .destructive) {
                pendingDelete = nil
                Task { await model.delete(message) }
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Il disparaîtra du salon pour tout le monde.")
        }
        .sheet(item: $reportTarget) { message in
            ReportSheet(target: .roomMessage(message.id), service: services.reports)
        }
    }

    // MARK: Direct radio

    /// Les partages radio en cours des autres membres, en lecture seule.
    private var liveSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("En direct · radio partagée")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            ForEach(model.live) { share in
                liveCard(share)
            }
        }
        .accessibilityIdentifier("rooms.thread.live")
    }

    private func liveCard(_ share: RoomLiveShare) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            SQAvatar(url: share.author.avatarUrl, name: share.author.displayName, size: 38)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(verbatim: share.author.displayName)
                    .font(SQType.rowTitle)
                    .foregroundStyle(SQColor.label)
                if let line = Self.liveLine(share), !line.isEmpty {
                    Text(verbatim: line)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let download = share.download {
                    Text(verbatim: "\(Int(download.mbps.rounded())) \(String(localized: "Mbit/s"))")
                        .font(SQType.caption(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                }
            }
            Spacer(minLength: 0)
            if let date = share.updatedAt {
                Text(date, format: .relative(presentation: .named))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// « 5G · N78 · PCI 417 · -91 dBm · SINR 17 dB », puis le réseau observé s'il est connu.
    static func liveLine(_ share: RoomLiveShare) -> String? {
        var parts: [String] = []
        if let summary = share.radio?.summary, !summary.isEmpty { parts.append(summary) }
        if let network = share.network { parts.append(RoomsLogic.operatorLabel(network)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Messages

    @ViewBuilder
    private var messagesSection: some View {
        if model.loading && model.messages.isEmpty {
            SQSpinner().frame(maxWidth: .infinity).padding(.vertical, SQSpace.xl)
        } else if model.unavailable {
            EmptyStateView(title: "Salon introuvable", message: "Ce salon n'existe plus.",
                           systemImage: "bubble.left.and.bubble.right")
        } else if let error = model.loadError, model.messages.isEmpty {
            ErrorStateView(title: "Impossible de charger le salon", message: error) {
                Task { await model.load() }
            }
        } else if model.messages.isEmpty {
            EmptyStateView(title: "Aucun message", message: "Sois le premier à écrire dans ce salon.",
                           systemImage: "bubble.left.and.bubble.right")
        } else {
            LazyVStack(alignment: .leading, spacing: SQSpace.lg) {
                ForEach(model.messages) { message in
                    messageRow(message)
                }
                if model.nextCursor != nil {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            Text(model.moreFailed ? "Réessayer de charger la suite" : "Voir les messages plus anciens")
                            if model.loadingMore { SQSpinner() }
                        }
                        .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .disabled(model.loadingMore)
                }
            }
        }
    }

    private func messageRow(_ message: RoomMessage) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            SQAvatar(url: message.author.avatarUrl, name: message.author.displayName, size: 34)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(verbatim: message.author.displayName)
                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                        .sqSingleLine()
                    if let date = message.createdAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .sqSingleLine()
                    }
                }
                if let summary = message.radio?.summary, !summary.isEmpty {
                    Label {
                        Text(verbatim: summary).monospacedDigit()
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                }
                Text(verbatim: message.text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if message.canDelete || isSignedIn {
                rowMenu(message)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rooms.message.\(message.id)")
    }

    private func rowMenu(_ message: RoomMessage) -> some View {
        Menu {
            if message.canDelete {
                Button(role: .destructive) {
                    pendingDelete = message
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } else {
                Button {
                    reportTarget = message
                } label: {
                    Label("Signaler", systemImage: "flag")
                }
            }
        } label: {
            Group {
                if model.deletingId == message.id {
                    SQSpinner()
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(model.deletingId != nil)
        .accessibilityLabel(String(localized: "Actions sur le message"))
    }

    // MARK: Nouveaux messages et écriture

    @ViewBuilder
    private func pendingPill(_ proxy: ScrollViewProxy) -> some View {
        if model.pendingCount > 0 {
            Button {
                Haptics.selection()
                model.applyPending()
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            } label: {
                Label {
                    Text("\(model.pendingCount) nouveaux messages")
                } icon: {
                    Image(systemName: "arrow.up")
                }
                .font(SQType.chip)
                .foregroundStyle(SQColor.onAccent)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 44)
                .background(SQColor.brandRed, in: Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .padding(.top, SQSpace.sm)
            .accessibilityIdentifier("rooms.thread.new")
        }
    }

    @ViewBuilder
    private func composerBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            if let error = model.postError { SQInlineError(message: error) }
            if isSignedIn {
                HStack(alignment: .bottom, spacing: SQSpace.sm) {
                    TextField("Écrire dans ce salon…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .font(SQType.body)
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm2)
                        .frame(minHeight: 44)
                        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                        .disabled(model.posting)
                        .accessibilityIdentifier("rooms.thread.field")
                    Button {
                        Task {
                            if await model.post(draft) {
                                draft = ""
                                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                            }
                        }
                    } label: {
                        Group {
                            if model.posting {
                                SQSpinner()
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(canPost ? SQColor.onAccent : SQColor.labelSecondary)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(canPost ? SQColor.brandRed : SQColor.fill, in: Circle())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .disabled(!canPost)
                    .accessibilityLabel(String(localized: "Publier"))
                    .accessibilityIdentifier("rooms.thread.post")
                }
                if draft.count > Self.textLimit - 100 {
                    Text("\(draft.count)/\(Self.textLimit)")
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(draft.count > Self.textLimit ? SQColor.dangerInk : SQColor.labelSecondary)
                }
            } else {
                Text("Connecte-toi pour écrire dans ce salon.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface)
    }
}
