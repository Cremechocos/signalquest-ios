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

    /// En-tête éditorial : poignée nette + kicker rouge, filet bas 1px.
    private var sheetHeader: some View {
        VStack(spacing: SQSpace.xs) {
            SQSheetHandle()
            Text("Commentaires")
                .sqKicker()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SQSpace.lg)
                .padding(.bottom, SQSpace.sm + 2)
        }
        .background(SQColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SQColor.separator)
                .frame(height: 1)
        }
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

    private func commentRow(_ comment: SocialComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
            authorButton(comment) {
                SQAvatar(url: comment.author.avatarUrl, name: comment.author.displayName, size: 36)
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                HStack {
                    authorButton(comment) {
                        Text(comment.author.displayName)
                            .font(SQFont.archivo(15, .semibold))
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
                if let likes = comment.likes, likes > 0 {
                    let isLiked = comment.likedByMe == true
                    HStack(spacing: SQSpace.xs + 1) {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .sqLikePop(trigger: isLiked)
                            .accessibilityHidden(true)
                        Text("\(likes)")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isLiked ? SQColor.like : SQColor.labelSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(likes) j’aime")
                }
            }
        }
        .padding(SQSpace.md)
        .sqEditorialCard()
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
            .background(SQColor.danger.opacity(0.10))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composer: some View {
        let isDisabled = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending
        return HStack(spacing: SQSpace.sm + 2) {
            TextField("Ajoute un commentaire", text: $model.draft, axis: .vertical)
                .textFieldStyle(SQTextFieldStyle())
                .lineLimit(1...4)
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: model.isSending ? "ellipsis" : "paperplane.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
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
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SQColor.separator)
                .frame(height: 1)
        }
    }
}
