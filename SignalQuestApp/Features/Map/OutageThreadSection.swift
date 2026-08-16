import SwiftUI

/**
 LA CONVERSATION d'une panne, affichée dans sa fiche.

 ── Pourquoi le fil est ici, et pas derrière un lien ──

 Une première version posait un bouton vers l'écran de publication. C'était défendable côté code —
 le fil d'une panne EST un post social, et il n'y a pas deux systèmes de commentaires — mais la
 fiche ne ressemblait plus à ce qui avait été validé : on n'y voyait ni les voix, ni le geste pour
 en ajouter une. Une conversation qu'il faut aller chercher ailleurs n'est pas une conversation.
 (Ce bouton avait en plus un défaut : son `onOpenThread` optionnel n'était fourni par personne, si
 bien qu'il ne s'affichait jamais.)

 Le compromis tenu ici : la SURFACE est nouvelle, la MÉCANIQUE ne l'est pas. Tout passe par
 `CommentsServicing` et les routes sociales existantes — mêmes limites de débit, même modération,
 mêmes réactions. Rien n'est réimplémenté, seulement affiché ailleurs.

 ── Ce que ce bloc n'est pas ──

 Il ne remplace pas l'arbitrage, qui vit au-dessus. Voter demande d'être sur zone, pèse dans le
 décompte et fait bouger l'état de la panne ; commenter est ouvert à tout compte connecté et ne
 change rien. D'où la phrase d'introduction : sans elle, deux gestes voisins se confondent.
 */
struct OutageThreadSection: View {
    let postId: String
    let commentCount: Int

    @EnvironmentObject private var services: AppServices

    @State private var comments: [SocialComment] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var failed = false
    @State private var posting = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("La conversation")
                    .font(SQFont.display(22, .bold, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                Text("Ouverte à tous. Les commentaires et les réactions ne modifient pas l'état de la panne.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            composer

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, SQSpace.md)
            } else if failed {
                // On DIT l'échec plutôt que d'afficher un fil vide : un bloc muet se lit comme
                // « personne n'a rien dit », ce qui est une autre information.
                Text("Impossible de charger la conversation.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else if comments.isEmpty {
                Text("Personne n'a encore commenté.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    ForEach(comments) { comment in
                        commentRow(comment)
                    }
                    if commentCount > comments.count {
                        Text("Et \(commentCount - comments.count) autre(s) commentaire(s)")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
        .task(id: postId) { await load() }
    }

    /// Le composer. Capsule douce, bouton brique — le seul accent de ce bloc.
    private var composer: some View {
        VStack(alignment: .trailing, spacing: SQSpace.sm) {
            TextField("Ajouter un commentaire…", text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .font(SQType.body)
                .padding(SQSpace.md)
                .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .disabled(posting)

            Button {
                Task { await post() }
            } label: {
                Text(posting ? "Envoi…" : "Publier")
                    .font(SQType.button)
                    .padding(.horizontal, SQSpace.xl)
                    .frame(minHeight: 44)
                    .foregroundStyle(canPost ? SQColor.surface : SQColor.labelSecondary)
                    .background(
                        RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous)
                            .fill(canPost ? SQColor.brandRed : SQColor.fill)
                    )
            }
            .buttonStyle(SQPressButtonStyle())
            .disabled(!canPost)
        }
    }

    private var canPost: Bool {
        !posting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Une voix du fil : qui, quoi, et le seul geste à coût nul — la réaction.
    private func commentRow(_ comment: SocialComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            // Initiales plutôt qu'un avatar distant : cette fiche s'ouvre souvent avec un réseau
            // dégradé — c'est même son sujet — et une image qui met dix secondes à venir vaut
            // moins qu'une pastille immédiate.
            Text(String((comment.author.displayName ?? "?").prefix(2)).uppercased())
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .frame(width: 34, height: 34)
                .background(SQColor.accentSoft, in: Circle())
                .foregroundStyle(SQColor.brandRed)

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(comment.author.displayName ?? "")
                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                Text(comment.text)
                    .font(SQType.body)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: SQSpace.sm) {
                    Button {
                        Task { await toggleLike(comment) }
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            // Un pouce, et AUCUN mot de constat : « je te lis », pas « je
                            // confirme ». Le vocabulaire du constat appartient à l'arbitrage.
                            Text("👍")
                            if let likes = comment.likes, likes > 0 {
                                Text("\(likes)")
                                    .font(SQFont.body(13, .semibold, relativeTo: .caption))
                            }
                        }
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 44)
                        .foregroundStyle(
                            comment.likedByMe == true ? SQColor.brandRed : SQColor.labelSecondary
                        )
                        .background(
                            Capsule().fill(
                                comment.likedByMe == true ? SQColor.accentSoft : SQColor.fill
                            )
                        )
                    }
                    .buttonStyle(SQPressButtonStyle())

                    if let replies = comment.repliesCount, replies > 0 {
                        Text("\(replies) réponse(s)")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        do {
            comments = try await services.comments.list(postId: postId, cursor: nil).comments
            failed = false
        } catch {
            failed = true
        }
        loading = false
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        posting = true
        // Rechargement après envoi plutôt qu'un ajout optimiste : le serveur peut modérer, tronquer
        // ou refuser, et afficher un commentaire qui n'existe pas serait pire que d'attendre.
        if (try? await services.comments.add(postId: postId, text: text, parentId: nil)) != nil {
            draft = ""
            await load()
        }
        posting = false
    }

    private func toggleLike(_ comment: SocialComment) async {
        let liked = comment.likedByMe == true
        let response = liked
            ? try? await services.comments.unlike(postId: postId, commentId: comment.id)
            : try? await services.comments.like(postId: postId, commentId: comment.id)
        guard let response, let index = comments.firstIndex(where: { $0.id == comment.id }) else {
            return
        }
        // Mise à jour EN PLACE et non rechargement : un like ne réordonne rien, et recharger
        // ferait sauter la liste sous le doigt.
        comments[index].likedByMe = response.liked
        comments[index].likes = response.count
    }
}
