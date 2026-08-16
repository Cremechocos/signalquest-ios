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
    /// Les réponses déjà chargées, par commentaire parent. Une clé absente veut dire « jamais
    /// demandé » ; présente avec un tableau vide, « chargé, et il n'y en a pas ».
    @State private var repliesByComment: [String: [SocialComment]] = [:]
    @State private var expandedReplies: Set<String> = []
    @State private var loadingReplies: Set<String> = []
    /// `nil` quand on écrit au fil, sinon le commentaire auquel on répond.
    @State private var replyTarget: SocialComment?

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
        /* Le fil vit EN DIRECT, comme sur Android.
           Sans cela, un cœur posé depuis l'Android restait invisible sur l'iPhone ouvert sur la
           même panne jusqu'à ce qu'on referme la fiche — constaté par Alexandre sur ses deux
           téléphones. Le canal `post:<id>` portait déjà les événements ; il lui manquait une porte
           SSE, seule voie dont dispose iOS (le WebSocket est réservé aux appels).

           On RELIT au lieu d'appliquer la charge utile : c'est le parti pris de `SSEClient`, qui
           n'émet que le nom de l'événement précisément pour qu'aucun écran ne diverge de la base.
           `task(id:)` annule et relance le flux quand la fiche change de panne, et le ferme quand
           elle disparaît. */
        .task(id: postId) {
            for await _ in services.sse.events(
                path: "/api/social/posts/\(postId)/stream"
            ) {
                await load()
                // Les fils dépliés se rafraîchissent aussi : sans cela, un cœur posé sur une
                // RÉPONSE depuis un autre appareil ne bougeait pas ici, alors même que le fil
                // parent venait d'être relu.
                for parentId in expandedReplies {
                    await loadReplies(parentId)
                }
            }
        }
    }

    /// Le composer. Capsule douce, bouton brique — le seul accent de ce bloc.
    private var composer: some View {
        VStack(alignment: .trailing, spacing: SQSpace.sm) {
            /* À QUI l'on répond, écrit au-dessus du champ.
               Sans cette ligne, rien à l'écran ne distingue « j'écris au fil » de « je réponds à
               Marc » : on tape, on publie, et la réponse atterrit ailleurs qu'on ne croyait —
               invisible avant l'envoi, irréparable après. La croix rend le champ au fil. */
            if let target = replyTarget {
                HStack(spacing: SQSpace.sm) {
                    Text(String(localized: "Réponse à @\(target.author.handle ?? target.author.displayName ?? "")"))
                        .font(SQFont.body(13, .semibold, relativeTo: .caption))
                        .foregroundStyle(SQColor.brandRed)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityLabel(String(localized: "Annuler la réponse"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField(
                replyTarget == nil
                    ? String(localized: "Ajouter un commentaire…")
                    : String(localized: "Répondre…"),
                text: $draft,
                axis: .vertical
            )
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
                    likeButton(comment, parentId: nil)

                    // « Répondre » à côté du pouce et jamais au-dessus : même couche que lui —
                    // ouverte à tous, sans effet sur l'état de la panne. En texte et non en
                    // bouton plein, pour ne rien disputer aux boutons d'arbitrage, plus haut.
                    Button {
                        replyTarget = comment
                        // La mention est PRÉ-ÉCRITE : c'est elle qui prévient la personne même si
                        // le fil est lu ailleurs, et la retaper à la main est le genre de geste
                        // qu'on n'accomplit pas debout dans la rue.
                        if let handle = comment.author.handle, !draft.hasPrefix("@\(handle)") {
                            draft = "@\(handle) " + draft
                        }
                    } label: {
                        Text(String(localized: "Répondre"))
                            .font(SQFont.body(13, .semibold, relativeTo: .caption))
                            .foregroundStyle(SQColor.labelSecondary)
                            .padding(.horizontal, SQSpace.sm)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(SQPressButtonStyle())
                }

                /* Le fil des réponses, replié par défaut.
                   Le compte vient du SERVEUR : il faut pouvoir annoncer « 3 réponses » avant de
                   les avoir descendues, sinon rien ne dit qu'il y a quelque chose à déplier.
                   La version précédente écrivait « 3 réponse(s) » — un texte mort, non traduit,
                   sur lequel on ne pouvait pas taper. */
                if (comment.repliesCount ?? 0) > 0 || !(repliesByComment[comment.id] ?? []).isEmpty {
                    Button {
                        Task { await toggleReplies(comment) }
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            Rectangle()
                                .fill(SQColor.separator)
                                .frame(width: 20, height: 1.5)
                            Text(repliesLabel(for: comment))
                                .font(SQFont.body(13, .semibold, relativeTo: .caption))
                                .foregroundStyle(SQColor.brandRed)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(SQPressButtonStyle())
                }

                if expandedReplies.contains(comment.id),
                   let loaded = repliesByComment[comment.id], !loaded.isEmpty {
                    // Un filet VERTICAL et pas seulement un décalage : l'indentation seule se perd
                    // dès qu'une réponse tient sur quatre lignes, et on ne sait plus à quoi elle
                    // répond.
                    HStack(alignment: .top, spacing: SQSpace.md) {
                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: SQSpace.lg) {
                            ForEach(loaded) { reply in
                                replyRow(reply)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// « Chargement… », « Masquer les réponses », ou « Voir N réponses ».
    private func repliesLabel(for comment: SocialComment) -> String {
        if loadingReplies.contains(comment.id) { return String(localized: "Chargement…") }
        if expandedReplies.contains(comment.id) { return String(localized: "Masquer les réponses") }
        let count = comment.repliesCount ?? repliesByComment[comment.id]?.count ?? 0
        // Un vrai pluriel, à la place du « réponse(s) » d'avant : c'est une chaîne que l'app
        // traduit, et la parenthèse ne se traduit dans aucune des cinq langues.
        return count == 1
            ? String(localized: "Voir 1 réponse")
            : String(localized: "Voir \(count) réponses")
    }

    /// Une réponse — le même commentaire, en plus petit et sans ses propres réponses.
    ///
    /// Un seul niveau d'imbrication, comme le fil social : au deuxième, la colonne de gauche mange
    /// l'écran d'un iPhone et le texte se lit en escalier. Répondre à une réponse repart donc sous
    /// le même parent, avec la mention `@` pour dire à qui l'on parle.
    private func replyRow(_ reply: SocialComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Text(String((reply.author.displayName ?? "?").prefix(2)).uppercased())
                .font(SQFont.body(10, .semibold, relativeTo: .caption2))
                .frame(width: 27, height: 27)
                .background(SQColor.accentSoft, in: Circle())
                .foregroundStyle(SQColor.brandRed)

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(reply.author.displayName ?? "")
                    .font(SQFont.body(13, .semibold, relativeTo: .caption))
                Text(reply.text)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                likeButton(reply, parentId: reply.parentId, compact: true)
            }
        }
    }

    /**
     Le cœur d'un commentaire ou d'une réponse.

     ── Pourquoi un symbole dessiné, et plus un émoji ──

     La première version posait un « 👍 » dans une capsule pleine. Trois choses n'allaient pas :
     un émoji système garde ses couleurs quoi qu'on fasse, et son jaune détonnait sur la crème du
     thème ; sa capsule pleine lui donnait le poids d'un bouton d'action alors que c'est un geste
     à coût nul ; et surtout il MENTAIT sur ce qu'il fait, puisque le serveur ne connaît qu'une
     réaction de commentaire, `❤️` — un pouce affiché ici enregistrait un cœur, lisible tel quel
     depuis le web et depuis Android.

     C'est donc le même cœur que le fil social, avec son rebond au tap : la même action doit se
     dessiner pareil dans toute l'app, et à l'identique d'un téléphone à l'autre.

     Extrait en fonction nommée aussi par nécessité : au-delà d'une certaine taille, le
     vérificateur de types de SwiftUI renonce sur l'expression entière sans dire où.
     */
    private func likeButton(
        _ comment: SocialComment,
        parentId: String?,
        compact: Bool = false
    ) -> some View {
        let liked = comment.likedByMe == true
        return Button {
            Task { await toggleLike(comment, parentId: parentId) }
        } label: {
            HStack(spacing: SQSpace.xs) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    // Le rebond dit « c'est parti » avant même que le serveur ne réponde.
                    .scaleEffect(liked ? 1.12 : 1)
                    .animation(SQMotion.bouncy, value: liked)
                // Un zéro ne s'écrit pas : « 0 » invite à croire que le compteur est cassé.
                if let likes = comment.likes, likes > 0 {
                    Text("\(likes)")
                        .font(SQFont.body(compact ? 12 : 13, .semibold, relativeTo: .caption))
                }
            }
            .padding(.horizontal, SQSpace.sm)
            // 44 points : la cible tactile minimale, quand le pictogramme n'en fait que 14.
            .frame(minHeight: 44)
            .foregroundStyle(liked ? SQColor.brandRed : SQColor.labelSecondary)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(
            liked
                ? String(localized: "Ne plus aimer ce commentaire")
                : String(localized: "Aimer ce commentaire")
        )
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
        let parent = replyTarget?.id
        // Rechargement après envoi plutôt qu'un ajout optimiste : le serveur peut modérer, tronquer
        // ou refuser, et afficher un commentaire qui n'existe pas serait pire que d'attendre.
        if (try? await services.comments.add(postId: postId, text: text, parentId: parent)) != nil {
            draft = ""
            replyTarget = nil
            await load()
            // Une réponse envoyée déplie le fil où elle atterrit : sans cela, elle disparaissait
            // derrière un « Voir 1 réponse » qu'il fallait deviner.
            if let parent {
                expandedReplies.insert(parent)
                await loadReplies(parent)
            }
        }
        posting = false
    }

    /// Déplie, replie, et charge la première fois.
    private func toggleReplies(_ comment: SocialComment) async {
        let id = comment.id
        if expandedReplies.contains(id) {
            expandedReplies.remove(id)
            return
        }
        // Déjà chargées : replier puis déplier ne doit pas refaire un aller-retour réseau.
        if repliesByComment[id] != nil {
            expandedReplies.insert(id)
            return
        }
        loadingReplies.insert(id)
        await loadReplies(id)
        expandedReplies.insert(id)
        loadingReplies.remove(id)
    }

    private func loadReplies(_ commentId: String) async {
        if let page = try? await services.comments.replies(
            postId: postId,
            commentId: commentId,
            cursor: nil
        ) {
            repliesByComment[commentId] = page.comments
        }
    }

    /// `parentId` non nul quand le pouce vise une RÉPONSE : elle ne vit pas dans `comments` mais
    /// dans le fil de son parent, et sans cette distinction le compteur restait figé.
    private func toggleLike(_ comment: SocialComment, parentId: String? = nil) async {
        let liked = comment.likedByMe == true
        let response = liked
            ? try? await services.comments.unlike(postId: postId, commentId: comment.id)
            : try? await services.comments.like(postId: postId, commentId: comment.id)
        guard let response else { return }
        // Mise à jour EN PLACE et non rechargement : un like ne réordonne rien, et recharger
        // ferait sauter la liste sous le doigt.
        if let parentId {
            guard var fil = repliesByComment[parentId],
                  let index = fil.firstIndex(where: { $0.id == comment.id }) else { return }
            fil[index].likedByMe = response.liked
            fil[index].likes = response.count
            repliesByComment[parentId] = fil
            return
        }
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        comments[index].likedByMe = response.liked
        comments[index].likes = response.count
    }
}
