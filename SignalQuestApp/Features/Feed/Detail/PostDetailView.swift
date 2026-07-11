import SwiftUI

struct PostDetailView: View {
    let item: UnifiedSocialFeedItem
    let feedService: SocialFeedServicing
    let commentsService: CommentsServicing
    let reportsService: ReportsServicing

    @State private var showSignalSheet = false
    @State private var showCommentsSheet = false
    @State private var showReportSheet = false
    @State private var localItem: UnifiedSocialFeedItem
    /// Auteur dont on pousse le profil public.
    @State private var profileAuthor: SocialFeedAuthor?

    init(
        item: UnifiedSocialFeedItem,
        feedService: SocialFeedServicing,
        commentsService: CommentsServicing,
        reportsService: ReportsServicing
    ) {
        self.item = item
        self.feedService = feedService
        self.commentsService = commentsService
        self.reportsService = reportsService
        _localItem = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg + 2) {
                FeedItemCard(
                    item: localItem,
                    onTap: { showSignalSheet = true },
                    onLike: { Task { await react() } },
                    onRepost: { Task { await repost() } },
                    onComment: { showCommentsSheet = true },
                    onFavorite: { Task { await favorite() } },
                    onShare: { /* PR4: share to conversation */ },
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
                              onLike: { Task { await react() } },
                              onRepost: { Task { await repost() } },
                              onFavorite: { Task { await favorite() } },
                              onComment: { showCommentsSheet = true },
                              onShare: {},
                              onMute: { Task { try? await feedService.muteNotifications(postId: localItem.id) } },
                              onReport: { showReportSheet = true },
                              onAuthorTap: {
                                  showSignalSheet = false
                                  pushProfileAfterDismiss(localItem.author)
                              })
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
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(targetType: "post", targetId: localItem.backendPostId, service: reportsService)
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

    private func react() async {
        _ = try? await feedService.react(postId: localItem.id, emoji: "❤️")
        Haptics.light()
    }
    private func repost() async {
        _ = try? await feedService.repost(postId: localItem.id)
        Haptics.medium()
    }
    private func favorite() async {
        _ = try? await feedService.favorite(postId: localItem.id)
        Haptics.light()
    }
}
