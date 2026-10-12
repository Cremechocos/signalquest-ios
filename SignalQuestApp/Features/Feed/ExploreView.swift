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
        defer { isSearching = false }
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
            VStack(alignment: .leading, spacing: SQSpace.xl) {
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
                    if model.selectedHashtag == nil, !recentProfiles.isEmpty {
                        recentProfilesSection
                    }
                    trendingSection
                    if model.selectedHashtag != nil {
                        hashtagFeedSection
                    } else {
                        suggestionsSection
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .navigationTitle("Explorer")
        .toolbarTitleLargeCompat()
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
                    onReport: { presentedSheet = .report(item) }
                )
            case .comments(let item):
                CommentsSheet(service: services.comments, postId: item.backendPostId,
                              profileService: services.feed, reports: services.reports)
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
            SQSectionHeader("Récents") {
                Button("Effacer") {
                    Haptics.selection()
                    RecentlyViewedStore.clear([.profile])
                }
                .font(SQType.caption)
                .tint(SQColor.brandRed)
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
                                SQAvatar(url: item.avatarURL, name: item.title, size: 52)
                                Text(item.title)
                                    .font(SQType.caption)
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
                ProgressView()
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

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            SQSectionHeader("À la une")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.sm) {
                    ForEach(model.trending) { tag in
                        let isOn = tag.tag == model.selectedHashtag
                        Button {
                            Haptics.selection()
                            model.selectHashtag(tag.tag)
                        } label: {
                            HStack(spacing: SQSpace.xs + 2) {
                                Text("#\(tag.tag)")
                                    .font(SQFont.body(13, .semibold))
                                Text(SignalFormatters.count(tag.postCount))
                                    .font(SQType.micro)
                                    .opacity(0.8)
                            }
                            .padding(.horizontal, SQSpace.md + 1)
                            .padding(.vertical, SQSpace.sm)
                            .background(
                                isOn ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(isOn ? SQColor.onAccent : SQColor.label)
                            .sqShadowSoft()
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.horizontal, SQSpace.xxs)
                .padding(.vertical, SQSpace.xs)
            }
        }
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
                            Button(following ? String(localized: "Suivi") : String(localized: "Suivre")) {
                                Task { await model.toggleHashtagFollow(tag) }
                            }
                            .font(SQType.caption.weight(.semibold))
                            .tint(following ? SQColor.labelSecondary : SQColor.brandRed)
                            .disabled(model.isTogglingHashtagFollow)
                            .accessibilityLabel(following
                                ? String(localized: "Ne plus suivre #\(tag)")
                                : String(localized: "Suivre #\(tag)"))
                            .accessibilityIdentifier("explore.hashtag.follow")
                        }
                        Button("Effacer") {
                            Haptics.selection()
                            model.selectHashtag(nil)
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
                    title: "Aucun post",
                    message: "Pas encore de publication sur ce hashtag.",
                    systemImage: "number"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: SQSpace.lg + 2) {
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
                        ProgressView()
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
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            SQSectionHeader("Suggestions")
            if model.suggestions.isEmpty {
                EmptyStateView(
                    title: "Aucune suggestion",
                    message: "Reviens plus tard pour découvrir de nouveaux profils.",
                    systemImage: "person.2"
                )
            } else {
                VStack(spacing: SQSpace.sm) {
                    ForEach(model.suggestions) { author in
                        suggestionRow(author)
                    }
                }
            }
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
                    SQAvatar(url: author.avatarUrl, name: author.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.displayName)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        if let handle = author.handle {
                            Text("@\(handle)")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voir le profil de \(author.displayName)")

            Spacer()

            Button {
                model.toggleFollow(author)
            } label: {
                Text(followed ? "Abonné" : "Suivre")
                    .font(SQFont.body(13, .semibold))
                    .padding(.horizontal, SQSpace.md + 2)
                    .padding(.vertical, SQSpace.sm)
                    .background(
                        followed ? AnyShapeStyle(SQColor.surfaceMuted) : AnyShapeStyle(SQColor.brandRed),
                        in: Capsule(style: .continuous)
                    )
                    .foregroundStyle(followed ? SQColor.label : SQColor.onAccent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sqLikePop(trigger: followed)
            .disabled(model.followBusyIds.contains(author.id))
        }
        .padding(SQSpace.md)
        .sqEditorialCard()
    }
}
