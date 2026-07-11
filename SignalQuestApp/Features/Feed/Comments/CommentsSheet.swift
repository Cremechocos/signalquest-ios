import SwiftUI

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published var comments: [SocialComment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var draft: String = ""
    @Published var isSending = false

    private let service: CommentsServicing
    private let postId: String

    init(service: CommentsServicing, postId: String) {
        self.service = service
        self.postId = postId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            comments = try await service.list(postId: postId, cursor: nil).comments
        } catch {
            errorMessage = "Impossible de charger les commentaires."
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let comment = try await service.add(postId: postId, text: text, parentId: nil)
            withAnimation(SQMotion.bouncy) { comments.insert(comment, at: 0) }
            draft = ""
            Haptics.success()
        } catch {
            // COMMENT-UX-01 : l'échec d'envoi est désormais affiché à l'utilisateur.
            errorMessage = "Échec de l'envoi. Réessaie."
            Haptics.error()
        }
    }

    /// Like/unlike optimiste d'un commentaire : bascule immédiate de l'état local
    /// puis réconciliation avec la réponse serveur (rollback en cas d'échec).
    /// Même pattern que `FeedViewModel.react`.
    func toggleLike(_ comment: SocialComment) {
        guard let idx = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let wasLiked = comments[idx].likedByMe == true
        let previousCount = comments[idx].likes ?? 0
        comments[idx].likedByMe = !wasLiked
        comments[idx].likes = max(0, previousCount + (wasLiked ? -1 : 1))
        Haptics.light()
        Task {
            do {
                let response = wasLiked
                    ? try await service.unlike(postId: postId, commentId: comment.id)
                    : try await service.like(postId: postId, commentId: comment.id)
                if let i = comments.firstIndex(where: { $0.id == comment.id }) {
                    comments[i].likedByMe = response.liked
                    comments[i].likes = response.count
                }
            } catch {
                guard !error.isCancellation else { return }
                if let i = comments.firstIndex(where: { $0.id == comment.id }) {
                    comments[i].likedByMe = wasLiked
                    comments[i].likes = previousCount
                }
            }
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader
                content
                if let error = model.errorMessage {
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
                        commentRow(comment)
                            .sqFadeUp()
                    }
                }
                .padding(SQSpace.lg)
            }
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
                                .foregroundStyle(SQColor.labelTertiary)
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
            .foregroundStyle(SQColor.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.dangerSoft)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composer: some View {
        let isDisabled = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending
        return HStack(spacing: SQSpace.sm + 2) {
            // Champ capsule « Crème » : SurfaceMuted, sans bordure, 44 pt mini.
            TextField("Ajoute un commentaire", text: $model.draft, axis: .vertical)
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
        .padding(SQSpace.md)
        .background(SQColor.surface)
    }
}
