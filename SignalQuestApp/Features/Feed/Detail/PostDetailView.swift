import SwiftUI

struct PostDetailView: View {
    let item: UnifiedSocialFeedItem
    let feedService: SocialFeedServicing
    let messagesService: MessagesServicing
    let commentsService: CommentsServicing
    let reportsService: ReportsServicing

    @State private var showSignalSheet = false
    @State private var showCommentsSheet = false
    @State private var showReportSheet = false
    @State private var showShareSheet = false
    @StateObject private var actions: PostDetailActions
    /// Auteur dont on pousse le profil public.
    @State private var profileAuthor: SocialFeedAuthor?

    init(
        item: UnifiedSocialFeedItem,
        feedService: SocialFeedServicing,
        messagesService: MessagesServicing,
        commentsService: CommentsServicing,
        reportsService: ReportsServicing,
        onItemChanged: @escaping @MainActor (UnifiedSocialFeedItem) -> Void = { _ in }
    ) {
        self.item = item
        self.feedService = feedService
        self.messagesService = messagesService
        self.commentsService = commentsService
        self.reportsService = reportsService
        _actions = StateObject(wrappedValue: PostDetailActions(
            item: item, service: feedService, onItemChanged: onItemChanged
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg + 2) {
                if let errorMessage = actions.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("post.detail.error")
                }
                if actions.isMutating {
                    ProgressView("En cours")
                        .tint(SQColor.brandRed)
                        .accessibilityIdentifier("post.detail.saving")
                }
                FeedItemCard(
                    item: actions.item,
                    onTap: { showSignalSheet = true },
                    onLike: { Task { await actions.mutate(.react) } },
                    onRepost: { Task { await actions.mutate(.repost) } },
                    onComment: { showCommentsSheet = true },
                    onFavorite: { Task { await actions.mutate(.favorite) } },
                    onShare: { showShareSheet = true },
                    onAuthorTap: { profileAuthor = actions.item.author }
                )
                GradientButton(
                    "Voir tous les commentaires (\(actions.item.commentsCount))",
                    systemImage: "bubble.left.and.bubble.right",
                    style: .secondary
                ) {
                    showCommentsSheet = true
                }
            }
            .padding(SQSpace.lg)
        }
        .signalQuestBackground()
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { showReportSheet = true } label: {
                        Label("Signaler", systemImage: "flag")
                    }
                } label: { Image(systemName: "ellipsis.circle").tint(SQColor.brandRed) }
                .accessibilityLabel("Plus d’options")
            }
        }
        .sheet(isPresented: $showSignalSheet) {
            SignalDetailSheet(item: actions.item,
                              onLike: { Task { await actions.mutate(.react) } },
                              onRepost: { Task { await actions.mutate(.repost) } },
                              onFavorite: { Task { await actions.mutate(.favorite) } },
                              onComment: { showCommentsSheet = true },
                              onShare: {
                                  showSignalSheet = false
                                  Task { @MainActor in
                                      try? await Task.sleep(nanoseconds: 380_000_000)
                                      showShareSheet = true
                                  }
                              },
                              onMute: { Task { try? await feedService.muteNotifications(postId: actions.item.id) } },
                              onReport: { showReportSheet = true },
                              onAuthorTap: {
                                  showSignalSheet = false
                                  pushProfileAfterDismiss(actions.item.author)
                              },
                              actionError: actions.errorMessage,
                              actionBusy: actions.isMutating)
        }
        .sheet(isPresented: $showCommentsSheet) {
            CommentsSheet(
                service: commentsService,
                postId: actions.item.backendPostId,
                profileService: feedService
            )
        }
        .sheet(isPresented: $showShareSheet) {
            PostShareSheet(post: actions.item, messagesService: messagesService) { conversation in
                await actions.share(to: conversation.id)
            }
        }
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(target: .post(actions.item.backendPostId), service: reportsService)
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: feedService)
        }
    }

    /// Pousse le profil après la fermeture du sheet (un push immédiat
    /// pendant l'animation de dismiss serait avalé).
    private func pushProfileAfterDismiss(_ author: SocialFeedAuthor) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            profileAuthor = author
        }
    }

}

