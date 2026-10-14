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
    /// Échec d'une action (envoi, suppression, j'aime), distinct de
    /// `errorMessage` qui ne concerne que le chargement : un envoi raté ne doit
    /// ni effacer ni remplacer l'erreur de chargement.
    @Published var actionErrorMessage: String?
    @Published var draft: String = ""
    @Published var isSending = false
    @Published var replyTo: SocialComment?
    @Published var expandedParentIDs: Set<String> = []
    @Published var repliesByParent: [String: ReplyPage] = [:]
    /// Commentaires publiés depuis l'ouverture : le titre de la feuille les compte.
    @Published var postedCount = 0
    /// Commentaires supprimés depuis l'ouverture : le titre les retire.
    @Published var deletedCount = 0
    /// Commentaire publié : nourrit le classement « Pour toi » après réussite,
    /// plus à la simple ouverture de la feuille (SOC-19).
    var onCommentPosted: (() -> Void)?

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
        actionErrorMessage = nil
        defer { isSending = false }
        do {
            let comment = try await service.add(postId: postId, text: text, parentId: parentID)
            withAnimation(SQMotion.resolve(SQMotion.bouncy, UIAccessibility.isReduceMotionEnabled)) {
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
            postedCount += 1
            onCommentPosted?()
            if let parentID, repliesByParent[parentID]?.hasLoaded != true {
                Task { await loadReplies(for: parentID, cursor: nil) }
            }
        } catch {
            guard !error.isCancellation else { return }
            if draft == submittedDraft && replyTo?.id == parentID {
                actionErrorMessage = String(localized: "Échec de l'envoi. Réessaie.")
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
                actionErrorMessage = String(localized: "Impossible d’enregistrer ton j’aime. Réessaie.")
                Haptics.error()
            }
        }
    }

    /// Supprime son propre commentaire (SOC-12). Retrait après accord du
    /// serveur : un commentaire qui disparaît puis revient serait pire qu'une
    /// seconde d'attente.
    func delete(_ comment: SocialComment) async {
        do {
            try await service.delete(postId: postId, commentId: comment.id)
            actionErrorMessage = nil
            deletedCount += 1
            withAnimation(SQMotion.resolve(SQMotion.standard, UIAccessibility.isReduceMotionEnabled)) {
                comments.removeAll { $0.id == comment.id }
                for parentID in Array(repliesByParent.keys) {
                    repliesByParent[parentID]?.comments.removeAll { $0.id == comment.id }
                    repliesByParent[parentID]?.sentComments.removeAll { $0.id == comment.id }
                }
            }
            Haptics.success()
        } catch {
            guard !error.isCancellation else { return }
            actionErrorMessage = error.userFacingMessage
            Haptics.error()
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
    @State private var profileAuthor: SocialFeedAuthor?
    @State private var authorReturnAnchorID: String?

    @State private var reportedComment: SocialComment?
    @State private var pendingCommentDeletion: SocialComment?
    @Environment(\.signedInUser) private var currentUser
    /// Nombre connu à l'ouverture (celui de la publication), affiché dans le
    /// titre. Figé : le parent peut déjà compter les commentaires envoyés ici.
    @State private var commentsCount: Int?

    /// Repli pour les anciens appels sans service de profil injecté.
    private let onAuthorTap: ((SocialFeedAuthor) -> Void)?
    private let profileService: SocialFeedServicing?
    /// Signalement des commentaires des autres (règle 1.2, SOC-12).
    private let reports: ReportsServicing?

    init(service: CommentsServicing, postId: String,
         profileService: SocialFeedServicing? = nil,
         reports: ReportsServicing? = nil,
         onAuthorTap: ((SocialFeedAuthor) -> Void)? = nil,
         commentsCount: Int? = nil,
         onCommentPosted: (() -> Void)? = nil) {
        let model = CommentsViewModel(service: service, postId: postId)
        model.onCommentPosted = onCommentPosted
        _model = StateObject(wrappedValue: model)
        self.profileService = profileService
        self.reports = reports
        self.onAuthorTap = onAuthorTap
        _commentsCount = State(initialValue: commentsCount)
    }

    init(model: CommentsViewModel, profileService: SocialFeedServicing? = nil,
         reports: ReportsServicing? = nil,
         onAuthorTap: ((SocialFeedAuthor) -> Void)? = nil,
         commentsCount: Int? = nil) {
        _model = StateObject(wrappedValue: model)
        self.profileService = profileService
        self.reports = reports
        self.onAuthorTap = onAuthorTap
        _commentsCount = State(initialValue: commentsCount)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
                if let error = model.errorMessage, model.hasLoaded || !model.comments.isEmpty {
                    errorBanner(error)
                }
                if let error = model.actionErrorMessage {
                    errorBanner(error)
                        .accessibilityIdentifier("comments.actionError")
                }
                composer
            }
            .sqAnimation(SQMotion.snappy, value: model.errorMessage)
            .sqAnimation(SQMotion.snappy, value: model.actionErrorMessage)
            // Le bandeau d'action s'efface seul : rien à fermer à la main.
            .task(id: model.actionErrorMessage) {
                guard model.actionErrorMessage != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                model.actionErrorMessage = nil
            }
            .background(SQColor.surface.ignoresSafeArea())
            .navigationTitle("Commentaires")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestinationItemCompat($profileAuthor) { author in
                if let profileService {
                    UserProfileView(userId: author.id, prefill: author, service: profileService)
                }
            }
            .sheet(item: $reportedComment) { comment in
                if let reports {
                    ReportSheet(target: .comment(comment.id), service: reports)
                }
            }
            .confirmationDialog(
                "Supprimer ce commentaire ?",
                isPresented: Binding(
                    get: { pendingCommentDeletion != nil },
                    set: { if !$0 { pendingCommentDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingCommentDeletion
            ) { comment in
                Button("Supprimer", role: .destructive) {
                    pendingCommentDeletion = nil
                    Task { await model.delete(comment) }
                }
                Button("Annuler", role: .cancel) { pendingCommentDeletion = nil }
            } message: { _ in
                Text("Il disparaîtra pour tout le monde.")
            }
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .task { if !model.hasLoaded { await model.load() } }
    }

    /// Titre avec le nombre, fermeture ronde : pas de barre de navigation.
    private var header: some View {
        let total = max(0, (commentsCount ?? 0) + model.postedCount - model.deletedCount)
        return HStack(spacing: SQSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs2) {
                Text("Commentaires")
                    .foregroundStyle(SQColor.label)
                if total > 0 {
                    Text(verbatim: "\(total)")
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .font(SQFont.display(18, .heavy, relativeTo: .headline))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("comments.title")
            Spacer(minLength: 0)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "comments.close") {
                dismiss()
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.lg)
        .padding(.bottom, SQSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.comments.isEmpty {
            SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SQSpace.lg) {
                        ForEach(model.comments) { comment in
                            commentThread(comment)
                                .id(comment.id)
                                .sqFadeUp()
                        }
                        if model.isLoadingMore {
                            SQSpinner().tint(SQColor.brandRed)
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
                .onChangeCompat(of: profileAuthor) { oldAuthor, newAuthor in
                    guard oldAuthor != nil, newAuthor == nil,
                          let anchor = authorReturnAnchorID else { return }
                    Task { @MainActor in
                        // Attend que la liste reprenne sa taille après le pop du profil.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard profileAuthor == nil, authorReturnAnchorID == anchor else { return }
                        proxy.scrollTo(anchor, anchor: .center)
                        authorReturnAnchorID = nil
                    }
                }
            }
        }
    }

    /// Retrait des réponses : elles s'alignent sur le texte du commentaire parent.
    private static let replyIndent: CGFloat = 34 + SQSpace.sm2

    private func commentThread(_ comment: SocialComment) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            commentRow(comment)
            HStack(spacing: SQSpace.lg) {
                Button("Répondre") { model.beginReply(to: comment) }
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(minHeight: 44)
                let page = model.repliesByParent[comment.id]
                let count = max(comment.repliesCount ?? 0,
                    (page?.comments.count ?? 0) + (page?.sentComments.count ?? 0))
                if count > 0 {
                    Button {
                        Task { await model.toggleReplies(for: comment) }
                    } label: {
                        Group {
                            if model.expandedParentIDs.contains(comment.id) {
                                Text("Masquer les réponses")
                            } else {
                                Text("Voir \(count) réponses")
                            }
                        }
                        .monospacedDigit()
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("comments.replies.\(comment.id)")
                }
            }
            .font(SQType.caption(.bold))
            .buttonStyle(.plain)
            .padding(.leading, Self.replyIndent)
            .padding(.top, -SQSpace.sm)
            if model.expandedParentIDs.contains(comment.id) {
                replies(for: comment)
            }
        }
    }

    @ViewBuilder
    private func replies(for parent: SocialComment) -> some View {
        let page = model.repliesByParent[parent.id] ?? CommentsViewModel.ReplyPage()
        Group {
            if page.isLoading && page.comments.isEmpty {
                SQSpinner().tint(SQColor.brandRed)
            }
            ForEach(page.comments) { reply in
                commentRow(reply, isReply: true).id(reply.id)
            }
            ForEach(page.sentComments) { reply in
                commentRow(reply, isReply: true).id(reply.id)
            }
            if page.hasLoaded && page.comments.isEmpty && page.sentComments.isEmpty && page.errorMessage == nil {
                Text("Aucune réponse")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if page.nextCursor != nil && !page.isLoading && page.errorMessage == nil {
                Button("Charger la suite") { Task { await model.loadMoreReplies(for: parent.id) } }
                    .font(SQType.caption(.bold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("comments.replies.loadMore.\(parent.id)")
            }
        }
        .padding(.leading, Self.replyIndent)
        if let error = page.errorMessage {
            errorBanner(error)
            Button("Réessayer") { Task { await model.retryReplies(for: parent.id) } }
                .padding(.leading, Self.replyIndent)
                .frame(minHeight: 44)
        }
    }

    /// Commentaire sans bulle : avatar, nom et temps, texte ; le cœur et son
    /// compteur dans la colonne de droite.
    private func commentRow(_ comment: SocialComment, isReply: Bool = false) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            authorButton(comment) {
                SQAvatar(url: comment.author.avatarUrl, name: comment.author.displayName, size: isReply ? 28 : 34)
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                HStack(spacing: SQSpace.xs) {
                    authorButton(comment) {
                        Text(comment.author.displayName)
                            .font(SQType.caption(.bold))
                            .foregroundStyle(SQColor.label)
                    }
                    if let created = comment.createdAt {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                Text(comment.text)
                    .font(SQFont.body(14.5, .regular, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            likeButton(comment)
        }
        .contextMenu { commentMenu(comment) }
    }

    /// Supprimer le sien, signaler celui des autres : ni l'un ni l'autre
    /// n'était possible (App Store, règle 1.2 ; SOC-12).
    @ViewBuilder
    private func commentMenu(_ comment: SocialComment) -> some View {
        if comment.author.id == LocalAccountScope.currentUserId {
            Button(role: .destructive) {
                pendingCommentDeletion = comment
            } label: {
                Label("Supprimer le commentaire", systemImage: "trash")
            }
        } else if reports != nil {
            Button(role: .destructive) {
                reportedComment = comment
            } label: {
                Label("Signaler le commentaire", systemImage: "flag")
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
            VStack(spacing: SQSpace.xxs) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .sqLikePop(trigger: isLiked)
                    .accessibilityHidden(true)
                if count > 0 {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(SQType.caption(.semibold))
            .foregroundStyle(isLiked ? SQColor.like : SQColor.labelSecondary)
            .frame(minWidth: 44, minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLiked ? "Je n’aime plus" : "J’aime")
        .accessibilityValue(count > 0 ? "\(count) j’aime" : "")
    }

    /// Avatar / nom tappable quand le parent fournit `onAuthorTap`.
    @ViewBuilder
    private func authorButton(_ comment: SocialComment, @ViewBuilder content: () -> some View) -> some View {
        if comment.author.id != "?", profileService != nil || onAuthorTap != nil {
            Button {
                Haptics.light()
                if profileService != nil {
                    authorReturnAnchorID = comment.id
                    profileAuthor = comment.author
                } else {
                    dismiss()
                    onAuthorTap?(comment.author)
                }
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voir le profil de \(comment.author.displayName)")
            .accessibilityIdentifier("comment.author.\(comment.id)")
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
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: currentUser?.avatarUrl, name: currentUser?.displayName ?? "", size: 30)
                    .accessibilityHidden(true)
                TextField(model.replyTo == nil
                    ? LocalizedStringKey("Ajouter un commentaire…")
                    : LocalizedStringKey("Répondre…"), text: $model.draft, axis: .vertical)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1...4)
                    .padding(.horizontal, SQSpace.md2)
                    .padding(.vertical, SQSpace.sm2)
                    .frame(minHeight: 44)
                    .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))
                    .accessibilityIdentifier("comments.input")
                // Envoi rond à l'encre, comme dans la visionneuse photo.
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "ellipsis" : "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SQColor.onInk)
                        .frame(width: 44, height: 44)
                        .background(SQColor.label, in: Circle())
                        .opacity(isDisabled ? 0.35 : 1)
                        .sqAnimation(SQMotion.fast, value: isDisabled)
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Envoyer le commentaire")
                .accessibilityIdentifier("comments.send")
                .disabled(isDisabled)
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm2)
        .background(SQColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(SQColor.separator).frame(height: 1 / UIScreen.main.scale)
        }
    }

}

#if DEBUG && targetEnvironment(simulator)
actor CommentsQAFixture: CommentsServicing {
    private let singleParent: Bool
    private var failedMoreOnce = false

    init(singleParent: Bool = false) { self.singleParent = singleParent }

    func list(postId: String, cursor: String?) async throws -> SocialCommentsResponse {
        try await Task.sleep(nanoseconds: 180_000_000)
        if cursor == "after-50", !failedMoreOnce {
            failedMoreOnce = true
            throw URLError(.notConnectedToInternet)
        }
        if singleParent {
            return try Self.page(ids: ["parent-0"])
        }
        return try Self.page(
            ids: cursor == nil ? (0..<50).map { "parent-\($0)" } : ["parent-49", "parent-50"],
            next: cursor == nil ? "after-50" : nil
        )
    }

    func replies(postId: String, commentId: String, cursor: String?) async throws -> SocialCommentsResponse {
        try await Task.sleep(nanoseconds: 180_000_000)
        return try Self.page(
            ids: cursor == nil ? (0..<20).map { "reply-\($0)" } : ["reply-19", "reply-20"],
            parentID: commentId, next: cursor == nil ? "after-20" : nil
        )
    }

    func add(postId: String, text: String, parentId: String?) async throws -> SocialComment {
        let body: [String: Any] = [
            "id": "sent-\(UUID().uuidString)", "postId": postId,
            "parentId": parentId as Any? ?? NSNull(),
            "author": ["id": "me", "name": "Moi"], "text": text,
        ]
        return try JSONDecoder.signalQuest.decode(
            SocialComment.self, from: JSONSerialization.data(withJSONObject: body)
        )
    }

    func like(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try JSONDecoder().decode(CommentReactionResponse.self, from: Data(#"{"liked":true,"count":2}"#.utf8))
    }

    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try JSONDecoder().decode(CommentReactionResponse.self, from: Data(#"{"liked":false,"count":1}"#.utf8))
    }

    private static func page(ids: [String], parentID: String? = nil, next: String? = nil) throws -> SocialCommentsResponse {
        let rows: [[String: Any]] = ids.map { id in
            ["id": id, "postId": "post-1", "parentId": parentID as Any? ?? NSNull(),
             "author": ["id": "author", "name": "Camille"], "text": id,
             "repliesCount": parentID == nil ? 21 : 0, "likesCount": 1]
        }
        let body: [String: Any] = [
            parentID == nil ? "comments" : "replies": rows,
            "nextCursor": next as Any? ?? NSNull(), "totalCount": ids.count,
        ]
        return try JSONDecoder.signalQuest.decode(
            SocialCommentsResponse.self, from: JSONSerialization.data(withJSONObject: body)
        )
    }
}
#endif

struct CommentsQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @EnvironmentObject private var services: AppServices
    @State private var fixture: CommentsQAFixture
    @State private var showsComments = true

    init() {
        let repliesOnly = AppEnvironment.hasQAFlag("comments-replies")
        _fixture = State(initialValue: CommentsQAFixture(singleParent: repliesOnly))
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            Button("Ouvrir les commentaires") { showsComments = true }
                .accessibilityIdentifier("comments.qa.open")
                .frame(minHeight: 44)
                .navigationTitle("Commentaires QA")
        }
        .sheet(isPresented: $showsComments) {
            CommentsSheet(service: fixture, postId: "post-1", profileService: services.feed)
        }
        #else
        EmptyView()
        #endif
    }
}
