import SwiftUI

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var page: SocialFeedPage?
    @Published var selectedHashtag: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: SocialFeedServicing
    private let storiesService: StoriesServicing?

    init(service: SocialFeedServicing, storiesService: StoriesServicing? = nil) {
        self.service = service
        self.storiesService = storiesService
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            page = .demo
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        if ProcessInfo.processInfo.arguments.contains("--qa-slow-load") {
            try? await Task.sleep(for: .seconds(4))
        }
        do {
            page = try await service.loadFeed(cursor: nil, hashtag: selectedHashtag)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func react(_ item: UnifiedSocialFeedItem, emoji: String = "❤️") {
        let previous = item
        Task {
            await applyLocalToggle(itemId: item.id) { current in
                var copy = current
                copy.likedByMe.toggle()
                copy.reactions = updatedReactions(current.reactions, emoji: emoji, selected: copy.likedByMe)
                return copy
            }
        }
        Task {
            do {
                let response = try await service.react(postId: item.id, emoji: emoji)
                await applyReactionResponse(itemId: item.id, response: response)
            } catch {
                await restore(previous)
                if !error.isCancellation { errorMessage = error.localizedDescription }
            }
        }
        Haptics.light()
    }

    func repost(_ item: UnifiedSocialFeedItem) {
        let previous = item
        Task {
            await applyLocalToggle(itemId: item.id) { current in
                var copy = current
                copy.repostedByMe.toggle()
                copy.repostsCount = max(0, current.repostsCount + (copy.repostedByMe ? 1 : -1))
                return copy
            }
        }
        Task {
            do {
                let response = try await service.repost(postId: item.id)
                await applyReactionResponse(itemId: item.id, response: response)
            } catch {
                await restore(previous)
                if !error.isCancellation { errorMessage = error.localizedDescription }
            }
        }
        Haptics.medium()
    }

    func favorite(_ item: UnifiedSocialFeedItem) {
        let previous = item
        Task {
            await applyLocalToggle(itemId: item.id) { current in
                var copy = current
                copy.favoritedByMe.toggle()
                copy.favoritesCount = max(0, current.favoritesCount + (copy.favoritedByMe ? 1 : -1))
                return copy
            }
        }
        Task {
            do {
                let response = try await service.favorite(postId: item.id)
                await applyReactionResponse(itemId: item.id, response: response)
            } catch {
                await restore(previous)
                if !error.isCancellation { errorMessage = error.localizedDescription }
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
                if !error.isCancellation { errorMessage = error.localizedDescription }
            }
        }
    }

    func share(_ item: UnifiedSocialFeedItem, to conversation: MessageConversation) async -> Bool {
        do {
            _ = try await service.share(postId: item.id, conversationId: conversation.id)
            Haptics.success()
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            Haptics.error()
            return false
        }
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
    @StateObject private var model: FeedViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter

    @State private var presentedSheet: FeedSheet?
    @State private var presentedStoryStart: Int?
    @State private var showStoryComposer = false
    @State private var showComposer = false
    @State private var showExplore = false
    /// Auteur dont on pousse le profil public (cards, commentaires, stories…).
    @State private var profileAuthor: SocialFeedAuthor?
    /// Profil demandé par notification (follow) via AppRouter — par id seul.
    @State private var routedProfileId: String?
    /// Post ouvert via deep-link / notification (résolu en item complet).
    @State private var routedPostItem: RoutedPost?

    private enum FeedSheet: Identifiable {
        case detail(UnifiedSocialFeedItem)
        case comments(UnifiedSocialFeedItem)
        case report(UnifiedSocialFeedItem)
        case share(UnifiedSocialFeedItem)
        case stories
        var id: String {
            switch self {
            case .detail(let i): return "detail-\(i.id)"
            case .comments(let i): return "comments-\(i.id)"
            case .report(let i): return "report-\(i.id)"
            case .share(let i): return "share-\(i.id)"
            case .stories: return "stories"
            }
        }
    }

    /// Enveloppe `Hashable` d'un post pour `navigationDestination(item:)`
    /// (deep-link), identifiée par l'id du post.
    private struct RoutedPost: Identifiable, Hashable {
        let item: UnifiedSocialFeedItem
        var id: String { item.id }
        static func == (lhs: RoutedPost, rhs: RoutedPost) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    init(service: SocialFeedServicing = SocialFeedService(api: APIClient())) {
        _model = StateObject(wrappedValue: FeedViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                Text("Le réseau, sans filtre")
                    .sqKicker()
                    .padding(.horizontal, SQSpace.xxs)

                if model.isLoading && model.page == nil {
                    LoadingSkeleton()
                        .sqShimmer()
                } else {
                    if let stories = model.page?.stories, !stories.isEmpty {
                        StoriesBar(
                            stories: stories,
                            currentUser: nil,
                            onCompose: { showStoryComposer = true },
                            onSelect: { story in
                                if let idx = stories.firstIndex(where: { $0.id == story.id }) {
                                    presentedStoryStart = idx
                                }
                            }
                        )
                    }
                    hashtags
                    if let error = model.errorMessage {
                        ErrorStateView(title: "Feed indisponible", message: error) {
                            Task { await model.load() }
                        }
                    }
                    ForEach(model.page?.items ?? []) { item in
                        FeedItemCard(
                            item: item,
                            onTap: { presentedSheet = .detail(item) },
                            onLike: { model.react(item) },
                            onRepost: { model.repost(item) },
                            onComment: { presentedSheet = .comments(item) },
                            onFavorite: { model.favorite(item) },
                            onShare: { presentedSheet = .share(item) },
                            onAuthorTap: { profileAuthor = item.author }
                        )
                        .contextMenu {
                            Button { model.muteNotifications(item) } label: {
                                Label(item.notificationsMutedByMe == true ? "Réactiver notifs" : "Couper notifs",
                                      systemImage: item.notificationsMutedByMe == true ? "bell" : "bell.slash")
                            }
                            Button(role: .destructive) { presentedSheet = .report(item) } label: {
                                Label("Signaler", systemImage: "flag")
                            }
                        }
                        .sqFadeUp()
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
        .navigationTitle("Feed")
        .toolbarTitleLargeCompat()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    showExplore = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SQColor.brandRed)
                }
                .accessibilityLabel("Explorer")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    showComposer = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .signalQuestBackground()
        .task {
            if model.page == nil { await model.load() }
        }
        .refreshable { await model.load() }
        .navigationDestination(isPresented: $showExplore) {
            ExploreView(service: services.feed)
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(
                userId: author.id,
                prefill: author,
                hasActiveStory: (model.page?.stories.contains(where: { $0.author.id == author.id })) ?? false,
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
                commentsService: services.comments,
                reportsService: services.reports
            )
        }
        .onChangeCompat(of: router.openUserProfileId) { _, id in
            guard let id else { return }
            router.openUserProfileId = nil
            routedProfileId = id
        }
        .onChangeCompat(of: router.openPostId) { _, id in
            guard let id else { return }
            router.openPostId = nil
            // On privilégie l'item déjà chargé dans le feed, sinon on le récupère.
            if let existing = model.page?.items.first(where: { $0.id == id || $0.backendPostId == id }) {
                routedPostItem = RoutedPost(item: existing)
            } else {
                Task {
                    if let fetched = try? await services.feed.post(id: id) {
                        routedPostItem = RoutedPost(item: fetched)
                    }
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .detail(let item):
                SignalDetailSheet(
                    item: item,
                    onLike: { model.react(item) },
                    onRepost: { model.repost(item) },
                    onFavorite: { model.favorite(item) },
                    onComment: { presentedSheet = .comments(item) },
                    onShare: { presentedSheet = .share(item) },
                    onMute: { model.muteNotifications(item) },
                    onReport: { presentedSheet = .report(item) },
                    onAuthorTap: {
                        presentedSheet = nil
                        pushProfileAfterDismiss(item.author)
                    }
                )
            case .comments(let item):
                CommentsSheet(
                    service: services.comments,
                    postId: item.backendPostId,
                    onAuthorTap: { author in
                        presentedSheet = nil
                        pushProfileAfterDismiss(author)
                    }
                )
            case .report(let item):
                ReportSheet(targetType: "post", targetId: item.backendPostId, service: services.reports)
            case .share(let item):
                PostShareSheet(
                    post: item,
                    messagesService: services.messages,
                    onShare: { conversation in
                        await model.share(item, to: conversation)
                    }
                )
            case .stories:
                EmptyView()
            }
        }
        .fullScreenCover(item: Binding(
            get: { presentedStoryStart.map { _ in StoriesPresentation() } },
            set: { if $0 == nil { presentedStoryStart = nil } }
        )) { _ in
            if let stories = model.page?.stories, let start = presentedStoryStart {
                StoryViewer(stories: Array(stories[min(start, stories.count - 1)...]),
                            onMarkViewed: { story in
                                Task { try? await services.stories.markViewed(story.id) }
                            },
                            onAuthorTap: { story in
                                presentedStoryStart = nil
                                pushProfileAfterDismiss(story.author)
                            },
                            onSendReply: { story, text in
                                sendStoryReply(story, text: text)
                            })
            }
        }
        .sheet(isPresented: $showStoryComposer) {
            StoryComposer(service: services.stories)
        }
        .sheet(isPresented: $showComposer) {
            ComposerSheet(service: services.feed, userService: services.users)
                .onDisappear { Task { await model.load() } }
        }
    }

    /// Pousse le profil après la fermeture d'un sheet / fullScreenCover :
    /// un push immédiat pendant l'animation de dismiss serait avalé.
    private func pushProfileAfterDismiss(_ author: SocialFeedAuthor) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            profileAuthor = author
        }
    }

    /// Répondre / réagir à une story = message privé à l'auteur (façon Instagram).
    /// Il n'existe pas d'endpoint de réaction de story : on résout/crée la
    /// conversation directe puis on envoie le texte (ou l'emoji). En non-E2EE pour
    /// que la réponse parte sans déverrouillage de la messagerie.
    private func sendStoryReply(_ story: SocialStory, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let created = try await services.messages.createConversation(
                    participantIds: [story.author.id], title: nil, e2ee: false
                )
                let conversations = try await services.messages.conversations()
                guard let conversation = conversations.first(where: { $0.id == created.conversationId }) else { return }
                _ = try await services.messages.sendText(trimmed, in: conversation, replyToId: nil, e2ee: services.e2ee)
            } catch {
                // Best-effort : la confirmation « Envoyé » du viewer est optimiste.
            }
        }
    }

    private var hashtags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(model.page?.trendingHashtags ?? []) { tag in
                    let isOn = tag.tag == model.selectedHashtag
                    Button {
                        Haptics.selection()
                        model.selectedHashtag = isOn ? nil : tag.tag
                        Task { await model.load() }
                    } label: {
                        Text("#\(tag.tag)")
                            .font(SQFont.archivo(14, .bold))
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

private struct StoriesPresentation: Identifiable { let id = UUID() }

private struct PostShareSheet: View {
    let post: UnifiedSocialFeedItem
    let messagesService: MessagesServicing
    let onShare: (MessageConversation) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [MessageConversation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var busyConversationId: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(post.text)
                        .font(.footnote)
                        .lineLimit(3)
                        .foregroundStyle(SQColor.labelSecondary)
                } header: {
                    Text("Publication")
                }

                Section("Partager vers") {
                    if isLoading {
                        ProgressView()
                    }
                    ForEach(conversations) { conversation in
                        Button {
                            Task { await share(conversation) }
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: conversation.groupPhotoUrl ?? conversation.participants.first?.user.avatarUrl, name: conversation.displayTitle, size: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.displayTitle.isEmpty ? "Conversation" : conversation.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(SQColor.label)
                                    Text(conversation.e2eeEnabled == true ? "Chiffrée" : "Conversation")
                                        .font(.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                Spacer()
                                if busyConversationId == conversation.id {
                                    ProgressView().tint(SQColor.brandRed)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                        .foregroundStyle(SQColor.brandRed)
                                }
                            }
                        }
                        .disabled(busyConversationId != nil)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SQColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Partager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conversations = AppEnvironment.usesDemoData ? .demo : try await messagesService.conversations()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func share(_ conversation: MessageConversation) async {
        busyConversationId = conversation.id
        defer { busyConversationId = nil }
        if await onShare(conversation) {
            dismiss()
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
            {"id": "story-1", "author": {"id": "u1", "name": "Camille", "handle": "camille", "avatarUrl": null}, "text": "5G Paris", "mediaUrl": null, "thumbnailUrl": null, "mediaKind": "text", "background": null, "metadata": null, "visibility": "friends", "status": "active", "durationSeconds": 5, "createdAt": "2026-05-11T10:00:00.000Z", "expiresAt": null, "viewedByMe": false, "isMine": false},
            {"id": "story-2", "author": {"id": "u2", "name": "Nora", "handle": "nora", "avatarUrl": null}, "text": "Photo site", "mediaUrl": null, "thumbnailUrl": null, "mediaKind": "text", "background": null, "metadata": null, "visibility": "public", "status": "active", "durationSeconds": 5, "createdAt": "2026-05-11T10:00:00.000Z", "expiresAt": null, "viewedByMe": true, "isMine": false}
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
