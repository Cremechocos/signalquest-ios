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
    @Published var errorMessage: String?
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
            let page = try await service.userPosts(userId: userId, cursor: nil, mine: loaded.isSelf)
            items = page.items
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    func toggleFollow() {
        guard var current = profile, !current.isSelf, !isTogglingFollow else { return }
        followPopTick += 1
        // Pas de Haptics ici : le GradientButton déclencheur en émet déjà un.
        // Bascule optimiste, corrigée par la réponse serveur.
        current.isFollowing.toggle()
        current.followersCount = max(0, current.followersCount + (current.isFollowing ? 1 : -1))
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
                    profile = updated
                }
            } catch {
                // Restaure l'état précédent en cas d'échec.
                if var reverted = profile {
                    reverted.isFollowing.toggle()
                    reverted.followersCount = max(0, reverted.followersCount + (reverted.isFollowing ? 1 : -1))
                    profile = reverted
                }
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    // MARK: Actions sur les posts (miroir de FeedViewModel)

    func react(_ item: UnifiedSocialFeedItem, emoji: String = "❤️") {
        let previous = item
        updateItem(id: item.id) { current in
            var copy = current
            copy.likedByMe.toggle()
            copy.reactions = Self.updatedReactions(current.reactions, emoji: emoji, selected: copy.likedByMe)
            return copy
        }
        guard !AppEnvironment.usesDemoData else { Haptics.light(); return }
        Task {
            do {
                let response = try await service.react(postId: item.id, emoji: emoji)
                applyReactionResponse(itemId: item.id, response: response)
            } catch {
                restore(previous)
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
        }
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
            stats: SocialUserProfileStats(points: 4210, gamificationPoints: 4210, level: 12, validations: 36, photos: 14, speedtests: 220)
        )
        items = SocialFeedPage.demo.items
        nextCursor = nil
        errorMessage = nil
    }
}

struct UserProfileView: View {
    @StateObject private var model: UserProfileViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    /// Anneau de story actif (info connue du feed appelant).
    private let hasActiveStory: Bool

    @State private var presentedSheet: ProfileSheet?
    @State private var showBlockConfirm = false
    @State private var showRemoveFriendConfirm = false

    private enum ProfileSheet: Identifiable {
        case detail(UnifiedSocialFeedItem)
        case comments(UnifiedSocialFeedItem)
        case report(UnifiedSocialFeedItem)
        case reportUser
        var id: String {
            switch self {
            case .detail(let i): return "detail-\(i.id)"
            case .comments(let i): return "comments-\(i.id)"
            case .report(let i): return "report-\(i.id)"
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
            VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                if model.isLoading && model.profile == nil {
                    profileSkeleton
                } else {
                    header
                    if let error = model.errorMessage {
                        ErrorStateView(title: "Profil indisponible", message: error) {
                            Task { await model.load() }
                        }
                    }
                    postsSection
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
        }
        .navigationTitle(model.profile?.displayName ?? model.prefill?.displayName ?? "Profil")
        .navigationBarTitleDisplayMode(.inline)
        .signalQuestBackground()
        .task {
            if model.profile == nil { await model.load() }
        }
        .refreshable { await model.load() }
        .confirmationDialog(
            "Bloquer \(model.profile?.displayName ?? "cet utilisateur") ?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("Bloquer", role: .destructive) { Task { await blockUser() } }
        } message: {
            Text("Tu ne verras plus ses publications ni ses messages, et il ne pourra plus te contacter.")
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .detail(let item):
                SignalDetailSheet(
                    item: item,
                    onLike: { model.react(item) },
                    onRepost: { model.repost(item) },
                    onFavorite: { model.favorite(item) },
                    onComment: { presentedSheet = .comments(item) },
                    onShare: {},
                    onMute: {},
                    onReport: { presentedSheet = .report(item) }
                )
            case .comments(let item):
                CommentsSheet(service: services.comments, postId: item.backendPostId)
            case .report(let item):
                ReportSheet(targetType: "post", targetId: item.backendPostId, service: services.reports)
            case .reportUser:
                ReportSheet(targetType: "user", targetId: model.userId, service: services.reports)
            }
        }
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 40, height: 40)
                .background(SQColor.surface, in: Circle())
                .sqShadowSoft()
                .contentShape(Circle())
        }
        .accessibilityLabel("Gérer la relation avec \(profile.displayName)")
        // Attaché au menu (et non au ScrollView) : un seul confirmationDialog
        // par nœud de hiérarchie, celui du blocage vit déjà sur le ScrollView.
        .confirmationDialog(
            "Retirer \(profile.displayName) de tes amis ?",
            isPresented: $showRemoveFriendConfirm,
            titleVisibility: .visible
        ) {
            Button("Retirer des amis", role: .destructive) { Task { await removeFriend() } }
        } message: {
            Text("Vous ne partagerez plus vos positions ni vos mesures. Tu pourras renvoyer une demande plus tard.")
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
            model.errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Bloque l'utilisateur consulté (Guideline 1.2) puis ferme l'écran : son
    /// contenu disparaît immédiatement de la pile de navigation courante.
    private func blockUser() async {
        guard let id = model.profile?.id else { return }
        do {
            try await services.friends.block(userId: id)
            Haptics.success()
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        let profile = model.profile
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            HStack(alignment: .center, spacing: SQSpace.lg) {
                avatar
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(profile?.displayName ?? model.prefill?.displayName ?? "Utilisateur")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                    if let handle = profile?.handle ?? model.prefill?.handle {
                        Text("@\(handle)")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let createdAt = profile?.createdAt {
                        Text("Membre depuis \(createdAt, format: .dateTime.month(.wide).year())")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelTertiary)
                    }
                }
                Spacer()
                if let profile, !profile.isSelf {
                    manageMenu(profile)
                }
            }

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statsRow

            if let profile, !profile.isSelf {
                followButton(profile)
            }
        }
        .padding(SQSpace.lg)
        .sqEditorialCard()
    }

