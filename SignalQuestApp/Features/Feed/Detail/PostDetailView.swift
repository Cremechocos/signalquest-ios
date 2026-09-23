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
    @State private var localItem: UnifiedSocialFeedItem
    @State private var isMutating = false
    @State private var errorMessage: String?
    /// Auteur dont on pousse le profil public.
    @State private var profileAuthor: SocialFeedAuthor?

    init(
        item: UnifiedSocialFeedItem,
        feedService: SocialFeedServicing,
        messagesService: MessagesServicing,
        commentsService: CommentsServicing,
        reportsService: ReportsServicing
    ) {
        self.item = item
        self.feedService = feedService
        self.messagesService = messagesService
        self.commentsService = commentsService
        self.reportsService = reportsService
        _localItem = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg + 2) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("post.detail.error")
                }
                if isMutating {
                    ProgressView("En cours")
                        .tint(SQColor.brandRed)
                        .accessibilityIdentifier("post.detail.saving")
                }
                FeedItemCard(
                    item: localItem,
                    onTap: { showSignalSheet = true },
                    onLike: { Task { await mutate(.react) } },
                    onRepost: { Task { await mutate(.repost) } },
                    onComment: { showCommentsSheet = true },
                    onFavorite: { Task { await mutate(.favorite) } },
                    onShare: { showShareSheet = true },
                    onAuthorTap: { profileAuthor = localItem.author }
                )
                GradientButton(
                    "Voir tous les commentaires (\(localItem.commentsCount))",
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
            SignalDetailSheet(item: localItem,
                              onLike: { Task { await mutate(.react) } },
                              onRepost: { Task { await mutate(.repost) } },
                              onFavorite: { Task { await mutate(.favorite) } },
                              onComment: { showCommentsSheet = true },
                              onShare: {
                                  showSignalSheet = false
                                  Task { @MainActor in
                                      try? await Task.sleep(nanoseconds: 380_000_000)
                                      showShareSheet = true
                                  }
                              },
                              onMute: { Task { try? await feedService.muteNotifications(postId: localItem.id) } },
                              onReport: { showReportSheet = true },
                              onAuthorTap: {
                                  showSignalSheet = false
                                  pushProfileAfterDismiss(localItem.author)
                              },
                              actionError: errorMessage,
                              actionBusy: isMutating)
        }
        .sheet(isPresented: $showCommentsSheet) {
            CommentsSheet(
                service: commentsService,
                postId: localItem.backendPostId,
                onAuthorTap: { author in
                    showCommentsSheet = false
                    pushProfileAfterDismiss(author)
                }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            PostShareSheet(post: localItem, messagesService: messagesService) { conversation in
                do {
                    let messageID = try await feedService.share(
                        postId: localItem.id, conversationId: conversation.id)
                    if messageID != nil { Haptics.success() }
                    return messageID
                } catch {
                    return nil
                }
            }
        }
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(target: .post(localItem.backendPostId), service: reportsService)
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

    private enum Mutation { case react, repost, favorite }

    private func mutate(_ action: Mutation) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            let response: ReactionResponse
            switch action {
            case .react: response = try await feedService.react(postId: localItem.id, emoji: "❤️")
            case .repost: response = try await feedService.repost(postId: localItem.id)
            case .favorite: response = try await feedService.favorite(postId: localItem.id)
            }
            localItem = localItem.applying(response)
            Haptics.success()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = String(localized: "Une erreur est survenue. Réessaie.")
            Haptics.error()
        }
    }
}

extension UnifiedSocialFeedItem {
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
