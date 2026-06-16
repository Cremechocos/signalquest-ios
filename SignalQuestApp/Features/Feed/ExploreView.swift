import SwiftUI

// Exploration du réseau social : hashtags tendance (flux filtré),
// suggestions d'utilisateurs à suivre et recherche d'utilisateurs.

@MainActor
final class ExploreViewModel: ObservableObject {
    @Published var trending: [TrendingHashtag] = []
    @Published var suggestions: [SocialFeedAuthor] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Recherche d'utilisateurs
    @Published var searchText = ""
    @Published var searchResults: [SocialUserSearchResult] = []
    @Published var isSearching = false

    // Flux filtré par hashtag
    @Published var selectedHashtag: String?
    @Published var hashtagItems: [UnifiedSocialFeedItem] = []
    @Published var hashtagCursor: String?
    @Published var isLoadingHashtag = false
    @Published var isLoadingMoreHashtag = false

    // Etat optimiste des follows déclenchés depuis les suggestions
    // (surcharge locale par-dessus author.isFollowing).
    @Published var followOverrides: [String: Bool] = [:]
    @Published var followBusyIds: Set<String> = []
    @Published var followPopTick = 0

    private let service: SocialFeedServicing
    private var searchTask: Task<Void, Never>?

    init(service: SocialFeedServicing) {
        self.service = service
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
            errorMessage = error.localizedDescription
        }
    }

    /// Recherche avec un léger debounce pour ne pas marteler l'API.
    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
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
        if AppEnvironment.usesDemoData {
            searchResults = Self.demoSearchResults.filter {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                ($0.handle?.localizedCaseInsensitiveContains(query) ?? false)
            }
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await service.searchUsers(query: query, limit: 12)
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

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
    }

    private func loadHashtagFeed(tag: String) async {
        if AppEnvironment.usesDemoData {
            hashtagItems = SocialFeedPage.demo.items.filter { $0.hashtags.contains(tag) }
            return
        }
        isLoadingHashtag = true
        defer { isLoadingHashtag = false }
        do {
            let page = try await service.loadFeed(cursor: nil, hashtag: tag)
            guard selectedHashtag == tag else { return }
            hashtagItems = page.items
            hashtagCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
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
            let page = try await service.loadFeed(cursor: cursor, hashtag: tag)
            guard selectedHashtag == tag else { return }
            let known = Set(hashtagItems.map(\.id))
            hashtagItems.append(contentsOf: page.items.filter { !known.contains($0.id) })
            hashtagCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isFollowed(_ author: SocialFeedAuthor) -> Bool {
        followOverrides[author.id] ?? (author.isFollowing == true)
    }

    func toggleFollow(_ author: SocialFeedAuthor) {
        guard !followBusyIds.contains(author.id) else { return }
        followPopTick += 1
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
                errorMessage = error.localizedDescription
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

    private let service: SocialFeedServicing

    @State private var profileAuthor: SocialFeedAuthor?
    @State private var detailItem: UnifiedSocialFeedItem?

    init(service: SocialFeedServicing) {
        self.service = service
        _model = StateObject(wrappedValue: ExploreViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                Text("Découvrir le réseau")
                    .sqKicker()
                    .padding(.horizontal, SQSpace.xxs)

                SQSearchField(text: $model.searchText, placeholder: "Rechercher un utilisateur") {
                    model.scheduleSearch()
                }
                .onChangeCompat(of: model.searchText) { _, _ in
                    model.scheduleSearch()
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
        }
        .navigationTitle("Explorer")
        .toolbarTitleLargeCompat()
        .signalQuestBackground()
        .task {
            if model.trending.isEmpty && model.suggestions.isEmpty { await model.load() }
        }
        .refreshable { await model.load() }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: service)
        }
        .sheet(item: $detailItem) { item in
            SignalDetailSheet(
                item: item,
                onLike: { Task { _ = try? await service.react(postId: item.id, emoji: "❤️") } },
                onRepost: { Task { _ = try? await service.repost(postId: item.id) } },
                onFavorite: { Task { _ = try? await service.favorite(postId: item.id) } }
            )
        }
    }

    // MARK: Recherche

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Résultats")
                .sqKicker()
            SQSectionHeader("Utilisateurs")
            if model.isSearching {
                ProgressView()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.lg)
            } else if model.searchResults.isEmpty {
                EmptyStateView(
                    title: "Aucun résultat",
                    message: "Essaie un autre nom ou un @handle.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            } else {
                VStack(spacing: SQSpace.sm) {
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
                            }
                            .padding(SQSpace.md)
                            .sqEditorialCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Tendances

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Tendances")
                .sqKicker()
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
                                    .font(SQFont.archivo(14, .bold))
                                Text(SignalFormatters.count(tag.postCount))
                                    .font(SQType.micro)
                                    .opacity(0.8)
                            }
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.sm)
                            .background(
                                isOn ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                    .stroke(isOn ? Color.clear : SQColor.separator, lineWidth: 1.5)
                            }
                            .foregroundStyle(isOn ? .white : SQColor.label)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Flux hashtag

    @ViewBuilder
    private var hashtagFeedSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            if let tag = model.selectedHashtag {
                SQSectionHeader("#\(tag)") {
                    Button("Effacer") {
                        Haptics.selection()
                        model.selectHashtag(nil)
                    }
                    .font(SQType.caption)
                    .tint(SQColor.brandRed)
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
                        FeedItemCard(
                            item: item,
                            onTap: { detailItem = item },
                            onAuthorTap: { profileAuthor = item.author }
                        )
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

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("À suivre")
                .sqKicker()
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

            Spacer()

            Button {
                model.toggleFollow(author)
            } label: {
                Text(followed ? "Abonné" : "Suivre")
                    .font(SQFont.archivo(13, .bold))
                    .padding(.horizontal, SQSpace.md + 2)
                    .padding(.vertical, SQSpace.sm)
                    .background(
                        followed ? AnyShapeStyle(SQColor.surface) : AnyShapeStyle(SQColor.brandRed),
                        in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .stroke(followed ? SQColor.label : Color.clear, lineWidth: 2)
                    }
                    .foregroundStyle(followed ? SQColor.label : .white)
            }
            .buttonStyle(.plain)
            .sqLikePop(trigger: model.followPopTick)
            .disabled(model.followBusyIds.contains(author.id))
        }
        .padding(SQSpace.md)
        .sqEditorialCard()
    }
}
