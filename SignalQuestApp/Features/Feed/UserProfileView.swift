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
            stats: SocialUserProfileStats(points: 4210, gamificationPoints: 4210, level: 12, validations: 36, photos: 14, speedtests: 220),
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
                        hostKey: "BOUYGUES", brandLabel: "Lebara"
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
    @State private var showBlockConfirm = false
    @State private var showRemoveFriendConfirm = false
    /// Demande d'ami envoyée pendant cette session (le profil n'expose pas l'état
    /// « en attente ») : bascule le libellé du menu sur « Demande envoyée ».
    @State private var friendRequestSent = false

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
                    secondaryStats
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
                ReportSheet(target: .post(item.backendPostId), service: services.reports)
            case .reportUser:
                ReportSheet(target: .profile(model.userId), service: services.reports)
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

    /// Envoie une demande d'ami. Le profil ne portant pas d'état « en attente »,
    /// on bascule un drapeau local pour éviter les envois répétés.
    private func addFriend() async {
        guard let id = model.profile?.id, !friendRequestSent else { return }
        do {
            try await services.friends.sendRequest(toUserId: id)
            friendRequestSent = true
            Haptics.success()
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

    /// En-tête « carte de visite » : l'essentiel tient sans défiler.
    ///
    /// L'identité est centrée, la bio reste alignée à gauche (une parole se lit
    /// en drapeau, pas centrée), et les réseaux passent en UNE barre empilée —
    /// à quatre opérateurs, des barres séparées mangeaient quatre lignes.
    @ViewBuilder
    private var header: some View {
        let profile = model.profile
        VStack(spacing: SQSpace.lg) {
            VStack(spacing: SQSpace.sm) {
                avatar
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(profile?.displayName ?? model.prefill?.displayName ?? "Utilisateur")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    // Badges sociaux (`accountBadges`), distincts des succès
                    // de gamification affichés plus bas dans la page.
                    SQUserBadges(badges: profile?.accountBadges ?? [], size: 15)
                }
                identityLine(profile)
            }
            // Réserve la gouttière du menu « ⋯ » pour que le bloc reste centré
            // sur la carte, et non sur l'espace qui lui reste à gauche du menu.
            .padding(.horizontal, SQSpace.xxl)

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(SQFont.body(14.5))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SQSpace.md)
                    .overlay(alignment: .leading) {
                        // Filet d'accent plutôt que des guillemets : la bio est
                        // une parole, pas une métadonnée de plus dans la liste.
                        Capsule()
                            .fill(SQColor.brandRed.opacity(0.35))
                            .frame(width: 3)
                    }
            }

            if let networks = profile?.networks, !networks.operators.isEmpty {
                measuredNetworks(networks)
            }

            statsRow

            if let profile, !profile.isSelf {
                actionRow(profile)
            }
        }
        .padding(SQSpace.lg)
        .sqEditorialCard()
        .overlay(alignment: .topTrailing) {
            // Le menu quitte le flux : l'en-tête est centré, un « ⋯ » inline
            // décalerait l'identité.
            if let profile, !profile.isSelf {
                manageMenu(profile).padding(SQSpace.sm)
            }
        }
    }

    /// `@pseudo · 🇫🇷 France`, puis l'ancienneté. Le pays vient des mesures, pas
    /// d'une déclaration : voir `SocialProfileNetworks`.
    @ViewBuilder
    private func identityLine(_ profile: SocialUserProfile?) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if let handle = profile?.handle ?? model.prefill?.handle {
                    Text("@\(handle)")
                }
                if let networks = profile?.networks, let country = networks.countryLabel {
                    if (profile?.handle ?? model.prefill?.handle) != nil {
                        Text("·").foregroundStyle(SQColor.labelTertiary)
                    }
                    // Pas de drapeau : le pays est DÉDUIT des mesures dans le cas
                    // général, et un drapeau donne à cette déduction l'autorité
                    // d'une nationalité déclarée.
                    Text(country)
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            if let createdAt = profile?.createdAt {
                Text("Membre depuis \(createdAt, format: .dateTime.month(.wide).year())")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .multilineTextAlignment(.center)
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
                .font(SQFont.body(12.5, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(networks.operators) { entry in
                        Rectangle()
                            .fill(Self.tint(for: entry))
                            .frame(width: max(2, proxy.size.width * entry.share))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(SQColor.fill)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            // La légende porte le détail chiffré : la barre seule ne dit pas
            // quel segment est quel opérateur.
            FlowLayoutCompat(spacing: SQSpace.md) {
                ForEach(networks.operators) { entry in
                    let name = Self.operatorLabel(for: entry)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.tint(for: entry))
                            .frame(width: 9, height: 9)
                        Text("\(name) \(entry.percentLabel)")
                            .font(SQFont.body(12))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.accessibilityLabel(for: entry))
                }
            }

            // Ne PAS écrire « ses N derniers tests » : `sampleSize` n'est pas une
            // fenêtre de récence, c'est le nombre de tests portant un opérateur.
            // Un compte à 229 tests dont 8 sans réseau détecté affichait
            // « ses 221 derniers », ce qui laissait croire à une troncature.
            Text("Sur \(networks.sampleSize) tests où un réseau a été détecté.")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
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
            return "\(name) : \(entry.percentLabel) des mesures"
        }
        return "\(name), sur le réseau \(host) : \(entry.percentLabel) des mesures"
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

    private var avatar: some View {
        SQAvatar(
            url: model.profile?.avatarUrl ?? model.prefill?.avatarUrl,
            name: model.profile?.displayName ?? model.prefill?.displayName ?? "?",
            size: 92
        )
        .padding(4)
        .overlay {
            if hasActiveStory {
                SQStoryRing(lineWidth: 3)
            }
        }
    }

    /// Trois mesures de CONTRIBUTION — ce que l'app sait faire de singulier.
    /// Abonnés et abonnements n'ont pas disparu : ils passent en pastilles sous
    /// la carte, où ils restent lisibles sans occuper la ligne forte.
    private var statsRow: some View {
        let stats = model.profile?.stats
        return HStack(spacing: 0) {
            SQChipMetric(value: SignalFormatters.count(stats?.points), label: "Points")
            statDivider
            SQChipMetric(value: SignalFormatters.count(stats?.speedtests), label: "Tests")
            statDivider
            SQChipMetric(value: SignalFormatters.count(stats?.validations), label: "Validations")
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(width: 1)
            .padding(.vertical, SQSpace.xs)
    }

    /// Suivre + Message côte à côte : les deux actions qu'on vient chercher sur
    /// un profil. « Message » n'apparaît que si le serveur l'autorise
    /// (`canMessage`) — le masquer vaut mieux qu'un bouton qui échoue.
    @ViewBuilder
    private func actionRow(_ profile: SocialUserProfile) -> some View {
        HStack(spacing: SQSpace.sm) {
            followButton(profile)
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

    /// Ouvre la conversation directe. Le serveur DÉDUPLIQUE : pour deux
    /// participants sans titre, il renvoie la conversation existante
    /// (`reused: true`) au lieu d'en créer une seconde.
    private func openConversation() async {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true
        defer { isOpeningConversation = false }
        if AppEnvironment.usesDemoData {
            router.route(toConversation: nil)
            return
        }
        do {
            let created = try await services.messages.createConversation(
                participantIds: [model.userId],
                title: nil,
                e2ee: true
            )
            router.route(toConversation: created.conversationId)
        } catch {
            // Erreur PROPRE à l'ouverture : passer par `model.errorMessage`
            // afficherait « Profil indisponible » avec un bouton qui recharge
            // le profil — un contresens, le profil s'est bien chargé.
            conversationError = error.localizedDescription
            Haptics.error()
        }
    }

    /// Pastilles secondaires : le lien social et le niveau.
    ///
    /// Le niveau s'affiche SANS barre de progression : le profil public renvoie
    /// `level`, pas les seuils de la tranche. Dessiner une progression
    /// demanderait d'inventer le denominateur.
    @ViewBuilder
    private var secondaryStats: some View {
        let profile = model.profile
        let stats = profile?.stats
        FlowLayoutCompat(spacing: SQSpace.sm) {
            if let level = stats?.level {
                secondaryChip("Niveau \(level)", systemImage: "chevron.up.circle", accented: true)
            }
            secondaryChip(
                "\(SignalFormatters.count(profile?.followersCount)) abonnés",
                systemImage: "person.2"
            )
            secondaryChip(
                "\(SignalFormatters.count(profile?.followingCount)) abonnements",
                systemImage: "person.crop.circle.badge.checkmark"
            )
            if let photos = stats?.photos, photos > 0 {
                secondaryChip("\(SignalFormatters.count(photos)) photos", systemImage: "photo")
            }
        }
    }

    private func secondaryChip(_ title: String, systemImage: String, accented: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(SQFont.body(12, .medium))
                .monospacedDigit()
        }
        .foregroundStyle(accented ? SQColor.accentInk : SQColor.labelSecondary)
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, 6)
        .background(
            accented ? SQColor.brandRed.opacity(0.12) : SQColor.fill,
            in: Capsule()
        )
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
