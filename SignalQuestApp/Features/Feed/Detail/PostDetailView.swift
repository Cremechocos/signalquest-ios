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
    /// Publication ouverte dans le composer (auteur uniquement).
    @State private var editingPost: UnifiedSocialFeedItem?
    @State private var confirmsDeletion = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
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
            VStack(spacing: SQSpace.cardPadding) {
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
                    onAuthorTap: { profileAuthor = actions.item.author },
                    // Sans ce vote, le sondage disparaissait du détail (AF-FIL-06).
                    onPollVote: { option in Task { await vote(option) } }
                )
                GradientButton(
                    String(localized: "Voir tous les commentaires (\(actions.item.commentsCount))"),
                    systemImage: "bubble.left.and.bubble.right",
                    style: .secondary
                ) {
                    showCommentsSheet = true
                }
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle("Publication")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Réservé à l'auteur, comme dans le fil : le serveur revérifie.
                    if actions.item.canManage {
                        Button { editingPost = actions.item } label: {
                            Label("Modifier", systemImage: "pencil")
                        }
                        Button { Task { await togglePin() } } label: {
                            Label(actions.item.isPinned ? "Désépingler" : "Épingler",
                                  systemImage: actions.item.isPinned ? "pin.slash" : "pin")
                        }
                        Button(role: .destructive) { confirmsDeletion = true } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                    // On ne signale pas sa propre publication ; la sourdine, elle,
                    // reste proposée comme dans la feuille de détail.
                    if !actions.item.canManage {
                        Button(role: .destructive) { showReportSheet = true } label: {
                            Label("Signaler", systemImage: "flag")
                        }
                    }
                    Button { Task { await toggleMute() } } label: {
                        Label(
                            actions.item.notificationsMutedByMe == true ? "Réactiver les notifications" : "Couper les notifications",
                            systemImage: actions.item.notificationsMutedByMe == true ? "bell" : "bell.slash"
                        )
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
                              // Fermer, attendre, puis présenter : ouverte pendant la
                              // fermeture de la fiche, la feuille était avalée (AF-FIL-02).
                              onComment: {
                                  showSignalSheet = false
                                  Task { @MainActor in
                                      try? await Task.sleep(nanoseconds: 380_000_000)
                                      showCommentsSheet = true
                                  }
                              },
                              onShare: {
                                  showSignalSheet = false
                                  Task { @MainActor in
                                      try? await Task.sleep(nanoseconds: 380_000_000)
                                      showShareSheet = true
                                  }
                              },
                              onMute: { Task { await toggleMute() } },
                              onReport: {
                                  showSignalSheet = false
                                  Task { @MainActor in
                                      try? await Task.sleep(nanoseconds: 380_000_000)
                                      showReportSheet = true
                                  }
                              },
                              onPollVote: { option in Task { await vote(option) } },
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
                profileService: feedService,
                reports: reportsService,
                commentsCount: actions.item.commentsCount,
                // Le compteur du bouton « Voir tous les commentaires » suit les nouveaux commentaires.
                onCommentPosted: { actions.update { $0.commentsCount += 1 } }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            PostShareSheet(
                post: actions.item,
                messagesService: messagesService,
                onShare: { conversation in await actions.share(to: conversation.id) },
                onShared: { messageId, conversation in presentShareUndo(messageId: messageId, conversation: conversation) }
            )
        }
        .sheet(item: $editingPost) { post in
            ComposerSheet(service: feedService, editing: post)
                .onDisappear { Task { await reloadAfterEdit() } }
        }
        .confirmationDialog(
            "Supprimer cette publication ?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) { Task { await deletePost() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible.")
        }
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(target: .post(actions.item.backendPostId), service: reportsService)
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: feedService)
        }
    }

    /// Vote (ou retrait de vote) sur le sondage ; l'échec remonte à l'écran
    /// au lieu d'être avalé.
    private func vote(_ option: FeedPoll.Option) async {
        guard actions.item.poll?.isOpen == true else { return }
        do {
            if let poll = try await feedService.votePoll(
                postId: actions.item.id, optionId: option.id, removing: option.votedByMe
            ) {
                actions.applyPoll(poll)
            }
        } catch {
            if !error.isCancellation { actions.fail(error) }
        }
    }

    /// Épingle ou détache. Le serveur n'en garde qu'un par auteur : le fil se
    /// recharge à la fermeture du détail, il corrige l'autre publication.
    private func togglePin() async {
        let willPin = !actions.item.isPinned
        do {
            try await feedService.setPinned(postId: actions.item.id, pinned: willPin)
            actions.update { $0.pinnedAt = willPin ? Date() : nil }
        } catch {
            if !error.isCancellation { actions.fail(error) }
        }
    }

    private func deletePost() async {
        do {
            try await feedService.deletePost(postId: actions.item.id)
            Haptics.success()
            dismiss()
        } catch {
            if !error.isCancellation { actions.fail(error) }
        }
    }

    private func toggleMute() async {
        do {
            _ = try await feedService.muteNotifications(postId: actions.item.id)
            actions.update { $0.notificationsMutedByMe = !($0.notificationsMutedByMe ?? false) }
        } catch {
            if !error.isCancellation { actions.fail(error) }
        }
    }

    /// Relit la publication après l'éditeur : le texte modifié remplace l'ancien.
    private func reloadAfterEdit() async {
        guard let fresh = try? await feedService.post(id: actions.item.id) else { return }
        actions.update { $0 = fresh }
    }

    /// Même proposition d'annulation que dans le fil, juste après un partage.
    private func presentShareUndo(messageId: String, conversation: MessageConversation) {
        let title = conversation.displayTitle.isEmpty ? String(localized: "la conversation") : conversation.displayTitle
        inAppNotifications.showUndo(
            body: String(localized: "Partagé vers \(title)"),
            actionLabel: String(localized: "Annuler")
        ) {
            Task {
                do {
                    try await messagesService.deleteMessage(messageId: messageId, forEveryone: true)
                    Haptics.success()
                } catch {
                    inAppNotifications.showError(String(localized: "Impossible d’annuler le partage. Réessaie."))
                }
            }
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
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Applique un changement local confirmé (épinglage, commentaire, relecture) et prévient le fil d'origine.
    func update(_ change: (inout UnifiedSocialFeedItem) -> Void) {
        var copy = item
        change(&copy)
        item = copy
        onItemChanged(copy)
    }

    /// Remonte l'échec d'une action menée hors de `mutate`.
    func fail(_ error: Error) {
        errorMessage = error.userFacingMessage
        Haptics.error()
    }

    /// Sondage relu après un vote : la carte et le fil d'origine suivent.
    func applyPoll(_ poll: FeedPoll) {
        var copy = item
        copy.poll = poll
        item = copy
        onItemChanged(item)
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