/// Même état pour le détail ouvert depuis le fil, une notification ou un message.
/// Un seul appel de mutation à la fois ; les compteurs changent sur reçu serveur.
@MainActor
final class PostDetailActions: ObservableObject {
    enum Mutation { case react, repost, favorite }

    @Published private(set) var item: UnifiedSocialFeedItem
    @Published private(set) var isMutating = false
    @Published private(set) var errorMessage: String?

    private let react: @MainActor (String) async throws -> ReactionResponse
    private let repost: @MainActor (String) async throws -> ReactionResponse
    private let favorite: @MainActor (String) async throws -> ReactionResponse
    private let sendShare: @MainActor (String, String) async throws -> String?
    private let onItemChanged: @MainActor (UnifiedSocialFeedItem) -> Void

    convenience init(
        item: UnifiedSocialFeedItem,
        service: SocialFeedServicing,
        onItemChanged: @escaping @MainActor (UnifiedSocialFeedItem) -> Void = { _ in }
    ) {
        self.init(
            item: item,
            react: { try await service.react(postId: $0, emoji: "❤️") },
            repost: { try await service.repost(postId: $0) },
            favorite: { try await service.favorite(postId: $0) },
            share: { try await service.share(postId: $0, conversationId: $1) },
            onItemChanged: onItemChanged
        )
    }

    init(
        item: UnifiedSocialFeedItem,
        react: @escaping @MainActor (String) async throws -> ReactionResponse,
        repost: @escaping @MainActor (String) async throws -> ReactionResponse,
        favorite: @escaping @MainActor (String) async throws -> ReactionResponse,
        share: @escaping @MainActor (String, String) async throws -> String?,
        onItemChanged: @escaping @MainActor (UnifiedSocialFeedItem) -> Void = { _ in }
    ) {
        self.item = item
        self.react = react
        self.repost = repost
        self.favorite = favorite
        self.sendShare = share
        self.onItemChanged = onItemChanged
    }

    func mutate(_ action: Mutation) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            let response: ReactionResponse
            switch action {
            case .react: response = try await react(item.id)
            case .repost: response = try await repost(item.id)
            case .favorite: response = try await favorite(item.id)
            }
            item = item.applying(response)
            onItemChanged(item)
            Haptics.success()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = String(localized: "Une erreur est survenue. Réessaie.")
            Haptics.error()
        }
    }

    func share(to conversationID: String) async -> String? {
        do {
            guard let messageID = try await sendShare(item.id, conversationID), !messageID.isEmpty else {
                return nil
            }
            Haptics.success()
            return messageID
        } catch {
            if !error.isCancellation { Haptics.error() }
            return nil
        }
    }
}

extension UnifiedSocialFeedItem {
    /// Projette uniquement les interactions validées, sans écraser un commentaire
    /// ou un autre champ plus récent déjà présent dans le fil ou le message.
    func adoptingInteractions(from detail: Self) -> Self {
        var updated = self
        updated.reactions = detail.reactions
        updated.likedByMe = detail.likedByMe
        updated.favoritedByMe = detail.favoritedByMe
        updated.favoritesCount = detail.favoritesCount
        updated.repostedByMe = detail.repostedByMe
        updated.repostsCount = detail.repostsCount
        return updated
    }

    func applying(_ response: ReactionResponse) -> Self {
        var updated = self
        if let reactions = response.reactions {
            updated.reactions = reactions
            updated.likedByMe = reactions.first(where: { $0.emoji == "❤️" })?.reactedByMe ?? false
        }
        if let favorited = response.favorited { updated.favoritedByMe = favorited }
        if let favoritesCount = response.favoritesCount { updated.favoritesCount = favoritesCount }
        if let reposted = response.reposted { updated.repostedByMe = reposted }
        if let repostsCount = response.repostsCount { updated.repostsCount = repostsCount }
        return updated
    }
}
