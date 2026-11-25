import SwiftUI

// Profil public d'un utilisateur : header (avatar, stats, bouton Suivre)
// + flux de ses posts avec pagination cursor.

@MainActor
final class UserProfileViewModel: ObservableObject {
    @Published var profile: SocialUserProfile?
    @Published var items: [UnifiedSocialFeedItem] = []
    @Published var nextCursor: String?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isTogglingFollow = false
    @Published var isSettingPostNotifications = false
    @Published var errorMessage: String?
    /// Profil réglé sur « personne » (403 PROFILE_PRIVATE) : un état calme,
    /// pas « Profil indisponible » avec un « Réessayer » qui n'y peut rien.
    @Published private(set) var isPrivate = false
    /// Échec d'une action (suivre, like, ami…) : bandeau passager, pas
    /// « Profil indisponible » avec un « Réessayer » qui rechargeait tout (SOC-14).
    @Published var actionError: String?
    /// Déclencheur du sqLikePop sur le bouton Suivre.
    @Published var followPopTick = 0

    let userId: String
    let prefill: SocialFeedAuthor?
    private let service: SocialFeedServicing

    init(userId: String, prefill: SocialFeedAuthor?, service: SocialFeedServicing) {
        self.userId = userId
        self.prefill = prefill
        self.service = service
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            loadDemo()
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await service.userProfile(userId: userId)
            profile = loaded
            isPrivate = false
            let page = try await service.userPosts(userId: userId, cursor: nil, mine: loaded.isSelf)
            items = page.items
            nextCursor = page.nextCursor
        } catch let APIError.http(status, code, _, _, _) where status == 403 && code == "PROFILE_PRIVATE" {
            isPrivate = true
            items = []
            nextCursor = nil
        } catch {
            if error.isCancellation { return }
            errorMessage = error.userFacingMessage
        }
    }

    func loadMore() async {
        guard !AppEnvironment.usesDemoData, !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.userPosts(userId: userId, cursor: cursor, mine: profile?.isSelf == true)
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    func toggleFollow() {
        guard var current = profile, !current.isSelf, !isTogglingFollow else { return }
        followPopTick += 1
        // Pas de Haptics ici : le GradientButton déclencheur en émet déjà un.
        // Bascule optimiste, corrigée par la réponse serveur.
        current.isFollowing.toggle()
        current.followersCount = max(0, current.followersCount + (current.isFollowing ? 1 : -1))
        // Abonnement neuf ou désabonnement : la cloche repart de « Désactivées » (SOCIAL-BELL-1).
        if current.postNotifications != nil { current.postNotifications = .off }
        profile = current
        if AppEnvironment.usesDemoData { return }
        isTogglingFollow = true
        Task {
            defer { isTogglingFollow = false }
            do {
                let result = try await service.toggleFollow(userId: userId)
                if var updated = profile {
                    updated.isFollowing = result.following
                    if let followers = result.followersCount {
                        updated.followersCount = followers
                    }
                    if let served = result.postNotifications {
                        updated.postNotifications = PostNotificationLevel(served: served)
                    }
                    profile = updated
                }
            } catch {
                // Restaure l'état précédent en cas d'échec.
                if var reverted = profile {
                    reverted.isFollowing.toggle()
                    reverted.followersCount = max(0, reverted.followersCount + (reverted.isFollowing ? 1 : -1))
                    profile = reverted
                }
                actionError = error.userFacingMessage
                Haptics.error()
            }
        }
    }

    /// Cloche du profil (SOCIAL-BELL-1) : choix affiché tout de suite, corrigé par la
    /// réponse ; en cas d'échec, retour au choix précédent avec le message habituel.
    func setPostNotifications(_ level: PostNotificationLevel) {
        guard var current = profile, current.isFollowing, let previous = current.postNotifications,
              previous != level, !isSettingPostNotifications else { return }
        current.postNotifications = level
        profile = current
        if AppEnvironment.usesDemoData { return }
        isSettingPostNotifications = true
        Task {
            defer { isSettingPostNotifications = false }
            do {
                let saved = try await service.setPostNotifications(userId: userId, level: level)
                profile?.postNotifications = saved
            } catch let APIError.http(status, code, _, _, _) where status == 409 && code == "NOT_FOLLOWING" {
                // Plus abonné (désabonnement ailleurs, blocage) : la cloche repasse à « Désactivées »
                // et le bouton propose de suivre (contrat).
                profile?.isFollowing = false
                profile?.postNotifications = .off
                Haptics.error()
            } catch {
                if error.isCancellation { return }
                profile?.postNotifications = previous
                actionError = error.userFacingMessage
                Haptics.error()
            }
        }
    }

    // MARK: Actions sur les posts (miroir de FeedViewModel)

    func react(_ item: UnifiedSocialFeedItem, emoji: String = "❤️") {
        let previous = item
        updateItem(id: item.id) { current in
            var copy = current
            // État propre à chaque emoji : `likedByMe` ne suit que le ❤️.
            let selected = !current.hasReacted(with: emoji)
            if emoji == "❤️" { copy.likedByMe = selected }
            copy.reactions = Self.updatedReactions(current.reactions, emoji: emoji, selected: selected)
            return copy
        }
        guard !AppEnvironment.usesDemoData else { Haptics.light(); return }
        Task {
            do {
                let response = try await service.react(postId: item.id, emoji: emoji)
                applyReactionResponse(itemId: item.id, response: response)
            } catch {
                restore(previous)
                actionError = error.userFacingMessage
            }
        }
        Haptics.light()
    }

    func repost(_ item: UnifiedSocialFeedItem) {
        let previous = item
        updateItem(id: item.id) { current in
            var copy = current
            copy.repostedByMe.toggle()
            copy.repostsCount = max(0, current.repostsCount + (copy.repostedByMe ? 1 : -1))
            return copy
        }
        guard !AppEnvironment.usesDemoData else { Haptics.medium(); return }
        Task {
            do {
                let response = try await service.repost(postId: item.id)
                applyReactionResponse(itemId: item.id, response: response)
            } catch {
                restore(previous)
                actionError = error.userFacingMessage
            }
        }
        Haptics.medium()
    }

    func favorite(_ item: UnifiedSocialFeedItem) {
        let previous = item
        updateItem(id: item.id) { current in
            var copy = current
            copy.favoritedByMe.toggle()
            copy.favoritesCount = max(0, current.favoritesCount + (copy.favoritedByMe ? 1 : -1))
            return copy
        }
        guard !AppEnvironment.usesDemoData else { return }
        Task {
            do {
                let response = try await service.favorite(postId: item.id)
                applyReactionResponse(itemId: item.id, response: response)
            } catch {
                restore(previous)
                actionError = error.userFacingMessage
            }
        }
    }

    func votePoll(_ item: UnifiedSocialFeedItem, option: FeedPoll.Option) {
        guard let poll = item.poll, poll.isOpen else { return }
        let removing = option.votedByMe
        Task {
            do {
                guard let updated = try await service.votePoll(postId: item.id, optionId: option.id, removing: removing) else { return }
                updateItem(id: item.id) { current in var copy = current; copy.poll = updated; return copy }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Épingle ou désépingle (un seul post épinglé à la fois, comme dans le fil).
    func togglePin(_ item: UnifiedSocialFeedItem) {
        let willPin = !item.isPinned
        Task {
            do {
                try await service.setPinned(postId: item.id, pinned: willPin)
                items = items.map { current in
                    var copy = current
                    if current.id == item.id { copy.pinnedAt = willPin ? Date() : nil }
                    else if willPin { copy.pinnedAt = nil }
                    return copy
                }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Visibilité seule (post automatique) : remise en place si le serveur refuse.
    func setVisibility(_ item: UnifiedSocialFeedItem, to visibility: SocialVisibility) {
        items = items.map { current in
            var copy = current
            if current.id == item.id { copy.visibility = visibility.rawValue }
            return copy
        }
        Task {
            do { _ = try await service.setVisibility(postId: item.id, visibility: visibility.rawValue) }
            catch {
                restore(item)
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Retire la publication tout de suite ; elle revient à sa place si le serveur refuse.
    func delete(_ item: UnifiedSocialFeedItem) {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        items.removeAll { $0.id == item.id }
        Task {
            do { try await service.deletePost(postId: item.id) }
            catch {
                if !items.contains(where: { $0.id == item.id }) {
                    items.insert(item, at: min(index, items.count))
                }
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    func muteNotifications(_ item: UnifiedSocialFeedItem) {
        Task {
            do {
                _ = try await service.muteNotifications(postId: item.id)
                updateItem(id: item.id) { current in
                    var copy = current
                    copy.notificationsMutedByMe = !(current.notificationsMutedByMe ?? false)
                    return copy
                }
            } catch {
                if !error.isCancellation { actionError = error.userFacingMessage }
            }
        }
    }

    /// Renvoie l'id du message créé, nil si échec (la feuille affiche l'échec).
    func share(_ item: UnifiedSocialFeedItem, to conversation: MessageConversation) async -> String? {
        do {
            let messageId = try await service.share(postId: item.id, conversationId: conversation.id)
            Haptics.success()
            return messageId
        } catch {
            Haptics.error()
            return nil
        }
    }

    /// Un commentaire publié depuis la feuille compte aussitôt sur la carte.
    func commentPosted(on item: UnifiedSocialFeedItem) {
        updateItem(id: item.id) { var copy = $0; copy.commentsCount += 1; return copy }
    }

    private func updateItem(id: String, _ transform: (UnifiedSocialFeedItem) -> UnifiedSocialFeedItem) {
        items = items.map { $0.id == id ? transform($0) : $0 }
    }

    private func applyReactionResponse(itemId: String, response: ReactionResponse) {
        updateItem(id: itemId) { current in
            var copy = current
            if let reactions = response.reactions {
                copy.reactions = reactions
                copy.likedByMe = reactions.first(where: { $0.emoji == "❤️" })?.reactedByMe ?? false
            }
            if let favorited = response.favorited { copy.favoritedByMe = favorited }
            if let favoritesCount = response.favoritesCount { copy.favoritesCount = favoritesCount }
            if let reposted = response.reposted { copy.repostedByMe = reposted }
            if let repostsCount = response.repostsCount { copy.repostsCount = repostsCount }
            return copy
        }
    }

    private func restore(_ item: UnifiedSocialFeedItem) {
        items = items.map { $0.id == item.id ? item : $0 }
    }

    private static func updatedReactions(_ reactions: [SocialReactionSummary], emoji: String, selected: Bool) -> [SocialReactionSummary] {
        var result = reactions
        if let index = result.firstIndex(where: { $0.emoji == emoji }) {
            let count = max(0, result[index].count + (selected ? 1 : -1))
            result[index] = SocialReactionSummary(emoji: emoji, count: count, reactedByMe: selected)
        } else if selected {
            result.append(SocialReactionSummary(emoji: emoji, count: 1, reactedByMe: true))
        }
        return result
    }

    // MARK: Démo

    private func loadDemo() {
        let isSelf = userId == AuthUser.mock.id
        profile = SocialUserProfile(
            id: userId,
            name: prefill?.name ?? (isSelf ? "SignalQuest iOS" : "Camille"),
            handle: prefill?.handle ?? (isSelf ? "ios" : "camille"),
            bio: "Cartographie le réseau, un speedtest à la fois.",
            avatarUrl: prefill?.avatarUrl,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 240),
            isSelf: isSelf,
            isFriend: !isSelf,
            isFollowing: false,
            followersCount: 128,
            followingCount: 87,
            canMessage: !isSelf,
            stats: SocialUserProfileStats(points: 4210, gamificationPoints: 4210, level: 12, validations: 36, photos: 14, speedtests: 220,
                                          publicSessions: 9),
            accountBadges: [SocialUserBadge(kind: "premium")],
            // Deux réseaux qui ne totalisent pas 100 % : la démo doit exercer la
            // piste résiduelle de la barre empilée, pas seulement le cas plein.
            networks: SocialProfileNetworks(
                countryCode: "FR",
                countryIsDeclared: false,
                operators: [
                    SocialProfileOperatorShare(key: "orange", count: 104, share: 0.52),
                    SocialProfileOperatorShare(key: "sfr", count: 60, share: 0.30),
                    // Part MVNO : exerce le nommage par la marque et la teinte
                    // atténuée de l'hôte, que les seules parts MNO ne couvraient pas.
                    SocialProfileOperatorShare(
                        key: "LEBARA", count: 16, share: 0.08,
                        hostKey: "SFR", brandLabel: "Lebara"
                    ),
                    // Sous l'ancien plancher de 5 % : présent pour verrouiller sa
                    // suppression, qui masquait des réseaux réellement mesurés.
                    SocialProfileOperatorShare(key: "free", count: 8, share: 0.04)
                ],
                sampleSize: 200
            )
        )
        items = SocialFeedPage.demo.items
        nextCursor = nil
        errorMessage = nil
    }
}

struct UserProfileView: View {
    @StateObject private var model: UserProfileViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    /// Ouverture de la conversation en cours : évite qu'un double appui crée
    /// deux requêtes concurrentes.
    @State private var isOpeningConversation = false
    /// Échec d'ouverture de la conversation, distinct de l'erreur de chargement
    /// du profil.
    @State private var conversationError: String?

    /// Anneau de story actif (info connue du feed appelant).
    private let hasActiveStory: Bool

    @State private var presentedSheet: ProfileSheet?
    /// Liste Abonnés / Abonnements poussée par valeur (iOS 16 gelait avec un
    /// NavigationLink(destination:) dans Profil).
    @State private var followListRoute: FollowListRoute?
    @State private var showBlockConfirm = false
    @State private var showRemoveFriendConfirm = false
    /// Demande d'ami envoyée pendant cette session (le profil n'expose pas l'état
    /// « en attente ») : bascule le libellé du menu sur « Demande envoyée ».
    @State private var friendRequestSent = false
    @State private var editingPost: UnifiedSocialFeedItem?
    @State private var pendingDeletion: UnifiedSocialFeedItem?
    /// Photo récente ouverte en plein écran.
    @State private var openedPhoto: SocialProfilePhoto?

    private enum ProfileSheet: Identifiable {
        case detail(UnifiedSocialFeedItem)
        case comments(UnifiedSocialFeedItem)
        case report(UnifiedSocialFeedItem)
        case share(UnifiedSocialFeedItem)
        case reportUser
        var id: String {
            switch self {
            case .detail(let i): return "detail-\(i.id)"
            case .comments(let i): return "comments-\(i.id)"
            case .report(let i): return "report-\(i.id)"
            case .share(let i): return "share-\(i.id)"
            case .reportUser: return "report-user"
            }
        }
    }

    init(
        userId: String,
        prefill: SocialFeedAuthor? = nil,
        hasActiveStory: Bool = false,
        service: SocialFeedServicing
    ) {
        _model = StateObject(wrappedValue: UserProfileViewModel(userId: userId, prefill: prefill, service: service))
        self.hasActiveStory = hasActiveStory
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                topBar
                if model.isLoading && model.profile == nil {
                    profileSkeleton
                } else {
                    // Échec de chargement sans profil : ni « — » dans les stats ni
                    // « Aucune publication » sous le message d'erreur.
                    let loadFailed = model.profile == nil && model.errorMessage != nil && !model.isPrivate
                    header
                    if let profile = model.profile, Self.isNewcomer(profile, postCount: model.items.count, isLoadingPosts: model.isLoading) {
                        newcomerCard(profile)
                    } else if !loadFailed, model.profile?.showsStats != false {
                        statsCard
                    }
                    if let networks = model.profile?.networks, !networks.operators.isEmpty {
                        measuredNetworks(networks)
                    }
                    // Publiques, les photos restent quand les chiffres sont masqués (comme Android).
                    if !model.isPrivate, !loadFailed, let photos = model.profile?.recentPhotos, !photos.isEmpty {
                        recentPhotos(photos)
                    }
                    if model.isPrivate {
                        EmptyStateView(
                            title: "Profil privé",
                            message: "Cette personne a choisi de ne pas montrer son profil.",
                            systemImage: "lock.fill"
                        )
                        .accessibilityIdentifier("profile.private")
                    } else {
                        if let error = model.errorMessage {
                            ErrorStateView(title: "Profil indisponible", message: error) {
                                Task { await model.load() }
                            }
                        }
                        // Nouveau membre : la carte d'accueil dit déjà qu'il n'y a rien encore.
                        if !loadFailed, !(model.profile.map {
                            Self.isNewcomer($0, postCount: model.items.count, isLoadingPosts: model.isLoading)
                        } ?? false) {
                            postsBlock
                        }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .navigationTitle(model.profile?.displayName ?? model.prefill?.displayName ?? "Profil")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task {
            if model.profile == nil { await model.load() }
        }
        .refreshable { await model.load() }
        .navigationDestinationItemCompat($followListRoute) { route in
            MemberFollowListView(route: route, service: services.feed)
        }
        .onChangeCompat(of: model.profile?.id) { _, _ in recordVisit() }
        .onChangeCompat(of: model.actionError) { _, message in
            guard let message else { return }
            inAppNotifications.showError(message)
            model.actionError = nil
        }
        .confirmationDialog(
            "Bloquer \(model.profile?.displayName ?? String(localized: "cet utilisateur")) ?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("Bloquer", role: .destructive) { Task { await blockUser() } }
        } message: {
            Text("Tu ne verras plus ses publications ni ses messages, et il ne pourra plus te contacter.")
        }
        .alert(
            "Conversation indisponible",
            isPresented: Binding(
                get: { conversationError != nil },
                set: { if !$0 { conversationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { conversationError = nil }
        } message: {
            Text(conversationError ?? "")
        }
        .sheet(item: $editingPost) { post in
            ComposerSheet(service: services.feed, editing: post, onPublished: { Task { await model.load() } })
        }
        .fullScreenCover(item: $openedPhoto) { photo in
            // Le site se déduit de la photo : le profil ne connaît que son identifiant.
            MapPhotoViewer(
                items: (model.profile?.recentPhotos ?? [photo]).map {
                    MapPhotoTarget(id: $0.id, thumbnailURL: $0.thumbnailUrl)
                },
                initialId: photo.id,
                service: services.photos,
                operatorAccent: { SQBrand.operatorColor($0) },
                operatorLabel: { SQBrand.operatorName($0) ?? $0 }
            )
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .detail(let opened):
                // Élément courant, pas la copie prise à l'ouverture (SOC-17).
                let item = model.items.first { $0.id == opened.id } ?? opened
                SignalDetailSheet(
                    item: item,
                    onLike: { model.react(item) },
                    onRepost: { model.repost(item) },
                    onFavorite: { model.favorite(item) },
                    onComment: { presentedSheet = .comments(item) },
                    // Partage et sourdine étaient des actions vides (AF-FIL-01).
                    onShare: { presentedSheet = .share(item) },
                    onMute: { model.muteNotifications(item) },
                    onReport: { presentedSheet = .report(item) },
                    onPollVote: { option in model.votePoll(item, option: option) }
                )
            case .comments(let item):
                CommentsSheet(service: services.comments, postId: item.backendPostId,
                              profileService: services.feed, reports: services.reports,
                              commentsCount: item.commentsCount,
                              onCommentPosted: { model.commentPosted(on: item) })
            case .report(let item):
                ReportSheet(post: item, service: services.reports)
            case .share(let item):
                PostShareSheet(
                    post: item,
                    messagesService: services.messages,
                    onShare: { conversation in await model.share(item, to: conversation) }
                )
            case .reportUser:
                ReportSheet(target: .profile(model.userId), service: services.reports)
            }
        }
    }

    /// Profil privé : on ne peut ni l'ouvrir ni retirer l'amitié, mais on peut
    /// toujours le signaler ou le bloquer.
    private var privateProfileMenu: some View {
        Menu {
            Button {
                presentedSheet = .reportUser
            } label: {
                Label("Signaler ce profil", systemImage: "flag")
            }
            Button(role: .destructive) {
                showBlockConfirm = true
            } label: {
                Label("Bloquer", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Plus d’options")
        .accessibilityIdentifier("profile.member.more")
    }

    /// Menu de gestion de la relation : bouton « ⋯ » circulaire 40 pt
    /// (surface + ombre repos, règle DA des boutons d'en-tête).
    /// « Retirer des amis » n'apparaît que si l'amitié est active.
    private func manageMenu(_ profile: SocialUserProfile) -> some View {
        Menu {
            if profile.isFriend {
                Button(role: .destructive) {
                    showRemoveFriendConfirm = true
                } label: {
                    Label("Retirer des amis", systemImage: "person.fill.xmark")
                }
            } else if !profile.isSelf {
                Button {
                    Task { await addFriend() }
                } label: {
                    Label(friendRequestSent ? "Demande envoyée" : "Ajouter en ami",
                          systemImage: friendRequestSent ? "checkmark" : "person.fill.badge.plus")
                }
                .disabled(friendRequestSent)
            }
            Button {
                presentedSheet = .reportUser
            } label: {
                Label("Signaler ce profil", systemImage: "flag")
            }
            Button(role: .destructive) {
                showBlockConfirm = true
            } label: {
                Label("Bloquer", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Gérer la relation avec \(profile.displayName)")
        .accessibilityIdentifier("profile.member.more")
        // Attaché au menu (et non au ScrollView) : un seul confirmationDialog
        // par nœud de hiérarchie, celui du blocage vit déjà sur le ScrollView.
        .confirmationDialog(
            "Retirer \(profile.displayName) de tes amis ?",
            isPresented: $showRemoveFriendConfirm,
            titleVisibility: .visible
        ) {
            Button("Retirer des amis", role: .destructive) { Task { await removeFriend() } }
        } message: {
            Text("Vos positions et vos mesures ne seront plus partagées entre vous deux. Tu pourras lui renvoyer une demande plus tard.")
        }
    }

    /// Retire l'amitié puis recharge le profil : `isFriend` est immuable côté
    /// modèle et le serveur reste la source de vérité.
    private func removeFriend() async {
        guard let id = model.profile?.id else { return }
        do {
            try await services.friends.remove(userId: id)
            Haptics.success()
            await model.load()
        } catch {
            model.actionError = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Envoie une demande d'ami. Le profil ne portant pas d'état « en attente »,
    /// on bascule un drapeau local pour éviter les envois répétés.
    private func addFriend() async {
        guard let id = model.profile?.id, !friendRequestSent else { return }
        do {
            try await services.friends.sendRequest(toUserId: id)
            friendRequestSent = true
            Haptics.success()
        } catch {
            model.actionError = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Historique local des profils consultés, proposé dans Explorer.
    private func recordVisit() {
        guard let profile = model.profile, !profile.isSelf else { return }
        RecentlyViewedStore.record(.profile(
            id: profile.id, name: profile.displayName, handle: profile.handle, avatarURL: profile.avatarUrl
        ))
    }

    /// Bloque l'utilisateur consulté (Guideline 1.2) puis ferme l'écran : son
    /// contenu disparaît immédiatement de la pile de navigation courante.
    private func blockUser() async {
        let id = model.profile?.id ?? model.userId
        do {
            try await services.friends.block(userId: id)
            RecentlyViewedStore.remove(.profile, targetId: id)
            Haptics.success()
            dismiss()
        } catch {
            model.actionError = error.userFacingMessage
            Haptics.error()
        }
    }

    // MARK: Header

    /// Retour rond à gauche, « ⋯ » (Bloquer, Retirer des amis, Signaler) à droite.
    private var topBar: some View {
        HStack {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "profile.member.back") {
                dismiss()
            }
            Spacer()
            if let profile = model.profile, !profile.isSelf {
                manageMenu(profile)
            } else if model.isPrivate {
                privateProfileMenu
            }
        }
    }

    /// Carte d'identité centrée (choix d'Alexandre du 25/11) : l'avatar rond dans l'anneau
    /// de niveau, le nom, @ et pays, niveau et ancienneté, la bio en encadré, le réseau le
    /// plus mesuré, les abonnés, puis « Suivre » et « Message ».
    @ViewBuilder
    private var header: some View {
        let profile = model.profile
        VStack(alignment: .center, spacing: SQSpace.md) {
            // Membre Premium mis en valeur (D13) : sa bannière en tête, décorative.
            if let spotlight = profile?.spotlight, spotlight.banner != .empty {
                SQSpotlightBanner(spotlight: spotlight)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .accessibilityIdentifier("profile.member.spotlightBanner")
            }
            VStack(spacing: SQSpace.sm) {
                avatar
                VStack(spacing: SQSpace.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(profile?.displayName ?? model.prefill?.displayName ?? MemberIdentity.someone)
                            .font(SQFont.display(24, .bold, relativeTo: .title2))
                            .foregroundStyle(SQColor.label)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .accessibilityIdentifier("profile.member.name")
                        // Badges sociaux (`accountBadges`), distincts des succès
                        // de gamification.
                        SQUserBadges(badges: profile?.accountBadges ?? [], size: 15)
                    }
                    identityLine(profile)
                }
                if let bio = profile?.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                    ProfileBioBox(bio: bio)
                }
                if let line = profile?.networks.flatMap(Self.mainNetworkLine) {
                    Label {
                        Text(verbatim: line)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.ink2)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.member.mainNetwork")
                }
                if let profile, Self.showsFollowCounters(profile) {
                    followCounters(profile)
                }
            }
            .frame(maxWidth: .infinity)

            if let profile, !profile.isSelf {
                actionRow(profile)
            }
        }
    }

    /// Nouveau membre vu par un autre : aucun chiffre servi au-dessus de zéro, aucun abonné,
    /// aucune publication. La carte d'accueil remplace alors les compteurs à zéro et le vide.
    static func isNewcomer(_ profile: SocialUserProfile, postCount: Int, isLoadingPosts: Bool) -> Bool {
        guard !profile.isSelf, profile.showsStats, postCount == 0, !isLoadingPosts,
              profile.followersCount == 0 else { return false }
        let stats = profile.stats
        let counts = [stats?.displayedPoints, stats?.speedtests, stats?.validations, stats?.photos, stats?.publicSessions]
        return counts.allSatisfy { ($0 ?? 0) == 0 } && profile.recentPhotos.isEmpty
    }

    /// « 0 abonné · 0 abonnement » ne dit rien d'un autre membre : la ligne n'apparaît
    /// qu'avec au moins un abonné ou un abonnement, ou sur son propre profil.
    static func showsFollowCounters(_ profile: SocialUserProfile) -> Bool {
        profile.isSelf || !profile.showsStats || profile.followersCount > 0 || profile.followingCount > 0
    }

    /// « Réseau le plus mesuré : Orange · 52 % ». Jamais « son opérateur » : la donnée dit
    /// où la personne mesure, pas son abonnement (voir `measuredNetworks`).
    static func mainNetworkLine(_ networks: SocialProfileNetworks) -> String? {
        guard let top = networks.operators.max(by: { $0.share < $1.share }), top.share > 0 else { return nil }
        return String(localized: "Réseau le plus mesuré : \(operatorLabel(for: top)) · \(top.percentLabel)")
    }

    /// Carte d'accueil d'un nouveau membre, à la place des compteurs à zéro.
    private func newcomerCard(_ profile: SocialUserProfile) -> some View {
        VStack(spacing: SQSpace.xs) {
            Image(systemName: "hand.wave")
                .font(SQType.heading)
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 40, height: 40)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Nouveau sur SignalQuest")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(profile.isFollowing
                 ? String(localized: "Tu suis \(profile.displayName) : ses premières mesures arriveront dans ton fil.")
                 : String(localized: "Suis \(profile.displayName) pour voir ses premières mesures."))
                .font(SQType.subhead)
                .foregroundStyle(SQColor.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .strokeBorder(SQColor.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.member.newcomer")
    }

    /// `@pseudo · France`, puis le niveau et l'ancienneté. Le pays vient des
    /// mesures, pas d'une déclaration : voir `SocialProfileNetworks`.
    @ViewBuilder
    private func identityLine(_ profile: SocialUserProfile?) -> some View {
        let handle = profile?.handle ?? model.prefill?.handle
        // Pas de drapeau : le pays est DÉDUIT des mesures dans le cas général, et
        // un drapeau donne à cette déduction l'autorité d'une nationalité déclarée.
        let country = profile?.networks?.countryLabel
        VStack(alignment: .center, spacing: SQSpace.xxs) {
            if handle != nil || country != nil {
                // Deux textes, pas un seul : le pseudo reste lisible à part.
                HStack(spacing: SQSpace.xs) {
                    if let handle { Text(verbatim: "@\(handle)") }
                    if handle != nil, country != nil { Text(verbatim: "·").accessibilityHidden(true) }
                    if let country { Text(verbatim: country) }
                }
                .font(SQType.subhead(.medium))
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
            }
            let level = profile?.showsStats == false ? nil : profile?.stats?.displayedLevel.map { String(localized: "Niveau \($0)") }
            let since = profile?.createdAt.map {
                String(localized: "membre depuis \($0.formatted(.dateTime.month(.wide).year()))")
            }
            let second = [level, since].compactMap { $0 }.joined(separator: " · ")
            if !second.isEmpty {
                // La pastille « Niv. N » de l'avatar montre déjà le niveau : à l'écran, la ligne
                // ne garde que l'ancienneté ; VoiceOver, qui ne lit pas la pastille, lit les deux.
                Text(verbatim: since ?? second)
                    .accessibilityLabel(second)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Compteurs « N abonnés · N abonnements » : ils ouvrent les listes, sauf
    /// quand le membre les masque (hors de son propre profil) — le nombre reste
    /// affiché, grisé et sans geste, et VoiceOver annonce « listes masquées ».
    /// Libellés traduits, singulier compris (SOC-28).
    private func followCounters(_ profile: SocialUserProfile) -> some View {
        let locked = profile.followListsHidden && !profile.isSelf
        // Chiffres masqués par le membre : les lignes restent, sans nombre.
        let followers = profile.showsStats ? followersLabel(profile.followersCount) : String(localized: "Abonnés")
        let following = profile.showsStats
            ? followingLabel(profile.followingCount)
            : String(localized: "followlist.segment.following")
        return HStack(spacing: SQSpace.xs) {
            followCounter(followers, kind: .followers, profile: profile, locked: locked)
            Text(verbatim: "·").accessibilityHidden(true)
            followCounter(following, kind: .following, profile: profile, locked: locked)
        }
        .font(SQType.caption(.semibold))
        .foregroundStyle(locked ? SQColor.labelSecondary : SQColor.label)
    }

    @ViewBuilder
    private func followCounter(_ title: String, kind: SocialFollowListKind, profile: SocialUserProfile, locked: Bool) -> some View {
        if locked {
            Text(verbatim: title)
                .frame(minHeight: 44)
                .accessibilityValue("Listes masquées")
                .accessibilityIdentifier("profile.member.\(kind.rawValue).locked")
        } else {
            Button {
                Haptics.light()
                followListRoute = FollowListRoute(
                    userId: profile.id, displayName: profile.displayName, kind: kind, isSelf: profile.isSelf
                )
            } label: {
                Text(verbatim: title)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(kind == .followers ? Text("Ouvre la liste des abonnés") : Text("Ouvre la liste des abonnements"))
            .accessibilityIdentifier("profile.member.\(kind.rawValue)")
        }
    }

    /// Ce que la personne apporte, sur une carte. Le profil public n'expose pas
    /// de nombre de publications : la carte garde les mesures de contribution.
    private var statsCard: some View {
        let stats = model.profile?.stats
        var cells: [(Int?, LocalizedStringKey)] = [
            (stats?.displayedPoints, "Points"),
            (stats?.speedtests, "Tests"),
            (stats?.validations, "Validations"),
            (stats?.photos, "Photos")
        ]
        // Servi seulement quand les chiffres sont visibles (IOS-037, comme Android et le Web).
        if let trips = stats?.publicSessions {
            cells.append((trips, "Trajets publics"))
        }
        // Alignées en haut : un libellé sur deux lignes ne décale pas les nombres.
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    Rectangle().fill(SQColor.separator).frame(width: 1).padding(.vertical, SQSpace.xs)
                }
                VStack(spacing: SQSpace.xxs) {
                    Text(verbatim: SignalFormatters.count(cell.0))
                        .font(SQFont.display(20, .heavy, relativeTo: .title3))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(cell.1)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, SQSpace.md)
        .padding(.horizontal, SQSpace.xs)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("profile.member.stats")
    }

    /// Photos récentes de la personne (6 au plus), comme Android et le Web : une grille
    /// de trois, chaque vignette ouvre la visionneuse plein écran.
    private func recentPhotos(_ photos: [SocialProfilePhoto]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Photos récentes")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, SQSpace.xs)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 3),
                spacing: SQSpace.sm
            ) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    let shape = RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    Button { openedPhoto = photo } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                RemoteImage(url: photo.thumbnailUrl, maxDimension: 200, contentMode: .fill, showsFailureUI: true) {
                                    Rectangle().fill(SQColor.fill).sqShimmer()
                                }
                            }
                            .clipShape(shape)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    // Le libellé est porté par le bouton : il reste lu si la vignette ne charge pas.
                    .accessibilityLabel(Text("Photo \(index + 1) sur \(photos.count)"))
                    .accessibilityHint(Text("Ouvre la photo en plein écran"))
                }
            }
            .padding(SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        .accessibilityIdentifier("profile.member.photos")
    }

    /// Sous 1 000, le nombre entier passe par une variation plurielle du catalogue
    /// (le français met 0 au singulier) ; au-delà, le nombre abrégé est toujours pluriel.
    private func followersLabel(_ count: Int?) -> String {
        guard let count, count < 1_000 else { return String(localized: "\(SignalFormatters.count(count)) abonnés") }
        return String(localized: "\(count) abonnés")
    }

    private func followingLabel(_ count: Int?) -> String {
        guard let count, count < 1_000 else { return String(localized: "\(SignalFormatters.count(count)) abonnements") }
        return String(localized: "\(count) abonnements")
    }

    /// Réseaux réellement mesurés par la personne.
    ///
    /// ⚠️ Le libellé ne dit PAS « opérateur ». Sur un compte réel la répartition
    /// est 52 % Orange / 48 % SFR : en déduire un abonnement serait inventer une
    /// identité. Ce que la donnée établit, c'est la couverture des mesures — et
    /// sur une app de mesure réseau, c'est l'information intéressante.
    ///
    /// La barre peut ne pas être pleine : le serveur écarte les parts sous 5 %
    /// et n'en garde que quatre. Le reste de piste visible est cette part
    /// résiduelle — la combler serait mentir sur le total.
    @ViewBuilder
    private func measuredNetworks(_ networks: SocialProfileNetworks) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Réseaux mesurés")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, SQSpace.xs)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                // Une barre par réseau : la part se lit sans légende à décoder.
                // La somme peut rester sous 100 % : le serveur écarte les parts
                // sous 5 % et n'en garde que quatre — la combler serait mentir.
                ForEach(networks.operators) { entry in
                    HStack(spacing: SQSpace.sm2) {
                        Text(verbatim: Self.operatorLabel(for: entry))
                            .font(SQType.subhead(.bold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                            .frame(width: 72, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(SQColor.segTrack)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Self.tint(for: entry))
                                        .frame(width: max(4, proxy.size.width * entry.share))
                                }
                        }
                        .frame(height: 8)
                        Text(verbatim: entry.percentLabel)
                            .font(SQType.subhead(.medium))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(for: entry))
                }
                // Ne PAS écrire « ses N derniers tests » : `sampleSize` n'est pas une
                // fenêtre de récence, c'est le nombre de tests portant un opérateur.
                Text("Sur \(networks.sampleSize) tests où un réseau a été détecté.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .padding(SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .accessibilityIdentifier("profile.member.networks")
        }
    }

    /// Clés qui ne désignent PAS un opérateur mais l'échec à en résoudre un.
    /// Le serveur les écrit dans `operatorKey` quand le couple MCC/MNC relevé
    /// n'existe pas dans le registre du marché — itinérance à l'étranger, MVNO
    /// absent du registre, ou territoire DROM non mappé finement.
    private static let unresolvedOperatorKeys: Set<String> = ["UNMAPPED_MNO", "DROM_OTHER"]

    /// Libellé d'une part de réseau.
    ///
    /// « Réseau observé » reprend le mot du registre côté serveur
    /// (`radio-market-registry`), pour que web, Android et iOS nomment la même
    /// chose pareil.
    private static func operatorLabel(for entry: SocialProfileOperatorShare) -> String {
        // Un MVNO porte SON nom : c'est celui que la personne lit sur son
        // téléphone. Afficher l'hôte serait exact techniquement et faux de son
        // point de vue — l'hôte est mentionné dans le libellé d'accessibilité et
        // suggéré par la teinte.
        if let brand = entry.brandLabel, !brand.isEmpty { return brand }
        if unresolvedOperatorKeys.contains(entry.key.uppercased()) {
            return String(localized: "Réseau observé")
        }
        // Les noms d'opérateurs sont des sigles : `entry.label` (`capitalized`)
        // donnait « Sfr ». Le registre de marque rend « SFR » ou « TELUS ».
        return SQBrand.operatorName(entry.key) ?? entry.label
    }

    /// Libellé lu par VoiceOver. Il porte, lui, le réseau hôte : « Lebara, sur le
    /// réseau Bouygues Telecom » — l'information ne doit pas être réservée à qui
    /// sait décoder une couleur.
    private static func accessibilityLabel(for entry: SocialProfileOperatorShare) -> String {
        let name = operatorLabel(for: entry)
        guard let hostKey = entry.hostKey,
              let host = SQBrand.operatorName(hostKey) else {
            return String(localized: "\(name) : \(entry.percentLabel) des mesures")
        }
        return String(localized: "\(name), sur le réseau \(host) : \(entry.percentLabel) des mesures")
    }

    /// Teinte d'une part de réseau. Une clé non résolue reçoit un gris neutre,
    /// pour ne pas faire passer un réseau inconnu pour un opérateur connu dans la
    /// barre comme dans la légende. (Le repli de `SQBrand` est lui aussi neutre
    /// depuis qu'il ne retombe plus sur le rouge SFR ; ce garde-fou explicite
    /// couvre les clés que la liste connaît comme non résolues.)
    private static func tint(for key: String) -> Color {
        unresolvedOperatorKeys.contains(key.uppercased())
            ? SQColor.labelTertiary
            : SQBrand.operatorColor(key)
    }

    /// Teinte d'une part. Un MVNO prend la couleur de son HÔTE, atténuée : il
    /// utilise bien ce réseau, mais le distinguer évite de le confondre avec les
    /// mesures faites sur une SIM de l'opérateur lui-même.
    ///
    /// ⚠️ Passer `entry.key` à `SQBrand.operatorColor` donnerait le gris « inconnu »
    /// pour « LEBARA » : c'est l'hôte qui porte la couleur, pas le MVNO.
    private static func tint(for entry: SocialProfileOperatorShare) -> Color {
        guard let hostKey = entry.hostKey else { return tint(for: entry.key) }
        return SQBrand.operatorColor(hostKey).opacity(0.55)
    }

    /// Avatar rond dans son anneau : la story d'abord, puis l'encre d'un membre mis en avant,
    /// sinon l'anneau de niveau (avancement servi, piste neutre sans lui) et sa pastille.
    private var avatar: some View {
        let stats = model.profile?.showsStats == false ? nil : model.profile?.stats
        return ZStack {
            if hasActiveStory {
                Circle().strokeBorder(SQColor.brandRed, lineWidth: 3)
            } else if let spotlight = model.profile?.spotlight {
                // L'encre du membre Premium, un seul anneau ; la story, elle, s'ouvre au toucher
                // et garde le sien.
                Circle().strokeBorder(spotlight.accent.ink, lineWidth: 3)
            } else {
                Circle().strokeBorder(SQColor.chip, lineWidth: 4)
                if let progress = stats?.levelFraction {
                    Circle()
                        .inset(by: 2)
                        .trim(from: 0, to: max(0.015, progress))
                        .stroke(SQColor.brandRed, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            SQAvatar(
                url: model.profile?.avatarUrl ?? model.prefill?.avatarUrl,
                name: model.profile?.displayName ?? model.prefill?.displayName ?? "?",
                size: 82
            )
            .clipShape(Circle())
        }
        .frame(width: 96, height: 96)
        .overlay(alignment: .bottom) {
            if let level = stats?.displayedLevel {
                Text("Niv. \(level)")
                    .font(SQType.micro)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, 2)
                    .background(SQColor.label, in: Capsule(style: .continuous))
                    .offset(y: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    /// Suivre + Message côte à côte : les deux actions qu'on vient chercher sur
    /// un profil. « Message » n'apparaît que si le serveur l'autorise
    /// (`canMessage`) — le masquer vaut mieux qu'un bouton qui échoue.
    @ViewBuilder
    private func actionRow(_ profile: SocialUserProfile) -> some View {
        HStack(spacing: SQSpace.sm) {
            followButton(profile)
            // Cloche seulement pour un abonné, et seulement si le serveur la sert (SOCIAL-BELL-1).
            if profile.isFollowing, !profile.isSelf, let level = profile.postNotifications {
                postNotificationsBell(profile, level: level)
            }
            if profile.canMessage == true {
                GradientButton(
                    "Message",
                    systemImage: "bubble.left",
                    isBusy: isOpeningConversation,
                    style: .secondary
                ) {
                    Task { await openConversation() }
                }
                .accessibilityLabel("Envoyer un message à \(profile.displayName)")
            }
        }
    }

    /// Ouvre la conversation directe. Le serveur DÉDUPLIQUE : il renvoie le
    /// tête-à-tête existant au lieu d'en créer un second.
    private func openConversation() async {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true
        defer { isOpeningConversation = false }
        if AppEnvironment.usesDemoData {
            router.route(toConversation: nil)
            return
        }
        do {
            let conversationId = try await services.openDirectConversation(with: model.userId)
            router.route(toConversation: conversationId)
        } catch {
            // Erreur PROPRE à l'ouverture : passer par `model.errorMessage`
            // afficherait « Profil indisponible » avec un bouton qui recharge
            // le profil — un contresens, le profil s'est bien chargé.
            conversationError = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Cloche du profil (SOCIAL-BELL-1, maquette web validée le 24/11) : au trait coupée,
    /// pleine avec ses ondes allumée ; coche devant le choix retenu, filet avant « Désactivées ».
    private func postNotificationsBell(_ profile: SocialUserProfile, level: PostNotificationLevel) -> some View {
        Menu {
            Section {
                ForEach([PostNotificationLevel.all, .postsReposts, .posts], id: \.self) { option in
                    postNotificationsOption(option, current: level)
                }
            } header: {
                Text(SQElision.apply(String(localized: "Notifications des posts de \(profile.displayName)"), name: profile.displayName))
            }
            Section {
                postNotificationsOption(.off, current: level)
            }
        } label: {
            Image(systemName: level == .off ? "bell" : "bell.and.waves.left.and.right.fill")
                .font(SQFont.body(16, .semibold, relativeTo: .body))
                .foregroundStyle(SQColor.label)
                .frame(width: SQSpace.primaryActionHeight, height: SQSpace.primaryActionHeight)
                .background(SQColor.surface, in: Circle())
                .overlay { Circle().strokeBorder(SQColor.separator, lineWidth: 1) }
                .contentShape(Circle())
        }
        .disabled(model.isSettingPostNotifications)
        .accessibilityLabel(level == .off
            ? SQElision.apply(String(localized: "Activer les notifications des posts de \(profile.displayName)"), name: profile.displayName)
            : SQElision.apply(String(localized: "Notifications des posts de \(profile.displayName) : \(level.label)"), name: profile.displayName))
        .accessibilityIdentifier("profile.postNotifications.bell")
    }

    /// Un choix du menu : la coche native d'un interrupteur, et le sous-titre de « Tous ses posts ».
    private func postNotificationsOption(_ option: PostNotificationLevel, current: PostNotificationLevel) -> some View {
        Toggle(isOn: Binding(
            get: { option == current },
            set: { isOn in if isOn { model.setPostNotifications(option) } }
        )) {
            Text(option.label)
            if let subtitle = option.subtitle { Text(subtitle) }
        }
    }

    private func followButton(_ profile: SocialUserProfile) -> some View {
        // Capsule « Crème » : encre pleine quand non suivi, surface + ombre
        // repos quand suivi (cf. GradientButton .primary / .secondary).
        GradientButton(
            profile.isFollowing ? "Suivi" : "Suivre",
            systemImage: profile.isFollowing ? "checkmark" : "person.badge.plus",
            style: profile.isFollowing ? .secondary : .primary
        ) {
            model.toggleFollow()
        }
        .sqLikePop(trigger: model.followPopTick)
        .disabled(model.isTogglingFollow)
        .accessibilityLabel(profile.isFollowing
            ? SQElision.apply(String(localized: "Se désabonner de \(profile.displayName)"), name: profile.displayName)
            : String(localized: "Suivre \(profile.displayName)"))
    }

    // MARK: Posts

    /// Titre « Publications », puis la liste complète, paginée.
    private var postsBlock: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            Text("Publications")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            .padding(.leading, SQSpace.xs)
            postsWithDeletionDialog
        }
    }

    /// Les publications, avec la confirmation avant d'en supprimer une des tiennes.
    private var postsWithDeletionDialog: some View {
        postsSection
            // Alerte centrée, « Annuler » visible : en confirmationDialog, iOS 26 la posait en
            // bulle sur le centre du fil, pointée vers une autre publication (IOS-044).
            .alert(
                "Supprimer cette publication ?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
            ) {
                Button("Supprimer", role: .destructive) {
                    if let item = pendingDeletion { model.delete(item) }
                    pendingDeletion = nil
                }
                Button("Annuler", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("Cette action est irréversible.")
            }
    }

    @ViewBuilder
    private var postsSection: some View {
        if model.isLoading && model.items.isEmpty {
            LoadingSkeleton().sqShimmer()
        } else if model.items.isEmpty {
            // Pour un autre profil, seules les publications récentes du fil public
            // sont parcourues : on le dit, et on laisse chercher plus loin.
            VStack(spacing: SQSpace.md) {
                EmptyStateView(
                    title: model.profile?.isSelf == true ? "Aucune publication" : "Aucune publication récente",
                    message: model.profile?.isSelf == true
                        ? "Partage ton premier speedtest ou post."
                        : "Les publications récentes de ce profil apparaîtront ici.",
                    systemImage: "sparkles"
                )
                loadMoreButton
            }
        } else {
            LazyVStack(alignment: .leading, spacing: SQSpace.cardPadding) {
                ForEach(model.items) { item in
                    FeedItemCard(
                        item: item,
                        onTap: { presentedSheet = .detail(item) },
                        onLike: { model.react(item) },
                        onRepost: { model.repost(item) },
                        onComment: { presentedSheet = .comments(item) },
                        onFavorite: { model.favorite(item) },
                        onShare: { presentedSheet = .share(item) },
                        onReact: { emoji in model.react(item, emoji: emoji) },
                        // Sans ce vote, le sondage disparaissait du profil (AF-FIL-06).
                        onPollVote: { option in model.votePoll(item, option: option) }
                    )
                    // Même menu que dans le fil : appui long et bouton ⋯ de la carte.
                    .contextMenu { postMenu(for: item) }
                    .environment(\.feedCardMenu, AnyView(postMenu(for: item)))
                    // Un repartage garde son auteur : seul le membre du profil est implicite.
                    .environment(\.feedCardShowsAuthor, item.author.id != model.userId)
                    .sqFadeUp()
                    .onAppear {
                        if item.id == model.items.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                }
                if model.isLoadingMore {
                    SQSpinner()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.md)
                } else {
                    // Une page parcourue sans résultat ne fait apparaître aucune carte :
                    // le chargement au défilement ne se relancerait pas tout seul.
                    loadMoreButton
                }
            }
        }
    }

    /// Actions d'une publication du profil : modifier, épingler et supprimer les
    /// tiennes ; couper les notifications et signaler les autres.
    @ViewBuilder
    private func postMenu(for item: UnifiedSocialFeedItem) -> some View {
        if item.canManage {
            // Un post automatique ne change que de visibilité (403 sinon, #694).
            if item.canEdit {
                Button { editingPost = item } label: {
                    Label("Modifier", systemImage: "pencil")
                }
            } else {
                PostVisibilityPicker(current: item.visibility) { model.setVisibility(item, to: $0) }
            }
            Button { model.togglePin(item) } label: {
                Label(item.isPinned ? "Désépingler" : "Épingler",
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) { pendingDeletion = item } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
        Button { model.muteNotifications(item) } label: {
            let muted = item.notificationsMutedByMe == true
            let title: LocalizedStringKey = muted ? "Réactiver les notifications" : "Couper les notifications"
            let icon = muted ? "bell" : "bell.slash"
            Label(title, systemImage: icon)
        }
        if !item.canManage {
            Button(role: .destructive) { presentedSheet = .report(item) } label: {
                Label("Signaler", systemImage: "flag")
            }
        }
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        if model.nextCursor != nil {
            Button {
                Task { await model.loadMore() }
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Text("Charger plus de publications")
                    if model.isLoadingMore { SQSpinner() }
                }
                .font(SQType.callout(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .disabled(model.isLoadingMore)
            .accessibilityIdentifier("profile.posts.loadMore")
        }
    }

    private var profileSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            HStack(spacing: SQSpace.lg) {
                Circle().fill(SQColor.fill).frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    RoundedRectangle(cornerRadius: SQRadius.sm).fill(SQColor.fill).frame(width: 150, height: 18)
                    RoundedRectangle(cornerRadius: SQRadius.sm).fill(SQColor.fill).frame(width: 90, height: 12)
                }
            }
            RoundedRectangle(cornerRadius: SQRadius.lg).fill(SQColor.fill).frame(height: 52)
            LoadingSkeleton()
        }
        .sqShimmer()
        .redacted(reason: .placeholder)
    }
}

// MARK: - Listes Abonnés / Abonnements

/// Destination poussée par valeur depuis les compteurs d'un profil.
struct FollowListRoute: Hashable {
    let userId: String
    let displayName: String
    let kind: SocialFollowListKind
    let isSelf: Bool
}

/// Pourquoi une liste est fermée : propre au membre, pas une panne à réessayer.
enum FollowListRestriction: Equatable {
    case listsHidden
    case profilePrivate
}

/// État d'une des deux listes (chacune se charge et se pagine seule).
struct FollowListing: Equatable {
    var people: [SocialFollowPerson] = []
    var nextCursor: String?
    var hasLoaded = false
    var isLoading = false
    var isLoadingMore = false
    var loadMoreFailed = false
    var errorMessage: String?
    var restriction: FollowListRestriction?
}

@MainActor
final class FollowListViewModel: ObservableObject {
    @Published var kind: SocialFollowListKind
    @Published private(set) var listings: [SocialFollowListKind: FollowListing] = [:]
    @Published private(set) var followBusyIds: Set<String> = []
    /// Échec d'un suivi : bandeau passager, la liste reste affichée.
    @Published var actionError: String?

    let route: FollowListRoute
    private let service: SocialFeedServicing
    private static let pageSize = 30
    private var loadTokens: [SocialFollowListKind: UUID] = [:]

    init(route: FollowListRoute, service: SocialFeedServicing) {
        self.route = route
        self.service = service
        kind = route.kind
    }

    var current: FollowListing { listings[kind] ?? FollowListing() }

    /// Première page (ou rechargement complet par « tirer pour rafraîchir »).
    /// Un jeton par liste : une réponse qui arrive après un nouveau chargement
    /// (changement de segment, rafraîchissement) est ignorée.
    func load(_ target: SocialFollowListKind? = nil) async {
        let kind = target ?? self.kind
        if AppEnvironment.usesDemoData {
            listings[kind] = Self.demoListing(kind)
            return
        }
        let token = UUID()
        loadTokens[kind] = token
        var listing = listings[kind] ?? FollowListing()
        // Une liste fermée (masquée, privée) repart de zéro : la restriction a pu être levée.
        if listing.restriction != nil { listing = FollowListing() }
        listing.isLoading = true
        listing.isLoadingMore = false
        listing.loadMoreFailed = false
        listing.errorMessage = nil
        listings[kind] = listing
        do {
            let page = try await service.followList(kind, userId: route.userId, cursor: nil, limit: Self.pageSize)
            guard loadTokens[kind] == token else { return }
            listings[kind] = FollowListing(people: Self.unique(page.people), nextCursor: page.nextCursor, hasLoaded: true)
        } catch {
            guard loadTokens[kind] == token else { return }
            var failed = listings[kind] ?? FollowListing()
            failed.isLoading = false
            if error.isCancellation {
                listings[kind] = failed
                return
            }
            if let restriction = Self.restriction(for: error) {
                failed = FollowListing(hasLoaded: true, restriction: restriction)
            } else if failed.hasLoaded && !failed.people.isEmpty {
                // Rafraîchissement raté : la liste déjà affichée reste, l'échec passe en bandeau.
                actionError = error.userFacingMessage
            } else {
                failed.errorMessage = error.userFacingMessage
            }
            listings[kind] = failed
        }
    }

    func loadMore() async {
        let kind = self.kind
        guard !AppEnvironment.usesDemoData, var listing = listings[kind], !listing.isLoading,
              !listing.isLoadingMore, let cursor = listing.nextCursor else { return }
        listing.isLoadingMore = true
        listing.loadMoreFailed = false
        listings[kind] = listing
        do {
            let page = try await service.followList(kind, userId: route.userId, cursor: cursor, limit: Self.pageSize)
            var updated = listings[kind] ?? listing
            let known = Set(updated.people.map(\.id))
            updated.people.append(contentsOf: Self.unique(page.people).filter { !known.contains($0.id) })
            updated.nextCursor = page.nextCursor
            updated.isLoadingMore = false
            listings[kind] = updated
        } catch {
            var failed = listings[kind] ?? listing
            failed.isLoadingMore = false
            // Une annulation (changement de segment) n'est pas un échec à montrer.
            failed.loadMoreFailed = !error.isCancellation
            listings[kind] = failed
        }
    }

    /// Bascule optimiste du suivi, corrigée par la réponse serveur et annulée en cas d'échec
    /// (même mécanisme que le bouton Suivre d'un profil).
    func toggleFollow(_ person: SocialFollowPerson) {
        guard !followBusyIds.contains(person.id) else { return }
        Haptics.medium()
        let wasFollowing = person.following
        setFollowing(!wasFollowing, for: person.id)
        if AppEnvironment.usesDemoData { return }
        followBusyIds.insert(person.id)
        Task {
            defer { followBusyIds.remove(person.id) }
            do {
                let result = try await service.toggleFollow(userId: person.id)
                setFollowing(result.following, for: person.id)
            } catch {
                setFollowing(wasFollowing, for: person.id)
                if !error.isCancellation { actionError = error.userFacingMessage }
                Haptics.error()
            }
        }
    }

    /// Le même membre peut figurer dans les deux listes : on met les deux à jour.
    private func setFollowing(_ value: Bool, for id: String) {
        for (kind, var listing) in listings {
            guard let index = listing.people.firstIndex(where: { $0.id == id }) else { continue }
            listing.people[index].following = value
            listings[kind] = listing
        }
    }

    private static func unique(_ people: [SocialFollowPerson]) -> [SocialFollowPerson] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }

    private static func restriction(for error: Error) -> FollowListRestriction? {
        guard case let APIError.http(status, code, _, _, _) = error, status == 403 else { return nil }
        switch code {
        case "FOLLOW_LISTS_HIDDEN": return .listsHidden
        case "PROFILE_PRIVATE": return .profilePrivate
        default: return nil
        }
    }

    private static func demoListing(_ kind: SocialFollowListKind) -> FollowListing {
        let names = ["Camille", "Nora", "Mehdi", "Inès", "Louis"]
        let people = names.enumerated().map { index, name in
            SocialFollowPerson(
                id: "demo-\(kind.rawValue)-\(index)", name: name, handle: name.lowercased(), avatarUrl: nil,
                following: index % 2 == 0, followsMe: index % 3 == 0, friend: index == 1
            )
        } + [SocialFollowPerson(id: "demo-\(kind.rawValue)-anon", name: nil, handle: nil, avatarUrl: nil)]
        return FollowListing(people: people, nextCursor: nil, hasLoaded: true)
    }
}

/// Liste paginée des abonnés ou des abonnements d'un membre. Toucher une ligne
/// ouvre le profil ; le bouton à droite suit ou se désabonne.
struct MemberFollowListView: View {
    @StateObject private var model: FollowListViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @Environment(\.dismiss) private var dismiss

    @State private var profileAuthor: SocialFeedAuthor?

    init(route: FollowListRoute, service: SocialFeedServicing) {
        _model = StateObject(wrappedValue: FollowListViewModel(route: route, service: service))
    }

    private var ownUserId: String? {
        AppEnvironment.usesDemoData ? AuthUser.mock.id : LocalAccountScope.currentUserId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "followlist.back") {
                        dismiss()
                    }
                    Spacer()
                }
                Text(verbatim: model.route.displayName)
                    .font(SQFont.display(22, .bold, relativeTo: .title2))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                MapSegmented(
                    selection: $model.kind,
                    options: [(SocialFollowListKind.followers, "Abonnés"), (SocialFollowListKind.following, "followlist.segment.following")],
                    identifier: "followlist.segment"
                )
                content
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .navigationTitle(model.route.displayName)
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task(id: model.kind) {
            if !model.current.hasLoaded { await model.load() }
        }
        .refreshable { await model.load() }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: services.feed)
        }
        .onChangeCompat(of: model.actionError) { _, message in
            guard let message else { return }
            inAppNotifications.showError(message)
            model.actionError = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        let listing = model.current
        if let restriction = listing.restriction {
            switch restriction {
            case .listsHidden:
                EmptyStateView(
                    title: "Listes masquées",
                    message: "Ce membre masque ses listes.",
                    systemImage: "eye.slash"
                )
                .accessibilityIdentifier("followlist.hidden")
            case .profilePrivate:
                EmptyStateView(
                    title: "Profil privé",
                    message: "Cette personne a choisi de ne pas montrer son profil.",
                    systemImage: "lock.fill"
                )
                .accessibilityIdentifier("followlist.private")
            }
        } else if let error = listing.errorMessage {
            ErrorStateView(title: "Liste indisponible", message: error) {
                Task { await model.load() }
            }
        } else if !listing.hasLoaded {
            skeleton
        } else if listing.people.isEmpty {
            emptyState
        } else {
            rows(listing)
        }
    }

    private var emptyState: some View {
        let followers = model.kind == .followers
        let isSelf = model.route.isSelf
        return EmptyStateView(
            title: followers ? "Aucun abonné" : "Aucun abonnement",
            message: followers
                ? (isSelf ? "Tes abonnés apparaîtront ici." : "Les abonnés de ce membre apparaîtront ici.")
                : (isSelf ? "Les membres que tu suis apparaîtront ici." : "Les abonnements de ce membre apparaîtront ici."),
            systemImage: "person.2"
        )
        .accessibilityIdentifier("followlist.empty")
    }

    private var skeleton: some View {
        VStack(spacing: SQSpace.md) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: SQSpace.md) {
                    Circle().fill(SQColor.fill).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        RoundedRectangle(cornerRadius: SQRadius.sm).fill(SQColor.fill).frame(width: 140, height: 14)
                        RoundedRectangle(cornerRadius: SQRadius.sm).fill(SQColor.fill).frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .sqShimmer()
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement…")
    }

    private func rows(_ listing: FollowListing) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(listing.people.enumerated()), id: \.element.id) { index, person in
                if index > 0 { Divider().padding(.leading, 58) }
                row(person)
                    .onAppear {
                        if person.id == listing.people.last?.id { Task { await model.loadMore() } }
                    }
            }
            if listing.isLoadingMore {
                SQSpinner()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.md)
            } else if listing.loadMoreFailed {
                // Le dernier élément est déjà à l'écran : sans bouton, rien ne relancerait la page.
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text("Réessayer")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityIdentifier("followlist.loadMore.retry")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func row(_ person: SocialFollowPerson) -> some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.light()
                profileAuthor = person.asAuthor
            } label: {
                HStack(spacing: SQSpace.md) {
                    SQAvatar(url: person.avatarUrl, name: person.displayName, size: 44)
                    VStack(alignment: .leading, spacing: SQSpace.xxs) {
                        Text(verbatim: person.displayName)
                            .font(SQType.body(.bold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                        if let handle = person.handle {
                            Text(verbatim: "@\(handle)")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(1)
                        }
                        relationPill(person)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Ouvre le profil")
            .accessibilityIdentifier("followlist.row.\(person.id)")

            if person.id != ownUserId {
                followButton(person)
            }
        }
        .padding(.vertical, SQSpace.xs2)
    }

    /// « Ami » prime sur « Te suit » : un ami est déjà un lien dans les deux sens.
    @ViewBuilder
    private func relationPill(_ person: SocialFollowPerson) -> some View {
        if person.friend || person.followsMe {
            Group {
                if person.friend { Text("Ami") } else { Text("Te suit") }
            }
                .font(SQType.micro)
                .foregroundStyle(person.friend ? SQColor.accentInk : SQColor.chipInk)
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, SQSpace.xxs)
                .background(person.friend ? SQColor.accentSoft : SQColor.chip, in: Capsule(style: .continuous))
        }
    }

    /// « Suivre » à l'encre ; une fois suivi, bouton secondaire.
    private func followButton(_ person: SocialFollowPerson) -> some View {
        Button {
            model.toggleFollow(person)
        } label: {
            Group {
                if person.following { Text("Suivi") } else { Text("Suivre") }
            }
                .font(SQType.subhead(.bold))
                .foregroundStyle(person.following ? SQColor.label : SQColor.onInk)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 32)
                .background(person.following ? SQColor.chip : SQColor.label, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sqLikePop(trigger: person.following)
        .disabled(model.followBusyIds.contains(person.id))
        .accessibilityLabel(person.following
                ? Text(SQElision.apply(String(localized: "Se désabonner de \(person.displayName)"), name: person.displayName))
                : Text("Suivre \(person.displayName)"))
        .accessibilityIdentifier("followlist.follow.\(person.id)")
    }
}

/// Bio d'un membre dans un encadré doux : trois lignes, puis « Voir plus » quand elle est
/// plus longue.
private struct ProfileBioBox: View {
    let bio: String
    @State private var expanded = false

    /// Au-delà d'environ trois lignes d'un iPhone, ou avec plusieurs paragraphes.
    private var isLong: Bool { bio.count > 130 || bio.filter(\.isNewline).count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text(verbatim: bio)
                .font(SQFont.body(14.5, .regular, relativeTo: .callout))
                .lineSpacing(2)
                .foregroundStyle(SQColor.label)
                .lineLimit(expanded || !isLong ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button {
                    Haptics.light()
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Voir moins" : "Voir plus")
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.member.bio.more")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.top, SQSpace.sm)
        .padding(.bottom, isLong ? 0 : SQSpace.sm)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityIdentifier("profile.member.bio")
    }
}
