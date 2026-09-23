import SwiftUI

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published var comments: [SocialComment] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasLoaded = false
    @Published var nextCursor: String?
    @Published var paginationErrorMessage: String?
    @Published var errorMessage: String?
    @Published var draft: String = ""
    @Published var isSending = false
    @Published var replyTo: SocialComment?
    @Published var expandedParentIDs: Set<String> = []
    @Published var repliesByParent: [String: ReplyPage] = [:]

    struct ReplyPage {
        var comments: [SocialComment] = []
        var sentComments: [SocialComment] = []
        var nextCursor: String?
        var isLoading = false
        var hasLoaded = false
        var errorMessage: String?
    }

    private let service: CommentsServicing
    private let postId: String
    private var listGeneration = UUID()
    private var replyGenerations: [String: UUID] = [:]

    init(service: CommentsServicing, postId: String) {
        self.service = service
        self.postId = postId
    }

    func load() async {
        let generation = UUID()
        listGeneration = generation
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        paginationErrorMessage = nil
        nextCursor = nil
        defer { if listGeneration == generation { isLoading = false } }
        do {
            let page = try await service.list(postId: postId, cursor: nil)
            guard listGeneration == generation else { return }
            comments = page.comments
            nextCursor = page.nextCursor
            hasLoaded = true
        } catch {
            guard listGeneration == generation, !error.isCancellation else { return }
            errorMessage = String(localized: "Impossible de charger les commentaires.")
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        let generation = listGeneration
        isLoadingMore = true
        paginationErrorMessage = nil
        defer { if listGeneration == generation { isLoadingMore = false } }
        do {
            let page = try await service.list(postId: postId, cursor: cursor)
            guard listGeneration == generation, nextCursor == cursor else { return }
            var seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { seen.insert($0.id).inserted })
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
        } catch {
            guard listGeneration == generation, !error.isCancellation else { return }
            paginationErrorMessage = String(localized: "Impossible de charger les commentaires.")
        }
    }

    func toggleReplies(for parent: SocialComment) async {
        if expandedParentIDs.contains(parent.id) {
            expandedParentIDs.remove(parent.id)
            return
        }
        expandedParentIDs.insert(parent.id)
        if repliesByParent[parent.id]?.hasLoaded != true {
            await loadReplies(for: parent.id, cursor: nil)
        }
    }

    func loadMoreReplies(for parentID: String) async {
        guard let page = repliesByParent[parentID], let cursor = page.nextCursor,
              !page.isLoading else { return }
        await loadReplies(for: parentID, cursor: cursor)
    }

    func retryReplies(for parentID: String) async {
        let page = repliesByParent[parentID]
        await loadReplies(for: parentID, cursor: page?.hasLoaded == true ? page?.nextCursor : nil)
    }

    private func loadReplies(for parentID: String, cursor: String?) async {
        var current = repliesByParent[parentID] ?? ReplyPage()
        guard !current.isLoading else { return }
        let generation = UUID()
        replyGenerations[parentID] = generation
        current.isLoading = true
        current.errorMessage = nil
        repliesByParent[parentID] = current
        defer {
            if replyGenerations[parentID] == generation {
                var settled = repliesByParent[parentID] ?? ReplyPage()
                settled.isLoading = false
                repliesByParent[parentID] = settled
            }
        }
        do {
            let response = try await service.replies(postId: postId, commentId: parentID, cursor: cursor)
            guard replyGenerations[parentID] == generation else { return }
            var updated = repliesByParent[parentID] ?? ReplyPage()
            if cursor == nil {
                updated.comments = response.comments
            } else {
                var seen = Set(updated.comments.map(\.id))
                updated.comments.append(contentsOf: response.comments.filter { seen.insert($0.id).inserted })
            }
            let fetchedIDs = Set(updated.comments.map(\.id))
            updated.sentComments.removeAll { fetchedIDs.contains($0.id) }
            updated.nextCursor = response.nextCursor == cursor ? nil : response.nextCursor
            updated.hasLoaded = true
            repliesByParent[parentID] = updated
        } catch {
            guard replyGenerations[parentID] == generation, !error.isCancellation else { return }
            var failed = repliesByParent[parentID] ?? ReplyPage()
            failed.errorMessage = String(localized: "Impossible de charger les commentaires.")
            repliesByParent[parentID] = failed
        }
    }

    func send() async {
        let submittedDraft = draft
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        let parentID = replyTo?.id
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let comment = try await service.add(postId: postId, text: text, parentId: parentID)
            withAnimation(SQMotion.bouncy) {
                if let parentID {
                    var page = repliesByParent[parentID] ?? ReplyPage()
                    if !page.comments.contains(where: { $0.id == comment.id }),
                       !page.sentComments.contains(where: { $0.id == comment.id }) {
                        page.sentComments.append(comment)
                    }
                    repliesByParent[parentID] = page
                    expandedParentIDs.insert(parentID)
                } else if !comments.contains(where: { $0.id == comment.id }) {
                    comments.insert(comment, at: 0)
                    hasLoaded = true
                }
            }
            if draft == submittedDraft && replyTo?.id == parentID {
                draft = ""
                replyTo = nil
            }
            Haptics.success()
            if let parentID, repliesByParent[parentID]?.hasLoaded != true {
                Task { await loadReplies(for: parentID, cursor: nil) }
            }
        } catch {
            guard !error.isCancellation else { return }
            if draft == submittedDraft && replyTo?.id == parentID {
                errorMessage = String(localized: "Échec de l'envoi. Réessaie.")
                Haptics.error()
            }
        }
    }

    func beginReply(to comment: SocialComment) { replyTo = comment }
    func cancelReply() { replyTo = nil }

    /// Like/unlike optimiste d'un commentaire : bascule immédiate de l'état local
    /// puis réconciliation avec la réponse serveur (rollback en cas d'échec).
    /// Même pattern que `FeedViewModel.react`.
    func toggleLike(_ comment: SocialComment) {
        let wasLiked = comment.likedByMe == true
        let previousCount = comment.likes ?? 0
        guard updateComment(comment.id, liked: !wasLiked,
            count: max(0, previousCount + (wasLiked ? -1 : 1))) else { return }
        Haptics.light()
        Task {
            do {
                let response = wasLiked
                    ? try await service.unlike(postId: postId, commentId: comment.id)
                    : try await service.like(postId: postId, commentId: comment.id)
                _ = updateComment(comment.id, liked: response.liked, count: response.count)
            } catch {
                guard !error.isCancellation else { return }
                _ = updateComment(comment.id, liked: wasLiked, count: previousCount)
            }
        }
    }

    @discardableResult
    private func updateComment(_ id: String, liked: Bool, count: Int) -> Bool {
        if let index = comments.firstIndex(where: { $0.id == id }) {
            comments[index].likedByMe = liked
            comments[index].likes = count
            return true
        }
        for parentID in Array(repliesByParent.keys) {
            guard var page = repliesByParent[parentID],
                  page.comments.contains(where: { $0.id == id })
                    || page.sentComments.contains(where: { $0.id == id }) else { continue }
            if let index = page.comments.firstIndex(where: { $0.id == id }) {
                page.comments[index].likedByMe = liked
                page.comments[index].likes = count
            }
            if let index = page.sentComments.firstIndex(where: { $0.id == id }) {
                page.sentComments[index].likedByMe = liked
                page.sentComments[index].likes = count
            }
            repliesByParent[parentID] = page
            return true
        }
        return false
    }
}