    private var avatar: some View {
        SQAvatar(
            url: model.profile?.avatarUrl ?? model.prefill?.avatarUrl,
            name: model.profile?.displayName ?? model.prefill?.displayName ?? "?",
            size: 84
        )
        .padding(4)
        .overlay {
            if hasActiveStory {
                SQStoryRing(lineWidth: 3)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: SQSpace.sm) {
            SQChipMetric(
                value: SignalFormatters.count(model.profile?.stats?.speedtests),
                label: "Speedtests",
                systemImage: "speedometer"
            )
            SQChipMetric(
                value: SignalFormatters.count(model.profile?.followersCount),
                label: "Abonnés",
                systemImage: "person.2"
            )
            SQChipMetric(
                value: SignalFormatters.count(model.profile?.followingCount),
                label: "Abonnements",
                systemImage: "person.crop.circle.badge.checkmark"
            )
        }
    }

    private func followButton(_ profile: SocialUserProfile) -> some View {
        // Capsule « Crème » : encre pleine quand non suivi, surface + ombre
        // repos quand suivi (cf. GradientButton .primary / .secondary).
        GradientButton(
            profile.isFollowing ? "Abonné" : "Suivre",
            systemImage: profile.isFollowing ? "checkmark" : "person.badge.plus",
            style: profile.isFollowing ? .secondary : .primary
        ) {
            model.toggleFollow()
        }
        .sqLikePop(trigger: model.followPopTick)
        .disabled(model.isTogglingFollow)
        .accessibilityLabel(profile.isFollowing ? "Se désabonner de \(profile.displayName)" : "Suivre \(profile.displayName)")
    }

    // MARK: Posts

    @ViewBuilder
    private var postsSection: some View {
        if model.isLoading && model.items.isEmpty {
            LoadingSkeleton().sqShimmer()
        } else if model.items.isEmpty {
            EmptyStateView(
                title: "Aucune publication",
                message: model.profile?.isSelf == true
                    ? "Partage ton premier speedtest ou post."
                    : "Les publications récentes de ce profil apparaîtront ici.",
                systemImage: "sparkles"
            )
        } else {
            LazyVStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                ForEach(model.items) { item in
                    FeedItemCard(
                        item: item,
                        onTap: { presentedSheet = .detail(item) },
                        onLike: { model.react(item) },
                        onRepost: { model.repost(item) },
                        onComment: { presentedSheet = .comments(item) },
                        onFavorite: { model.favorite(item) }
                    )
                    .sqFadeUp()
                    .onAppear {
                        if item.id == model.items.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.md)
                }
            }
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
