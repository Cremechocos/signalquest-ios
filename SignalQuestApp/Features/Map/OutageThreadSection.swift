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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var comments: [SocialComment] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var failed = false
    /// La panne dont le fil est affiché : seul son premier chargement montre le spinner, les
    /// relectures du direct se font sans faire clignoter le bloc.
    @State private var loadedPostId: String?
    @State private var nextCursor: String?
    /// Vrai dès qu'une page suivante a été ajoutée : une relecture du direct ne la jette pas.
    @State private var loadedMorePages = false
    @State private var loadingMore = false
    @State private var moreFailed = false
    @State private var posting = false
    @State private var postError: String?
    /// Les réponses déjà chargées, par commentaire parent. Une clé absente veut dire « jamais
    /// demandé » ; présente avec un tableau vide, « chargé, et il n'y en a pas ».
    @State private var repliesByComment: [String: [SocialComment]] = [:]
    @State private var expandedReplies: Set<String> = []
    @State private var loadingReplies: Set<String> = []
    /// Échec de lecture des réponses, par commentaire parent : le fil reste replié et le dit.
    @State private var repliesErrors: [String: String] = [:]
    /// Réaction refusée ou perdue : sans mot, le cœur revenait à son état sans explication.
    @State private var likeError: String?
    /// `nil` quand on écrit au fil, sinon le commentaire auquel on répond.
    @State private var replyTarget: SocialComment?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("La conversation").sqKicker().accessibilityAddTraits(.isHeader)
                Text("Ouverte à tous. Les commentaires et les réactions ne modifient pas l'état de la panne.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            composer

            if let likeError {
                SQInlineError(message: likeError)
            }

            if loading {
                SQSpinner()
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
                    if nextCursor != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: SQSpace.sm) {
                                Text(moreFailed ? "Réessayer de charger la suite" : "Voir plus de commentaires")
                                if loadingMore { SQSpinner() }
                            }
                            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .disabled(loadingMore)
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
                    await loadReplies(parentId, reportsFailure: false)
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
                        .sqSingleLine()
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

            if let postError {
                SQInlineError(message: postError)
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

                if let repliesError = repliesErrors[comment.id] {
                    SQInlineError(message: repliesError)
                    Button {
                        Task { await toggleReplies(comment) }
                    } label: {
                        Text("Réessayer")
                            .font(SQFont.body(13, .semibold, relativeTo: .caption))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
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
                .font(SQType.micro)
                .minimumScaleFactor(0.8)
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
                    .scaleEffect(liked && !reduceMotion ? 1.12 : 1)
                    .sqAnimation(SQMotion.bouncy, value: liked)
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
        let firstLoad = loadedPostId != postId
        if firstLoad {
            loading = true
            loadedMorePages = false
            nextCursor = nil
        }
        do {
            let page = try await services.comments.list(postId: postId, cursor: nil)
            if loadedMorePages {
                // Les pages suivantes déjà lues restent sous la première, relue.
                let ids = Set(page.comments.map(\.id))
                comments = page.comments + comments.filter { !ids.contains($0.id) }
            } else {
                comments = page.comments
                nextCursor = page.nextCursor
            }
            failed = false
            loadedPostId = postId
        } catch {
            // Une relecture du direct qui échoue garde le fil déjà affiché.
            if firstLoad { failed = true }
        }
        loading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await services.comments.list(postId: postId, cursor: cursor)
            let ids = Set(comments.map(\.id))
            comments += page.comments.filter { !ids.contains($0.id) }
            nextCursor = page.nextCursor
            loadedMorePages = true
            moreFailed = false
        } catch {
            moreFailed = true
        }
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        posting = true
        postError = nil
        let parent = replyTarget?.id
        // Rechargement après envoi plutôt qu'un ajout optimiste : le serveur peut modérer, tronquer
        // ou refuser, et afficher un commentaire qui n'existe pas serait pire que d'attendre.
        let sent: Bool
        do {
            _ = try await services.comments.add(postId: postId, text: text, parentId: parent)
            sent = true
        } catch {
            // Le brouillon reste pour un nouvel essai ; l'échec se dit (AF-CARTE-14).
            if !error.isCancellation { postError = error.userFacingMessage }
            sent = false
        }
        if sent {
            draft = ""
            replyTarget = nil
            await load()
            // Une réponse envoyée déplie le fil où elle atterrit : sans cela, elle disparaissait
            // derrière un « Voir 1 réponse » qu'il fallait deviner.
            if let parent {
                if await loadReplies(parent) { expandedReplies.insert(parent) }
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
        // On ne déplie que si la lecture a réussi : sinon « Masquer les réponses » s'affichait
        // au-dessus d'un fil vide, comme si personne n'avait répondu.
        if await loadReplies(id) { expandedReplies.insert(id) }
        loadingReplies.remove(id)
    }

    /// `true` si les réponses sont à jour. `reportsFailure: false` pour les relectures du
    /// direct, qui gardent silencieusement ce qui est déjà affiché.
    @discardableResult
    private func loadReplies(_ commentId: String, reportsFailure: Bool = true) async -> Bool {
        do {
            let page = try await services.comments.replies(
                postId: postId,
                commentId: commentId,
                cursor: nil
            )
            repliesByComment[commentId] = page.comments
            repliesErrors[commentId] = nil
            return true
        } catch {
            if reportsFailure, !error.isCancellation {
                repliesErrors[commentId] = error.userFacingMessage
            }
            return false
        }
    }

    /// `parentId` non nul quand le pouce vise une RÉPONSE : elle ne vit pas dans `comments` mais
    /// dans le fil de son parent, et sans cette distinction le compteur restait figé.
    private func toggleLike(_ comment: SocialComment, parentId: String? = nil) async {
        let liked = comment.likedByMe == true
        likeError = nil
        let response: CommentReactionResponse
        do {
            if liked {
                response = try await services.comments.unlike(postId: postId, commentId: comment.id)
            } else {
                response = try await services.comments.like(postId: postId, commentId: comment.id)
            }
        } catch {
            if !error.isCancellation { likeError = error.userFacingMessage }
            return
        }
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

/**
 LA DISCUSSION d'un site, pour l'opérateur affiché dans sa fiche (SITE-1).

 Même surface que le fil d'une panne, mais un autre sujet : on y parle du site lui-même (une
 bande activée, des travaux, un débit qui chute le soir), et une demande d'aide joint l'état
 radio de l'appareil. Sur iPhone, cet état se limite à la technologie : le reste n'est pas lisible.
 Chaque opérateur d'un site partagé a son propre fil.
 */
struct SiteThreadSection: View {
    let market: String
    let operatorKey: String
    let siteId: String
    let operatorLabel: String

    @EnvironmentObject private var services: AppServices

    @State private var comments: [SiteComment] = []
    @State private var commentCount = 0
    @State private var nextCursor: String?
    @State private var loading = true
    @State private var failed = false
    /// Le serveur ne connaît pas de fil pour ce site et cet opérateur : la section se retire.
    @State private var unavailable = false
    @State private var loadingMore = false
    @State private var moreFailed = false
    @State private var draft = ""
    @State private var asksHelp = false
    @State private var posting = false
    @State private var postError: String?
    @State private var actionError: String?
    @State private var pendingDelete: SiteComment?
    @State private var deletingId: String?
    @State private var reportTarget: SiteComment?

    private static let textLimit = 1000

    private var threadKey: String { "\(market)|\(operatorKey)|\(siteId)" }

    private var isSignedIn: Bool {
        AppEnvironment.usesDemoData || LocalAccountScope.sessionSnapshot() != nil
    }

    /// La technologie de l'appareil, seule part de l'état radio qu'iOS expose.
    private var deviceRadio: SiteCommentRadio? {
        SiteCommentRadio.coarse(services.networkPath.status.cellularTechnology)
    }

    var body: some View {
        Group {
            if !unavailable {
                content
            }
        }
        .task(id: threadKey) { await load() }
        .alert(
            "Supprimer ce message ?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { comment in
            Button("Supprimer", role: .destructive) {
                pendingDelete = nil
                Task { await delete(comment) }
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Il disparaîtra de la discussion pour tout le monde.")
        }
        .sheet(item: $reportTarget) { comment in
            ReportSheet(target: .siteComment(comment.id), service: services.reports)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                HStack(spacing: SQSpace.sm) {
                    Text("Discussion du site").sqKicker().accessibilityAddTraits(.isHeader)
                    if commentCount > 0 {
                        Text("\(commentCount)")
                            .font(SQFont.body(12, .semibold, relativeTo: .caption))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Text("Ouverte à tous, sur le réseau \(operatorLabel) de ce site. Les messages ne modifient ni les pannes ni les identifiants.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSignedIn {
                composer
            } else {
                Text("Connecte-toi pour participer à la discussion.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if let actionError {
                SQInlineError(message: actionError)
            }

            if loading {
                SQSpinner()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, SQSpace.md)
            } else if failed {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Impossible de charger la discussion.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    retryButton("Réessayer") { await load() }
                }
            } else if comments.isEmpty {
                Text("Personne n'a encore écrit sur ce site.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    ForEach(comments) { comment in
                        row(comment)
                    }
                    if nextCursor != nil {
                        retryButton(moreFailed ? "Réessayer de charger la suite" : "Voir les messages plus anciens",
                                    busy: loadingMore) { await loadMore() }
                            .disabled(loadingMore)
                    }
                }
            }
        }
        .accessibilityIdentifier("antenna.detail.siteThread")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if let postError {
                SQInlineError(message: postError)
            }

            TextField(
                asksHelp ? String(localized: "Décris ce qui ne va pas…") : String(localized: "Écrire sur ce site…"),
                text: $draft,
                axis: .vertical
            )
                .lineLimit(2...6)
                .font(SQType.body)
                .padding(SQSpace.md)
                .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .disabled(posting)
                .accessibilityIdentifier("antenna.detail.siteThread.field")

            if let radio = deviceRadio {
                Toggle(isOn: $asksHelp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Demande d'aide")
                            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.label)
                        Text("Joint ta technologie actuelle (\(radio.summary)). Aucune position n'est envoyée.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(SQColor.brandRed)
                .disabled(posting)
                .accessibilityIdentifier("antenna.detail.siteThread.help")
            }

            HStack {
                let count = draft.count
                if count > Self.textLimit - 100 {
                    Text("\(count)/\(Self.textLimit)")
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(count > Self.textLimit ? SQColor.dangerInk : SQColor.labelSecondary)
                }
                Spacer()
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
                .accessibilityIdentifier("antenna.detail.siteThread.post")
            }
        }
    }

    private var canPost: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !posting && !text.isEmpty && text.count <= Self.textLimit
    }

    private func row(_ comment: SiteComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Text(String(comment.author.displayName.prefix(2)).uppercased())
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .frame(width: 34, height: 34)
                .background(SQColor.accentSoft, in: Circle())
                .foregroundStyle(SQColor.brandRed)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(comment.author.displayName)
                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                        .sqSingleLine()
                    if let date = comment.createdAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .sqSingleLine()
                    }
                }
                if comment.kind == .help {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Demande d'aide", systemImage: "lifepreserver")
                            .font(SQFont.body(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(SQColor.accentInk)
                        if let summary = comment.radio?.summary, !summary.isEmpty {
                            Text(summary)
                                .font(SQType.caption)
                                .monospacedDigit()
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                }
                Text(comment.text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if comment.canDelete || isSignedIn {
                rowMenu(comment)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func rowMenu(_ comment: SiteComment) -> some View {
        Menu {
            if comment.canDelete {
                Button(role: .destructive) {
                    pendingDelete = comment
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } else {
                Button {
                    reportTarget = comment
                } label: {
                    Label("Signaler", systemImage: "flag")
                }
            }
        } label: {
            Group {
                if deletingId == comment.id {
                    SQSpinner()
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(deletingId != nil)
        .accessibilityLabel(String(localized: "Actions sur le message"))
    }

    private func retryButton(_ title: LocalizedStringKey, busy: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: SQSpace.sm) {
                Text(title)
                if busy { SQSpinner() }
            }
            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        failed = false
        unavailable = false
        actionError = nil
        defer { loading = false }
        do {
            let page = try await services.siteComments.list(market: market, operatorKey: operatorKey, siteId: siteId, cursor: nil)
            comments = page.comments
            commentCount = page.thread.commentCount
            nextCursor = page.nextCursor
            moreFailed = false
        } catch {
            guard !error.isCancellation else { return }
            comments = []
            commentCount = 0
            nextCursor = nil
            if case .http(let status, _, _, _, _) = error as? APIError, status == 404 || status == 400 {
                unavailable = true
            } else {
                failed = true
            }
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await services.siteComments.list(market: market, operatorKey: operatorKey, siteId: siteId, cursor: cursor)
            let ids = Set(comments.map(\.id))
            comments += page.comments.filter { !ids.contains($0.id) }
            nextCursor = page.nextCursor
            moreFailed = false
        } catch {
            if !error.isCancellation { moreFailed = true }
        }
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canPost else { return }
        let radio = asksHelp ? deviceRadio : nil
        let kind: SiteCommentKind = radio == nil ? .comment : .help
        posting = true
        postError = nil
        defer { posting = false }
        do {
            // Le serveur renvoie le message tel qu'il l'a enregistré : on l'affiche sans relire le fil.
            let comment = try await services.siteComments.add(
                market: market, operatorKey: operatorKey, siteId: siteId, kind: kind, text: text, radio: radio
            )
            comments.insert(comment, at: 0)
            commentCount += 1
            draft = ""
            asksHelp = false
            Haptics.success()
        } catch {
            // Le brouillon reste pour un nouvel essai.
            if !error.isCancellation {
                Haptics.error()
                postError = error.userFacingMessage
            }
        }
    }

    private func delete(_ comment: SiteComment) async {
        deletingId = comment.id
        actionError = nil
        defer { deletingId = nil }
        do {
            try await services.siteComments.delete(id: comment.id)
            comments.removeAll { $0.id == comment.id }
            commentCount = max(0, commentCount - 1)
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }
}