struct CommentsSheet: View {
    @StateObject private var model: CommentsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Navigation vers le profil de l'auteur d'un commentaire (gérée par le parent).
    private let onAuthorTap: ((SocialFeedAuthor) -> Void)?

    init(service: CommentsServicing, postId: String, onAuthorTap: ((SocialFeedAuthor) -> Void)? = nil) {
        _model = StateObject(wrappedValue: CommentsViewModel(service: service, postId: postId))
        self.onAuthorTap = onAuthorTap
    }

    init(model: CommentsViewModel, onAuthorTap: ((SocialFeedAuthor) -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.onAuthorTap = onAuthorTap
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader
                content
                if let error = model.errorMessage, model.hasLoaded || !model.comments.isEmpty {
                    errorBanner(error)
                }
                composer
            }
            .sqAnimation(SQMotion.snappy, value: model.errorMessage)
            .signalQuestBackground()
            .navigationTitle("Commentaires")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task { await model.load() }
    }

    /// En-tête « Crème » : poignée seule, sans filet ni kicker (le titre est
    /// porté par la barre de navigation).
    private var sheetHeader: some View {
        SQSheetHandle()
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.comments.isEmpty {
            ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasLoaded, let error = model.errorMessage {
            VStack(spacing: SQSpace.md) {
                EmptyStateView(title: "Chargement impossible", message: error, systemImage: "wifi.exclamationmark")
                GradientButton("Réessayer", style: .secondary) { Task { await model.load() } }
                    .padding(.horizontal, SQSpace.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.comments.isEmpty {
            EmptyStateView(
                title: "Aucun commentaire",
                message: "Lance la conversation.",
                systemImage: "bubble.left"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                    ForEach(model.comments) { comment in
                        commentThread(comment)
                            .sqFadeUp()
                    }
                    if model.isLoadingMore {
                        ProgressView().tint(SQColor.brandRed)
                            .frame(maxWidth: .infinity)
                    } else if model.nextCursor != nil {
                        GradientButton(model.paginationErrorMessage == nil ? "Charger la suite" : "Réessayer", style: .secondary) {
                            Task { await model.loadMore() }
                        }
                        .accessibilityIdentifier("comments.loadMore")
                    }
                    if let error = model.paginationErrorMessage {
                        errorBanner(error)
                    }
                }
                .padding(SQSpace.lg)
                .sqReadableWidth(600)
            }
        }
    }

    private func commentThread(_ comment: SocialComment) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            commentRow(comment)
            HStack(spacing: SQSpace.lg) {
                Button("Répondre") { model.beginReply(to: comment) }
                    .frame(minHeight: 44)
                let page = model.repliesByParent[comment.id]
                let count = max(comment.repliesCount ?? 0,
                    (page?.comments.count ?? 0) + (page?.sentComments.count ?? 0))
                if count > 0 {
                    Button {
                        Task { await model.toggleReplies(for: comment) }
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            Text("Réponses")
                            Text(verbatim: "\(count)").monospacedDigit()
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("comments.replies.\(comment.id)")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .buttonStyle(.plain)
            .padding(.leading, 44)
            if model.expandedParentIDs.contains(comment.id) {
                replies(for: comment)
            }
        }
    }

    @ViewBuilder
    private func replies(for parent: SocialComment) -> some View {
        let page = model.repliesByParent[parent.id] ?? CommentsViewModel.ReplyPage()
        if page.isLoading && page.comments.isEmpty {
            ProgressView().tint(SQColor.brandRed).padding(.leading, SQSpace.xl)
        }
        ForEach(page.comments) { reply in
            commentRow(reply).padding(.leading, SQSpace.xl)
        }
        ForEach(page.sentComments) { reply in
            commentRow(reply).padding(.leading, SQSpace.xl)
        }
        if page.hasLoaded && page.comments.isEmpty && page.sentComments.isEmpty && page.errorMessage == nil {
            Text("Aucune réponse")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.leading, SQSpace.xl)
        }
        if page.nextCursor != nil && !page.isLoading && page.errorMessage == nil {
            Button("Charger la suite") { Task { await model.loadMoreReplies(for: parent.id) } }
                .padding(.leading, SQSpace.xl)
                .frame(minHeight: 44)
                .accessibilityIdentifier("comments.replies.loadMore.\(parent.id)")
        }
        if let error = page.errorMessage {
            errorBanner(error)
            Button("Réessayer") { Task { await model.retryReplies(for: parent.id) } }
                .padding(.leading, SQSpace.xl)
                .frame(minHeight: 44)
        }
    }

    /// Rangée « Crème » : avatar + bulle douce `SurfaceMuted` rayon 14, sans
    /// bordure ; le like se pose sous la bulle.
    private func commentRow(_ comment: SocialComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
            authorButton(comment) {
                SQAvatar(url: comment.author.avatarUrl, name: comment.author.displayName, size: 36)
            }
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    HStack {
                        authorButton(comment) {
                            Text(comment.author.displayName)
                                .font(SQFont.body(15, .semibold))
                                .foregroundStyle(SQColor.label)
                        }
                        Spacer()
                        if let created = comment.createdAt {
                            Text(created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Text(comment.text)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                }
                .padding(SQSpace.md)
                .background(
                    SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                )
                likeButton(comment)
                    .padding(.leading, SQSpace.xs)
            }
        }
    }

    /// Cœur toujours tappable (like/unlike) ; le compteur n'apparaît qu'à partir
    /// de 1. Bascule optimiste gérée par le view model.
    private func likeButton(_ comment: SocialComment) -> some View {
        let isLiked = comment.likedByMe == true
        let count = comment.likes ?? 0
        return Button {
            model.toggleLike(comment)
        } label: {
            HStack(spacing: SQSpace.xs + 1) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .sqLikePop(trigger: isLiked)
                    .accessibilityHidden(true)
                if count > 0 {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isLiked ? SQColor.like : SQColor.labelSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .accessibilityLabel(isLiked ? "Je n’aime plus" : "J’aime")
        .accessibilityValue(count > 0 ? "\(count) j’aime" : "")
    }

    /// Avatar / nom tappable quand le parent fournit `onAuthorTap`.
    @ViewBuilder
    private func authorButton(_ comment: SocialComment, @ViewBuilder content: () -> some View) -> some View {
        if let onAuthorTap, comment.author.id != "?" {
            Button {
                Haptics.light()
                dismiss()
                onAuthorTap(comment.author)
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voir le profil de \(comment.author.displayName)")
        } else {
            content()
        }
    }

    /// Bandeau d'erreur (COMMENT-UX-01) — l'échec n'est plus silencieux.
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(SQType.caption)
            .foregroundStyle(SQColor.dangerInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.dangerSoft)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composer: some View {
        let isDisabled = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            if let replyTo = model.replyTo {
                HStack(spacing: SQSpace.xs) {
                    Text("Réponse à")
                    Text(replyTo.author.displayName).fontWeight(.semibold)
                    Spacer()
                    Button("Annuler") { model.cancelReply() }
                        .frame(minHeight: 44)
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityIdentifier("comments.replyTarget")
            }
            HStack(spacing: SQSpace.sm + 2) {
                // Champ capsule « Crème » : SurfaceMuted, sans bordure, 44 pt mini.
                TextField(model.replyTo == nil
                    ? LocalizedStringKey("Ajoute un commentaire")
                    : LocalizedStringKey("Répondre…"), text: $model.draft, axis: .vertical)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1...4)
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm + 2)
                    .frame(minHeight: 44)
                    .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "ellipsis" : "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.onAccent)
                        .frame(width: 44, height: 44)
                        .background(SQColor.brandRed, in: Circle())
                        .opacity(isDisabled ? 0.45 : 1)
                        .sqAnimation(SQMotion.fast, value: isDisabled)
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Envoyer le commentaire")
                .disabled(isDisabled)
            }
        }
        .padding(SQSpace.md)
        .background(SQColor.surface)
    }
}
