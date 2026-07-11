import SwiftUI
import CoreLocation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var page: SocialFeedPage?
    @Published var selectedHashtag: String?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    /// Pouls réseau (héro) — nil tant qu'aucune donnée / position n'est disponible.
    @Published var pulse: NetworkPulse?

    private let service: SocialFeedServicing
    private let storiesService: StoriesServicing?
    private let location: LocationService?

    init(service: SocialFeedServicing, storiesService: StoriesServicing? = nil, location: LocationService? = nil) {
        self.service = service
        self.storiesService = storiesService
        self.location = location
    }

    /// Charge le pouls réseau autour de la position courante. Ne déclenche JAMAIS
    /// de prompt de localisation depuis le feed : on ne l'interroge que si
    /// l'autorisation est déjà accordée ou qu'une position est déjà connue. Échec
    /// silencieux : le héro disparaît simplement.
    func loadPulse() async {
        if AppEnvironment.usesDemoData { pulse = .demo; return }
        guard let location else { return }
        let status = location.authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        guard authorized || location.lastLocation != nil else { return }
        guard let coordinate = await location.currentLocation()?.coordinate else { return }
        do {
            let result = try await service.networkPulse(latitude: coordinate.latitude, longitude: coordinate.longitude)
            pulse = result.hasData ? result : nil
        } catch {
            // Silencieux : le héro n'est simplement pas affiché.
        }
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

    /// Pagination ascendante du fil (FEED-FUNC-01) : charge la page suivante via
    /// `nextCursor` et append en dédoublonnant par id. Déclenchée à l'apparition de
    /// la dernière carte. Le `refreshable` reste un reset complet (`load`).
    func loadMore() async {
        guard !isLoading, !isLoadingMore,
              let current = page,
              let cursor = current.nextCursor, !cursor.isEmpty else { return }
        if AppEnvironment.usesDemoData { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await service.loadFeed(cursor: cursor, hashtag: selectedHashtag)
            var seen = Set(current.items.map { $0.id })
            let appended = next.items.filter { seen.insert($0.id).inserted }
            page = SocialFeedPage(
                items: current.items + appended,
                nextCursor: next.nextCursor,
                stories: current.stories,
                trendingHashtags: current.trendingHashtags,
                suggestedUsers: current.suggestedUsers,
                requestId: next.requestId ?? current.requestId
            )
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

    /// Partage le post ; renvoie l'id du message créé (pour l'annulation), nil si échec.
    func share(_ item: UnifiedSocialFeedItem, to conversation: MessageConversation) async -> String? {
        do {
            let messageId = try await service.share(postId: item.id, conversationId: conversation.id)
            Haptics.success()
            return messageId
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            Haptics.error()
            return nil
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
    @State private var showMessages = false
    /// Auteur dont on pousse le profil public (cards, commentaires, stories…).
    @State private var profileAuthor: SocialFeedAuthor?
    /// Profil demandé par notification (follow) via AppRouter — par id seul.
    @State private var routedProfileId: String?
    /// Post ouvert via deep-link / notification (résolu en item complet).
    @State private var routedPostItem: RoutedPost?
    /// Partage réussi en attente d'annulation (pilule éphémère en bas du feed).
    @State private var shareUndo: ShareUndoState?

    private struct ShareUndoState: Identifiable {
        let id = UUID()
        let messageId: String
        let conversationTitle: String
    }

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

    init(service: SocialFeedServicing = SocialFeedService(api: APIClient()), location: LocationService? = nil) {
        _model = StateObject(wrappedValue: FeedViewModel(service: service, location: location))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SQSpace.lg) {
                header

                if model.isLoading && model.page == nil {
                    LoadingSkeleton()
                        .sqShimmer()
                } else {
                    if let pulse = model.pulse {
                        NetworkPulseHero(pulse: pulse)
                            .sqFadeUp()
                    }
                    // Rail visible dès que la page est chargée, même sans story
                    // amie (fidèle au prototype : « Ta story » reste le point
                    // d'entrée de création).
                    if let stories = model.page?.stories {
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
                        // Rail débordant : annule le padding écran pour que le
                        // scroll fuie sous les bords (1re bulle alignée à 20 pt).
                        .padding(.horizontal, -SQSpace.lg)
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
                            onAuthorTap: { profileAuthor = item.author },
                            onReact: { emoji in model.react(item, emoji: emoji) }
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
                        .onAppear {
                            if item.id == model.page?.items.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView().tint(SQColor.brandRed); Spacer() }
                            .padding(.vertical, SQSpace.md)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
        }
        // Directement sur le ScrollView (avant le ZStack de signalQuestBackground).
        .sqDockAutoMinimize()
        .overlay(alignment: .bottom) { shareUndoPill }
        // Header custom (DA Crème) : plus de gros titre nav système.
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .task {
            if model.page == nil { await model.load() }
            await model.loadPulse()
            await consumeFeedRoutesIfNeeded()
            presentMessagesIfNeeded()
        }
        .refreshable {
            await model.load()
            await model.loadPulse()
        }
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
        .onChangeCompat(of: router.openUserProfileId) { _, _ in
            Task { await consumeFeedRoutesIfNeeded() }
        }
        .onChangeCompat(of: router.openPostId) { _, _ in
            Task { await consumeFeedRoutesIfNeeded() }
        }
        .onChangeCompat(of: router.openConversationId) { _, conversationId in
            if conversationId != nil { showMessages = true }
        }
        .onChangeCompat(of: router.openMessagesInbox) { _, shouldOpen in
            if shouldOpen { presentMessagesIfNeeded() }
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
                    },
                    onShared: { messageId, conversation in
                        presentShareUndo(messageId: messageId, conversation: conversation)
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
                            },
                            onDelete: { story in
                                Task {
                                    try? await services.stories.delete(story.id)
                                    await model.load()
                                }
                            },
                            viewersProvider: { story in
                                (try? await services.stories.viewers(storyId: story.id)) ?? []
                            })
            }
        }
        .sheet(isPresented: $showStoryComposer) {
            StoryComposer(service: services.stories, friendsService: services.friends)
        }
        .sheet(isPresented: $showComposer) {
            ComposerSheet(service: services.feed, userService: services.users)
                .onDisappear { Task { await model.load() } }
        }
    }

    // MARK: Annulation d'un partage

    private func presentShareUndo(messageId: String, conversation: MessageConversation) {
        let title = conversation.displayTitle.isEmpty ? "la conversation" : conversation.displayTitle
        let state = ShareUndoState(messageId: messageId, conversationTitle: title)
        withAnimation(SQMotion.snappy) { shareUndo = state }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if shareUndo?.id == state.id { withAnimation(SQMotion.snappy) { shareUndo = nil } }
            }
        }
    }

    private func undoShare(_ state: ShareUndoState) {
        withAnimation(SQMotion.snappy) { shareUndo = nil }
        Task {
            try? await services.messages.deleteMessage(messageId: state.messageId, forEveryone: true)
            await MainActor.run { Haptics.success() }
        }
    }

    /// Pilule éphémère « Partagé · Annuler » (parité pilule Android). Le message
    /// partagé est supprimé côté serveur si l'utilisateur annule.
    @ViewBuilder
    private var shareUndoPill: some View {
        if let state = shareUndo {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SQColor.success)
                    .accessibilityHidden(true)
                Text("Partagé vers \(state.conversationTitle)")
                    .font(SQType.caption.weight(.medium))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Spacer(minLength: SQSpace.sm)
                Button("Annuler") { undoShare(state) }
                    .font(SQType.caption.weight(.bold))
                    .tint(SQColor.brandRed)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 2)
            .background(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowDock()
            .padding(.horizontal, SQSpace.xl)
            .padding(.bottom, SQSpace.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Consomme les routes de notification Feed (profil/post) — appelé au montage
    /// (.task) ET sur changement du routeur, pour ne pas perdre une route au lancement
    /// à froid (NAV-BUG-01).
    private func consumeFeedRoutesIfNeeded() async {
        if let id = router.openUserProfileId {
            router.openUserProfileId = nil
            routedProfileId = id
        }
        if let id = router.openPostId {
            router.openPostId = nil
            if let existing = model.page?.items.first(where: { $0.id == id || $0.backendPostId == id }) {
                routedPostItem = RoutedPost(item: existing)
            } else if let fetched = try? await services.feed.post(id: id) {
                routedPostItem = RoutedPost(item: fetched)
            }
        }
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
                _ = try await services.messages.sendText(trimmed, in: conversation, replyToId: nil, e2ee: services.e2ee, idempotencyKey: nil, ttlSeconds: 0)
            } catch {
                // Best-effort : la confirmation « Envoyé » du viewer est optimiste.
            }
        }
    }

    // MARK: Header custom — titre display + boutons circulaires

    private var header: some View {
        HStack(spacing: SQSpace.sm + 2) {
            Text("Communauté")
                .font(SQFont.display(26, .bold))
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SQSpace.sm)
            headerButton(systemImage: "bubble.left.and.bubble.right", label: "Messages") {
                showMessages = true
            } decoration: {
                if services.unreadConversations > 0 {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 10, height: 10)
                        .padding(2)
                        .background(SQColor.surface, in: Circle())
                        .offset(x: 1, y: -1)
                }
            }
            .accessibilityValue(services.unreadConversations == 0
                                ? "Aucun message non lu"
                                : "\(services.unreadConversations) conversations non lues")
            headerButton(systemImage: "magnifyingglass", label: "Explorer") {
                showExplore = true
            }
            headerButton(systemImage: "square.and.pencil", label: "Créer une publication") {
                showComposer = true
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Bouton circulaire d'en-tête 42 pt : fond surface + ombre douce, icône
    /// encre ; `decoration` pose le point « non-lus » au-dessus du cercle.
    private func headerButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        headerButton(systemImage: systemImage, label: label, action: action) { EmptyView() }
    }

    private func headerButton<Decoration: View>(
        systemImage: String,
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder decoration: () -> Decoration
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 42, height: 42)
                .background(SQColor.surface, in: Circle())
                .sqShadowSoft()
                .overlay(alignment: .topTrailing) { decoration() }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Hashtags — capsules pleines/douces

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
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, SQSpace.md + 1)
                            .padding(.vertical, SQSpace.sm)
                            .background(
                                isOn ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(isOn ? SQColor.onAccent : SQColor.label)
                            .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.xs)
        }
        // Déborde du padding écran pour ne pas rogner les ombres au scroll.
        .padding(.horizontal, -SQSpace.xl)
    }
}

private struct StoriesPresentation: Identifiable { let id = UUID() }

private struct PostShareSheet: View {
    let post: UnifiedSocialFeedItem
    let messagesService: MessagesServicing
    /// Renvoie l'id du message créé (succès) ou nil (échec).
    let onShare: (MessageConversation) async -> String?
    /// Appelé après un partage réussi, pour proposer l'annulation côté feed.
    var onShared: (String, MessageConversation) -> Void = { _, _ in }

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
                                        .accessibilityHidden(true)
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
        if let messageId = await onShare(conversation) {
            onShared(messageId, conversation)
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
